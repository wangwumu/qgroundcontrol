#include "RallyPointController.h"
#include "RallyPoint.h"
#include "Vehicle.h"
#include "GeoJsonHelper.h"
#include "JsonParsing.h"
#include "SettingsManager.h"
#include "AppSettings.h"
#include "PlanMasterController.h"
#include "RallyPointManager.h"
#include "Vehicle.h"
#include "AuthController.h"
#include "QGCLoggingCategory.h"

#include <QtCore/QJsonArray>

QGC_LOGGING_CATEGORY(RallyPointControllerLog, "PlanManager.RallyPointController")

RallyPointController::RallyPointController(PlanMasterController* masterController, QObject* parent)
    : PlanElementController (masterController, parent)
    , _managerVehicle               (masterController->managerVehicle())
{
    connect(&_points, &QmlObjectListModel::countChanged, this, &RallyPointController::containsItemsChanged);
}

RallyPointController::~RallyPointController()
{

}

void RallyPointController::start(bool flyView)
{
    qCDebug(RallyPointControllerLog) << "start flyView" << flyView;

    _managerVehicleChanged(_masterController->managerVehicle());
    connect(_masterController, &PlanMasterController::managerVehicleChanged, this, &RallyPointController::_managerVehicleChanged);

    PlanElementController::start(flyView);
}

void RallyPointController::_managerVehicleChanged(Vehicle* managerVehicle)
{
    if (_managerVehicle) {
        // 只断开还活着的那个：QPointer 非空即说明代管载具尚在，它的返航点管理器也随之
        // 尚在。载具已销毁时根本不进这里 —— QPointer 已自动置空，硬解引用就是空指针
        // 崩溃（原裸指针版本正是崩在这两行）。
        _rallyPointManager()->disconnect(this);
        _managedVehicle()->disconnect(this);
        _managerVehicle = nullptr;
    }

    // 传入 nullptr 表示"当前没有代管载具"：既可能是首次 start() 时还没有活动载具，
    // 也可能是上一架被 MultiVehicleManager 销毁后 QPointer 置空。
    // 回落到离线控制载具 —— 与 PlanMasterController::_activeVehicleChanged() 的 nullptr
    // 分支同口径。
    _managerVehicle = managerVehicle ? managerVehicle : _masterController->controllerVehicle();

    RallyPointManager* const rallyPointManager = _rallyPointManager();
    connect(rallyPointManager, &RallyPointManager::loadComplete,       this, &RallyPointController::_managerLoadComplete);
    connect(rallyPointManager, &RallyPointManager::sendComplete,       this, &RallyPointController::_managerSendComplete);
    connect(rallyPointManager, &RallyPointManager::removeAllComplete,  this, &RallyPointController::_managerRemoveAllComplete);
    connect(rallyPointManager, &RallyPointManager::inProgressChanged,  this, &RallyPointController::syncInProgressChanged);

    (void) connect(_managedVehicle(), &Vehicle::capabilityBitsChanged, this, [this](uint64_t capabilityBits) {
        Q_UNUSED(capabilityBits);
        emit supportedChanged(supported());
    });

    emit supportedChanged(supported());
}

Vehicle* RallyPointController::_managedVehicle(void) const
{
    // _managerVehicle 是 QPointer：代管载具被 MultiVehicleManager 销毁后自动置空。
    // 此时回落到离线控制载具 —— 与 PlanMasterController::_activeVehicleChanged() 的
    // nullptr 分支同口径。
    // 回落放在**读点**而非只放在赋值点：从不调 start() 的 PlanMasterController 不转发
    // 销毁通知，从载具死到新载具到的这段窗口里本函数照样会被调到
    // （supported() 读 capabilityBits 就经它）。
    return _managerVehicle ? _managerVehicle.data() : _masterController->controllerVehicle();
}

RallyPointManager* RallyPointController::_rallyPointManager(void) const
{
    // 现取而不缓存：返航点管理器的宿主就是代管载具，随它一同销毁。
    // 缓存一份就多一个会悬垂的空位，而现取天然满足"永不为空"。
    return _managedVehicle()->rallyPointManager();
}

