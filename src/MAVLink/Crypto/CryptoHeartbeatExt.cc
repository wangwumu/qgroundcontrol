#include "CryptoHeartbeatExt.h"

#include "CryptoCodec.h"
#include "MAVLinkLib.h"
#include "development/mavlink_msg_gnss_integrity.h"

#include <QtMath>

#include <cmath>
#include <cstring>

namespace MAVLinkCrypto {

namespace {

// 小端序读取辅助（无 endian 依赖：显式字节组装）。
inline uint32_t readU32LE(const uint8_t* p)
{
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline int32_t readI32LE(const uint8_t* p)
{
    return static_cast<int32_t>(readU32LE(p));
}
inline uint16_t readU16LE(const uint8_t* p)
{
    return uint16_t(uint16_t(p[0]) | (uint16_t(p[1]) << 8));
}
inline uint64_t readU64LE(const uint8_t* p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= uint64_t(p[i]) << (8 * i);
    }
    return v;
}
inline int16_t readI16LE(const uint8_t* p)
{
    return static_cast<int16_t>(readU16LE(p));
}
inline float readF32LE(const uint8_t* p)
{
    const uint32_t u = readU32LE(p);
    float f = 0.0f;
    std::memcpy(&f, &u, sizeof(f));
    return f;
}

} // namespace

bool parseHeartbeatExt(const uint8_t* extBytes, int extLen, HeartbeatExt* out)
{
    // 兼容最小 37B（60822.0）；len∈[37,55) 只解析前 37B，新增字段保持默认哨兵。
    if (extBytes == nullptr || out == nullptr || extLen < HeartbeatExt::kExtBaseSize) {
        return false;
    }
    HeartbeatExt e;
    // 60822.0 基段（offset 0-36）
    e.lat            = readI32LE(extBytes + 0);
    e.lon            = readI32LE(extBytes + 4);
    e.alt            = readI32LE(extBytes + 8);
    e.vx             = readI16LE(extBytes + 12);
    e.vy             = readI16LE(extBytes + 14);
    e.vz             = readI16LE(extBytes + 16);
    e.roll           = readF32LE(extBytes + 18);
    e.pitch          = readF32LE(extBytes + 22);
    e.yaw            = readF32LE(extBytes + 26);
    e.fixType        = extBytes[30];
    e.satellitesUsed = extBytes[31];
    e.voltage        = readU16LE(extBytes + 32);
    e.remaining      = static_cast<int8_t>(extBytes[34]);
    e.navState       = extBytes[35];
    e.armingState    = extBytes[36];
    // 60824.0 新增字段（offset 37-54）：仅当 len >= 55B 时解析，否则保持默认哨兵
    if (extLen >= HeartbeatExt::kExt60824Size) {
        e.hasExtendedFields = true;
        e.timeBootMs     = readU32LE(extBytes + 37);
        e.relAlt         = readI32LE(extBytes + 41);
        e.airspeed       = readI16LE(extBytes + 45);
        e.airspeedSource = extBytes[47];
        e.vtolState      = extBytes[48];
        e.landed         = extBytes[49];
        e.current        = readI16LE(extBytes + 50);
        e.temperature    = readI16LE(extBytes + 52);
        e.failsafe       = extBytes[54];
    }
    // 60825.0 各段累计独立判断（不能写成降序 else-if：84B 帧也必须解析出 55B/37B 段）。
    // gps_utc_us（offset 55-62）
    if (extLen >= 63) {
        e.hasGpsUtc = true;
        e.gpsUtcUs  = readU64LE(extBytes + 55);
    }
    // 系统状态段（offset 63-71）
    if (extLen >= HeartbeatExt::kExtSystemStatusSize) {
        e.hasSystemStatus = true;
        e.sensorsHealth   = readU32LE(extBytes + 63);
        e.loadPct         = extBytes[67];
        e.gnssErrors      = uint8_t(extBytes[68] & 0x7F);
        const uint8_t gnssStates = extBytes[69];
        e.gnssJam   = uint8_t(gnssStates & 0x03);
        e.gnssSpoof = uint8_t((gnssStates >> 2) & 0x03);
        e.gnssAuth  = uint8_t((gnssStates >> 4) & 0x03);
        e.gnssRaim  = uint8_t((gnssStates >> 6) & 0x03);
        const uint8_t vibXy = extBytes[70];
        e.vibX = uint8_t(vibXy & 0x07);
        e.vibY = uint8_t((vibXy >> 3) & 0x07);
        // 列 bit0=X bit1=Y bit2=Z；线上 bit6/bit7 = clip_x/y、bit3 = clip_z
        e.vibClip = uint8_t(((vibXy >> 6) & 0x01) | (((vibXy >> 7) & 0x01) << 1));
        const uint8_t vibZFlags = extBytes[71];
        e.vibZ = uint8_t(vibZFlags & 0x07);
        if (vibZFlags & 0x08) {
            e.vibClip |= 0x04;
        }
        e.vibValid = (vibZFlags & 0x10) != 0;
    }
    // 保留区（offset 72-83）
    if (extLen >= HeartbeatExt::kExtSize) {
        e.hasReserved = true;
        std::memcpy(e.reserved, extBytes + 72, sizeof(e.reserved));
    }
    *out = e;
    return true;
}

bool parseHeartbeatExtFromFrame(uint32_t msgid, const uint8_t* frame, int frameLen, HeartbeatExt* out)
{
    if (frame == nullptr || out == nullptr || frameLen < static_cast<int>(kV2HeaderLen) + 1) {
        return false;
    }
    if (frame[0] != 0xFD) {
        return false; // 仅 MAVLink V2
    }
    if (msgid != 0) {
        return false; // 仅 HEARTBEAT（msgid=0；是否加密由调用方按帧路径判断）
    }
    const int payloadLen = frame[1];
    if (payloadLen <= 9) {
        return false; // 明文待命心跳（无 EXT）
    }
    // 帧长自校验：帧头声称的 payload 必须完整落在缓冲内（防截断/伪造 len 字段越界读）。
    // 调用方传完整标准帧（含 CRC）时 frameLen 更大，此检查恒保守成立。
    if (frameLen < static_cast<int>(kV2HeaderLen) + payloadLen) {
        return false;
    }
    // EXT 紧随 HEARTBEAT payload(9B) 之后（明文不含 deviceID——decryptFrame 已剥离）
    return parseHeartbeatExt(frame + static_cast<int>(kV2HeaderLen) + 9, payloadLen - 9, out);
}

QList<mavlink_message_t> buildHeartbeatExtTelemetry(const uint8_t* plainFrame, const HeartbeatExt& ext)
{
    QList<mavlink_message_t> msgs;
    if (plainFrame == nullptr) {
        return msgs;
    }
    // sysid/compid 取解密还原的标准帧头（decryptFrame 已从 deviceID 还原，与 Vehicle::_defaultComponentId 匹配）
    const uint8_t sysid = plainFrame[5];
    const uint8_t compid = plainFrame[6];

    // GLOBAL_POSITION_INT：lat/lon/alt 全有效才打包（哨兵不产生 0°N 0°E / 0m 假高度）。
    // 速度哨兵填 0（该消息无 NaN 可用，速度非本消息关键字段）。
    if (ext.hasPosition() && ext.hasAltitude()) {
        mavlink_message_t msg{};
        (void) mavlink_msg_global_position_int_pack(
            sysid, compid, &msg,
            ext.hasExtendedFields ? static_cast<uint32_t>(ext.timeBootMs) : 0, // time_boot_ms（60824.0；37B 兼容帧无扩展段 → 0=未知）
            ext.lat, ext.lon,                         // degE7
            ext.alt,                                  // alt(mm)，MSL
            ext.relAlt != HeartbeatExt::kInvalidInt32 ? ext.relAlt : 0, // relative_alt(mm，60824.0)
            ext.vx != HeartbeatExt::kInvalidInt16 ? ext.vx : 0, // cm/s
            ext.vy != HeartbeatExt::kInvalidInt16 ? ext.vy : 0,
            ext.vz != HeartbeatExt::kInvalidInt16 ? ext.vz : 0,
            UINT16_MAX);                              // hdg：EXT 无航向
        msgs.append(msg);
    }

    // ATTITUDE：EXT 无姿态哨兵（roll/pitch/yaw 恒有效），恒打包。
    {
        mavlink_message_t msg{};
        (void) mavlink_msg_attitude_pack(sysid, compid, &msg, 0, ext.roll, ext.pitch, ext.yaw, 0, 0, 0);
        msgs.append(msg);
    }

    // GPS_RAW_INT：lat/lon/alt 有效才打包；在 GLOBAL_POSITION_INT 之后（_handleGpsRawInt
    // 不会用 GPS 坐标覆盖已就位的位置）。
    if (ext.hasPosition() && ext.hasAltitude()) {
        mavlink_message_t msg{};
        (void) mavlink_msg_gps_raw_int_pack(
            sysid, compid, &msg,
            0,                                        // time_usec
            ext.fixType,                              // fix_type
            ext.lat, ext.lon,                         // degE7
            ext.alt,                                  // alt(mm)
            UINT16_MAX,                               // eph → hdop NaN
            UINT16_MAX,                               // epv → vdop NaN
            0,                                        // vel（EXT 无地速；vx/vy 为 NED 分量）
            UINT16_MAX,                               // cog → course NaN
            ext.satellitesUsed,                       // satellites_visible
            0,                                        // alt_ellipsoid
            0,                                        // h_acc
            0,                                        // v_acc
            0,                                        // vel_acc
            0,                                        // hdg_acc
            UINT16_MAX);                              // yaw → NaN
        msgs.append(msg);
    }

    // BATTERY_STATUS：有电池数据（电压/剩余）或电流/温度之一才打包；voltage==0（未知）
    // → UINT16_MAX（BatteryFactGroup 求和得 NaN）。门控含 hasCurrent/hasTemperature：
    // 仅电流/温度传感器在线（电压未知、remaining=-1）时不能丢弃整条消息。
    if (ext.hasBattery() || ext.hasCurrent() || ext.hasTemperature()) {
        mavlink_battery_status_t batt{};
        batt.id = 0;                                 // 默认电池槽位（BatteryFactGroup id 匹配）
        batt.voltages[0] = (ext.voltage == 0) ? UINT16_MAX : ext.voltage; // 总电压填 cell0
        for (int i = 1; i < 10; i++) {
            batt.voltages[i] = UINT16_MAX;           // 未知 cell
        }
        batt.current_battery = (ext.current != HeartbeatExt::kInvalidInt16) ? static_cast<int16_t>(ext.current * 10) : -1; // cA（EXT 0.1A × 10）
        batt.current_consumed = -1;
        batt.energy_consumed = -1;
        batt.battery_remaining = ext.remaining;      // -1 → percentRemaining NaN（无电池估算）
        batt.temperature = ext.hasTemperature() ? static_cast<int16_t>(ext.temperature * 10) : INT16_MAX; // cdegC（EXT 0.1°C × 10）；未知 → INT16_MAX
        batt.time_remaining = 0;
        mavlink_message_t msg{};
        (void) mavlink_msg_battery_status_encode(sysid, compid, &msg, &batt);
        msgs.append(msg);
    }

    // VFR_HUD：`groundSpeed` / `airSpeed` / `climbRate` 三个 Fact 的**唯一**来源
    // （`VehicleFactGroup::_handleVfrHud`）。恒打包——该消息无 NaN/哨兵语义，QGC handler
    // 也把无效值折成 0，故哨兵分量按 0 计。注意航向不在该 handler 里：`heading` 由上面的
    // ATTITUDE.yaw 经 `_handleAttitudeWorker` 写入，此处填的 heading 仅供其它消费者使用。
    {
        const int16_t kBad16 = HeartbeatExt::kInvalidInt16;
        const double vx       = (ext.vx != kBad16)       ? ext.vx / 100.0       : 0.0; // cm/s → m/s
        const double vy       = (ext.vy != kBad16)       ? ext.vy / 100.0       : 0.0;
        const double vz       = (ext.vz != kBad16)       ? ext.vz / 100.0       : 0.0;
        const double airspeed = (ext.airspeed != kBad16) ? ext.airspeed / 100.0 : 0.0;
        double hdgDeg = qRadiansToDegrees(static_cast<double>(ext.yaw));
        hdgDeg = std::fmod(hdgDeg, 360.0);
        if (hdgDeg < 0.0) {
            hdgDeg += 360.0;
        }
        mavlink_message_t msg{};
        (void) mavlink_msg_vfr_hud_pack(
            sysid, compid, &msg,
            static_cast<float>(airspeed),                       // airspeed (m/s, TAS)
            static_cast<float>(std::sqrt(vx * vx + vy * vy)),   // groundspeed (m/s)：由 NED 水平分量合成
            static_cast<int16_t>(qRound(hdgDeg)),               // heading (deg)
            0,                                                  // throttle (%)：EXT 无油门量
            ext.hasAltitude() ? static_cast<float>(ext.alt / 1000.0) : 0.0f, // alt (m, MSL)
            static_cast<float>(-vz));                           // climb (m/s)：NED 的 vz 向下为正，取负
        msgs.append(msg);
    }

    // EXTENDED_SYS_STATE：`Vehicle::_handleExtendedSysState` 据此同时驱动
    // `flying`/`landing`（landed_state）与 `vtolInFwdFlight`（vtol_state == MAV_VTOL_STATE_FW）。
    // ‼️ 仅 hasExtendedFields（55B）时打包：37B 兼容帧的 landed/vtolState 是「未提供」的 0，
    //    映射成 IN_AIR 等于对飞行事实撒谎。37B 时**不注入**，QGC 保持上一次已知状态。
    if (ext.hasExtendedFields) {
        mavlink_message_t msg{};
        (void) mavlink_msg_extended_sys_state_pack(
            sysid, compid, &msg,
            ext.vtolState,   // 与 MAV_VTOL_STATE_* 1:1（PX4 VtolVehicleStatus.msg 首行保证）
            (ext.landed & 0x01) ? MAV_LANDED_STATE_ON_GROUND : MAV_LANDED_STATE_IN_AIR);
        msgs.append(msg);
    }

    // ── 60825.0：系统状态段（仅 hasSystemStatus，≥72B）──────────────────
    // ≥72B 是这些字段「已提供」的唯一判据；55B/37B 帧注入 0 会把「未知」变成
    // 「全部传感器故障 / CPU 空转」，比不显示更糟。
    if (ext.hasSystemStatus) {
        // SYS_STATUS：present/enabled 全 1 表示「本端只报健康，不主张启用面」。
        // present 不能置 bit31（MAV_SYS_STATUS_EXTENSION_USED 会要求 extended 三个字段
        // 同步有效），故用 0x7FFFFFFF。
        {
            mavlink_message_t msg{};
            // load 单位 d‰（MAVLink 规范；QGC 当前不消费该字段，仅保证单位正确）。
            // EXT 255 = 未知 → 0。
            const uint16_t load = (ext.loadPct == 255) ? 0 : static_cast<uint16_t>(ext.loadPct * 10);
            (void) mavlink_msg_sys_status_pack(
                sysid, compid, &msg,
                0x7FFFFFFF,          // onboard_control_sensors_present
                0x7FFFFFFF,          // onboard_control_sensors_enabled
                ext.sensorsHealth,   // onboard_control_sensors_health（PX4 已补未映射位为 1）
                load,                // load（d‰）
                UINT16_MAX,          // voltage_battery：QGC 电池只由 BATTERY_STATUS 更新
                -1,                  // current_battery
                -1,                  // battery_remaining
                0, 0, 0, 0, 0, 0,    // drop_rate_comm / errors_comm / errors_count1-4
                0, 0, 0);            // extended present/enabled/health（本端不主张）
            msgs.append(msg);
        }

        // GNSS_INTEGRITY：id 是 GPS 实例号（VehicleGPSFactGroup::_gnssIntegrityId 默认 0），
        // 不是 device_id。四个 quality 与 hfom/vfom 有意填哨兵（EXT 不搬运）。
        {
            mavlink_message_t msg{};
            (void) mavlink_msg_gnss_integrity_pack(
                sysid, compid, &msg,
                0,                    // id：GPS 实例号
                ext.gnssErrors,       // system_errors（bit0-6）
                ext.gnssAuth,         // authentication_state（3 = OK）
                ext.gnssJam,          // jamming_state
                ext.gnssSpoof,        // spoofing_state
                ext.gnssRaim,         // raim_state（PX4 当前恒 0 = UNKNOWN）
                UINT16_MAX,           // raim_hfom → 未知
                UINT16_MAX,           // raim_vfom → 未知
                255,                  // corrections_quality
                255,                  // system_status_summary
                255,                  // gnss_signal_quality
                255);                 // post_processing_quality
            msgs.append(msg);
        }

        // VIBRATION：EXT 只有档位（0–7），按档位中位映射成 QGC 期望的指标量级；
        // clipping 是 EXT 的轴语义布尔，与 VIBRATION 的 Accel1/2/3 无法一一对应，
        // 一律填 0（不伪造计数）。
        // ‼️ 不在 vib_valid==0 时停发：协议要求发送端在无效时把档位写 0，此时消息本身就是
        // 「三轴 0」；停发反而让 QGC 保留上一次的旧值（比显示 0 更糟）。
        {
            static constexpr float kLevelMidpoint[8] = {0.0f, 5.0f, 15.0f, 25.0f, 37.5f, 52.5f, 80.0f, 100.0f};
            const auto midpoint = [](uint8_t level) {
                return kLevelMidpoint[level > 7 ? 7 : level];
            };
            mavlink_message_t msg{};
            (void) mavlink_msg_vibration_pack(
                sysid, compid, &msg,
                ext.hasExtendedFields ? static_cast<uint64_t>(ext.timeBootMs) * 1000ULL : 0ULL,
                midpoint(ext.vibX),
                midpoint(ext.vibY),
                midpoint(ext.vibZ),
                0, 0, 0);
            msgs.append(msg);
        }
    }
    return msgs;
}

} // namespace MAVLinkCrypto
