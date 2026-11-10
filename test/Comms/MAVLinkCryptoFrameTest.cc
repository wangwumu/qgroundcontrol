#include "MAVLinkCryptoFrameTest.h"

#include <QtCore/QDateTime>
#include <QtCore/QObject>
#include <QtCore/QRegularExpression>
#include <QtCore/QScopeGuard>
#include <QtCore/QVariantList>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>
#include <QtTest/QTest>

#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/DeviceID.h"
#include "Crypto/DeviceKeyManager.h"
#include "Crypto/MAVLinkCrypto.h"
#include "MAVLinkLib.h"
#include "MAVLinkProtocol.h"
#include "MockLink.h"
#include "MultiVehicleManager.h"
#include "QmlObjectListModel.h"

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

/// 被动取密钥那一格的两个 deviceID（Task 8）：同样与其它格互不重叠。
/// 两格共用一份清单，靠 `isInManifest` 的**真假**分开——这样「拉」与「不拉」之间
/// 只差清单归属这一个变量，不掺进"两次注入的帧有何不同"。
constexpr uint8_t kInManifestSysId = 0x79;
constexpr uint8_t kInManifestCompId = 0x44;
constexpr uint8_t kOutOfManifestSysId = 0x7A;
constexpr uint8_t kOutOfManifestCompId = 0x45;

constexpr MAVLinkCrypto::DeviceID kInManifestDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kInManifestSysId, kInManifestCompId);
constexpr MAVLinkCrypto::DeviceID kOutOfManifestDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kOutOfManifestSysId, kOutOfManifestCompId);

/// 「非引入方不建车」那一格的独占身份（2026-11-10）。
/// ⚠️ **不能复用** kPlaintextDeviceID：前一个用例已用同一 sysid 建过 Vehicle（那时名单
///    未推送、fail-open），复用它会让"阳性对照必须多出一辆"这一臂永远等不到新车。
/// ⚠️ compid 必须是 `kNormalizedComponentID`(1)：明文支会把帧头 compid 归一化成 1 再喂
///    标准解析器，而**不重算 CRC** ⇒ 用别的 compid 会造出 CRC 不匹配的帧，阳性对照永远建不出车
///    （实测踩到：compid=0x46 时第一臂假绿、阳性对照 count 不增）。
constexpr uint8_t kNonIntroducerSysId = 0x7B;
constexpr uint8_t kNonIntroducerCompId = 1;
constexpr MAVLinkCrypto::DeviceID kNonIntroducerDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kNonIntroducerSysId, kNonIntroducerCompId);

/// 会话边界格（2026-11-10）的独占身份：本文件唯一**真正解密成功**的用例。
constexpr uint8_t kSessionBoundarySysId = 0x7C;
constexpr uint8_t kSessionBoundaryCompId = 0x47;
constexpr MAVLinkCrypto::DeviceID kSessionBoundaryDeviceID =
    MAVLinkCrypto::makeDeviceID(0, 0, kSessionBoundarySysId, kSessionBoundaryCompId);

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

/// 32 字节试验密钥（内容无关紧要，本用例只问"本地有没有"）。
MAVLinkCrypto::Key testKey()
{
    MAVLinkCrypto::Key key{};
    for (size_t i = 0; i < key.size(); ++i) {
        key[i] = static_cast<uint8_t>(i);
    }
    return key;
}

