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
};
