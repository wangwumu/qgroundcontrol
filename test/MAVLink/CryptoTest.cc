#include "CryptoTest.h"

#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/CryptoHeartbeatExt.h"
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

/// 构造 EXT 55B（小端序，协议 60824.0 §4）。前 37B 为 60822.0 基段，尾部 9 字段为
/// 60824.0 新增；新字段参数默认哨兵（供"仅解析基段"兼容用例复用）。
QByteArray makeExtBytes(int32_t lat, int32_t lon, int32_t alt, int16_t vx, int16_t vy, int16_t vz,
                        uint8_t fix, uint8_t sat, uint16_t volt, int8_t rem, uint8_t nav, uint8_t arm,
                        uint32_t bootMs = 0, int32_t relAlt = HeartbeatExt::kInvalidInt32,
                        int16_t airspeed = HeartbeatExt::kInvalidInt16, uint8_t airsrc = HeartbeatExt::kAirspeedSourceDisabled,
                        uint8_t vtol = 0, uint8_t land = 0,
                        int16_t curr = HeartbeatExt::kInvalidInt16, int16_t temp = HeartbeatExt::kInvalidInt16,
                        uint8_t fail = 0)
{
    QByteArray b(HeartbeatExt::kExtSize, 0);
    const auto putI32 = [&b](int off, int32_t v) {
        b[off] = static_cast<char>(v & 0xFF);
        b[off + 1] = static_cast<char>((v >> 8) & 0xFF);
        b[off + 2] = static_cast<char>((v >> 16) & 0xFF);
        b[off + 3] = static_cast<char>((v >> 24) & 0xFF);
    };
    const auto putU32 = [&b](int off, uint32_t v) {
        b[off] = static_cast<char>(v & 0xFF);
        b[off + 1] = static_cast<char>((v >> 8) & 0xFF);
        b[off + 2] = static_cast<char>((v >> 16) & 0xFF);
        b[off + 3] = static_cast<char>((v >> 24) & 0xFF);
    };
    const auto putI16 = [&b](int off, int16_t v) {
        b[off] = static_cast<char>(v & 0xFF);
        b[off + 1] = static_cast<char>((v >> 8) & 0xFF);
    };
    const auto putF32 = [&putI32](int off, float v) {
        uint32_t u = 0;
        std::memcpy(&u, &v, sizeof(u));
        putI32(off, static_cast<int32_t>(u));
    };
    putI32(0, lat);
    putI32(4, lon);
    putI32(8, alt);
    putI16(12, vx);
    putI16(14, vy);
    putI16(16, vz);
    putF32(18, 0.1f);
    putF32(22, -0.2f);
    putF32(26, 0.3f);
    b[30] = static_cast<char>(fix);
    b[31] = static_cast<char>(sat);
    putI16(32, static_cast<int16_t>(volt));
    b[34] = static_cast<char>(rem);
    b[35] = static_cast<char>(nav);
    b[36] = static_cast<char>(arm);
    // 60824.0 新增字段（offset 37-54）
    putU32(37, bootMs);
    putI32(41, relAlt);
    putI16(45, airspeed);
    b[47] = static_cast<char>(airsrc);
    b[48] = static_cast<char>(vtol);
    b[49] = static_cast<char>(land);
    putI16(50, curr);
    putI16(52, temp);
    b[54] = static_cast<char>(fail);
    return b;
}

/// 组装加密心跳标准帧：header(10) + 给定 payload（HEARTBEAT 9B + EXT）+ CRC。
QByteArray makeHeartbeatExtFrameFromPayload(const QByteArray& payload)
{
    QByteArray frame;
    frame.append(static_cast<char>(0xFD));                 // magic
    frame.append(static_cast<char>(payload.size()));       // len
    frame.append(static_cast<char>(0));                    // incompat_flags
    frame.append(static_cast<char>(0));                    // compat_flags
    frame.append(static_cast<char>(0));                    // seq
    frame.append(static_cast<char>(0x0C));                 // sysid
    frame.append(static_cast<char>(0x0D));                 // compid
    frame.append(static_cast<char>(0));                    // msgid=0 (HEARTBEAT)
    frame.append(static_cast<char>(0));
    frame.append(static_cast<char>(0));
    frame.append(payload);
    // CRC：从 len 字段起覆盖 header 余部 + payload + crc_extra（与 makeFrameWithIncompat 一致）
    uint16_t crc = 0;
    crc_init(&crc);
    for (int i = 1; i < frame.size(); ++i) {
        crc_accumulate(static_cast<uint8_t>(frame.at(i)), &crc);
    }
    crc_accumulate(heartbeatCrcExtra(), &crc);
    frame.append(static_cast<char>(crc & 0xFF));
    frame.append(static_cast<char>(crc >> 8));
    return frame;
}

