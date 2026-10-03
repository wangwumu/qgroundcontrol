#pragma once

/// QGC 端加密链路握手状态机（依据 `docs/10_deviceID与payload加密公共规范.md` §2.5/§2.6 与第三部分「QGC 地面站」契约）。
///
/// 职责：
/// - 状态机：待命(Standby) → 建链中(Linking) → 正常(Active) → 回待命；
/// - counter 管理：QGC 发送用**奇数**，起点按两档选取（见 `nextOutgoingCounter()`）——
///   ① 上行或下行水位有其一 → 取其 **max** 的奇数后继（正常情形下行恒领先，结果即
///   `Y+1`，与规范 §3.2.4.2 的重启恢复规则同形；两台 QGC 据此同源，2026-09-27 用户
///   裁定合并原档①/档②）；② 两者皆无 → 加密安全随机 62 位奇数（规范 §2.5）；
/// - 防重放：按 deviceID + 方向（上行/下行）**分别**维护 lastNonce，`本次 > lastNonce` 才接受；
/// - 密钥：经 DeviceKeyManager 获取，本控制器持有一个「活跃目标 deviceID + 密钥」。
///
/// 本模块为**状态与 counter 管理核心**；收发 hook 由 LinkInterface/MAVLinkProtocol 接线调用。
/// 线程安全：状态/映射由本类 `_mutex` 保护，lastNonce 由 ReplayGuard 内部锁保护。两者存在
/// **嵌套**（本类持 `_mutex` 时调 `ReplayGuard::peek*` / `accept`），锁序单向
/// （CryptoController → ReplayGuard）故无死锁；接收路径经 Qt::AutoConnection 排队，
/// 在主线程串行执行。

#include <QtCore/QElapsedTimer>
#include <QtCore/QHash>
#include <QtCore/QList>
#include <QtCore/QMutex>
#include <QtCore/QMutexLocker>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>

#include "DeviceID.h"
#include "DeviceKeyManager.h"
#include "MAVLinkCrypto.h"
#include "ReplayGuard.h"

namespace MAVLinkCrypto {

class CryptoController : public QObject
{
    Q_OBJECT

public:
    enum class State {
        Standby, ///< 待命：只读（解密遥测），不建链、不发指令
        Linking, ///< 建链中：已选定目标、取密钥中/已就绪；密钥就绪后自动进入 Active
        Active,  ///< 正常：可加密下发指令
    };
    Q_ENUM(State)

    /// 80005 登记心跳默认周期（毫秒）。规范 §3.2/附录 A：`GCS_KEEPALIVE_INTERVAL`
    /// 须远小于 mavp2p 的 MAP_TTL 且小于 NAT UDP idle timeout。默认 10s。
    static constexpr int kRegistrationIntervalMs = 10000;
    /// PX4 失联报警默认超时（毫秒，规范附录 A LINK_LOSS_TIMEOUT：心跳周期×3~5，典型 5s）。
    static constexpr int kLinkLossTimeoutMs = 5000;

    explicit CryptoController(QObject* parent = nullptr);
    ~CryptoController() override;

    CryptoController(const CryptoController&) = delete;
    CryptoController& operator=(const CryptoController&) = delete;

    /// 全局单例访问点（收发链路均通过它访问加密状态）。
    static CryptoController* instance();

    /// 本端 GCS 的 deviceID。
    void setGcsDeviceID(DeviceID deviceID);

    /// 是否启用加密链路（由 CryptoSettings 注入）。
    void setCryptoEnabled(bool enabled);
    bool cryptoEnabled() const;

    /// 启用/停用 80005 QGC 登记/保活心跳（明文特例，规范 §2.2/§3.2）。
    /// 启用后按 `GCS_KEEPALIVE_INTERVAL` 周期向 mavp2p 发 80005。
    /// @param enabled  是否启用（由 CryptoSettings 注入）
    /// @param intervalMs  保活周期（毫秒，默认见 `kRegistrationIntervalMs`）
    void setRegistrationEnabled(bool enabled, int intervalMs = kRegistrationIntervalMs);
    bool registrationEnabled() const;

    /// 超时阈值的编译期兜底（§3.6.4）。
    /// 对应 1Hz 发帧频率，是**保守**选择：20Hz 下偏慢（晚 1s 才发现），
    /// 但任何频率 ≥ 1Hz 都不会误判。
    /// ⚠️ 主路径必须是后端下发：若后端不下发、而 PX4 又降到了 0.2Hz 以下，
    ///    这个默认值会误判（每 3s 重发一次，而飞机 5s 才发一帧）。
    static constexpr int DEFAULT_FRAME_TIMEOUT_MS = 3000;

