#include "FlightEventLoggerTest.h"

#include "FlightEventLogger.h"
#include "MAVLinkLib.h"

#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QStringList>
#include <QtCore/QTemporaryDir>
#include <QtCore/QTimeZone>

#include <cstring>

using Direction = FlightEventLogger::Direction;
using Category  = FlightEventLogger::Category;
using Stream    = FlightEventLogger::Stream;

// ---------------------------------------------------------------------------
// 分类
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_classifyCommandLong_test()
{
    mavlink_message_t msg{};
    (void) mavlink_msg_command_long_pack(255, 190, &msg, 1, 1, MAV_CMD_NAV_LAND, 0,
                                         0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f);

    QVERIFY(FlightEventLogger::classify(msg) == Category::Command);
}

void FlightEventLoggerTest::_classifyCommandAck_test()
{
    mavlink_message_t msg{};
    (void) mavlink_msg_command_ack_pack(1, 1, &msg, MAV_CMD_NAV_LAND, MAV_RESULT_ACCEPTED,
                                        0, 0, 255, 190);

    QVERIFY(FlightEventLogger::classify(msg) == Category::Ack);
}

void FlightEventLoggerTest::_classifyStatusText_test()
{
    char text[MAVLINK_MSG_STATUSTEXT_FIELD_TEXT_LEN] = {};
    (void) std::strncpy(text, "Preflight Fail: system power unavailable", sizeof(text) - 1);

    mavlink_message_t msg{};
    (void) mavlink_msg_statustext_pack(1, 1, &msg, MAV_SEVERITY_CRITICAL, text, 0, 0);

    QVERIFY(FlightEventLogger::classify(msg) == Category::Alert);
}

void FlightEventLoggerTest::_classifyUnrelatedFrameIsNone_test()
{
    // PING（msgid 4）不属本日志关注范围：它既不是命令/应答，也不携带状态或报警。
    mavlink_message_t msg{};
    (void) mavlink_msg_ping_pack(1, 1, &msg, 0, 0, 0, 0);

    QVERIFY(FlightEventLogger::classify(msg) == Category::None);
    QVERIFY(FlightEventLogger::renderFrame(msg).isEmpty());

    // 阳性对照：本用例断言的是「无」——没有这一格，一个恒返回 None 的空实现照样通过。
    mavlink_message_t known{};
    (void) mavlink_msg_command_long_pack(255, 190, &known, 1, 1, MAV_CMD_NAV_LAND, 0,
                                         0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f);
    QVERIFY(FlightEventLogger::classify(known) != Category::None);
    QVERIFY(!FlightEventLogger::renderFrame(known).isEmpty());
}

// ---------------------------------------------------------------------------
// 渲染：命令 / 应答
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_commandLongRendersCommandName_test()
{
    mavlink_message_t msg{};
    (void) mavlink_msg_command_long_pack(255, 190, &msg, 1, 1, MAV_CMD_NAV_LAND, 0,
                                         0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f);

    const QString rendered = FlightEventLogger::renderFrame(msg);

    QVERIFY2(rendered.contains(QStringLiteral("NAV_LAND(21)")), qPrintable(rendered));
    QVERIFY2(rendered.contains(QStringLiteral("目标 1:1")), qPrintable(rendered));
}

void FlightEventLoggerTest::_commandAckRendersResultInChinese_test()
{
    mavlink_message_t msg{};
    (void) mavlink_msg_command_ack_pack(1, 1, &msg, MAV_CMD_NAV_LAND, MAV_RESULT_ACCEPTED,
                                        0, 0, 255, 190);

    const QString rendered = FlightEventLogger::renderFrame(msg);

    QVERIFY2(rendered.contains(QStringLiteral("NAV_LAND(21)")), qPrintable(rendered));
    QVERIFY2(rendered.contains(QStringLiteral("已接受(0)")), qPrintable(rendered));
}

void FlightEventLoggerTest::_commandAckDeniedIsNotSilent_test()
{
    // 被拒绝的应答必须与「已接受」在文本上可区分 —— 否则事后排查看不出命令没生效。
    mavlink_message_t msg{};
    (void) mavlink_msg_command_ack_pack(1, 1, &msg, MAV_CMD_DO_REPOSITION, MAV_RESULT_DENIED,
                                        0, 0, 255, 190);

    const QString rendered = FlightEventLogger::renderFrame(msg);

    QVERIFY2(rendered.contains(QStringLiteral("拒绝(2)")), qPrintable(rendered));
    QVERIFY2(!rendered.contains(QStringLiteral("已接受")), qPrintable(rendered));
}

