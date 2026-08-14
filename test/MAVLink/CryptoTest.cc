#include "CryptoTest.h"

#include "Crypto/CryptoCodec.h"
#include "Crypto/DeviceID.h"
#include "Crypto/MAVLinkCrypto.h"
#include "Crypto/ReplayGuard.h"
#include "MAVLinkLib.h"

#include <QtTest/QtTest>

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

UT_REGISTER_TEST_LIGHTWEIGHT(CryptoTest, TestLabel::Unit)
