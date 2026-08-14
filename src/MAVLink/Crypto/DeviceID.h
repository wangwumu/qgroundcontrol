#pragma once

/// 32 位 deviceID 重组工具。
///
/// 依据 `docs/10_deviceID与payload加密公共规范.md` 第一部分：
/// 将 MAVLink V2 帧头的 4 个单字节字段 —— incompatFlag(偏移2)、compatFlag(偏移3)、
/// systemID(偏移5)、componentID(偏移6) —— 合并解读为一个 32 位无符号整型 deviceID。
///
/// 编码公式: deviceID = (inc << 24) | (com << 16) | (sys << 8) | comp
/// 解码公式: inc  = (deviceID >> 24) & 0xFF
///           com  = (deviceID >> 16) & 0xFF
///           sys  = (deviceID >> 8)  & 0xFF
///           comp =  deviceID        & 0xFF
///
/// 约束（规范 §1.4）：deviceID 第 3 字节（incompatFlag）的 bit0 必须为 0，
/// 等价 `deviceID & 0x01000000 == 0`，以避免标准 MAVLink 解析器误判为带签名帧。

#include <cstdint>

#include <mavlink_types.h>

namespace MAVLinkCrypto {

/// 32 位设备标识类型。纯整数，帧内不分层语义（租户/站点归属由数据库决定）。
using DeviceID = uint32_t;

/// 无效/未登记的 deviceID 哨兵值。
inline constexpr DeviceID kInvalidDeviceID = 0;

// ---------------------------------------------------------------------------
// 纯位操作（不依赖 mavlink 结构体）
// ---------------------------------------------------------------------------

/// 编码：4 个单字节字段 → deviceID。
inline constexpr DeviceID makeDeviceID(uint8_t incompatFlag, uint8_t compatFlag, uint8_t systemID,
                                       uint8_t componentID)
{
    return (static_cast<DeviceID>(incompatFlag) << 24) | (static_cast<DeviceID>(compatFlag) << 16) |
           (static_cast<DeviceID>(systemID) << 8) | static_cast<DeviceID>(componentID);
}

/// 解码：deviceID → incompatFlag（最高字节）。
inline constexpr uint8_t incompatFlag(DeviceID id)
{
    return static_cast<uint8_t>((id >> 24) & 0xFFu);
}

/// 解码：deviceID → compatFlag。
inline constexpr uint8_t compatFlag(DeviceID id)
{
    return static_cast<uint8_t>((id >> 16) & 0xFFu);
}

/// 解码：deviceID → systemID（第 3 字节）。
inline constexpr uint8_t systemID(DeviceID id)
{
    return static_cast<uint8_t>((id >> 8) & 0xFFu);
}

/// 解码：deviceID → componentID（最低字节）。
inline constexpr uint8_t componentID(DeviceID id)
{
    return static_cast<uint8_t>(id & 0xFFu);
}

/// 约束校验（规范 §1.4）：incompatFlag 的 bit0 必须为 0。
/// true = 合法（不会触发 MAVLink 签名误判）；false = 非法。
inline constexpr bool hasValidSignatureBit(DeviceID id)
{
    return (id & 0x01000000u) == 0;
}

// ---------------------------------------------------------------------------
// mavlink_message_t 互转
// ---------------------------------------------------------------------------

/// 从 mavlink_message_t 的帧头 4 字段重组 deviceID。
inline DeviceID fromMessage(const mavlink_message_t& message)
{
    return makeDeviceID(message.incompat_flags, message.compat_flags, message.sysid, message.compid);
}

/// 将 deviceID 拆分写入 mavlink_message_t 的帧头 4 字段。
/// 调用方须确保 deviceID 满足 hasValidSignatureBit()，否则标准解析器会误判签名。
inline void toMessage(DeviceID id, mavlink_message_t& message)
{
    message.incompat_flags = incompatFlag(id);
    message.compat_flags = compatFlag(id);
    message.sysid = systemID(id);
    message.compid = componentID(id);
}

} // namespace MAVLinkCrypto
