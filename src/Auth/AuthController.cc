#include "AuthController.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLoggingCategory>
#include <QtCore/QRectF>
#include <QtGui/QGuiApplication>
#include <QtGui/QKeyEvent>
#include <QtGui/QMouseEvent>
#include <QtGui/QTouchEvent>
#include <QtGui/QWheelEvent>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

#include "CryptoSettings.h"
#include "QGCLoggingCategory.h"
#include "SettingsManager.h"
#include "Utilities/Network/QGCNetworkHelper.h"
#include "MAVLink/Crypto/CryptoController.h"
#include "MAVLink/Crypto/DeviceKeyManager.h"
#include "MissionManager/PlanUploader.h"

#include <algorithm>

QGC_LOGGING_CATEGORY(AuthControllerLog, "Auth.AuthController")

AuthController* AuthController::s_instance = nullptr;

AuthController::AuthController(QObject* parent)
    : QObject(parent)
    , _networkManager(QGCNetworkHelper::createNetworkManager(this))
{
    if (s_instance == nullptr) {
        s_instance = this;
    }
}

AuthController::~AuthController()
{
    if (s_instance == this) {
        s_instance = nullptr;
    }
    if (_screenLocked) {
        qGuiApp->removeEventFilter(this);
    }
}

AuthController* AuthController::instance()
{
    return s_instance;
}

void AuthController::setUnlockDialogOpen(bool open)
{
    if (_unlockDialogOpen != open) {
        _unlockDialogOpen = open;
        emit unlockDialogOpenChanged();
    }
}

QString AuthController::serverUrl() const
{
    // 复用 CryptoSettings::cryptoGcsServerUrl（不含尾斜杠）
    return SettingsManager::instance()->cryptoSettings()->cryptoGcsServerUrl()->rawValue().toString().trimmed();
}

QNetworkReply* AuthController::_postJson(const QString& path, const QJsonObject& body)
{
    const QString url = QStringLiteral("%1%2").arg(serverUrl(), path);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    QGCNetworkHelper::setJsonHeaders(request);
    if (!_token.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _token);
    }
    return _networkManager->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------

void AuthController::login(const QString& username, const QString& password)
{
    if (username.isEmpty() || password.isEmpty()) {
        _setError(QStringLiteral("用户名与密码不能为空"));
        emit loginFailed(errorString());
        return;
    }
    if (serverUrl().isEmpty()) {
        _setError(QStringLiteral("gcs_server 地址未配置（CryptoSettings）"));
        emit loginFailed(errorString());
        return;
    }

    _pendingUsername = username;
    _unlockInProgress = false;

    QJsonObject body;
    body.insert(QStringLiteral("username"), username);
    body.insert(QStringLiteral("password"), password);
    // 声明 QGC 客户端：后端按 qgc 处理并返回设备密钥集合 devices
    body.insert(QStringLiteral("client_type"), QStringLiteral("qgc"));

    QNetworkReply* reply = _postJson(QStringLiteral("/api/auth/login"), body);
    if (reply == nullptr) {
        _setError(QStringLiteral("无法发起登录请求"));
        emit loginFailed(errorString());
        return;
    }
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        _onLoginFinished(reply);
        reply->deleteLater();
    });
    qCDebug(AuthControllerLog) << "login request:" << username;
}