// ---------------------------------------------------------------------------
// 渲染：报警
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_statusTextRendersSeverityInChinese_test()
{
    char text[MAVLINK_MSG_STATUSTEXT_FIELD_TEXT_LEN] = {};
    (void) std::strncpy(text, "Preflight Fail: system power unavailable", sizeof(text) - 1);

    mavlink_message_t msg{};
    (void) mavlink_msg_statustext_pack(1, 1, &msg, MAV_SEVERITY_CRITICAL, text, 0, 0);

    const QString rendered = FlightEventLogger::renderFrame(msg);

    QVERIFY2(rendered.contains(QStringLiteral("严重(2)")), qPrintable(rendered));
    QVERIFY2(rendered.contains(QStringLiteral("Preflight Fail: system power unavailable")),
             qPrintable(rendered));
}

void FlightEventLoggerTest::_statusTextKeepsRawTabAndText_test()
{
    // PX4 的日志器通告以制表符结尾（[logger] ./log/2026-09-29/02_36_20.ulg<TAB>）。
    // 尾部制表符与文本必须逐字节保真：它是分片边界的线索，不能被 trim 掉。
    const QByteArray raw = QByteArrayLiteral("[logger] ./log/2026-09-29/02_36_20.ulg\t");
    char text[MAVLINK_MSG_STATUSTEXT_FIELD_TEXT_LEN] = {};
    (void) std::memcpy(text, raw.constData(), static_cast<size_t>(raw.size()));

    mavlink_message_t msg{};
    (void) mavlink_msg_statustext_pack(1, 1, &msg, MAV_SEVERITY_INFO, text, 0, 0);

    const QString rendered = FlightEventLogger::renderFrame(msg);

    QVERIFY2(rendered.contains(QString::fromLatin1(raw)), qPrintable(rendered));
}

// ---------------------------------------------------------------------------
// 行格式与文件名
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_formatLineCarriesTimestampDirectionAndCategory_test()
{
    const QDateTime when(QDate(2026, 9, 29), QTime(10, 43, 21, 312), QTimeZone::UTC);

    const QString line = FlightEventLogger::formatLine(when, Direction::ToVehicle, Category::Command,
                                                       QStringLiteral("NAV_LAND(21)"));

    QVERIFY2(line.startsWith(QStringLiteral("2026-09-29T10:43:21.312+00:00")), qPrintable(line));
    QVERIFY2(line.contains(FlightEventLogger::directionLabel(Direction::ToVehicle)), qPrintable(line));
    QVERIFY2(line.contains(QStringLiteral("命令")), qPrintable(line));
    QVERIFY2(line.contains(QStringLiteral("NAV_LAND(21)")), qPrintable(line));

    // 方向必须可区分：只断言「含有飞控」的话，两个方向都能通过，等于没测。
    QVERIFY(FlightEventLogger::directionLabel(Direction::ToVehicle)
            != FlightEventLogger::directionLabel(Direction::FromVehicle));

    const QString incoming = FlightEventLogger::formatLine(when, Direction::FromVehicle, Category::Ack,
                                                           QStringLiteral("NAV_LAND(21)"));
    QVERIFY2(!incoming.contains(FlightEventLogger::directionLabel(Direction::ToVehicle)),
             qPrintable(incoming));
}

void FlightEventLoggerTest::_fileNameIsTimestamped_test()
{
    const QDateTime when(QDate(2026, 9, 29), QTime(10, 43, 21), QTimeZone::UTC);

    QCOMPARE(FlightEventLogger::fileNameFor(when), QStringLiteral("qgc_flight_20260929_104321.log"));
}

