#pragma once

#include <QtCore/QPointer>
#include <QtPositioning/QGeoCoordinate>
#include <QtQmlIntegration/QtQmlIntegration>

#include "PlanElementController.h"
#include "QmlObjectListModel.h"

class GeoFenceManager;
class RallyPointManager;
class Vehicle;

class RallyPointController : public PlanElementController
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("")
public:
    explicit RallyPointController(PlanMasterController* masterController, QObject* parent = nullptr);
    ~RallyPointController();

    Q_PROPERTY(QmlObjectListModel*  points                  READ points                                             CONSTANT)
    Q_PROPERTY(QString              editorQml               READ editorQml                                          CONSTANT)
    Q_PROPERTY(QObject*             currentRallyPoint       READ currentRallyPoint      WRITE setCurrentRallyPoint  NOTIFY currentRallyPointChanged)

    Q_INVOKABLE void addPoint       (QGeoCoordinate point);
    Q_INVOKABLE void removePoint    (QObject* rallyPoint);

    void start                      (bool flyView) final;
    bool supported                  (void) const final;
    void save                       (QJsonObject& json) final;
    bool load                       (const QJsonObject& json, QString& errorString) final;
    void loadFromVehicle            (void) final;
    void sendToVehicle              (void) final;
    void removeAll                  (void) final;
    void removeAllFromVehicle       (void) final;
    bool syncInProgress             (void) const final;
    bool dirty                      (void) const final { return _dirty; }
    void setDirty                   (bool dirty) final;
    bool containsItems              (void) const final;
    bool showPlanFromManagerVehicle (void) final;

    QmlObjectListModel* points                  (void) { return &_points; }
    QString             editorQml               (void) const;
    QObject*            currentRallyPoint       (void) const { return _currentRallyPoint; }

    void setCurrentRallyPoint   (QObject* rallyPoint);
    bool isEmpty                (void) const;

signals:
    void currentRallyPointChanged(QObject* rallyPoint);
    void loadComplete(void);

private slots:
    void _managerLoadComplete       (void);
    void _managerSendComplete       (bool error);
    void _managerRemoveAllComplete  (bool error);
    void _setFirstPointCurrent      (void);
    void _managerVehicleChanged     (Vehicle* managerVehicle);

private:
    /// 代管载具 —— **永不为 nullptr**。_managerVehicle 是 QPointer：载具被
    /// MultiVehicleManager 销毁后自动置空；此时回落到离线控制载具。回落放在**读点**
    /// 而非只放在赋值点：从不调 start() 的 PlanMasterController 不转发销毁通知，
    /// 从载具死到新载具到的这段窗口里读点照样会被调到（QML 直接读 syncInProgress）。
    /// 定义在 .cc：QPointer::data() 要 static_cast 到 Vehicle*，本头文件只有前向声明。
    Vehicle* _managedVehicle(void) const;
    /// 返航点管理器 —— **永不为 nullptr**。它是代管载具的子对象，随载具一同销毁，
    /// 故**不保存**，一律经 _managedVehicle() 现取。
    RallyPointManager* _rallyPointManager(void) const;

    /// ⚠️ 本成员可空，类内一律经 _managedVehicle() / _rallyPointManager() 读。
    QPointer<Vehicle>   _managerVehicle;
    bool                _dirty =                false;
    QmlObjectListModel  _points;
    QObject*            _currentRallyPoint =    nullptr;
    bool                _itemsRequested =       false;

    static constexpr int    _jsonCurrentVersion = 2;
    static constexpr const char* _jsonFileTypeValue =  "RallyPoints";
    static constexpr const char* _jsonPointsKey =      "points";
};