    /// 由 `RomView.qml` 在**每次成功轮询**后调用（§3.5.3）：
    /// 传入"需要监控的飞机"的 deviceID 列表，以及本次生效的超时阈值（毫秒）。
    ///
    /// - **本函数被调用过** = 有一份清单生效（`_monitorListActive = true`），此后
    ///   `_sendRegistration` 一律按 `_monitorDevices` 取列表；**空清单也是有效清单**
    ///   （发 num=0 的登记帧，语义是"本 GCS 在线、暂不关联任何 PX4"）。
    /// - 只有**从未成功推送过清单**时（`_monitorListActive == false`：站点视图、
    ///   未登录、首拉未回）才回退到 `_linkedDevices` 全体。
    ///   ‼️ 早先的实现拿 `_monitorDevices.isEmpty()` 兼作这个判据，把"成功的空清单"
    ///   与"从没有过清单"混成了一格：前者被静默读成后者 ⇒ 取列表口径翻回
    ///   `_linkedDevices` 全体 ⇒ 签出释出（`releaseDevice` 摘空清单之后）当场失效，
    ///   那架飞机又被重新登记回去。
    /// - `frameTimeoutMs <= 0` ⇒ 用 `DEFAULT_FRAME_TIMEOUT_MS`。
    /// - 集合**内容变化**时立即跑一轮加速发送（§3.4）；
    ///   内容不变则什么都不做——2s 轮询会反复调用本函数，
    ///   若每次都加速，10s 保活周期会被打乱。
    ///
    /// ‼️ **轮询失败时不要调用本函数**（保留上一次的清单）。
    ///    把"请求失败"当成"没有需要监控的飞机"会让登记集合清空，
    ///    全部飞机在 60s TTL 后集体掉线，而失败原因可能只是一次网络抖动（§3.5.4）。
    ///
    /// ‼️ 阈值与清单**必须同一次调用传入**：拆成两个 setter 会造出
    ///    "新阈值配旧清单"的中间态（§3.6.4）。
    Q_INVOKABLE void setMonitorDevices(const QVariantList& deviceIds, int frameTimeoutMs);

    /// 当前生效的超时阈值（毫秒）。
    int frameTimeoutMs() const;

    /// 当前监控清单的条数。
    /// ⚠️ **0 不等于"没有清单"**——清单有没有生效看 `monitorListActiveForTest()`：
    ///    "生效的 0 条"与"从未推送过"在取列表口径上是两回事。
    /// 供测试与诊断读——`_monitorDevices` 本身是 private。
    int monitorDeviceCount() const;

    /// 立即跑一轮加速登记（§3.4）：连续 `ceil(n/16)` 次发送、批间隔
    /// `kRegistrationBurstIntervalMs`，让新集合在**秒级**内全部接上，
    /// 而不是等 `batches × 10s` 的游标周期。
    /// `n` = 这一轮真正要发的 deviceID 总数，与 `_sendRegistration()` 取列表的口径一致
    /// （含"`_activeDeviceID` 有效且不在清单里 ⇒ 追加一个"）；批数封顶见
    /// `kMaxRegistrationBatches`。
    ///
    /// 触发点两处：① `setMonitorDevices` 检测到集合变化；② 登录成功后
    /// `AuthController` 通知（`_linkedDevices` 刚被填充）。
    ///
    /// ⚠️ **不要把它接到 2s 轮询上**——那会打乱 10s 保活周期。
    /// ⚠️ 集合没变时反复调用它最多多花几帧，不改集合、不改变行为方向。
    /// ⚠️ 闸的落点分两类：
    ///    ① **C++ 内部调用**：闸一律在**调用方**——本函数自带 `registrationEnabled()` 门，
    ///       而 `_sendRegistration()` 与 `_sendRegistrationFrame()` **两个都没有**
    ///       （前者零 `return`、只有取批 + 发帧；后者只管计数 + 组帧 + 发。都假定调用方已把好关）。
    ///       新增 C++ 调用点时必须自己带门判断。
    ///    ② **QML 可达的入口（`Q_INVOKABLE`）不能依赖"闸在调用方"**：QML 是外部调用方，
    ///       而 `registrationEnabled()` **不是** `Q_INVOKABLE` ⇒ QML 物理上查不到闸的状态，
    ///       没法自己把门。故闸必须落在**这条路径上 QML 触不到的那一层**：
    ///       - `reRegisterDevice()` **自己就发送** ⇒ 门在它自己身上（见其声明处）；
    ///       - `setMonitorDevices()` **自己不发送**，发送发生在它触发的
    ///         `requestAcceleratedRegistration()` 里 ⇒ 门在那个**被调方**，本函数不带门。
    ///       ⇒ 判据不是"入口是不是 `Q_INVOKABLE`"，而是"从入口到发送这条链上至少有一层带门"。
    Q_INVOKABLE void requestAcceleratedRegistration();

