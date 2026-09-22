#include "MAVLinkCryptoFrameTest.h"

#include <QtCore/QScopeGuard>
#include <QtTest/QTest>

#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/DeviceID.h"
#include "MAVLinkLib.h"
#include "MAVLinkProtocol.h"
#include "MockLink.h"

namespace {

/// 每格**独占**一个 deviceID：单例状态跨用例共享，复用会造出顺序相关的用例。
/// 取值与 Task 1 的用例（`0x0A0B0C10u`）不同，也不等于 `kInvalidDeviceID`。
/// 用 MockLink 之外的 sysid，确保这两个 deviceID 本进程从未出现过。
/// 定义成文件级常量（而非各用例里的局部量）是为了让 `cleanup()` 能在**失败路径**上
/// 一样复位它们的防重放水位——两处写法不会漂移。
constexpr uint8_t kPlaintextSysId = 0x77;
constexpr uint8_t kPlaintextCompId = 0x42;
constexpr uint8_t kEncryptedSysId = 0x78;
constexpr uint8_t kEncryptedCompId = 0x43;

constexpr MAVLinkCrypto::DeviceID kPlaintextDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kPlaintextSysId, kPlaintextCompId);
constexpr MAVLinkCrypto::DeviceID kEncryptedDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kEncryptedSysId, kEncryptedCompId);

/// 读数上界（毫秒）。`>= 0` 单独用区分不了「刚刚记的」与「很久以前记的」，真正把
/// 「刚刚」钉死的是前面那句 `QCOMPARE(..., qint64(-1))`；这条上界是**加固**，用来抓
/// 「在陈旧时刻记账」这类回归。
///
/// 取值 200 而非更宽松的 1000：正确实现下这个读数就是 `noteDeviceFrame(deviceID)`
/// 与 `msSinceLastFrame(deviceID)` **两条相邻语句**之间的间隔（亚毫秒级），200 有约
/// 1000 倍余量；而实测「记账时刻陈旧」的回归读数是 **342 / 494 ms**（= `_frameClock`
/// 构造到用例执行之间的间隔，由进程启动 + QGC 初始化决定），1000 会**放它过去**
/// ——一条恒真的断言等于没有断言。故 200 才是这条加固的判据下限。
constexpr qint64 kFreshFrameUpperBoundMs = 200;

/// 构造一个标准（明文）MAVLink v2 HEARTBEAT 帧的线上字节。
/// 帧头 layout：0=magic(0xFD) 1=len 2=incompat 3=compat 4=seq 5=sysid 6=compid 7..9=msgid
QByteArray plaintextHeartbeatFrame(uint8_t sysid, uint8_t compid)
{
    mavlink_message_t msg{};
    (void) mavlink_msg_heartbeat_pack(sysid, compid, &msg, MAV_TYPE_QUADROTOR, MAV_AUTOPILOT_GENERIC, 0, 0, 0);

    uint8_t buffer[MAVLINK_MAX_PACKET_LEN]{};
    const int len = mavlink_msg_to_send_buffer(buffer, &msg);
    return QByteArray(reinterpret_cast<const char*>(buffer), len);
}

/// 构造一个「不是明文待命心跳」的加密帧：msgid != 0 且 payload block >= 28
/// （counter 8 + deviceID 4 + tag 16 = 28，规范 §2.6 第 0 步的长度门槛）。
///
/// 内容不需要是真的密文——本用例只走到 `noteDeviceFrame` 那一行就被防重放拒回，
/// 永远走不到解密。**这正是要验证的**：位置在防重放检查之前。
QByteArray encryptedFrame(uint8_t sysid, uint8_t compid, uint64_t counter)
{
    constexpr int kPayloadBlockLen = 28;
    QByteArray frame;
    frame.reserve(static_cast<int>(MAVLinkCrypto::kV2HeaderLen) + kPayloadBlockLen +
                  static_cast<int>(MAVLinkCrypto::kCrcLen));

    frame.append(static_cast<char>(0xFD));              // magic
    frame.append(static_cast<char>(kPayloadBlockLen));  // len（payload block）
    frame.append(static_cast<char>(0));                 // incompat（deviceID 高字节）
    frame.append(static_cast<char>(0));                 // compat
    frame.append(static_cast<char>(0));                 // seq
    frame.append(static_cast<char>(sysid));             // sysid
    frame.append(static_cast<char>(compid));            // compid
    frame.append(static_cast<char>(1));                 // msgid 低字节 = 1
    frame.append(static_cast<char>(0));
    frame.append(static_cast<char>(0));
    for (int i = 0; i < 8; i++) {  // counter：大端
        frame.append(static_cast<char>(static_cast<uint8_t>(counter >> (56 - i * 8))));
    }
    for (int i = 0; i < kPayloadBlockLen - 8; i++) {  // 其余为占位字节
        frame.append(static_cast<char>(0xAB));
    }
    frame.append(static_cast<char>(0));  // CRC 占位（不会走到校验）
    frame.append(static_cast<char>(0));
    return frame;
}

}  // namespace