// ---------------------------------------------------------------------------
// 高频状态流：分类与去重
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_streamOfHighFrequencyMessages_test()
{
    const auto streamOfMsgid = [](uint32_t msgid) {
        mavlink_message_t m{};
        m.msgid = msgid;
        return FlightEventLogger::streamOf(m);
    };

    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_HEARTBEAT) == Stream::HeartbeatState);
    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_SYS_STATUS) == Stream::SysStatusHealth);
    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_POSITION_TARGET_GLOBAL_INT) == Stream::TargetPoint);

    // 事件不是状态：命令、应答、报警一律逐条记，放进这个集合就等于把它们删掉。
    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_STATUSTEXT) == Stream::None);
    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_COMMAND_LONG) == Stream::None);
    QVERIFY(streamOfMsgid(MAVLINK_MSG_ID_COMMAND_ACK) == Stream::None);
}

void FlightEventLoggerTest::_firstStreamValueIsWritten_test()
{
    FlightEventLogger::StreamState state;
    const QDateTime now(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    const auto decision = FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("解锁=否"), now);

    QVERIFY(decision.write);
    // 首次写入没有「上次」，不能用 0 冒充 —— 0 会被下游读成「刚刚变过」。
    QVERIFY2(decision.secondsSinceLastWrite < 0.0,
             qPrintable(QString::number(decision.secondsSinceLastWrite)));
    QVERIFY(state.hasValue);
    QCOMPARE(state.value, QByteArrayLiteral("解锁=否"));
}

void FlightEventLoggerTest::_unchangedStreamValueIsSkipped_test()
{
    FlightEventLogger::StreamState state;
    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    (void) FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("解锁=否"), t0);
    const auto again = FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("解锁=否"),
                                                            t0.addSecs(1));

    QVERIFY2(!again.write, "取值没变就不该再写一行");

    // 阳性对照：同一条流换个值必须写 —— 否则一个恒返回 write=false 的实现也能过。
    const auto changed = FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("解锁=是"),
                                                              t0.addSecs(2));
    QVERIFY(changed.write);
}

void FlightEventLoggerTest::_changedStreamValueIsWrittenWithElapsed_test()
{
    FlightEventLogger::StreamState state;
    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    (void) FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("自定义模式=2"), t0);
    const auto changed = FlightEventLogger::decideStreamWrite(state, QByteArrayLiteral("自定义模式=4"),
                                                              t0.addMSecs(2500));

    QVERIFY(changed.write);
    QVERIFY2(qAbs(changed.secondsSinceLastWrite - 2.5) < 0.001,
             qPrintable(QString::number(changed.secondsSinceLastWrite)));
    // 基准必须是「上次写入的时刻」，不是上次调用的时刻。
    QCOMPARE(state.lastWrittenAt, t0.addMSecs(2500));
}

void FlightEventLoggerTest::_alertStreamIsNeverDeduplicated_test()
{
    char text[MAVLINK_MSG_STATUSTEXT_FIELD_TEXT_LEN] = {};
    (void) std::strncpy(text, "Preflight Fail: system power unavailable", sizeof(text) - 1);

    mavlink_message_t alert{};
    (void) mavlink_msg_statustext_pack(1, 1, &alert, MAV_SEVERITY_CRITICAL, text, 0, 0);

    // 同一段告警连播两次必须出两行：飞控出问题时正是靠反复播报暴露的。
    QVERIFY(FlightEventLogger::streamOf(alert) == Stream::None);

    // 阳性对照：去重机制本身是有效的 —— 同样的「两帧同值」若落进流集合就会被吞掉。
    // 少了这一格，「streamOf 返回 None」可能只是因为压根没实现去重。
    FlightEventLogger::StreamState state;
    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);
    const QByteArray fingerprint = FlightEventLogger::renderFrame(alert).toUtf8();
    QVERIFY(!fingerprint.isEmpty());
    QVERIFY(FlightEventLogger::decideStreamWrite(state, fingerprint, t0).write);
    QVERIFY(!FlightEventLogger::decideStreamWrite(state, fingerprint, t0.addSecs(1)).write);
}

