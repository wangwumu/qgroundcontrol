#include "AuthController.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLoggingCategory>
#include <QtCore/QRectF>
#include <QtCore/QRegularExpression>
#include <QtCore/QStandardPaths>
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

QGC_LOGGING_CATEGORY(AuthControllerLog, "Auth.AuthController")

AuthController* AuthController::s_instance = nullptr;

AuthController::AuthController(QObject* parent)
    : QObject(parent)
    , _networkManager(QGCNetworkHelper::createNetworkManager(this))
{
    if (s_instance == nullptr) {
        s_instance = this;
    }

    // standaloneMode 只在登录状态变化时重算（为何不连 cryptoKeySource 见头文件 _updateStandaloneMode 注释）。
    // ⚠️ 构造期刻意不调用 standaloneMode()：那时 SettingsManager 未必就绪。
    //    初值与真实值不符只会多 emit 一次；QML 每次求值都走 getter，不会显示错。
    connect(this, &AuthController::loggedInChanged, this, &AuthController::_updateStandaloneMode);
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

bool AuthController::standaloneMode() const
{
    if (_loggedIn) {
        return false;   // 已登录 ⇒ 联网运营态
    }
    CryptoSettings* const cryptoSettings = SettingsManager::instance()->cryptoSettings();
    if (cryptoSettings == nullptr) {
        return true;    // 读不到设置 ⇒ 倒向"保留功能"
    }
    // cryptoKeySource：0 = 本地 key 文件（单机联调那一套）；1 = gcs_server / 数据库（运营）。
    // ‼️ 用它而**不是** cryptoGcsDeviceID：后者是「本机 GCS 自己的 deviceID」，全仓只有
    //    QGCApplication 一个读点、**没有任何写入点** ⇒ 没人填它时恒为默认 0 ⇒ 判据会**恒判成运营**
    //    （实测：本机两个 ini 里都没有这个键）。而 cryptoKeySource 是全仓 3 处代码读点
    //    （QGCApplication.cc 两处 + 本文件）构成的「本地联调 vs 服务端」分岔点，且与"本地登记的
    //    那台 deviceID"(cryptoLocalKeyDeviceID) 成对出现；另有 2 处只是注释里提及，不算读点。
    //    它的默认值是 1 ⇒ 全新机器自动判成运营态，正是要的效果。
    // 用户 2026-09-26 裁定取此字段。
    Fact* const keySourceFact = cryptoSettings->cryptoKeySource();
    // 读不到该 Fact 时同样倒向"保留功能"（同上面两条）。
    return keySourceFact == nullptr ? true : keySourceFact->rawValue().toUInt() == 0;
}

void AuthController::_updateStandaloneMode()
{
    const bool current = standaloneMode();
    if (_lastStandaloneMode != current) {
        _lastStandaloneMode = current;
        emit standaloneModeChanged();
    }
}

bool AuthController::standaloneModeEnabled()
{
    AuthController* const inst = instance();
    // 单例未创建（QML 引擎尚未首次访问本类型）⇒ 倒向"保留功能"，不误裁剪。
    return inst == nullptr ? true : inst->standaloneMode();
}

bool AuthController::backendLoggedIn()
{
    return s_instance && s_instance->_loggedIn;
}

void AuthController::setLoggedInForTest(bool loggedIn)
{
    if (_loggedIn == loggedIn) {
        return;
    }
    _loggedIn = loggedIn;
    // 构造函数里已把 loggedInChanged 连到 _updateStandaloneMode ⇒ 这里会自动重算并（值真变时）广播。
    emit loggedInChanged();
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

// ---------------------------------------------------------------------------
// 设备序列号
// ---------------------------------------------------------------------------

QString AuthController::_readDeviceSerial() const
{
    // 由 _deviceSerialForAuth() 在 kDevDisableDeviceGate=false（正式版）时调用，读取本机真实序列号。
    // AppConfigLocation/qgc_device.cfg（与 mavlink_key.bin 同目录，见 QGCApplication.cc 读密钥先例）。
    // ⚠️ 安全局限：本期明文存 cfg，可被拷贝；正式版须硬件 IC 卡（序列号在加密芯片内，不可导出）。
    // 只读序列号，绝不读写 site_id（site_id 仅在内存+HTTPS 链路）。
    const QString path = QDir(QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation))
                             .filePath(QStringLiteral("qgc_device.cfg"));
    QFileInfo info(path);
    if (!info.exists() || !info.isFile()) {
        // 文件不存在：属部署配置问题（运维需放置 cfg），与「文件存在但缺键」区分开。
        qCWarning(AuthControllerLog) << "设备序列号配置不存在（部署需放置 qgc_device.cfg）:" << path;
        return QString();
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCWarning(AuthControllerLog) << "无法读取设备序列号配置:" << path;
        return QString();
    }
    const QRegularExpression lineRe(QStringLiteral(R"(^\s*([^#;\s][^=]*?)\s*=\s*(.*?)\s*$)"));
    const QRegularExpression keyRe(QStringLiteral("^device_serial$"), QRegularExpression::CaseInsensitiveOption);
    // 值截取到首个行内注释符（# 或 ;）前，再 trim，避免 `device_serial=SN # note` 带上注释。
    const QRegularExpression inlineRe(QStringLiteral(R"(\s*[#;].*$)"));
    while (!file.atEnd()) {
        const QString line = file.readLine().trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')) || line.startsWith(QLatin1Char(';'))) {
            continue;
        }
        const QRegularExpressionMatch m = lineRe.match(line);
        if (!m.hasMatch()) {
            continue;
        }
        if (keyRe.match(m.captured(1).trimmed()).hasMatch()) {
            QString serial = m.captured(2);
            serial = serial.remove(inlineRe).trimmed();
            if (!serial.isEmpty()) {
                return serial;
            }
        }
    }
    // 文件存在但缺 device_serial 键：属配置缺项，与「文件不存在」区分。
    qCWarning(AuthControllerLog) << "设备序列号配置缺 device_serial 键:" << path;
    return QString();
}