/// 组装一条**可真正解密**的加密心跳帧：标准帧 = 10B 头 + HEARTBEAT payload(9B) + EXT(63B) + CRC。
///
/// EXT 的 gps_utc_us 在 EXT 偏移 55（= payload 偏移 9+55=64），属 60825.0 段；
/// 传 0 表示「未定位/未同步」，正是会话边界判据必须 fail-closed 的输入。
/// heartbeat.type（线上 offset 4）= MAV_TYPE_GCS：`MultiVehicleManager` 不给 GCS 建 Vehicle，本用例因此
/// 不会牵出 InitialConnectStateMachine（它会发上行请求，污染严格模式日志）。
QByteArray encryptedHeartbeatWithGpsUtc(uint64_t counter, uint64_t gpsUtcUs)
{
    const uint8_t crcExtra = mavlink_get_msg_entry(MAVLINK_MSG_ID_HEARTBEAT)->crc_extra;

    // ⚠️ MAVLink v2 线上字段按宽度降序重排：custom_mode(4B) 在前，type 在 **offset 4**，
    //    不是 offset 0。写错位置会让 type=MAV_TYPE_GENERIC ⇒ 真的被建出一架 Vehicle
    //    （实测：写成 offset 0 时弹出「已连接到载具 124」并牵出后续上行）。
    QByteArray payload(9 + 63, '\0');
    payload[4] = static_cast<char>(MAV_TYPE_GCS);  // heartbeat.type
    payload[8] = static_cast<char>(3);             // mavlink_version
    for (int i = 0; i < 8; ++i) {                  // gps_utc_us：小端
        payload[64 + i] = static_cast<char>((gpsUtcUs >> (8 * i)) & 0xFF);
    }

    QByteArray plain;
    plain.append(static_cast<char>(0xFD));                 // magic
    plain.append(static_cast<char>(payload.size()));       // len
    plain.append(static_cast<char>(0));                    // incompat
    plain.append(static_cast<char>(0));                    // compat
    plain.append(static_cast<char>(0));                    // seq
    plain.append(static_cast<char>(kSessionBoundarySysId));
    plain.append(static_cast<char>(kSessionBoundaryCompId));
    plain.append(static_cast<char>(0));                    // msgid=0 (HEARTBEAT)
    plain.append(static_cast<char>(0));
    plain.append(static_cast<char>(0));
    plain.append(payload);
    uint16_t crc = 0;
    crc_init(&crc);
    for (int i = 1; i < plain.size(); ++i) {
        crc_accumulate(static_cast<uint8_t>(plain.at(i)), &crc);
    }
    crc_accumulate(crcExtra, &crc);
    plain.append(static_cast<char>(crc & 0xFF));
    plain.append(static_cast<char>(crc >> 8));

    uint8_t enc[MAVLINK_MAX_PACKET_LEN + 64]{};
    int encLen = 0;
    if (!MAVLinkCrypto::encryptFrame(reinterpret_cast<const uint8_t*>(plain.constData()), plain.size(), crcExtra,
                                     kSessionBoundaryDeviceID, counter, testKey(), enc, &encLen)) {
        return {};
    }
    return QByteArray(reinterpret_cast<const char*>(enc), encLen);
}

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
    // 会话边界格会真的解密成功并建链（本文件唯一）：状态机与密钥都得在**失败路径**上
    // 一并复位，否则后续用例面对的是一个 Active 着的单例、且自带别人的密钥。
    if (crypto->state() != MAVLinkCrypto::CryptoController::State::Standby) {
        crypto->returnToStandby();
    }
    crypto->resetReplay(kSessionBoundaryDeviceID);
    crypto->deviceKeyManager()->removeKey(kSessionBoundaryDeviceID);
    crypto->removeLinkedDevice(kSessionBoundaryDeviceID);

    // 权限前置闸（2026-11-10）要求报文对应的 deviceID 在本端权限范围内：用例会给
    // 自己的 deviceID 挂上 `_linkedDevices` 授权 ⇒ 必须在这里撤销。用例末尾那句
    // `removeLinkedDevice` 在失败路径上不执行，残留下来会让别的用例的 `isInManifest`
    // 多出真值（`_testPlaintextHeartbeatTriggersFetchOnlyWhenInManifest` 的"清单外"
    // 一格正是靠清单归属的**真假**分开的）。含"清单外"那一格的 kOutOfManifestDeviceID：
    // 它靠 `_linkedDevices` 取得授权而 `isInManifest` 仍为假。
    crypto->removeLinkedDevice(kPlaintextDeviceID);
    crypto->removeLinkedDevice(kEncryptedDeviceID);
    crypto->removeLinkedDevice(kOutOfManifestDeviceID);
    crypto->removeLinkedDevice(kNonIntroducerDeviceID);

    // gcs_server 地址同样是进程级的：`DeviceKeyManager` 挂在单例上，用例末尾那句
    // `setServerUrl(QString())` 在**失败路径**上不会执行。配了地址的用例会让 `fetchKeys`
    // 从"静默早退"变成"真的发请求"，此后任何一次拉取都会多出一条失败的 warning
    // ——落在别的用例的 strict-mode 日志检查上。故复位点放在这里。
    crypto->deviceKeyManager()->setServerUrl(QString());

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
/// 发送路径上「加密未就绪」那条分支（"crypto enabled, link not Active"）⇒ strict mode 下
/// 用例失败。⚠️ 该分支 2026-10-05 起按 msgid 分流：非心跳仍走 `qCWarning` + 飞行事件日志，
/// **msgid 0（GCS 心跳）改为 `qCDebug` 且不写事件日志**（QGC 从启动到建链成功期间它按 1Hz
/// 刷屏）。别因此以为心跳落进窗口就无害 —— 那条 debug 会不会被本进程的 strict mode 抓到，
/// 取决于该 category 的 debug 是否开启，不要依赖它。这里只包住同步的 `receiveBytes` 调用、
/// 不回到事件循环，故 MockLink 的遥测（已由 `setCommLost(true)` 静音）不可能落进窗口内。
void MAVLinkCryptoFrameTest::_injectWithCryptoEnabled(const QByteArray& frame)
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    crypto->setCryptoEnabled(true);
    // ⚠️ 复位必须是 scope guard，不能写成裸的尾随语句：将来若在下面这行 `receiveBytes`
    // 前后插入一个早 `return`（或它抛出），尾随语句会被跳过，`cryptoEnabled` 就
    // **进程级泄漏为 true** —— 此后本进程每一条**非心跳**外发消息都会命中 `LinkInterface`
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

    // 权限前置闸（2026-11-10）：未授权设备的帧在**任何状态写入之前**丢弃，
    // 因此连收帧时间戳都不该记。这一臂同时是下面正面断言的阴性对照——
    // 单看"授权后记了"，分不清它记的是这一帧还是某个无条件记账的旁路。
    QVERIFY2(!crypto->isDeviceAuthorized(deviceID), "初态必须未授权，否则阴性对照不成立");
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kPlaintextSysId, kPlaintextCompId));
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));
    // 收帧时间戳只覆盖 `noteDeviceFrame`；`learnDeviceSystemMapping` 是一条**独立**写点。
    // 少了这条断言，把闸下移到 learn 之后（或删掉闸、只删 note）也能全绿。
    MAVLinkCrypto::DeviceID mapped = MAVLinkCrypto::kInvalidDeviceID;
    QVERIFY2(!crypto->deviceIDForSystemID(kPlaintextSysId, mapped) || mapped != deviceID,
             "未授权帧不得学习 sysid 映射");

    // 授权：挂进名册。⚠️ 先显式清空 serverUrl——`addLinkedDevice` 对"新加入且本地无密钥"
    // 的设备会发一次批量拉取，配了地址就变成真实 HTTP（cleanup 复位它，但顺序依赖能免则免）。
    crypto->deviceKeyManager()->setServerUrl(QString());
    crypto->addLinkedDevice(deviceID);
    QVERIFY2(crypto->isDeviceAuthorized(deviceID), "名册内必须放行");

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

    // 未授权设备的帧在权限闸处就返回，不记收帧时间戳、不学映射（阴性对照，同明文那一格）。
    QVERIFY2(!crypto->isDeviceAuthorized(deviceID), "初态必须未授权，否则阴性对照不成立");
    _injectWithCryptoEnabled(encryptedFrame(kEncryptedSysId, kEncryptedCompId, 1000));
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));
    MAVLinkCrypto::DeviceID mapped = MAVLinkCrypto::kInvalidDeviceID;
    QVERIFY2(!crypto->deviceIDForSystemID(kEncryptedSysId, mapped) || mapped != deviceID,
             "未授权帧不得学习 sysid 映射");

    crypto->deviceKeyManager()->setServerUrl(QString());
    crypto->addLinkedDevice(deviceID);
    QVERIFY2(crypto->isDeviceAuthorized(deviceID), "名册内必须放行");

    _injectWithCryptoEnabled(encryptedFrame(kEncryptedSysId, kEncryptedCompId, 1000));

    // 变异自证①：删掉加密帧分支那一行 ⇒ 此处变红，而明文那一格仍绿
    // 变异自证②：把 noteDeviceFrame 挪到 isIncomingAcceptable 之后 ⇒ 此处同样变红
    const qint64 ms = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(ms >= 0 && ms < kFreshFrameUpperBoundMs,
             qPrintable(QStringLiteral("加密帧支必须记收帧时间戳，且须记在防重放检查之前（读数 ms=%1）").arg(ms)));
}

