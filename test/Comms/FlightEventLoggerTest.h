#pragma once

#include "UnitTest.h"

class FlightEventLoggerTest : public UnitTest
{
    Q_OBJECT

private slots:
    // 分类
    void _classifyCommandLong_test();
    void _classifyCommandAck_test();
    void _classifyStatusText_test();
    void _classifyUnrelatedFrameIsNone_test();

    // 渲染：命令 / 应答
    void _commandLongRendersCommandName_test();
    void _commandAckRendersResultInChinese_test();
    void _commandAckDeniedIsNotSilent_test();

    // 渲染：报警
    void _statusTextRendersSeverityInChinese_test();
    void _statusTextKeepsRawTabAndText_test();

    // 行格式与文件名
    void _formatLineCarriesTimestampDirectionAndCategory_test();
    void _fileNameIsTimestamped_test();

    // 高频状态流：分类与去重
    void _streamOfHighFrequencyMessages_test();
    void _firstStreamValueIsWritten_test();
    void _unchangedStreamValueIsSkipped_test();
    void _changedStreamValueIsWrittenWithElapsed_test();
    void _alertStreamIsNeverDeduplicated_test();
    void _statusFramesRenderReadableState_test();

    // 心跳间隔
    void _heartbeatGapIsAnnouncedAfterSilence_test();
    void _normalHeartbeatIsNotAGap_test();
    void _heartbeatGapSurvivesDeduplication_test();

    // 文件生命周期
    void _fileNameCollisionGetsSuffix_test();
    void _logFrameWritesToFileAndDeduplicates_test();
};
