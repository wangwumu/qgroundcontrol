#include "FlightEventLogger.h"

#include "Extensions/VTOLSafetyMessages.h"
#include "MAVLinkLib.h"

#include <QtCore/QDir>
#include <QtCore/QMutexLocker>
#include <QtCore/QStandardPaths>

// ============================================================================
// 枚举 → 中文
//
// 日志里不出现裸枚举：既便于人读，也避免被浏览器/编辑器的自动翻译曲解。
// 一律保留数字后缀（如「拒绝(2)」），以便与 MAVLink 协议文档逐条对照。
// ============================================================================

/// MAV_RESULT → 中文。
static QString _resultLabel(uint8_t result)
{
    switch (result) {
    case MAV_RESULT_ACCEPTED:             return QStringLiteral("已接受");
    case MAV_RESULT_TEMPORARILY_REJECTED: return QStringLiteral("暂时拒绝");
    case MAV_RESULT_DENIED:               return QStringLiteral("拒绝");
    case MAV_RESULT_UNSUPPORTED:          return QStringLiteral("不支持");
    case MAV_RESULT_FAILED:               return QStringLiteral("失败");
    case MAV_RESULT_IN_PROGRESS:          return QStringLiteral("进行中");
    case MAV_RESULT_CANCELLED:            return QStringLiteral("已取消");
    default:                              return QStringLiteral("未知");
    }
}

/// MAV_SEVERITY → 中文。
static QString _severityLabel(uint8_t severity)
{
    switch (severity) {
    case MAV_SEVERITY_EMERGENCY: return QStringLiteral("紧急");
    case MAV_SEVERITY_ALERT:     return QStringLiteral("告警");
    case MAV_SEVERITY_CRITICAL:  return QStringLiteral("严重");
    case MAV_SEVERITY_ERROR:     return QStringLiteral("错误");
    case MAV_SEVERITY_WARNING:   return QStringLiteral("警告");
    case MAV_SEVERITY_NOTICE:    return QStringLiteral("注意");
    case MAV_SEVERITY_INFO:      return QStringLiteral("信息");
    case MAV_SEVERITY_DEBUG:     return QStringLiteral("调试");
    default:                     return QStringLiteral("未知");
    }
}

/// MAV_STATE → 中文。
static QString _mavStateLabel(uint8_t state)
{
    switch (state) {
    case MAV_STATE_UNINIT:               return QStringLiteral("未初始化");
    case MAV_STATE_BOOT:                 return QStringLiteral("启动中");
    case MAV_STATE_CALIBRATING:          return QStringLiteral("校准中");
    case MAV_STATE_STANDBY:              return QStringLiteral("待命");
    case MAV_STATE_ACTIVE:               return QStringLiteral("运行中");
    case MAV_STATE_CRITICAL:             return QStringLiteral("严重");
    case MAV_STATE_EMERGENCY:            return QStringLiteral("紧急");
    case MAV_STATE_POWEROFF:             return QStringLiteral("关机");
    case MAV_STATE_FLIGHT_TERMINATION:   return QStringLiteral("终止飞行");
    default:                             return QStringLiteral("未知");
    }
}

