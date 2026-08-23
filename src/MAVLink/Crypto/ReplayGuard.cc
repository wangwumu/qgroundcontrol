#include "ReplayGuard.h"

namespace MAVLinkCrypto {

bool ReplayGuard::isAcceptable(DeviceID deviceID, uint64_t counter) const
{
    const QMutexLocker locker(&_mutex);

    const auto it = _downLastNonce.constFind(deviceID);
    if (it == _downLastNonce.constEnd()) {
        return true; // 首帧：unset → 通过判定（不登记）
    }
    return counter > it.value();
}

void ReplayGuard::commit(DeviceID deviceID, uint64_t counter)
{
    const QMutexLocker locker(&_mutex);
    _downLastNonce.insert(deviceID, counter);
}

bool ReplayGuard::accept(DeviceID deviceID, uint64_t counter)
{
    const QMutexLocker locker(&_mutex);

    const auto it = _upLastNonce.constFind(deviceID);
    if (it == _upLastNonce.constEnd() || counter > it.value()) {
        // 首帧或严格递增 → 接受并登记
        _upLastNonce.insert(deviceID, counter);
        return true;
    }

    // counter <= lastNonce → 重放/乱序
    return false;
}

void ReplayGuard::reset(DeviceID deviceID)
{
    const QMutexLocker locker(&_mutex);
    _upLastNonce.remove(deviceID);
    _downLastNonce.remove(deviceID);
}

void ReplayGuard::clear()
{
    const QMutexLocker locker(&_mutex);
    _upLastNonce.clear();
    _downLastNonce.clear();
}

bool ReplayGuard::hasDevice(DeviceID deviceID) const
{
    const QMutexLocker locker(&_mutex);
    return _upLastNonce.contains(deviceID);
}

bool ReplayGuard::peekLastNonce(DeviceID deviceID, uint64_t& outLast) const
{
    const QMutexLocker locker(&_mutex);
    const auto it = _upLastNonce.constFind(deviceID);
    if (it == _upLastNonce.constEnd()) {
        return false;
    }
    outLast = it.value();
    return true;
}

} // namespace MAVLinkCrypto
