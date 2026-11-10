#pragma once

/// 加密心跳扩展基础状态（协议 61013.0「加密心跳扩展基础状态.md」§4）。
///
/// PX4 建链后精简 GCS 链路的独立遥测流，把基础状态并入加密心跳的 **AES-GCM 加密明文**：
///   `加密明文 = deviceID(4B) || HEARTBEAT payload(9B) || EXT(84B)`（97B），
///   加密后 block = counter(8) + ciphertext(97) + tag(16) = 121B。
/// 本模块解析 **decryptFrame 解密后还原的标准帧**（已剥离 deviceID、还原 10B V2 头，
/// payload = HEARTBEAT 9B + EXT 84B）里的 EXT（84B 小端序）→ 可读结构，供 QGC 更新车辆
/// 位置/速度/姿态/GPS/电池/模式/相对高度/空速/VTOL 阶段/起降/电流/温度/异常/时间戳，
/// 替代原独立遥测流（EXT 是唯一遥测来源）。
///
/// 兼容：60822.0 = 37B，60824.0 追加到 55B，60825.0 追加到 84B。解析按长度分段累计
/// （≥37 / ≥55 / ≥63 / ≥72 / ≥84），旧帧缺的段保持默认，不越界读取。
///
/// 明文待命心跳（payload=9B，无 EXT）不适用本模块。

#include <cstdint>

#include <QList>

// 前向声明 mavlink_message_t（QGC 经 mavlink_types.h 定义；打包函数在 .cc 引入 mavlink 头）
typedef struct __mavlink_message mavlink_message_t;

namespace MAVLinkCrypto {

/// EXT 84 字节（小端序）展开后的基础状态（60825.0；前 37B 为 60822.0 兼容基段，
/// 37–54 为 60824.0 段）。
struct HeartbeatExt
{
    /// EXT 完整固定长度（60825.0 = 84B）。
    static constexpr int kExtSize = 84;
    /// 兼容最小长度（60822.0 基段 37B）：len ∈ [37,55) 时仅解析前 37B，新字段保持默认。
    static constexpr int kExtBaseSize = 37;
    /// 60824.0 段结束长度（55B）：len >= 55 才有 timeBootMs…failsafe。
    /// ⚠️ hasExtendedFields 仍按本长度判定，**不要**改成 kExtSize（84）——否则 55B 帧会退化成
    /// 「无扩展段」，VTOL/landed 将停止注入。
    static constexpr int kExt60824Size = 55;
    /// 60825.0 系统状态段结束长度（72B）：len >= 72 才有 health/load/gnss/vib。
    static constexpr int kExtSystemStatusSize = 72;
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

    // ── 60825.0 新增（offset 55-83，尾部追加，向后兼容）──────────
    uint64_t gpsUtcUs = 0;        // µs，GPS UTC（0 = 未定位/未同步）
    uint32_t sensorsHealth = 0;   // SYS_STATUS base 健康位（PX4 已补未映射位为 1）
    uint8_t loadPct = 255;        // %，CPU 占用（255 = 未知）
    uint8_t gnssErrors = 0;       // GNSS 自检故障位 bit0-6
    uint8_t gnssJam = 0;          // 干扰 0-3
    uint8_t gnssSpoof = 0;        // 欺骗 0-3
    uint8_t gnssAuth = 0;         // 认证 0-3（3 = OK）
    uint8_t gnssRaim = 0;         // RAIM 0-3
    uint8_t vibX = 0;             // 振动等级 0-7（x = 陀螺锥形运动）
    uint8_t vibY = 0;             // 振动等级 0-7（y = 陀螺高频）
    uint8_t vibZ = 0;             // 振动等级 0-7（z = 加速度计高频）
    uint8_t vibClip = 0;          // bit0=X bit1=Y bit2=Z
    bool vibValid = false;        // 振动等级有效
    uint8_t reserved[12] = {};    // 保留区原样（reserved[0] = 版本号）

    /// 是否存在 60824.0 扩展段（offset 37-54）。parse 时 len >= kExt60824Size(55) 才置 true；
    /// 37B 兼容帧（旧 PX4）为 false，此时 timeBootMs/vtolState/landed/failsafe 的 0 是
    /// "未提供"而非真实 0 值，注入/显示须据此区分（避免伪"开机瞬间"时间戳）。
    bool hasExtendedFields = false;
    /// 是否存在 60825.0 的 gps_utc_us（len >= 63）。
    bool hasGpsUtc = false;
    /// 是否存在 60825.0 的系统状态段（len >= 72）。false 时新列/伪报文一律不产生，
    /// 不得把「未提供」的 0 当作 health=全部故障或 load=0。
    bool hasSystemStatus = false;
    /// 是否存在保留区（len >= 84）。
    bool hasReserved = false;

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

/// 从 EXT 起始字节解析小端结构。len >= kExtBaseSize(37) 才解析（37B 兼容），
/// 之后各段累计独立解析：>=55 → 60824 段，>=63 → gps_utc，>=72 → 系统状态段，
/// >=84 → 保留区。缺段字段保持默认。返回 false 仅当 len 过短。
bool parseHeartbeatExt(const uint8_t* extBytes, int extLen, HeartbeatExt* out);

/// 从加密心跳解密后的标准帧解析 EXT。
/// 仅当 msgid==HEARTBEAT 且 payload 长度 > 9（加密心跳带 EXT）时成功；
/// 明文待命心跳（payload=9B）、非 HEARTBEAT、非 V2 帧返回 false。
bool parseHeartbeatExtFromFrame(uint32_t msgid, const uint8_t* frame, int frameLen, HeartbeatExt* out);

/// 把加密心跳 EXT 打包成标准遥测消息（GLOBAL_POSITION_INT / ATTITUDE / GPS_RAW_INT /
/// BATTERY_STATUS / VFR_HUD / EXTENDED_SYS_STATE），供 QGC Vehicle 消费（替代 PX4 精简后的独立遥测流）。
/// 60825.0 追加（仅 hasSystemStatus，≥72B）：SYS_STATUS（健康位/CPU 负载）、
/// GNSS_INTEGRITY（GNSS 四状态）、VIBRATION（振动档位中位）。
/// sysid/compid 取自解密标准帧头 plainFrame[5]/[6]（decryptFrame 已从 deviceID 还原）。
/// 哨兵字段不注入假值：位置/GPS 要求 lat/lon/alt 全有效才打包对应消息；
/// 电压未知（0）→ BATTERY_STATUS 用 UINT16_MAX（显示 NaN）；无电池数据 → 不打包。
/// ATTITUDE / VFR_HUD 恒打包（哨兵分量按 0 计，两者都不依赖位置）；
/// EXTENDED_SYS_STATE 仅 55B 扩展帧打包——37B 兼容帧的 landed/vtolState 是「未提供」而非
/// 「在地面/非 VTOL」，注入会把 QGC 的 `flying`/`landing`/`vtolInFwdFlight` 钉死在错误值上。
/// 返回空列表 = 无有效遥测可注入。
QList<mavlink_message_t> buildHeartbeatExtTelemetry(const uint8_t* plainFrame, const HeartbeatExt& ext);

} // namespace MAVLinkCrypto
