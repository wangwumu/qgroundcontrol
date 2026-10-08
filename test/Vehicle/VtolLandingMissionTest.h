#pragma once

#include "BaseClasses/VehicleTest.h"

/// 降落端统一链（设计稿 §9.8.4）的 ③④ 步：组一条两航点降落航线、上传、切 AUTO_MISSION。
///
/// ‼️ 本测试最要紧的一格是**结构**：PX4 上 `sendHomePositionToVehicle()` 返回 false
/// ⇒ `PlanManager::writeMissionItems` 会 `delete missionItems[0]` ⇒ 调用方**必须垫第一项占位**。
/// 不垫的后果是静默的：两航点被删成单航点 `VTOL_LAND`，PX4 在 `FeasibilityChecker` 里拒收，
/// 而上传层**仍回 `MISSION_ACK=0`** ⇒ 界面无痕、飞机不动（§9.5.2 / §9.5.10）。
class VtolLandingMissionTest : public VehicleTest
{
    Q_OBJECT

public:
    explicit VtolLandingMissionTest(QObject* parent = nullptr) : VehicleTest(parent) {}

private slots:
    void _missionItemsStructure();
    void _missionItemsAreIndependentCopies();
    void _startMissionUploadsAndSwitchesMode();
    void _startMissionConfirmsModeByReadback();
    void _startMissionReportsUploadFailure();
    void _startMissionRejectsInvalidCoordinates();
};