/// MAV_CMD → 协议名。未收录的返回空串（由调用方渲染成「未知命令(编号)」）。
/// 只收录 QGC 实际会发出、以及排障时最常需要认出的那些；宁缺毋滥，
/// 编错的命令名比「未知命令」更难发现。
static QString _commandName(uint16_t command)
{
    switch (command) {
    case MAV_CMD_NAV_WAYPOINT:                   return QStringLiteral("NAV_WAYPOINT");
    case MAV_CMD_NAV_LOITER_UNLIM:               return QStringLiteral("NAV_LOITER_UNLIM");
    case MAV_CMD_NAV_LOITER_TIME:                return QStringLiteral("NAV_LOITER_TIME");
    case MAV_CMD_NAV_RETURN_TO_LAUNCH:           return QStringLiteral("NAV_RETURN_TO_LAUNCH");
    case MAV_CMD_NAV_LAND:                       return QStringLiteral("NAV_LAND");
    case MAV_CMD_NAV_TAKEOFF:                    return QStringLiteral("NAV_TAKEOFF");
    case MAV_CMD_NAV_VTOL_TAKEOFF:               return QStringLiteral("NAV_VTOL_TAKEOFF");
    case MAV_CMD_NAV_VTOL_LAND:                  return QStringLiteral("NAV_VTOL_LAND");
    case MAV_CMD_DO_SET_MODE:                    return QStringLiteral("DO_SET_MODE");
    case MAV_CMD_DO_CHANGE_SPEED:                return QStringLiteral("DO_CHANGE_SPEED");
    case MAV_CMD_DO_SET_HOME:                    return QStringLiteral("DO_SET_HOME");
    case MAV_CMD_DO_FLIGHTTERMINATION:           return QStringLiteral("DO_FLIGHTTERMINATION");
    case MAV_CMD_DO_LAND_START:                  return QStringLiteral("DO_LAND_START");
    case MAV_CMD_DO_REPOSITION:                  return QStringLiteral("DO_REPOSITION");
    case MAV_CMD_DO_PAUSE_CONTINUE:              return QStringLiteral("DO_PAUSE_CONTINUE");
    case MAV_CMD_PREFLIGHT_CALIBRATION:          return QStringLiteral("PREFLIGHT_CALIBRATION");
    case MAV_CMD_MISSION_START:                  return QStringLiteral("MISSION_START");
    case MAV_CMD_COMPONENT_ARM_DISARM:           return QStringLiteral("COMPONENT_ARM_DISARM");
    case MAV_CMD_GET_HOME_POSITION:              return QStringLiteral("GET_HOME_POSITION");
    case MAV_CMD_SET_MESSAGE_INTERVAL:           return QStringLiteral("SET_MESSAGE_INTERVAL");
    case MAV_CMD_REQUEST_MESSAGE:                return QStringLiteral("REQUEST_MESSAGE");
    case MAV_CMD_REQUEST_AUTOPILOT_CAPABILITIES: return QStringLiteral("REQUEST_AUTOPILOT_CAPABILITIES");
    case MAV_CMD_DO_VTOL_TRANSITION:             return QStringLiteral("DO_VTOL_TRANSITION");
    default:                                     return QString();
    }
}

/// 「名称(编号)」；未收录的命令退化成「未知命令(编号)」。
static QString _commandWithNumber(uint16_t command)
{
    const QString name = _commandName(command);
    return name.isEmpty() ? QStringLiteral("未知命令(%1)").arg(command)
                          : QStringLiteral("%1(%2)").arg(name).arg(command);
}

/// 扩展消息（80000-80005）→ 中文名。未收录的返回空串。
static QString _extensionName(uint32_t msgid)
{
    switch (msgid) {
    case MAVLINK_MSG_ID_WEATHER_FORECAST:  return QStringLiteral("天气预报");
    case MAVLINK_MSG_ID_ALTERNATE_LANDING: return QStringLiteral("备降点");
    case MAVLINK_MSG_ID_SENSOR_CTRL:       return QStringLiteral("传感器控制");
    case MAVLINK_MSG_ID_VIDEO_CTRL:        return QStringLiteral("视频控制");
    case MAVLINK_MSG_ID_QGC_REGISTRATION:  return QStringLiteral("QGC登记心跳");
    default:                               return QString();
    }
}

// ============================================================================
// 内部工具
// ============================================================================

