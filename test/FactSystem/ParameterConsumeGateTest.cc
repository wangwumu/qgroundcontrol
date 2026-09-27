#include "ParameterConsumeGateTest.h"

#include <QtTest/QTest>

#include "AuthController.h"
#include "MAVLinkLib.h"
#include "MockLink.h"
#include "MultiVehicleManager.h"
#include "ParameterManager.h"
#include "Vehicle.h"

namespace {

/// 喂给 ParameterManager 的参数名。取一个 MockLink 绝不会自己发出的名字，
/// 这样"这个 fact 有没有被建出来"就等价于"这一帧有没有被消费"。
constexpr const char *kProbeParamName = "GATE_TEST_PARAM";

mavlink_message_t _makeParamValue(uint8_t chan, const char *name, float value)
{
    mavlink_message_t msg{};
    // ‼️ 参数顺序按 wire 顺序：param_id, param_value, param_type, param_count, param_index
    //    —— 与 mavlink_param_value_t 结构体字段顺序（value/count/index/id/type）**不同**，v2 会 reorder。
    // ‼️ component_id 必须是 AUTOPILOT1：_handleParamValue 用的是 message.compid 作为
    //    componentId，fact 也建在该 component 下；写成别的 compid 会"喂进去但查不到"，
    //    阳性对照会假红、差分点会假绿。
    mavlink_msg_param_value_pack_chan(
        /* system_id      */ 255,
        /* component_id   */ MAV_COMP_ID_AUTOPILOT1,
        /* chan           */ chan,
        /* msg            */ &msg,
        /* param_id       */ name,
        /* param_value    */ value,
        /* param_type     */ MAV_PARAM_TYPE_REAL32,
        /* param_count    */ 1,
        /* param_index    */ 0);
    return msg;
}

}  // namespace

void ParameterConsumeGateTest::_ensureAuthSingleton(bool present)
{
    if (present) {
        if (!AuthController::instance()) {
            // 构造函数内部登记 s_instance（首个实例）。
            new AuthController();
        }
    } else {
        delete AuthController::instance();  // 析构把 s_instance 置空
    }
}

void ParameterConsumeGateTest::cleanup()
{
    // 单例跨用例存活：必须恢复成"不存在"，否则后续用例（含其他测试类）会被判成运营态。
    _ensureAuthSingleton(false);
    VehicleTestManualConnect::cleanup();
}

void ParameterConsumeGateTest::_consumeGate_data()
{
    QTest::addColumn<bool>("authSingletonPresent");
    QTest::addColumn<bool>("loggedIn");
    QTest::addColumn<bool>("sendFrame");
    QTest::addColumn<bool>("expectConsumed");

    //                     单例存在  已登录   喂帧    期望落地
    QTest::newRow("Standalone_Consumed")    << false << false << true  << true;
    QTest::newRow("OnlineMode_NotConsumed") << true  << true  << true  << false;
    QTest::newRow("OnlineMode_NoFrame")     << true  << true  << false << false;
}

void ParameterConsumeGateTest::_consumeGate()
{
    QFETCH(bool, authSingletonPresent);
    QFETCH(bool, loggedIn);
    QFETCH(bool, sendFrame);
    QFETCH(bool, expectConsumed);

    // 状态必须在连接之前就位：_startParameterDownload 是在 Vehicle 接入时跑的。
    _ensureAuthSingleton(authSingletonPresent);
    if (authSingletonPresent) {
        AuthController::instance()->setLoggedInForTest(loggedIn);
    }

    _connectMockLink(MAV_AUTOPILOT_PX4);
    QVERIFY(_vehicle);
    QVERIFY(_mockLink);

    ParameterManager *const paramManager = _vehicle->parameterManager();
    QVERIFY(paramManager);

    // 参数状态机收敛后再喂帧：否则测的可能是"下载还没跑完"而不是"这一帧被没被消费"。
    QTRY_VERIFY_WITH_TIMEOUT(paramManager->parametersReady(), TestTimeout::longMs());

    if (sendFrame) {
        const mavlink_message_t msg = _makeParamValue(_mockLink->mavlinkChannel(), kProbeParamName, 42.0f);
        paramManager->mavlinkMessageReceived(msg);

        // 让接收侧的信号分发跑完（facadded 是直连信号，processEvents 足够）。
        QCoreApplication::processEvents();
    }

    const bool consumed = paramManager->parameterExists(MAV_COMP_ID_AUTOPILOT1, QString::fromLatin1(kProbeParamName));
    QCOMPARE(consumed, expectConsumed);

    _disconnectMockLink();
}

UT_REGISTER_TEST(ParameterConsumeGateTest, TestLabel::Integration, TestLabel::Vehicle, TestLabel::Serial)
