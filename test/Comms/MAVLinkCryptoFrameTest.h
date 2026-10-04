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

    /// 被动取密钥时机（规范 §2.7.2 e，Task 8）：明文待命心跳支。
    ///
    /// ‼️ 必须声明在**最后**：本用例会置 `_monitorListActive = true`（无复位入口，全仓只有
    ///    `setResponsibleParty` 会在会话边界清它）并设上 `_serverUrl`。两个都是**进程级**状态，
    ///    排在前面会把"清单未生效 ⇒ 回退 `_linkedDevices`"这类判据的基础态污染掉。
    ///    moc 按声明顺序生成，故"最后"＝"最后跑"。
    void _testPlaintextHeartbeatTriggersFetchOnlyWhenInManifest();
};
