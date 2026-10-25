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
    void _streamDedupIsPerDirection_test();
    void _alertStreamIsNeverDeduplicated_test();
    void _statusFramesRenderReadableState_test();

    // 心跳间隔
    void _heartbeatGapIsAnnouncedAfterSilence_test();
    void _normalHeartbeatIsNotAGap_test();
    void _heartbeatGapSurvivesDeduplication_test();
    void _heartbeatGapIsTrackedPerDevice_test();

    // 文件生命周期
    void _fileNameCollisionGetsSuffix_test();
    void _logFrameWritesToFileAndDeduplicates_test();

    // 排障所需：设备归属、80005 载荷、设备级状态迁移
    void _registrationFrameRendersDeviceList_test();
    void _registrationFrameRendersTrailingZeroId_test();
    void _registrationFrameRendersTruncation_test();
    void _deviceIdIsWrittenIntoLine_test();
    void _streamDedupIsPerDevice_test();
    void _deviceStateTransitionIsWrittenOnce_test();

    // 写盘失败不得推进去重/状态记账（否则该转换在进程余下生命里永久丢失）
    void _failedWriteDoesNotRecordDeviceState_test();
    void _failedWriteDoesNotAdvanceStreamDedup_test();
    void _failedWriteDoesNotLoseHeartbeatGap_test();
    void _startFailsWhenHeaderCannotBeWritten_test();

    // 80005 的可见性：不逐帧写，只在登记集合变化时写一行汇总
    void _registrationFrameIsNotLoggedPerFrame_test();
    void _registrationSetIsLoggedOnlyWhenChanged_test();
};
