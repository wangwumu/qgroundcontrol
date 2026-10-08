#include "VtolLandingMissionTest.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QRegularExpression>
#include <QtPositioning/QGeoCoordinate>
#include <QtTest/QSignalSpy>

#include "FirmwarePlugin.h"
#include "MissionItem.h"
#include "MockLink.h"
#include "MockLinkMissionItemHandler.h"   // 上传失败注入（`setMissionItemFailureMode`）
#include "Vehicle.h"

namespace {
// 苏黎世附近的任意合法坐标；机位在进近点以东约 100 m。
constexpr double kApproachLat = 47.3977419;
constexpr double kApproachLon = 8.5455938;
constexpr double kSlotLat     = 47.3977419;
constexpr double kSlotLon     = 8.5469000;
constexpr double kAltRel      = 60.0;
}

/// 组出来的航线必须是 `[占位, WAYPOINT@进近点, VTOL_LAND@机位]` 三项。
///
/// ‼️ 断言的**不是**"三项看起来对"，而是那条决定性约定的每一环：
///    第 0 项存在且是普通航点（占位，PX4 路径上必被删）；第 1 项是普通航点
///    （删掉占位后它成为首项，**不能是降落航点**，否则被 `navigator_mis_starts_w_landing2` 拒）；
///    第 2 项才是 `VTOL_LAND` 且落在机位坐标上。
void VtolLandingMissionTest::_missionItemsStructure()
{
    const QList<MissionItem*> items =
        Vehicle::createVtolLandingMissionItems(kApproachLat, kApproachLon, kSlotLat, kSlotLon, kAltRel);

    QCOMPARE(items.count(), 3);

    QCOMPARE(items[0]->sequenceNumber(), 0);
    QCOMPARE(items[0]->command(), MAV_CMD_NAV_WAYPOINT);

    QCOMPARE(items[1]->sequenceNumber(), 1);
    QCOMPARE(items[1]->command(), MAV_CMD_NAV_WAYPOINT);
    QVERIFY(qAbs(items[1]->coordinate().latitude() - kApproachLat) < 1e-6);
    QVERIFY(qAbs(items[1]->coordinate().longitude() - kApproachLon) < 1e-6);

    QCOMPARE(items[2]->sequenceNumber(), 2);
    QCOMPARE(items[2]->command(), MAV_CMD_NAV_VTOL_LAND);
    QVERIFY(qAbs(items[2]->coordinate().latitude() - kSlotLat) < 1e-6);
    QVERIFY(qAbs(items[2]->coordinate().longitude() - kSlotLon) < 1e-6);

    for (MissionItem* item : items) {
        // 相对高度帧：高度取自调用那一刻的 `altitudeRelative()`（相对 home，米）。
        QCOMPARE(item->frame(), MAV_FRAME_GLOBAL_RELATIVE_ALT);
        QVERIFY(qAbs(item->param7() - kAltRel) < 1e-6);
        // param1..3 是 hold / acceptance radius / pass radius —— 全取默认 0（同既有
        // `VTOLLandingComplexItem::_createLandItem` 的守法）。
        QCOMPARE(item->param1(), 0.0);
        QCOMPARE(item->param2(), 0.0);
        QCOMPARE(item->param3(), 0.0);
        // param4 是 yaw：降落端**不控朝向**（§9.5.9 第 1、2 条）⇒ 不指定。
        QVERIFY(qIsNaN(item->param4()));
        QVERIFY(item->autoContinue());
        // `isCurrentItem` 由 `PlanManager::writeMissionItems` 按 firstIndex 重设，
        // 这里传 false 是"不由组项方决定"。
        QVERIFY(!item->isCurrentItem());
    }

    qDeleteAll(items);
}

/// 两次调用必须产出**互不共享**的对象：`PlanManager` 会接管并最终删除传入的项，
/// 若组项函数返回缓存对象，第二次调用就会拿到已被删除的指针。
void VtolLandingMissionTest::_missionItemsAreIndependentCopies()
{
    const QList<MissionItem*> first =
        Vehicle::createVtolLandingMissionItems(kApproachLat, kApproachLon, kSlotLat, kSlotLon, kAltRel);
    const QList<MissionItem*> second =
        Vehicle::createVtolLandingMissionItems(kApproachLat, kApproachLon, kSlotLat, kSlotLon, kAltRel);

    QCOMPARE(first.count(), second.count());
    for (int i = 0; i < first.count(); i++) {
        QVERIFY(first[i] != second[i]);
    }

    qDeleteAll(first);
    qDeleteAll(second);
}