/// 组装加密心跳标准帧：HEARTBEAT payload(9B) + EXT(55B)，len=64。
QByteArray makeExtFrame(int32_t lat, int32_t lon, int32_t alt, int16_t vx, int16_t vy, int16_t vz,
                        uint8_t fix, uint8_t sat, uint16_t volt, int8_t rem, uint8_t nav, uint8_t arm,
                        uint32_t bootMs = 0, int32_t relAlt = HeartbeatExt::kInvalidInt32,
                        int16_t airspeed = HeartbeatExt::kInvalidInt16, uint8_t airsrc = HeartbeatExt::kAirspeedSourceDisabled,
                        uint8_t vtol = 0, uint8_t land = 0,
                        int16_t curr = HeartbeatExt::kInvalidInt16, int16_t temp = HeartbeatExt::kInvalidInt16,
                        uint8_t fail = 0)
{
    const QByteArray hbPayload = makeHeartbeatFrame(0x0C, 0x0D).mid(10, 9); // 标准 HEARTBEAT payload
    // 9B HEARTBEAT + 55B EXT = 64
    const QByteArray payload = hbPayload
        + makeExtBytes(lat, lon, alt, vx, vy, vz, fix, sat, volt, rem, nav, arm,
                       bootMs, relAlt, airspeed, airsrc, vtol, land, curr, temp, fail);
    return makeHeartbeatExtFrameFromPayload(payload);
}

