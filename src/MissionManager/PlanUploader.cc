#include "PlanUploader.h"

#include <QtCore/QDateTime>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLoggingCategory>
#include <QtCore/QSet>
#include <QtCore/QVariantMap>
#include <QtNetwork/QNetworkReply>

#include "MissionController.h"
#include "PlanMasterController.h"
#include "QGCLoggingCategory.h"
#include "QmlObjectListModel.h"
#include "Utilities/Network/QGCNetworkHelper.h"
#include "VisualMissionItem.h"

QGC_LOGGING_CATEGORY(PlanUploaderLog, "Mission.PlanUploader")

PlanUploader* PlanUploader::s_instance = nullptr;

PlanUploader::PlanUploader(QObject* parent)
    : QObject(parent)
    , _networkManager(QGCNetworkHelper::createNetworkManager(this))
{
    if (s_instance == nullptr) {
        s_instance = this;
    }
}

PlanUploader::~PlanUploader()
{
    if (s_instance == this) {
        s_instance = nullptr;
    }
}

PlanUploader* PlanUploader::instance()
{
    // 首次调用即创建（与 AuthController 不同：PlanUploader 先由 C++ 注入 serverUrl/
    // token 再被 QML 使用，故由 C++ 侧触发构造，QML 通过上下文属性拿到同一实例）
    if (s_instance == nullptr) {
        s_instance = new PlanUploader();
    }
    return s_instance;
}

void PlanUploader::setServerUrl(const QString& url)
{
    // 归一化：去首尾空白 + 剥尾斜杠，避免拼接出 //api/...（_sendJson/fetchUavs 的单一事实源）
    _serverUrl = url.trimmed();
    while (_serverUrl.endsWith(QLatin1Char('/'))) {
        _serverUrl.chop(1);
    }
}

void PlanUploader::setAuthToken(const QString& token)
{
    _authToken = token;
}

void PlanUploader::_sendJson(const QString& path, const QJsonObject& body,
                             const std::function<void(const QJsonDocument&)>& onSuccess,
                             const std::function<void(const QString&)>& onError)
{
    const QString url = QStringLiteral("%1%2").arg(_serverUrl, path);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    QGCNetworkHelper::setJsonHeaders(request);
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    QNetworkReply* reply = _networkManager->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    if (reply == nullptr) {
        if (onError) {
            onError(QStringLiteral("无法发起请求"));
        }
        return;
    }

    connect(reply, &QNetworkReply::finished, this, [reply, path, onSuccess, onError]() {
        if (!QGCNetworkHelper::isSuccess(reply)) {
            if (onError) {
                // 透传后端真实错误（如 400 {"message":"航点编码已存在"}），回退到 HTTP 状态码短语
                QString detail = QGCNetworkHelper::errorMessage(reply);
                const QByteArray responseBody = reply->readAll();
                if (!responseBody.isEmpty()) {
                    const QJsonDocument errDoc = QJsonDocument::fromJson(responseBody);
                    if (errDoc.isObject()) {
                        const QJsonObject o = errDoc.object();
                        for (const QString& key : {QStringLiteral("message"), QStringLiteral("error"), QStringLiteral("detail")}) {
                            const QString msg = o.value(key).toString();
                            if (!msg.isEmpty()) {
                                detail = msg;
                                break;
                            }
                        }
                    }
                }
                onError(detail);
            }
        } else {
            // 2xx 一律回调 onSuccess，body 为空/非对象也传（doc 可能为 null），
            // 由调用方决定是否需要对象——submit 等 action 接口可能 204/空 body。
            const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
            if (doc.isNull() || !doc.isObject()) {
                qCWarning(PlanUploaderLog) << "2xx response without JSON object:" << path;
            }
            if (onSuccess) {
                onSuccess(doc);
            }
        }
        reply->deleteLater();
    });
}

