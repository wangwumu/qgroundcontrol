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
        // ‼️ 走到这里就说明这是一份**成功推送的清单**（调用方只在该轮请求 200 且载荷合法时
        //    才调本函数）。清单生效标志在此置位，且**此后不再回落**——它是"本视图有没有
        //    话语权"的开关，不是"清单非空"的代词。空清单同样生效（见 .h 的语义说明）。
        _monitorListActive = true;
        // 名册里出现 = 本端以**监控员身份**重新认领它 ⇒ 撤销"已签出"记号（2026-10-06）。
        // ⚠️ 这一处撤销是**必要**的，不是宽纵：监控员名册取自 `_routeDevices`（后端 ③ 的
        //    **航线名册**投影），与"场地签出"正交。若签出后该 id 仍在名册里，说明本端
        //    **确实需要**收它的遥测（画 L3 marker）——那是正当接收，不是"被残余报文激活"。
        // ⚠️ 判据是"在 parsed 里"，不是"在 parsed 里且是本次新增的"：清单是**整份替换**语义，
        //    两种写法在这次转移上等价；选无条件 remove 是因为误撤销只回到今天的行为，
        //    误保留却会让本端收不到一架它该监控的飞机的遥测。
        for (const DeviceID did : parsed) {
            _releasedDevices.remove(did);
        }
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

    // 主动取密钥时机之二（规范 §2.7.2 e）：监控清单**内容变化**时，对尚无本地密钥的 ID 批量拉。
    //
    // ⚠️ 登记集合的取密钥**不等于建链权**：取名单是为了并行解密多架遥测，建不建链另由
    //    `beginLinking` 入口的 `isInitiatorFor(deviceID)` 回答（2026-10-04 起闸名已由
    //    `isResponsibleParty()` 收窄——资格只是它的第一条，不再充分）。
    //    ‼️ 旧注释在此写「监控员 `responsibleParty=false`、全程不建链」——**2026-10-06 起
    //    两头都错**：监控员已是有资格的责任方（他是责任链第二跳），且**持有指令权时确实
    //    建链**（`OpsCommon.monitorHoldsControl`）。取密钥与建链在此**解耦**。
    //    与站点侧 `addLinkedDevice` 的逐条拉取同属「主动」，但落点不同：那份清单是
    //    一个个接手过来的，这一份是**整份推来**的，所以这里是**一次批量**。
    //
    // ‼️ 判据必须是 `changed`，**不是**"被调用了一次"，也不是 `_monitorListActive`：
    //    调用方 `RomView.qml` 由每轮 `routeTasksUpdated` 驱动 ⇒ 不加本判据就是每轮一次
    //    HTTP；而 `_monitorListActive` 在上面那个锁块里是**无条件**置位的（空清单同样生效），
    //    拿它当"清单变了"的判据恒真。
    //
    // ⚠️ 锁**外**发（与 `addLinkedDevice` 同理）：`fetchKeys` 内部会 `emit keysRequested`，
    //    持锁 emit 会把信号处理器拖进临界区（`_mutex` 非递归）。`missing` 在锁内算、锁外发。
    // ⚠️ 这里**不**写 `if (!missing.isEmpty())`：空列表早退已在 `DeviceKeyManager::fetchKeys`
    //    里钉住（Task 5 的用例守着），再判一次就是第二个会漂移的判据。
    if (changed) {
        QList<DeviceID> missing;
        {
            const QMutexLocker locker(&_mutex);
            for (DeviceID id : _monitorDevices) {
                // `hasKey` 取的是 `_keyManager` 自己的锁（`_cacheMutex`）。两把锁的获取顺序
                // 全仓只有 `_mutex` → `_cacheMutex` 这一个方向：`_keyManager` 不回调本类，
                // 且它 `emit keyFetched` 在 `cacheKey` 的锁**之外** ⇒ 无反转。
                if (!_keyManager.hasKey(id)) {
                    missing << id;
                }
            }
        }
        _keyManager.fetchKeys(missing); // ⚠️ 值成员，用 `.` 不是 `->`
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
        // ‼️ 闸的落点分两类：
        //    ① **C++ 内部调用**：闸一律在**调用方**——本函数自带这道门，而 `_sendRegistration()`
        //       与 `_sendRegistrationFrame()` **两个都没有**（前者零 `return`——只有取批 +
        //       发帧；后者只管计数 + 组帧 + 发。都假定调用方已把好关）。登记关着时不发帧靠的是
        //       `setRegistrationEnabled(false)` 停掉周期定时器，**不是**它们的自检。
        //    ② **QML 可达的入口（`Q_INVOKABLE`）必须自带门**：QML 查不到闸的状态
        //       （`registrationEnabled()` 不是 Q_INVOKABLE）⇒ "闸在调用方"对它根本不成立。
        //       `reRegisterDevice()` 即此类，见其实现与声明处的注释。
        return;
    }

    int n = 0;        // 本轮要发的**总量**（含追加的 active）
    int listSize = 0; // 清单本身的条数（不含追加）——仅供容量告警把两个量都打出来
    {
        const QMutexLocker locker(&_mutex);
        // ‼️ 口径必须与 `_sendRegistration()` 取列表的那几行**一致**：那里在
        //    `_activeDeviceID` 有效且不在清单里时会把它**追加到末尾**。
        //    少算这一个的后果：清单条数为 16 的整数倍（16/32/48/64/80）时
        //    `ceil(n/16)` 少排一批，而追加在末尾的 `_activeDeviceID` 恰好总落在最后一批
        //    ⇒ 它这一轮永远取不到、要等下一个 10s 周期——而那架正是用户刚选定、
        //    正在建链的目标。改完 n = 这一轮真正要发的总量。
        // ‼️ 与 `_sendRegistration()` 同口径：走同一个 `_manifestLocked()`，两处不可能再漂
        //    （口径本身"为什么是 `_monitorListActive` 而不是 `_monitorDevices.isEmpty()`"
        //    见那个函数的声明处，这里刻意不再复述——复述就是下一个漂移点）。
        const QList<DeviceID>& devices = _manifestLocked();
        listSize = devices.size();
        n = listSize;
        if (_activeDeviceID != kInvalidDeviceID && !devices.contains(_activeDeviceID)) {
            n++;
        }
    }

    const int batches = (n <= 0) ? 1 : ((n + MAX_QGC_LINKED_PX4 - 1) / MAX_QGC_LINKED_PX4);
    const int capped = qMin(batches, kMaxRegistrationBatches);
    if (capped < batches) {
        // 容量天花板（§3.4）：越过 n ≤ 80 时稳态本来就保证不了 TTL，
        // 加速发送再多也只是把这一轮塞满。**截断的是批数，不是集合**——
        // 集合永远不动（§3.6.2）。
        // ‼️ 两个量都要打：触发判据用的是 `n`（本轮总量，含追加的 active），
        //    而 `_monitorDevices` 的实际条数是 `listSize`。只打一个会让排障者
        //    去找一个不存在的清单（清单恰 80 条 + active 不在清单 ⇒ n=81 触发告警）。
        qCWarning(CryptoControllerLog) << "登记总量超过容量天花板（n ≤ 80），加速发送已截断："
                                       << "监控清单" << listSize << "架 / 本轮" << n << "架 / 需" << batches << "批";
    }

    // ⚠️ 用 QTimer::singleShot 串，**不要**用 QThread::msleep 或忙等——那会卡 GUI 线程（§3.4）
    for (int i = 0; i < capped; i++) {
        QTimer::singleShot(i * kRegistrationBurstIntervalMs, this, [this]() {
            _sendRegistration();
        });
    }
}