/// ISO 8601 带毫秒与显式偏移。手写而不用 Qt::ISODate：
/// ISODate 对 UTC 的表示随 Qt 版本变过（'Z' / 空 / '+00:00'），
/// 而本日志要求格式恒定、且能与 /tmp/FlightData*.mavlink 里的 epoch 微秒对齐换算。
static QString _isoWithOffset(const QDateTime& when)
{
    const int offsetSec = when.offsetFromUtc();
    const int absSec = qAbs(offsetSec);
    return when.toString(QStringLiteral("yyyy-MM-dd'T'HH:mm:ss.zzz"))
         + QStringLiteral("%1%2:%3")
               .arg(offsetSec < 0 ? QLatin1Char('-') : QLatin1Char('+'))
               .arg(absSec / 3600, 2, 10, QLatin1Char('0'))
               .arg((absSec % 3600) / 60, 2, 10, QLatin1Char('0'));
}

// ============================================================================
// FlightEventLogger
// ============================================================================

FlightEventLogger* FlightEventLogger::instance()
{
    static FlightEventLogger s_instance;
    return &s_instance;
}

FlightEventLogger::Category FlightEventLogger::classify(const mavlink_message_t& message)
{
    switch (message.msgid) {
    case MAVLINK_MSG_ID_COMMAND_LONG:
    case MAVLINK_MSG_ID_COMMAND_INT:
    case MAVLINK_MSG_ID_WEATHER_FORECAST:
    case MAVLINK_MSG_ID_ALTERNATE_LANDING:
    case MAVLINK_MSG_ID_SENSOR_CTRL:
    case MAVLINK_MSG_ID_VIDEO_CTRL:
        return Category::Command;
    case MAVLINK_MSG_ID_COMMAND_ACK:
        return Category::Ack;
    case MAVLINK_MSG_ID_STATUSTEXT:
        return Category::Alert;
    case MAVLINK_MSG_ID_HEARTBEAT:
    case MAVLINK_MSG_ID_SYS_STATUS:
        return Category::Status;
    case MAVLINK_MSG_ID_POSITION_TARGET_GLOBAL_INT:
        // 目标点变化是「动作」，不是「状态」：它记的是「改去哪儿」，不是「现在如何」。
        return Category::Action;
    case MAVLINK_MSG_ID_QGC_REGISTRATION:
        // 登记/保活心跳是链路层自动行为，不是操作员命令。
        return Category::Link;
    default:
        return Category::None;
    }
}

