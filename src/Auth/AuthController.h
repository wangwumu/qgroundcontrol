#pragma once

/// QGC 用户会话控制器（登录 / 交接班 / 屏幕锁定）。
///
/// 职责：
/// - 登录：POST {cryptoGcsServerUrl}/api/auth/login（用户名 + 密码）→ 后台验证；
///   成功后保存会话 token、当前用户，并把返回的「设备密钥集合」逐条写入
///   DeviceKeyManager 内存缓存（QHash<DeviceID, Key>，不落地）。
/// - 交接班：记录当前用户 → 接收人（尽力 POST /api/auth/handover）。
/// - 屏幕锁定：锁定态通过 `qApp` 事件过滤器吞掉鼠标按钮 + 键盘 + 快捷键，
///   放行滚轮(Wheel)与触摸(Touch)以保留地图缩放/拖动；解锁按钮位置例外放行。
/// - 会话仅存内存，重启 QGC 需重新登录（不持久化）。
///
/// QML 单例：`import QGroundControl` 后直接 `AuthController.xxx` 访问。
/// C++ 侧通过 `AuthController::instance()` 访问同一实例（QML 引擎先创建）。

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtNetwork/QNetworkAccessManager>
#include <QtQmlIntegration/QtQmlIntegration>

class QNetworkReply;
class QQuickItem;
class QJsonObject;

Q_DECLARE_LOGGING_CATEGORY(AuthControllerLog)

class AuthController : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(AuthController)
    QML_SINGLETON

    Q_PROPERTY(bool      loggedIn         READ loggedIn         NOTIFY loggedInChanged)
    Q_PROPERTY(QString   currentUser      READ currentUser      NOTIFY currentUserChanged)
    Q_PROPERTY(QString   displayName      READ displayName      NOTIFY displayNameChanged)
    Q_PROPERTY(qint64    userId           READ userId           NOTIFY userIdChanged)
    Q_PROPERTY(QStringList roles          READ roles            NOTIFY rolesChanged)
    Q_PROPERTY(bool      screenLocked     READ screenLocked     NOTIFY screenLockedChanged)
    Q_PROPERTY(bool      unlockDialogOpen READ unlockDialogOpen WRITE setUnlockDialogOpen NOTIFY unlockDialogOpenChanged)
    Q_PROPERTY(QString   errorString      READ errorString      NOTIFY errorStringChanged)
    /// 本站点 id（来自 login 响应 role_sites 单值；site_id 仅存内存，绝不落配置文件）。
    Q_PROPERTY(qint64    siteId           READ siteId           NOTIFY siteIdChanged)
    /// 单机模式：本地按单机方式配置（cryptoKeySource == 0，走本地密钥文件）且未登录。
    /// true（单机）⇒ 一切照旧：参数照常下载、开发菜单照显。
    /// false（联网运营）⇒ 停参数下载 + 裁剪界面，见 docs/qgc/联网运营模式界面裁剪-20260926.md。
    /// ‼️ 判据只在此处定义一次：C++ 侧读本方法、QML 侧读本属性，**禁止在别处重写表达式**
    ///    ——同一条件写两遍必然漂移，而本仓已有过「只改了一侧」的先例。
    Q_PROPERTY(bool      standaloneMode   READ standaloneMode   NOTIFY standaloneModeChanged)

public:
    explicit AuthController(QObject* parent = nullptr);
    ~AuthController() override;

    AuthController(const AuthController&) = delete;
    AuthController& operator=(const AuthController&) = delete;

    /// 全局单例访问点（QML 引擎首次访问本类型时构造并记录）。
    static AuthController* instance();

    /// 后台已登录 ⇒ 计划 / 地理围栏 / 返航点的**自动**装载（非用户显式请求）应被闸住。
    /// 判据挂在登录状态上而非具体视图，故 OpsView 及今后新增的视图一并适用。
    /// 未创建单例时返回 false —— 宁可照常装载，也不误跳过（QGC 缺省页面行为不变）。
    static bool backendLoggedIn();

    bool    loggedIn() const { return _loggedIn; }

    /// 单机模式判据：`!loggedIn && cryptoKeySource == 0`。
    /// ‼️ 用 cryptoKeySource 而非 cryptoGcsDeviceID（用户 2026-09-26 裁定）：后者是「本机 GCS 自己的
    ///    deviceID」，全仓零写入点、本机两个 ini 里都没这个键 ⇒ 恒取默认 0 ⇒ 判据会恒判成运营，
    ///    与「单机要保留」正好相反。cryptoKeySource 默认 1（= 运营），全新机器自动落到运营态。
    /// 安全取向：**读不到判据时返回 true**（宁可照常下载参数、照显菜单，也不误裁剪）
    /// —— 与 backendLoggedIn() 的「宁可照常装载，也不误跳过」同一取向。
    bool    standaloneMode() const;

    /// C++ 侧判据入口（static 包装）：供不便持有实例的调用点使用（如 ParameterManager）。
    /// 单例未创建时返回 true —— 同样是「宁可照常，也不误裁剪」。
    /// ‼️ C++ 侧一律走本函数、QML 侧一律走上面的属性，**不要在任何地方重写那个表达式**。
    static bool standaloneModeEnabled();
    QString currentUser() const { return _currentUser; }
    QString     displayName() const { return _displayName; }
    qint64      userId() const { return _userId; }
    QStringList roles() const { return _roles; }
    Q_INVOKABLE bool hasRole(const QString& role) const { return _roles.contains(role); }
    bool    screenLocked() const { return _screenLocked; }
    bool    unlockDialogOpen() const { return _unlockDialogOpen; }
    void    setUnlockDialogOpen(bool open);
    QString errorString() const { return _errorString; }
    qint64  siteId() const { return _siteId; }          ///< 本站点 id（仅内存，登录 role_sites 单值）

    /// 登录：POST /api/auth/login。成功后解析 token + devices(设备密钥集合) 并内存缓存。
    Q_INVOKABLE void login(const QString& username, const QString& password);

    /// 交接班：记录当前用户 → 接收人（尽力 POST /api/auth/handover，不阻塞 UI）。
    Q_INVOKABLE void handover(const QString& receiver);

    /// 锁定屏幕：置锁定态 + 安装 qApp 事件过滤器。
    Q_INVOKABLE void lockScreen();

    /// 解锁：复用 /api/auth/login 验证当前用户密码，通过后解除锁定。
    Q_INVOKABLE void unlock(const QString& password);

    /// gcs_server 基址（复用 CryptoSettings::cryptoGcsServerUrl）。
    Q_INVOKABLE QString serverUrl() const;

    /// 会话是否已持有 token（DeviceKeyManager 取密钥时用 Bearer）。
    Q_INVOKABLE bool hasToken() const { return !_token.isEmpty(); }

    /// 会话 token（OpsView 网络层 XHR 鉴权用，Authorization: Bearer <token>）。
    Q_INVOKABLE QString authToken() const { return _token; }

