#include "ReplayGuard.h"

namespace MAVLinkCrypto {

bool ReplayGuard::accept(DeviceID deviceID, uint64_t counter)
{
    const QMutexLocker locker(&_mutex);

    const auto it = _lastNonce.constFind(deviceID);
    if (it == _lastNonce.constEnd()) {
        // 首帧：unset → 接受并登记
        _lastNonce.insert(deviceID, counter);
        return true;
    }

    if (counter > it.value()) {
        _lastNonce.insert(deviceID, counter);
        return true;
    }

    // counter <= lastNonce → 重放/乱序
    return false;
}

void ReplayGuard::reset(DeviceID deviceID)
{
    const QMutexLocker locker(&_mutex);
    _lastNonce.remove(deviceID);
}

void ReplayGuard::clear()
{
    const QMutexLocker locker(&_mutex);
    _lastNonce.clear();
}

bool ReplayGuard::hasDevice(DeviceID deviceID) const
{
    const QMutexLocker locker(&_mutex);
    return _lastNonce.contains(deviceID);
}

bool ReplayGuard::peekLastNonce(DeviceID deviceID, uint64_t& outLast) const
{
    const QMutexLocker locker(&_mutex);
    const auto it = _lastNonce.constFind(deviceID);
    if (it == _lastNonce.constEnd()) {
        return false;
    }
    outLast = it.value();
    return true;
}

} // namespace MAVLinkCrypto