QString FlightEventLogger::renderFrame(const mavlink_message_t& message)
{
    switch (message.msgid) {
    case MAVLINK_MSG_ID_COMMAND_LONG:
        return QStringLiteral("%1 目标 %2:%3")
            .arg(_commandWithNumber(mavlink_msg_command_long_get_command(&message)))
            .arg(mavlink_msg_command_long_get_target_system(&message))
            .arg(mavlink_msg_command_long_get_target_component(&message));

    case MAVLINK_MSG_ID_COMMAND_INT:
        return QStringLiteral("%1 目标 %2:%3 坐标系 %4")
            .arg(_commandWithNumber(mavlink_msg_command_int_get_command(&message)))
            .arg(mavlink_msg_command_int_get_target_system(&message))
            .arg(mavlink_msg_command_int_get_target_component(&message))
            .arg(mavlink_msg_command_int_get_frame(&message));

    case MAVLINK_MSG_ID_COMMAND_ACK: {
        const uint8_t result = mavlink_msg_command_ack_get_result(&message);
        return QStringLiteral("%1 结果=%2(%3)")
            .arg(_commandWithNumber(mavlink_msg_command_ack_get_command(&message)))
            .arg(_resultLabel(result))
            .arg(result);
    }

    case MAVLINK_MSG_ID_STATUSTEXT: {
        // +1 且零初始化：MAVLink 的 char 数组字段不保证带结尾 NUL。
        char text[MAVLINK_MSG_STATUSTEXT_FIELD_TEXT_LEN + 1] = {};
        mavlink_msg_statustext_get_text(&message, text);
        const uint8_t severity = mavlink_msg_statustext_get_severity(&message);
        const uint16_t id = mavlink_msg_statustext_get_id(&message);
        const uint8_t chunkSeq = mavlink_msg_statustext_get_chunk_seq(&message);

        QString body = QStringLiteral("%1(%2) %3")
                           .arg(_severityLabel(severity))
                           .arg(severity)
                           .arg(QString::fromLatin1(text));
        // 分片字段只在真分片时报（id≠0 或 chunk_seq≠0），否则每行都拖一串零。
        if (id != 0 || chunkSeq != 0) {
            body += QStringLiteral(" [分片 id=%1 seq=%2]").arg(id).arg(chunkSeq);
        }
        return body;
    }

    case MAVLINK_MSG_ID_HEARTBEAT: {
        const uint8_t baseMode = mavlink_msg_heartbeat_get_base_mode(&message);
        const uint8_t systemStatus = mavlink_msg_heartbeat_get_system_status(&message);
        return QStringLiteral("解锁=%1 自定义模式=%2 系统状态=%3(%4)")
            .arg((baseMode & MAV_MODE_FLAG_SAFETY_ARMED) ? QStringLiteral("是") : QStringLiteral("否"))
            .arg(mavlink_msg_heartbeat_get_custom_mode(&message))
            .arg(_mavStateLabel(systemStatus))
            .arg(systemStatus);
    }

    case MAVLINK_MSG_ID_SYS_STATUS: {
        const int8_t remaining = mavlink_msg_sys_status_get_battery_remaining(&message);
        return QStringLiteral("传感器健康=0x%1 电池电压=%2mV 电池剩余=%3")
            .arg(mavlink_msg_sys_status_get_onboard_control_sensors_health(&message),
                 8, 16, QLatin1Char('0'))
            .arg(mavlink_msg_sys_status_get_voltage_battery(&message))
            .arg(remaining < 0 ? QStringLiteral("未知")
                               : QString::number(remaining) + QStringLiteral("%"));
    }

    case MAVLINK_MSG_ID_POSITION_TARGET_GLOBAL_INT: {
        // degE7 → 度。QString::number 走 C 域，不受运行环境 locale 影响
        // （QString::arg 的 %Ln 才走本地域，那会让日志里出现逗号小数点）。
        return QStringLiteral("目标点 纬度=%1 经度=%2 高度=%3m")
            .arg(QString::number(mavlink_msg_position_target_global_int_get_lat_int(&message) / 10000000.0,
                                 'f', 7))
            .arg(QString::number(mavlink_msg_position_target_global_int_get_lon_int(&message) / 10000000.0,
                                 'f', 7))
            .arg(QString::number(
                static_cast<double>(mavlink_msg_position_target_global_int_get_alt(&message)), 'f', 1));
    }

    case MAVLINK_MSG_ID_WEATHER_FORECAST:
    case MAVLINK_MSG_ID_ALTERNATE_LANDING:
    case MAVLINK_MSG_ID_SENSOR_CTRL:
    case MAVLINK_MSG_ID_VIDEO_CTRL:
    case MAVLINK_MSG_ID_QGC_REGISTRATION:
        return QStringLiteral("%1(扩展 %2)").arg(_extensionName(message.msgid)).arg(message.msgid);

    default:
        return QString();
    }
}

QString FlightEventLogger::categoryLabel(Category category)
{
    switch (category) {
    case Category::Command: return QStringLiteral("命令");
    case Category::Ack:     return QStringLiteral("应答");
    case Category::Action:  return QStringLiteral("动作");
    case Category::Status:  return QStringLiteral("状态");
    case Category::Alert:   return QStringLiteral("异常");
    case Category::Link:    return QStringLiteral("链路");
    case Category::Ui:      return QStringLiteral("界面");
    case Category::None:    break;
    }
    return QStringLiteral("无关");
}

QString FlightEventLogger::directionLabel(Direction direction)
{
    switch (direction) {
    case Direction::ToVehicle:   return QStringLiteral("QGC→飞控");
    case Direction::FromVehicle: return QStringLiteral("飞控→QGC");
    case Direction::Local:       return QStringLiteral("QGC内部");
    }
    return QString();
}