void PlanUploader::_sendGet(const QString& path,
                            const std::function<void(const QJsonDocument&)>& onSuccess,
                            const std::function<void(const QString&)>& onError)
{
    const QString url = QStringLiteral("%1%2").arg(_serverUrl, path);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    QGCNetworkHelper::setJsonHeaders(request);
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    QNetworkReply* reply = _networkManager->get(request);
    if (reply == nullptr) {
        if (onError) {
            onError(QStringLiteral("无法发起请求"));
        }
        return;
    }

    connect(reply, &QNetworkReply::finished, this, [reply, path, onSuccess, onError]() {
        if (!QGCNetworkHelper::isSuccess(reply)) {
            if (onError) {
                // 透传后端真实错误（同 _sendJson）
                QString detail = QGCNetworkHelper::errorMessage(reply);
                const QByteArray responseBody = reply->readAll();
                if (!responseBody.isEmpty()) {
                    const QJsonDocument errDoc = QJsonDocument::fromJson(responseBody);
                    if (errDoc.isObject()) {
                        const QJsonObject o = errDoc.object();
                        for (const QString& key : {QStringLiteral("message"), QStringLiteral("error"), QStringLiteral("detail")}) {
                            const QString msg = o.value(key).toString();
                            if (!msg.isEmpty()) {
                                detail = msg;
                                break;
                            }
                        }
                    }
                }
                onError(detail);
            }
        } else if (onSuccess) {
            const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
            onSuccess(doc);
        }
        reply->deleteLater();
    });
}

void PlanUploader::fetchUavs()
{
    if (!isConfigured()) {
        qCWarning(PlanUploaderLog) << "fetchUavs: gcs_server not configured";
        emit uavListError(QStringLiteral("后台地址未配置，无法拉取无人机列表"));
        return;
    }
    if (_fetchUavsInProgress) {
        return;   // 重入守卫：QML onCompleted 与 onLoggedInChanged 可能连发，只保留在途的一次
    }

    // GET /api/uavs（响应为 UAV 数组：id/uav_no/device_id/status/model）
    const QString url = QStringLiteral("%1/api/uavs").arg(_serverUrl);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    QNetworkReply* reply = _networkManager->get(request);
    if (reply == nullptr) {
        qCWarning(PlanUploaderLog) << "fetchUavs: get returned nullptr";
        emit uavListError(QStringLiteral("无法发起无人机列表请求"));
        return;
    }
    _fetchUavsInProgress = true;

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        _fetchUavsInProgress = false;
        if (QGCNetworkHelper::isSuccess(reply)) {
            const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
            QVariantList uavList;
            if (doc.isArray()) {
                for (const QJsonValue& value : doc.array()) {
                    const QJsonObject obj = value.toObject();
                    QVariantMap map;
                    map.insert(QStringLiteral("id"), obj.value(QStringLiteral("id")).toVariant());
                    map.insert(QStringLiteral("uav_no"), obj.value(QStringLiteral("uav_no")).toVariant());
                    map.insert(QStringLiteral("device_id"), obj.value(QStringLiteral("device_id")).toVariant());
                    map.insert(QStringLiteral("status"), obj.value(QStringLiteral("status")).toVariant());
                    map.insert(QStringLiteral("model"), obj.value(QStringLiteral("model")).toVariant());
                    uavList.append(map);
                }
            } else {
                qCWarning(PlanUploaderLog) << "fetchUavs: 200 but non-array body:" << reply->readAll();
                emit uavListError(QStringLiteral("无人机列表响应格式异常（期望数组）"));
            }
            _uavList = uavList;
            emit uavListChanged();
        } else {
            const QString error = QGCNetworkHelper::errorMessage(reply);
            qCWarning(PlanUploaderLog) << "fetchUavs failed:" << error;
            emit uavListError(QStringLiteral("拉取无人机列表失败：%1").arg(error));
        }
        reply->deleteLater();
    });
}

