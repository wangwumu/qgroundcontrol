#include "CryptoTest.h"

#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/CryptoLinkLogger.h"
#include "Crypto/DeviceID.h"
#include "Crypto/MAVLinkCrypto.h"
#include "Crypto/ReplayGuard.h"
#include "MAVLinkLib.h"
#include "Extensions/VTOLSafetyMessages.h"

#include <QtTest/QtTest>

#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QTemporaryFile>
#include <cstring>

namespace {

using namespace MAVLinkCrypto;

/// 固定测试密钥（32 字节递增模式）。
Key testKey()
{
    Key key{};
    for (size_t i = 0; i < key.size(); ++i) {
        key[i] = static_cast<uint8_t>(i);
    }
    return key;
}

/// 构造一个标准 MAVLink HEARTBEAT 帧字节（含 CRC）。
QByteArray makeHeartbeatFrame(uint8_t sysid, uint8_t compid)
{
    mavlink_message_t msg{};
    (void) mavlink_msg_heartbeat_pack(sysid, compid, &msg, MAV_TYPE_QUADROTOR, MAV_AUTOPILOT_GENERIC, 0, 0, 0);

    uint8_t buffer[MAVLINK_MAX_PACKET_LEN];
    const int len = mavlink_msg_to_send_buffer(buffer, &msg);
    return QByteArray(reinterpret_cast<const char*>(buffer), len);
}

/// HEARTBEAT 消息的真实 CRC_EXTRA。
uint8_t heartbeatCrcExtra()
{
    const mavlink_msg_entry_t* const entry = mavlink_get_msg_entry(MAVLINK_MSG_ID_HEARTBEAT);
    return entry ? entry->crc_extra : 0;
}

/// 构造一个 incompat_flags 字节为指定值的合法 HEARTBEAT 帧（重算 CRC）。
/// 用于验证 parser 对 deviceID 高字节复用 incompat_flags（bit1~7）的放行（规范 §1.4/§1.5）。
QByteArray makeFrameWithIncompat(uint8_t incompat)
{
    mavlink_message_t msg{};
    (void) mavlink_msg_heartbeat_pack(0x0C, 0x0D, &msg, MAV_TYPE_QUADROTOR, MAV_AUTOPILOT_GENERIC, 0, 0, 0);

    uint8_t buf[MAVLINK_MAX_PACKET_LEN];
    int pos = 0;
    buf[pos++] = 0xFD;
    buf[pos++] = msg.len;
    buf[pos++] = incompat;
    buf[pos++] = msg.compat_flags;
    buf[pos++] = msg.seq;
    buf[pos++] = msg.sysid;
    buf[pos++] = msg.compid;
    buf[pos++] = static_cast<uint8_t>(msg.msgid & 0xFFu);
    buf[pos++] = static_cast<uint8_t>((msg.msgid >> 8) & 0xFFu);
    buf[pos++] = static_cast<uint8_t>((msg.msgid >> 16) & 0xFFu);

    // CRC 覆盖 len..msgid + payload + crc_extra（与 mavlink_finalize_message_buffer 一致）
    uint16_t checksum;
    crc_init(&checksum);
    for (int i = 1; i < pos; ++i) {
        crc_accumulate(buf[i], &checksum);
    }
    for (int i = 0; i < msg.len; ++i) {
        crc_accumulate(static_cast<uint8_t>(_MAV_PAYLOAD(&msg)[i]), &checksum);
    }
    crc_accumulate(heartbeatCrcExtra(), &checksum);

    for (int i = 0; i < msg.len; ++i) {
        buf[pos++] = static_cast<uint8_t>(_MAV_PAYLOAD(&msg)[i]);
    }
    buf[pos++] = static_cast<uint8_t>(checksum & 0xFFu);
    buf[pos++] = static_cast<uint8_t>(checksum >> 8);

    return QByteArray(reinterpret_cast<const char*>(buf), pos);
}

/// 用本地 parser 状态逐字节解析一帧（自包含，不读写全局通道状态）。
/// 返回最后一字节的 framing；解析过程中填充 message 与 outStatus。
uint8_t parseFrame(const QByteArray& frame, mavlink_message_t& message, mavlink_status_t& outStatus)
{
    mavlink_message_t rxmsg{};
    mavlink_status_t status{};
    uint8_t framing = MAVLINK_FRAMING_INCOMPLETE;
    for (int i = 0; i < frame.size(); ++i) {
        framing = mavlink_frame_char_buffer(&rxmsg, &status, static_cast<uint8_t>(frame.at(i)),
                                            &message, &outStatus);
    }
    return framing;
}

} // namespace

void CryptoTest::_testDeviceIDEncodeDecode()
{
    const DeviceID id = makeDeviceID(0x12, 0x34, 0x56, 0x78);
    QCOMPARE(id, static_cast<DeviceID>(0x12345678));

    QCOMPARE(incompatFlag(id), static_cast<uint8_t>(0x12));
    QCOMPARE(compatFlag(id), static_cast<uint8_t>(0x34));
    QCOMPARE(systemID(id), static_cast<uint8_t>(0x56));
    QCOMPARE(componentID(id), static_cast<uint8_t>(0x78));
}