/// 在 MockLink 上走完整条 ③④：上传成功 ⇒ 发出 2 条 mission 项 ⇒ 切到 AutoPilot 的自动任务模式。
///
/// ‼️ 「发出 2 条」这一格是**独立于组项单测**的第二重判别力：传入 3 项，PX4 路径删 1 项，
///    所以链路上只该看到 2 条。若实现忘了垫占位，传入 2 项 ⇒ 删 1 项 ⇒ 只剩 1 条 ⇒ 本格红。
///    走 `MISSION_ITEM_INT` 还是 `MISSION_ITEM` 取决于链路探测结果，所以两者**合计**计数。
void VtolLandingMissionTest::_startMissionUploadsAndSwitchesMode()
{
    QVERIFY(_vehicle);
    QVERIFY(_mockLink);

    const QString missionMode = _vehicle->firmwarePlugin()->missionFlightMode();
    QVERIFY(!missionMode.isEmpty());

    _mockLink->clearReceivedMavlinkMessageCounts();
    _mockLink->clearReceivedMavCommandCounts();

    QSignalSpy finishedSpy(_vehicle, &Vehicle::vtolLandingMissionFinished);
    QVERIFY(finishedSpy.isValid());

    QVERIFY(_vehicle->startVtolLandingMission(kApproachLat, kApproachLon, kSlotLat, kSlotLon));

    QVERIFY_TRUE_WAIT(finishedSpy.count() == 1, TestTimeout::longMs());
    const QList<QVariant> args = finishedSpy.takeFirst();
    QVERIFY2(args.at(0).toBool(), qPrintable(args.at(1).toString()));

    const int itemMsgs =
        _mockLink->receivedMavlinkMessageCount(MAVLINK_MSG_ID_MISSION_ITEM_INT) +
        _mockLink->receivedMavlinkMessageCount(MAVLINK_MSG_ID_MISSION_ITEM);
    QCOMPARE(itemMsgs, 2);

    // ④ 切 AUTO_MISSION：`Vehicle::setFlightMode` 在 `MAV_CMD_DO_SET_MODE` 受支持时发命令、
    //    否则回落成 SET_MODE 报文 ⇒ 两者合计至少一条。
    const int modeMsgs = _mockLink->receivedMavCommandCount(MAV_CMD_DO_SET_MODE) +
                         _mockLink->receivedMavlinkMessageCount(MAVLINK_MSG_ID_SET_MODE);
    QVERIFY(modeMsgs >= 1);
}

/// 坐标闸：NaN / 越界必须**一个字节都不发**，并且经信号给出可见失败。
/// ‼️ (0,0) **不算**无效坐标 —— 「有没有可用接机机位」是业务判据，由 QML 侧按路径分别把关
///    （正常降落两条路判、救济路刻意不判，§9.7）。这一格钉住"C++ 侧不越权判业务"。
void VtolLandingMissionTest::_startMissionRejectsInvalidCoordinates()
{
    QVERIFY(_vehicle);
    QVERIFY(_mockLink);

    _mockLink->clearReceivedMavlinkMessageCounts();
    _mockLink->clearReceivedMavCommandCounts();

    QSignalSpy finishedSpy(_vehicle, &Vehicle::vtolLandingMissionFinished);
    QVERIFY(finishedSpy.isValid());

    QVERIFY(!_vehicle->startVtolLandingMission(qQNaN(), kApproachLon, kSlotLat, kSlotLon));
    QCOMPARE(finishedSpy.count(), 1);
    QVERIFY(!finishedSpy.takeFirst().at(0).toBool());

    QCOMPARE(_mockLink->receivedMavlinkMessageCount(MAVLINK_MSG_ID_MISSION_COUNT), 0);

    // 连 (0,0) 也**不**被 C++ 侧拦下 —— 它是合法坐标，业务判据不在这里。
    QVERIFY(_vehicle->startVtolLandingMission(0.0, 0.0, 0.0, 0.0));
}

/// ④ 的判别力：**成功信号到达的那一刻，模式已经真的回读到了**（§9.5.6 / §9.5.10）。
///
/// ‼️ 判别力来自**顺序**，不来自"有没有发 SET_MODE"（上一个用例已经查了那个）：
///    MockLink 的模式回显走 `MockLinkWorker` 的 **10 Hz** 心跳
///    （`MockLinkWorker.h:22` `kTimer10HzIntervalMs = 100`），而 `_handleSetMode`
///    （`MockLink.cc:1121-1130`）只是写 `_mavBaseMode`/`_mavCustomMode`，**自己不回显**。
///    ⇒ **不做回读**的实现会在同一个 lambda 里紧接着就 emit，那一刻 `flightMode()`
///      还是旧值 ⇒ 本格红；做回读的实现会先等到心跳把回显送上来 ⇒ 本格绿。
///    这也正是 §9.7 实验 #4「同模式切被接受」与 `_setFlightModeAndValidate` 第一支
///    （先比当前值、相等即 true）之间的关系：两条都成立，不互相推翻。
void VtolLandingMissionTest::_startMissionConfirmsModeByReadback()
{
    QVERIFY(_vehicle);
    QVERIFY(_mockLink);

    const QString missionMode = _vehicle->firmwarePlugin()->missionFlightMode();
    QVERIFY2(!missionMode.isEmpty(), "本用例的前提是非空的任务模式名");

    // 前提：起点**不是**目标模式。MockLink 的初值是 `PX4CustomMode::MANUAL`
    //（`MockLink.h:365`），`VehicleTest::init()/cleanup()`（`VehicleTest.cc:22-56`）
    // 每个用例重建 MockLink ⇒ 本断言应当成立。
    // ⚠️ 若这一行红了：先查 `VehicleTest` 是不是复用了上一个用例的 Vehicle，**不要**为了
    //    让用例变绿而把断言删掉 —— 删掉之后「回读」与「不回读」两种实现在本格上都绿，
    //    本格就变成了零判别力的摆设。
    QVERIFY2(_vehicle->flightMode() != missionMode,
             qPrintable(QStringLiteral("起点已是目标模式，本用例无判别力：") + _vehicle->flightMode()));

    QSignalSpy finishedSpy(_vehicle, &Vehicle::vtolLandingMissionFinished);
    QVERIFY(finishedSpy.isValid());

    QVERIFY(_vehicle->startVtolLandingMission(kApproachLat, kApproachLon, kSlotLat, kSlotLon));
    QVERIFY_TRUE_WAIT(finishedSpy.count() == 1, TestTimeout::longMs());
    const QList<QVariant> args = finishedSpy.takeFirst();
    QVERIFY2(args.at(0).toBool(), qPrintable(args.at(1).toString()));

    // ‼️ 本用例的全部就在这一行：信号到达的**同一刻**，模式必须已经回读到了。
    QCOMPARE(_vehicle->flightMode(), missionMode);
}

