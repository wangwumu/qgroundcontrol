#include "CryptoLinkLogger.h"

// ============================================================================
// 联调开关：QGC ↔ PX4 报文链路日志。
// 由 CMake option `QGC_CRYPTO_LINK_LOG` 控制（src/MAVLink/Crypto/CMakeLists.txt）：
//   默认 OFF（方法体为空，零开销）；联调构建时配置 -DQGC_CRYPTO_LINK_LOG=ON 启用。
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
        // 打开失败（如 /tmp 不可写）：静默，日志不落盘（联调观察，不阻塞链路）
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
    return true;
#else
    return false;
#endif
}

void CryptoLinkLogger::logOutgoing(uint32_t msgid, uint32_t deviceID, bool encrypted,
                                   const char* bytes, int len, bool parseOk,
                                   const QString& failReason)
{
#ifdef QGC_CRYPTO_LINK_LOG
    const int payloadLen = encrypted ? static_cast<int>(frameLength(
                                           reinterpret_cast<const uint8_t*>(bytes))) :
                                       (len - static_cast<int>(kV2HeaderLen) -
                                        static_cast<int>(kCrcLen));
    _append(true, encrypted, parseOk, msgid, deviceID, _describeMsgid(msgid), payloadLen,
            _parseContent(msgid, encrypted, bytes, len), failReason);
#else
    Q_UNUSED(msgid)
    Q_UNUSED(deviceID)
    Q_UNUSED(encrypted)
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    Q_UNUSED(parseOk)
    Q_UNUSED(failReason)
#endif
}

void CryptoLinkLogger::logIncoming(uint32_t msgid, uint32_t deviceID, bool encrypted,
                                   const char* bytes, int len, bool parseOk,
                                   const QString& failReason)
{
#ifdef QGC_CRYPTO_LINK_LOG
    const int payloadLen = encrypted ? static_cast<int>(frameLength(
                                           reinterpret_cast<const uint8_t*>(bytes))) :
                                       (len - static_cast<int>(kV2HeaderLen) -
                                        static_cast<int>(kCrcLen));
    _append(false, encrypted, parseOk, msgid, deviceID, _describeMsgid(msgid), payloadLen,
            _parseContent(msgid, encrypted, bytes, len), failReason);
#else
    Q_UNUSED(msgid)
    Q_UNUSED(deviceID)
    Q_UNUSED(encrypted)
    Q_UNUSED(bytes)
    Q_UNUSED(len)
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
    line += QTime::currentTime().toString(QStringLiteral("HH:mm:ss")) + QLatin1Char(' ');
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

bool CryptoLinkLogger::isCommandMessage(uint32_t msgid)
{
    return isCommandMsgid(msgid);
}

QString CryptoLinkLogger::parseRegistrationPayload(const char* bytes, int len)
{
#ifdef QGC_CRYPTO_LINK_LOG
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
#else
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    return QString();
#endif
}

uint32_t CryptoLinkLogger::deviceIDFromFrameBytes(const char* bytes, int len)
{
#ifdef QGC_CRYPTO_LINK_LOG
    if (bytes == nullptr || len < 7) {
        return 0;
    }
    return deviceIDFromFrame(reinterpret_cast<const uint8_t*>(bytes));
#else
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    return 0;
#endif
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

QString CryptoLinkLogger::_parseContent(uint32_t msgid, bool encrypted, const char* bytes, int len)
{
#ifdef QGC_CRYPTO_LINK_LOG
    if (encrypted) {
        if (bytes != nullptr && len >= static_cast<int>(kV2HeaderLen) +
                                            static_cast<int>(kCounterSize)) {
            const uint64_t counter = counterFromFrame(
                reinterpret_cast<const uint8_t*>(bytes));
            return QStringLiteral("counter=%1,密文").arg(counter);
        }
        return QStringLiteral("密文");
    }
    if (msgid == MAVLINK_MSG_ID_QGC_REGISTRATION) { // 80005
        return parseRegistrationPayload(bytes, len);
    }
    if (msgid == 0) {
        return QStringLiteral("待命心跳");
    }
    return QStringLiteral("msgid=%1").arg(msgid);
#else
    Q_UNUSED(msgid)
    Q_UNUSED(encrypted)
    Q_UNUSED(bytes)
    Q_UNUSED(len)
    return QString();
#endif
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