    /// 对单个 deviceID 立即发一个**只含它**的 80005 报文（§3.6.2 的"定向加速重发"）。
    ///
    /// 由 `RomView.qml` 在每 2s 的轮询节拍上、对 `msSinceLastFrame(id)` 超过
    /// 生效阈值（`frameTimeoutMs()`）的飞机调用。mavp2p 收到后只做**幂等刷新**
    /// （`m.pairs[k] = e; e.lastSeen = now`），不触碰任何其它 pair、不断开已建立的链路。
    ///
    /// ‼️ **只重发，绝不移出登记集合**（`_monitorDevices` / `_regCursor` 一概不碰）——
    ///    移出会让它更收不到帧 ⇒ 下一轮又超时 ⇒ **永久静默失效**，且日志上看不出
    ///    任何异常。代价是幂等的：单架报文的 MAVLink 帧 = 10 字节帧头 + 5 字节 payload
    ///    （`CryptoTest::_testQgcRegistration` 断言 `msg.len == 5`）+ 2 字节 CRC = **17 字节**
    ///    （未签名；启用 MAVLink 签名时再加 13 字节）
    ///    ⇒ **误判的代价是一个 17 字节的帧**。
    ///
    /// ‼️ **自带 `registrationEnabled()` 门**（先校验参数、再校验状态 ⇒ 非法 deviceID 的
    ///    告警在关门时照常打）。门必须落在**被调用方**：本函数是 `Q_INVOKABLE`，而
    ///    `registrationEnabled()` **不是** ⇒ QML 调用点（`RomView.qml` 的 2s 节拍）物理上
    ///    查不到闸的状态，"闸在调用方"这条原则对它根本不成立。
    ///    缺门的后果（P5 终审 I-1）：crypto 关闭 ⇒ `_registrationEnabled` 恒 false、周期定时器
    ///    也停着 ⇒ 本函数成为 80005 的**唯一**发送方，而明文路径上没有 `noteDeviceFrame` 埋点
    ///    ⇒ `msSinceLastFrame()` 恒 -1 ⇒ QML 判据恒真 ⇒ 每 2s 对清单里每架发一次，
    ///    永不停止、无退避、无日志。
    /// ⚠️ 设门**不削兜底**：设计文档（`航线监控员主界面设计-20260922.md` §3.6.3 场景表第 5 行）
    ///    要的是「`_sendRegistration` 因故停摆 ⇒ 全部飞机超时 ⇒ 全部重发」，而轮转停摆在生产
    ///    代码里的唯一成因就是 `setRegistrationEnabled(false)`（它停掉周期定时器）——那恰恰是
    ///    "用户要求不发"，不是"意外停摆"。登记**开着**而轮转意外没发时门是开的，
    ///    超时检查照常兜底：这正是要保留的语义。
    ///    （对照：`_sendRegistration()` / `_sendRegistrationFrame()` 仍然都没有门——它们只被
    ///    C++ 内部调用，闸在调用方；见 `requestAcceleratedRegistration()` 的注释。）
    Q_INVOKABLE void reRegisterDevice(quint32 deviceID);

    /// ---- 仅供单测（生产代码不得调用）----
    /// **发送帧**的累计次数（计的是 `_sendRegistrationFrame()` 进入次数，
    /// 含组帧失败后早退的那一次）。单测里没有 UDP link，发送本身观察不到，
    /// 只能数"帧组了几次"。
    /// ‼️ 不是 `_sendRegistration()` 被调用过的次数——定向重发 `reRegisterDevice()`
    ///    绕过 `_sendRegistration()` 直调 `_sendRegistrationFrame()`，同样计入。
    /// ‼️ 不要用 `_regCursor` 代替：n ≤ 16 时它恒 0，n > 16 时跑满一个周期它会回绕到 0。
    int registrationSendCountForTest() const;

    /// 当前监控清单的**内容**副本。`monitorDeviceCount()` 只给条数，
    /// 区分不了 `{a}` 与 `{b}`。供测试断言清单本身。
    QList<DeviceID> monitorDevicesForTest() const;

    /// 监控清单是否**已生效**（`setMonitorDevices` 至少成功推送过一次）。
    /// 与 `monitorDeviceCount()` 分开读：0 条**生效的**清单 ≠ 没有清单——取列表口径不同
    /// （`_monitorListActive ? _monitorDevices : _linkedDevices`）。
    bool monitorListActiveForTest() const;

    /// 失联监测是否正在运行（`_linkLossTimer` 存在且 `isActive()`）。
    /// 供测试钉住「让位释出」与「切换活跃目标」都会把它停掉（两处漏停都会在 5s 后对一架
    /// **已不再被关心**的飞机发 `px4LinkLost` 假告警）。
    /// ‼️ `_startLinkLossMonitor` 的第一道门是 `_cryptoEnabled`，其缺省为 false ⇒
    ///    **用例必须先 `setCryptoEnabled(true)` 才有判别力**；否则定时器从不启动、
    ///    `_stopLinkLossMonitor()` 退化成纯 no-op，删掉调用点也全绿。
    bool linkLossMonitorActiveForTest() const;

