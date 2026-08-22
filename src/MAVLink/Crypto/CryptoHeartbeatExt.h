#pragma once

/// 加密心跳扩展基础状态（协议 60822.0「加密心跳扩展基础状态.md」§4）。
///
/// PX4 建链后精简 GCS 链路的独立遥测流，把基础状态并入加密心跳的 **AES-GCM 加密明文**：
///   `加密明文 = deviceID(4B) || HEARTBEAT payload(9B) || EXT(37B)`（50B），
///   加密后 block = counter(8) + ciphertext(50) + tag(16) = 74B。
/// 本模块解析 **decryptFrame 解密后还原的标准帧**（已剥离 deviceID、还原 10B V2 头，
/// payload = HEARTBEAT 9B + EXT 37B）里的 EXT（37B 小端序）→ 可读结构，供 QGC 更新车辆
/// 位置/速度/姿态/GPS/电池/模式，替代原独立遥测流（EXT 是唯一遥测来源）。
///
/// 明文待命心跳（payload=9B，无 EXT）不适用本模块。

#include <cstdint>

#include <QList>

// 前向声明 mavlink_message_t（QGC 经 mavlink_types.h 定义；打包函数在 .cc 引入 mavlink 头）
typedef struct __mavlink_message mavlink_message_t;

namespace MAVLinkCrypto {

/// EXT 37 字节（小端序）展开后的基础状态。
struct HeartbeatExt
{
    /// EXT 固定长度。
    static constexpr int kExtSize = 37;
    /// lat/lon/alt 无效哨兵（估算未就绪/NaN）。
    static constexpr int32_t kInvalidInt32 = INT32_MIN;
    /// vx/vy/vz 无效哨兵。
    static constexpr int16_t kInvalidInt16 = INT16_MIN;

    int32_t lat = kInvalidInt32;   // degE7（float64 度 × 10⁷ 取整）
    int32_t lon = kInvalidInt32;   // degE7
    int32_t alt = kInvalidInt32;   // mm，MSL（float32 米 × 1000）
    int16_t vx = kInvalidInt16;    // cm/s，北向速度（NED，m/s × 100）
    int16_t vy = kInvalidInt16;    // cm/s，东向速度
    int16_t vz = kInvalidInt16;    // cm/s，地向速度
    float   roll = 0.0f;           // rad（四元数→欧拉）
    float   pitch = 0.0f;          // rad
    float   yaw = 0.0f;            // rad
    uint8_t fixType = 0;           // GPS 定位类型（SensorGps.fix_type，0=无定位）
    uint8_t satellitesUsed = 0;    // GPS 可见卫星数
    uint16_t voltage = 0;          // mV，电池电压（float32 V × 1000，0=无效）
    int8_t  remaining = -1;        // %，电池剩余（0-100，-1=未知）
    uint8_t navState = 0;          // 导航模式（VehicleStatus.nav_state）
    uint8_t armingState = 0;       // 武装状态（VehicleStatus.arming_state）

    /// lat/lon 均有效（非哨兵）→ 位置可信。
    bool hasPosition() const { return lat != kInvalidInt32 && lon != kInvalidInt32; }
    /// alt 有效。
    bool hasAltitude() const { return alt != kInvalidInt32; }
    /// 至少一个速度分量有效。
    bool hasVelocity() const { return vx != kInvalidInt16 || vy != kInvalidInt16 || vz != kInvalidInt16; }
    /// 电池数据有效（电压>0 或剩余>=0）→ 有电池接入。
    bool hasBattery() const { return voltage > 0 || remaining >= 0; }
};

/// 从 EXT 起始字节解析 37 字节小端结构。len 必须 >= 37，否则返回 false。
bool parseHeartbeatExt(const uint8_t* extBytes, int extLen, HeartbeatExt* out);

/// 从加密心跳解密后的标准帧解析 EXT。
/// 仅当 msgid==HEARTBEAT 且 payload 长度 > 9（加密心跳带 EXT）时成功；
/// 明文待命心跳（payload=9B）、非 HEARTBEAT、非 V2 帧返回 false。
bool parseHeartbeatExtFromFrame(uint32_t msgid, const uint8_t* frame, int frameLen, HeartbeatExt* out);

/// 把加密心跳 EXT 打包成标准遥测消息（GLOBAL_POSITION_INT / ATTITUDE / GPS_RAW_INT /
/// BATTERY_STATUS），供 QGC Vehicle 消费（替代 PX4 精简后的独立遥测流）。
/// sysid/compid 取自解密标准帧头 plainFrame[5]/[6]（decryptFrame 已从 deviceID 还原）。
/// 哨兵字段不注入假值：位置/GPS 要求 lat/lon/alt 全有效才打包对应消息；
/// 电压未知（0）→ BATTERY_STATUS 用 UINT16_MAX（显示 NaN）；无电池数据 → 不打包。
/// 返回空列表 = 无有效遥测可注入。
QList<mavlink_message_t> buildHeartbeatExtTelemetry(const uint8_t* plainFrame, const HeartbeatExt& ext);

} // namespace MAVLinkCrypto