void FlightEventLoggerTest::_statusFramesRenderReadableState_test()
{
    // 心跳：解锁位 + 自定义模式 + 系统状态
    mavlink_message_t armed{};
    (void) mavlink_msg_heartbeat_pack(1, 1, &armed, MAV_TYPE_FIXED_WING, MAV_AUTOPILOT_PX4,
                                      MAV_MODE_FLAG_SAFETY_ARMED | MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
                                      4, MAV_STATE_ACTIVE);
    const QString armedText = FlightEventLogger::renderFrame(armed);
    QVERIFY2(armedText.contains(QStringLiteral("解锁=是")), qPrintable(armedText));
    QVERIFY2(armedText.contains(QStringLiteral("自定义模式=4")), qPrintable(armedText));
    QVERIFY2(armedText.contains(QStringLiteral("运行中(4)")), qPrintable(armedText));

    // 未解锁必须是可区分的另一串 —— 否则「解锁」这一列等于没有。
    mavlink_message_t disarmed{};
    (void) mavlink_msg_heartbeat_pack(1, 1, &disarmed, MAV_TYPE_FIXED_WING, MAV_AUTOPILOT_PX4,
                                      0, 4, MAV_STATE_STANDBY);
    const QString disarmedText = FlightEventLogger::renderFrame(disarmed);
    QVERIFY2(disarmedText.contains(QStringLiteral("解锁=否")), qPrintable(disarmedText));
    QVERIFY2(!disarmedText.contains(QStringLiteral("解锁=是")), qPrintable(disarmedText));

    // SYS_STATUS：传感器健康位图 + 电池
    mavlink_message_t sys{};
    (void) mavlink_msg_sys_status_pack(1, 1, &sys, 0, 0, 0x00000001u, 0, 12000, -1, 88,
                                       0, 0, 0, 0, 0, 0, 0, 0, 0);
    const QString sysText = FlightEventLogger::renderFrame(sys);
    QVERIFY2(sysText.contains(QStringLiteral("0x00000001")), qPrintable(sysText));
    QVERIFY2(sysText.contains(QStringLiteral("12000")), qPrintable(sysText));
    QVERIFY2(sysText.contains(QStringLiteral("88")), qPrintable(sysText));

    // 目标点：degE7 → 度
    mavlink_message_t target{};
    (void) mavlink_msg_position_target_global_int_pack(1, 1, &target, 0,
                                                       MAV_FRAME_GLOBAL_RELATIVE_ALT_INT, 0,
                                                       473977420, 85456050, 120.5f,
                                                       0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f);
    const QString targetText = FlightEventLogger::renderFrame(target);
    QVERIFY2(targetText.contains(QStringLiteral("47.3977420")), qPrintable(targetText));
    QVERIFY2(targetText.contains(QStringLiteral("8.5456050")), qPrintable(targetText));
}

// ---------------------------------------------------------------------------
// 心跳间隔
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_heartbeatGapIsAnnouncedAfterSilence_test()
{
    QDateTime last;
    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    // 首次心跳没有「上次」，不能报中断。
    QVERIFY(!FlightEventLogger::observeHeartbeat(last, t0, 5.0).resumed);

    const auto gap = FlightEventLogger::observeHeartbeat(last, t0.addSecs(30), 5.0);
    QVERIFY(gap.resumed);
    QVERIFY2(qAbs(gap.silentSeconds - 30.0) < 0.001,
             qPrintable(QString::number(gap.silentSeconds)));
    QCOMPARE(last, t0.addSecs(30));
}

void FlightEventLoggerTest::_normalHeartbeatIsNotAGap_test()
{
    QDateTime last;
    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);
    (void) FlightEventLogger::observeHeartbeat(last, t0, 5.0);

    const auto normal = FlightEventLogger::observeHeartbeat(last, t0.addMSecs(1000), 5.0);
    QVERIFY(!normal.resumed);

    // 阳性对照：同一条流静默 30 秒必须报 —— 否则「恒不报」的实现也能过。
    QVERIFY(FlightEventLogger::observeHeartbeat(last, t0.addMSecs(31000), 5.0).resumed);
}