    /// 最近一次进入 `_sendRegistrationFrame()` 时**实际装入帧**的 deviceID 序列
    /// （已按 `MAX_QGC_LINKED_PX4` 截断，口径与 `deviceBytes` 循环一致）。
    /// `registrationSendCountForTest()` 只数"发了几帧"，区分不了"帧里装的是 a 还是 b"
    /// —— 定向重发的判据必须落在**内容**上：一个"发了一帧、但帧里装的是别人"的实现，
    /// 能同时骗过计数与集合两格。
    /// ⚠️ 组帧失败（`packLen == 0`）早退前就已记录：口径是"这一帧打算装什么"，
    ///    与 `registrationSendCountForTest()` 一致（它也把失败那一次计进去）。
    QList<DeviceID> lastRegistrationPayloadForTest() const;

    /// 从 `devices` 的 `cursor` 位置起取至多 `batch` 个（环形回绕），
    /// 并把 `cursor` 就地推进到**下一批的起点**（§3.3）。
    ///
    /// 语义：把 n 架切成 ceil(n/batch) 批，每批 ≤ batch
    /// （n=18、batch=16 ⇒ 批次大小依次 16、2、16、2…）。
    /// ⚠️ 不是"每次取满 batch 个的滑窗"——那样每批恒为 16 个，第二批会白白多带
    ///    14 个 deviceID（56 字节），且与 §9.2 的实测判据不符。
    ///
    /// n ≤ batch 时退化为「一批全取、游标恒 0」，与改动前行为完全一致。
    ///
    /// @pre ‼️ **`batch <= MAX_QGC_LINKED_PX4`（当前 16）——这条由调用方保证，不是本函数保证。**
    ///    本函数**只保证「返回值 ≤ batch」，不做上限裁剪**——它是纯函数，不知道 80005
    ///    登记报文的 payload 容量。`batch > 16` 时它会照常返回那么多元素。
    ///    （`batch <= 0` 不是违约：按空批处理并把游标归零，见下。）
    ///
    ///    违约后果（**静默覆盖缺口，不是内存越界**）：游标按本轮取出量推进（尾批小于 `batch`），而 payload
    ///    只装得下 `MAX_QGC_LINKED_PX4` 个 ⇒ 传 `batch = 60` 时，每轮丢掉本轮取出的、超出 16 个的那部分
    ///    （整批 = `batch - 16`，尾批更少），这些 id 此后任何一轮都不会再出现（无日志、无断言、不报错）。
    ///    它是**内容**错误：飞机登记不上，而链路看上去一切正常。
    ///
    ///    ⚠️ **不会**越界写：发送侧 `_sendRegistrationFrame()` 的
    ///    `qMin(ids.size(), MAX_QGC_LINKED_PX4)` 是**真实存在的运行期兜底**，
    ///    `deviceCount` 恒 ≤ 16、最大写索引 63 < 64。故「`deviceBytes` 定长、
    ///    构造上不会越界」这条论证由**发送侧自身**保证。接线时（Task 4）把 `batch`
    ///    钉在 `MAX_QGC_LINKED_PX4`，是为了**覆盖性**（每个 id 都被登记到），
    ///    不是为了避免内存错误——别因为"反正有 qMin 兜底"就把 `batch` 调大。
    ///
    /// 抽成 public static 纯函数是为了单测：`_sendRegistration()` 的发送路径依赖
    /// `LinkManager`（单测里无 UDP link），无法观察它实际发了什么。
    static QList<DeviceID> nextRegistrationBatch(const QList<DeviceID>& devices, int batch, int& cursor);

    /// 声明本 QGC 关联的 PX4 deviceID（加入登记心跳 payload）。
    /// 单设备场景：建链目标 deviceID 即关联对象。
    void addLinkedDevice(DeviceID deviceID);

    /// 撤销一条关联（从登记心跳 payload 里移除该 deviceID）。
    /// ⚠️ 只有**逐条撤销**这一档，**没有 `clear()`**：本集合的语义是"本 GCS 还关联哪些
    ///    飞机"，上层（`releaseDevice`）按签出事件一架一架地撤；一个"清空全部"的入口
    ///    会把一次误判放大成整个站点掉线（mavp2p 侧全部配对在 `MAP_TTL` 后过期）。
    /// @return true=该 deviceID 原本在集合里，已移除；false=本来就不在（幂等）
    bool removeLinkedDevice(DeviceID deviceID);