signals:
    void loggedInChanged();
    void currentUserChanged();
    void displayNameChanged();
    void userIdChanged();
    void rolesChanged();
    void screenLockedChanged();
    void unlockDialogOpenChanged();
    void errorStringChanged();
    void siteIdChanged();
    void standaloneModeChanged();
    void loginSucceeded();
    void loginFailed(const QString& error);
    void unlockSucceeded();
    void unlockFailed(const QString& error);
    void handoverCompleted(const QString& receiver);

protected:
    /// 屏幕锁定的输入过滤：吞鼠标按钮 + 键盘 + 快捷键，放行滚轮/触摸/移动。
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    QNetworkReply* _postJson(const QString& path, const QJsonObject& body);
    void _onLoginFinished(QNetworkReply* reply);
    void _onUnlockFinished(QNetworkReply* reply);
    /// 事件坐标是否落在锁定覆盖层「解锁按钮」上（该按钮在锁定时保持可点）。
    bool _isOnUnlockButton(QObject* watched, QEvent* event) const;
    void _setError(const QString& error);
    /// 登录状态变化后重算 standaloneMode，值真变了才 emit。
    /// ⚠️ 刻意**不**连 cryptoKeySource 的 rawValueChanged：它是启动时读取的静态配置，
    ///    改了本就要重启 QGC 才生效（QGCApplication 启动时按它决定密钥来源与注入）；
    ///    且运营态下菜单入口已被隐掉 ⇒ 用户够不到"运行中改它"的路径。
    void _updateStandaloneMode();
    /// 从 AppConfigLocation/qgc_device.cfg 读本机 QGC 设备序列号（key=value，# 注释跳过）。
    /// ⚠️ 安全局限：本期明文，可被拷贝；正式版须硬件 IC 卡（序列号在加密芯片内）。
    /// 失败/未配置返回空串。只读序列号，绝不读写 site_id。
    /// 由 _deviceSerialForAuth() 在 kDevDisableDeviceGate=false（正式版）时调用。
    QString _readDeviceSerial() const;
    /// login/unlock 携带的设备序列号（site 归属门禁）。kDevDisableDeviceGate=true（开发期）返回固定值，
    /// false 返回 _readDeviceSerial()（真实序列号）。⚠️ 上线前置 false，否则产品无校验地用固定序列号登录。
    QString _deviceSerialForAuth() const;

    QNetworkAccessManager* _networkManager = nullptr;
    QString _token;                 ///< 会话 token（仅内存）
    QString _currentUser;
    QString _displayName;           ///< display_name（命令条显示名；回退 username）
    qint64  _userId = 0;            ///< user_id（交接方向判别 proposed_by == 当前用户）
    qint64  _siteId = 0;            ///< 本站点 id（login role_sites 单值；仅内存，绝不落配置文件）
    QStringList _roles;             ///< roles（界面按角色渲染/分流）
    QString _pendingUsername;
    bool    _loggedIn = false;
    /// 上次广播出去的 standaloneMode，仅用于判断"要不要 emit"。
    /// QML 每次求值都走 getter，故初值与真实值不符只会多 emit 一次，不会显示错。
    bool    _lastStandaloneMode = true;
    bool    _screenLocked = false;
    bool    _unlockDialogOpen = false;
    bool    _unlockInProgress = false;      ///< 当前响应来自 unlock()（仅校验密码，不重置会话）
    QString _errorString;
    QQuickItem* _unlockButton = nullptr;    ///< 锁定覆盖层上的解锁按钮（objectName 查找）

    static AuthController* s_instance;      ///< 单例指针（构造时记录首个实例）
};
