#pragma once

/// 加密帧编解码核心（依据 `docs/10_deviceID与payload加密公共规范.md` §1.2 / §2.3 / §2.4 / §2.6）。
///
/// 在字节层做标准 MAVLink V2 帧 ↔ 加密帧 的转换，对 mavlink 库透明：
/// - 发送：标准帧（mavlink_msg_to_send_buffer 输出）→ 加密帧（帧头 deviceID 拆分 + payload AES-GCM 加密）
/// - 接收：加密帧 → 标准帧（deviceID 重组 + 防重放所需 counter 提取 + payload 解密 + 帧头还原）
///
/// 帧格式约定（V2）：
///   标准帧:  magic(1) len(1) incompat(1) compat(1) seq(1) sysid(1) compid(1) msgid(3) payload(len) CRC(2)
///   加密帧:  magic(1) len'(1) inc(1) com(1) seq(1) sys(1) comp(1) msgid(3) [counter(8)+ciphertext(N)+tag(16)] CRC(2)
///   其中 inc/com/sys/comp 为 deviceID 的 4 字节（大端），len' = N + 24，N = 4 + 原始 payload 长度。
///
/// CRC 计算（与 mavlink 库一致）：crc(帧头从 len 起 9 字节) + crc(payload block) + crc(crc_extra)。
/// crc_extra 由调用方传入（发送端从 mavlink_message_t 查，接收端从帧头 msgid 查）。

#include <cstddef>
#include <cstdint>

#include "DeviceID.h"
#include "MAVLinkCrypto.h"

namespace MAVLinkCrypto {

/// MAVLink V2 帧头固定长度（magic + len + incompat + compat + seq + sysid + compid + msgid[3]）。
inline constexpr size_t kV2HeaderLen = 10;
/// CRC 字段长度。
inline constexpr size_t kCrcLen = 2;

/// 标准帧 → 加密帧。
/// @param plainFrame  标准帧字节（mavlink_msg_to_send_buffer 输出，含 CRC），长度 >= kV2HeaderLen + kCrcLen
/// @param plainLen    标准帧总长度
/// @param crcExtra    该消息类型的 CRC_EXTRA 字节
/// @param gcsDeviceID 本端 GCS 的 deviceID（拆入帧头 4 字节）
/// @param counter     本方向（QGC 奇数）发送 counter
/// @param key         目标设备通信密钥
/// @param encFrame    加密帧输出缓冲（长度 >= plainLen + kTagSize + kCounterSize + kDeviceIDSize）
/// @param encLen      输出加密帧长度
/// @return true=成功
bool encryptFrame(const uint8_t* plainFrame, int plainLen, uint8_t crcExtra, DeviceID gcsDeviceID,
                  uint64_t counter, const Key& key, uint8_t* encFrame, int* encLen);

/// 加密帧 → 标准帧。
/// @param encFrame    加密帧字节，长度 >= kV2HeaderLen + kCounterSize + kDeviceIDSize + kTagSize + kCrcLen
/// @param encLen      加密帧总长度
/// @param crcExtra    该消息类型的 CRC_EXTRA 字节（由调用方从帧头 msgid 查）
/// @param key         设备通信密钥
/// @param outDeviceID 输出从帧头重组的 deviceID
/// @param outCounter  输出从 payload block 读取的 counter
/// @param plainFrame  标准帧输出缓冲（长度 >= encLen）
/// @param plainLen    输出标准帧长度
/// @return true=解密 + 密钥绑定校验通过
bool decryptFrame(const uint8_t* encFrame, int encLen, uint8_t crcExtra, const Key& key,
                  DeviceID* outDeviceID, uint64_t* outCounter, uint8_t* plainFrame, int* plainLen);

/// 从加密帧头重组 deviceID（不解密，供路由/防重放/密钥查找）。
DeviceID deviceIDFromFrame(const uint8_t* encFrame);

/// 从加密帧头读取 msgid（3 字节小端）。
uint32_t msgidFromFrame(const uint8_t* encFrame);

/// 从加密帧头读取 len 字段（payload block 长度）。
uint8_t frameLength(const uint8_t* encFrame);

/// 从加密帧 payload block 前 8 字节读取 counter（大端）。
uint64_t counterFromFrame(const uint8_t* encFrame);

} // namespace MAVLinkCrypto