void CryptoTest::_testDeviceIDSignatureBit()
{
    // incompatFlag 最高字节 bit0 必须为 0，否则 MAVLink 解析器误判签名
    QVERIFY(hasValidSignatureBit(0x00000000u));
    QVERIFY(hasValidSignatureBit(0x12000000u)); // bit24=0（0x12 的 bit0=0）
    QVERIFY(!hasValidSignatureBit(0x01000000u)); // bit24=1
    QVERIFY(!hasValidSignatureBit(0x13000000u)); // 0x13 的 bit0=1
}

void CryptoTest::_testDeviceIDMessageRoundTrip()
{
    mavlink_message_t msg{};
    msg.incompat_flags = 0x12;
    msg.compat_flags = 0x34;
    msg.sysid = 0x56;
    msg.compid = 0x78;

    const DeviceID id = fromMessage(msg);
    QCOMPARE(id, static_cast<DeviceID>(0x12345678));

    mavlink_message_t msg2{};
    toMessage(id, msg2);
    QCOMPARE(msg2.incompat_flags, static_cast<uint8_t>(0x12));
    QCOMPARE(msg2.compat_flags, static_cast<uint8_t>(0x34));
    QCOMPARE(msg2.sysid, static_cast<uint8_t>(0x56));
    QCOMPARE(msg2.compid, static_cast<uint8_t>(0x78));
}

void CryptoTest::_testCryptoRoundTrip()
{
    const Key key = testKey();
    const DeviceID deviceID = 0x12345678u;
    const uint64_t counter = 1;

    const uint8_t plaintext[] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE};
    const size_t plaintextLen = sizeof(plaintext);

    uint8_t ciphertext[sizeof(plaintext) + kDeviceIDSize];
    uint8_t tag[kTagSize];
    QVERIFY(encrypt(key, counter, deviceID, plaintext, plaintextLen, ciphertext, tag));

    // 密文长度 = 明文长度 + deviceID 前缀（4 字节）
    const size_t ciphertextLen = plaintextLen + kDeviceIDSize;

    uint8_t decrypted[sizeof(plaintext) + kDeviceIDSize];
    QVERIFY(decrypt(key, counter, deviceID, ciphertext, ciphertextLen, tag, decrypted));

    // 解密输出 = deviceID(4B) + 原始明文
    const DeviceID embeddedDeviceID = (static_cast<DeviceID>(decrypted[0]) << 24) |
                                      (static_cast<DeviceID>(decrypted[1]) << 16) |
                                      (static_cast<DeviceID>(decrypted[2]) << 8) |
                                      static_cast<DeviceID>(decrypted[3]);
    QCOMPARE(embeddedDeviceID, deviceID);
    QCOMPARE(QByteArray(reinterpret_cast<const char*>(decrypted + kDeviceIDSize), static_cast<int>(plaintextLen)),
             QByteArray(reinterpret_cast<const char*>(plaintext), static_cast<int>(plaintextLen)));
}

void CryptoTest::_testCryptoWrongKey()
{
    const Key key = testKey();
    Key wrongKey = testKey();
    wrongKey[0] ^= 0xFF; // 翻转一字节

    const DeviceID deviceID = 0x12345678u;
    const uint64_t counter = 1;

    const uint8_t plaintext[] = {0x01, 0x02, 0x03};
    uint8_t ciphertext[sizeof(plaintext) + kDeviceIDSize];
    uint8_t tag[kTagSize];
    QVERIFY(encrypt(key, counter, deviceID, plaintext, sizeof(plaintext), ciphertext, tag));

    uint8_t decrypted[sizeof(plaintext) + kDeviceIDSize];
    QVERIFY(!decrypt(wrongKey, counter, deviceID, ciphertext, sizeof(plaintext) + kDeviceIDSize, tag, decrypted));
}

void CryptoTest::_testReplayGuard()
{
    ReplayGuard guard;
    const DeviceID deviceID = 0x11223344u;

    // 首帧接受
    QVERIFY(guard.accept(deviceID, 100));
    // 严格递增接受
    QVERIFY(guard.accept(deviceID, 101));
    // 重放拒绝（等于 last）
    QVERIFY(!guard.accept(deviceID, 101));
    // 乱序拒绝（小于 last）
    QVERIFY(!guard.accept(deviceID, 50));

    // 不同 deviceID 独立
    const DeviceID otherDevice = 0x55667788u;
    QVERIFY(guard.accept(otherDevice, 1));
    QVERIFY(guard.accept(otherDevice, 2));

    // peekLastNonce
    uint64_t last = 0;
    QVERIFY(guard.peekLastNonce(deviceID, last));
    QCOMPARE(last, static_cast<uint64_t>(101));

    // reset
    guard.reset(deviceID);
    QVERIFY(guard.accept(deviceID, 5));
}

void CryptoTest::_testCodecRoundTrip()
{
    const Key key = testKey();
    const DeviceID gcsDeviceID = 0x0A0B0C0Du; // bit24=0，满足 signature bit 约束
    const uint64_t counter = 3;                // QGC 奇数

    // 标准 HEARTBEAT 帧
    const QByteArray plainFrame = makeHeartbeatFrame(0x0C, 0x0D);
    QVERIFY(plainFrame.size() > static_cast<int>(kV2HeaderLen));

    // 加密
    uint8_t encFrame[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    const uint8_t crcExtra = heartbeatCrcExtra();
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(plainFrame.constData()), plainFrame.size(), crcExtra,
                         gcsDeviceID, counter, key, encFrame, &encLen));

    // 加密帧头 deviceID 校验
    QCOMPARE(deviceIDFromFrame(encFrame), gcsDeviceID);
    QCOMPARE(counterFromFrame(encFrame), counter);
    QCOMPARE(msgidFromFrame(encFrame), static_cast<uint32_t>(MAVLINK_MSG_ID_HEARTBEAT));

    // 解密还原
    uint8_t decryptedFrame[MAVLINK_MAX_PACKET_LEN];
    DeviceID boundDeviceID = 0;
    uint64_t boundCounter = 0;
    int decLen = 0;
    QVERIFY(decryptFrame(encFrame, encLen, crcExtra, key, &boundDeviceID, &boundCounter, decryptedFrame, &decLen));

    QCOMPARE(boundDeviceID, gcsDeviceID);
    QCOMPARE(boundCounter, counter);
    QCOMPARE(decLen, plainFrame.size());
    QCOMPARE(QByteArray(reinterpret_cast<const char*>(decryptedFrame), decLen), plainFrame);
}