void CryptoController::reRegisterDevice(quint32 deviceID)
{
    if (deviceID == kInvalidDeviceID || !hasValidSignatureBit(static_cast<DeviceID>(deviceID))) {
        qCWarning(CryptoControllerLog) << "reRegisterDevice: 非法 deviceID，忽略" << deviceID;
        return;
    }
    // ‼️ **登记闸设在这里**（先校验参数、再校验状态：非法 deviceID 的告警在关门时照常打）。
    //    门必须落在**被调用方**：`registrationEnabled()` **不是** Q_INVOKABLE，而本函数**是**
    //    ⇒ QML 调用点（RomView.qml 的 2s 节拍）物理上查不到闸的状态，无法自己把门。
    //    缺门的后果（P5 终审 I-1）：crypto 关闭 ⇒ `_registrationEnabled` 恒 false、
    //    周期定时器也停着 ⇒ 本函数成为 80005 的**唯一**发送方，且 `msSinceLastFrame()` 在
    //    明文路径上没有埋点恒返回 -1 ⇒ QML 判据恒真 ⇒ 每 2s 对清单里每架发一次，
    //    永不停止、无退避、无日志。
    // ⚠️ 设门**不削兜底**：设计文档 §3.6.3 场景表第 5 行要的是"周期轮转因故停摆时靠定向重发
    //    兜底"，而轮转停摆在生产代码里的唯一成因就是 `setRegistrationEnabled(false)`
    //    （它停掉定时器）——恰恰是"用户要求不发"的情形，不是"意外停摆"。登记**开着**而
    //    轮转意外没发时门是开的，超时检查照常兜底：这正是要保留的语义。
    if (!registrationEnabled()) {
        return;
    }
    // ‼️ **签出闸**（2026-10-06 补）：与上面那道门同样落在**被调用方**，理由也一样——
    //    本函数是 `Q_INVOKABLE`，而 `_releasedDevices` 是 private，QML 调用点
    //    （`RomView.qml` 的 2s 节拍）物理上查不到闸的状态。
    //    这道闸不是"多一道防线"，而是与 `releaseDevice` 清 `_lastFrameMs` **配对**的另一半：
    //    清掉时间戳后 `msSinceLastFrame()` 返回 -1 ⇒ 调用点的 `since < 0` 判据**恒真**
    //    ⇒ 每 2s 对签出过的飞机发一次；而 `_monitorIds` 取自
    //    `OpsCommon.monitorDeviceIds(_routeDevices)`——那是后端 ③ 的**航线名册**投影，
    //    与"场地签出"正交，签出后该 id 仍可能留在里面（同机双角色时必然如此）。
    //    缺这道闸，重发会把 mavp2p 那个配对的 `qgcSeen` 重新刷新鲜（`processRegistration`
    //    命中已有配对时 `lastSeen` 与 `qgcSeen` 两个都刷）⇒ 配对**永不过期**、
    //    残余加密帧无限期投喂——正好抵消 `releaseDevice` 想达成的效果。
    // ⚠️ **静默**返回、不打告警：这是一条 2s 一次的**预期路径**，打日志就是刷屏。
    {
        const QMutexLocker locker(&_mutex);
        if (_releasedDevices.contains(static_cast<DeviceID>(deviceID))) {
            return;
        }
    }
    // 单发一批（只含这一个），复用 _sendRegistrationFrame 的组帧与发送逻辑。
    // ‼️ 这里**不碰** _monitorDevices、不碰 _regCursor —— 重发是幂等刷新，
    //    任何集合改动都会把"超时自愈"变成"超时自我放逐"（§3.6.2）。
    _sendRegistrationFrame(QList<DeviceID>{ static_cast<DeviceID>(deviceID) });
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

bool CryptoController::monitorListActiveForTest() const
{
    const QMutexLocker locker(&_mutex);
    return _monitorListActive;
}

bool CryptoController::linkLossMonitorActiveForTest() const
{
    // 与 `_stopLinkLossMonitor()` 同口径：QTimer 的操作在锁外（timer 归属主线程，
    // 持锁调它有反序风险）。这里只读 `isActive()`，不改状态。
    return _linkLossTimer != nullptr && _linkLossTimer->isActive();
}

QList<DeviceID> CryptoController::lastRegistrationPayloadForTest() const
{
    const QMutexLocker locker(&_mutex);
    return _lastRegistrationPayload;
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

void CryptoController::addLinkedDevice(quint32 deviceID)
{
    // ⚠️ 形参是 `quint32` 而非 `DeviceID`（同一个类型，仅拼写不同）——理由见头文件：
    //    moc 按字面解析，写 typedef 会让这个 QML 入口的形参变成"未解析类型"。
    // 规范 §1.4：PX4 deviceID 的 bit24（incompatFlag bit0）必须为 0
    if (deviceID == kInvalidDeviceID || !hasValidSignatureBit(deviceID)) {
        qCWarning(CryptoControllerLog) << "addLinkedDevice: invalid deviceID" << deviceID;
        return;
    }
    bool added = false;
    {
        const QMutexLocker locker(&_mutex);
        // 接手 = 撤销"已签出"记号（2026-10-06）。放在 `if (!contains)` **之外**：站点视图
        // 每 2s 重推同一份清单，重复接手同一架是常态，只在首次 `added` 时撤销会漏掉
        // "签出 → 同轮又接手"那条路径。
        _releasedDevices.remove(deviceID);
        if (!_linkedDevices.contains(deviceID)) {
            _linkedDevices.append(deviceID);
            added = true;
            qCDebug(CryptoControllerLog) << "linked device added" << deviceID;
        }
    }
    // ⚠️ 锁**外**：`fetchKeys` 内部会 `emit keysRequested`，持锁 emit 会把信号处理器
    //    拖进临界区（`_mutex` 非递归，处理器里再取锁就是自死锁）。
    //
    // 主动取密钥时机之一（规范 §2.7.2 e）：清单里**新出现**一个本地尚无密钥的 ID ⇒ 拉它。
    // ‼️ 这一句是自动建链的必要条件，不是优化：两处建链闸都要求 `hasKey(deviceID)` 已为真，
    //    而 `beginLinking` 内部那条"无密钥则 fetchKey"的 `else` 落在闸**之后**，
    //    在自动建链路径上**恒不可达**。登录响应一旦不再下发 key，少了这一句整条路径死锁。
    // ⚠️ 判 `added` 而不是只判 `hasKey`：站点视图每 2s 重推同一份清单，
    //    只判 `hasKey` 会在"服务端没有这份密钥"时变成每轮重拉一次 HTTP。
    if (added && !_keyManager.hasKey(deviceID)) {
        _keyManager.fetchKeys({ deviceID }); // `_keyManager` 是**值成员**，用 `.` 不是 `->`
    }
}

bool CryptoController::removeLinkedDevice(DeviceID deviceID)
{
    const QMutexLocker locker(&_mutex);
    const bool removed = (_linkedDevices.removeAll(deviceID) > 0);
    if (removed) {
        qCDebug(CryptoControllerLog) << "linked device removed" << deviceID;
    }
    return removed;
}

const QList<DeviceID>& CryptoController::_manifestLocked() const
{
    return _monitorListActive ? _monitorDevices : _linkedDevices;
}

bool CryptoController::isInManifest(DeviceID deviceID) const
{
    const QMutexLocker locker(&_mutex);
    return _manifestLocked().contains(deviceID);
}

void CryptoController::releaseDevice(quint32 deviceID)
{
    const DeviceID id = static_cast<DeviceID>(deviceID);
    // 参数校验与 addLinkedDevice / setMonitorDevices 用**同一组**口径（非 0 + 签名位合法）
    if (id == kInvalidDeviceID || !hasValidSignatureBit(id)) {
        qCWarning(CryptoControllerLog) << "releaseDevice: 非法 deviceID，忽略" << deviceID;
        return;
    }
    // 防御：本端 GCS 的 deviceID 不属于"被关联的 PX4"，绝不该出现在 _linkedDevices 里。
    // 真出现了说明上游数据串了线，此时**释放它**会把自己的登记身份摘掉——
    // 宁可留一条告警，也不做这个动作。
    if (id == _gcsDeviceID) {
        qCWarning(CryptoControllerLog) << "releaseDevice: 拒绝释放本端 GCS deviceID" << deviceID;
        return;
    }

    // ⚠️ `hasKey` 在取本类 `_mutex` **之前**问：`_keyManager` 自管一把锁，两把锁没必要嵌套。
    //    （`DeviceKeyManager::_onReplyFinished` 在 `cacheKey` 之后、`emit keyFetched` 之前
    //    就已经放掉了它那把锁，故两侧本无锁序问题——这里只是不去制造一个。）
    const bool hasCachedKey = _keyManager.hasKey(id);

    bool yielded = false; // 本次是否让出了上行权（决定要不要停失联监测、发 stateChanged）
    {
        const QMutexLocker locker(&_mutex);
        // ⓪ 成员资格闸（2026-10-04 补）：本端关于这架飞机**没有任何本地状态**时早退。
        //    判据四条：不在登记集合、不在监控清单、没占上行权、本地没有它的密钥。
        //    ‼️ 今天这道闸**不改任何可达行为**——这四件事落在这样一个 id 上本来就全是空操作
        //    （`removeAll` 返回 0、`removeKey` 找不到条目、`ReplayGuard::reset` 只 remove 不插入、
        //    `_activeDeviceID != id` 故不让位），唯一的可观测差别是多一条告警。
        //    ⇒ 它挡的是**将来**：本函数是 `Q_INVOKABLE` 的破坏性原语，日后任何**新增**的破坏性
        //    步骤若忘了自带成员资格判据，会在这里被统一拦下。
        //    判据与 `_onKeyFetched` 那处「已被释出」的三集合判定同源，多一条 `hasCachedKey`：
        //    **有密钥却不在任何集合**（在途 `fetchKey` 刚装回来的那种）仍应允许释出 ——
        //    删掉那把密钥正是释出要做的事。
        //    残留假设（2026-10-04 查实，今天成立）：水位不会脱离密钥存在 —— 下行水位只有
        //    `MAVLinkProtocol.cc` 在**解密 + tag 认证通过后**那一处写，那必然有密钥；上行水位只由
        //    `nextOutgoingCounter()` 写，那条路要 Active，同样有密钥。故本闸不会挡下
        //    「给一个已无密钥的 id 清水位」这种清理。
        if (!hasCachedKey && !_linkedDevices.contains(id) && !_monitorDevices.contains(id) &&
            _activeDeviceID != id) {
            qCWarning(CryptoControllerLog) << "releaseDevice: 该 deviceID 未与本端关联，忽略" << deviceID;
            return;
        }
        // ① 移出登记集合：本端不再为它发 80005（mavp2p 的配对随之在 MAP_TTL 后过期）。
        //    编号与 .h 的四件事一致。这里写**内联** removeAll 而不调 `removeLinkedDevice`：
        //    那个函数自己加 `_mutex`，本处已持锁 ⇒ `QMutex` 非递归会死锁。
        _linkedDevices.removeAll(id);
        // ①b 也从监控清单里摘掉（① 的同一件事，第二个容器）。清单本由上层整份重推
        //     （poll 成功即全量替换），这里多做一步是为了补一个真实的缝：
        //     **poll 失败时刻意保留上一次清单**（§3.5.4），若不摘，
        //     已释出的飞机会被那一份陈旧清单一直登记着。
        //     ⚠️ 摘完可能成为空清单——那不是"没有清单"。**若这份清单曾生效**
        //     （`_monitorListActive == true`），取列表口径不会翻回 `_linkedDevices`
        //     （否则这次释出当场失效）；而未打开过 RomView 的会话从不调
        //     `setMonitorDevices`（全仓唯一调用点就在 RomView 里），此时该标志本就是
        //     false，摘空也无从翻起。
        if (_monitorDevices.removeAll(id) > 0) {
            _regCursor = 0; // 集合变了，旧游标没有意义（同 setMonitorDevices）
        }
        // ⑤ 清三张 per-device 表，并记入 `_releasedDevices`（2026-10-06 补）。
        //    ⚠️ 这三张表原来**刻意不动**（见 .h 的旧注释）：理由是"前者没有清理时机判据"
        //    与"删掉会让 `beginLinkingForSystemID` 在这架飞机上失效"。今天两条都反过来了——
        //    签出**就是**那个清理时机，而让 `beginLinkingForSystemID` 在这架飞机上失效
        //    **正是**签出要做的事（清表后它会打一条 `unknown systemID` 警告并 return；
        //    留着映射则本端还能凭一个 systemID 为已经交还出去的飞机重新建链）。
        _lastFrameMs.remove(id);
        //    ⚠️ `_deviceToSystem` 今天**只写不读**（`:901` 是唯一写点，全仓无读者——
        //    `deviceIDForSystemID` 读的是反向表）。清它是防泄漏 + 与反向表保持一致，
        //    没有"不清就会被读错"这一层；下面的断言也验不到它（无观测点）。
        _deviceToSystem.remove(id);
        //    ‼️ `_systemToDevice` **不能**按正向表反查 systemID 再删。反向表按 systemID
        //    只存**最后一架**（`learnDeviceSystemMapping` 是无条件 insert），而**多架同
        //    systemID 是常态**——`Vehicle.cc` 的 `deviceID()` 注释记着实测：本场地 17 架
        //    的 sysid 全是 150。照正向表反查会把**别人**的条目一起删掉
        //    （`beginLinkingForSystemID(150)` 此后对 B 也失效）。
        //    判据只能是"值等于本 id"，故这里遍历而不是查表。
        for (auto it = _systemToDevice.begin(); it != _systemToDevice.end();) {
            if (it.value() == id) {
                it = _systemToDevice.erase(it);
            } else {
                ++it;
            }
        }
        //    ‼️ 只清不够：mavp2p 在配对老化前（`MAP_TTL`，实测云端部署未传 `--map-ttl`
        //    ⇒ 默认 60s）仍会把该机的加密帧转发过来，而 `MAVLinkProtocol.cc` 的四条收帧记账
        //    是**无条件**的 ⇒ 只清不记的话，上面三张表会被**下一帧**原地写回，签出等于没签出。
        //    这个记号由三个入口自己消费：`learnDeviceSystemMapping` / `noteDeviceFrame` /
        //    `reRegisterDevice`；撤销点是"本端以任何身份重新认领它"
        //    （`addLinkedDevice` / `setMonitorDevices`）。
        _releasedDevices.insert(id);
        // ④ 让出上行权——**只在它确实占着槽时**。`_activeDeviceID` 是单槽，
        //    可能正属于另一架飞机，无条件回 Standby 会把在飞那架一起打掉。
        if (_activeDeviceID == id) {
            _activeDeviceID = kInvalidDeviceID;
            _state = State::Standby;
            yielded = true;
        }
    }

    // ② 删本地密钥。**这一步是必需的**，它与 ③ 一起构成"清空水位"的安全前提：
    //    `MAVLinkProtocol.cc` 那两处自动建链的闸就是 hasKey——删掉它，本端才不会在
    //    飞机尚未回到待命（PX4 全局水位仍是旧值）时贸然用随机起点发首帧。
    //    详见 .h 的因果链说明。`beginLinking` 在 hasKey 未命中时会自动取密钥，
    //    所以重新接引不会因此卡住，只是多一个 HTTP 往返。
    _keyManager.removeKey(id);
    // ③ 上下行水位**一并清空**（2026-10-03 用户裁定）。清空之后本端对这架飞机的
    //    上行起点重新回到"随机奇起点 ⇒ 收到下行后改取 下行+1"的规则（规范 §2.5/§3.2.4.2）。
    resetReplay(id);

    if (yielded) {
        // 锁外调用：它内部要加锁（同 returnToStandby 的写法）
        _stopLinkLossMonitor();
    }
    qCDebug(CryptoControllerLog) << "released device" << id << (yielded ? "(yielded uplink)" : "");
    if (yielded) {
        emit stateChanged();
    }
}

void CryptoController::_sendRegistration()
{
    QList<DeviceID> batch;
    {
        const QMutexLocker locker(&_mutex);
        // §3.5.3：有**生效的**监控清单时用清单，否则回退 _linkedDevices
        //（未登录 / 站点视图从未推过清单 ⇒ 保持现状，零回归）。
        // ‼️ 取清单的判据收在 `_manifestLocked()` 一处（`_monitorListActive`，**不是**
        //    `_monitorDevices.isEmpty()`）——这里刻意只留引用，理由不再复述。
        QList<DeviceID> devices = _manifestLocked();
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
    // ‼️ 计数在**首条可执行语句**、且在下面的 `packLen == 0` 早退**之前**——
    //    它数的是"发了多少帧"（含组帧失败那一帧），不是"`_sendRegistration()` 进去过几次"。
    //    ⚠️ 放在 `_sendRegistration()` 里会让定向重发（`reRegisterDevice` 直调本函数）
    //    整条路径**不计入**，而单测的判据正是这个计数。
    {
        const QMutexLocker locker(&_mutex);
        _registrationSendCount++;
    }

    // 帧头 deviceID 用 GCS 段固定值（文档 §1.3 QGC_REGISTRATION_DEVICE_ID_DEFAULT），
    // 由 pack 函数拆入帧头 4 字节（方案 B）。payload 填关联 PX4 deviceID 集合。
    const int deviceCount = qMin(ids.size(), static_cast<int>(MAX_QGC_LINKED_PX4));

    // 单测用：记下**这一帧真正装进去的** id（截断之后），口径与下面的 `deviceBytes` 循环一致。
    // ‼️ 记的是 `deviceCount` 而非调用方传进来的整个 `ids`——否则断言会对着"打算装的"而非"装了的"。
    {
        const QMutexLocker locker(&_mutex);
        _lastRegistrationPayload = ids.mid(0, deviceCount);
    }

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

void CryptoController::setResponsibleParty(bool responsible)
{
    bool revokeActiveLink = false;
    {
        const QMutexLocker locker(&_mutex);
        _responsibleParty = responsible;
        // 会话边界：责任方身份被重新判定（登录成功 / 登录被拒 / 本地密钥源初始化）⇒
        // 上一个会话的监控清单**当场作废**（闩回落 + 清单清空 + 轮转游标归零）。
        // 为什么落在这里：`_monitorListActive` 是**单向闩**（全仓仅 `setMonitorDevices`
        // 一处置 true），而取列表的口径是 `_monitorListActive ? _monitorDevices : _linkedDevices`
        // —— 闩不回落，**跨会话**时本端会一直按上一个站点的 `_monitorDevices` 发 80005 登记心跳：
        // 新会话的飞机登记不上，旧站点的飞机被继续登记。复位后回到 §3.5.4 的既有口径
        // （回退 `_linkedDevices`），新会话的清单由 RomView 的 `setMonitorDevices` 重新推上来。
        // ⚠️ **生产路径**上这段今天不改任何行为：本仓 QGC 没有登出（`AuthController.cc` 逐字写着
        //    「当前 QGC 无登出路径，进程内"已登录再换账号登录"不可达；将来若加登出，需一并清理」），
        //    一次会话内本函数只在登录时被调一次，那时闩必为 false。它是给"将来加登出"预备的。
        //    ‼️ 但**别**据此说这段"不可达"：单元测试二进制里它是**活的**——`CryptoTest::init()`
        //    每格无条件调本函数，某格用 `setMonitorDevices` 把闩置真之后，**下一格的 `init()`**
        //    就会走进这里把闩清掉。改这段前先想清楚测试侧的可见后果。
        // ⚠️ 只清监控清单，**不动** `_linkedDevices`：它的写侧是站点视图的接手/释出
        //    （`OpsShell.qml` 调 `addLinkedDevice` / `releaseDevice`）与单机模式的本地密钥源
        //    （`QGCApplication.cc` 调 `addLinkedDevice`），生命周期不归本函数。
        //    ⚠️ 旧注释说它"是登录时写入的、归 `AuthController`"——自 2026-10-04 起登录**不再**
        //    写它（登录响应已不含 `devices`），那句已失效。
        // ⚠️ 刻意**不打日志**：这里不是异常而是定义的边界；且本文件用例的 `init()` 每次都调本
        //    函数，留一条日志会让 strict mode 在下一个用例里以"未预期日志"红掉。
        if (_monitorListActive) {
            _monitorListActive = false;
            _monitorDevices.clear();
            _regCursor = 0;
        }
        // 同一会话边界，**起/终维也当场作废**（2026-10-04 补）。理由与上面那段同源：它是
        // 「本端持有哪些飞机的指令权」的判定结果，归属登录会话；跨会话留着会让新账号按上一个
        // 站点的名单建链。
        // ‼️ 缺省 false 还有第二重作用：它是「本端**尚未确定**起/终维」的表达，而
        //    `isInitiatorFor` 靠它退回旧形态。**单机模式（本地密钥源）不推起/终维，行为
        //    不变靠的就是这一条**——它与 `_monitorListActive` 不同，必须**无条件**清，
        //    不能挂在上面那个 `if` 里。
        // ⚠️ 同样刻意不打日志（本函数在单测里每格都被调，留日志会让 strict mode 红）。
        _initiatorScopeValid = false;
        _initiatorDevices.clear();
        // 收回发言权时，已建立的链路必须**当场**降回待命。闸只在 beginLinking 的入口
        // 检查一次，而 LinkInterface 只看 state()——标志翻转本身不会撤销 Active 链路，
        // 于是本机会以「当前 Active」继续加密外发（操纵杆 MANUAL_CONTROL 天然走这条路）。
        // 判据用 != Standby 而非 == Active：Linking 中途被收回同样要打断（它会走向 Active，
        // 且 _activeDeviceID 已被占用）。
        revokeActiveLink = !responsible && _state != State::Standby;
    }
    // returnToStandby 自己取 _mutex，必须在锁外调用（QMutex 非递归）。
    if (revokeActiveLink) {
        returnToStandby();
    }
}

bool CryptoController::isResponsibleParty() const
{
    const QMutexLocker locker(&_mutex);
    return _responsibleParty;
}

void CryptoController::setInitiatorDevices(const QVariantList& deviceIds)
{
    QList<DeviceID> parsed;
    parsed.reserve(deviceIds.size());
    for (const QVariant& v : deviceIds) {
        bool ok = false;
        const uint id = v.toUInt(&ok);
        // ⚠️ 与 `addLinkedDevice` / `setMonitorDevices` 用**同一组**校验（非 0 + 签名位合法，
        //    规范 §1.4），保证"能进 `_linkedDevices` 的就能进本集合"，三处口径不漂移。
        if (!ok || id == kInvalidDeviceID || !hasValidSignatureBit(static_cast<DeviceID>(id))) {
            qCWarning(CryptoControllerLog) << "setInitiatorDevices: 非法 deviceID，已跳过" << v;
            continue;
        }
        parsed.append(static_cast<DeviceID>(id));
    }

    bool revokeActiveLink = false;
    {
        const QMutexLocker locker(&_mutex);
        // 走到这里就说明这是一份**成功推送的名单**（调用方只在该轮请求 200 且载荷合法时才
        // 调本函数）。生效标志在此置位，且**此后不再回落**（只有会话边界 `setResponsibleParty`
        // 能清它）——它是"本端有没有确定起/终维"的开关，不是"名单非空"的代词。
        // ‼️ 空名单同样生效：它表示「本端此刻不持有任何一架的指令权」⇒ 全拒（fail-closed）。
        _initiatorScopeValid = true;
        _initiatorDevices = parsed;
        // 闸只在 `beginLinking` 入口检查**一次**（同 `setResponsibleParty` 收权那一段的
        // 理由）：正在 Active 的那一架若本端不再持有其指令权（责任链推进、交棒给了下一方），
        // 必须当场让出上行权。否则本机会继续以当前 Active 加密外发，与新持有方的 QGC 争同一
        // deviceID 的上行奇数序列——违反 §3.1「同一时刻只有一个发送端（任务 QGC）」。
        // 判据用 `!= Standby` 而非 `== Active`：Linking 中途同样要打断（它会走向 Active，
        // 且 `_activeDeviceID` 已被占用）。
        revokeActiveLink = (_state != State::Standby) && !parsed.contains(_activeDeviceID);
    }
    // `returnToStandby` 自己取 `_mutex`，必须在锁外调用（QMutex 非递归）。
    // ⚠️ 它**不删密钥**——本端可能仍是这架飞机的降落站，遥测还要照常解密上屏，
    //    交还的只是"发言权"。
    if (revokeActiveLink) {
        returnToStandby();
    }
}

bool CryptoController::isInitiatorFor(DeviceID deviceID) const
{
    // ① **资格**闸（2026-09-27 裁定；2026-10-06 放宽到含 ROUTE_MONITOR）。
    //    语义是"本端有没有发言权"，**不是**"本端此刻是不是责任方"——后者由 ④ 回答。
    //    ‼️ 旧注释在此写「非责任方一律不建链（航线监控员等）」——**2026-10-06 起已失效**：
    //    监控员正是责任链的第二跳，他的指令（出发/回航/备降）只有他该发，故他必须有资格。
    //    仍在闸外的是 FLIGHT_SUPERVISOR。
    //    它在其它分支之前，故监控员视图从不推起/终维也不影响它。
    if (!isResponsibleParty()) {
        return false;
    }
    // ② 退回旧形态（信息不可得，**不是**"信息说不是"）：没有 deviceID 就无从判起/终。
    //    非加密路径上 `Vehicle::_deviceID` 是默认实参 `kInvalidDeviceID`，且它建车即定
    //    终身、无 setter ⇒ 这类会话永远走分支 ③ 或本条。
    if (deviceID == kInvalidDeviceID) {
        return true;
    }
    const QMutexLocker locker(&_mutex);
    // ③ 退回旧形态：本端尚未收到过起/终维。两种来源——站点视图还没刷出第一轮（窗口
    //    **最长 2 s**：`_bootstrap` 站点支只调 `_fetchMySite`、不调 `_fetchOverview`，
    //    首次推送要等 `pollTimer` 的第一个 tick，`OpsShell.qml` 的 `interval: 2000`），
    //    或本部署根本不跑站点视图（**单机模式的本地密钥源**）。
    //    ⚠️ 这一条是**刻意 fail-open** 的，且它与 ④ 的差别是本设计的全部要害：
    //    收紧它会让单机模式一架都建不了链（该建链的也建不了）。
    if (!_initiatorScopeValid) {
        return true;
    }
    // ④ 已生效 ⇒ 严格按名单判，fail-closed：不在名单里就是不建链。
    return _initiatorDevices.contains(deviceID);
}

void CryptoController::beginLinking(DeviceID targetDeviceID)
{
    // 建链闸（2026-09-27 用户裁定；2026-10-06 扩到责任链三档）：**同一时刻只有持有该机
    // 指令权的那一台 QGC 与 PX4 握手**。越过持有方去发任务/围栏/集结点命令是完全错误的
    // ——两端各取一个上行 counter ⇒ nonce 重复（规范 §2.5）。非接引方在此直接返回，
    // 状态保持 Standby。
    //
    // 位置：**函数最前**，早于非法 deviceID 检查、早于任何状态写入与其它日志。
    // 这是"本进程压根不该建链"的更高层判据，与参数是否合法无关；放后面还会让非责任方
    // 每次收到待命心跳都刷一条 invalid deviceID 告警。
    // 之所以能一处覆盖全部上行：三个建链入口（MAVLinkProtocol 的明文待命心跳 / 加密下行、
    // MissionController::sendToVehicle → beginLinkingForSystemID）全部汇聚到本函数；而
    // "不发指令"由 LinkInterface 对非 Active 直接 drop 兜住——任务/围栏/集结点/参数/心跳
    // 一条都发不出去，无需在各自控制器里再布闸。
    //
    // ‼️ 拒绝路径**刻意不打任何日志**，不是遗漏：
    //   ① 这是航线监控员的**正常业务状态**，不是故障——按 memory 里"未预期日志即失败"
    //      的测试约定，打日志就要在每个用例里预期它，收益为零。
    //   ② 频率上更不允许：本函数在非责任方下会被**每一条**明文待命心跳（1 Hz，PX4 在
    //      建链前一直发）和**每一条**加密遥测下行（另一台建链后，本机有密钥即可解密、
    //      频率远高于 1 Hz）各调一次。逐次告警会在几秒内淹没有用的日志。
    //   ③ 该类别（QGC_LOGGING_CATEGORY ⇒ Q_LOGGING_CATEGORY(..., QtWarningMsg)）的
    //      debug 默认关闭，且 QGCLoggingCategoryManager 装了自定义 category filter，
    //      setFilterRules 被它覆写——想在测试里观察必须走 --logging= 命令行，不值得。
    // 需要判断"本机是不是责任方"的调用方直接读 isResponsibleParty()，不要靠日志。
    //
    // ‼️ 2026-10-04 起判据从 `isResponsibleParty()` 收窄为 `isInitiatorFor(targetDeviceID)`：
    //    资格只是"本端有权发言"，还差"本端**此刻**持有**这一架**的指令权"。可接引范围 =
    //    出站 ∪ **进站**（§2.7.2 d）⇒ 终点站也拿得到密钥、也够资格 ⇒ 旧判据挡不住它，
    //    它会占住 `_activeDeviceID` 单槽把当时的持有方挤掉，违反 §3.1「同一 deviceID
    //    指令方向同一时刻只有一个发送端」。拒绝路径的静默理由与上面同一段，不变。
    if (!isInitiatorFor(targetDeviceID)) {
        return;
    }

    // 拒绝非法目标：sentinel 0 与签名位非法值（规范 §1.4）
    if (targetDeviceID == kInvalidDeviceID || !hasValidSignatureBit(targetDeviceID)) {
        qCWarning(CryptoControllerLog) << "beginLinking: invalid target deviceID" << targetDeviceID;
        return;
    }
    bool hadLinkLossMonitor = false;
    {
        const QMutexLocker locker(&_mutex);
        if (_state == State::Active && _activeDeviceID == targetDeviceID) {
            return; // 已在任务中
        }
        // 切换活跃目标：在跑的那份失联监测监的是**上一个**目标。此后每一帧 `commitIncoming`
        // 都会因 `deviceID != _activeDeviceID` 在 `_startLinkLossMonitor` 里早退 ⇒ 它既不会
        // 被改派、也不会被自然停掉，只会在超时那一刻对一架**已不该被关心**的飞机发
        // `px4LinkLost`（假失联告警）。故"停"必须挂在这里，不能只挂在 `releaseDevice` 的
        // 让位分支上——被切走的目标未必紧接着被释出。
        hadLinkLossMonitor = (_linkLossDevice != kInvalidDeviceID);
        _activeDeviceID = targetDeviceID;
        _state = State::Linking;
    }
    if (hadLinkLossMonitor) {
        _stopLinkLossMonitor(); // 锁外调用（同 _startLinkLossMonitor：timer 归属主线程）
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
    // 签出闸（2026-10-06 补）：`releaseDevice` 刚清掉这两张表，而 mavp2p 在配对老化前
    // （`MAP_TTL`，实测默认 60s）仍会转发该机的帧 ⇒ 不挡的话下一帧就把表重建回来。
    // ‼️ 闸收在**本函数体内**、不在 `MAVLinkProtocol.cc` 的调用点：那里的注释
    //    （`:211-222`）写明了那四行必须**无条件**执行（失联判据依赖它们，且它们是
    //    "全新启动学映射"的唯一入口）。用白名单（`isInManifest`）当闸会打破那个入口。
    if (_releasedDevices.contains(deviceID)) {
        return;
    }
    _deviceToSystem.insert(deviceID, systemID);
    _systemToDevice.insert(systemID, deviceID);
}

void CryptoController::noteDeviceFrame(DeviceID deviceID)
{
    if (deviceID == kInvalidDeviceID) {
        return;
    }
    const QMutexLocker locker(&_mutex);
    // 签出闸：理由同 `learnDeviceSystemMapping`（`releaseDevice` 已清 `_lastFrameMs`，
    // 不挡的话残余帧会把它重建回来，本端就为一条**已经交还出去**的链路保留了收帧记录）。
    if (_releasedDevices.contains(deviceID)) {
        return;
    }
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
    bool releasedDevice = false;
    {
        const QMutexLocker locker(&_mutex);
        if (_state != State::Linking || _activeDeviceID != deviceID) {
            // ‼️ 早退之前先判一次：这次回包是不是为一个**已被释出**的 deviceID 而来。
            //    必须在这里把它删掉，因为 `cacheKey` 已经在
            //    `DeviceKeyManager::_onReplyFinished` 里**无条件**执行过了——`releaseDevice`
            //    刚删掉的密钥，此刻被这个回包**原地装回来**，于是 `MAVLinkProtocol.cc`
            //    两处自动建链的 `hasKey` 闸重新打开：收到该机的帧 ⇒ beginLinking ⇒
            //    用**随机奇起点**给一架已经签出的飞机发首帧（正是 .h 里那条要堵的链）。
            //    判据＝三个集合都不认它。正常的"建链目标从 A 改到 B"切换下 A 仍在某个
            //    集合里 ⇒ 不误伤；真不在任何集合里，那它本来就该被释出。
            releasedDevice = (_linkedDevices.indexOf(deviceID) < 0 &&
                              _monitorDevices.indexOf(deviceID) < 0 &&
                              _activeDeviceID != deviceID);
            if (!releasedDevice) {
                return; // 非当前目标 / 状态已变
            }
        }
    }
    if (releasedDevice) {
        _keyManager.removeKey(deviceID);  // 锁外调用（_keyManager 自管锁，同 releaseDevice）
        // ‼️ 刻意用 **Warning** 而非 Debug：这是安全相关异常（在途回包正试图给一架已释出的
        //    飞机重装密钥，也就是 `MAVLinkProtocol` 那两处自动建链闸重开的瞬间），同时是
        //    本修复**唯一**可观测的痕迹。本类别（`QGCLoggingCategory`）默认级别就是
        //    `QtWarningMsg`，用 Debug 在默认运行下根本不输出 —— 等于堵了洞却没留证。
        qCWarning(CryptoControllerLog) << "key fetched for a released device, dropped again" << deviceID;
        return;
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

    // 起点基准 = max(上行水位, 下行水位)，取其严格后继的奇数。
    //
    // 档①/档②**合并**（2026-09-27 用户裁定）：原实现档①（有上行水位）优先，导致
    // **接管方卡在自己的旧上行序列上**——一台 QGC 用「PX4 下行 nonce + 1」把 mavp2p
    // 的边缘防重放水位顶高后，接管的 QGC 仍按**自己的**上行水位 +2，两者步长相同
    // ⇒ 差距永不缩小 ⇒ 该台上行被持续判重丢弃、很久才恢复（QGC 无 ack、察觉不到，
    // 规范 §2.5）。合并后两台同源：一律从 PX4 当前下行水位续起。
    //
    // 正常情形「下行恒领先上行」（建链时 DOWNLINK_INIT_OFFSET 给出余量，见下），故
    // 本式结果恒等于「下行 + 1」，与规范 §3.2.4.2 的重启恢复规则同形；下行稀疏、
    // 上行领先时取上行，避免把已发出的水位拉回去。
    uint64_t upLast = 0;
    uint64_t downLast = 0;
    const bool hasUp = _replayGuard.peekUpLastNonce(_activeDeviceID, upLast);
    const bool hasDown = _replayGuard.peekDownLastNonce(_activeDeviceID, downLast);

    if (hasUp || hasDown) {
        const uint64_t last = (hasUp && hasDown) ? (upLast > downLast ? upLast : downLast)
                                                 : (hasUp ? upLast : downLast);

        // 安全性依赖「下行 counter 恒领先上行」：DOWNLINK_INIT_OFFSET（=1001，**PX4
        // 侧常量**，QGC 仓库不持有；见规范 §2.5/附录 A）给出 500 帧余量 ⇒ 只要
        // N_up − N_down ≤ 500 就有 Y+1 > 接管前的上行水位。
        // ⚠️ 这是**现状约束**而非未来风险：摇杆 MANUAL_CONTROL 现在就走本加密发送
        // 路径（默认 25 Hz、上限 200 Hz）持续消耗余量；是否真被击穿取决于当时的
        // 下行速率，本侧无法测定。完整论证见实现说明文档 §3.2.4.2。
        // ⚠️ 范围守卫必须在算式**之前**（照抄 PX4 next_tx_counter）：last 越界时
        // last+2 会回绕成小奇数，而下方 2^62 守卫判在回绕之后、根本拦不住。
        // 实际只有下行可能越界——上行水位由下方「≥ 2^62 拒发」守卫保证恒 < 2^62。
        if (last >= (1ull << 62)) {
            qCWarning(CryptoControllerLog)
                << "downlink counter out of range, refuse to send:" << last << "device" << _activeDeviceID;
            return false;
        }
        // (last & 1u) 分支是防御：下行序列异常为奇数时不得产出偶数上行 counter。
        outCounter = (last & 1u) ? (last + 2) : (last + 1);
    } else {
        // 上行与下行水位皆空 ⇒ 沿用建链首帧的随机起点，避免重启后从 1 重来导致
        // nonce 复用（规范 §2.5）。§3.2.4.2 只禁止用确定性或旧 counter，随机起点不违反。
        // 能走到这里有**三**条路：① 明文待命心跳触发 beginLinking——此时 QGC 是建链发起方，
        // §2.5 的随机起点正是正确规则；② 同一次 receiveBytes 内先提交下行、后建链
        // （微秒级窗口）；③ **释出后重建链**（`releaseDevice` 把水位清了之后）。
        // ⚠️ 三条路里只有 ③ 的安全性由本端自己保证——它依赖同一批删掉的密钥（见
        //    releaseDevice 的因果链）：密钥若还在，那两个自动建链入口会把飞机接回来，
        //    而那时 PX4 的残留水位与我们的随机起点只是"可能"相容。
        // 注意：本档**不是**一次性抉择——2026-10-03 起 `releaseDevice` 是生产路径上
        // **唯一**的 `resetReplay` 调用方（此前只有测试调它），但若进程内先走本档、
        // 再收到下行，下一帧即按上式改取「下行 + 1」。
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