/// 上传层报错 ⇒ **不发成功信号**、且**一个字节都不切模式**（§9.5.10 的下半句）。
///
/// 「上传层的 `MISSION_ACK` 不足以判定接受」这一点，正面由上一个用例（回读）钉住；
/// 本用例钉反面：连 `sendComplete` 都带 error 的时候，绝不能报成功、更不能去切模式。
void VtolLandingMissionTest::_startMissionReportsUploadFailure()
{
    QVERIFY(_vehicle);
    QVERIFY(_mockLink);

    // 注入：最后一次 `MISSION_ACK` 回错误码（`MockLinkMissionItemHandler.h` 的 `FailureMode_t`）。
    _mockLink->setMissionItemFailureMode(
        MockLinkMissionItemHandler::FailureMode_t::FailWriteFinalAckErrorAck, MAV_MISSION_ERROR);

    _mockLink->clearReceivedMavlinkMessageCounts();
    _mockLink->clearReceivedMavCommandCounts();

    QSignalSpy finishedSpy(_vehicle, &Vehicle::vtolLandingMissionFinished);
    QVERIFY(finishedSpy.isValid());

    // ‼️ 下面这条 app message 是**既有**通路 `Vehicle::_missionManagerError`（挂在
    //    `Vehicle.cc:248` 那条连接上）发出的 —— 它正是 `Vehicle.cc` 里 ⛔ 注释要保护的东西：
    //    本实现用**代次计数**而**不** `disconnect`，就是为了不断掉它。所以这里**要求它出现**
    //    （而不是 `ignoreLogMessage` 把它静默掉）：哪天有人改回 `disconnect`，本行会红。
    //
    // ⚠️ 文案是 `tr()` 出来的 ⇒ **不能写死中文字面量**（本机 zh 绿、CI en 红）。
    //    与源码同一个 context、同一次翻译取模板，再切掉 `%1` 起的实参部分。
    QString appMsgPrefix =
        QCoreApplication::translate("Vehicle", "Mission transfer failed. Error: %1");
    const int argPos = appMsgPrefix.indexOf(QStringLiteral("%1"));
    if (argPos >= 0) {
        appMsgPrefix.truncate(argPos);
    }
    expectAppMessage(QRegularExpression(QRegularExpression::escape(appMsgPrefix)));

    QVERIFY(_vehicle->startVtolLandingMission(kApproachLat, kApproachLon, kSlotLat, kSlotLon));
    QVERIFY_TRUE_WAIT(finishedSpy.count() >= 1, TestTimeout::longMs());

    // 上面那条 app message 必须已经到过：它由 `MissionManager::error` 经 248 那条连接**同步**发出。
    verifyExpectedLogMessage();

    // `error` 与 `sendComplete(true)` 两条通路**都可能**各报一次（注释里写明"先后不保证"）
    // ⇒ 数**全部**都是 false，不是只看第一条。
    for (const QList<QVariant>& args : finishedSpy) {
        QVERIFY2(!args.at(0).toBool(),
                 qPrintable(QStringLiteral("上传失败却报了成功：") + args.at(1).toString()));
    }

    // ‼️ 不切模式。`setFlightMode` 在 PX4 上走 `SET_MODE` 报文（`MAV_CMD_DO_SET_MODE` 只有
    //    APM 的 override 返回真），所以两个都要查 —— 写成一个只会得到假绿。
    QCOMPARE(_mockLink->receivedMavCommandCount(MAV_CMD_DO_SET_MODE), 0);
    QCOMPARE(_mockLink->receivedMavlinkMessageCount(MAVLINK_MSG_ID_SET_MODE), 0);
}

UT_REGISTER_TEST(VtolLandingMissionTest, TestLabel::Integration, TestLabel::Vehicle)
