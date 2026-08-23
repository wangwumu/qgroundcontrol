#pragma once

/// 防重放状态。按 deviceID + 方向（上行/下行）维护独立 lastNonce（实际存 counter 值）。
///
/// 注意：这是对 `docs/10_deviceID与payload加密公共规范.md` §2.6「单全局 lastNonce」模型的
/// **刻意偏离**（与 PX4 侧 `_rx_last_nonce`/`_tx_last_nonce` 分离一致）。理由：上行
/// （发送侧 QGC→PX4，counter 为奇数）与下行（接收侧 PX4→QGC，counter 为偶数）是两条
/// 独立序列，若共用单 map，发送侧 peekLastNonce 会读到对端下行 counter，导致上行 counter
/// 跳变、违反「每次 +2」规则。拆分不影响防重放语义（各方向仍严格递增）。
/// 协议 §2.6 要求两阶段：
///   第 3 步  仅判定：counter >  lastNonce[deviceID] ？       → isAcceptable()
///   第 9 步  认证通过后才更新 lastNonce                      → commit()
///
/// 首帧（unset）即判定通过。线程安全（接收链路可能多线程）。

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

    /// 下行（接收侧，PX4→QGC）纯判定（协议 §2.6 第 3 步）：
    /// counter > downLastNonce[deviceID]？（首帧未登记即通过）。不修改状态。
    bool isAcceptable(DeviceID deviceID, uint64_t counter) const;

    /// 下行认证通过后提交（协议 §2.6 第 9 步）：更新 downLastNonce[deviceID] = counter。
    /// 必须在解密与 tag 认证成功之后调用，防止未认证帧污染重放窗口。
    void commit(DeviceID deviceID, uint64_t counter);

    /// 上行（发送侧 QGC→PX4）判定 + 更新（一次性原子操作）。
    /// 仅用于发送侧原子预留 counter（生成的 counter 必 > upLast，accept 必成功）；
    /// 接收侧请使用 isAcceptable() + commit() 两阶段，勿用本方法。
    bool accept(DeviceID deviceID, uint64_t counter);

    /// 重置指定设备的 up/down lastNonce（如建链时清历史序列）。
    void reset(DeviceID deviceID);

    /// 清空所有状态（链路切换、断链重连时）。
    void clear();

    /// 上行是否已登记指定设备（用于诊断/日志）。
    bool hasDevice(DeviceID deviceID) const;

    /// 只读查询指定设备的上行 lastNonce 值（不修改状态）。
    /// @return true=已登记，outLast 填充；false=未登记（unset）
    bool peekLastNonce(DeviceID deviceID, uint64_t& outLast) const;

private:
    QHash<DeviceID, uint64_t> _upLastNonce;    ///< 上行（发送侧）lastNonce：QGC→PX4，奇数序列
    QHash<DeviceID, uint64_t> _downLastNonce;  ///< 下行（接收侧）lastNonce：PX4→QGC，偶数序列
    mutable QMutex _mutex;
};

} // namespace MAVLinkCrypto