void CryptoTest::_testCodecWrongKey()
{
    const Key key = testKey();
    Key wrongKey = testKey();
    wrongKey[31] ^= 0x01;

    const DeviceID gcsDeviceID = 0x0A0B0C0Du;
    const uint64_t counter = 5;
    const uint8_t crcExtra = heartbeatCrcExtra();

    const QByteArray plainFrame = makeHeartbeatFrame(0x0C, 0x0D);

    uint8_t encFrame[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(plainFrame.constData()), plainFrame.size(), crcExtra,
                         gcsDeviceID, counter, key, encFrame, &encLen));

    uint8_t decryptedFrame[MAVLINK_MAX_PACKET_LEN];
    DeviceID boundDeviceID = 0;
    uint64_t boundCounter = 0;
    int decLen = 0;
    QVERIFY(!decryptFrame(encFrame, encLen, crcExtra, wrongKey, &boundDeviceID, &boundCounter, decryptedFrame, &decLen));
}

void CryptoTest::_testReplayGuardTwoPhase()
{
    ReplayGuard guard;
    const DeviceID deviceID = 0x11223344u;

    // 两阶段：判定通过但未 commit → lastNonce 未前进，重复判定仍通过（首帧）
    QVERIFY(guard.isAcceptable(deviceID, 100));
    QVERIFY(guard.isAcceptable(deviceID, 100)); // 未认证帧不得推进重放窗口（C2）

    // 认证通过后 commit
    guard.commit(deviceID, 100);
    QVERIFY(!guard.isAcceptable(deviceID, 100)); // 重放拒绝
    QVERIFY(!guard.isAcceptable(deviceID, 50));  // 乱序拒绝
    QVERIFY(guard.isAcceptable(deviceID, 101));  // 递增通过
    QVERIFY(guard.isAcceptable(deviceID, 101));  // 未 commit 前不推进
    guard.commit(deviceID, 101);
    QVERIFY(!guard.isAcceptable(deviceID, 101));

    // 不同 deviceID 独立
    const DeviceID otherDevice = 0x55667788u;
    QVERIFY(guard.isAcceptable(otherDevice, 1));
    guard.commit(otherDevice, 1);
    QVERIFY(!guard.isAcceptable(otherDevice, 1));
}

void CryptoTest::_testCodecMalformedFrame()
{
    const Key key = testKey();
    const uint8_t crcExtra = heartbeatCrcExtra();
    DeviceID outDev = 0;
    uint64_t outCounter = 0;
    int outLen = 0;
    uint8_t out[MAVLINK_MAX_PACKET_LEN];

    // 畸形帧：头内 len < 28（counter+deviceID+tag 最小块）→ 防 uint16 下溢与越界（C3）
    QByteArray shortFrame = makeHeartbeatFrame(0x0C, 0x0D);
    shortFrame.resize(static_cast<int>(kV2HeaderLen) + 2);
    shortFrame[1] = 10;
    QVERIFY(!decryptFrame(reinterpret_cast<const uint8_t*>(shortFrame.constData()), shortFrame.size(), crcExtra,
                          key, &outDev, &outCounter, out, &outLen));

    // 截断帧：头内 len 声明 100，但输入仅帧头
    QByteArray truncated = makeHeartbeatFrame(0x0C, 0x0D);
    truncated.resize(static_cast<int>(kV2HeaderLen));
    truncated[1] = 100;
    QVERIFY(!decryptFrame(reinterpret_cast<const uint8_t*>(truncated.constData()), truncated.size(), crcExtra,
                          key, &outDev, &outCounter, out, &outLen));

    // encryptFrame 防御：标准帧过短
    QByteArray tinyFrame(5, static_cast<char>(0xFD));
    uint8_t enc[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    QVERIFY(!encryptFrame(reinterpret_cast<const uint8_t*>(tinyFrame.constData()), tinyFrame.size(), crcExtra,
                          0x0A0B0C0Du, 3, key, enc, &encLen));

    // encryptFrame 防御：零长度 payload 拒绝（规范 §2.2）
    QByteArray zeroLen = makeHeartbeatFrame(0x0C, 0x0D);
    zeroLen[1] = 0;
    expectLogMessage("MAVLink.Crypto.CryptoCodec", QtWarningMsg,
                     QRegularExpression(QStringLiteral("zero-length payload")));
    QVERIFY(!encryptFrame(reinterpret_cast<const uint8_t*>(zeroLen.constData()), zeroLen.size(), crcExtra,
                          0x0A0B0C0Du, 3, key, enc, &encLen));
    verifyExpectedLogMessage();

    // encryptFrame 防御：签名位非法的 deviceID 拒绝（规范 §1.4）
    QByteArray plainFrame = makeHeartbeatFrame(0x0C, 0x0D);
    expectLogMessage("MAVLink.Crypto.CryptoCodec", QtWarningMsg,
                     QRegularExpression(QStringLiteral("invalid deviceID")));
    QVERIFY(!encryptFrame(reinterpret_cast<const uint8_t*>(plainFrame.constData()), plainFrame.size(), crcExtra,
                          0x01000000u, 3, key, enc, &encLen));
    verifyExpectedLogMessage();
}

void CryptoTest::_testCodecHeaderTamper()
{
    const Key key = testKey();
    const DeviceID droneID = 0x0A0B0C0Du; // 帧头 deviceID = 目标无人机（C1 语义）
    const uint64_t counter = 3;
    const uint8_t crcExtra = heartbeatCrcExtra();

    const QByteArray plainFrame = makeHeartbeatFrame(0x0C, 0x0D);

    uint8_t encFrame[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(plainFrame.constData()), plainFrame.size(), crcExtra,
                         droneID, counter, key, encFrame, &encLen));

    // 帧头 deviceID 必须等于加密方传入的目标 ID（PX4 按帧头查自己的密钥）
    QCOMPARE(deviceIDFromFrame(encFrame), droneID);

    // 篡改帧头 deviceID 为另一设备：nonce 变化 + 密钥绑定失败 → 拒绝
    uint8_t tampered[MAVLINK_MAX_PACKET_LEN + 32];
    memcpy(tampered, encFrame, static_cast<size_t>(encLen));
    const DeviceID attackerID = 0x0A0B0C0Eu;
    tampered[2] = static_cast<uint8_t>((attackerID >> 24) & 0xFFu);
    tampered[3] = static_cast<uint8_t>((attackerID >> 16) & 0xFFu);
    tampered[5] = static_cast<uint8_t>((attackerID >> 8) & 0xFFu);
    tampered[6] = static_cast<uint8_t>(attackerID & 0xFFu);

    DeviceID outDev = 0;
    uint64_t outCounter = 0;
    int outLen = 0;
    uint8_t out[MAVLINK_MAX_PACKET_LEN];
    QVERIFY(!decryptFrame(tampered, encLen, crcExtra, key, &outDev, &outCounter, out, &outLen));
}

