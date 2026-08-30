#pragma once

/// 加密心跳扩展基础状态（协议 60824.0「加密心跳扩展基础状态.md」§4）。
///
/// PX4 建链后精简 GCS 链路的独立遥测流，把基础状态并入加密心跳的 **AES-GCM 加密明文**：
///   `加密明文 = deviceID(4B) || HEARTBEAT payload(9B) || EXT(55B)`（68B），
///   加密后 block = counter(8) + ciphertext(68) + tag(16) = 92B。
/// 本模块解析 **decryptFrame 解密后还原的标准帧**（已剥离 deviceID、还原 10B V2 头，
/// payload = HEARTBEAT 9B + EXT 55B）里的 EXT（55B 小端序）→ 可读结构，供 QGC 更新车辆
/// 位置/速度/姿态/GPS/电池/模式/相对高度/空速/VTOL 阶段/起降/电流/温度/异常/时间戳，
/// 替代原独立遥测流（EXT 是唯一遥测来源）。
///
/// 60824.0 在 60822.0 的 EXT(37B) 基础上**尾部追加 9 字段**扩展为 55B，向后兼容：
/// 旧接收方解析前 37B 不受影响；QGC 收到旧版 37B EXT 时按 60822.0 解析前 37B、
/// 新增字段保持哨兵/默认（安全忽略）。
///
/// 明文待命心跳（payload=9B，无 EXT）不适用本模块。

#include <cstdint>

#include <QList>

// 前向声明 mavlink_message_t（QGC 经 mavlink_types.h 定义；打包函数在 .cc 引入 mavlink 头）
typedef struct __mavlink_message mavlink_message_t;

namespace MAVLinkCrypto {

/// EXT 55 字节（小端序）展开后的基础状态（60824.0；前 37B 为 60822.0 兼容基段）。
struct HeartbeatExt
{
    /// EXT 完整固定长度（60824.0）。
    static constexpr int kExtSize = 55;
    /// 兼容最小长度（60822.0 基段 37B）：len ∈ [37,55) 时仅解析前 37B，新字段保持默认。
    static constexpr int kExtBaseSize = 37;
    /// lat/lon/alt/rel_alt 无效哨兵（估算未就绪/NaN/home 未设）。
    static constexpr int32_t kInvalidInt32 = INT32_MIN;
    /// vx/vy/vz/airspeed/current/temperature 无效哨兵。
    static constexpr int16_t kInvalidInt16 = INT16_MIN;
    /// airspeed_source 无效哨兵（DISABLED=-1 → 0xFF）。
    static constexpr uint8_t kAirspeedSourceDisabled = 0xFF;

    // ── 60822.0 基段（offset 0-36，不变）──────────────────────────
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

    // ── 60824.0 新增（offset 37-54，尾部追加，向后兼容）──────────
    uint32_t timeBootMs = 0;                          // ms，飞控开机累计时间（hrt_absolute_time()/1000）
    int32_t relAlt = kInvalidInt32;                   // mm，相对起飞点高度（vgp.alt − home.alt，home 有效时）
    int16_t airspeed = kInvalidInt16;                 // cm/s，真空速 TAS（true_airspeed_m_s × 100）
    uint8_t airspeedSource = kAirspeedSourceDisabled; // 空速来源（0xFF=DISABLED，纯多旋翼不发布）
    uint8_t vtolState = 0;                            // VTOL 转换阶段（VtolVehicleStatus.vehicle_vtol_state）
    uint8_t landed = 0;                               // 位掩码：bit0=landed, bit1=ground_contact, bit2=in_ground_effect
    int16_t current = kInvalidInt16;                  // 0.1A，电池电流（current_a × 10）
    int16_t temperature = kInvalidInt16;              // 0.1°C，环境温度（ambient_temperature × 10）
    uint8_t failsafe = 0;                             // 位掩码：bit0=failsafe, bit1=gcs_connection_lost, bit2-7=failure_detector 低 6 位

    /// 是否存在 60824.0 扩展段（offset 37-54）。parse 时 len >= kExtSize(55) 才置 true；
    /// 37B 兼容帧（旧 PX4）为 false，此时 timeBootMs/vtolState/landed/failsafe 的 0 是
    /// "未提供"而非真实 0 值，注入/显示须据此区分（避免伪"开机瞬间"时间戳）。
    bool hasExtendedFields = false;

    /// lat/lon 均有效（非哨兵）→ 位置可信。
    bool hasPosition() const { return lat != kInvalidInt32 && lon != kInvalidInt32; }
    /// alt 有效。
    bool hasAltitude() const { return alt != kInvalidInt32; }
    /// 至少一个速度分量有效。
    bool hasVelocity() const { return vx != kInvalidInt16 || vy != kInvalidInt16 || vz != kInvalidInt16; }
    /// 电池数据有效（电压>0 或剩余>=0）→ 有电池接入。
    bool hasBattery() const { return voltage > 0 || remaining >= 0; }
    /// 相对高度有效。
    bool hasRelativeAltitude() const { return relAlt != kInvalidInt32; }
    /// 电流有效。
    bool hasCurrent() const { return current != kInvalidInt16; }
    /// 温度有效。
    bool hasTemperature() const { return temperature != kInvalidInt16; }
};

/// 从 EXT 起始字节解析小端结构。len >= kExtBaseSize(37) 才解析（37B 兼容）；
/// len >= kExtSize(55) 时解析全部 55B，否则新增字段保持默认哨兵。返回 false 仅当 len 过短。
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
