#include "CryptoController.h"

#include <algorithm>

#include <openssl/crypto.h>

#include <QtCore/QApplicationStatic>
#include <QtCore/QFile>
#include <QtCore/QLoggingCategory>
#include <QtCore/QRandomGenerator>

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
    if (_replayGuard.peekLastNonce(_activeDeviceID, last)) {
        // 取严格大于 last 的最小奇数
        outCounter = (last & 1u) ? (last + 2) : (last + 1);
    } else {
        // 首帧：加密安全随机 62 位奇数起点（避免重启后从 1 重来导致 nonce 复用，规范 §2.5）
        outCounter = randomOddCounter();
    }

    // 达到 COUNTER_MAX = 2^62 时停止发送（重新建链换密钥），不得越界（规范 §2.5）
    if (outCounter >= (1ull << 62)) {
        qCWarning(CryptoControllerLog) << "outgoing counter reached 2^62, refuse to send (re-key required)";
        return false;
    }

    // 原子预留：更新 lastNonce（outCounter 必 > last，accept 必成功）
    (void) _replayGuard.accept(_activeDeviceID, outCounter);
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
}

void CryptoController::resetReplay(DeviceID deviceID)
{
    _replayGuard.reset(deviceID);
}

} // namespace MAVLinkCrypto