void FlightEventLoggerTest::_heartbeatGapSurvivesDeduplication_test()
{
    // 心跳中断的判定必须独立于「这一帧要不要写盘」。
    // 若把判定挪到去重之后（看着更省事），取值未变的心跳会被整个跳过，
    // 「心跳中断」就永远不会现形 —— 而链路无声恰恰是本日志最该抓到的事之一。
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    FlightEventLogger* logger = FlightEventLogger::instance();
    QVERIFY(logger->start(dir.path()));
    const QString path = logger->filePath();

    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);
    const auto heartbeat = [] {
        mavlink_message_t m{};
        (void) mavlink_msg_heartbeat_pack(1, 1, &m, MAV_TYPE_FIXED_WING, MAV_AUTOPILOT_PX4,
                                          0, 2, MAV_STATE_ACTIVE);
        return m;
    };

    QVERIFY(logger->logFrame(Direction::FromVehicle, heartbeat(), t0));             // 首次 → 写
    QVERIFY(!logger->logFrame(Direction::FromVehicle, heartbeat(), t0.addSecs(1))); // 未变 → 不写
    // 静默 8 秒后恢复：这一帧本身仍被去重，但「中断 8 秒」那一行必须出来。
    QVERIFY(logger->logFrame(Direction::FromVehicle, heartbeat(), t0.addSecs(9)));

    logger->stop();

    QFile f(path);
    QVERIFY(f.open(QIODevice::ReadOnly));
    QStringList dataLines;
    for (const QByteArray& raw : f.readAll().split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (!line.isEmpty() && !line.startsWith(QLatin1Char('#'))) {
            dataLines << line;
        }
    }
    f.close();

    QCOMPARE(dataLines.size(), 2);
    QVERIFY2(dataLines[1].contains(QStringLiteral("心跳中断 8.0 秒后恢复")), qPrintable(dataLines[1]));
}

// ---------------------------------------------------------------------------
// 文件生命周期
// ---------------------------------------------------------------------------

void FlightEventLoggerTest::_fileNameCollisionGetsSuffix_test()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QDateTime when(QDate(2026, 9, 29), QTime(10, 43, 21), QTimeZone::UTC);

    const QString first = FlightEventLogger::uniqueFileNameIn(dir.path(), when);
    QCOMPARE(first, QStringLiteral("qgc_flight_20260929_104321.log"));

    {
        QFile occupied(QDir(dir.path()).filePath(first));
        QVERIFY(occupied.open(QIODevice::WriteOnly));
    }

    // 同一秒内第二次启动（用户会同时开两台 QGC）不得覆盖第一份日志。
    const QString second = FlightEventLogger::uniqueFileNameIn(dir.path(), when);
    QVERIFY2(second != first, qPrintable(second));
    QVERIFY2(second.endsWith(QStringLiteral(".log")), qPrintable(second));
    QVERIFY2(second.contains(QStringLiteral("20260929_104321")), qPrintable(second));
    QVERIFY(!QFile::exists(QDir(dir.path()).filePath(second)));
}

void FlightEventLoggerTest::_logFrameWritesToFileAndDeduplicates_test()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    FlightEventLogger* logger = FlightEventLogger::instance();
    QVERIFY(logger->start(dir.path()));
    QVERIFY(logger->isOpen());
    const QString path = logger->filePath();
    QVERIFY(QFile::exists(path));

    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    const auto heartbeat = [](bool armed, uint32_t mode) {
        mavlink_message_t m{};
        (void) mavlink_msg_heartbeat_pack(1, 1, &m, MAV_TYPE_FIXED_WING, MAV_AUTOPILOT_PX4,
                                          armed ? MAV_MODE_FLAG_SAFETY_ARMED : 0, mode,
                                          MAV_STATE_ACTIVE);
        return m;
    };
    mavlink_message_t command{};
    (void) mavlink_msg_command_long_pack(255, 190, &command, 1, 1, MAV_CMD_NAV_LAND, 0,
                                         0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f);

    QVERIFY(logger->logFrame(Direction::ToVehicle, command, t0));
    QVERIFY(logger->logFrame(Direction::FromVehicle, heartbeat(false, 2), t0));            // 首次 → 写
    QVERIFY(!logger->logFrame(Direction::FromVehicle, heartbeat(false, 2), t0.addSecs(1))); // 未变 → 不写
    QVERIFY(!logger->logFrame(Direction::FromVehicle, heartbeat(false, 2), t0.addSecs(2))); // 仍未变 → 不写
    QVERIFY(logger->logFrame(Direction::FromVehicle, heartbeat(true, 4), t0.addSecs(3)));   // 变了 → 写

    logger->stop();
    QVERIFY(!logger->isOpen());

    QFile f(path);
    QVERIFY(f.open(QIODevice::ReadOnly));
    QStringList dataLines;
    for (const QByteArray& raw : f.readAll().split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (!line.isEmpty() && !line.startsWith(QLatin1Char('#'))) {
            dataLines << line;
        }
    }
    f.close();

    // 5 帧进去、3 行出来：两条重复心跳被去重，命令与两条变化的心跳各一行。
    QCOMPARE(dataLines.size(), 3);
    QVERIFY2(dataLines[0].contains(QStringLiteral("NAV_LAND(21)")), qPrintable(dataLines[0]));
    QVERIFY2(dataLines[0].contains(FlightEventLogger::directionLabel(Direction::ToVehicle)),
             qPrintable(dataLines[0]));
    QVERIFY2(dataLines[1].contains(QStringLiteral("解锁=否")), qPrintable(dataLines[1]));
    QVERIFY2(dataLines[2].contains(QStringLiteral("解锁=是")), qPrintable(dataLines[2]));
    // 变化的那一行要带上「距上次变化」—— 不然看不出这个状态稳定了多久。
    QVERIFY2(dataLines[2].contains(QStringLiteral("距上次变化 3.0 秒")), qPrintable(dataLines[2]));
}