void AuthController::_onLoginFinished(QNetworkReply* reply)
{
    if (!QGCNetworkHelper::isSuccess(reply)) {
        const QString error = QGCNetworkHelper::errorMessage(reply);
        _setError(error);
        if (_unlockInProgress) {
            emit unlockFailed(error);
        } else {
            emit loginFailed(error);
        }
        return;
    }

    const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
    if (doc.isNull() || !doc.isObject()) {
        _setError(QStringLiteral("登录响应非合法 JSON"));
        if (_unlockInProgress) {
            emit unlockFailed(errorString());
        } else {
            emit loginFailed(errorString());
        }
        return;
    }

    const QJsonObject obj = doc.object();
    // 兼容 {token, ...} 顶层 与 { data: {token, ...} } 包裹两种形态
    const QJsonObject data = obj.contains(QStringLiteral("data")) ? obj.value(QStringLiteral("data")).toObject() : obj;

    const QString token = data.value(QStringLiteral("token")).toString();
    if (token.isEmpty()) {
        _setError(QStringLiteral("登录响应缺少 token"));
        if (_unlockInProgress) {
            emit unlockFailed(errorString());
        } else {
            emit loginFailed(errorString());
        }
        return;
    }

    if (_unlockInProgress) {
        // 解锁路径：仅校验当前用户密码，token 顺带刷新，不重置会话状态
        _token = token;
        MAVLinkCrypto::CryptoController::instance()->deviceKeyManager()->setAuthToken(token);
        PlanUploader::instance()->setAuthToken(token);   // 航线上传后台会话 token
        _screenLocked = false;
        qGuiApp->removeEventFilter(this);
        _unlockButton = nullptr;
        emit screenLockedChanged();
        qCDebug(AuthControllerLog) << "unlock success";
        emit unlockSucceeded();
        return;
    }

    // ---- 正常登录路径 ----
    _token = token;
    _currentUser = data.value(QStringLiteral("username")).toString();
    if (_currentUser.isEmpty()) {
        _currentUser = _pendingUsername;
    }
    // 监控主界面（OpsView）所需的用户画像：id/display_name/roles
    _userId = data.value(QStringLiteral("user_id")).toVariant().toLongLong();
    _displayName = data.value(QStringLiteral("display_name")).toString();
    if (_displayName.isEmpty()) {
        _displayName = _currentUser;
    }
    _roles.clear();
    const QJsonArray roleArr = data.value(QStringLiteral("roles")).toArray();
    for (const QJsonValue& rv : roleArr) {
        const QString role = rv.toString();
        if (!role.isEmpty()) {
            _roles.append(role);
        }
    }
    _loggedIn = true;

    // 会话 token 注入 DeviceKeyManager（衔接加密链路取密钥鉴权）
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    MAVLinkCrypto::DeviceKeyManager* const keyManager = crypto->deviceKeyManager();
    keyManager->setAuthToken(_token);
    PlanUploader::instance()->setAuthToken(_token);   // 航线上传后台会话 token

    // 设备密钥集合：解析 {devices:[{deviceID,key}]}，逐条
    //  ① cacheKey(deviceID, key)：密钥写入内存缓存（QHash<DeviceID,Key>，不落地）；
    //  ② addLinkedDevice(deviceID)：deviceID 加入关联集合 —— 80005 明文登记心跳的
    //     payload 即此集合（规范 §3.2.4.2「QGC 重启恢复」：重新登录→取回 deviceID 集合→
    //     登记心跳携带该集合）。两者一起，QGC 才既持有解密密钥、又能向 mavp2p 声明关联。
    // 关键约束：deviceID 只与站点相关、不随登录用户变化——同一站点任意用户（登录/重登/
    // 交接班）取回的集合完全相同，故无需按用户区分或清空 _linkedDevices。
    // 获取规则暂未定义：后端测试时返回 table_device_key 全部，QGC 侧按此格式解析。
    const QJsonArray devices = data.value(QStringLiteral("devices")).toArray();
    int cachedCount = 0;
    for (const QJsonValue& value : devices) {
        const QJsonObject deviceObj = value.toObject();
        const MAVLinkCrypto::DeviceID deviceID = static_cast<MAVLinkCrypto::DeviceID>(
            deviceObj.value(QStringLiteral("deviceID")).toVariant().toUInt());
        const QByteArray keyBytes = QByteArray::fromBase64(deviceObj.value(QStringLiteral("key")).toString().toUtf8());
        if (deviceID == MAVLinkCrypto::kInvalidDeviceID || keyBytes.size() != static_cast<int>(MAVLinkCrypto::kKeySize)) {
            qCWarning(AuthControllerLog) << "skipped invalid device entry: deviceID" << deviceID
                                         << "keyLen" << keyBytes.size();
            continue;
        }
        MAVLinkCrypto::Key key{};
        std::copy(keyBytes.constBegin(), keyBytes.constEnd(), key.begin());
        keyManager->cacheKey(deviceID, key);
        crypto->addLinkedDevice(deviceID);   // 80005 登记集合 = 登录取回的 deviceID 集合
        ++cachedCount;
    }
    qCInfo(AuthControllerLog) << "login success:" << _currentUser << "cached" << cachedCount << "device keys"
                              << "(site-scoped: deviceID set independent of user, same for any login; "
                                 "linked set used as 80005 registration payload)";

    emit loggedInChanged();
    emit currentUserChanged();
    emit displayNameChanged();
    emit userIdChanged();
    emit rolesChanged();
    emit loginSucceeded();
}

// ---------------------------------------------------------------------------
// 交接班
// ---------------------------------------------------------------------------

void AuthController::handover(const QString& receiver)
{
    if (receiver.isEmpty()) {
        return;
    }
    qCInfo(AuthControllerLog) << "交接班:" << _currentUser << "->" << receiver;

    if (serverUrl().isEmpty()) {
        emit handoverCompleted(receiver);
        return;
    }

    QJsonObject body;
    body.insert(QStringLiteral("from_user"), _currentUser);
    body.insert(QStringLiteral("to_user"), receiver);

    QNetworkReply* reply = _postJson(QStringLiteral("/api/auth/handover"), body);
    if (reply == nullptr) {
        emit handoverCompleted(receiver);
        return;
    }
    // 尽力而为：不阻塞 UI，不解析响应
    connect(reply, &QNetworkReply::finished, reply, &QObject::deleteLater);
    emit handoverCompleted(receiver);
}