bool RallyPointController::load(const QJsonObject& json, QString& errorString)
{
    removeAll();

    errorString.clear();

    if (json.contains(JsonParsing::jsonVersionKey) && json[JsonParsing::jsonVersionKey].toInt() == 1) {
        // We just ignore old version 1 data
        return true;
    }

    QList<JsonParsing::KeyValidateInfo> keyInfoList = {
        { JsonParsing::jsonVersionKey,   QJsonValue::Double, true },
        { _jsonPointsKey,               QJsonValue::Array,  true },
    };
    if (!JsonParsing::validateKeys(json, keyInfoList, errorString)) {
        return false;
    }

    QString errorStr;
    QString errorMessage = tr("Rally: %1");

    if (json[JsonParsing::jsonVersionKey].toInt() != _jsonCurrentVersion) {
        errorString = tr("Rally Points supports version %1").arg(_jsonCurrentVersion);
        return false;
    }

    QList<QGeoCoordinate> rgPoints;
    if (!GeoJsonHelper::loadGeoCoordinateArray(json[_jsonPointsKey], true /* altitudeRequired */, rgPoints, errorStr)) {
        errorString = errorMessage.arg(errorStr);
        return false;
    }

    QObjectList pointList;
    for (int i=0; i<rgPoints.count(); i++) {
        pointList.append(new RallyPoint(rgPoints[i], this));
    }
    _points.swapObjectList(pointList);

    setDirty(false);
    _setFirstPointCurrent();

    return true;
}

void RallyPointController::save(QJsonObject& json)
{
    json[JsonParsing::jsonVersionKey] = _jsonCurrentVersion;

    QJsonArray rgPoints;
    QJsonValue jsonPoint;
    for (int i=0; i<_points.count(); i++) {
        GeoJsonHelper::saveGeoCoordinate(qobject_cast<RallyPoint*>(_points[i])->coordinate(), true /* writeAltitude */, jsonPoint);
        rgPoints.append(jsonPoint);
    }
    json[_jsonPointsKey] = QJsonValue(rgPoints);
}

void RallyPointController::removeAll(void)
{
    _points.clearAndDeleteContents();
    setDirty(true);
    setCurrentRallyPoint(nullptr);
}

void RallyPointController::removeAllFromVehicle(void)
{
    if (_masterController->offline()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::removeAllFromVehicle called while offline";
    } else if (syncInProgress()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::removeAllFromVehicle called while syncInProgress";
    } else {
        _rallyPointManager()->removeAll();
    }
}

void RallyPointController::loadFromVehicle(void)
{
    if (_masterController->offline()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::loadFromVehicle called while offline";
    } else if (syncInProgress()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::loadFromVehicle called while syncInProgress";
    } else {
        _itemsRequested = true;
        _rallyPointManager()->loadFromVehicle();
    }
}

void RallyPointController::sendToVehicle(void)
{
    if (_masterController->offline()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::sendToVehicle called while offline";
    } else if (syncInProgress()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::sendToVehicle called while syncInProgress";
    } else {
        qCDebug(RallyPointControllerLog) << "RallyPointController::sendToVehicle";
        setDirty(false);
        QList<QGeoCoordinate> rgPoints;
        for (int i=0; i<_points.count(); i++) {
            rgPoints.append(qobject_cast<RallyPoint*>(_points[i])->coordinate());
        }
        _rallyPointManager()->sendToVehicle(rgPoints);
    }
}

bool RallyPointController::syncInProgress(void) const
{
    return _rallyPointManager()->inProgress();
}

void RallyPointController::setDirty(bool dirty)
{
    if (dirty != _dirty) {
        _dirty = dirty;
        emit dirtyChanged(dirty);
    }
}

QString RallyPointController::editorQml(void) const
{
    return _rallyPointManager()->editorQml();
}

void RallyPointController::_managerLoadComplete(void)
{
    // Fly view always reloads on _loadComplete
    // Plan view only reloads if:
    //  - Load was specifically requested
    //  - There is no current Plan
    // 已登录后台系统：同 MissionController —— 显式请求照常，载具自行发起的自动装载不再装入。
    if (!_itemsRequested && AuthController::backendLoggedIn()) {
        qCDebug(RallyPointControllerLog) << "_managerLoadComplete: backend logged in, skipping auto plan load";
        _itemsRequested = false;
        return;
    }

    if (_flyView || _itemsRequested || isEmpty()) {
        _points.clearAndDeleteContents();
        QObjectList pointList;
        for (int i=0; i<_rallyPointManager()->points().count(); i++) {
            pointList.append(new RallyPoint(_rallyPointManager()->points()[i], this));
        }
        _points.swapObjectList(pointList);
        setDirty(false);
        _setFirstPointCurrent();
        emit loadComplete();
    }
    _itemsRequested = false;
}

