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
};