void PlanUploader::uploadPlan(PlanMasterController* pmc, int uavId, const QString& title)
{
    if (_uploading) {
        emit uploadFailed(QStringLiteral("上一次上传尚未完成"));
        return;
    }
    if (!isConfigured()) {
        emit uploadFailed(QStringLiteral("后台地址未配置"));
        return;
    }
    if (_authToken.isEmpty()) {
        emit uploadFailed(QStringLiteral("未登录或会话已失效，请重新登录"));
        return;
    }
    // 航线标题必填：多条临时航线靠它区分
    const QString trimmedTitle = title.trimmed();
    if (trimmedTitle.isEmpty()) {
        emit uploadFailed(QStringLiteral("航线标题不能为空"));
        return;
    }
    if (uavId <= 0) {
        emit uploadFailed(QStringLiteral("请先选择无人机"));
        return;
    }

    // QML 参数为 PlanMasterController*（QML_ELEMENT），此处仅作防御性空校验
    PlanMasterController* const plan = pmc;
    if (plan == nullptr) {
        emit uploadFailed(QStringLiteral("计划控制器无效"));
        return;
    }

    // 提取航点：跳过 home 位置与无坐标项；高度取 amslEntryAlt（coordinate 不含高度）
    _waypoints.clear();
    MissionController* const mission = plan->missionController();
    QmlObjectListModel* const items = mission->visualItems();
    for (int i = 0; i < items->count(); ++i) {
        VisualMissionItem* const vmi = qobject_cast<VisualMissionItem*>(items->get(i));
        if (vmi == nullptr || vmi->homePosition() || !vmi->specifiesCoordinate()) {
            continue;
        }
        const QGeoCoordinate coord = vmi->coordinate();
        if (!coord.isValid()) {
            continue;
        }
        WaypointData w;
        w.lat = coord.latitude();
        w.lon = coord.longitude();
        w.altitude = vmi->amslEntryAlt();
        _waypoints.append(w);
    }
    if (_waypoints.isEmpty()) {
        emit uploadFailed(QStringLiteral("计划中没有有效航点"));
        return;
    }

    // 本次会话状态初始化
    _ts = QString::number(QDateTime::currentMSecsSinceEpoch());
    _routeCode = QStringLiteral("QGC-%1").arg(_ts);
    _taskNo = _routeCode;
    _routeTitle = trimmedTitle;
    _planJson = QString::fromUtf8(plan->saveToJson().toJson(QJsonDocument::Compact));
    _uavId = uavId;
    _waypointIds.clear();
    _nextWaypointIndex = 0;
    _routeId = 0;
    _taskId = 0;

    _uploading = true;
    emit uploadingChanged();
    // 先预检角色权限：缺任何所需角色立即失败（_checkPermissions 内 _failUpload），
    // 此时尚未创建任何航点/航线/任务，不留孤儿资源。
    _checkPermissions();
}

// 上传第一步：预检当前用户是否具备全流程所需角色，缺任一立即失败、不建任何资源。
// 所需角色（与后端 router.go RequireRoles 一致）：
//   建航点/建航线：SITE_ATC 或 OP_OPERATOR；建飞行任务：SITE_MANAGER。
// 角色来自 GET /api/auth/me（JWT claims，与后端鉴权判定同源）。
void PlanUploader::_checkPermissions()
{
    _sendGet(QStringLiteral("/api/auth/me"),
             [this](const QJsonDocument& doc) {
                 const QJsonObject obj = doc.object();
                 const QJsonArray roles = obj.value(QStringLiteral("roles")).toArray();
                 QSet<QString> roleSet;
                 for (const QJsonValue& v : roles) {
                     roleSet.insert(v.toString());
                 }
                 const bool canCreateWaypointRoute = roleSet.contains(QStringLiteral("SITE_ATC"))
                                                     || roleSet.contains(QStringLiteral("OP_OPERATOR"));
                 const bool canCreateTask = roleSet.contains(QStringLiteral("SITE_MANAGER"));
                 if (!canCreateWaypointRoute || !canCreateTask) {
                     QStringList missing;
                     if (!canCreateWaypointRoute) {
                         missing << QStringLiteral("SITE_ATC / OP_OPERATOR（建临时航点、临时航线）");
                     }
                     if (!canCreateTask) {
                         missing << QStringLiteral("SITE_MANAGER（建飞行任务）");
                     }
                     // 未创建任何资源，直接失败
                     _failUpload(QStringLiteral("当前用户缺少角色：%1，无法上传，未创建任何资源")
                                     .arg(missing.join(QStringLiteral("、"))));
                     return;
                 }
                 _uploadNextWaypoint();
             },
             [this](const QString& error) {
                 _failUpload(QStringLiteral("上传前角色校验失败：%1").arg(error));
             });
}