QString FlightEventLogger::formatLine(const QDateTime& when, Direction direction, Category category,
                                      const QString& body, const QString& note)
{
    QString line = QStringLiteral("%1 | %2 | %3 | %4")
                       .arg(_isoWithOffset(when), directionLabel(direction),
                            categoryLabel(category), body);
    if (!note.isEmpty()) {
        line += QStringLiteral(" | ") + note;
    }
    return line;
}

QString FlightEventLogger::fileNameFor(const QDateTime& when)
{
    return QStringLiteral("qgc_flight_%1.log").arg(when.toString(QStringLiteral("yyyyMMdd_HHmmss")));
}

FlightEventLogger::Stream FlightEventLogger::streamOf(const mavlink_message_t& message)
{
    switch (message.msgid) {
    case MAVLINK_MSG_ID_HEARTBEAT:                  return Stream::HeartbeatState;
    case MAVLINK_MSG_ID_SYS_STATUS:                 return Stream::SysStatusHealth;
    case MAVLINK_MSG_ID_POSITION_TARGET_GLOBAL_INT: return Stream::TargetPoint;
    default:                                        return Stream::None;
    }
}

FlightEventLogger::StreamDecision FlightEventLogger::decideStreamWrite(StreamState& state,
                                                                       const QByteArray& value,
                                                                       const QDateTime& now)
{
    StreamDecision decision;

    if (state.hasValue && state.value == value) {
        decision.write = false;
        decision.secondsSinceLastWrite = state.lastWrittenAt.msecsTo(now) / 1000.0;
        return decision;
    }

    decision.write = true;
    // 首次写入没有「上次」：给 -1 而不是 0 —— 0 会被下游读成「刚刚变过」。
    decision.secondsSinceLastWrite = state.hasValue ? state.lastWrittenAt.msecsTo(now) / 1000.0 : -1.0;

    state.hasValue = true;
    state.value = value;
    state.lastWrittenAt = now;
    return decision;
}

FlightEventLogger::HeartbeatGap FlightEventLogger::observeHeartbeat(QDateTime& lastHeartbeatAt,
                                                                    const QDateTime& now,
                                                                    double thresholdSeconds)
{
    HeartbeatGap gap;
    // 首次心跳没有「上次」可言，不报中断 —— 否则每次启动都会凭空多一条。
    if (lastHeartbeatAt.isValid()) {
        gap.silentSeconds = lastHeartbeatAt.msecsTo(now) / 1000.0;
        gap.resumed = gap.silentSeconds > thresholdSeconds;
    }
    lastHeartbeatAt = now;
    return gap;
}

QString FlightEventLogger::uniqueFileNameIn(const QString& dir, const QDateTime& when)
{
    const QString base = fileNameFor(when);
    const QDir directory(dir);
    if (!directory.exists(base)) {
        return base;
    }

    // 同一秒内第二次启动（用户会同时开两台 QGC 联调）不得覆盖第一份日志。
    const QString stem = base.left(base.size() - QStringLiteral(".log").size());
    for (int n = 2; n < 10000; ++n) {
        const QString candidate = QStringLiteral("%1-%2.log").arg(stem).arg(n);
        if (!directory.exists(candidate)) {
            return candidate;
        }
    }

    // 取不到不重名的名字就返回空串，由 start() 判失败 —— 绝不静默覆盖既有日志。
    return QString();
}