void MAVLinkCryptoFrameTest::cleanup()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    // 兜底：任何一条用例中途失败都不会把「加密已启用」泄漏给别的用例（单例状态跨用例共享）。
    crypto->setCryptoEnabled(false);

    // 防重放水位同样复位，且必须在这里而不是用例末尾：加密格会把水位抬到 2000，
    // 用例末尾那句尾随 `resetReplay` 在**失败路径**上不会执行 ⇒ 水位留在进程级单例里。
    // 今天因 deviceID 独占看着无害，但这正是本文件在防的那类跨用例泄漏。
    crypto->resetReplay(kPlaintextDeviceID);
    crypto->resetReplay(kEncryptedDeviceID);

    VehicleTestManualConnect::cleanup();
}

/// 把「注入一帧」夹在 `cryptoEnabled` 的**最小窗口**内执行。
///
/// ‼️ 为什么必须开：`MAVLinkProtocol::receiveBytes` 的**入口**先按 `cryptoEnabled()`
/// 分流（函数开头的那个 `if`），false 时整包走普通解析路径，
/// `_receiveEncryptedBytes` / `_processEncryptedFrame` **根本不会被调用**——
/// 也就是说这两个分支（连同要钉的两行 `noteDeviceFrame`）不可达，用例只能恒红。
/// 计划里「receiveBytes 的分支只由帧内容决定、与 cryptoEnabled 全无关系」的说法
/// 只对 `_receiveEncryptedBytes` 里 `isPlaintextHeartbeat` 那一层（帧头 msgid 与 payload 长度
/// 判定）的**内层**分流成立；对**入口**分流不成立。
/// 实测证据：接线两行之后不启用 ⇒ 两条用例仍在原断言处 FAIL。
///
/// ‼️ 为什么窗口必须这么窄：`CryptoController::setCryptoEnabled` 本身只是加锁 + 赋值
/// （不起定时器、不动状态机），但**开启期间任何外发消息**都会命中 `LinkInterface`
/// 发送路径上的那个 `qCWarning`（"crypto enabled, link not Active"）⇒ strict mode 下
/// 用例失败。这里只包住同步的 `receiveBytes` 调用、不回到事件循环，
/// 故 MockLink 的遥测（已由 `setCommLost(true)` 静音）不可能落进窗口内。
void MAVLinkCryptoFrameTest::_injectWithCryptoEnabled(const QByteArray& frame)
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    crypto->setCryptoEnabled(true);
    // ⚠️ 复位必须是 scope guard，不能写成裸的尾随语句：将来若在下面这行 `receiveBytes`
    // 前后插入一个早 `return`（或它抛出），尾随语句会被跳过，`cryptoEnabled` 就
    // **进程级泄漏为 true** —— 此后本进程每一条外发消息都会命中 `LinkInterface`
    // 发送路径上那个 `qCWarning`（"crypto enabled, link not Active"，strict mode 下
    // 连带把别的用例搞红）。`cleanup()` 只兜得住「用例断言失败」，兜不住「用例中途中断」。
    const auto guard = qScopeGuard([crypto] { crypto->setCryptoEnabled(false); });
    MAVLinkProtocol::instance()->receiveBytes(_mockLink, frame);
}

void MAVLinkCryptoFrameTest::_testPlaintextHeartbeatNotesFrame()
{
    // 明文待命心跳支：msgID=0 且 payload block < 28（规范 §2.2 的明文特例）
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    // 静音 MockLink 自身的遥测流：注入的帧必须是唯一的输入，
    // 否则 MockLink 的设备会污染读数（照 MAVLinkV1TrafficTest::_testV1RadioStatusDoesNotWarn）
    _mockLink->setCommLost(true);

    const MAVLinkCrypto::DeviceID deviceID = kPlaintextDeviceID;
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));

    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kPlaintextSysId, kPlaintextCompId));

    // 变异自证：删掉明文心跳分支那一行 ⇒ 此处变红，而 _testEncryptedFrameNotesFrame 仍绿
    const qint64 ms = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(ms >= 0 && ms < kFreshFrameUpperBoundMs,
             qPrintable(QStringLiteral("明文待命心跳支必须记收帧时间戳（读数 ms=%1）").arg(ms)));
}

void MAVLinkCryptoFrameTest::_testEncryptedFrameNotesFrame()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    _mockLink->setCommLost(true);

    const MAVLinkCrypto::DeviceID deviceID = kEncryptedDeviceID;
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));

    // 把防重放水位抬到 2000：随后喂 counter=1000 的帧必被拒。
    // 本用例的判别力全在这里——「记了」与「记在检查之前」是同一条断言的两面。
    // 水位复位在 `cleanup()` 里（失败路径上也要生效），不在本函数末尾。
    QVERIFY(crypto->isIncomingAcceptable(deviceID, 2000));
    crypto->commitIncoming(deviceID, 2000);

    _injectWithCryptoEnabled(encryptedFrame(kEncryptedSysId, kEncryptedCompId, 1000));

    // 变异自证①：删掉加密帧分支那一行 ⇒ 此处变红，而明文那一格仍绿
    // 变异自证②：把 noteDeviceFrame 挪到 isIncomingAcceptable 之后 ⇒ 此处同样变红
    const qint64 ms = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(ms >= 0 && ms < kFreshFrameUpperBoundMs,
             qPrintable(QStringLiteral("加密帧支必须记收帧时间戳，且须记在防重放检查之前（读数 ms=%1）").arg(ms)));
}

UT_REGISTER_TEST(MAVLinkCryptoFrameTest, TestLabel::Integration, TestLabel::Comms)