void CryptoTest::_testCodecOverflowDegrade()
{
    const Key key = testKey();
    const DeviceID gcsDeviceID = 0x0A0B0C0Du;
    const uint64_t counter = 7;

    // 构造 payload 253 字节的标准帧（ENCAPSULATED_DATA）：8+4+253+16 = 281 > 255 → 超限
    mavlink_message_t msg{};
    uint8_t data[MAVLINK_MSG_ID_ENCAPSULATED_DATA_LEN];
    memset(data, 0xAB, sizeof(data));
    (void) mavlink_msg_encapsulated_data_pack(0x0C, 0x0D, &msg, 0, data);

    uint8_t plainFrame[MAVLINK_MAX_PACKET_LEN];
    const int plainLen = mavlink_msg_to_send_buffer(plainFrame, &msg);
    const uint8_t crcExtra = mavlink_get_crc_extra(&msg);

    uint8_t encFrame[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    expectLogMessage("MAVLink.Crypto.CryptoCodec", QtWarningMsg,
                     QRegularExpression(QStringLiteral("overflow")));
    QVERIFY(encryptFrame(plainFrame, plainLen, crcExtra, gcsDeviceID, counter, key, encFrame, &encLen));
    verifyExpectedLogMessage();

    // 退化帧：payload block = counter(8) + deviceID(4) + tag(16) = 28
    QCOMPARE(static_cast<int>(encFrame[1]),
             static_cast<int>(kCounterSize + kDeviceIDSize + kTagSize));

    // 解密还原：payload 为空（供接收方按规范 §2.6 第 10 步丢弃）
    DeviceID outDev = 0;
    uint64_t outCounter = 0;
    int outLen = 0;
    uint8_t out[MAVLINK_MAX_PACKET_LEN];
    QVERIFY(decryptFrame(encFrame, encLen, crcExtra, key, &outDev, &outCounter, out, &outLen));
    QCOMPARE(static_cast<int>(out[1]), 0); // 还原帧 payload 长度 = 0
}

void CryptoTest::_testCryptoEmptyPlaintext()
{
    const Key key = testKey();
    const DeviceID deviceID = 0x12345678u;
    const uint64_t counter = 9;

    // 空明文（退化帧支持）：明文仅 deviceID 前缀，密文 = 4 字节
    uint8_t ciphertext[kDeviceIDSize];
    uint8_t tag[kTagSize];
    QVERIFY(encrypt(key, counter, deviceID, nullptr, 0, ciphertext, tag));

    uint8_t decrypted[kDeviceIDSize];
    QVERIFY(decrypt(key, counter, deviceID, ciphertext, kDeviceIDSize, tag, decrypted));

    // 解密输出 = deviceID 前缀
    const DeviceID embedded = (static_cast<DeviceID>(decrypted[0]) << 24) |
                              (static_cast<DeviceID>(decrypted[1]) << 16) |
                              (static_cast<DeviceID>(decrypted[2]) << 8) |
                              static_cast<DeviceID>(decrypted[3]);
    QCOMPARE(embedded, deviceID);
}

void CryptoTest::_testParserAcceptsHighDeviceID()
{
    // deviceID 高字节复用帧头 incompat_flags（bit1~7，规范 §1.4/§1.5）。修复前标准 parser 在
    // GOT_LENGTH 状态把任何 bit1~7 非零的帧当作"未知标志"拒绝，导致 deviceID ≥ 0x01000000 的
    // 链路双向静默全断（doc 11）。此处验证 parser 放行这些帧。
    for (const uint8_t incompat : {uint8_t{0x00}, uint8_t{0x02}, uint8_t{0x12}, uint8_t{0xFE}}) {
        const QByteArray frame = makeFrameWithIncompat(incompat);

        mavlink_message_t message{};
        mavlink_status_t outStatus{};
        const uint8_t framing = parseFrame(frame, message, outStatus);

        QCOMPARE(static_cast<int>(framing), static_cast<int>(MAVLINK_FRAMING_OK));
        QCOMPARE(static_cast<int>(message.incompat_flags), static_cast<int>(incompat));
        // 独立校验序列化正确性，避免「序列化自洽但字段写错」被放行结果掩盖
        QCOMPARE(static_cast<int>(message.sysid), 0x0C);
        QCOMPARE(static_cast<int>(message.compid), 0x0D);
        QCOMPARE(static_cast<uint32_t>(message.msgid), static_cast<uint32_t>(MAVLINK_MSG_ID_HEARTBEAT));
    }
}

void CryptoTest::_testParserSignedFlagPreserved()
{
    // incompat 的 bit0（SIGNED）置位：parser 必须识别为带签名帧并进入 SIGNATURE_WAIT，
    // 而非放行为 OK。补丁只删 bit1~7 的拒绝，不得破坏 bit0 的 SIGNED 判定（规范 §1.4）。
    const QByteArray frame = makeFrameWithIncompat(0x01); // 无签名尾

    mavlink_message_t message{};
    mavlink_status_t outStatus{};
    const uint8_t framing = parseFrame(frame, message, outStatus);

    QVERIFY(framing != MAVLINK_FRAMING_OK); // 签名未验证完，不得判 OK
    QCOMPARE(static_cast<int>(outStatus.parse_state), static_cast<int>(MAVLINK_PARSE_STATE_SIGNATURE_WAIT));
}

void CryptoTest::_testParserRejectsBadCrc()
{
    // incompat 置位 + 坏 CRC：补丁只放开 bit1~7 拒绝，不得旁路完整性校验。
    // 篡改 payload 使 CRC 失配 → 必须判 BAD_CRC。
    QByteArray frame = makeFrameWithIncompat(0xFE);
    const int lastPayloadIdx = frame.size() - 3; // CRC 前最后一个 payload 字节
    frame[lastPayloadIdx] = static_cast<char>(static_cast<uint8_t>(frame.at(lastPayloadIdx)) ^ 0xFFu);

    mavlink_message_t message{};
    mavlink_status_t outStatus{};
    const uint8_t framing = parseFrame(frame, message, outStatus);

    QCOMPARE(static_cast<int>(framing), static_cast<int>(MAVLINK_FRAMING_BAD_CRC));
}

void CryptoTest::_testRandomOddCounter()
{
    // 建链首帧 counter 必须是 62 位奇数（规范 §2.5）：最低位置 1、且 < 2^62，
    // 留出 +2 递增余量，避免重启后从 1 重来导致同一密钥下 nonce 复用。
    for (int i = 0; i < 32; ++i) {
        const uint64_t counter = CryptoController::randomOddCounter();
        QVERIFY((counter & 1u) != 0u);
        QVERIFY(counter < (1ull << 62));
    }
}

void CryptoTest::_testNextOutgoingCounter()
{
    // nextOutgoingCounter 端到端：首帧随机 62 位奇数、后续严格 +2、非 Active 态拒绝。
    CryptoController* const crypto = CryptoController::instance();
    const DeviceID deviceID = 0x0A0B0C0Du; // bit24=0，满足签名位约束（规范 §1.4）

    // 复位单例（Q_APPLICATION_STATIC 跨测试共享，需清历史状态）
    crypto->returnToStandby();
    crypto->resetReplay(deviceID);

    // 缓存密钥后建链 → 同步进入 Active
    crypto->deviceKeyManager()->cacheKey(deviceID, testKey());
    crypto->beginLinking(deviceID);
    QCOMPARE(crypto->state(), CryptoController::State::Active);

    // 非 Active 态拒绝
    crypto->returnToStandby();
    uint64_t rejected = 0;
    QVERIFY(!crypto->nextOutgoingCounter(rejected));
    crypto->beginLinking(deviceID);
    QCOMPARE(crypto->state(), CryptoController::State::Active);

    // 首帧：随机 62 位奇数，不再恒为 1（P(c1==1)=2^-61，实践上不会 flaky）
    uint64_t c1 = 0;
    QVERIFY(crypto->nextOutgoingCounter(c1));
    QVERIFY((c1 & 1u) != 0u);
    QVERIFY(c1 < (1ull << 62));
    QVERIFY(c1 != 1);

    // 后续帧：严格 +2（对端依赖的确定性契约）
    uint64_t c2 = 0;
    QVERIFY(crypto->nextOutgoingCounter(c2));
    QCOMPARE(c2, c1 + 2);

    // 清理（单例 + 全局 lastNonce + key cache 均持久，避免污染同进程其他测试）
    crypto->returnToStandby();
    crypto->deviceKeyManager()->removeKey(deviceID);
    crypto->resetReplay(deviceID);
}

void CryptoTest::_testVtolMessages()
{
    // 1) CRC_EXTRA：必须与 pymavlink message_checksum 一致（算法已用 HEARTBEAT=50 校验）。
    //    旧值为占位 255/254/255/63，会导致加密帧 CRC 与接收端不符。
    uint8_t crc = 0;
    QVERIFY(mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_WEATHER_FORECAST, &crc));
    QCOMPARE(crc, static_cast<uint8_t>(152));
    QVERIFY(mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_ALTERNATE_LANDING, &crc));
    QCOMPARE(crc, static_cast<uint8_t>(84));
    QVERIFY(mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_SENSOR_CTRL, &crc));
    QCOMPARE(crc, static_cast<uint8_t>(78));
    QVERIFY(mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_VIDEO_CTRL, &crc));
    QCOMPARE(crc, static_cast<uint8_t>(22));
    // 非 VTOL 消息 → 返回 false（调用方回退 mavlink_get_crc_extra）
    QVERIFY(!mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_HEARTBEAT, &crc));

    // 2) 字段排序：MAVLink 要求类型大小降序（pymavlink 强制），offsetof 反映 wire 布局。
    //    旧 struct 把 uint8 组排在 uint16 组之前，导致与接收端逐字节错位。
    QCOMPARE(offsetof(mavlink_weather_forecast_t, wind_speed), size_t(20));
    QCOMPARE(offsetof(mavlink_weather_forecast_t, weather_type), size_t(30));
    QCOMPARE(offsetof(mavlink_alternate_landing_t, distance_from_current), size_t(12));
    QCOMPARE(offsetof(mavlink_alternate_landing_t, runway_length), size_t(16));
    QCOMPARE(offsetof(mavlink_alternate_landing_t, site_id), size_t(20));
    QCOMPARE(offsetof(mavlink_alternate_landing_t, site_type), size_t(36));
    QCOMPARE(offsetof(mavlink_video_ctrl_t, resolution_w), size_t(0));
    QCOMPARE(offsetof(mavlink_video_ctrl_t, target_system), size_t(6));
    QCOMPARE(offsetof(mavlink_video_ctrl_t, codec), size_t(11));

    // 3) pack → decode 往返（字段映射一致性）。
    mavlink_message_t msg{};

    mavlink_msg_weather_forecast_pack(0x01, 0x02, &msg, 10000000, 20000000, 30000, 111, 222, 3, 2, 80, 1500, 27000, 250,
                                      1200, 5000, "sunny");
    mavlink_weather_forecast_t wf{};
    mavlink_msg_weather_forecast_decode(&msg, &wf);
    QCOMPARE(wf.latitude, static_cast<int32_t>(10000000));
    QCOMPARE(wf.longitude, static_cast<int32_t>(20000000));
    QCOMPARE(wf.altitude, static_cast<int32_t>(30000));
    QCOMPARE(wf.valid_from, static_cast<uint32_t>(111));
    QCOMPARE(wf.valid_to, static_cast<uint32_t>(222));
    QCOMPARE(wf.weather_type, static_cast<uint8_t>(3));
    QCOMPARE(wf.severity, static_cast<uint8_t>(2));
    QCOMPARE(wf.confidence, static_cast<uint8_t>(80));
    QCOMPARE(wf.wind_speed, static_cast<uint16_t>(1500));
    QCOMPARE(wf.wind_direction, static_cast<uint16_t>(27000));
    QCOMPARE(wf.temperature, static_cast<int16_t>(250));
    QCOMPARE(wf.rainfall, static_cast<uint16_t>(1200));
    QCOMPARE(wf.visibility, static_cast<uint16_t>(5000));
    QCOMPARE(QByteArray(wf.description, 5), QByteArray("sunny"));

    mavlink_msg_alternate_landing_pack(0x01, 0x02, &msg, "SITE01", 10000000, 20000000, 30000, 1, 2, 500, 9000, 3, 7500,
                                       "field");
    mavlink_alternate_landing_t al{};
    mavlink_msg_alternate_landing_decode(&msg, &al);
    QCOMPARE(al.latitude, static_cast<int32_t>(10000000));
    QCOMPARE(al.longitude, static_cast<int32_t>(20000000));
    QCOMPARE(al.altitude, static_cast<int32_t>(30000));
    QCOMPARE(al.site_type, static_cast<uint8_t>(1));
    QCOMPARE(al.priority, static_cast<uint8_t>(2));
    QCOMPARE(al.runway_length, static_cast<uint16_t>(500));
    QCOMPARE(al.runway_heading, static_cast<uint16_t>(9000));
    QCOMPARE(al.surface_condition, static_cast<uint8_t>(3));
    QCOMPARE(al.distance_from_current, static_cast<uint32_t>(7500));
    QCOMPARE(QByteArray(al.site_id, 6), QByteArray("SITE01"));
    QCOMPARE(QByteArray(al.description, 5), QByteArray("field"));

    mavlink_msg_sensor_ctrl_pack(0x01, 0x02, &msg, 10, 20, 3, 1);
    mavlink_sensor_ctrl_t sc{};
    mavlink_msg_sensor_ctrl_decode(&msg, &sc);
    QCOMPARE(sc.target_system, static_cast<uint8_t>(10));
    QCOMPARE(sc.target_component, static_cast<uint8_t>(20));
    QCOMPARE(sc.sensor_id, static_cast<uint8_t>(3));
    QCOMPARE(sc.command, static_cast<uint8_t>(1));

    mavlink_msg_video_ctrl_pack(0x01, 0x02, &msg, 10, 20, 5, 1, 1920, 1080, 30, 4000, "h264");
    mavlink_video_ctrl_t vc{};
    mavlink_msg_video_ctrl_decode(&msg, &vc);
    QCOMPARE(vc.target_system, static_cast<uint8_t>(10));
    QCOMPARE(vc.target_component, static_cast<uint8_t>(20));
    QCOMPARE(vc.camera_id, static_cast<uint8_t>(5));
    QCOMPARE(vc.command, static_cast<uint8_t>(1));
    QCOMPARE(vc.resolution_w, static_cast<uint16_t>(1920));
    QCOMPARE(vc.resolution_h, static_cast<uint16_t>(1080));
    QCOMPARE(vc.framerate, static_cast<uint8_t>(30));
    QCOMPARE(vc.bitrate_kbps, static_cast<uint16_t>(4000));
    QCOMPARE(QByteArray(vc.codec, 4), QByteArray("h264"));
}