    /// **签出释出**：某架飞机签出后，本站在本地交还关于它的一切。
    ///
    /// 由站点视图（`OpsShell.qml`）在轮询 diff 检出"某架飞机已离开本站任务列表"时调用。
    /// 时机判据（本端能观测到的确证签出）：该行离开 `view=site` ⟺ 监控员已 ACCEPT 该移交
    /// （见 `ops-view-visibility-two-branches`）。**请求失败与空响应都不构成调用理由**
    /// ——QML 侧只对"200 且是数组"的响应做 diff，且初值与空集合同形（见 QML 里的注释）。
    ///
    /// ⓪ 前置**成员资格闸**（2026-10-04 补）：本端关于这架飞机没有任何本地状态
    ///   （不在 `_linkedDevices`、不在 `_monitorDevices`、没占 `_activeDeviceID`、本地无密钥）
    ///   时告警并早退，不做下面四件事。⚠️ 今天它**不改任何可达行为**（那样的 id 上四件事本就
    ///   全是空操作），挡的是将来新增的破坏性步骤；理由与残留假设见 .cc 内的实现注释。
    ///
    /// 四件事，缺一不可（2026-10-03 用户裁定「上下全清」）：
    ///   ① 移出登记集合 —— 不再为它发 80005；mavp2p 的配对随后在 `MAP_TTL` 后过期；
    ///      此后要重新接引，走那条明文待命心跳的老路即可（mavp2p 重新建配对）。
    ///      ⚠️ 实现上是**内联** `_linkedDevices.removeAll(id)`，**不是**调上面那个
    ///      `removeLinkedDevice`——后者自己加 `_mutex`，而本函数在调用点已持锁
    ///      （`QMutex` 非递归）⇒ 调它会自死锁。两处做的是同一件事，只是不共函数。
    ///   ①b **同时**从监控清单 `_monitorDevices` 摘除，并把轮转游标 `_regCursor` 归零
    ///      （同为"移出登记集合"，只是第二个容器）。站点流程下 `_sendRegistration` 实际
    ///      读的就是这一份；不摘的话，一份**刻意保留**的陈旧清单（§3.5.4：poll 失败时
    ///      保留上一份清单）会一直把已释出的飞机登记下去。
    ///   ② `removeKey` —— 删掉本地密钥；
    ///   ③ `resetReplay` —— 上行与下行水位**一并清空**；
    ///   ④ 若它正占着上行权（`_activeDeviceID`），当场让出并回 Standby。
    ///
    /// ‼️ ②③ 必须**同批**，这不是"顺手多清一个"，理由是一条因果链：
    ///    水位清空后，本端下一次建链走 `nextOutgoingCounter()` 的**随机奇起点**档
    ///    （`hasUp || hasDown` 皆假 ⇒ `else` 支）。随机起点要**必被接受**，前提是 PX4 侧
    ///    两个方向的水位皆 unset——它们都是**全局标量**
    ///    （`mavlink_crypto.h`，注释逐字 `(received frames, global)`；`_tx_last_nonce_set == false`
    ///    就是 standby），与"有几台 QGC 连着它"无关。
    ///    ⚠️ **"回到待命那一刻软重置"是设计依赖、当前并未实现**：PX4 树里
    ///    `_rx_last_nonce_set` / `_tx_last_nonce_set` **从无 `= false` 赋值**（只有置 true 两处），
    ///    规范 §2.9「断连机制（任务完成 / 解绑）」标题逐字写着「设计已定，待实现」。
    ///    今天「从明文待命心跳重新接引是安全的」实际靠的是**开机时两标量皆 unset** 这一偶然前提。
    ///    ⚠️ 且"收到明文待命心跳"与"上行水位已清"**不是同一个标量**：心跳的发出条件是
    ///    `!_tx_last_nonce_set`，而能否接受我方首帧取决于 `_rx_last_nonce`；两者只在收到
    ///    **奇数**上行时才同时置位 ⇒ 二者可分离，不能当"同义信号"用。
    ///    ⚠️ 但另有两个建链入口**不**经过待命心跳：`MAVLinkProtocol.cc` 的两处自动建链
    ///    （收到该 deviceID 的帧即 `beginLinking`）。它们的闸是
    ///    `state() == Standby && hasKey(deviceID)`——飞机还在航线上飞时，PX4 的
    ///    `_rx_last_nonce` 仍是上一台发指令的 QGC 推到的旧值，此时照随机档发首帧**可能**被
    ///    丢弃（PX4 侧是**单向**阈值 `counter > _rx_last_nonce`、无跳变上限、也不回错；
    ///    随机起点高于残留水位时仍会被接受，故是概率而非必然）。
    ///    ⇒ **只清水位不删密钥，等于亲手开了这个缺口**；两件事必须一起做。
    ///    （关掉那两个入口的可操作手段**就是**删密钥——闸的另一半 `state` 不由本端控制。）
    ///    ⚠️ 代价（已知、可接受）：重新接引要多一个 `fetchKey` 往返——`beginLinking` 在
    ///    `hasKey` 未命中时会自动取密钥（见其实现），不是"取不到密钥就卡住"。
    ///
    /// ‼️ ④ 的守卫是**必须**的：`_activeDeviceID` 是单槽，它可能正属于**另一架**飞机。
    ///    无条件回 Standby 会把在飞那架的链路一起打掉。
    ///
    /// ⚠️ `_lastFrameMs` 与 `_deviceToSystem`/`_systemToDevice` **刻意不动**：前者没有清理
    ///    时机判据（见其声明处）；后者是学习表、重建时会覆盖，且删掉会让
    ///    `beginLinkingForSystemID` 在这架飞机上失效。两张表都不含 nonce，不在本次裁定范围内。
    /// @param deviceID  要释出的 PX4 deviceID
    Q_INVOKABLE void releaseDevice(quint32 deviceID);

