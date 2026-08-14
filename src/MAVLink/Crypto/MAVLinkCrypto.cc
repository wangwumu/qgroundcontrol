#include "MAVLinkCrypto.h"

#include <openssl/evp.h>

#include <cstring>

namespace MAVLinkCrypto {

namespace {

/// 将 uint64 counter 按大端序写入 8 字节缓冲。
void writeCounterBE(uint64_t counter, uint8_t* out)
{
    for (int i = kCounterSize - 1; i >= 0; --i) {
        out[i] = static_cast<uint8_t>(counter & 0xFFu);
        counter >>= 8;
    }
}

/// 将 deviceID 按大端序写入 4 字节缓冲。
void writeDeviceIDBE(DeviceID deviceID, uint8_t* out)
{
    out[0] = static_cast<uint8_t>((deviceID >> 24) & 0xFFu);
    out[1] = static_cast<uint8_t>((deviceID >> 16) & 0xFFu);
    out[2] = static_cast<uint8_t>((deviceID >> 8) & 0xFFu);
    out[3] = static_cast<uint8_t>(deviceID & 0xFFu);
}

} // namespace

void makeNonce(uint64_t counter, DeviceID deviceID, uint8_t* nonceOut)
{
    writeCounterBE(counter, nonceOut);
    writeDeviceIDBE(deviceID, nonceOut + kCounterSize);
}

bool encrypt(const Key& key, uint64_t counter, DeviceID deviceID, const uint8_t* plaintext,
             size_t plaintextLen, uint8_t* ciphertextOut, uint8_t* tagOut)
{
    if (plaintext == nullptr || plaintextLen == 0 || ciphertextOut == nullptr || tagOut == nullptr) {
        return false; // 规范 §2.2：原始消息 payload 长度必须 >= 1 字节
    }

    uint8_t nonce[kNonceSize];
    makeNonce(counter, deviceID, nonce);

    uint8_t aad[kCounterSize];
    writeCounterBE(counter, aad);

    uint8_t deviceIDBytes[kDeviceIDSize];
    writeDeviceIDBE(deviceID, deviceIDBytes);

    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        return false;
    }

    bool ok = false;
    int outLen = 0;

    do {
        if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
            break;
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(kNonceSize), nullptr) != 1) {
            break;
        }
        if (EVP_EncryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce) != 1) {
            break;
        }
        // counter 作为 AAD（附加认证数据）
        if (EVP_EncryptUpdate(ctx, nullptr, &outLen, aad, static_cast<int>(kCounterSize)) != 1) {
            break;
        }

        int total = 0;
        // 明文首部：deviceID 前缀（4 字节）
        if (EVP_EncryptUpdate(ctx, ciphertextOut, &outLen, deviceIDBytes, static_cast<int>(kDeviceIDSize)) != 1) {
            break;
        }
        total = outLen;

        // 明文主体：原始 payload
        if (EVP_EncryptUpdate(ctx, ciphertextOut + total, &outLen, plaintext, static_cast<int>(plaintextLen)) != 1) {
            break;
        }
        total += outLen;

        if (EVP_EncryptFinal_ex(ctx, ciphertextOut + total, &outLen) != 1) {
            break;
        }
        total += outLen;

        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, static_cast<int>(kTagSize), tagOut) != 1) {
            break;
        }

        ok = true;
    } while (false);

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

bool decrypt(const Key& key, uint64_t counter, DeviceID deviceID, const uint8_t* ciphertext,
             size_t ciphertextLen, const uint8_t* tag, uint8_t* plaintextOut)
{
    if (ciphertext == nullptr || ciphertextLen < kDeviceIDSize || tag == nullptr || plaintextOut == nullptr) {
        return false;
    }

    uint8_t nonce[kNonceSize];
    makeNonce(counter, deviceID, nonce);

    uint8_t aad[kCounterSize];
    writeCounterBE(counter, aad);

    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        return false;
    }

    bool ok = false;
    int outLen = 0;

    do {
        if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
            break;
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(kNonceSize), nullptr) != 1) {
            break;
        }
        if (EVP_DecryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce) != 1) {
            break;
        }
        if (EVP_DecryptUpdate(ctx, nullptr, &outLen, aad, static_cast<int>(kCounterSize)) != 1) {
            break;
        }

        int total = 0;
        if (EVP_DecryptUpdate(ctx, plaintextOut, &outLen, ciphertext, static_cast<int>(ciphertextLen)) != 1) {
            break;
        }
        total = outLen;

        // 设置 tag 后 final 才做认证校验
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, static_cast<int>(kTagSize), const_cast<uint8_t*>(tag)) != 1) {
            break;
        }
        if (EVP_DecryptFinal_ex(ctx, plaintextOut + total, &outLen) != 1) {
            break; // tag 校验失败：篡改/伪造帧
        }

        ok = true;
    } while (false);

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

} // namespace MAVLinkCrypto