void CryptoTest::_testQgcRegistration()
{
    // CRC_EXTRA 助手：80005 应命中 138
    uint8_t crc = 0;
    QVERIFY(mavlink_msg_vtol_crc_extra(MAVLINK_MSG_ID_QGC_REGISTRATION, &crc));
    QCOMPARE(crc, static_cast<uint8_t>(138));

    // pack：帧头 deviceID 拆分（10000 → sysid=39, compid=16），变长 len，CRC 与序列化一致
    mavlink_message_t msg{};
    // 1 个 deviceID = 0x00410C31（大端表示最低字节非 0，不会被裁剪——测试精确 len）
    const uint8_t deviceBytes[4] = { 0x00, 0x41, 0x0C, 0x31 };
    const uint16_t len = mavlink_msg_qgc_registration_pack(QGC_REGISTRATION_DEVICE_ID_DEFAULT, &msg,
                                                           deviceBytes, 1);
    QVERIFY(len != 0);

    // 帧头 deviceID = 10000 = 0x00002710 → sysid=0x27(39), compid=0x10(16)
    QCOMPARE(msg.sysid, static_cast<uint8_t>(39));
    QCOMPARE(msg.compid, static_cast<uint8_t>(16));
    QCOMPARE(msg.incompat_flags, static_cast<uint8_t>(0));
    QCOMPARE(msg.compat_flags, static_cast<uint8_t>(0));
    QCOMPARE(msg.msgid, static_cast<uint32_t>(80005));

    // 变长 len = 1 + 1×4 = 5（deviceID 最低字节 0x31 非 0，不裁剪）
    QCOMPARE(msg.len, static_cast<uint8_t>(5));
    // payload[0] = deviceID_num
    QCOMPARE(_MAV_PAYLOAD(&msg)[0], static_cast<uint8_t>(1));
    // checksum：用 pymavlink x25crc 数学验证（帧头 9 字节 + payload + crc_extra=138）
    QCOMPARE(msg.checksum, static_cast<uint16_t>(0xF55D));

    // 序列化：确认帧字节布局正确（len 精确、帧头 deviceID 拆分正确、CRC 与 len 一致）
    uint8_t buf[MAVLINK_MAX_PACKET_LEN];
    const int bufLen = mavlink_msg_to_send_buffer(buf, &msg);
    QVERIFY(bufLen > 0);

    // 帧头：magic=0xFD, len=5, incompat=0, compat=0, seq=0, sysid=39, compid=16
    QCOMPARE(buf[0], static_cast<uint8_t>(0xFD));
    QCOMPARE(buf[1], static_cast<uint8_t>(5));
    QCOMPARE(buf[2], static_cast<uint8_t>(0));
    QCOMPARE(buf[3], static_cast<uint8_t>(0));
    QCOMPARE(buf[5], static_cast<uint8_t>(39));
    QCOMPARE(buf[6], static_cast<uint8_t>(16));

    // C1 裁剪场景：deviceID 最低字节为 0（0x27100000）→ 尾部零被裁，len=3，
    // pack 必须按裁剪后 len 算 CRC（否则线上 CRC 与接收端不一致）。
    const uint8_t zeroLowBytes[4] = { 0x27, 0x10, 0x00, 0x00 };
    mavlink_message_t msg2{};
    const uint16_t len2 = mavlink_msg_qgc_registration_pack(QGC_REGISTRATION_DEVICE_ID_DEFAULT, &msg2, zeroLowBytes, 1);
    QVERIFY(len2 != 0);
    QCOMPARE(msg2.len, static_cast<uint8_t>(3));          // 1 + 4 - 2（尾部两个 0 被裁）
    QCOMPARE(msg2.checksum, static_cast<uint16_t>(0xCD74)); // 按 len=3 算的完整 CRC
}