    /// 设备密钥管理器（从 gcs_server 取密钥）。
    DeviceKeyManager* deviceKeyManager() { return &_keyManager; }

    /// 调试注入：从本地 key 文件读取 32 字节 AES-256 密钥并缓存到指定 deviceID。
    /// 用于绕过 gcs_server 的本地联调（QGC ↔ PX4 直连调通加密协议）。
    /// @param path       key 文件路径（须为恰好 32 字节原始密钥）
    /// @param deviceID   目标无人机 deviceID（应与 PX4 侧 MAV_DEVICE_ID 一致）
    /// @return true=读取并注入成功；false=文件不存在/长度错误/注入失败
    bool injectLocalKeyFromFile(const QString& path, DeviceID deviceID);

    /// 当前状态（线程安全，加锁读取）。
    State state() const;

    /// 本端 GCS 的 deviceID（线程安全，加锁读取）。
    DeviceID gcsDeviceID() const;

    /// 当前建链的目标无人机 deviceID（无任务时为 kInvalidDeviceID）。
    DeviceID activeDeviceID() const;

    /// 当前目标设备的通信密钥是否已就绪。
    bool hasActiveKey() const;

    /// 取当前目标设备的密钥。
    /// @return true=成功，outKey 填充；false=无活跃设备或密钥未就绪
    bool activeKey(Key& outKey) const;

    // -----------------------------------------------------------------------
    // 握手流程
    // -----------------------------------------------------------------------

    /// 责任方（站点操作员）标志：**只有责任方的 QGC 允许建链**，其余身份（航线监控员、
    /// 飞行安全监理）停在 Standby——即 State::Standby 的定义「只读（解密遥测），不建链、
    /// 不发指令」。三个建链入口全部汇聚到 beginLinking，这一处闸就覆盖了任务/围栏/集结点/
    /// 参数/心跳的全部上行（LinkInterface 对非 Active 直接 drop），而接收/解密路径不看
    /// state ⇒ 非责任方仍照常收到遥测，是"只读监视"而不是"断线"。
    ///
    /// 判据是「**含** SITE_ATC」，不是「不含 ROUTE_MONITOR」——后端 roles.go 明确允许
    /// SITE_ATC 与 ROUTE_MONITOR 双身份并存（角色是并集），按后者写会把这类账号误判成
    /// 非责任方。另：站点归属无需在此判断——能走到 beginLinking 就说明该 deviceID 在本站
    /// 集合里（登录时后端已校验 site_id ∈ 用户 role_sites）。
    ///
    /// 缺省 **false**（fail-closed：没被授予就不能发言）。生产路径有三个写入点：
    ///   · AuthController 登录成功 ⇒ setResponsibleParty(roles 含 SITE_ATC)。**无条件覆写**，
    ///     这样即使 ini 里 cryptoKeySource 仍是 0（下面那条写的 true），登录后也以角色为准。
    ///   · AuthController 登录被拒（清 _roles 的那条分支）⇒ setResponsibleParty(false)，
    ///     不能留下上一账号的责任方身份。
    ///   · QGCApplication::init 本地密钥源（cryptoKeySource==0）⇒ setResponsibleParty(true)。
    ///     那是单机联调直连、**根本不登录**（AuthController::standaloneMode 的定义即
    ///     !loggedIn && cryptoKeySource==0），此时本 QGC 是唯一操作者，不存在"谁该发言"之争。
    ///
    /// ⚠️ 本函数**不只是写标志**：收回（false）时会把已建立的链路当场降回 Standby。理由是闸
    /// 只在 beginLinking 的入口检查一次，而 LinkInterface 只看 state()——只翻标志不撤链路，
    /// 闸对"先 Active 后收回"这条路径等于没生效（详见 .cc 内的实现说明）。
    ///
    /// ⚠️ 同时**作废监控清单**（2026-10-04 补）：`_monitorListActive` 回落、`_monitorDevices`
    /// 清空、`_regCursor` 归零。理由：该闩全仓只置不落，而取列表的口径是
    /// `_monitorListActive ? _monitorDevices : _linkedDevices` ⇒ 不在此处作废的话，**跨会话**
    /// 时本端会一直按上一个站点的清单发 80005 登记心跳。本函数是三个会话边界写入点
    /// （登录成功 / 登录被拒 / 本地密钥源初始化）的公共落点，故作废落在这里。
    /// ⚠️ 本仓 QGC **没有登出**，今天这条不可达，是为将来加登出预备的（判定同 .cc）。
    /// ⚠️ `_linkedDevices` **不在**本函数的清理范围：它由 `AuthController` 登录时写入并自管。
    ///
    /// @param responsible true=责任方（可建链）
    void setResponsibleParty(bool responsible);

    /// 当前是否为责任方（线程安全，加锁读取）。
    bool isResponsibleParty() const;