// ---------------------------------------------------------------------------
// 屏幕锁定 / 解锁
// ---------------------------------------------------------------------------

void AuthController::lockScreen()
{
    if (_screenLocked) {
        return;
    }
    // 预查锁定覆盖层上的解锁按钮（覆盖层随 MainWindow 加载，常驻实例化）
    _unlockButton = nullptr;
    const QList<QWindow*> windows = qGuiApp->topLevelWindows();
    for (QWindow* window : windows) {
        if (auto* quickWindow = qobject_cast<QQuickWindow*>(window)) {
            _unlockButton = quickWindow->findChild<QQuickItem*>(QStringLiteral("lockScreenUnlockButton"));
            if (_unlockButton) {
                break;
            }
        }
    }
    _screenLocked = true;
    emit screenLockedChanged();
    qGuiApp->installEventFilter(this);
    qCDebug(AuthControllerLog) << "screen locked";
}

void AuthController::unlock(const QString& password)
{
    if (password.isEmpty()) {
        _setError(QStringLiteral("密码不能为空"));
        emit unlockFailed(errorString());
        return;
    }
    if (serverUrl().isEmpty()) {
        _setError(QStringLiteral("gcs_server 地址未配置（CryptoSettings）"));
        emit unlockFailed(errorString());
        return;
    }

    _unlockInProgress = true;

    QJsonObject body;
    body.insert(QStringLiteral("username"), _currentUser);
    body.insert(QStringLiteral("password"), password);
    // 解锁同样走 qgc 客户端通道（后端按 qgc 处理）
    body.insert(QStringLiteral("client_type"), QStringLiteral("qgc"));

    QNetworkReply* reply = _postJson(QStringLiteral("/api/auth/login"), body);
    if (reply == nullptr) {
        _setError(QStringLiteral("无法发起解锁请求"));
        emit unlockFailed(errorString());
        return;
    }
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        _onLoginFinished(reply);
        reply->deleteLater();
    });
}

// ---------------------------------------------------------------------------
// 事件过滤器：屏幕锁定核心
// ---------------------------------------------------------------------------
//
// 未锁定或解锁密码框打开时放行一切。锁定时：
//   - 吞：鼠标按钮（含右键→禁右键菜单）、键盘、快捷键
//   - 放行：滚轮（地图缩放）、触摸（地图拖动）、鼠标移动
//   - 例外：落在锁定覆盖层「解锁按钮」上的鼠标事件放行（该按钮保持可点）

bool AuthController::eventFilter(QObject* watched, QEvent* event)
{
    if (!_screenLocked || _unlockDialogOpen) {
        return QObject::eventFilter(watched, event);
    }

    switch (event->type()) {
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonDblClick:
    case QEvent::MouseButtonRelease:
        if (_isOnUnlockButton(watched, event)) {
            break; // 解锁按钮例外放行
        }
        return true;
    case QEvent::KeyPress:
    case QEvent::KeyRelease:
    case QEvent::ShortcutOverride:
    case QEvent::Shortcut:
    case QEvent::ContextMenu:
        return true;
    case QEvent::Wheel:
    case QEvent::MouseMove:
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::TouchEnd:
    case QEvent::TouchCancel:
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

bool AuthController::_isOnUnlockButton(QObject* watched, QEvent* event) const
{
    QQuickItem* unlockButton = _unlockButton;
    if (unlockButton == nullptr) {
        // 兜底：覆盖层若延迟实例化，逐窗口查找
        const QList<QWindow*> windows = qGuiApp->topLevelWindows();
        for (QWindow* window : windows) {
            if (auto* quickWindow = qobject_cast<QQuickWindow*>(window)) {
                unlockButton = quickWindow->findChild<QQuickItem*>(QStringLiteral("lockScreenUnlockButton"));
                if (unlockButton) {
                    break;
                }
            }
        }
        if (unlockButton == nullptr) {
            return false;
        }
    }

    // QEvent 不是 QObject 派生，qobject_cast 不适用；QEvent 多态，用 dynamic_cast。
    QMouseEvent* mouseEvent = dynamic_cast<QMouseEvent*>(event);
    if (mouseEvent == nullptr) {
        return false;
    }

    // 事件坐标归一化到场景坐标（QQuickWindow 场景，与 mapRectToScene 同系）
    QPointF scenePos = mouseEvent->position();
    if (auto* item = qobject_cast<QQuickItem*>(watched)) {
        scenePos = item->mapToScene(mouseEvent->position());
    }

    const QRectF buttonRect = unlockButton->mapRectToScene(
        QRectF(0, 0, unlockButton->width(), unlockButton->height()));
    return buttonRect.contains(scenePos);
}

void AuthController::_setError(const QString& error)
{
    _errorString = error;
    emit errorStringChanged();
}
