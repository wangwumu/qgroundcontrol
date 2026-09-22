#pragma once

/// QGC 端加密链路握手状态机（依据 `docs/10_deviceID与payload加密公共规范.md` §2.5/§2.6 与第三部分「QGC 地面站」契约）。
///
/// 职责：
/// - 状态机：待命(Standby) → 建链中(Linking) → 正常(Active) → 回待命；
/// - counter 管理：QGC 发送用**奇数**，起点按三档选取（见 `nextOutgoingCounter()`）——
///   ① 本设备上行水位在 → 取其最小奇数后继；② 上行缺失但下行水位在（QGC 重启恢复，
///   规范 §3.2.4.2）→ 取下行最大值 Y 的奇数后继 Y+1；③ 两者皆无 → 加密安全随机 62 位
///   奇数（规范 §2.5）；
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
    /// - 空列表 = "没有清单" ⇒ `_sendRegistration` 回退到 `_linkedDevices` 全体。
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

    /// 当前监控清单的条数（0 = 无清单，回退 `_linkedDevices`）。
    /// 供测试与诊断读——`_monitorDevices` 本身是 private。
    int monitorDeviceCount() const;

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

    /// 任务建链：选定目标无人机，取密钥，进入 Linking。
    /// 由上层在「确定航线 + 选定无人机」时调用。
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
    /// 起点选取：上行水位在 → 严格大于它的最小奇数（运行期 +2 节拍）；上行水位缺失
    /// 但下行水位在 → 下行最大值 Y 的奇数后继 Y+1（QGC 重启恢复，规范 §3.2.4.2）；
    /// 两者都无 → 加密安全随机 62 位奇数（规范 §2.5 的建链首帧规则，同时也覆盖
    /// 「本进程尚未提交过任何下行」的情形）。
    /// 仅 Active 状态可调用。第二档在下行 counter 越界时拒发（守卫在算式之前）。
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
    /// 「需要监控的飞机」的 deviceID 列表（§3.5.3）。
    /// 空 = 没有清单 ⇒ `_sendRegistration` 回退到 `_linkedDevices`。
    QList<DeviceID> _monitorDevices;
    /// 本次生效的超时阈值（毫秒）。与 `_monitorDevices` 同一次调用更新。
    int _frameTimeoutMs = DEFAULT_FRAME_TIMEOUT_MS;
    /// 分批发送的游标（§3.3），跨两次 `_sendRegistration()` 保持。
    int _regCursor = 0;
    QTimer* _linkLossTimer = nullptr; ///< PX4 失联检测定时器
    DeviceID _linkLossDevice = kInvalidDeviceID; ///< 正在监测失联的活跃 deviceID
    mutable QMutex _mutex;
};

} // namespace MAVLinkCrypto
