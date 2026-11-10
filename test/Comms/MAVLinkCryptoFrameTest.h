#pragma once

#include "BaseClasses/VehicleTestManualConnect.h"

/// 加密链路下的收帧时间戳接线（设计文档 §3.6.1）。
///
/// 钉的是 `MAVLinkProtocol` 里**两个分支各有一行** `noteDeviceFrame`：
///   ① `_receiveEncryptedBytes` 的明文待命心跳支；
///   ② `_processEncryptedFrame` 取完 deviceID 处（**防重放检查之前**）。
///
/// ⚠️ 两格必须**对称**且各自独立。若只写 ②，把 ① 那行删掉不会有任何用例变红；
///    若两格其实走的是同一条路径（例如都用了加密帧），删任一行会**两格一起红**——
///    那时它们并没有分别守住两条分支。
class MAVLinkCryptoFrameTest : public VehicleTestManualConnect
{
    Q_OBJECT

protected slots:
    void cleanup() override;

private:
    /// 在 `cryptoEnabled` 的最小窗口内同步注入一帧（见 .cc 里的详细理由）。
    void _injectWithCryptoEnabled(const QByteArray& frame);

private slots:
    void _testPlaintextHeartbeatNotesFrame();
    void _testEncryptedFrameNotesFrame();

    /// 会话边界（2026-11-10 用户裁定）：**被防重放水位拦下的加密心跳**，只有解密后
    /// EXT 的 GPS UTC 与本地时间相差 ≤5s 才把本机下行水位压到本帧 counter；旧 UTC / UTC=0 一律仍按重放丢弃。
    ///
    /// 复现场景：qgc1 一直运行（水位被旧会话推到 3.298e18），PX4 重启后新会话从
    /// 1.618e18 起 ⇒ 恒运行的 qgc1 每一帧都被判重放、"没有数据"；新起的 qgc2 水位为空
    /// 所以能接。清水位必须由**认证过的新鲜证据**触发——明文待命心跳无认证（伪造它
    /// 就能重放旧加密帧），故判据只能放在解密侧。
    /// ⚠️ 本用例是本文件唯一真正解密成功的一条：它会走到 `_feedStandardFrame`，故 payload
    ///    用 `MAV_TYPE_GCS`（`MultiVehicleManager` 明确不为其建车），避免牵出
    ///    InitialConnectStateMachine 的上行。仍要求它排在两个 `setResponsibleParty` 用例之前。
    void _testSessionBoundaryLowersReplayWatermark();

    /// 被动取密钥时机（规范 §2.7.2 e，Task 8）：明文待命心跳支。
    ///
    /// ‼️ 必须声明在**最后**：本用例会置 `_monitorListActive = true`，而本文件**全程不调**
    ///    `CryptoController::setResponsibleParty`（那是 `CryptoTest` 在 `init()` 里每格调的）
    ///    ⇒ 闩在本文件内**只升不落**，排在前面会把后面用例"清单未生效 ⇒ 回退 `_linkedDevices`"
    ///    这类判据的基础态污染掉。
    /// ⚠️ 本用例设的另一个进程级状态 `_serverUrl` **不是**污染源：本文件 `cleanup()` 里的
    ///    `setServerUrl(QString())`（`MAVLinkCryptoFrameTest.cc`）每格都会复位它——放 cleanup
    ///    而不是用例末尾，正是为了失败路径也执行。「无复位入口」这句话**只对 `_monitorListActive`
    ///    成立**，别推广到 `_serverUrl`，也别推广到全仓。
    ///    moc 按声明顺序生成，故"最后"＝"最后跑"。
    void _testPlaintextHeartbeatTriggersFetchOnlyWhenInManifest();

    /// 非引入方的明文待命心跳**不得**喂标准解析器（2026-11-10 用户复现）。
    ///
    /// 否则已登录的监控员会被待命中的 PX4 建出 Vehicle → InitialConnectStateMachine
    /// 自动请求任务/围栏/集结点 → 全部被 Standby 丢弃 → 三连报错弹窗。飞行中的加密帧
    /// 不受影响（走 `_processEncryptedFrame`），监控员照常看遥测。
    /// ⚠️ 同前一条：本用例在**最后**执行，会设 `setResponsibleParty`——该状态在本文件内
    ///    只升不落，排到前面会污染其它用例的基础态。
    void _testNonIntroducerPlaintextHeartbeatDoesNotBuildVehicle();
};
