#pragma once

#include "UnitTest.h"

class CryptoTest : public UnitTest
{
    Q_OBJECT

private slots:
    // 每个用例前统一把单例标为责任方（见 .cc 里的实现注释）。
    // 唯一不适用的是 _testBeginLinkingRequiresResponsibleParty，它自己会置回 false。
    void init();

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
    void _testNextOutgoingCounterPrefersHigherDownlink();  // 档①②合并：一律取 max(上行,下行) 的奇数后继
    void _testNextOutgoingCounterRejectsWrappedDownlink();  // 下行越界须拒发（守卫在算式之前）

    // 责任方闸：只有站点操作员（含 SITE_ATC 身份）的 QGC 才允许建链进 Active
    void _testBeginLinkingRequiresResponsibleParty();

    // 起/终维（2026-10-04 裁定）：只有**该机当前任务起飞站**的 QGC 才允许建链
    void _testBeginLinkingRequiresInitiatorSite();

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

    // 清单从未生效 ⇒ 回退 _linkedDevices（§3.5.4）这条零回归承诺的判据。
    // ‼️ 声明在 _testSetMonitorDevices **之前**：本用例要的初态是"闩仍为 false"。
    //    这条顺序原本是**硬约束**（`_monitorListActive` 当时一旦置 true 就永不回落，全仓
    //    只有一处 `= true`、无复位点 ⇒ 排在置 true 的那个用例之后，false 那一臂就再也测不到）；
    //    2026-10-04 起 `CryptoController::setResponsibleParty` 会在会话边界作废清单，
    //    而本文件 `init()` 每次都调它 ⇒ 顺序变成**冗余保险**而非必需。保留它：判据越少依赖
    //    "谁先跑"越好，而这行注释的代价是零。
    void _testRegistrationFallbackToLinked();

    // 监控清单与超时阈值（§3.5.3/§3.6.4）：一次调用两个实参、非法 id 跳过、空清单**生效**
    void _testSetMonitorDevices();

    // 会话边界作废监控清单（2026-10-04 补）：责任方身份被重新判定 ⇒ 闩回落、清单清空
    void _testMonitorListInvalidatedAtSessionBoundary();

    // 加速首轮（§3.4）：集合变化触发连续发送、集合不变不触发、容量天花板截断
    void _testRequestAcceleratedRegistration();

    // 定向重发（§3.6.2）：只发一帧、**绝不移出登记集合**、自带 registrationEnabled 门
    void _testReRegisterDevice();

    // 签出释出：登记集合撤销 + 密钥删除 + 上下行水位**全清** + 让出上行权（2026-10-03 裁定）
    void _testReleaseDevice();

    // 签出释出的成员资格闸（2026-10-04 补）：与本端毫无关联的 deviceID 不得被释出
    void _testReleaseDeviceUnknownDeviceIgnored();

    // 异步建链（§3.2）：密钥**未**缓存 ⇒ fetchKey → keyFetched 回包 ⇒ `_onKeyFetched` 的
    // **正常臂**调 `confirmLinking()` 进 Active。本文件其余 `beginLinking` 没有一处落到这条
    // 异步臂上，删掉那一句 `confirmLinking()` 现有用例会全绿。
    void _testAsyncLinkingConfirm();

    // 批量取密钥（规范 §2.7.2 d，Task 5）：空列表 / 全非法 ID ⇒ 过滤后为空 ⇒ 一次 HTTP 都不发。
    // 判据落在新增的 `keysRequested` 信号上（它是"到底有没有发起请求"的唯一可观测点）。
    void _testFetchKeysEmptyListMakesNoRequest();

    // 站点视图清单的 adopt 侧（规范 §2.7.2 e，Task 6）：`addLinkedDevice` 只在
    // "**新**加入且本地尚无密钥"时触发一次拉取。判据同样落在 `keysRequested` 上。
    void _testAddLinkedDeviceFetchesOnlyWhenKeyMissing();

    // `isInManifest` 的取清单口径（Task 6，Task 8 依赖）：必须是
    // `_monitorListActive ? _monitorDevices : _linkedDevices`，**不是**按 `_monitorDevices`
    // 空否判。⚠️ 本用例会置 `_monitorListActive = true`；它**不在 slots 末尾**
    //    （其后还有 `_testSetMonitorDevicesFetchesOnlyMissing` 等三格），所以"不污染后续用例"
    //    靠的**不是声明位置**，而是闩**有**复位入口：`CryptoController::setResponsibleParty`
    //    在会话边界作废清单，而本文件 `init()`（`CryptoTest.cc`）每格**无条件**调它
    //    ⇒ 每格开头闩恒为 false，顺序**非硬约束**；格内再用 `setMonitorDevices` 显式钉两种取值。
    void _testIsInManifestUsesMonitorListActiveNotEmptiness();

    // 主动取密钥时机之二（规范 §2.7.2 e，Task 7）：监控清单**内容变化**时，对尚无本地
    // 密钥的 ID 触发**一次批量**拉取。
    // ⚠️ 三格都在钉 `changed` 这个判据：变了才拉 / 没变不拉 / 空清单不拉。
    //    判据同样落在 `keysRequested` 上（与 Task 5/6 同一套观测点）。
    void _testSetMonitorDevicesFetchesOnlyMissing();
    void _testSetMonitorDevicesUnchangedDoesNotRefetch();
    void _testSetMonitorDevicesEmptyFetchesNothing();

    // 签出释出的 ⑤（2026-10-06 补）：三张 per-device 表必须清。此前 ①–④ 一律不动它们。
    void _testReleaseDeviceClearsPerDeviceTables();

    // ⑤ 的后半：**只清不够** —— mavp2p 在配对老化（实测默认 60s）前仍会转发该机的帧，
    // 而 `MAVLinkProtocol.cc` 的四条收帧记账是**无条件**的 ⇒ 闸必须落在
    // `learnDeviceSystemMapping` / `noteDeviceFrame` 体内，否则下一帧就把表重建回来。
    // ⚠️ 本格同时钉"闸可撤销"（`addLinkedDevice` 与 `setMonitorDevices` 两个撤销点）——
    //    少了那半，"无条件拒绝一切 learn/note"这种把本端钉死的实现也会全绿。
    void _testReleaseDeviceBlocksFrameReactivation();

    // ⑤ 的第三格：`reRegisterDevice` 的签出闸。它与 ⑤ 清 `_lastFrameMs` 是**配对**的两半：
    // 清掉时间戳后 `RomView.qml` 的 `since < 0` 判据恒真 ⇒ 每 2s 重发会把 mavp2p 那个配对的
    // `qgcSeen` 重新刷新鲜 ⇒ 配对永不过期。
    void _testReleaseDeviceBlocksReRegister();
};