// 返回本次 login/unlock 携带的设备序列号（site 归属门禁）。
// ⚠️ 上线前必须把 kDevDisableDeviceGate 置为 false，否则产品会继续无校验地用固定序列号登录。
// false 时改读 qgc_device.cfg 的真实序列号（后端门禁恢复后强制归属校验）。
QString AuthController::_deviceSerialForAuth() const
{
    const bool kDevDisableDeviceGate = true;   // ⚠️【开发期临时禁用】上线前置 false，恢复站点归属门禁
    if (kDevDisableDeviceGate) {
        return QStringLiteral("UAVM-QGC-DEV");
    }
    return _readDeviceSerial();
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
    // 站点归属门禁：QGC 登录必须携带本机设备序列号（后端校验设备绑定站点与用户站点匹配，恢复门禁后生效）。
    // 【开发期临时】kDevDisableDeviceGate=true 时用固定序列号（见 _deviceSerialForAuth），不读 cfg：
    // 避免开发/联调因 cfg 缺失或未登记而登录失败。后端对应校验目前已注释掉（见 auth.go），固定值不会被校验。
    // 正式上线前：① 置 kDevDisableDeviceGate=false（改读 qgc_device.cfg）；② 恢复后端校验。
    // 见《07-界面功能设计.md》「站点归属设备序列号机制（开发期临时禁用）」一节。
    const QString deviceSerial = _deviceSerialForAuth();

    _pendingUsername = username;
    _unlockInProgress = false;

    QJsonObject body;
    body.insert(QStringLiteral("username"), username);
    body.insert(QStringLiteral("password"), password);
    // 声明 QGC 客户端：后端按 qgc 处理并返回设备密钥集合 devices
    body.insert(QStringLiteral("client_type"), QStringLiteral("qgc"));
    // 设备序列号（站点归属门禁）：后端查表得绑定站点并与用户站点匹配，匹配才放行（恢复门禁后生效）
    body.insert(QStringLiteral("device_serial"), deviceSerial);

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
        // 优先透出后端返回的具体原因（QGC 设备序列号未登记/停用/站点不匹配 等含差异提示），
        // 而非通用 "HTTP 403: Forbidden"——否则用户无法区分该去登记设备、恢复设备还是换账号。
        QString error = QGCNetworkHelper::errorMessage(reply);
        // 不走 parseJsonReply——它在 reply->error()!=NoError（即任何 4xx/5xx，含 403）时直接返回
        // 空文档、不 readAll()，导致后端返回的具体 error（序列号未登记/停用/站点不匹配）永远透不出来。
        // 此处直接读 body：先用 looksLikeJson 排除 nginx/网关错误页，再取后端 error 字段。
        const QByteArray body = reply->readAll();
        if (QGCNetworkHelper::looksLikeJson(body)) {
            const QJsonDocument doc = QJsonDocument::fromJson(body);
            if (doc.isObject()) {
                const QString apiError = doc.object().value(QStringLiteral("error")).toString();
                if (!apiError.isEmpty()) {
                    error = apiError;
                }
            }
        }
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
    // 本站点 id：登录响应 role_sites{role:[site_id...]}。业务假定「一用户只属一个站点」（创建/修改
    // 用户界面保证），故此处取 role_sites 中首个非零 site_id 作为本站（OpsView 判定基准）。
    // 注：后端 role_sites 理论可为多值（表未硬约束），但用户界面已保证单站点；如未来放行多站点，
    // 应改用登录门禁匹配的权威 site_id 而非在此扫首个。site_id 仅存内存，绝不落文件。
    // 每次正常登录无条件重解析：换账号（交接班/登出重登）会覆盖旧站点值，避免残留上一账号站点。
    _siteId = 0;
    const QJsonObject roleSites = data.value(QStringLiteral("role_sites")).toObject();
    for (const QJsonValue& sitesVal : roleSites) {
        const QJsonArray sites = sitesVal.toArray();
        for (const QJsonValue& s : sites) {
            const qint64 site = s.toVariant().toLongLong();
            if (site > 0) {
                _siteId = site;
                break;
            }
        }
        if (_siteId > 0) {
            break;
        }
    }

    // ---- QGC 登录角色闸（2026-09-21 用户裁定）----
    // QGC 只允许三种身份登入：站点操作员（SITE_ATC）、航线监控员（ROUTE_MONITOR）、
    // 飞行安全监理（FLIGHT_SUPERVISOR）——《异常处置与降落端载体迁移-设计稿-20260913.md》§1 B13。
    // 其余角色（场地管理员 SITE_MANAGER、系统管理员、运营制单/复核、观察者）**一律拒绝**：
    // 清空本次已写入的会话字段并保持在**未登录**状态，不进入任何主界面。
    // 改前无此闸：token 到手即置 _loggedIn=true，非三类角色会在 MainWindow.qml 的兜底分支落到
    // showFlyView()——那是"把人放到别的界面"而非"拒绝"，于是场地管理员能以已登录状态进入地面站。
    // ⚠️ 与后端 handlers/auth.go 的 qgc 白名单**两端同解**（后端同句文案、同三种角色）；此处是第二道，
    //    防的是旧版后端/绕过前端闸的情形。**两处白名单必须同步修改**，只改一边会出现"能登进去但处处 403"
    //    或"根本登不进去"。
    // 位置约束（关键）：必须在 `_loggedIn = true` **之前**。若放到其后，就成了"先算登录成功、再回滚登出"，
    //    而下方 DeviceKeyManager::cacheKey / CryptoController::addLinkedDevice 已执行——加密链路会带着
    //    非授权账号取回的 deviceID 集合继续跑（80005 登记集合被污染）。
    // 已知边界：DeviceKeyManager/PlanUploader 内**先前**会话注入的 token 不在此处理（既有失败分支同样不
    //    处理）。当前 QGC 无登出路径，进程内"已登录再换账号登录"不可达；将来若加登出，需一并清理。
    if (!_roles.contains(QStringLiteral("SITE_ATC"))
        && !_roles.contains(QStringLiteral("ROUTE_MONITOR"))
        && !_roles.contains(QStringLiteral("FLIGHT_SUPERVISOR"))) {
        const bool wasLoggedIn = _loggedIn;
        _token.clear();
        _currentUser.clear();
        _displayName.clear();
        _userId = 0;
        _roles.clear();
        _siteId = 0;
        _loggedIn = false;
        // 责任方标志一并收回。**本分支是普通被拒登录路径**——任何无三类角色的账号尝试登录
        // 都会走到这里，不只是"已登录再换账号登录"（后者才因无登出路径而不可达）。与上面
        // 清 _roles 同理：不能留下上一账号的责任方身份。注意 setResponsibleParty(false)
        // 会**顺带把已建立的加密链路降回 Standby**（见 CryptoController.h 内说明）。
        MAVLinkCrypto::CryptoController::instance()->setResponsibleParty(false);
        if (wasLoggedIn) {
            emit loggedInChanged();
        }
        const QString error = QStringLiteral("该账号无地面站操作权限（仅站点操作员、航线监控员、飞行安全监理可登录）");
        _setError(error);
        qCWarning(AuthControllerLog) << "login rejected: 非 QGC 三类身份，已保持未登录";
        // _unlockInProgress 时本函数不会走到这里（解锁分支在更早处 return），故一律发 loginFailed。
        emit loginFailed(error);
        return;
    }

    _loggedIn = true;

    // 会话 token 注入 DeviceKeyManager（衔接加密链路取密钥鉴权）
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    MAVLinkCrypto::DeviceKeyManager* const keyManager = crypto->deviceKeyManager();

    // 责任方闸（2026-09-27 用户裁定）：**只有站点操作员那一台 QGC 与 PX4 握手**。
    // 航线监控员在获取权限前没有权限向 PX4 发送任何指令——它的 QGC 停在 Standby，
    // 只解密遥测，任务/围栏/集结点/参数/心跳一条都发不出去（LinkInterface 对非 Active
    // 直接 drop；闸的落点是 CryptoController::beginLinking，那是三个建链入口的汇聚点）。
    //
    // 判据是「**含** SITE_ATC」而非「不含 ROUTE_MONITOR」：后端 roles.go 明确允许这两种
    // 身份并存（角色是并集），按后者写会把兼双身份的账号误判成非责任方。
    //
    // ‼️ **无条件覆写**，不能写成"只在为 false 时才设"：QGCApplication::init 在本地密钥源
    //    （cryptoKeySource==0）时已写过 true，而那是"单机联调不登录"场景的判断。若用户在
    //    那样配置的机器上仍然登录（进运营模式），必须以角色为准把那个 true 收回来，
    //    否则航线监控员会带着 init 留下的责任方身份建链。
    crypto->setResponsibleParty(_roles.contains(QStringLiteral("SITE_ATC")));
    keyManager->setAuthToken(_token);
    PlanUploader::instance()->setAuthToken(_token);   // 航线上传后台会话 token

    qCInfo(AuthControllerLog) << "login success:" << _currentUser;

    // 设备密钥与 deviceID **都不再随登录响应下发**（规范 §2.7.2 c）。
    // 旧行为是解析响应里的 {devices:[{deviceID,key}]}、逐条 cacheKey + addLinkedDevice，
    // 而后端返回的是 table_device_key 全平台 ACTIVE 集合 ⇒ 任意一台 QGC 登录后即手握
    // 每一架飞机的密钥（先到的那架抢占 CryptoController 的唯一 Active 槽位，后到者永远排队）。
    //
    // deviceID 与密钥的唯一合法来源是两条**已在跑的轮询**：
    //   · 站点操作员 ⇒ `OpsShell.qml` 把 overview 的 device_id 推给 `addLinkedDevice`
    //   · 航线监控员 ⇒ `RomView.qml` 推 `setMonitorDevices`
    // 取密钥发生在建链闸**之前**（`CryptoController::addLinkedDevice` /
    // `setMonitorDevices` / `MAVLinkProtocol` 明文待命心跳支的被动触发），见规范 §2.7.2 e。
    // 因此登录这一步**不做任何** deviceID/密钥的装配，也不清空 —— 那两份集合各有
    // 自己的替换语义（站点视图是"新出现即加、消失即释出"的集合 diff，见 `OpsShell.qml`
    // 的 `_siteDeviceIdsKey`；监控清单是整份替换）。

    // 立即跑一轮登记加速，让设备在秒级内接上，而不是等 batches × 10s 的游标周期
    // （设计文档 §3.4）。⚠️ 理由**不是**"登录刚填充了登记集合"——登录已不再填充任何集合
    // （见上）；这里是"登录是一个合理的重试时机"，且此后各通道的 adopt 侧会各自触发。
    // 复用上面已取的 `crypto`，不新起 CryptoController::instance() 调用点。
    // ⚠️ 排在 emit loginSucceeded() 之前：那块信号已经接了一堆消费者
    //    （计划控制器的自动装载等），把登记加速排在它们后面没有意义。
    crypto->requestAcceleratedRegistration();

    emit loggedInChanged();
    emit currentUserChanged();
    emit displayNameChanged();
    emit userIdChanged();
    emit rolesChanged();
    emit siteIdChanged();
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
    // 解锁同样走 qgc 客户端通道（后端序列号校验在【开发期临时禁用】，见 auth.go；
    // 恢复启用后缺序列号才会返回 403）。
    // 设备序列号同 login：kDevDisableDeviceGate=true 时固定值；上线置 false 后读 qgc_device.cfg。
    const QString deviceSerial = _deviceSerialForAuth();

    _unlockInProgress = true;

    QJsonObject body;
    body.insert(QStringLiteral("username"), _currentUser);
    body.insert(QStringLiteral("password"), password);
    // 解锁同样走 qgc 客户端通道（后端按 qgc 处理）
    body.insert(QStringLiteral("client_type"), QStringLiteral("qgc"));
    body.insert(QStringLiteral("device_serial"), deviceSerial);

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
