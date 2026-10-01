#pragma once

#include "QmlUITestBase.h"

#include <QtCore/QObject>
#include <QtPositioning/QGeoCoordinate>

/// `OpsRouteSync.qml` 的 `vehicle` 输入只用到两处：`vehicle.vtol`（组装 mission 项）
/// 与 `vehicle.homePosition`（起飞项坐标）。真正的 `Vehicle*` 在本用例里**不需要** ——
/// 三道高度闸都在 `start()` / `_buildAndSend()` 里、**早于** `_plan.startStaticActiveVehicle()`
/// 那一步（那里才要求实参是 `Vehicle*`）。用一个最小替身即可把三道闸都走到。
class OpsRouteSyncFakeVehicle : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool          vtol         READ vtol         CONSTANT)
    Q_PROPERTY(QGeoCoordinate homePosition READ homePosition CONSTANT)

public:
    explicit OpsRouteSyncFakeVehicle(QObject *parent = nullptr) : QObject(parent) {}

    bool           vtol()         const { return true; }
    QGeoCoordinate homePosition() const { return QGeoCoordinate(47.3977, 8.5455, 488.0); }
};

/// `OpsRouteSync.qml` 三道高度闸（飞行 / 起飞 / 降落）的可执行判据。
///
/// 三道闸的文案是既有口径**逐字**比对，界面上有对应用户认知 —— 不要改它们。
class OpsRouteSyncUITest : public QmlUITestBase
{
    Q_OBJECT

public:
    OpsRouteSyncUITest() = default;

private slots:
    void _testGates_data();
    void _testGates();
};
