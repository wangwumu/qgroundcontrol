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
};
