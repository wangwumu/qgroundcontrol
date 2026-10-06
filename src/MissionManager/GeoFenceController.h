#pragma once

#include <QtCore/QPointer>
#include <QtPositioning/QGeoCoordinate>
#include <QtQmlIntegration/QtQmlIntegration>

#include "PlanElementController.h"
#include "QmlObjectListModel.h"
#include "Fact.h"

class GeoFenceManager;
class QGCFenceCircle;
class QGCFencePolygon;
class Vehicle;

class GeoFenceController : public PlanElementController
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("")
    Q_MOC_INCLUDE("QGCFencePolygon.h")
    Q_MOC_INCLUDE("QGCFenceCircle.h")

public:
    GeoFenceController(PlanMasterController* masterController, QObject* parent = nullptr);
    ~GeoFenceController();

    Q_PROPERTY(QmlObjectListModel*  polygons                READ polygons                                           CONSTANT)
    Q_PROPERTY(QmlObjectListModel*  circles                 READ circles                                            CONSTANT)
    Q_PROPERTY(QGeoCoordinate       breachReturnPoint       READ breachReturnPoint      WRITE setBreachReturnPoint  NOTIFY breachReturnPointChanged)
    Q_PROPERTY(Fact*                breachReturnAltitude    READ breachReturnAltitude                               CONSTANT)

    // Radius of the "paramCircularFence" which is called the "Geofence Failsafe" in PX4 and the "Circular Geofence" on ArduPilot
    Q_PROPERTY(double               paramCircularFence      READ paramCircularFence                                 NOTIFY paramCircularFenceChanged)

    /// Add a new inclusion polygon to the fence
    ///     @param topLeft: Top left coordinate or map viewport
    ///     @param bottomRight: Bottom right left coordinate or map viewport
    Q_INVOKABLE void addInclusionPolygon(QGeoCoordinate topLeft, QGeoCoordinate bottomRight);

    /// Add a new inclusion circle to the fence
    ///     @param topLeft: Top left coordinate or map viewport
    ///     @param bottomRight: Bottom right left coordinate or map viewport
    Q_INVOKABLE void addInclusionCircle(QGeoCoordinate topLeft, QGeoCoordinate bottomRight);

    /// Deletes the specified polygon from the polygon list
    ///     @param index: Index of polygon to delete
    Q_INVOKABLE void deletePolygon(int index);

    /// Deletes the specified circle from the circle list
    ///     @param index: Index of circle to delete
    Q_INVOKABLE void deleteCircle(int index);

    /// Clears the interactive bit from all fence items
    Q_INVOKABLE void clearAllInteractive(void);

    double  paramCircularFence  (void);
    Fact*   breachReturnAltitude(void) { return &_breachReturnAltitudeFact; }

    // Overrides from PlanElementController
    bool supported                  (void) const final;
    void start                      (bool flyView) final;
    void save                       (QJsonObject& json) final;
    bool load                       (const QJsonObject& json, QString& errorString) final;
    void loadFromVehicle            (void) final;
    void sendToVehicle              (void) final;
    void removeAll                  (void) final;
    void removeAllFromVehicle       (void) final;
    bool syncInProgress             (void) const final;
    bool dirty                      (void) const final;
    void setDirty                   (bool dirty) final;
    bool containsItems              (void) const final;
    bool showPlanFromManagerVehicle (void) final;

    QmlObjectListModel* polygons                (void) { return &_polygons; }
    QmlObjectListModel* circles                 (void) { return &_circles; }
    QGeoCoordinate      breachReturnPoint       (void) const { return _breachReturnPoint; }

    void setBreachReturnPoint   (const QGeoCoordinate& breachReturnPoint);
    bool isEmpty                (void) const;

signals:
    void breachReturnPointChanged       (QGeoCoordinate breachReturnPoint);
    void editorQmlChanged               (QString editorQml);
    void loadComplete                   (void);
    void paramCircularFenceChanged      (void);

private slots:
    void _polygonDirtyChanged       (bool dirty);
    void _setDirty                  (void);
    void _setFenceFromManager       (const QList<QGCFencePolygon>& polygons, const QList<QGCFenceCircle>&  circles);
    void _setReturnPointFromManager (QGeoCoordinate breachReturnPoint);
    void _managerLoadComplete       (void);
    void _managerSendComplete       (bool error);
    void _managerRemoveAllComplete  (bool error);
    void _parametersReady           (void);
    void _managerVehicleChanged      (Vehicle* managerVehicle);

private:
    void _init(void);

    /// 代管载具 —— **永不为 nullptr**。_managerVehicle 是 QPointer：载具被
    /// MultiVehicleManager 销毁后自动置空；此时回落到离线控制载具。回落放在**读点**
    /// 而非只放在赋值点：从不调 start() 的 PlanMasterController 不转发销毁通知，
    /// 从载具死到新载具到的这段窗口里读点照样会被调到（QML 直接读 syncInProgress）。
    /// 定义在 .cc：QPointer::data() 要 static_cast 到 Vehicle*，本头文件只有前向声明。
    Vehicle* _managedVehicle(void) const;
    /// 围栏管理器 —— **永不为 nullptr**。它是代管载具的子对象，随载具一同销毁，
    /// 故**不保存**，一律经 _managedVehicle() 现取。
    GeoFenceManager* _geoFenceManager(void) const;

    /// ⚠️ 本成员可空，类内一律经 _managedVehicle() / _geoFenceManager() 读。
    QPointer<Vehicle>   _managerVehicle;
    bool                _dirty =                        false;
    QmlObjectListModel  _polygons;
    QmlObjectListModel  _circles;
    QGeoCoordinate      _breachReturnPoint;
    Fact                _breachReturnAltitudeFact;
    double              _breachReturnDefaultAltitude =  qQNaN();
    bool                _itemsRequested =               false;

    /// QPointer: 这 4 个 Fact 都属于**载具的参数管理器**，随载具一同销毁。
    /// 用裸指针则在载具消失后会留下悬垂，而 _parametersReady() 开头的
    /// `if (fact) { fact->disconnect(this); }` 正是踩在这上面 —— disconnect 是虚函数调用，
    /// 对象已死就是空指针/野指针崩溃。
    QPointer<Fact>      _px4ParamCircularFenceFact;
    QPointer<Fact>      _apmParamCircularFenceRadiusFact;
    QPointer<Fact>      _apmParamCircularFenceEnabledFact;
    QPointer<Fact>      _apmParamCircularFenceTypeFact;

    static QMap<QString, FactMetaData*> _metaDataMap;

    static constexpr int _jsonCurrentVersion = 2;

    static constexpr const char* _jsonFileTypeValue =        "GeoFence";
    static constexpr const char* _jsonBreachReturnKey =      "breachReturn";
    static constexpr const char* _jsonPolygonsKey =          "polygons";
    static constexpr const char* _jsonCirclesKey =           "circles";

    static constexpr const char* _breachReturnAltitudeFactName = "Altitude";

    static constexpr const char* _px4ParamCircularFence =    "GF_MAX_HOR_DIST";
    static constexpr const char* _apmParamCircularFenceRadius =    "FENCE_RADIUS";
    static constexpr const char* _apmParamCircularFenceEnabled =    "FENCE_ENABLE";
    static constexpr const char* _apmParamCircularFenceType =    "FENCE_TYPE";
};