/// 会话边界（2026-11-10 用户裁定）：**被防重放水位拦下的加密心跳**，解密后其 EXT 的
/// GPS UTC 与本地时间相差 ≤5s 才清本机水位；否则仍按重放丢弃。
///
/// 复现：qgc1 一直运行（下行水位被旧会话推到 3.298e18），PX4 重启后新会话从 1.618e18 起
/// ⇒ 恒运行的 qgc1 每一帧都被判重放、"没有数据"；新起的 qgc2 水位为空所以能接。
/// 清水位必须由**认证过的新鲜证据**触发——明文待命心跳无认证（伪造它就能重放旧加密帧），
/// 故判据只能放在解密侧：GCM 认证通过（伪造者没有密钥就过不了）+ UTC 新鲜（旧会话帧带旧时间戳）。
///
/// ‼️ 四臂必须同处一个函数：臂①②③（旧 UTC / UTC=0 / 未来 UTC）的断言形态都是"水位没动"，
///    单看没有判别力（把整块实现删掉它们也绿）。判别力全部来自同一函数里的臂④阳性对照。
/// ‼️ 走的是真入口：`_injectWithCryptoEnabled` → `MAVLinkProtocol::receiveBytes`。
void MAVLinkCryptoFrameTest::_testSessionBoundaryLowersReplayWatermark()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    _mockLink->setCommLost(true);
    // 会话边界本身要留一条生产告警（PX4 重启是需人工关注的运维事件）；它在**通过**用例里
    // 也是预期输出，故按单条消息放行，而不是改断言或降成 debug 绕开 strict mode。
    ignoreLogMessage("Comms.MAVLinkProtocol", QtWarningMsg, QRegularExpression("replay watermark lowered"));

    const MAVLinkCrypto::DeviceID deviceID = kSessionBoundaryDeviceID;
    // 授权 + 本地密钥是前置：缺任一条帧都走不到解密，本用例就恒绿（假绿）。
    crypto->deviceKeyManager()->setServerUrl(QString());
    crypto->addLinkedDevice(deviceID);
    crypto->deviceKeyManager()->cacheKey(deviceID, testKey());
    QVERIFY2(crypto->isDeviceAuthorized(deviceID), "前置：名册内");
    QVERIFY2(crypto->deviceKeyManager()->hasKey(deviceID), "前置：本地密钥");

    constexpr uint64_t kOldSessionCounter = 0x3000000000000000ull;  // 实测旧会话 ≈ 3.298e18
    // 四臂各用**不同**的 counter：观测手段是「该 counter 之后一帧是否可收」——
    // 帧被丢 ⇒ 水位仍在旧会话高处 ⇒ 不可收；帧被接受 ⇒ 水位压到该 counter ⇒ 下一帧可收。
    // ⚠️ 不能用「该 counter 自身是否可收」：`commit` 之后严格大于才可收，两条路径读数相同
    //    （实测：写成同值断言时，把 UTC 校验整个删掉用例依然全绿）。
    constexpr uint64_t kStaleUtcCounter = 0x1500000000000000ull;
    constexpr uint64_t kZeroUtcCounter = 0x1510000000000000ull;
    constexpr uint64_t kFutureUtcCounter = 0x1520000000000000ull;
    constexpr uint64_t kBoundaryCounter = 0x1600000000000000ull;  // 实测新会话 ≈ 1.618e18
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

    // 旧会话先把水位推高（PX4 重启前的最后一帧）。
    crypto->commitIncoming(deviceID, kOldSessionCounter);
    QVERIFY2(!crypto->isIncomingAcceptable(deviceID, kBoundaryCounter + 1),
             "前置：旧水位必须高于新会话 counter，否则四臂都测不到任何东西");

    // 臂① 旧 UTC（60s 前）⇒ 不构成会话边界：帧被丢、水位不动。
    _injectWithCryptoEnabled(encryptedHeartbeatWithGpsUtc(kStaleUtcCounter,
                                                          static_cast<uint64_t>(nowMs - 60'000) * 1000));
    QVERIFY2(!crypto->isIncomingAcceptable(deviceID, kStaleUtcCounter + 1),
             "旧 UTC 的加密心跳不得清水位——否则重放一条旧会话帧就能反复打开重放窗口");

    // 臂② UTC=0（未定位/未同步）⇒ 无法判新鲜度，必须 fail-closed。
    _injectWithCryptoEnabled(encryptedHeartbeatWithGpsUtc(kZeroUtcCounter, 0));
    QVERIFY2(!crypto->isIncomingAcceptable(deviceID, kZeroUtcCounter + 1), "UTC=0 时必须 fail-closed，水位不动");

    // 臂③ 未来 UTC（超前 10s）⇒ 与旧 UTC 同理：容差是**双向**的，时钟异常的一侧同样
    //      不能当边界（否则对方时钟跑偏就能无限次压低本端水位）。
    _injectWithCryptoEnabled(encryptedHeartbeatWithGpsUtc(kFutureUtcCounter,
                                                          static_cast<uint64_t>(nowMs + 10'000) * 1000));
    QVERIFY2(!crypto->isIncomingAcceptable(deviceID, kFutureUtcCounter + 1),
             "未来 UTC（超前 >5s）不得清水位——新鲜度判据必须取绝对值");

    // 臂④ 新鲜 UTC ⇒ 这就是会话边界：水位压到本帧 counter，后续新会话帧放行。
    _injectWithCryptoEnabled(encryptedHeartbeatWithGpsUtc(kBoundaryCounter, static_cast<uint64_t>(nowMs) * 1000));
    QVERIFY2(crypto->isIncomingAcceptable(deviceID, kBoundaryCounter + 1),
             "新鲜 UTC 的加密心跳是会话边界：水位必须被压到本帧 counter");
    QVERIFY2(!crypto->isIncomingAcceptable(deviceID, kBoundaryCounter),
             "边界只前移一步：本帧之后同一 counter 重放仍必须被拒（不是永久放行）");
}

/// 被动取密钥时机（规范 §2.7.2 e，Task 8）：明文待命心跳支。
///
/// 钉的是条件 `!hasKey(deviceID) && isInManifest(deviceID)` 的**两个合取项**，
/// 外加"确实发了请求"这一事实本身：
///   ① 清单内 + 本地无密钥 ⇒ 拉 1 个      ← 正面判据：证明这套观测是活的
///   ② 清单外 + 本地无密钥 ⇒ 一个都不拉   ← 钉 `isInManifest`
///   ③ 清单内 + 本地有密钥 ⇒ 也不拉       ← 钉 `!hasKey`
/// ②③ 的断言形态都是"什么都没发生"，**单看没有判别力**（把整块实现删掉它们也绿）。
/// 它们的判别力全部来自同一个用例里的 ① 做了阳性对照 —— 三格必须同处一个函数，
/// 拆开就是把 ②③ 变成恒真的装饰。
///
/// ‼️ 走的是真入口：`_injectWithCryptoEnabled` → `MAVLinkProtocol::receiveBytes`。
///    直接调 `beginLinking` 或 `fetchKeys` 都测不到"被动时机"，那是另一回事。
void MAVLinkCryptoFrameTest::_testPlaintextHeartbeatTriggersFetchOnlyWhenInManifest()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    _mockLink->setCommLost(true);

    // ② 那一格（"清单外不拉"）的 deviceID 必须先通过**接收权限闸**（2026-11-10），
    //    否则帧在 `MAVLinkProtocol.cc` 入口就被丢弃，根本到不了下面那个取密钥条件——
    //    本格会变成"测权限闸"而不是"测 isInManifest"（删掉 `isInManifest` 合取项也照样绿）。
    //    `addLinkedDevice` 给出的组合恰好是：权限判据（两个集合的并集）为真、`isInManifest`
    //    为假（监控清单生效后它只看 `_monitorDevices`）。
    // ⚠️ 必须放在配 serverUrl **之前**：此刻地址还是空的（上一格 cleanup 已复位），
    //    `addLinkedDevice` 对"新加入且无密钥"设备那次拉取会静默早退，不制造额外请求。
    crypto->deviceKeyManager()->setServerUrl(QString());
    crypto->addLinkedDevice(kOutOfManifestDeviceID);

    // ‼️ 必须显式配一个 serverUrl，被动触发才可观测：`fetchKeys` 在 `!isConfigured()` 时
    //    **静默早退**，且早退排在 `emit keysRequested` **之前** ⇒ 不配的话信号永不发射，
    //    ① 会红、② 会以"什么都没发生"的理由假绿。端口 1 无人监听（必然被拒），
    //    只为了让 `isConfigured()` 为真，不发真实流量。
    crypto->deviceKeyManager()->setServerUrl(QStringLiteral("http://127.0.0.1:1"));
    crypto->deviceKeyManager()->clearCache();

    // 两次必然失败的请求各打一条 warning。strict mode 下未预期的日志＝用例失败。
    // `isIgnored` 是逐条匹配、**不消费**规则的 ⇒ 一条规则覆盖同类全部告警。
    ignoreLogMessage("MAVLink.Crypto.DeviceKeyManager", QtWarningMsg, QRegularExpression("fetchKeys failed"));

    // 清单里只有 kInManifestDeviceID。
    // ‼️ 必须在挂观察者**之前**推：这一步自己就会触发一次拉取（Task 7 的 `changed` 判据，
    //    而 `clearCache()` 刚把密钥清空 ⇒ 那一次一定发得出去），那是"主动时机"的信号，
    //    不属于本用例要钉的"被动时机"。信号是同步发射的，先推后挂即可把它挡在观察窗之外。
    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(kInManifestDeviceID) }, 5000);

    QList<MAVLinkCrypto::DeviceID> requested;
    // 用栈上的 `guard` 当 context（不是 `this`、更不是三参写法）：本类对象跨用例不析构，
    // 而这个 lambda 按引用捕获 `requested` —— 连接若活过本函数，它写的就是已析构的栈帧。
    // `guard` 出作用域即断开，把这件事交给编译器而不是"记得手动 disconnect"。
    QObject guard;
    QObject::connect(crypto->deviceKeyManager(), &MAVLinkCrypto::DeviceKeyManager::keysRequested, &guard,
                     [&requested](const QList<MAVLinkCrypto::DeviceID>& ids) { requested += ids; });

    // 前置：两格的清单归属确实是一真一假。少了这两句，② 有可能因为"清单其实也含它"而恒真。
    QVERIFY2(crypto->isInManifest(kInManifestDeviceID), "前置：①的 deviceID 必须在清单内");
    QVERIFY2(!crypto->isInManifest(kOutOfManifestDeviceID), "前置：②的 deviceID 必须不在清单内");

    // ① 清单内 + 本地无密钥 ⇒ 被动拉 1 个
    // 变异自证：删掉 `MAVLinkProtocol.cc` 里那段被动拉取 ⇒ 此处变红（`requested` 为空）。
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kInManifestSysId, kInManifestCompId));
    QCOMPARE(requested, QList<MAVLinkCrypto::DeviceID>{ kInManifestDeviceID });

    // ② 清单外 + 本地无密钥 ⇒ 一个都不拉
    // 变异自证：把判断里的 `isInManifest(deviceID)` 去掉 ⇒ 此处变红（会多出 kOutOfManifestDeviceID）。
    requested.clear();
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kOutOfManifestSysId, kOutOfManifestCompId));
    QVERIFY2(requested.isEmpty(), "清单外的 deviceID 一律不拉（规范 §2.7.2 e）");

    // ③ 清单内 + 本地**已有**密钥 ⇒ 也不拉
    //    这一格钉的是合取项 `!hasKey(deviceID)`。①② 都盖不到它：① 里 `hasKey` 为假，
    //    ② 里第一个合取项为真、被 `isInManifest` 短路。少了这一格，把 `!hasKey(...)` 整个
    //    删掉（于是每架在飞飞机 1 Hz 的心跳各触发一次 HTTP，清单多大就是多少次/秒）
    //    在本文件里**一条断言都不会变红**。
    //
    //    ⚠️ 前置：本格是全文第一处让建链闸 `state()==Standby && hasKey(deviceID)` 成真的地方
    //       （①② 无密钥，从不进闸），因此 `beginLinking` 会被**真正调用**。非责任方在入口
    //       静默 return，那正是本进程的常态；但若本进程其实是责任方，它会真的进 Linking、
    //       改动加密状态机与失联监测——那测的就不是本用例要测的东西了。宁可按前置失败报出来，
    //       也不要让它静默地测成另一回事。
    QVERIFY2(!crypto->isResponsibleParty(),
             "前置：本格假定本进程是非责任方（BEGINLINKING 入口静默返回）；若本进程已是责任方，"
             "本格会真的建链，须重新设计");
    requested.clear();
    crypto->deviceKeyManager()->cacheKey(kInManifestDeviceID, testKey());
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kInManifestSysId, kInManifestCompId));
    QVERIFY2(requested.isEmpty(), "本地已有密钥的 deviceID 不得重复拉取（否则每架飞机每次心跳一次 HTTP）");
    crypto->deviceKeyManager()->removeKey(kInManifestDeviceID);

    // ---- 把上面两次请求的 HTTP 副作用在**本用例内**消化掉 ----
    // 这个 QNAM 是单例 `DeviceKeyManager` 的值成员，**进程内不析构** ⇒ 不排空的话，那两条
    // 失败的 reply 会落在后续的事件循环里，以"未预期日志"把别人判红。
    // 判据用"NAM 名下不再挂着子 reply"（`nam->get()` 的返回值就以 it 为 parent），
    // 比数数耐用：无论漏了几条都在这儿收干净。
    QNetworkAccessManager* const nam = crypto->deviceKeyManager()->findChild<QNetworkAccessManager*>();
    QVERIFY2(nam != nullptr, "DeviceKeyManager 必须持有一个以自身为 parent 的 QNAM");
    // ⚠️ 条件式等待，不是固定延时（本仓 Golden Rule 禁止 `QTest::qWait(<毫秒>)`）。
    QTRY_VERIFY_WITH_TIMEOUT(nam->findChildren<QNetworkReply*>().isEmpty(), 5000);
}

