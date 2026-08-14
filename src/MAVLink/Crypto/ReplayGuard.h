#pragma once

/// 防重放状态（依据 `docs/10_deviceID与payload加密公共规范.md` §2.5/§2.6）。
///
/// 每个接收方按 deviceID 维护全局 lastNonce（实际存 counter 值，因同一 deviceID 下
/// nonce 字典序 = counter 数值序）。收到帧后：
///   counter >  lastNonce[deviceID] → 接受，并更新 lastNonce
///   counter <= lastNonce[deviceID] → 判定重放/乱序，丢弃
///
/// 首帧（unset）即接受并登记。线程安全（接收链路可能多线程）。

#include <QtCore/QHash>
#include <QtCore/QMutex>
#include <QtCore/QMutexLocker>

#include "DeviceID.h"

namespace MAVLinkCrypto {

class ReplayGuard
{
public:
    ReplayGuard() = default;
    ~ReplayGuard() = default;

    ReplayGuard(const ReplayGuard&) = delete;
    ReplayGuard& operator=(const ReplayGuard&) = delete;

    /// 检查 counter 是否可接受（本次 > last），并原子更新 last。
    /// @param deviceID 设备标识（从帧头重组）
    /// @param counter  每帧唯一 counter（从 payload block 明文前 8 字节读取）
    /// @return true=接受（首帧或严格递增）；false=重放/乱序（counter <= last）
    bool accept(DeviceID deviceID, uint64_t counter);

    /// 重置指定设备的 lastNonce（如建链时清历史序列）。
    void reset(DeviceID deviceID);

    /// 清空所有状态（链路切换、断链重连时）。
    void clear();

    /// 是否已登记指定设备（用于诊断/日志）。
    bool hasDevice(DeviceID deviceID) const;

    /// 只读查询指定设备的 lastNonce 值（不修改状态）。
    /// @return true=已登记，outLast 填充；false=未登记（unset）
    bool peekLastNonce(DeviceID deviceID, uint64_t& outLast) const;

private:
    QHash<DeviceID, uint64_t> _lastNonce;
    mutable QMutex _mutex;
};

} // namespace MAVLinkCrypto
