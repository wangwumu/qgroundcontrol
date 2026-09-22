#include "CryptoController.h"

#include <algorithm>

#include <openssl/crypto.h>

#include <QtCore/QApplicationStatic>
#include <QtCore/QFile>
#include <QtCore/QLoggingCategory>
#include <QtCore/QRandomGenerator>

#include "Comms/LinkInterface.h"
#include "Comms/LinkManager.h"
#include "Extensions/VTOLSafetyMessages.h"
#include "QGCLoggingCategory.h"

QGC_LOGGING_CATEGORY(CryptoControllerLog, "MAVLink.Crypto.CryptoController")

namespace MAVLinkCrypto {

Q_APPLICATION_STATIC(CryptoController, _cryptoControllerInstance);

CryptoController* CryptoController::instance()
{
    return _cryptoControllerInstance();
}

CryptoController::CryptoController(QObject* parent)
    : QObject(parent)
    , _keyManager(this)
{
    _frameClock.start();
    connect(&_keyManager, &DeviceKeyManager::keyFetched, this, &CryptoController::_onKeyFetched);
    connect(&_keyManager, &DeviceKeyManager::fetchFailed, this, &CryptoController::_onFetchFailed);
}

CryptoController::~CryptoController() = default;

void CryptoController::setGcsDeviceID(DeviceID deviceID)
{
    // 规范 §1.4 硬性约束：incompatFlag bit0 必须为 0，否则标准解析器误判为签名帧
    if (!hasValidSignatureBit(deviceID)) {
        qCWarning(CryptoControllerLog) << "setGcsDeviceID: invalid deviceID (signature bit set)" << deviceID;
        return;
    }
    const QMutexLocker locker(&_mutex);
    _gcsDeviceID = deviceID;
}

bool CryptoController::injectLocalKeyFromFile(const QString& path, DeviceID deviceID)
{
    // 目标 deviceID 合法性校验（规范 §1.4：bit24 必须为 0）
    if (deviceID == kInvalidDeviceID || !hasValidSignatureBit(deviceID)) {
        qCWarning(CryptoControllerLog) << "injectLocalKeyFromFile: invalid deviceID" << deviceID;
        return false;
    }

    QFile keyFile(path);
    if (!keyFile.open(QIODevice::ReadOnly)) {
        qCWarning(CryptoControllerLog) << "injectLocalKeyFromFile: cannot open" << path << keyFile.errorString();
        return false;
    }

    // 先按文件大小校验，避免误放的大文件被整读进内存
    if (keyFile.size() != static_cast<qint64>(kKeySize)) {
        qCWarning(CryptoControllerLog) << "injectLocalKeyFromFile: key file size" << keyFile.size()
                                       << "!= expected" << kKeySize << "for" << path;
        return false;
    }

    QByteArray data = keyFile.read(kKeySize);
    if (data.size() != static_cast<int>(kKeySize)) {
        qCWarning(CryptoControllerLog) << "injectLocalKeyFromFile: read" << data.size()
                                       << "!= expected" << kKeySize << "for" << path;
        return false;
    }

    Key key{};
    std::copy(data.constBegin(), data.constEnd(), key.begin());
    _keyManager.cacheKey(deviceID, key);
    // 擦除栈上密钥副本（密钥已入缓存，由 DeviceKeyManager 管理生命周期）。
    // 用 OPENSSL_cleanse 而非 fill(0)：后者可能被优化器做死存储消除，前者是防优化安全清零。
    OPENSSL_cleanse(key.data(), key.size());
    OPENSSL_cleanse(data.data(), static_cast<size_t>(data.size()));
    qCInfo(CryptoControllerLog) << "injectLocalKeyFromFile: injected local key for device" << deviceID << "from" << path;
    return true;
}

void CryptoController::setCryptoEnabled(bool enabled)
{
    const QMutexLocker locker(&_mutex);
    _cryptoEnabled = enabled;
}

bool CryptoController::cryptoEnabled() const
{
    const QMutexLocker locker(&_mutex);
    return _cryptoEnabled;
}

void CryptoController::setRegistrationEnabled(bool enabled, int intervalMs)
{
    {
        const QMutexLocker locker(&_mutex);
        _registrationEnabled = enabled;
    }

    if (_registrationTimer == nullptr) {
        _registrationTimer = new QTimer(this);
        _registrationTimer->setTimerType(Qt::CoarseTimer);
        connect(_registrationTimer, &QTimer::timeout, this, &CryptoController::_sendRegistration);
    }

    if (enabled) {
        // 上电/启用即发一条（登记），随后周期保活
        _sendRegistration();
        _registrationTimer->start(intervalMs > 0 ? intervalMs : kRegistrationIntervalMs);
        qCDebug(CryptoControllerLog) << "registration enabled, interval" << intervalMs << "ms";
    } else {
        _registrationTimer->stop();
        qCDebug(CryptoControllerLog) << "registration disabled";
    }
}

bool CryptoController::registrationEnabled() const
{
    const QMutexLocker locker(&_mutex);
    return _registrationEnabled;
}

void CryptoController::setMonitorDevices(const QVariantList& deviceIds, int frameTimeoutMs)
{
    QList<DeviceID> parsed;
    parsed.reserve(deviceIds.size());
    for (const QVariant& v : deviceIds) {
        bool ok = false;
        const uint id = v.toUInt(&ok);
        // ⚠️ 与 addLinkedDevice 用**同一组**校验（非 0 + 签名位合法），
        //    保证"能进 _linkedDevices 的就能进 _monitorDevices"，两处口径不漂移。
        if (!ok || id == kInvalidDeviceID || !hasValidSignatureBit(static_cast<DeviceID>(id))) {
            qCWarning(CryptoControllerLog) << "setMonitorDevices: 非法 deviceID，已跳过" << v;
            continue;
        }
        parsed.append(static_cast<DeviceID>(id));
    }

    bool changed = false;
    {
        const QMutexLocker locker(&_mutex);
        _frameTimeoutMs = (frameTimeoutMs > 0) ? frameTimeoutMs : DEFAULT_FRAME_TIMEOUT_MS;
        // ‼️ 判据是"集合内容变了"，不是"被调用了一次"（§3.4）
        changed = (parsed != _monitorDevices);
        if (changed) {
            _monitorDevices = parsed;
            _regCursor = 0;  // 集合变了，旧游标没有意义
        }
    }

    // ‼️ 判据是"集合内容变了"。2s 轮询会反复调用本函数，若每次都加速，
    //    10s 保活周期会被打乱（§3.4）。
    if (changed) {
        requestAcceleratedRegistration();
    }
}

int CryptoController::frameTimeoutMs() const
{
    const QMutexLocker locker(&_mutex);
    return _frameTimeoutMs;
}

int CryptoController::monitorDeviceCount() const
{
    const QMutexLocker locker(&_mutex);
    return _monitorDevices.size();
}

void CryptoController::requestAcceleratedRegistration()
{
    if (!registrationEnabled()) {
        return;  // 未启用登记时不加速（与 _sendRegistration 的门一致）
    }

    int n = 0;
    {
        const QMutexLocker locker(&_mutex);
        n = _monitorDevices.isEmpty() ? _linkedDevices.size() : _monitorDevices.size();
    }

    const int batches = (n <= 0) ? 1 : ((n + MAX_QGC_LINKED_PX4 - 1) / MAX_QGC_LINKED_PX4);
    const int capped = qMin(batches, kMaxRegistrationBatches);
    if (capped < batches) {
        // 容量天花板（§3.4）：越过 n ≤ 80 时稳态本来就保证不了 TTL，
        // 加速发送再多也只是把这一轮塞满。**截断的是批数，不是集合**——
        // 集合永远不动（§3.6.2）。
        qCWarning(CryptoControllerLog) << "监控清单超过容量天花板（n ≤ 80），加速发送已截断"
                                       << n << "架 / 需" << batches << "批";
    }

    // ⚠️ 用 QTimer::singleShot 串，**不要**用 QThread::msleep 或忙等——那会卡 GUI 线程（§3.4）
    for (int i = 0; i < capped; i++) {
        QTimer::singleShot(i * kRegistrationBurstIntervalMs, this, [this]() {
            _sendRegistration();
        });
    }
}

int CryptoController::registrationSendCountForTest() const
{
    const QMutexLocker locker(&_mutex);
    return _registrationSendCount;
}

QList<DeviceID> CryptoController::monitorDevicesForTest() const
{
    const QMutexLocker locker(&_mutex);
    return _monitorDevices;
}

QList<DeviceID> CryptoController::nextRegistrationBatch(const QList<DeviceID>& devices, int batch, int& cursor)
{
    const int n = devices.size();
    if (n <= 0 || batch <= 0) {
        cursor = 0;
        return {};
    }
    // 防御：监控清单缩小后，上一轮留下的游标可能已越界
    if (cursor < 0 || cursor >= n) {
        cursor = 0;
    }
    const int count = qMin(batch, n - cursor);

    QList<DeviceID> out;
    out.reserve(count);
    for (int i = 0; i < count; i++) {
        out.append(devices.at((cursor + i) % n));
    }
    cursor = (cursor + count) % n;
    return out;
}

void CryptoController::addLinkedDevice(DeviceID deviceID)
{
    // 规范 §1.4：PX4 deviceID 的 bit24（incompatFlag bit0）必须为 0
    if (deviceID == kInvalidDeviceID || !hasValidSignatureBit(deviceID)) {
        qCWarning(CryptoControllerLog) << "addLinkedDevice: invalid deviceID" << deviceID;
        return;
    }
    const QMutexLocker locker(&_mutex);
    if (!_linkedDevices.contains(deviceID)) {
        _linkedDevices.append(deviceID);
        qCDebug(CryptoControllerLog) << "linked device added" << deviceID;
    }
}

void CryptoController::_sendRegistration()
{
    {
        // ‼️ 计数必须在任何 return 之前 —— 它数的是"函数被进入了几次"。
        const QMutexLocker locker(&_mutex);
        _registrationSendCount++;
    }
    QList<DeviceID> batch;
    {
        const QMutexLocker locker(&_mutex);
        // §3.5.3：有监控清单时用清单，否则回退 _linkedDevices
        //（未登录 / RomView 未打开 ⇒ 保持现状，零回归）
        QList<DeviceID> devices = _monitorDevices.isEmpty() ? _linkedDevices : _monitorDevices;
        if (_activeDeviceID != kInvalidDeviceID && !devices.contains(_activeDeviceID)) {
            devices.append(_activeDeviceID);
        }
        // §3.3：分批轮转。n ≤ 16 时退化为"一批全取、游标恒 0"，与改动前一致。
        // ‼️ batch 仍须是 MAX_QGC_LINKED_PX4（@pre）。但传更大值**不会越界**——下游 qMin 是真实兜底，
        //    deviceCount 恒 ≤ 16、最大写索引 63 < 64。真实后果是**覆盖性缺口**：游标按本轮取出量推进（尾批小于 batch）
        //    而 payload 只装前 16 个 ⇒ 每轮丢掉本轮取出的、超出 16 个的那部分（整批 = batch-16，尾批更少）。
        batch = nextRegistrationBatch(devices, MAX_QGC_LINKED_PX4, _regCursor);
    }

    // 空批 = 没有关联设备：保持现状，发一个 num=0 的登记告诉 mavp2p "本 GCS 在线"
    _sendRegistrationFrame(batch);
}

void CryptoController::_sendRegistrationFrame(const QList<DeviceID>& ids)
{
    // 帧头 deviceID 用 GCS 段固定值（文档 §1.3 QGC_REGISTRATION_DEVICE_ID_DEFAULT），
    // 由 pack 函数拆入帧头 4 字节（方案 B）。payload 填关联 PX4 deviceID 集合。
    const int deviceCount = qMin(ids.size(), static_cast<int>(MAX_QGC_LINKED_PX4));

    // ⚠️ 定长数组，不是 VLA：`uint8_t deviceBytes[count * 4]` 是 GCC 扩展、
    //    不是标准 C++，MSVC 直接编译失败，本仓是多平台构建（§3.3 关键点 1）。
    //    count 恒 ≤ MAX_QGC_LINKED_PX4，故构造上不会越界。
    uint8_t deviceBytes[MAX_QGC_LINKED_PX4 * 4] = {};
    for (int i = 0; i < deviceCount; i++) {
        const uint32_t dev = ids.at(i);
        deviceBytes[i * 4 + 0] = static_cast<uint8_t>(dev >> 24);
        deviceBytes[i * 4 + 1] = static_cast<uint8_t>(dev >> 16);
        deviceBytes[i * 4 + 2] = static_cast<uint8_t>(dev >> 8);
        deviceBytes[i * 4 + 3] = static_cast<uint8_t>(dev);
    }

    mavlink_message_t message{};
    const uint16_t packLen = mavlink_msg_qgc_registration_pack(QGC_REGISTRATION_DEVICE_ID_DEFAULT, &message,
                                                               deviceCount > 0 ? deviceBytes : nullptr,
                                                               static_cast<uint8_t>(deviceCount));
    if (packLen == 0) {
        qCWarning(CryptoControllerLog) << "registration: pack failed (invalid deviceID), skip";
        return;
    }

    // 遍历已连接 UDP link，明文发送（规范 §2.2/§3.2：80005 仅 mavp2p 消费，
    // 只发广域网 UDP 链路，不发给串口/USB/模拟器等 PX4 直连链路）。
    const auto links = LinkManager::instance()->links();
    bool sent = false;
    for (const auto& link : links) {
        if (!link || !link->isConnected()) {
            continue;
        }
        const auto cfg = link->linkConfiguration();
        if (!cfg || cfg->type() != LinkConfiguration::TypeUdp) {
            continue; // 仅 UDP（mavp2p/广域网）链路
        }
        link->sendPlaintextMessageThreadSafe(message);
        sent = true;
    }
    qCDebug(CryptoControllerLog) << "registration sent, devices" << deviceCount << (sent ? "delivered" : "no udp link");
}

DeviceID CryptoController::activeDeviceID() const
{
    const QMutexLocker locker(&_mutex);
    return _activeDeviceID;
}

CryptoController::State CryptoController::state() const
{
    const QMutexLocker locker(&_mutex);
    return _state;
}

DeviceID CryptoController::gcsDeviceID() const
{
    const QMutexLocker locker(&_mutex);
    return _gcsDeviceID;
}

bool CryptoController::hasActiveKey() const
{
    const QMutexLocker locker(&_mutex);
    return _activeDeviceID != kInvalidDeviceID && _keyManager.hasKey(_activeDeviceID);
}

bool CryptoController::activeKey(Key& outKey) const
{
    const QMutexLocker locker(&_mutex);
    if (_activeDeviceID == kInvalidDeviceID) {
        return false;
    }
    return _keyManager.keyForDevice(_activeDeviceID, outKey);
}

void CryptoController::beginLinking(DeviceID targetDeviceID)
{
    // 拒绝非法目标：sentinel 0 与签名位非法值（规范 §1.4）
    if (targetDeviceID == kInvalidDeviceID || !hasValidSignatureBit(targetDeviceID)) {
        qCWarning(CryptoControllerLog) << "beginLinking: invalid target deviceID" << targetDeviceID;
        return;
    }
    {
        const QMutexLocker locker(&_mutex);
        if (_state == State::Active && _activeDeviceID == targetDeviceID) {
            return; // 已在任务中
        }
        _activeDeviceID = targetDeviceID;
        _state = State::Linking;
    }
    emit stateChanged();

    qCDebug(CryptoControllerLog) << "beginLinking device" << targetDeviceID;

    // 密钥已缓存 → 立即进入 Active；否则异步获取，keyFetched 后自动 confirmLinking。
    if (_keyManager.hasKey(targetDeviceID)) {
        confirmLinking();
    } else {
        // 密钥未缓存：本地注入模式（cryptoKeySource=0）下若目标 deviceID 与本地注入的不一致，
        // 会走到这里走 gcs_server 网络拉取——这是预期的降级，但记录日志便于排查"本地联调却走了网络"。
        qCDebug(CryptoControllerLog) << "beginLinking: no cached key for device" << targetDeviceID
                                     << ", fetching from gcs_server";
        _keyManager.fetchKey(targetDeviceID);
    }
}

void CryptoController::beginLinkingForSystemID(uint8_t systemID)
{
    DeviceID deviceID;
    {
        const QMutexLocker locker(&_mutex);
        if (!_systemToDevice.contains(systemID)) {
            qCWarning(CryptoControllerLog) << "beginLinkingForSystemID: unknown systemID" << systemID;
            return;
        }
        deviceID = _systemToDevice.value(systemID);
    }
    beginLinking(deviceID);
}

void CryptoController::learnDeviceSystemMapping(DeviceID deviceID, uint8_t systemID)
{
    const QMutexLocker locker(&_mutex);
    _deviceToSystem.insert(deviceID, systemID);
    _systemToDevice.insert(systemID, deviceID);
}

void CryptoController::noteDeviceFrame(DeviceID deviceID)
{
    if (deviceID == kInvalidDeviceID) {
        return;
    }
    const QMutexLocker locker(&_mutex);
    _lastFrameMs.insert(deviceID, _frameClock.elapsed());
}

qint64 CryptoController::msSinceLastFrame(quint32 deviceID) const
{
    const QMutexLocker locker(&_mutex);
    const auto it = _lastFrameMs.constFind(static_cast<DeviceID>(deviceID));
    if (it == _lastFrameMs.constEnd()) {
        return -1;
    }
    return _frameClock.elapsed() - it.value();
}

bool CryptoController::deviceIDForSystemID(uint8_t systemID, DeviceID& outDeviceID) const
{
    const QMutexLocker locker(&_mutex);
    const auto it = _systemToDevice.constFind(systemID);
    if (it == _systemToDevice.constEnd()) {
        return false;
    }
    outDeviceID = it.value();
    return true;
}

void CryptoController::confirmLinking()
{
    DeviceID confirmedDevice;
    {
        const QMutexLocker locker(&_mutex);
        if (_state != State::Linking) {
            return;
        }
        _state = State::Active;
        confirmedDevice = _activeDeviceID;
    }
    qCDebug(CryptoControllerLog) << "linking confirmed device" << confirmedDevice;
    emit linkingConfirmed(confirmedDevice);
    emit stateChanged();
}

void CryptoController::failLinking(const QString& error)
{
    DeviceID failedDevice;
    {
        const QMutexLocker locker(&_mutex);
        failedDevice = _activeDeviceID;
        _activeDeviceID = kInvalidDeviceID;
        _state = State::Standby;
    }
    qCWarning(CryptoControllerLog) << "linking failed device" << failedDevice << error;
    emit linkingFailed(failedDevice, error);
    emit stateChanged();
}

void CryptoController::returnToStandby()
{
    {
        const QMutexLocker locker(&_mutex);
        _activeDeviceID = kInvalidDeviceID;
        _state = State::Standby;
    }
    // 回待命 = 连接解除，停用失联监测（不再误报，C2 修正）
    _stopLinkLossMonitor();
    qCDebug(CryptoControllerLog) << "return to standby";
    emit stateChanged();
}

void CryptoController::_onKeyFetched(DeviceID deviceID)
{
    {
        const QMutexLocker locker(&_mutex);
        if (_state != State::Linking || _activeDeviceID != deviceID) {
            return; // 非当前目标 / 状态已变
        }
    }
    confirmLinking();
}

void CryptoController::_onFetchFailed(DeviceID deviceID, const QString& error)
{
    {
        // 与 _onKeyFetched 对称的守卫：陈旧请求的失败不得误杀当前建链目标
        const QMutexLocker locker(&_mutex);
        if (_state != State::Linking || _activeDeviceID != deviceID) {
            return; // 非当前目标 / 状态已变
        }
    }
    failLinking(error);
}

bool CryptoController::nextOutgoingCounter(uint64_t& outCounter)
{
    const QMutexLocker locker(&_mutex);
    if (_state != State::Active || _activeDeviceID == kInvalidDeviceID) {
        return false;
    }

    uint64_t last = 0;
    if (_replayGuard.peekUpLastNonce(_activeDeviceID, last)) {
        // 取严格大于 last 的最小奇数
        outCounter = (last & 1u) ? (last + 2) : (last + 1);
    } else if (_replayGuard.peekDownLastNonce(_activeDeviceID, last)) {
        // QGC 重启恢复（规范 §3.2.4.2）：上行水位随进程丢失，改用下行水位推起点。
        // Y = 已提交的下行 counter 最大值（两阶段调用保证，见 ReplayGuard.h），
        // Y+1 即其奇数后继，也就是本档的起点。
        // 不可取随机起点（§2.5 建链首帧规则）：约 50% 概率落回旧上行区间，且
        // accept() 随即记下该值，此后每条 +2 仍低于旧水位 ⇒ 上行持续被 mavp2p
        // 边缘判重丢弃，而 QGC 侧察觉不到（§2.5：按自身节奏发送、不确认）。
        // 安全性依赖「下行 counter 恒领先上行」：DOWNLINK_INIT_OFFSET（=1001，**PX4
        // 侧常量**，QGC 仓库不持有；见规范 §2.5/附录 A）给出 500 帧余量 ⇒ 只要
        // N_up − N_down ≤ 500 就有 Y+1 > 重启前的上行水位。
        // ⚠️ 这是**现状约束**而非未来风险：摇杆 MANUAL_CONTROL 现在就走本加密发送
        // 路径（默认 25 Hz、上限 200 Hz）持续消耗余量；是否真被击穿取决于当时的
        // 下行速率，本侧无法测定。完整论证见实现说明文档 §3.2.4.2。
        // ⚠️ 范围守卫必须在算式**之前**（照抄 PX4 next_tx_counter）：last 越界时
        // last+2 会回绕成小奇数，而下方 2^62 守卫判在回绕之后、根本拦不住。
        if (last >= (1ull << 62)) {
            qCWarning(CryptoControllerLog)
                << "downlink counter out of range, refuse to send:" << last << "device" << _activeDeviceID;
            return false;
        }
        // (last & 1u) 分支是防御：下行序列异常为奇数时不得产出偶数上行 counter。
        outCounter = (last & 1u) ? (last + 2) : (last + 1);
    } else {
        // 上行与下行水位皆空（本进程尚未提交过任何下行）⇒ 沿用建链首帧的随机起点，
        // 避免重启后从 1 重来导致 nonce 复用（规范 §2.5）。§3.2.4.2 只禁止用确定性
        // 或旧 counter，随机起点不违反。
        // ⚠️ 这是一次性抉择：下方 accept() 随即写入上行水位，此后本进程内必命中第一
        // 档，不会「待 PX4 恢复下行后按 Y+1 收敛」（resetReplay 无生产调用方）。
        // 能走到这里只有两条路，且都安全：① 明文待命心跳触发 beginLinking —— 此时
        // QGC 是建链发起方，§2.5 的随机起点正是正确规则，且该待命心跳已清掉 mavp2p
        // 的水位；② 同一次 receiveBytes 内先提交下行、后建链（微秒级窗口）。
        outCounter = randomOddCounter();
    }

    // 达到 COUNTER_MAX = 2^62 时停止发送（重新建链换密钥），不得越界（规范 §2.5）
    if (outCounter >= (1ull << 62)) {
        qCWarning(CryptoControllerLog) << "outgoing counter reached 2^62, refuse to send (re-key required)";
        return false;
    }

    // 原子预留：更新 lastNonce。上面各档产出的 outCounter 必 > last，故 accept 必成功；
    // 仍检查返回值——失败意味着 nonce 将被复用，属不可逆的安全事故（规范 §2.5）。
    if (!_replayGuard.accept(_activeDeviceID, outCounter)) {
        qCCritical(CryptoControllerLog) << "counter reservation failed, refuse to send:" << outCounter << "device"
                                        << _activeDeviceID;
        return false;
    }
    return true;
}

uint64_t CryptoController::randomOddCounter()
{
    // 62 位随机，最低位置 1（奇数）；高 2 位清 0 留出 +2 递增余量，避免过早 wrap（规范 §2.5）
    constexpr uint64_t kCounterMask = (1ull << 62) - 1ull;
    return (QRandomGenerator::system()->generate64() & kCounterMask) | 1ull;
}

bool CryptoController::isIncomingAcceptable(DeviceID deviceID, uint64_t counter) const
{
    // ReplayGuard 内部已加锁，独立于本类 _mutex，避免嵌套死锁
    return _replayGuard.isAcceptable(deviceID, counter);
}

void CryptoController::commitIncoming(DeviceID deviceID, uint64_t counter)
{
    _replayGuard.commit(deviceID, counter);
    // 收到活跃 PX4 的合法下行（含心跳）→ 重置失联检测。
    // 仅对当前活跃目标监测（单设备场景；多 PX4 会话时 `_linkLossDevice` 单值
    // 会被最后收到的设备覆盖，需改为按 deviceID 分列的计时器——待多设备会话实现）。
    _startLinkLossMonitor(deviceID);
}

void CryptoController::setLinkLossTimeout(int timeoutMs)
{
    if (_linkLossTimer == nullptr) {
        _linkLossTimer = new QTimer(this);
        _linkLossTimer->setTimerType(Qt::CoarseTimer);
        _linkLossTimer->setSingleShot(true);
        connect(_linkLossTimer, &QTimer::timeout, this, &CryptoController::_onLinkLossTimeout);
    }
    _linkLossTimer->setInterval(timeoutMs > 0 ? timeoutMs : kLinkLossTimeoutMs);
}

void CryptoController::_startLinkLossMonitor(DeviceID deviceID)
{
    // 失联监测仅在已建链（Active）且是当前活跃设备时才有意义：
    // Standby 时 PX4 只发明文待命心跳（广播存在性，未建立任何 QGC 连接），不构成"失联"（C2 修正）。
    {
        const QMutexLocker locker(&_mutex);
        if (!_cryptoEnabled || deviceID == kInvalidDeviceID || _state != State::Active ||
            deviceID != _activeDeviceID) {
            return;
        }
        _linkLossDevice = deviceID;
    }
    if (_linkLossTimer == nullptr) {
        setLinkLossTimeout(kLinkLossTimeoutMs);
    }
    // QTimer 操作在锁外（timer 归属主线程，避免持锁调用）
    _linkLossTimer->start();
}

void CryptoController::_stopLinkLossMonitor()
{
    if (_linkLossTimer != nullptr) {
        _linkLossTimer->stop();
    }
    {
        const QMutexLocker locker(&_mutex);
        _linkLossDevice = kInvalidDeviceID;
    }
}

void CryptoController::_onLinkLossTimeout()
{
    DeviceID lostDevice;
    {
        const QMutexLocker locker(&_mutex);
        lostDevice = _linkLossDevice;
    }
    if (lostDevice != kInvalidDeviceID) {
        qCWarning(CryptoControllerLog) << "PX4 link loss detected for device" << lostDevice;
        emit px4LinkLost(lostDevice);
        // 触发后清空，避免计时器意外重启时重复报陈旧设备
        const QMutexLocker locker(&_mutex);
        _linkLossDevice = kInvalidDeviceID;
    }
}

void CryptoController::resetReplay(DeviceID deviceID)
{
    _replayGuard.reset(deviceID);
}

} // namespace MAVLinkCrypto
