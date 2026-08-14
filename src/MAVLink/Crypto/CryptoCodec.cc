#include "CryptoCodec.h"

#include <checksum.h>
#include <mavlink_types.h>

#include <cstring>

namespace MAVLinkCrypto {

namespace {

/// counter 按大端序写入 8 字节。
void writeCounterBE(uint64_t counter, uint8_t* out)
{
    for (int i = kCounterSize - 1; i >= 0; --i) {
        out[i] = static_cast<uint8_t>(counter & 0xFFu);
        counter >>= 8;
    }
}

/// 从 8 字节大端序读取 counter。
uint64_t readCounterBE(const uint8_t* in)
{
    uint64_t counter = 0;
    for (int i = 0; i < static_cast<int>(kCounterSize); ++i) {
        counter = (counter << 8) | in[i];
    }
    return counter;
}

/// 从 4 字节大端序读取 deviceID。
DeviceID readDeviceIDBE(const uint8_t* in)
{
    return (static_cast<DeviceID>(in[0]) << 24) | (static_cast<DeviceID>(in[1]) << 16) |
           (static_cast<DeviceID>(in[2]) << 8) | static_cast<DeviceID>(in[3]);
}

/// 计算 MAVLink V2 帧 CRC：crc(帧头从 len 起 9 字节) + crc(payload) + crc(crc_extra)。
uint16_t computeCrc(const uint8_t* frame, uint8_t payloadLen, uint8_t crcExtra)
{
    uint16_t crc;
    crc_init(&crc);
    for (int i = 1; i < static_cast<int>(kV2HeaderLen); ++i) {
        crc_accumulate(frame[i], &crc);
    }
    crc_accumulate_buffer(&crc, reinterpret_cast<const char*>(frame + kV2HeaderLen), payloadLen);
    crc_accumulate(crcExtra, &crc);
    return crc;
}

} // namespace

bool encryptFrame(const uint8_t* plainFrame, int plainLen, uint8_t crcExtra, DeviceID gcsDeviceID,
                  uint64_t counter, const Key& key, uint8_t* encFrame, int* encLen)
{
    if (plainFrame == nullptr || encFrame == nullptr || encLen == nullptr || plainLen < 0) {
        return false;
    }

    const uint8_t payloadLen = plainFrame[1];
    const uint8_t seq = plainFrame[4];
    const uint32_t msgid = msgidFromFrame(plainFrame);
    const uint8_t* payload = plainFrame + kV2HeaderLen;

    // 加密 payload：明文 = deviceID(4B) + payload，密文长度 = payloadLen + 4
    uint8_t ciphertext[MAVLINK_MAX_PAYLOAD_LEN + kDeviceIDSize];
    uint8_t tag[kTagSize];
    if (!encrypt(key, counter, gcsDeviceID, payload, payloadLen, ciphertext, tag)) {
        return false;
    }
    const uint16_t ciphertextLen = static_cast<uint16_t>(payloadLen) + kDeviceIDSize;

    // 组装加密帧头（deviceID 拆 4 字节写入 inc/com/sys/comp）
    const uint16_t encPayloadLen = kCounterSize + ciphertextLen + kTagSize;
    encFrame[0] = 0xFD; // magic (MAVLINK_STX)
    encFrame[1] = static_cast<uint8_t>(encPayloadLen);
    encFrame[2] = incompatFlag(gcsDeviceID);
    encFrame[3] = compatFlag(gcsDeviceID);
    encFrame[4] = seq;
    encFrame[5] = systemID(gcsDeviceID);
    encFrame[6] = componentID(gcsDeviceID);
    encFrame[7] = static_cast<uint8_t>(msgid & 0xFFu);
    encFrame[8] = static_cast<uint8_t>((msgid >> 8) & 0xFFu);
    encFrame[9] = static_cast<uint8_t>((msgid >> 16) & 0xFFu);

    // payload block = counter(8B) + ciphertext + tag
    uint8_t* pb = encFrame + kV2HeaderLen;
    writeCounterBE(counter, pb);
    std::memcpy(pb + kCounterSize, ciphertext, ciphertextLen);
    std::memcpy(pb + kCounterSize + ciphertextLen, tag, kTagSize);

    // CRC
    const uint16_t crc = computeCrc(encFrame, static_cast<uint8_t>(encPayloadLen), crcExtra);
    encFrame[kV2HeaderLen + encPayloadLen] = static_cast<uint8_t>(crc & 0xFFu);
    encFrame[kV2HeaderLen + encPayloadLen + 1] = static_cast<uint8_t>(crc >> 8);

    *encLen = kV2HeaderLen + encPayloadLen + kCrcLen;
    return true;
}

bool decryptFrame(const uint8_t* encFrame, int encLen, uint8_t crcExtra, const Key& key,
                  DeviceID* outDeviceID, uint64_t* outCounter, uint8_t* plainFrame, int* plainLen)
{
    if (encFrame == nullptr || plainFrame == nullptr || encLen < 0 || outDeviceID == nullptr ||
        outCounter == nullptr || plainLen == nullptr) {
        return false;
    }

    const uint8_t encPayloadLen = encFrame[1];
    const uint8_t seq = encFrame[4];
    const uint32_t msgid = msgidFromFrame(encFrame);
    const DeviceID deviceID = deviceIDFromFrame(encFrame);
    const uint64_t counter = counterFromFrame(encFrame);

    // payload block 拆分
    const uint8_t* pb = encFrame + kV2HeaderLen;
    const uint8_t* ciphertext = pb + kCounterSize;
    const uint16_t ciphertextLen = static_cast<uint16_t>(encPayloadLen) - kCounterSize - kTagSize;
    const uint8_t* tag = pb + kCounterSize + ciphertextLen;

    // 解密：明文 = deviceID(4B) + 原始 payload
    uint8_t plaintext[MAVLINK_MAX_PAYLOAD_LEN + kDeviceIDSize];
    if (!decrypt(key, counter, deviceID, ciphertext, ciphertextLen, tag, plaintext)) {
        return false;
    }

    // 密钥绑定：明文内嵌 deviceID 必须与帧头重组一致
    const DeviceID embeddedDeviceID = readDeviceIDBE(plaintext);
    if (embeddedDeviceID != deviceID) {
        return false;
    }

    const uint8_t* payload = plaintext + kDeviceIDSize;
    const uint16_t payloadLen = ciphertextLen - kDeviceIDSize;

    // 还原标准帧（incompat/compat 清零，sysid/compid 从 deviceID 还原）
    plainFrame[0] = 0xFD;
    plainFrame[1] = static_cast<uint8_t>(payloadLen);
    plainFrame[2] = 0;
    plainFrame[3] = 0;
    plainFrame[4] = seq;
    plainFrame[5] = systemID(deviceID);
    plainFrame[6] = componentID(deviceID);
    plainFrame[7] = static_cast<uint8_t>(msgid & 0xFFu);
    plainFrame[8] = static_cast<uint8_t>((msgid >> 8) & 0xFFu);
    plainFrame[9] = static_cast<uint8_t>((msgid >> 16) & 0xFFu);
    std::memcpy(plainFrame + kV2HeaderLen, payload, payloadLen);

    // CRC
    const uint16_t crc = computeCrc(plainFrame, static_cast<uint8_t>(payloadLen), crcExtra);
    plainFrame[kV2HeaderLen + payloadLen] = static_cast<uint8_t>(crc & 0xFFu);
    plainFrame[kV2HeaderLen + payloadLen + 1] = static_cast<uint8_t>(crc >> 8);

    *outDeviceID = deviceID;
    *outCounter = counter;
    *plainLen = kV2HeaderLen + payloadLen + kCrcLen;
    return true;
}

DeviceID deviceIDFromFrame(const uint8_t* encFrame)
{
    return makeDeviceID(encFrame[2], encFrame[3], encFrame[5], encFrame[6]);
}

uint32_t msgidFromFrame(const uint8_t* encFrame)
{
    return static_cast<uint32_t>(encFrame[7]) | (static_cast<uint32_t>(encFrame[8]) << 8) |
           (static_cast<uint32_t>(encFrame[9]) << 16);
}

uint8_t frameLength(const uint8_t* encFrame)
{
    return encFrame[1];
}

uint64_t counterFromFrame(const uint8_t* encFrame)
{
    return readCounterBE(encFrame + kV2HeaderLen);
}

} // namespace MAVLinkCrypto
