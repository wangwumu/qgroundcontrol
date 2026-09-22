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
    void _testReplayGuardUpDownSeparation();  // 上下行 lastNonce 分离：互不污染、reset/clear 双清

    // 收帧时间戳（§3.6.1）：判据是「任意一帧」不是「心跳帧」，载体是本地单调时钟
    void _testNoteDeviceFrame();

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
    void _testNextOutgoingCounterRestartYPlusOne();  // 规范 §3.2.4.2：重启后取下行 Y 的奇数后继，非随机起点
    void _testNextOutgoingCounterRejectsWrappedDownlink();  // 下行越界须拒发（守卫在算式之前）

    // VTOL 自定义消息（80000-80003）：字段排序 + CRC_EXTRA + 往返（纳入加密链路）
    void _testVtolMessages();

    // 80005 QGC 登记心跳：CRC_EXTRA + pack 帧字节（帧头 deviceID 拆分 + 变长 len + CRC 一致）
    void _testQgcRegistration();

    // 本地 key 文件注入（调试路径）：读 32 字节文件 → 缓存 → keyForDevice 可命中
    void _testInjectLocalKey();

    // 报文链路日志器格式验证（联调宏 QGC_CRYPTO_LINK_LOG 启用时断言）
    void _testCryptoLinkLogger();

    // 加密心跳扩展基础状态（60822.0 EXT）：37B 小端解析 + 哨兵 + 往返（block=74）
    void _testHeartbeatExt();
    // EXT 注入层：buildHeartbeatExtTelemetry 门控/哨兵/字段映射（合成遥测）
    void _testHeartbeatExtInjection();

    // 80005 分批（§3.3/§3.4）：切批 + 环形轮转 + 覆盖性
    void _testNextRegistrationBatch();

    // 监控清单与超时阈值（§3.5.3/§3.6.4）：一次调用两个实参、非法 id 跳过、空清单回退
    void _testSetMonitorDevices();

    // 加速首轮（§3.4）：集合变化触发连续发送、集合不变不触发、容量天花板截断
    void _testRequestAcceleratedRegistration();

    // 定向重发（§3.6.2）：只发一帧、**绝不移出登记集合**、无 registrationEnabled 门
    void _testReRegisterDevice();
};
