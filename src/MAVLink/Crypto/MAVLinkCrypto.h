#pragma once

/// AES-256-GCM payload 加解密（依据 `docs/10_deviceID与payload加密公共规范.md` 第二部分）。
///
/// 算法与约定：
/// - 算法：AES-256-GCM，密钥 256 位（32 字节）
/// - nonce（12 字节）= counter(8B 大端) || deviceID(4B 大端)
/// - AAD = counter(8B 大端)（counter 为明文，被 GCM 认证）
/// - 加密明文 = deviceID(4B 大端) || 原始 MAVLink 消息 payload
/// - tag = 16 字节
///
/// 本模块为纯函数式工具，无状态、线程安全，不依赖 QGC 组件（仅 OpenSSL libcrypto）。

#include <array>
#include <cstddef>
#include <cstdint>

#include "DeviceID.h"

namespace MAVLinkCrypto {

/// 256 位（32 字节）AES 通信密钥。
using Key = std::array<uint8_t, 32>;

/// 固定常量。
inline constexpr size_t kKeySize = 32;     ///< 密钥字节数
inline constexpr size_t kNonceSize = 12;   ///< GCM nonce 字节数（counter 8B + deviceID 4B）
inline constexpr size_t kTagSize = 16;     ///< GCM 认证标签字节数
inline constexpr size_t kCounterSize = 8;  ///< counter 明文字节数
inline constexpr size_t kDeviceIDSize = 4; ///< 明文内嵌 deviceID 字节数

/// 构造 12 字节 GCM nonce：counter(8B 大端) || deviceID(4B 大端)。
/// @param counter  每帧唯一的单调递增值（PX4 偶数 / QGC 奇数）
/// @param deviceID 本端设备标识（大端序写入）
/// @param nonceOut 输出缓冲，长度必须 >= kNonceSize
void makeNonce(uint64_t counter, DeviceID deviceID, uint8_t* nonceOut);

/// AES-256-GCM 加密。
/// @param key            32 字节通信密钥
/// @param counter        每帧唯一 counter（同时作为 AAD）
/// @param deviceID       本端 deviceID（写入明文首部，供接收方密钥绑定）
/// @param plaintext      原始 MAVLink 消息 payload；允许为空（规范 §2.3 超限退化帧仅含 deviceID 前缀）
/// @param plaintextLen   明文长度（不含 4 字节 deviceID 前缀）
/// @param ciphertextOut  输出密文缓冲，长度 >= plaintextLen
/// @param tagOut         输出 16 字节 GCM tag
/// @return true=成功；false=失败（密钥/参数异常）
/// 注：规范 §2.2「零长度消息禁止」由调用方（encryptFrame）在原始 payloadLen==0 时执行。
bool encrypt(const Key& key, uint64_t counter, DeviceID deviceID, const uint8_t* plaintext,
             size_t plaintextLen, uint8_t* ciphertextOut, uint8_t* tagOut);

/// AES-256-GCM 解密（含 tag 认证）。
///
/// 解密输出为**完整明文**（长度 = ciphertextLen）：
///   前 4 字节 = 明文内嵌 deviceID（供调用方做密钥绑定校验，见规范 §2.6 第 8 步）；
///   剩余 ciphertextLen - 4 字节 = 原始 MAVLink 消息 payload。
///
/// @param counter      位于 payload block 明文首部 8 字节（不在 GCM 密文内）
/// @param deviceID     从帧头重组的 deviceID₁（用于构造 nonce）
/// @param ciphertext   payload block 中的密文（长度 >= kDeviceIDSize）
/// @param plaintextOut 输出完整明文缓冲，长度 >= ciphertextLen
/// @return true=解密且 tag 校验通过；false=tag 校验失败（篡改/伪造帧）或参数异常
bool decrypt(const Key& key, uint64_t counter, DeviceID deviceID, const uint8_t* ciphertext,
             size_t ciphertextLen, const uint8_t* tag, uint8_t* plaintextOut);

} // namespace MAVLinkCrypto