    /// 任务建链：选定目标无人机，取密钥，进入 Linking。
    /// 由上层在「确定航线 + 选定无人机」时调用。
    /// ⚠️ 非责任方调用时**直接返回、状态保持 Standby**（判据见 setResponsibleParty）。
    void beginLinking(DeviceID targetDeviceID);

    /// 按 systemID 触发建链（便捷方法：内部查 deviceID↔systemID 映射）。
    /// 供上层（如 MissionController::sendToVehicle）用 vehicle->id() 触发。
    void beginLinkingForSystemID(uint8_t systemID);

    /// 学习 deviceID ↔ systemID 映射（接收端解密成功后调用）。
    void learnDeviceSystemMapping(DeviceID deviceID, uint8_t systemID);

    /// 记录「收到了该 deviceID 的任意一帧」的时刻（设计文档 §3.6.1）。
    ///
    /// ‼️ 是**任意帧**，不是心跳帧——建链后 PX4 停发明文心跳、改发加密遥测
    /// （`data_writer/writer.go` 的「语义注意」段），只记心跳会让判据在
    /// **接引成功那一刻起永久失效**，表现为每 2s 判一次超时、无限定向重发，
    /// 而链路完全正常、日志上看不出任何异常。
    ///
    /// 由 `MAVLinkProtocol` 在**两个**收帧分支各显式调用一行（明文待命心跳支、
    /// 加密帧支）。**不要**塞进 `learnDeviceSystemMapping` 内部——那个函数的名字
    /// 只承诺"学习映射"，隐式更新时间戳属于名字没体现的行为。
    void noteDeviceFrame(DeviceID deviceID);

    /// 距上次收到该 deviceID 的帧过去了多少毫秒；**-1 = 从未收到**。
    /// 由 `RomView.qml` 在每 2s 的轮询节拍上读取，与生效的阈值比较（§3.6.2）。
    Q_INVOKABLE qint64 msSinceLastFrame(quint32 deviceID) const;

    /// 按 systemID 查 deviceID。
    /// @return true=命中，outDeviceID 填充；false=未学习到映射
    bool deviceIDForSystemID(uint8_t systemID, DeviceID& outDeviceID) const;

    /// 密钥就绪后进入 Active（可下发指令）。
    /// 注意：当前实现把「gcs_server 取密钥成功」视为建链确认，并未等待 PX4 的显式确认报文。
    void confirmLinking();

    /// 建链失败（取密钥失败），回到 Standby。
    void failLinking(const QString& error);

    /// 任务结束 / 断链，回到 Standby（继续只读遥测）。
    void returnToStandby();

    // -----------------------------------------------------------------------
    // counter 管理与防重放
    // -----------------------------------------------------------------------

    /// 取下一个本方向（QGC 奇数）发送 counter，并**原子预留**（更新 lastNonce）。
    /// 起点选取：**max(上行水位, 下行水位) 的奇数后继**——上下行水位皆在时取较大者，
    /// 正常情形下行领先（建链时 DOWNLINK_INIT_OFFSET 给余量）故结果恒为「下行 Y 的
    /// 奇数后继 Y+1」（规范 §3.2.4.2）；下行稀疏、上行领先时取上行，不把水位拉回去。
    /// 两者都无 → 加密安全随机 62 位奇数（规范 §2.5 的建链首帧规则，同时也覆盖
    /// 「本进程尚未提交过任何下行」的情形）。
    /// 仅 Active 状态可调用。水位越界时拒发（守卫在算式之前；实际只有下行能越界，
    /// 上行水位由下方「≥ 2^62 拒发」保证恒 < 2^62）。
    /// @return true=成功，outCounter 填充；false=非 Active 状态，或 counter 越界 /
    ///         预留失败（均已记日志；调用方须丢弃该帧，不得复用 counter）
    bool nextOutgoingCounter(uint64_t& outCounter);

    /// 生成加密安全随机 62 位奇数 counter 起点（规范 §2.5：建链首帧用随机起点，
    /// 避免重启后从 1 重来导致同一密钥下 nonce 复用）。
    /// @return [1, 2^62) 内的奇数
    static uint64_t randomOddCounter();

    /// 接收帧防重放「判定」（协议 §2.6 第 3 步）：counter > lastNonce[deviceID]？
    /// 纯检查，不更新状态。@return true=可接受；false=重放/乱序
    bool isIncomingAcceptable(DeviceID deviceID, uint64_t counter) const;

    /// 接收帧防重放「提交」（协议 §2.6 第 9 步）：解密 + tag 认证通过后更新 lastNonce。
    void commitIncoming(DeviceID deviceID, uint64_t counter);

    /// 重置指定设备的 lastNonce（如建链时清历史）。
    void resetReplay(DeviceID deviceID);