/// 对给定加密心跳标准帧做 encrypt→decrypt，返回解密后的标准帧与解析出的 EXT。
/// 便捷封装：供往返与注入层测试复用。
struct ExtRoundTrip {
    QByteArray encFrame;         // 加密帧（不含 CRC 读取用；原始完整）
    QByteArray decFrame;         // 解密后的标准帧（len=46）
    HeartbeatExt ext;            // 解析出的 EXT
    DeviceID boundDeviceID = 0;
    uint64_t boundCounter = 0;
};
ExtRoundTrip roundTripExt(const QByteArray& extFrame, const Key& key, DeviceID deviceID, uint64_t counter)
{
    ExtRoundTrip rt;
    const uint8_t crcExtra = heartbeatCrcExtra();
    uint8_t enc[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    if (!encryptFrame(reinterpret_cast<const uint8_t*>(extFrame.constData()), extFrame.size(), crcExtra,
                      deviceID, counter, key, enc, &encLen)) {
        return rt;
    }
    rt.encFrame = QByteArray(reinterpret_cast<const char*>(enc), encLen);
    uint8_t plain[MAVLINK_MAX_PACKET_LEN];
    int plainLen = 0;
    if (!decryptFrame(enc, encLen, crcExtra, key, &rt.boundDeviceID, &rt.boundCounter, plain, &plainLen)) {
        return rt;
    }
    rt.decFrame = QByteArray(reinterpret_cast<const char*>(plain), plainLen);
    (void) parseHeartbeatExtFromFrame(0, plain, plainLen, &rt.ext);
    return rt;
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

void CryptoTest::_testReplayGuardUpDownSeparation()
{
    ReplayGuard guard;
    const DeviceID deviceID = 0x11223344u;

    // 上行 accept 登记（发送侧，奇数序列）
    QVERIFY(guard.accept(deviceID, 101));

    // 下行独立窗口：首帧 unset 通过，commit 一个更大的偶数（接收侧）
    QVERIFY(guard.isAcceptable(deviceID, 1000));
    guard.commit(deviceID, 1000);

    // 核心不变量：下行 commit(1000) 不得污染上行——上行仍按 101→103→105 递增
    // （若共用单 map：103 > 1000 为假 → 本断言失败，即回归被捕获）
    QVERIFY(guard.accept(deviceID, 103));
    QVERIFY(!guard.accept(deviceID, 101)); // 上行重放仍拒绝
    QVERIFY(guard.accept(deviceID, 105));

    // peekLastNonce 只读上行窗口（发送侧）
    uint64_t last = 0;
    QVERIFY(guard.peekLastNonce(deviceID, last));
    QCOMPARE(last, static_cast<uint64_t>(105)); // 若共用：读到 1000 → 失败

    // 反向：上行 accept 不得污染下行——下行重放仍拒绝、严格递增
    QVERIFY(!guard.isAcceptable(deviceID, 1000));
    QVERIFY(guard.isAcceptable(deviceID, 1001));
    guard.commit(deviceID, 1001);

    // reset 同时清 up 与 down
    guard.reset(deviceID);
    QVERIFY(guard.accept(deviceID, 1));
    QVERIFY(guard.isAcceptable(deviceID, 1));

    // clear 同时清 up 与 down（此前 clear 无任何测试）
    guard.accept(deviceID, 10);
    guard.commit(deviceID, 20);
    guard.clear();
    QVERIFY(guard.accept(deviceID, 5));
    QVERIFY(guard.isAcceptable(deviceID, 5));
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
    // 80005 明文登记心跳帧：帧头 deviceID=10000（GCS 段），payload=2 个 PX4 deviceID（10000001/10000002）
    const uint8_t regFrame[] = {
        0xFD, 0x09, 0x00, 0x00, 0x00, 0x27, 0x10, 0x85, 0x38, 0x01, // header：len=9 deviceID=10000 msgid=80005(0x13885)
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
    // 解密后的明文 GLOBAL_POSITION_INT 帧（msgid=33，类型降序布局）：lat=31.2345678 lon=121.4567890 alt=50m
    // lat=312345678=0x129e044e 小端 4E 04 9E 12；lon=1214567890=0x4864d5d2 小端 D2 D5 64 48
    const uint8_t plainPos[] = {
        0xFD, 0x1C, 0x00, 0x00, 0x00, 0x98, 0x81, 0x21, 0x00, 0x00, // len=28 msgid=33
        0x00, 0x00, 0x00, 0x00, 0x4E, 0x04, 0x9E, 0x12, 0xD2, 0xD5, // time_boot_ms=0, lat=312345678, lon=1214567890
        0x64, 0x48, 0x50, 0xC3, 0x00, 0x00, 0x40, 0x9C, 0x00, 0x00, // alt=50000, relative_alt=40000
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // vx,vy,vz,hdg=0
        0x00, 0x00,                                                  // crc
    };

    // 纯解析逻辑无条件可测（宏关闭时解析函数仍编译，见 CryptoLinkLogger.cc）
    QCOMPARE(MAVLinkCrypto::CryptoLinkLogger::deviceIDFromFrameBytes(
                 reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame))),
             10000u);
    QCOMPARE(MAVLinkCrypto::CryptoLinkLogger::parseRegistrationPayload(
                 reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame))),
             QStringLiteral("10000001,10000002"));

    // 文件写入验证需 enabled()（宏 OFF 或 /tmp 打开失败则跳过）
    if (!MAVLinkCrypto::CryptoLinkLogger::enabled()) {
        QSKIP("文件日志未启用（QGC_CRYPTO_LINK_LOG OFF 或 /tmp 打开失败），跳过文件写入断言");
        return;
    }

    // 记录发出（QGC）80005 + 收到（PX4）加密帧（明文=解密后的 GLOBAL_POSITION_INT，验证密文解开成可读字段）
    MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
        80005, 10000, false, reinterpret_cast<const char*>(regFrame), static_cast<int>(sizeof(regFrame)),
        nullptr, 0, true);
    MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
        33, 66051, true, reinterpret_cast<const char*>(encFrame), static_cast<int>(sizeof(encFrame)),
        reinterpret_cast<const char*>(plainPos), static_cast<int>(sizeof(plainPos)), true);

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
    // 加密帧：... PX4 A 33 66051 C S 位置遥测 28 counter=123 lat=31.2345678,lon=121.4567890,alt=50.0m
    QVERIFY2(lineEnc.contains(QStringLiteral("PX4")) && lineEnc.contains(QStringLiteral("66051")) &&
                 lineEnc.contains(QStringLiteral("counter=123")) &&
                 lineEnc.contains(QStringLiteral("lat=31.2345678")) &&
                 lineEnc.contains(QStringLiteral("lon=121.4567890")),
             qPrintable(QStringLiteral("加密帧行格式异常: %1").arg(lineEnc)));
}

