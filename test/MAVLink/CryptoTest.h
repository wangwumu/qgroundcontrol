#pragma once

#include "UnitTest.h"

class CryptoTest : public UnitTest
{
    Q_OBJECT

private slots:
    // DeviceID 重组
    void _testDeviceIDEncodeDecode();
    void _testDeviceIDSignatureBit();
    void _testDeviceIDMessageRoundTrip();

    // AES-256-GCM 加解密
    void _testCryptoRoundTrip();
    void _testCryptoWrongKey();

    // 防重放
    void _testReplayGuard();
    void _testReplayGuardTwoPhase();

    // 加密帧编解码（标准帧 ↔ 加密帧）
    void _testCodecRoundTrip();
    void _testCodecWrongKey();
    void _testCodecMalformedFrame();      // 畸形/截断帧长度防御（C3）
    void _testCodecHeaderTamper();        // 帧头 deviceID 篡改 → 密钥绑定拒绝
    void _testCodecOverflowDegrade();     // 超限 payload 退化帧（规范 §2.3）
    void _testCryptoEmptyPlaintext();     // 空明文（退化帧）加解密

    // MAVLink parser 放行 deviceID 高字节复用 incompat_flags（bit1~7）
    void _testParserAcceptsHighDeviceID();
    void _testParserSignedFlagPreserved();   // bit0(SIGNED) 置位 → 进入 SIGNATURE_WAIT
    void _testParserRejectsBadCrc();         // incompat 置位 + 坏 CRC → BAD_CRC

    // counter 随机起点（规范 §2.5：62 位奇数，避免重启后 nonce 复用）
    void _testRandomOddCounter();
    void _testNextOutgoingCounter();         // nextOutgoingCounter 端到端：首帧随机、+2 递增、非 Active 拒绝

    // VTOL 自定义消息（80000-80003）：字段排序 + CRC_EXTRA + 往返（纳入加密链路）
    void _testVtolMessages();

    // 80005 QGC 登记心跳：CRC_EXTRA + pack 帧字节（帧头 deviceID 拆分 + 变长 len + CRC 一致）
    void _testQgcRegistration();

    // 本地 key 文件注入（调试路径）：读 32 字节文件 → 缓存 → keyForDevice 可命中
    void _testInjectLocalKey();
};