void CryptoTest::_testInjectLocalKey()
{
    // 用 QTemporaryFile（自动带 PID/随机后缀，避免并行测试冲突）写 32 字节测试密钥，
    // 验证 injectLocalKeyFromFile 的成功与失败路径。
    CryptoController* const crypto = CryptoController::instance();

    // --- 成功路径：32 字节文件 → 注入 → 命中 ---
    QTemporaryFile file(QStringLiteral("qgc_test_mavlink_key_XXXXXX.bin"));
    QVERIFY(file.open());
    const Key testK = testKey();
    QCOMPARE(file.write(reinterpret_cast<const char*>(testK.data()), static_cast<qint64>(testK.size())),
             static_cast<qint64>(testK.size()));
    file.close();

    QVERIFY(crypto->injectLocalKeyFromFile(file.fileName(), 1));
    Key outKey{};
    QVERIFY(crypto->deviceKeyManager()->keyForDevice(1, outKey));
    QVERIFY(outKey == testK);
    crypto->deviceKeyManager()->removeKey(1);

    // --- 失败路径 1：长度错误（31 字节）---
    QTemporaryFile shortFile(QStringLiteral("qgc_test_mavlink_key_short_XXXXXX.bin"));
    QVERIFY(shortFile.open());
    QCOMPARE(shortFile.write(reinterpret_cast<const char*>(testK.data()), static_cast<qint64>(testK.size() - 1)),
             static_cast<qint64>(testK.size() - 1));
    shortFile.close();
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression(QStringLiteral("key file size")));
    QVERIFY(!crypto->injectLocalKeyFromFile(shortFile.fileName(), 1));
    verifyExpectedLogMessage();
    QVERIFY(!crypto->deviceKeyManager()->hasKey(1));

    // --- 失败路径 2：非法 deviceID（0 与 bit24 置位）---
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression(QStringLiteral("invalid deviceID 0")));
    QVERIFY(!crypto->injectLocalKeyFromFile(file.fileName(), 0));
    verifyExpectedLogMessage();
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression(QStringLiteral("invalid deviceID 16777216")));
    QVERIFY(!crypto->injectLocalKeyFromFile(file.fileName(), 0x01000000u));
    verifyExpectedLogMessage();

    // --- 失败路径 3：文件不存在 ---
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression(QStringLiteral("cannot open")));
    QVERIFY(!crypto->injectLocalKeyFromFile(QStringLiteral("/nonexistent/mavlink_key.bin"), 1));
    verifyExpectedLogMessage();

    // QTemporaryFile 析构自动清理
}