void FlightEventLoggerTest::_streamDedupIsPerDirection_test()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    FlightEventLogger* logger = FlightEventLogger::instance();
    QVERIFY(logger->start(dir.path()));
    const QString path = logger->filePath();

    const QDateTime t0(QDate(2026, 9, 29), QTime(10, 0, 0), QTimeZone::UTC);

    const auto heartbeat = [](uint32_t mode) {
        mavlink_message_t m{};
        (void) mavlink_msg_heartbeat_pack(1, 1, &m, MAV_TYPE_FIXED_WING, MAV_AUTOPILOT_PX4,
                                          0, mode, MAV_STATE_ACTIVE);
        return m;
    };

    // QGC 自己每秒发一条 GCS 心跳，飞行器也每秒回一条：同 msgid、不同取值。
    // 去重状态若只按 msgid 存，两条流会互相顶掉对方的取值 ⇒ 每条心跳都判成「变了」，
    // 去重彻底失效。这不是假想：真机端到端实测到每次心跳各写一行、并伴以
    // 「距上次变化 0.0 秒」（见 memory 里防重放水位按方向分列的同型教训）。
    QVERIFY(logger->logFrame(Direction::FromVehicle, heartbeat(2), t0));             // 该方向首次 → 写
    QVERIFY(logger->logFrame(Direction::ToVehicle, heartbeat(9), t0.addSecs(1)));    // 另一方向首次 → 也写
    QVERIFY(!logger->logFrame(Direction::FromVehicle, heartbeat(2), t0.addSecs(2))); // 本方向未变 → 不写
    QVERIFY(!logger->logFrame(Direction::ToVehicle, heartbeat(9), t0.addSecs(3)));   // 本方向未变 → 不写
    QVERIFY(!logger->logFrame(Direction::FromVehicle, heartbeat(2), t0.addSecs(4))); // 仍未变 → 不写

    logger->stop();

    QFile f(path);
    QVERIFY(f.open(QIODevice::ReadOnly));
    QStringList dataLines;
    for (const QByteArray& raw : f.readAll().split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (!line.isEmpty() && !line.startsWith(QLatin1Char('#'))) {
            dataLines << line;
        }
    }
    f.close();

    // 5 帧进去、2 行出来。
    QCOMPARE(dataLines.size(), 2);
    QVERIFY2(dataLines[0].contains(FlightEventLogger::directionLabel(Direction::FromVehicle)),
             qPrintable(dataLines[0]));
    QVERIFY2(dataLines[1].contains(FlightEventLogger::directionLabel(Direction::ToVehicle)),
             qPrintable(dataLines[1]));
    // 两个方向各自的首次都不带「距上次变化」：首次没有「上次」。若两条流共用一个槽位，
    // 后写的那个方向会被算成「距另一条流 1.0 秒」。
    QVERIFY2(!dataLines[0].contains(QStringLiteral("距上次变化")), qPrintable(dataLines[0]));
    QVERIFY2(!dataLines[1].contains(QStringLiteral("距上次变化")), qPrintable(dataLines[1]));
}

UT_REGISTER_TEST(FlightEventLoggerTest, TestLabel::Unit)