bool FlightEventLogger::start(const QString& directory)
{
    QMutexLocker locker(&_mutex);

    if (_file.isOpen()) {
        _file.close();
    }

    const QString dir = directory.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/FlightLogs")
        : directory;
    if (dir.isEmpty() || !QDir().mkpath(dir)) {
        return false;
    }

    const QDateTime openedAt = QDateTime::currentDateTime();
    const QString name = uniqueFileNameIn(dir, openedAt);
    if (name.isEmpty()) {
        return false;
    }

    _file.setFileName(QDir(dir).filePath(name));
    if (!_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        return false;
    }

    _streams.clear();
    _lastHeartbeatAt = QDateTime();

    _file.write("# QGC 飞行事件日志\n");
    _file.write("# 每行: <时间 ISO 含毫秒与时区> | <方向> | <类别> | <正文> | <备注>\n");
    _file.write("# 方向: QGC→飞控 / 飞控→QGC / QGC内部\n");
    _file.write("# 与 /tmp/FlightData*.mavlink 分工: 那个是全量原始帧, 且发送方向写的是加密后的字节;\n");
    _file.write("#   本文件只记关键事件, 发送方向取自加密之前的明文。\n");
    _file.write(QStringLiteral("# 启动时刻: %1\n").arg(_isoWithOffset(openedAt)).toUtf8());
    _file.flush();
    return true;
}

void FlightEventLogger::stop()
{
    QMutexLocker locker(&_mutex);
    if (_file.isOpen()) {
        _file.flush();
        _file.close();
    }
}

bool FlightEventLogger::isOpen() const
{
    QMutexLocker locker(&_mutex);
    return _file.isOpen();
}

QString FlightEventLogger::filePath() const
{
    QMutexLocker locker(&_mutex);
    return _file.fileName();
}

bool FlightEventLogger::logFrame(Direction direction, const mavlink_message_t& message,
                                 const QDateTime& now)
{
    const bool isHeartbeat = (direction == Direction::FromVehicle) &&
                             (message.msgid == MAVLINK_MSG_ID_HEARTBEAT);
    const Category category = classify(message);
    const QString body = (category == Category::None) ? QString() : renderFrame(message);
    const Stream stream = (category == Category::None) ? Stream::None : streamOf(message);

    QMutexLocker locker(&_mutex);
    bool wrote = false;

    // 心跳间隔先判，且与是否写盘无关：取值未变的心跳同样证明链路是通的，
    // 若把它并进去重里一起跳过，「心跳中断」将永远不会被观测到。
    if (isHeartbeat) {
        const HeartbeatGap gap =
            observeHeartbeat(_lastHeartbeatAt, now, kHeartbeatGapThresholdSeconds);
        if (gap.resumed) {
            wrote = _writeLineLocked(formatLine(now, Direction::Local, Category::Link,
                                                QStringLiteral("心跳中断 %1 秒后恢复")
                                                    .arg(QString::number(gap.silentSeconds, 'f', 1))));
        }
    }

    if (body.isEmpty()) {
        return wrote;
    }

    QString note;
    if (stream != Stream::None) {
        const StreamDecision decision =
            decideStreamWrite(_streams[static_cast<uint32_t>(message.msgid)], body.toUtf8(), now);
        if (!decision.write) {
            return wrote;
        }
        if (decision.secondsSinceLastWrite >= 0.0) {
            note = QStringLiteral("距上次变化 %1 秒")
                       .arg(QString::number(decision.secondsSinceLastWrite, 'f', 1));
        }
    }

    return _writeLineLocked(formatLine(now, direction, category, body, note));
}

void FlightEventLogger::logLocalEvent(const QString& text, const QDateTime& now)
{
    QMutexLocker locker(&_mutex);
    _writeLineLocked(formatLine(now, Direction::Local, Category::Ui, text));
}

void FlightEventLogger::logLinkEvent(const QString& text, const QDateTime& now)
{
    QMutexLocker locker(&_mutex);
    _writeLineLocked(formatLine(now, Direction::Local, Category::Link, text));
}

bool FlightEventLogger::_writeLineLocked(const QString& line)
{
    if (!_file.isOpen()) {
        // 未 start() 时丢弃：钩子可能先于 start 接线。此处不缓冲 —— 缓冲会让
        // 「日志里没有」既可能是没发生、也可能是没落盘，把排障判据搅浑。
        return false;
    }

    _file.write(line.toUtf8());
    _file.write("\n", 1);
    // 逐行落盘：本日志的用途正是「进程出事后回看」，攒在缓冲区里等于没写。
    _file.flush();
    return true;
}