void CryptoTest::_testCryptoLinkLogger()
{
    if (!MAVLinkCrypto::CryptoLinkLogger::enabled()) {
        QSKIP("QGC_CRYPTO_LINK_LOG not enabled (联调构建开启后此用例生效)");
        return;
    }
    // 80005 明文登记心跳帧：帧头 deviceID=10000（GCS 段），payload=2 个 PX4 deviceID（10000001/10000002）
    const uint8_t regFrame[] = {
        0xFD, 0x09, 0x00, 0x00, 0x00, 0x27, 0x10, 0x89, 0x38, 0x01, // header：len=9 deviceID=10000 msgid=80005
        0x02, 0x00, 0x98, 0x96, 0x81, 0x00, 0x98, 0x96, 0x82,         // payload：num=2, deviceID 集合
        0x00, 0x00,                                                  // crc
    };
    // 加密帧：deviceID=66051(0x00010203)，counter=123，msgid=33，payload=28（8 counter + 20 密文/tag）
    const uint8_t encFrame[] = {
        0xFD, 0x1C, 0x00, 0x01, 0x00, 0x02, 0x03, 0x21, 0x00, 0x00, // len=28 deviceID=66051 msgid=33
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7B,              // counter=123（8B 大端）
        0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,  // 密文(4)+tag(16)
        0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x00, 0x00,                                                  // crc
    };

    // 帧头 deviceID 重组 + 80005 payload 解析
    QCOMPARE(MAVLinkCrypto::CryptoLinkLogger::deviceIDFromFrameBytes(
                 reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame))),
             10000u);
    QCOMPARE(MAVLinkCrypto::CryptoLinkLogger::parseRegistrationPayload(
                 reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame))),
             QStringLiteral("10000001,10000002"));

    // 记录发出（QGC）80005 + 收到（PX4）加密帧
    MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
        80005, 10000, false, reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame)), true);
    MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
        33, 66051, true, reinterpret_cast<const char*>(encFrame), static_cast<int>(sizeof(encFrame)), true);

    // 读日志文件，断言最后两行格式与内容（logger 单例序号持续递增，不校验具体序号值）
    QFile f(QStringLiteral("/tmp/qgc_crypto_link.log"));
    QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
    const QList<QByteArray> lines = f.readAll().split('\n');
    f.close();
    QVERIFY2(lines.size() >= 3, "日志文件应有至少两条记录");
    const QString lineReg  = QString::fromUtf8(lines[lines.size() - 3]);
    const QString lineEnc  = QString::fromUtf8(lines[lines.size() - 2]);
    // 80005：... QGC A 80005 10000 M S QGC登记心跳 9 10000001,10000002
    QVERIFY2(lineReg.contains(QStringLiteral("QGC")) && lineReg.contains(QStringLiteral("80005")) &&
                 lineReg.contains(QStringLiteral("10000001,10000002")),
             qPrintable(QStringLiteral("80005 行格式异常: %1").arg(lineReg)));
    // 加密帧：... PX4 A 33 66051 C S 位置遥测 28 counter=123,密文
    QVERIFY2(lineEnc.contains(QStringLiteral("PX4")) && lineEnc.contains(QStringLiteral("66051")) &&
                 lineEnc.contains(QStringLiteral("counter=123")),
             qPrintable(QStringLiteral("加密帧行格式异常: %1").arg(lineEnc)));
}

UT_REGISTER_TEST_LIGHTWEIGHT(CryptoTest, TestLabel::Unit)