void CryptoTest::_testHeartbeatExt()
{
    using namespace MAVLinkCrypto;

    // --- 往返：加密（block=92）→ 解密 → 解析 EXT(55B) ---
    // （makeExtBytes/makeExtFrame 为文件级辅助，供本方法与注入层测试复用）
    const Key key = testKey();
    const DeviceID deviceID = 66051u; // 0x00010203，PX4 段
    const uint64_t counter = 1000;    // 下行偶数
    const uint8_t crcExtra = heartbeatCrcExtra();

    // 12 个基段参数 + 9 个 60824.0 新增字段参数（bootMs, relAlt, airspeed, airsrc, vtol, land, curr, temp, fail）
    const QByteArray extFrame = makeExtFrame(312345678, 1214567890, 50000, 100, 200, -50, 3, 12, 11100, 85, 6, 1,
                                             12345, 4321, 5678, 1, 4, 3, -5, 20, 0x03);
    uint8_t encBuffer[MAVLINK_MAX_PACKET_LEN + 32];
    int encLen = 0;
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(extFrame.constData()), extFrame.size(), crcExtra,
                         deviceID, counter, key, encBuffer, &encLen));
    // block = counter(8) + ciphertext(4+9+55=68) + tag(16) = 92
    QCOMPARE(encBuffer[1], static_cast<uint8_t>(92));
    QCOMPARE(counterFromFrame(encBuffer), counter);

    uint8_t plainOut[MAVLINK_MAX_PACKET_LEN];
    DeviceID boundDev = 0;
    uint64_t boundCounter = 0;
    int plainOutLen = 0;
    QVERIFY(decryptFrame(encBuffer, encLen, crcExtra, key, &boundDev, &boundCounter, plainOut, &plainOutLen));
    QCOMPARE(boundDev, deviceID);
    QCOMPARE(plainOut[1], static_cast<uint8_t>(64)); // HEARTBEAT(9) + EXT(55)
    QCOMPARE(plainOutLen, extFrame.size());

    HeartbeatExt ext;
    QVERIFY(parseHeartbeatExtFromFrame(0, plainOut, plainOutLen, &ext));
    QCOMPARE(ext.lat, static_cast<int32_t>(312345678));
    QCOMPARE(ext.lon, static_cast<int32_t>(1214567890));
    QCOMPARE(ext.alt, static_cast<int32_t>(50000));
    QCOMPARE(ext.vx, static_cast<int16_t>(100));
    QCOMPARE(ext.vy, static_cast<int16_t>(200));
    QCOMPARE(ext.vz, static_cast<int16_t>(-50));
    QCOMPARE(ext.roll, 0.1f);
    QCOMPARE(ext.pitch, -0.2f);
    QCOMPARE(ext.yaw, 0.3f);
    QCOMPARE(ext.fixType, static_cast<uint8_t>(3));
    QCOMPARE(ext.satellitesUsed, static_cast<uint8_t>(12));
    QCOMPARE(ext.voltage, static_cast<uint16_t>(11100));
    QCOMPARE(ext.remaining, static_cast<int8_t>(85));
    QCOMPARE(ext.navState, static_cast<uint8_t>(6));
    QCOMPARE(ext.armingState, static_cast<uint8_t>(1));
    QVERIFY(ext.hasPosition());
    QVERIFY(ext.hasAltitude());
    QVERIFY(ext.hasVelocity());
    QVERIFY(ext.hasBattery());
    // 60824.0 新增字段
    QCOMPARE(ext.timeBootMs, static_cast<uint32_t>(12345));
    QCOMPARE(ext.relAlt, static_cast<int32_t>(4321));
    QCOMPARE(ext.airspeed, static_cast<int16_t>(5678));
    QCOMPARE(ext.airspeedSource, static_cast<uint8_t>(1));
    QCOMPARE(ext.vtolState, static_cast<uint8_t>(4));
    QCOMPARE(ext.landed, static_cast<uint8_t>(3));
    QCOMPARE(ext.current, static_cast<int16_t>(-5));
    QCOMPARE(ext.temperature, static_cast<int16_t>(20));
    QCOMPARE(ext.failsafe, static_cast<uint8_t>(0x03));
    QVERIFY(ext.hasRelativeAltitude());
    QVERIFY(ext.hasCurrent());

    // --- 哨兵：无效位置/速度/电池须被识别（不得当作 0 坐标 / 0V 真实数据） ---
    const QByteArray sentinelFrame = makeExtFrame(HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32,
                                                  HeartbeatExt::kInvalidInt32,
                                                  HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16,
                                                  HeartbeatExt::kInvalidInt16, 0, 0, 0, -1, 0, 0);
    uint8_t enc2[MAVLINK_MAX_PACKET_LEN + 32];
    int enc2Len = 0;
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(sentinelFrame.constData()), sentinelFrame.size(), crcExtra,
                         deviceID, counter + 2, key, enc2, &enc2Len));
    uint8_t plain2[MAVLINK_MAX_PACKET_LEN];
    DeviceID dev2 = 0;
    uint64_t cnt2 = 0;
    int plain2Len = 0;
    QVERIFY(decryptFrame(enc2, enc2Len, crcExtra, key, &dev2, &cnt2, plain2, &plain2Len));
    HeartbeatExt sentinel;
    QVERIFY(parseHeartbeatExtFromFrame(0, plain2, plain2Len, &sentinel));
    QVERIFY(!sentinel.hasPosition());
    QVERIFY(!sentinel.hasAltitude());
    QVERIFY(!sentinel.hasVelocity());
    QVERIFY(!sentinel.hasBattery());

    // 部分有效：lat/lon 有效但 vx 哨兵、电池 remaining=-1 但 voltage>0 → 位置/电池仍有效
    const QByteArray partialFrame = makeExtFrame(312345678, 1214567890, 50000,
                                                 HeartbeatExt::kInvalidInt16, 200, -50, 3, 12, 11100, -1, 6, 1);
    uint8_t enc3[MAVLINK_MAX_PACKET_LEN + 32];
    int enc3Len = 0;
    QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(partialFrame.constData()), partialFrame.size(), crcExtra,
                         deviceID, counter + 4, key, enc3, &enc3Len));
    uint8_t plain3[MAVLINK_MAX_PACKET_LEN];
    DeviceID dev3 = 0;
    uint64_t cnt3 = 0;
    int plain3Len = 0;
    QVERIFY(decryptFrame(enc3, enc3Len, crcExtra, key, &dev3, &cnt3, plain3, &plain3Len));
    HeartbeatExt partial;
    QVERIFY(parseHeartbeatExtFromFrame(0, plain3, plain3Len, &partial));
    QVERIFY(partial.hasPosition());
    QVERIFY(partial.hasAltitude());
    QVERIFY(partial.hasVelocity()); // vy/vz 有效
    QVERIFY(partial.hasBattery());  // voltage>0
    QCOMPARE(partial.remaining, static_cast<int8_t>(-1)); // -1 未知保留

    // --- 兼容：旧版 37B EXT（60822.0）→ 解析前 37B，新字段保持默认哨兵 ---
    {
        QByteArray ext37 = makeExtBytes(312345678, 1214567890, 50000, 100, 200, -50, 3, 12, 11100, 85, 6, 1);
        ext37.resize(HeartbeatExt::kExtBaseSize); // 截断到 37B（模拟旧 PX4 发送）
        const QByteArray hbPayload = makeHeartbeatFrame(0x0C, 0x0D).mid(10, 9);
        const QByteArray frame37 = makeHeartbeatExtFrameFromPayload(hbPayload + ext37); // len=46

        uint8_t enc37[MAVLINK_MAX_PACKET_LEN + 32];
        int enc37Len = 0;
        QVERIFY(encryptFrame(reinterpret_cast<const uint8_t*>(frame37.constData()), frame37.size(), crcExtra,
                             deviceID, counter + 8, key, enc37, &enc37Len));
        uint8_t plain37[MAVLINK_MAX_PACKET_LEN];
        DeviceID dev37 = 0;
        uint64_t cnt37 = 0;
        int plain37Len = 0;
        QVERIFY(decryptFrame(enc37, enc37Len, crcExtra, key, &dev37, &cnt37, plain37, &plain37Len));
        HeartbeatExt ext37out;
        QVERIFY(parseHeartbeatExtFromFrame(0, plain37, plain37Len, &ext37out));
        QCOMPARE(ext37out.lat, static_cast<int32_t>(312345678));  // 基段正常解析
        QCOMPARE(ext37out.remaining, static_cast<int8_t>(85));
        QCOMPARE(ext37out.relAlt, HeartbeatExt::kInvalidInt32);   // 新字段默认哨兵
        QCOMPARE(ext37out.airspeed, HeartbeatExt::kInvalidInt16);
        QCOMPARE(ext37out.airspeedSource, HeartbeatExt::kAirspeedSourceDisabled);
        QCOMPARE(ext37out.current, HeartbeatExt::kInvalidInt16);
        QCOMPARE(ext37out.temperature, HeartbeatExt::kInvalidInt16);
        QVERIFY(!ext37out.hasRelativeAltitude());
        QVERIFY(!ext37out.hasCurrent());
        QVERIFY(!ext37out.hasExtendedFields); // 37B 兼容帧无扩展段
    }

    // --- 明文待命心跳（payload=9B）→ 不解析 EXT ---
    const QByteArray standby = makeHeartbeatFrame(0x0C, 0x0D);
    HeartbeatExt noExt;
    QVERIFY(!parseHeartbeatExtFromFrame(0, reinterpret_cast<const uint8_t*>(standby.constData()), standby.size(), &noExt));
    // 非 HEARTBEAT msgid → 拒绝
    QVERIFY(!parseHeartbeatExtFromFrame(33, reinterpret_cast<const uint8_t*>(extFrame.constData()), extFrame.size(), &noExt));

    // --- 日志格式化：heartbeatExtToText 纯函数断言（不依赖宏/文件）---
    {
        HeartbeatExt logExt;
        logExt.lat = 312345678;
        logExt.lon = 1214567890;
        logExt.alt = 50000;
        logExt.vx = 100;
        logExt.vy = 200;
        logExt.vz = -50;
        logExt.roll = 0.1f;
        logExt.pitch = -0.2f;
        logExt.yaw = 0.3f;
        logExt.fixType = 3;
        logExt.satellitesUsed = 12;
        logExt.voltage = 11100;
        logExt.remaining = 85;
        logExt.navState = 6;
        logExt.armingState = 1;
        // 60824.0 新增字段
        logExt.hasExtendedFields = true; // 日志对 boot/vtol/land/fail 仅在 55B 扩展段存在时显示
        logExt.timeBootMs = 12345;
        logExt.relAlt = 4321;
        logExt.airspeed = 5678;
        logExt.airspeedSource = 1;
        logExt.vtolState = 4;
        logExt.landed = 3;
        logExt.current = -5;
        logExt.temperature = 20;
        logExt.failsafe = 0x03;
        const QString text = CryptoLinkLogger::heartbeatExtToText(logExt);
        QVERIFY2(text.contains(QStringLiteral("lat=31.2345678")) && text.contains(QStringLiteral("alt=50.0m")) &&
                     text.contains(QStringLiteral("batt=11100mV/85%")) && text.contains(QStringLiteral("nav=6")) &&
                     text.contains(QStringLiteral("arm=1")) &&
                     text.contains(QStringLiteral("boot=12345")) && text.contains(QStringLiteral("relalt=4.3m")) &&
                     text.contains(QStringLiteral("air=5678")) && text.contains(QStringLiteral("airsrc=1")) &&
                     text.contains(QStringLiteral("vtol=4,land=3")) && text.contains(QStringLiteral("curr=-5")) &&
                     text.contains(QStringLiteral("temp=20")) && text.contains(QStringLiteral("fail=3")),
                 qPrintable(QStringLiteral("EXT 日志文本异常: %1").arg(text)));
        // 哨兵 → NA / DIS
        const QString invalidText = CryptoLinkLogger::heartbeatExtToText(HeartbeatExt{});
        QVERIFY2(invalidText.contains(QStringLiteral("lat=NA")) && invalidText.contains(QStringLiteral("alt=NA")) &&
                     invalidText.contains(QStringLiteral("v=NA/NA/NA")) &&
                     invalidText.contains(QStringLiteral("relalt=NA")) && invalidText.contains(QStringLiteral("air=NA")) &&
                     invalidText.contains(QStringLiteral("airsrc=DIS")) && invalidText.contains(QStringLiteral("curr=NA")) &&
                     invalidText.contains(QStringLiteral("temp=NA")),
                 qPrintable(QStringLiteral("EXT 哨兵日志文本异常: %1").arg(invalidText)));
    }

    // --- 日志文件写入（仅联调宏 QGC_CRYPTO_LINK_LOG 启用时；默认关则跳过） ---
    if (!CryptoLinkLogger::enabled()) {
        QSKIP("文件日志未启用（QGC_CRYPTO_LINK_LOG OFF），跳过文件写入断言");
        return;
    }
    CryptoLinkLogger::instance()->logIncoming(
        0, deviceID, true, reinterpret_cast<const char*>(encBuffer), encLen,
        reinterpret_cast<const char*>(plainOut), plainOutLen, true);
    QFile f(QStringLiteral("/tmp/qgc_crypto_link.log"));
    QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
    const QList<QByteArray> lines = f.readAll().split('\n');
    f.close();
    const QString last = QString::fromUtf8(lines[lines.size() - 2]);
    QVERIFY2(last.contains(QStringLiteral("EXT:")) && last.contains(QStringLiteral("lat=31.2345678")) &&
                 last.contains(QStringLiteral("batt=11100mV/85%")),
             qPrintable(QStringLiteral("加密心跳日志行缺少 EXT 字段: %1").arg(last)));
}