// 非引入方的明文待命心跳：记账照做，但**不得**喂标准解析器（2026-11-10 用户复现）。
// 用户现象：qgc1（航线监控员）在 PX4 重启后"向 PX4 请求参数、弹围栏/集结点错误"。
// 根因不是上行没被拦（拦住了），而是明文心跳建出了 Vehicle → InitialConnectStateMachine
// 自动发起任务/围栏/集结点下载 → 全部被 Standby 丢弃 → 重试耗尽 → 三连弹窗。
void MAVLinkCryptoFrameTest::_testNonIntroducerPlaintextHeartbeatDoesNotBuildVehicle()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    // 阳性对照会建出第二架车，QGC 原生会弹"已连接到载具 N"（上游行为，见 c-connected-veh-popup）。
    // strict mode 下未预期日志＝失败，故只忽略这一条；别顺手把整个 category 静音。
    ignoreLogMessage("API.QGCApplication.AppMessage", QtDebugMsg, QRegularExpression("已连接到载具"));

    _connectMockLinkNoInitialConnectSequence();
    _mockLink->setCommLost(true);

    // 过接收权限闸（名册并集），但**不**进引入名单。
    crypto->deviceKeyManager()->setServerUrl(QString());
    crypto->addLinkedDevice(kNonIntroducerDeviceID);
    QVERIFY2(crypto->isDeviceAuthorized(kNonIntroducerDeviceID), "前置：必须过权限闸，否则测的是权限闸而不是引入权");

    // 本文件此前从未推过责任方/引入名单 ⇒ 显式设成"责任方 + 有效空名单"。
    // 这一臂的判别力全在 `setIntroducerDevices({})`：它是 fail-closed 的有效空集，
    // 与"从未推送过"（fail-open）必须区分开。
    crypto->setResponsibleParty(true);
    crypto->setIntroducerDevices(QVariantList{});
    QVERIFY2(!crypto->isIntroducerFor(kNonIntroducerDeviceID), "前置：本端此刻必须是该机的非引入方");

    const int countBefore = MultiVehicleManager::instance()->vehicles()->count();
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kNonIntroducerSysId, kNonIntroducerCompId));
    QCOMPARE(MultiVehicleManager::instance()->vehicles()->count(), countBefore);

    // 阳性对照：同一帧、同一 deviceID，只把引入名单放行 ⇒ 必须建出车辆。
    // 没有这一臂，"不建"可能只是因为帧本身建不出车（心跳字段/授权/解析路径任一处坏了），
    // 那样断言恒真、零判别力。
    crypto->setIntroducerDevices(QVariantList{ static_cast<uint>(kNonIntroducerDeviceID) });
    QVERIFY2(crypto->isIntroducerFor(kNonIntroducerDeviceID), "前置：阳性对照必须由引入方发起");
    _injectWithCryptoEnabled(plaintextHeartbeatFrame(kNonIntroducerSysId, kNonIntroducerCompId));
    QCOMPARE(MultiVehicleManager::instance()->vehicles()->count(), countBefore + 1);

    // 复原：本用例是文件里最后一个，但责任方/名单是进程级状态，不能留给 cleanupTestCase。
    crypto->setIntroducerDevices(QVariantList{});
    crypto->setResponsibleParty(false);
}

UT_REGISTER_TEST(MAVLinkCryptoFrameTest, TestLabel::Integration, TestLabel::Comms)