void RallyPointController::_managerSendComplete(bool error)
{
    // Fly view always reloads after send
    if (!error && _flyView) {
        showPlanFromManagerVehicle();
    }
}

void RallyPointController::_managerRemoveAllComplete(bool error)
{
    if (!error) {
        // Remove all from vehicle so we always update
        showPlanFromManagerVehicle();
    }
}

void RallyPointController::addPoint(QGeoCoordinate point)
{
    double defaultAlt;
    if (_points.count()) {
        defaultAlt = qobject_cast<RallyPoint*>(_points[_points.count() - 1])->coordinate().altitude();
    } else {
        if(_masterController->controllerVehicle()->fixedWing()) {
            defaultAlt = SettingsManager::instance()->appSettings()->defaultMissionItemAltitude()->rawValue().toDouble();
        }
        else {
            defaultAlt = RallyPoint::getDefaultFactAltitude();
        }
    }
    point.setAltitude(defaultAlt);
    RallyPoint* newPoint = new RallyPoint(point, this);
    _points.append(newPoint);
    setCurrentRallyPoint(newPoint);
    setDirty(true);
}

bool RallyPointController::supported(void) const
{
    return _managedVehicle()->capabilityBits() & MAV_PROTOCOL_CAPABILITY_MISSION_RALLY;
}

void RallyPointController::removePoint(QObject* rallyPoint)
{
    int foundIndex = 0;
    for (foundIndex=0; foundIndex<_points.count(); foundIndex++) {
        if (_points[foundIndex] == rallyPoint) {
            _points.removeOne(rallyPoint);
            rallyPoint->deleteLater();
        }
    }

    if (_points.count()) {
        int newIndex = qMin(foundIndex, _points.count() - 1);
        newIndex = qMax(newIndex, 0);
        setCurrentRallyPoint(_points[newIndex]);
    } else {
        setCurrentRallyPoint(nullptr);
    }
}

void RallyPointController::setCurrentRallyPoint(QObject* rallyPoint)
{
    if (_currentRallyPoint != rallyPoint) {
        _currentRallyPoint = rallyPoint;
        emit currentRallyPointChanged(rallyPoint);
    }
}

void RallyPointController::_setFirstPointCurrent(void)
{
    setCurrentRallyPoint(_points.count() ? _points[0] : nullptr);
}

bool RallyPointController::containsItems(void) const
{
    return _points.count() > 0;
}

bool RallyPointController::showPlanFromManagerVehicle (void)
{
    qCDebug(RallyPointControllerLog) << "showPlanFromManagerVehicle _flyView" << _flyView;
    if (_masterController->offline()) {
        qCCritical(RallyPointControllerLog) << "RallyPointController::showPlanFromManagerVehicle called while offline";
        return true;    // stops further propagation of showPlanFromManagerVehicle due to error
    } else {
        // 用户显式动作（PlanView.qml:830 按钮 → PlanMasterController::_showPlanFromManagerVehicle → 此处）。
        // 必须在下面两个早返回**之前**置位：否则载具初始加载未完成时提前返回，_itemsRequested 停在
        // false，等 _loadComplete 信号到达时本文 :200 的登录闸会把它当成"载具自动装载"拦掉——按钮点了没反应。
        // GeoFenceController::showPlanFromManagerVehicle 同形（其 :372），三处必须一致。
        _itemsRequested = true;
        if (!_managedVehicle()->initialPlanRequestComplete()) {
            // The vehicle hasn't completed initial load, we can just wait for loadComplete to be signalled automatically
            qCDebug(RallyPointControllerLog) << "showPlanFromManagerVehicle: !initialPlanRequestComplete, wait for signal";
            return true;
        } else if (syncInProgress()) {
            // If the sync is already in progress, _loadComplete will be called automatically when it is done. So no need to do anything.
            qCDebug(RallyPointControllerLog) << "showPlanFromManagerVehicle: syncInProgress wait for signal";
            return true;
        } else {
            qCDebug(RallyPointControllerLog) << "showPlanFromManagerVehicle: sync complete";
            _itemsRequested = true;
            _managerLoadComplete();
            return false;
        }
    }
}

bool RallyPointController::isEmpty(void) const
{
    return _points.count() == 0;
}