void PlanUploader::_uploadNextWaypoint()
{
    if (_nextWaypointIndex >= _waypoints.size()) {
        _createRoute();
        return;
    }

    const WaypointData& w = _waypoints.at(_nextWaypointIndex);
    const QString seq = QString::number(_nextWaypointIndex);

    QJsonObject body;
    body[QStringLiteral("name")] = QStringLiteral("%1-%2").arg(_routeCode, seq);
    body[QStringLiteral("code")] = QStringLiteral("%1-%2").arg(_routeCode, seq);
    body[QStringLiteral("command")] = 16;   // MAV_CMD_NAV_WAYPOINT（临时航线航点即坐标点）
    body[QStringLiteral("lat")] = w.lat;
    body[QStringLiteral("lon")] = w.lon;
    body[QStringLiteral("altitude")] = w.altitude;
    body[QStringLiteral("is_temporary")] = true;

    _sendJson(QStringLiteral("/api/waypoints"), body,
              [this](const QJsonDocument& doc) {
                  // toVariant().toInt()：兼容后端把 id 序列化为数字字符串的情况
                  const int id = doc.object().value(QStringLiteral("id")).toVariant().toInt();
                  if (id <= 0) {
                      _failUpload(QStringLiteral("建航点响应缺少 id"));
                      return;
                  }
                  _waypointIds.append(id);
                  ++_nextWaypointIndex;
                  _uploadNextWaypoint();
              },
              [this](const QString& error) {
                  _failUpload(QStringLiteral("建航点失败：%1").arg(error));
              });
}

void PlanUploader::_createRoute()
{
    if (_waypointIds.isEmpty()) {
        _failUpload(QStringLiteral("未建立任何航点"));
        return;
    }

    QJsonArray wpIds;
    for (int id : _waypointIds) {
        wpIds.append(id);
    }

    QJsonObject body;
    body[QStringLiteral("route_code")] = _routeCode;   // 唯一编号（route_code 全局唯一约束）
    body[QStringLiteral("route_name")] = _routeTitle;  // 用户输入的航线标题，便于区分
    body[QStringLiteral("category")] = QStringLiteral("TEMPORARY");
    body[QStringLiteral("start_waypoint_id")] = _waypointIds.first();  // 起飞点
    body[QStringLiteral("end_waypoint_id")] = _waypointIds.last();     // 终点
    body[QStringLiteral("waypoint_ids")] = wpIds;                      // 全部点（含起止站）都放进来，后端据此算 waypoint_count=len=n 更准
    body[QStringLiteral("plan_data")] = _planJson;                     // QGC .plan JSON

    _sendJson(QStringLiteral("/api/routes"), body,
              [this](const QJsonDocument& doc) {
                  const int id = doc.object().value(QStringLiteral("id")).toVariant().toInt();
                  if (id <= 0) {
                      _failUpload(QStringLiteral("建航线响应缺少 id"));
                      return;
                  }
                  _routeId = id;
                  _createTask();
              },
              [this](const QString& error) {
                  _failUpload(QStringLiteral("建航线失败：%1").arg(error));
              });
}

