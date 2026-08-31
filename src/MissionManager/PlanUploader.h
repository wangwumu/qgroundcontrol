#pragma once

/// QGC 航线上传后台（PlanUploader）。
///
/// 把「航线规划」当前计划上传到 gcs_server，时序为：
///   逐点建临时航点（POST /api/waypoints，is_temporary=true）
///   → 建临时航线（POST /api/routes，登录 client_type=qgc 自动置 TEMPORARY）
///   → 建飞行任务（POST /api/tasks，必填 uav_id）
///   → 提交审核（POST /api/tasks/:id/submit，DRAFT→PENDING_REVIEW，等待批准）
///
/// 航线类型约定（gcs_server route.go:95）：QGC（client_type=qgc）创建的航线恒为
/// 临时航线 TEMPORARY；web 后台创建的为固定航线 FIXED。临时航线/临时航点不参与
/// 航线级审核（ReviewStatus=VALIDATED），任务级审核由 submit/review 完成。
///
/// QML 访问：在 QGCCorePlugin::createQmlApplicationEngine 注册为上下文属性
/// `planUploader`（与 joystickManager 同款方式），QML 直接 `planUploader.xxx`。
/// C++ 侧通过 `PlanUploader::instance()` 访问同一实例。
///
/// token/serverUrl 注入（同 DeviceKeyManager）：
///   - QGCApplication 启动：setServerUrl(cryptoGcsServerUrl)
///   - AuthController 登录/解锁成功：setAuthToken(_token)
///
/// 线程亲和：本类全部接口仅供 GUI 线程调用（_networkManager 以 this 为 parent、
/// 全部 reply 以 this 为 context 连接），勿从工作线程调用。

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantList>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkRequest>

#include <functional>

class QNetworkReply;
class QJsonObject;
class PlanMasterController;

Q_DECLARE_LOGGING_CATEGORY(PlanUploaderLog)

class PlanUploader : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QVariantList uavList   READ uavList   NOTIFY uavListChanged)
    Q_PROPERTY(bool         uploading READ uploading NOTIFY uploadingChanged)

public:
    explicit PlanUploader(QObject* parent = nullptr);
    ~PlanUploader() override;

    PlanUploader(const PlanUploader&) = delete;
    PlanUploader& operator=(const PlanUploader&) = delete;

    /// 全局单例访问点（首次调用时构造并记录）。
    static PlanUploader* instance();

    /// gcs_server 基址 / Bearer token（与 DeviceKeyManager 相同注入方式）。
    void setServerUrl(const QString& url);
    void setAuthToken(const QString& token);
    bool isConfigured() const { return !_serverUrl.isEmpty(); }

    QVariantList uavList() const { return _uavList; }
    bool uploading() const { return _uploading; }

    /// 拉取可选无人机列表（GET /api/uavs）→ uavList，供界面下拉选择。
    Q_INVOKABLE void fetchUavs();

    /// 上传当前计划到后台：逐点建临时航点 → 建临时航线 → 建飞行任务 → 提交审核。
    /// pmc 为 PlanMasterController（QML 传 _planMasterController，QML_ELEMENT 已注册）；
    /// uavId 为界面下拉选中的无人机 id（POST /api/tasks 必填）；
    /// title 为航线标题（必填，作 route_name，便于区分多条临时航线）。
    /// 成功发 uploadSucceeded(message)，失败发 uploadFailed(error)。
    Q_INVOKABLE void uploadPlan(PlanMasterController* pmc, int uavId, const QString& title);

signals:
    void uavListChanged();
    void uploadingChanged();
    void uploadSucceeded(const QString& message);
    void uploadFailed(const QString& error);
    void uavListError(const QString& error);

private:
    struct WaypointData {
        double lat = 0.0;
        double lon = 0.0;
        double altitude = 0.0;
    };

    /// 通用 POST（path 含 /api 前缀），HTTP 2xx 时回调 onSuccess（body 为空/非对象也回调，
    /// 由调用方决定是否需要 JSON 对象）；非 2xx 时 onError 携带后端真实错误信息。
    void _sendJson(const QString& path, const QJsonObject& body,
                   const std::function<void(const QJsonDocument&)>& onSuccess,
                   const std::function<void(const QString&)>& onError);

    /// 通用 GET（同 _sendJson 语义）。
    void _sendGet(const QString& path,
                  const std::function<void(const QJsonDocument&)>& onSuccess,
                  const std::function<void(const QString&)>& onError);

    /// 尽力清理上传中途已建的后台资源（fire-and-forget，忽略结果）：
    ///   已建航线 → DELETE /api/routes/:id（后端级联删除其临时航点）；
    ///   否则 → 逐点 DELETE /api/waypoints/:id。
    /// 任务已建时无 DELETE 端点、且航线被任务引用（删除 409），无法清理，仅靠错误提示告知残留。
    void _cleanupPartialResources();
    void _deleteResource(const QString& path);

    // 上传状态机（串行请求，逐步推进）
    void _checkPermissions();   // 第一步：GET /api/auth/me 预检角色，缺权限立刻失败，不建任何资源
    void _uploadNextWaypoint();
    void _createRoute();
    void _createTask();
    void _submitTask();
    void _finishUpload();
    void _failUpload(const QString& error);

    QNetworkAccessManager* _networkManager = nullptr;
    QString _serverUrl;
    QString _authToken;
    bool    _uploading = false;
    bool    _fetchUavsInProgress = false;   // fetchUavs 重入守卫（QML onCompleted + onLoggedInChanged 可能并发触发）
    QVariantList _uavList;

    // 一次上传会话的状态
    QList<WaypointData> _waypoints;
    QList<int> _waypointIds;
    int _nextWaypointIndex = 0;
    QString _ts;                 // 唯一编号时间戳前缀（QGC-<ts>[-<seq>]）
    QString _routeCode;
    QString _taskNo;
    QString _routeTitle;         // 用户输入的航线标题（route_name，必填非空）
    int _uavId = 0;
    int _routeId = 0;
    int _taskId = 0;
    QString _planJson;           // QGC .plan JSON（Route.plan_data）

    static PlanUploader* s_instance;
};
