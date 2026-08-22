#include "CryptoHeartbeatExt.h"

#include "CryptoCodec.h"
#include "MAVLinkLib.h"

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
    if (extBytes == nullptr || out == nullptr || extLen < HeartbeatExt::kExtSize) {
        return false;
    }
    HeartbeatExt e;
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
            0,                                        // time_boot_ms
            ext.lat, ext.lon,                         // degE7
            ext.alt,                                  // alt(mm)，MSL
            0,                                        // relative_alt(mm)：EXT 仅 MSL，无相对高度
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

    // BATTERY_STATUS：有电池数据才打包；voltage==0（未知）→ UINT16_MAX（BatteryFactGroup 求和得 NaN）。
    if (ext.hasBattery()) {
        mavlink_battery_status_t batt{};
        batt.id = 0;                                 // 默认电池槽位（BatteryFactGroup id 匹配）
        batt.voltages[0] = (ext.voltage == 0) ? UINT16_MAX : ext.voltage; // 总电压填 cell0
        for (int i = 1; i < 10; i++) {
            batt.voltages[i] = UINT16_MAX;           // 未知 cell
        }
        batt.current_battery = -1;                   // 无电流测量
        batt.current_consumed = -1;
        batt.energy_consumed = -1;
        batt.battery_remaining = ext.remaining;      // -1 → percentRemaining NaN（无电池估算）
        batt.temperature = INT16_MAX;                // 未知温度
        batt.time_remaining = 0;
        mavlink_message_t msg{};
        (void) mavlink_msg_battery_status_encode(sysid, compid, &msg, &batt);
        msgs.append(msg);
    }
    return msgs;
}

} // namespace MAVLinkCrypto