void PlanUploader::_createTask()
{
    QJsonObject body;
    body[QStringLiteral("task_no")] = _taskNo;
    body[QStringLiteral("route_id")] = _routeId;
    body[QStringLiteral("uav_id")] = _uavId;

    _sendJson(QStringLiteral("/api/tasks"), body,
              [this](const QJsonDocument& doc) {
                  const int id = doc.object().value(QStringLiteral("id")).toVariant().toInt();
                  if (id <= 0) {
                      _failUpload(QStringLiteral("建任务响应缺少 id"));
                      return;
                  }
                  _taskId = id;
                  _submitTask();
              },
              [this](const QString& error) {
                  _failUpload(QStringLiteral("建任务失败：%1").arg(error));
              });
}

void PlanUploader::_submitTask()
{
    // DRAFT → PENDING_REVIEW：进入等待批准队列
    _sendJson(QStringLiteral("/api/tasks/%1/submit").arg(_taskId), {},
              [this](const QJsonDocument&) { _finishUpload(); },
              [this](const QString& error) {
                  _failUpload(QStringLiteral("提交审核失败：%1").arg(error));
              });
}

void PlanUploader::_finishUpload()
{
    _uploading = false;
    emit uploadingChanged();
    qCInfo(PlanUploaderLog) << "plan uploaded:" << _routeTitle << _routeCode << "task" << _taskNo;
    emit uploadSucceeded(QStringLiteral("临时航线「%1」（%2）与飞行任务 %3 已提交，等待平台批准")
                             .arg(_routeTitle, _routeCode, _taskNo));
}

void PlanUploader::_failUpload(const QString& error)
{
    _uploading = false;
    emit uploadingChanged();

    // 提示已建资源范围（后端不自动回收孤儿临时航点/航线）
    QString detail = error;
    if (!_waypointIds.isEmpty() || _routeId > 0 || _taskId > 0) {
        QStringList created;
        if (!_waypointIds.isEmpty()) {
            created << QStringLiteral("%1 个临时航点").arg(_waypointIds.size());
        }
        if (_routeId > 0) {
            created << QStringLiteral("临时航线");
        }
        if (_taskId > 0) {
            created << QStringLiteral("飞行任务");
        }
        // 清理语义如实说明：任务已建时无 DELETE 接口、航线被引用（409），无法清理；
        // 否则已发起 best-effort 删除（fire-and-forget，结果未知，勿宣称"已清理成功"）。
        const QString cleanNote = _taskId > 0
                ? QStringLiteral("任务无删除接口，无法自动清理")
                : QStringLiteral("已发起自动清理本次残留");
        detail += QStringLiteral("（已创建 %1；%2。重试会重新创建）").arg(created.join(QStringLiteral("、")), cleanNote);
        _cleanupPartialResources();
    }

    qCWarning(PlanUploaderLog) << "upload failed:" << detail;
    emit uploadFailed(detail);
}

void PlanUploader::_cleanupPartialResources()
{
    // 任务已建时无 DELETE 端点、且删除航线会因「被任务引用」返回 409，无法清理，仅靠错误提示。
    if (_taskId > 0) {
        return;
    }
    if (_routeId > 0) {
        // 删除航线 → 后端级联删除该航线的临时航点
        _deleteResource(QStringLiteral("/api/routes/%1").arg(_routeId));
        return;
    }
    for (int id : _waypointIds) {
        _deleteResource(QStringLiteral("/api/waypoints/%1").arg(id));
    }
}

void PlanUploader::_deleteResource(const QString& path)
{
    const QString url = QStringLiteral("%1%2").arg(_serverUrl, path);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    QGCNetworkHelper::setJsonHeaders(request);
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    // fire-and-forget：尽力清理，不关心结果，仅确保 reply 释放
    QNetworkReply* reply = _networkManager->deleteResource(request);
    if (reply != nullptr) {
        connect(reply, &QNetworkReply::finished, reply, &QObject::deleteLater);
    }
}