    /// 设置 PX4 失联报警超时（规范附录 A LINK_LOSS_TIMEOUT，默认见 kLinkLossTimeoutMs）。
    /// 启用加密时生效：收到活跃 PX4 下行报文重置计时器，超时未收到则发 px4LinkLost 信号。
    void setLinkLossTimeout(int timeoutMs);

signals:
    void stateChanged();
    void linkingConfirmed(DeviceID deviceID);
    void linkingFailed(DeviceID deviceID, const QString& error);
    /// PX4 失联：linkLossTimeoutMs 内未收到该 deviceID 的任何下行（含心跳）。
    /// 由上层（如 QGCApplication）连接做 UI 弹窗告警。
    void px4LinkLost(DeviceID deviceID);

private:
    /// 加速发送的批间隔（§3.4：批间隔 ~200ms，用一次性定时器串，不阻塞主线程）。
    static constexpr int kRegistrationBurstIntervalMs = 200;
    /// 加速发送的批数上限，与 §3.4 的容量约束同源（batches ≤ 5 ⇔ n ≤ 80）。
    static constexpr int kMaxRegistrationBatches = 5;

    void _onKeyFetched(DeviceID deviceID);
    void _onFetchFailed(DeviceID deviceID, const QString& error);
    void _sendRegistration(); ///< 发送 80005 登记/保活心跳（周期触发）
    /// 把一批 deviceID 组帧并发出（§3.3 的组帧 + UDP link 过滤 + sent 日志）。
    /// 抽出来是为了让定向重发（`reRegisterDevice`）复用同一套逻辑，
    /// 避免 §3.3 的"定长 deviceBytes"约束出现两个维护点。
    void _sendRegistrationFrame(const QList<DeviceID>& ids);
    void _startLinkLossMonitor(DeviceID deviceID); ///< 启动/重置失联检测（仅 Active 状态）
    void _stopLinkLossMonitor(); ///< 停止失联检测（回待命时）
    void _onLinkLossTimeout(); ///< 失联超时：发 px4LinkLost 信号

    State _state = State::Standby;
    DeviceID _gcsDeviceID = kInvalidDeviceID;
    DeviceID _activeDeviceID = kInvalidDeviceID;
    DeviceKeyManager _keyManager; ///< 密钥管理（内部持有，构造时以 this 为 parent）
    bool _cryptoEnabled = false;
    /// 责任方标志（站点操作员）。缺省 false = fail-closed：没被授予就不能建链。
    /// 写入点见 setResponsibleParty 的文档注释；**不受 returnToStandby 影响**——
    /// 它是"登录会话/运行模式"的属性，不是"本次任务"的属性。
    bool _responsibleParty = false;
    ReplayGuard _replayGuard;
    QHash<DeviceID, uint8_t> _deviceToSystem; ///< deviceID → systemID 映射（接收端学习）
    QHash<uint8_t, DeviceID> _systemToDevice; ///< systemID → deviceID 反向映射
    /// deviceID → 最近一次收帧时 `_frameClock` 的毫秒读数。
    /// ⚠️ 刻意**不做清理**：条目数 = 本进程见过的 deviceID 数（天花板 80），
    ///    内存可忽略；加清理反而引入"清理时机"这个新判据，是净损失。
    QHash<DeviceID, qint64> _lastFrameMs;
    /// `_lastFrameMs` 的时间基准。单调、不受系统时钟调整影响。
    QElapsedTimer _frameClock;
    QTimer* _registrationTimer = nullptr; ///< 80005 周期发送定时器
    bool _registrationEnabled = false;
    QList<DeviceID> _linkedDevices; ///< 本 QGC 关联的 PX4 deviceID（登记心跳 payload）
    /// 「需要监控的飞机」的 deviceID 列表（§3.5.3）。**条数可以是 0**——
    /// "这份清单有没有生效"由 `_monitorListActive` 回答，不由本容器的空否回答。
    QList<DeviceID> _monitorDevices;
    /// 监控清单是否已生效（`setMonitorDevices` 至少成功推送过一次）。缺省 false = 从未有过清单。
    /// ‼️ 取列表的口径是 `_monitorListActive ? _monitorDevices : _linkedDevices`，
    ///    **不是** `_monitorDevices.isEmpty() ? …`——后者会把"成功的空清单"读成"没有清单"，
    ///    让签出释出（`releaseDevice` 摘空清单之后）当场失效、飞机被重新登记回去。
    bool _monitorListActive = false;
    /// 本次生效的超时阈值（毫秒）。与 `_monitorDevices` 同一次调用更新。
    int _frameTimeoutMs = DEFAULT_FRAME_TIMEOUT_MS;
    /// 分批发送的游标（§3.3），跨两次 `_sendRegistration()` 保持。
    int _regCursor = 0;
    int _registrationSendCount = 0; ///< 单测用的发送计数，见 registrationSendCountForTest()
    /// 单测用的"上一帧装了什么"，见 lastRegistrationPayloadForTest()。
    QList<DeviceID> _lastRegistrationPayload;
    QTimer* _linkLossTimer = nullptr; ///< PX4 失联检测定时器
    DeviceID _linkLossDevice = kInvalidDeviceID; ///< 正在监测失联的活跃 deviceID
    mutable QMutex _mutex;
};

} // namespace MAVLinkCrypto
