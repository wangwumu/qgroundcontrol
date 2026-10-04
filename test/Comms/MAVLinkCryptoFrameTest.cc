#include "MAVLinkCryptoFrameTest.h"

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

UT_REGISTER_TEST(MAVLinkCryptoFrameTest, TestLabel::Integration, TestLabel::Comms)
