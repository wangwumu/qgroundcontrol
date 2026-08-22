#include "CryptoLinkLogger.h"

// ============================================================================
// 联调开关：QGC ↔ PX4 报文链路日志。
// 由 CMake option `QGC_CRYPTO_LINK_LOG` 控制（src/MAVLink/Crypto/CMakeLists.txt）：
//   默认 OFF——文件写入/格式化方法体为空；纯解析函数仍无条件编译（可测试）。
//   联调构建时配置 -DQGC_CRYPTO_LINK_LOG=ON 启用文件日志。
// ============================================================================

#include <QTime>

#include "CryptoCodec.h"
#include "Extensions/VTOLSafetyMessages.h"

namespace MAVLinkCrypto {

#ifdef QGC_CRYPTO_LINK_LOG
// 日志固定路径（联调观察文件）
static const char* kLogPath = "/tmp/qgc_crypto_link.log";
#endif

// 命令类消息 ID（用户命令触发；其余为 QGC 自动发送）。
// 数字常量对应标准 mavlink 宏名（QGC 经 CPM 拉取的 mavlink 生成头，避免硬依赖）。
static bool isCommandMsgid(uint32_t msgid)
{
    switch (msgid) {
    case 75:  // MAVLINK_MSG_ID_COMMAND_INT
    case 76:  // MAVLINK_MSG_ID_COMMAND_LONG
    case 39:  // MAVLINK_MSG_ID_MISSION_ITEM
    case 73:  // MAVLINK_MSG_ID_MISSION_ITEM_INT
    case 44:  // MAVLINK_MSG_ID_MISSION_COUNT
    case 43:  // MAVLINK_MSG_ID_MISSION_REQUEST_LIST
    case 51:  // MAVLINK_MSG_ID_MISSION_REQUEST_INT
    case 40:  // MAVLINK_MSG_ID_MISSION_REQUEST
    case 47:  // MAVLINK_MSG_ID_MISSION_ACK
    case 176: // MAVLINK_MSG_ID_SET_MODE
    case 23:  // MAVLINK_MSG_ID_PARAM_SET
    case 86:  // MAVLINK_MSG_ID_SET_POSITION_TARGET_GLOBAL_INT
    case 84:  // MAVLINK_MSG_ID_SET_POSITION_TARGET_LOCAL_NED
    case 82:  // MAVLINK_MSG_ID_SET_ATTITUDE_TARGET
    case MAVLINK_MSG_ID_WEATHER_FORECAST:   // 80000
    case MAVLINK_MSG_ID_ALTERNATE_LANDING:  // 80001
    case MAVLINK_MSG_ID_SENSOR_CTRL:        // 80002
    case MAVLINK_MSG_ID_VIDEO_CTRL:         // 80003
        return true;
    default:
        return false;
    }
}

CryptoLinkLogger::CryptoLinkLogger()
{
#ifdef QGC_CRYPTO_LINK_LOG
    _file.setFileName(QLatin1String(kLogPath));
    if (!_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        // 打开失败（如 /tmp 不可写）：只告警一次（enabled() 反映 false，写路径不再触碰关闭的 QFile）。
        // 用 Qt 全局 qWarning（不用 QGC_LOGGING_CATEGORY，保持本调试工具可独立编译/测试）。
        qWarning("CryptoLinkLogger: cannot open log %s: %s", kLogPath, qPrintable(_file.errorString()));
    }
#endif
}

CryptoLinkLogger::~CryptoLinkLogger()
{
#ifdef QGC_CRYPTO_LINK_LOG
    if (_file.isOpen()) {
        _file.close();
    }
#endif
}

CryptoLinkLogger* CryptoLinkLogger::instance()
{
    static CryptoLinkLogger* inst = new CryptoLinkLogger;
    return inst;
}

bool CryptoLinkLogger::enabled()
{
#ifdef QGC_CRYPTO_LINK_LOG
    return instance()->_file.isOpen();
#else
    return false;
#endif
}

void CryptoLinkLogger::logOutgoing(uint32_t msgid, uint32_t deviceID, bool encrypted,
                                   const char* bytes, int len,
                                   const char* plainBytes, int plainLen, bool parseOk,
                                   const QString& failReason)
{
#ifdef QGC_CRYPTO_LINK_LOG
    const int payloadLen = (bytes == nullptr)
                               ? 0 // 加密失败无线上帧（bytes 可传 null）
                               : (encrypted
                                      ? static_cast<int>(frameLength(reinterpret_cast<const uint8_t*>(bytes)))
                                      : (len - static_cast<int>(kV2HeaderLen) - static_cast<int>(kCrcLen)));
    _append(true, encrypted, parseOk, msgid, deviceID, _describeMsgid(msgid), payloadLen,
            _parseContent(msgid, encrypted, bytes, len, plainBytes, plainLen), failReason);
#else
    Q_UNUSED(msgid)
    Q_UNUSED(deviceID)
    Q_UNUSED(encrypted)
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    Q_UNUSED(plainBytes)
    Q_UNUSED(plainLen)
    Q_UNUSED(parseOk)
    Q_UNUSED(failReason)
#endif
}

void CryptoLinkLogger::logIncoming(uint32_t msgid, uint32_t deviceID, bool encrypted,
                                   const char* bytes, int len,
                                   const char* plainBytes, int plainLen, bool parseOk,
                                   const QString& failReason)
{
#ifdef QGC_CRYPTO_LINK_LOG
    const int payloadLen = (bytes == nullptr)
                               ? 0 // 加密失败无线上帧（bytes 可传 null）
                               : (encrypted
                                      ? static_cast<int>(frameLength(reinterpret_cast<const uint8_t*>(bytes)))
                                      : (len - static_cast<int>(kV2HeaderLen) - static_cast<int>(kCrcLen)));
    _append(false, encrypted, parseOk, msgid, deviceID, _describeMsgid(msgid), payloadLen,
            _parseContent(msgid, encrypted, bytes, len, plainBytes, plainLen), failReason);
#else
    Q_UNUSED(msgid)
    Q_UNUSED(deviceID)
    Q_UNUSED(encrypted)
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    Q_UNUSED(plainBytes)
    Q_UNUSED(plainLen)
    Q_UNUSED(parseOk)
    Q_UNUSED(failReason)
#endif
}

void CryptoLinkLogger::_append(bool outgoing, bool encrypted, bool parseOk, uint32_t msgid,
                               uint32_t deviceID, const QString& note, int payloadLen,
                               const QString& content, const QString& failReason)
{
    const QMutexLocker locker(&_mutex);
    ++_seq;

    QString line;
    line += _padLeft(QString::number(_seq), 5) + QLatin1Char(' ');
    line += QTime::currentTime().toString(QStringLiteral("HH:mm:ss.zzz")) + QLatin1Char(' ');
    line += QLatin1String(outgoing ? "QGC" : "PX4") + QLatin1Char(' ');
    line += QLatin1String(isCommandMsgid(msgid) ? "C" : "A") + QLatin1Char(' ');
    line += _padLeft(QString::number(msgid), 8) + QLatin1Char(' ');
    line += _padLeft(QString::number(deviceID), 6) + QLatin1Char(' ');
    line += QLatin1String(encrypted ? "C" : "M") + QLatin1Char(' ');
    line += QLatin1String(parseOk ? "S" : "F") + QLatin1Char(' ');
    line += _padToWidth(note, 40) + QLatin1Char(' ');
    line += _padLeft(QString::number(payloadLen), 3) + QLatin1Char(' ');
    line += content;
    if (!parseOk && !failReason.isEmpty()) {
        line += QStringLiteral("（%1）").arg(failReason);
    }

    _file.write(line.toUtf8());
    _file.write("\n", 1);
    _file.flush();
}

QString CryptoLinkLogger::parseRegistrationPayload(const char* bytes, int len)
{
    if (bytes == nullptr || len < static_cast<int>(kV2HeaderLen) + 1) {
        return QString();
    }
    const uint8_t* p = reinterpret_cast<const uint8_t*>(bytes);
    const int num = p[kV2HeaderLen]; // deviceID_num
    QStringList ids;
    for (int i = 0;
         i < num &&
         static_cast<int>(kV2HeaderLen) + 1 + (i + 1) * 4 <= len;
         i++) {
        const uint32_t did = (uint32_t(p[kV2HeaderLen + 1 + i * 4]) << 24) |
                             (uint32_t(p[kV2HeaderLen + 1 + i * 4 + 1]) << 16) |
                             (uint32_t(p[kV2HeaderLen + 1 + i * 4 + 2]) << 8) |
                             uint32_t(p[kV2HeaderLen + 1 + i * 4 + 3]);
        ids << QStringLiteral("%1").arg(did, 6, 10, QLatin1Char('0'));
    }
    return ids.join(QLatin1String(","));
}

uint32_t CryptoLinkLogger::deviceIDFromFrameBytes(const char* bytes, int len)
{
    if (bytes == nullptr || len < 7) {
        return 0;
    }
    return deviceIDFromFrame(reinterpret_cast<const uint8_t*>(bytes));
}

QString CryptoLinkLogger::_describeMsgid(uint32_t msgid)
{
    switch (msgid) {
    case MAVLINK_MSG_ID_QGC_REGISTRATION: return QStringLiteral("QGC登记心跳");
    case 0:         return QStringLiteral("心跳");
    case 33:                                return QStringLiteral("位置遥测");
    case 24:                                return QStringLiteral("GPS原始数据");
    case 30:                                return QStringLiteral("姿态");
    case 253:                               return QStringLiteral("状态文本");
    case 74:                                return QStringLiteral("空速地速");
    case 76:                                return QStringLiteral("飞行指令");
    case 75:                                return QStringLiteral("飞行指令");
    case MAVLINK_MSG_ID_WEATHER_FORECAST:  return QStringLiteral("天气预报命令");
    case MAVLINK_MSG_ID_ALTERNATE_LANDING: return QStringLiteral("备降点命令");
    case MAVLINK_MSG_ID_SENSOR_CTRL:       return QStringLiteral("传感器控制");
    case MAVLINK_MSG_ID_VIDEO_CTRL:        return QStringLiteral("视频控制");
    default:                                return QStringLiteral("MAVLink报文");
    }
}

QString CryptoLinkLogger::_parseContent(uint32_t msgid, bool encrypted, const char* bytes, int len,
                                        const char* plainBytes, int plainLen)
{
    if (encrypted) {
        QString prefix;
        if (bytes != nullptr && len >= static_cast<int>(kV2HeaderLen) +
                                            static_cast<int>(kCounterSize)) {
            prefix = QStringLiteral("counter=%1").arg(
                counterFromFrame(reinterpret_cast<const uint8_t*>(bytes)));
        }
        // 解密后的明文帧 → 解析可读字段（密文解开成可读内容）
        if (plainBytes != nullptr && plainLen > 0) {
            const QString fields = _parsePlainFields(msgid, plainBytes, plainLen);
            return prefix.isEmpty() ? fields : prefix + QLatin1Char(' ') + fields;
        }
        return prefix.isEmpty() ? QStringLiteral("密文") : prefix + QStringLiteral(" 密文");
    }
    if (msgid == MAVLINK_MSG_ID_QGC_REGISTRATION) { // 80005
        return parseRegistrationPayload(bytes, len);
    }
    // 明文帧：解析可读字段（含 msgid=0 待命心跳的 type/mode）
    return _parsePlainFields(msgid, bytes, len);
}

QString CryptoLinkLogger::_parsePlainFields(uint32_t msgid, const char* plainBytes, int plainLen)
{
    if (plainBytes == nullptr || plainLen <= 0) {
        return QStringLiteral("msgid=%1").arg(msgid);
    }
    mavlink_message_t msg {};
    _frameToMessage(plainBytes, plainLen, msg);
    // 帧无效（非 V2 / 截断）或 msgid 与调用方不一致 → 回退，不显示误导性全零字段
    if (msg.magic != 0xFD || msg.msgid != msgid) {
        return QStringLiteral("msgid=%1").arg(msgid);
    }

    switch (msgid) {
    case 0: { // HEARTBEAT
        const uint8_t type = mavlink_msg_heartbeat_get_type(&msg);
        const uint8_t baseMode = mavlink_msg_heartbeat_get_base_mode(&msg);
        return QStringLiteral("待命心跳 type=%1,mode=0x%2").arg(type).arg(baseMode, 2, 16, QLatin1Char('0'));
    }
    case 33: { // GLOBAL_POSITION_INT
        const int32_t lat = mavlink_msg_global_position_int_get_lat(&msg);
        const int32_t lon = mavlink_msg_global_position_int_get_lon(&msg);
        const int32_t alt = mavlink_msg_global_position_int_get_alt(&msg);
        return QStringLiteral("lat=%1,lon=%2,alt=%3m").arg(lat / 1e7, 0, 'f', 7).arg(lon / 1e7, 0, 'f', 7).arg(alt / 1000.0, 0, 'f', 1);
    }
    case 24: { // GPS_RAW_INT
        const uint8_t fix = mavlink_msg_gps_raw_int_get_fix_type(&msg);
        const uint8_t sat = mavlink_msg_gps_raw_int_get_satellites_visible(&msg);
        return QStringLiteral("fix=%1,sat=%2").arg(fix).arg(sat);
    }
    case 30: { // ATTITUDE
        const float roll = mavlink_msg_attitude_get_roll(&msg);
        const float pitch = mavlink_msg_attitude_get_pitch(&msg);
        const float yaw = mavlink_msg_attitude_get_yaw(&msg);
        return QStringLiteral("roll=%1,pitch=%2,yaw=%3").arg(roll, 0, 'f', 2).arg(pitch, 0, 'f', 2).arg(yaw, 0, 'f', 2);
    }
    case 74: { // VFR_HUD
        const float air = mavlink_msg_vfr_hud_get_airspeed(&msg);
        const float gnd = mavlink_msg_vfr_hud_get_groundspeed(&msg);
        const float alt = mavlink_msg_vfr_hud_get_alt(&msg);
        return QStringLiteral("airspeed=%1,gnd=%2,alt=%3m").arg(air, 0, 'f', 1).arg(gnd, 0, 'f', 1).arg(alt, 0, 'f', 1);
    }
    case 147: { // BATTERY_STATUS
        const int32_t remaining = mavlink_msg_battery_status_get_battery_remaining(&msg);
        return QStringLiteral("battery=%1%%").arg(remaining);
    }
    case 253: { // STATUSTEXT
        char text[51] = {};
        mavlink_msg_statustext_get_text(&msg, text);
        return QStringLiteral("text=%1").arg(QString::fromLatin1(text));
    }
    case 76: { // COMMAND_LONG
        const uint16_t cmd = mavlink_msg_command_long_get_command(&msg);
        const float p1 = mavlink_msg_command_long_get_param1(&msg);
        return QStringLiteral("cmd=%1,p1=%2").arg(cmd).arg(p1, 0, 'f', 1);
    }
    default:
        return QStringLiteral("msgid=%1").arg(msgid);
    }
}

void CryptoLinkLogger::_frameToMessage(const char* bytes, int len, mavlink_message_t& msg)
{
    memset(&msg, 0, sizeof(msg));
    if (bytes == nullptr || len < static_cast<int>(kV2HeaderLen)) {
        return;
    }
    const uint8_t* const p = reinterpret_cast<const uint8_t*>(bytes);
    if (p[0] != 0xFD) {
        return; // 仅支持 MAVLink V2
    }
    msg.magic = p[0];
    msg.len = p[1];
    msg.incompat_flags = p[2];
    msg.compat_flags = p[3];
    msg.seq = p[4];
    msg.sysid = p[5];
    msg.compid = p[6];
    msg.msgid = p[7] | (uint32_t(p[8]) << 8) | (uint32_t(p[9]) << 16);
    const int payloadLen = qMin<int>(msg.len, len - static_cast<int>(kV2HeaderLen));
    if (payloadLen > 0) {
        memcpy(msg.payload64, p + kV2HeaderLen, static_cast<size_t>(payloadLen));
    }
}

QString CryptoLinkLogger::_padToWidth(const QString& s, int width)
{
    int w = 0;
    for (const QChar& c : s) {
        w += (c.unicode() < 0x80) ? 1 : 2;
    }
    if (w >= width) {
        return s;
    }
    return s + QString(width - w, QLatin1Char(' '));
}

QString CryptoLinkLogger::_padLeft(const QString& s, int width)
{
    if (s.size() >= width) {
        return s;
    }
    return QString(width - s.size(), QLatin1Char(' ')) + s;
}

} // namespace MAVLinkCrypto