void CryptoTest::_testHeartbeatExtInjection()
{
    using namespace MAVLinkCrypto;

    const Key key = testKey();
    const DeviceID deviceID = 66051u; // 0x00010203 → sys=0x02, comp=0x03
    const uint64_t counter = 1000;

    // --- 有效 EXT(55B) → 4 条遥测：GLOBAL_POSITION_INT / ATTITUDE / GPS_RAW_INT / BATTERY_STATUS ---
    const ExtRoundTrip good = roundTripExt(
        makeExtFrame(312345678, 1214567890, 50000, 100, 200, -50, 3, 12, 11100, 85, 6, 1,
                     12345, 4321, 5678, 1, 4, 3, -5, 20, 0x03),
        key, deviceID, counter);
    QVERIFY(!good.decFrame.isEmpty());
    const QList<mavlink_message_t> goodMsgs = buildHeartbeatExtTelemetry(
        reinterpret_cast<const uint8_t*>(good.decFrame.constData()), good.ext);
    QCOMPARE(goodMsgs.size(), 4);
    QCOMPARE(goodMsgs[0].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_GLOBAL_POSITION_INT));
    QCOMPARE(goodMsgs[1].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_ATTITUDE));
    QCOMPARE(goodMsgs[2].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_GPS_RAW_INT));
    QCOMPARE(goodMsgs[3].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_BATTERY_STATUS));
    // sysid/compid 从解密帧头还原（deviceID 拆分）
    QCOMPARE(goodMsgs[0].sysid, static_cast<uint8_t>(0x02));
    QCOMPARE(goodMsgs[0].compid, static_cast<uint8_t>(0x03));
    // 字段映射（单位 degE7 / mm / cm/s / mV）
    mavlink_global_position_int_t gpi;
    mavlink_msg_global_position_int_decode(&goodMsgs[0], &gpi);
    QCOMPARE(gpi.lat, static_cast<int32_t>(312345678));
    QCOMPARE(gpi.lon, static_cast<int32_t>(1214567890));
    QCOMPARE(gpi.alt, static_cast<int32_t>(50000));
    QCOMPARE(gpi.vx, static_cast<int16_t>(100));
    QCOMPARE(gpi.relative_alt, static_cast<int32_t>(4321));   // 60824.0 rel_alt 注入
    QCOMPARE(gpi.time_boot_ms, static_cast<uint32_t>(12345)); // 60824.0 飞控时间戳注入
    mavlink_attitude_t att;
    mavlink_msg_attitude_decode(&goodMsgs[1], &att);
    QCOMPARE(att.roll, 0.1f);
    QCOMPARE(att.pitch, -0.2f);
    QCOMPARE(att.yaw, 0.3f);
    mavlink_gps_raw_int_t gps;
    mavlink_msg_gps_raw_int_decode(&goodMsgs[2], &gps);
    QCOMPARE(gps.fix_type, static_cast<uint8_t>(3));
    QCOMPARE(gps.satellites_visible, static_cast<uint8_t>(12));
    mavlink_battery_status_t batt;
    mavlink_msg_battery_status_decode(&goodMsgs[3], &batt);
    QCOMPARE(batt.voltages[0], static_cast<uint16_t>(11100));
    QCOMPARE(batt.battery_remaining, static_cast<int8_t>(85));
    QCOMPARE(batt.current_battery, static_cast<int16_t>(-50)); // 60824.0 current 0.1A×10 → cA
    QCOMPARE(batt.temperature, static_cast<int16_t>(200));     // cdegC（EXT 0.1°C×10：20×0.1°C=2.0°C → 200 cdegC）

    // --- 位置全哨兵 → 仅 ATTITUDE（GLOBAL/GPS 跳过；无电池数据跳过） ---
    const ExtRoundTrip sentinelRt = roundTripExt(
        makeExtFrame(HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32,
                     HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16,
                     0, 0, 0, -1, 0, 0),
        key, deviceID, counter + 2);
    QVERIFY(!sentinelRt.decFrame.isEmpty());
    const QList<mavlink_message_t> sentinelMsgs = buildHeartbeatExtTelemetry(
        reinterpret_cast<const uint8_t*>(sentinelRt.decFrame.constData()), sentinelRt.ext);
    QCOMPARE(sentinelMsgs.size(), 1);
    QCOMPARE(sentinelMsgs[0].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_ATTITUDE));

    // --- lat/lon 有效但 alt 哨兵 → GLOBAL/GPS 跳过（避免 0m 假高度），仅 ATTITUDE + BATTERY ---
    const ExtRoundTrip noAltRt = roundTripExt(
        makeExtFrame(312345678, 1214567890, HeartbeatExt::kInvalidInt32, 100, 200, -50, 3, 12, 11100, 85, 6, 1),
        key, deviceID, counter + 4);
    QVERIFY(!noAltRt.decFrame.isEmpty());
    const QList<mavlink_message_t> noAltMsgs = buildHeartbeatExtTelemetry(
        reinterpret_cast<const uint8_t*>(noAltRt.decFrame.constData()), noAltRt.ext);
    QCOMPARE(noAltMsgs.size(), 2);
    QCOMPARE(noAltMsgs[0].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_ATTITUDE));
    QCOMPARE(noAltMsgs[1].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_BATTERY_STATUS));

    // --- 电池第三分支：voltage=0（未知）但 remaining=50 → 打包 BATTERY，voltages[0]=UINT16_MAX（NaN） ---
    // 位置设哨兵以聚焦电池映射（仅 ATTITUDE + BATTERY 两条）。
    const ExtRoundTrip battOnlyRt = roundTripExt(
        makeExtFrame(HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32,
                     HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16,
                     0, 0, 0, 50, 6, 1),
        key, deviceID, counter + 6);
    QVERIFY(!battOnlyRt.decFrame.isEmpty());
    const QList<mavlink_message_t> battOnlyMsgs = buildHeartbeatExtTelemetry(
        reinterpret_cast<const uint8_t*>(battOnlyRt.decFrame.constData()), battOnlyRt.ext);
    QCOMPARE(battOnlyMsgs.size(), 2);
    QCOMPARE(battOnlyMsgs[0].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_ATTITUDE));
    QCOMPARE(battOnlyMsgs[1].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_BATTERY_STATUS));
    mavlink_battery_status_t battOnly;
    mavlink_msg_battery_status_decode(&battOnlyMsgs[1], &battOnly);
    QCOMPARE(battOnly.voltages[0], static_cast<uint16_t>(UINT16_MAX)); // 未知电压 → NaN
    QCOMPARE(battOnly.battery_remaining, static_cast<int8_t>(50));

    // --- 电流/温度有效但电压未知（voltage=0, remaining=-1）→ BATTERY 仍打包（门控含 hasCurrent/hasTemperature），
    // 电流/温度按 cA/cdegC 注入，电压保持 NaN ---
    const ExtRoundTrip currTempRt = roundTripExt(
        makeExtFrame(HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt32,
                     HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16, HeartbeatExt::kInvalidInt16,
                     0, 0, 0, -1, 6, 1,
                     0, HeartbeatExt::kInvalidInt32, HeartbeatExt::kInvalidInt16, HeartbeatExt::kAirspeedSourceDisabled,
                     0, 0, 35, 255, 0),
        key, deviceID, counter + 8);
    QVERIFY(!currTempRt.decFrame.isEmpty());
    QVERIFY(!currTempRt.ext.hasBattery()); // voltage=0, remaining=-1
    QVERIFY(currTempRt.ext.hasCurrent());
    QVERIFY(currTempRt.ext.hasTemperature());
    const QList<mavlink_message_t> currTempMsgs = buildHeartbeatExtTelemetry(
        reinterpret_cast<const uint8_t*>(currTempRt.decFrame.constData()), currTempRt.ext);
    QCOMPARE(currTempMsgs.size(), 2);  // ATTITUDE + BATTERY（门控含 current/temp，BATTERY 不丢）
    QCOMPARE(currTempMsgs[1].msgid, static_cast<uint32_t>(MAVLINK_MSG_ID_BATTERY_STATUS));
    mavlink_battery_status_t ctBatt;
    mavlink_msg_battery_status_decode(&currTempMsgs[1], &ctBatt);
    QCOMPARE(ctBatt.voltages[0], static_cast<uint16_t>(UINT16_MAX)); // 电压未知 → NaN
    QCOMPARE(ctBatt.current_battery, static_cast<int16_t>(350));     // 35 0.1A × 10 = 350 cA
    QCOMPARE(ctBatt.temperature, static_cast<int16_t>(2550));        // 255 0.1°C × 10 = 2550 cdegC

    // --- hasBattery 谓词三分支（直接构造结构体） ---
    {
        HeartbeatExt withVolt;
        withVolt.voltage = 11100;
        withVolt.remaining = -1;
        QVERIFY(withVolt.hasBattery());
        HeartbeatExt withRemain;
        withRemain.voltage = 0;
        withRemain.remaining = 50;
        QVERIFY(withRemain.hasBattery());
        HeartbeatExt none;
        none.voltage = 0;
        none.remaining = -1;
        QVERIFY(!none.hasBattery());
    }
}

UT_REGISTER_TEST_LIGHTWEIGHT(CryptoTest, TestLabel::Unit)
