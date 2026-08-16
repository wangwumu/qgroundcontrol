# QGC 加密 MAVLink 链路实现说明

> 本文档整理本次对 QGC 地面站工程的全部改动：**32 位 deviceID 帧头重组 + AES-256-GCM payload 加密**。
> 协议依据：`docs/10_deviceID与payload加密公共规范.md`（mavp2p / PX4 / QGC 三方公共规范）。
> 提交：分支 `DID4B_Aes`，commit `11e0ad1ac`（加密实现）+ `734b77100`（汉化润色）。

---

## 1. 概述

本次改动为 QGC 增加了一条**加密 MAVLink 链路**能力，与 PX4 飞控、mavp2p 网关共同实现：

- **32 位 deviceID**：把 MAVLink V2 帧头 4 个单字节字段（`incompatFlag`/`compatFlag`/`systemID`/`componentID`）合并解读为一个全局唯一的 32 位设备标识，支撑多租户场景下数千架无人机的唯一寻址。
- **AES-256-GCM payload 加密**：对 MAVLink 帧的 payload 部分做认证加密（保密 + 完整性 + 防重放），帧头保持明文供路由与密钥绑定。

改动分为三部分：
1. **新增 `src/MAVLink/Crypto/` 加密模块**（6 个组件，纯新增，不侵入 mavlink 库）；
2. **接线**（在现有收发链路上挂接加密/解密逻辑）；
3. **新增 `CryptoSettings` 设置组**（4 个配置项，QML/持久化可用）。

---

## 2. 协议要点回顾

> 完整定义见 `docs/10_deviceID与payload加密公共规范.md`，此处仅列 QGC 实现直接依赖的要点。

### 2.1 deviceID 帧头重组（规范 §1.2）

```
帧头字节偏移:   2         3         5         6
             ┌─────────┬─────────┬─────────┬─────────┐
             │ inc(1B) │ com(1B) │ sys(1B) │ comp(1B)│
             └─────────┴─────────┴─────────┴─────────┘
             ◄────────── 解读为 uint32 deviceID ─────────►
```

- 编码：`deviceID = (inc << 24) | (com << 16) | (sys << 8) | comp`
- **约束（§1.4）**：`deviceID & 0x01000000 == 0`，即 incompatFlag（最高字节）的 bit0 必须为 0，避免标准 MAVLink 解析器误判为「带签名帧」。
- **约束（§1.4/§1.5）**：incompatFlag 的 bit1~7（deviceID bit25~31）会被标准 parser 当作「未知保留标志」而拒绝整帧，必须修改 parser 放行——QGC 侧以构建期补丁实现（见 §4.6），否则 deviceID 只能用到低 24 位（详见 `docs/11_deviceID与incompat_flags冲突说明.md`）。

### 2.2 payload 加密结构（规范 §2.3 / §2.4）

加密后的 payload block：

```
┌───────────────┬─────────────────────────────┬──────────┐
│  counter(8B)  │  ciphertext(NB)             │  tag(16B)│
│   明文         │   AES-256-GCM 密文           │  认证标签  │
└───────────────┴─────────────────────────────┴──────────┘
```

- 加密明文 = `deviceID(4B 大端) || 原始 MAVLink 消息 payload`
- `N = 4 + 原始 payload 长度`，`len(payload block) = N + 24`
- 明文内嵌 deviceID 用于**密钥绑定**（防「用自己的密钥冒充他人设备」）。

### 2.3 nonce / AAD 构造（规范 §2.5）

- **nonce（12B）** = `counter(8B 大端) || deviceID(4B 大端)`
- **AAD** = `counter(8B 大端)`（counter 为明文，被 GCM 认证，篡改即 tag 校验失败）

### 2.4 奇偶 counter 分家（规范 §2.5）

- 同一 deviceID 使用**一把通信密钥**，PX4 与 QGC 双向共用；
- **PX4 发偶数 counter，QGC 发奇数 counter**，奇偶不相交 → 全局 nonce 永不碰撞；
- 发送规则：**建链首帧由 QGC 取加密安全随机 62 位奇数起点**，此后取「严格大于该 deviceID 全局 lastNonce 的最小本方向奇偶值」（规范 §2.5）。

### 2.5 防重放（规范 §2.5 / §2.6）

每个接收方按 deviceID 维护全局 `lastNonce`：

```
counter >  lastNonce[deviceID] → 接受并更新
counter <= lastNonce[deviceID] → 重放/乱序，丢弃
```

### 2.6 接收处理流程（规范 §2.6）

```
0. 长度检查（payload block < 28 → 丢弃）
1. 帧头重组 deviceID₁
2. 读 payload 前 8 字节 counter
3. 防重放（counter > lastNonce）
4. 构造 nonce
5. 取密钥（查无 → 丢弃）
6. AES-GCM 解密 + tag 校验
7. 提取明文前 4 字节 deviceID₂
8. 密钥绑定（deviceID₂ == deviceID₁）
9. 更新 lastNonce
10. 按 msgID 解析剩余明文
```

### 2.7 握手状态机（规范 §2.5 / 第三部分）

```
Standby（待命，只读遥测）
   │  MissionController 确定航线 + 选定无人机
   ▼
Linking（取密钥，回传奇数起点）
   │  keyFetched → confirmLinking
   ▼
Active（可加密下发指令）
   │  任务结束 / 断链 → returnToStandby
   ▼
Standby
```

---

## 3. 新增模块：`src/MAVLink/Crypto/`

| 文件 | 职责 |
|------|------|
| `DeviceID.h` | 32 位 deviceID 位操作 + 与 `mavlink_message_t` 互转（header-only） |
| `MAVLinkCrypto.h/.cc` | AES-256-GCM 加解密核心（OpenSSL EVP），无状态纯函数 |
| `ReplayGuard.h/.cc` | 按 deviceID 维护 lastNonce 的防重放状态 |
| `DeviceKeyManager.h/.cc` | 经 HTTPS 向 gcs_server 获取/缓存设备密钥 |
| `CryptoController.h/.cc` | 握手状态机 + counter 管理 + 防重放 + deviceID↔systemID 映射，全局单例 |
| `CryptoCodec.h/.cc` | 帧级编解码：标准帧 ↔ 加密帧（deviceID 拆分 + payload 加密 + CRC 重算） |
| `CMakeLists.txt` | 构建集成（桌面/Android 双平台 OpenSSL 链接） |

### 3.1 `DeviceID.h`（header-only）

- `using DeviceID = uint32_t;`，`kInvalidDeviceID = 0`
- 纯位操作：`makeDeviceID()` / `incompatFlag()` / `compatFlag()` / `systemID()` / `componentID()`
- 约束校验：`hasValidSignatureBit()`（`(id & 0x01000000) == 0`）
- mavlink 互转：`fromMessage()`（帧头 4 字段重组）、`toMessage()`（拆分写回）

### 3.2 `MAVLinkCrypto.h/.cc`

核心 AES-256-GCM 工具，纯函数式、无状态、线程安全，仅依赖 OpenSSL `libcrypto`。

```cpp
using Key = std::array<uint8_t, 32>;   // 256 位密钥
kKeySize=32  kNonceSize=12  kTagSize=16  kCounterSize=8  kDeviceIDSize=4

void makeNonce(uint64_t counter, DeviceID deviceID, uint8_t* nonceOut);
bool encrypt(const Key&, uint64_t counter, DeviceID deviceID,
             const uint8_t* plaintext, size_t plaintextLen,
             uint8_t* ciphertextOut, uint8_t* tagOut);
bool decrypt(const Key&, uint64_t counter, DeviceID deviceID,
             const uint8_t* ciphertext, size_t ciphertextLen,
             const uint8_t* tag, uint8_t* plaintextOut);
```

实现要点（`MAVLinkCrypto.cc`）：
- 用 `EVP_aes_256_gcm()` + `EVP_CIPHER_CTX_ctrl` 设 12 字节 IV 长度；
- **AAD = counter(8B)**：先 `EVP_EncryptUpdate(..., aad, 8)` 再加密数据；
- 加密明文 = `deviceID(4B) || payload`（deviceID 前缀先写入密文）；
- `encrypt` 允许 `plaintextLen == 0`（PR 修复：规范 §2.3 超限退化帧的明文仅 deviceID 前缀、payload 为空）；
  规范 §2.2「零长度消息禁止」由调用方 `encryptFrame` 在原始 payloadLen==0 时执行；
- `decrypt` 通过 `EVP_CTRL_GCM_SET_TAG` 后 `EVP_DecryptFinal_ex` 做 tag 认证，失败返回 `false`；
- 解密输出 = `deviceID(4B) || 原始 payload`，deviceID 供调用方做密钥绑定。

### 3.3 `ReplayGuard.h/.cc`

线程安全的防重放状态（`QHash<DeviceID, uint64_t> _lastNonce` + `QMutex`）。

```cpp
bool isAcceptable(DeviceID, uint64_t) const;  // 纯判定（§2.6 第 3 步），不修改状态
void commit(DeviceID, uint64_t);              // 认证后提交（§2.6 第 9 步），更新 lastNonce
bool accept(DeviceID, uint64_t);              // 判定+更新（仅发送侧原子预留 counter 用）
void reset(DeviceID deviceID);                // 重置单设备 lastNonce
void clear();                                 // 清空全部
bool hasDevice(DeviceID deviceID) const;
bool peekLastNonce(DeviceID deviceID, uint64_t& outLast) const;  // 只读查询
```

> **两阶段语义**（PR 修复）：接收侧必须先用 `isAcceptable()` 判定、再在解密 + tag 认证通过后调 `commit()`。
> 一次性的 `accept()` 只在发送侧用于原子预留 counter（生成的 counter 必 > last）。

### 3.4 `DeviceKeyManager.h/.cc`

密钥获取与缓存，`QObject`，内部持有 `QNetworkAccessManager`（经 `QGCNetworkHelper` 创建）。

```cpp
void setServerUrl(const QString& url);   // gcs_server 地址（如 https://uav.example.com）
void setAuthToken(const QString& token); // Bearer token（不含 "Bearer " 前缀）
bool isConfigured() const;
bool hasKey(DeviceID deviceID) const;
bool keyForDevice(DeviceID deviceID, Key& outKey) const;
void cacheKey(DeviceID deviceID, const Key& key);
void removeKey(DeviceID deviceID);
void clearCache();
void fetchKey(DeviceID deviceID);        // 异步 GET，完成发 keyFetched/fetchFailed
signals:
    void keyFetched(DeviceID deviceID);
    void fetchFailed(DeviceID deviceID, const QString& error);
```

实现要点：
- 请求：`GET {serverUrl}/api/device-keys/{deviceId}`，带 `Authorization: Bearer {token}`；
- 解析 JSON，兼容 `{ "key": "<base64>" }` 与 `{ "data": { "key": "<base64>" } }` 两种形态；
- Base64 解码后校验必须为 32 字节，否则失败；
- 密钥仅内存缓存，进程退出即失效；`removeKey`/`clearCache` 用 `std::fill(..., 0)` **安全清零**。

### 3.5 `CryptoController.h/.cc`

QGC 端加密状态机核心，`Q_APPLICATION_STATIC` 全局单例，线程安全（内部 `QMutex`）。

```cpp
enum class State { Standby, Linking, Active };

static CryptoController* instance();

// 配置注入
void setGcsDeviceID(DeviceID deviceID);
void setCryptoEnabled(bool enabled);
bool cryptoEnabled() const;
DeviceKeyManager* deviceKeyManager();

// 状态
State state() const;
DeviceID gcsDeviceID() const;
DeviceID activeDeviceID() const;
bool hasActiveKey() const;
bool activeKey(Key& outKey) const;

// 握手
void beginLinking(DeviceID targetDeviceID);
void beginLinkingForSystemID(uint8_t systemID);   // 便捷：按 systemID 查 deviceID
void learnDeviceSystemMapping(DeviceID deviceID, uint8_t systemID);
bool deviceIDForSystemID(uint8_t systemID, DeviceID& outDeviceID) const;
void confirmLinking();
void failLinking(const QString& error);
void returnToStandby();

// counter 与防重放
bool nextOutgoingCounter(uint64_t& outCounter);       // 奇数，首帧随机起点，此后严格大于 lastNonce
static uint64_t randomOddCounter();                   // 加密安全随机 62 位奇数（§2.5）
bool isIncomingAcceptable(DeviceID, uint64_t) const;  // 接收防重放「判定」（§2.6 第 3 步）
void commitIncoming(DeviceID, uint64_t);              // 接收防重放「提交」（§2.6 第 9 步，认证后）
void resetReplay(DeviceID deviceID);

signals:
    void stateChanged();
    void linkingConfirmed(DeviceID deviceID);
    void linkingFailed(DeviceID deviceID, const QString& error);
```

实现要点：
- `beginLinking()`：**先校验目标合法性**（`kInvalidDeviceID` 与签名位非法值拒绝），再置 `_activeDeviceID` + `_state=Linking`；密钥已缓存则立即 `confirmLinking()`，否则 `fetchKey()`；
- `_onKeyFetched()`：状态仍为 Linking 且目标一致时 `confirmLinking()` → Active；`_onFetchFailed()` 有**同款守卫**——陈旧请求的失败不会误杀当前建链目标；
- `nextOutgoingCounter()`：`last` 为奇数取 `last+2`、偶数取 `last+1`；**首帧取加密安全随机 62 位奇数起点**（`randomOddCounter()`，`QRandomGenerator::system()` + 最低位置 1，规范 §2.5 防重启后 nonce 复用），并原子预留（更新 lastNonce）；
- `isIncomingAcceptable()` / `commitIncoming()`：**两阶段防重放**（协议 §2.6 第 3 步只判定、第 9 步认证通过后才更新 lastNonce），防止未认证的伪造帧（明文 counter 可伪造）污染重放窗口；
- `learnDeviceSystemMapping()`：维护 `_deviceToSystem` / `_systemToDevice` 双向映射（接收时由 MAVLinkProtocol 在取密钥前学习，见 §4.2）；
- `setGcsDeviceID()`：**拒绝签名位非法值**（规范 §1.4）；`state()`/`gcsDeviceID()` **加锁读取**（线程安全）。

### 3.6 `CryptoCodec.h/.cc`

帧级编解码，在字节层做标准帧 ↔ 加密帧转换，对 mavlink 库透明。

```cpp
constexpr size_t kV2HeaderLen = 10;   // magic+len+inc+com+seq+sys+comp+msgid(3)
constexpr size_t kCrcLen = 2;

bool encryptFrame(const uint8_t* plainFrame, int plainLen, uint8_t crcExtra, DeviceID gcsDeviceID,
                  uint64_t counter, const Key& key, uint8_t* encFrame, int* encLen);
bool decryptFrame(const uint8_t* encFrame, int encLen, uint8_t crcExtra, const Key& key,
                  DeviceID* outDeviceID, uint64_t* outCounter, uint8_t* plainFrame, int* plainLen);

DeviceID deviceIDFromFrame(const uint8_t* encFrame);   // 不解密，从帧头重组
uint32_t msgidFromFrame(const uint8_t* encFrame);      // 3 字节小端
uint8_t frameLength(const uint8_t* encFrame);          // 读 len 字段
uint64_t counterFromFrame(const uint8_t* encFrame);    // 读 payload 前 8 字节大端
```

帧格式：

```
标准帧:  magic(1) len(1) incompat(1) compat(1) seq(1) sysid(1) compid(1) msgid(3) payload(len) CRC(2)
加密帧:  magic(1) len'(1) inc(1)    com(1)    seq(1) sys(1)  comp(1)  msgid(3) [counter(8)+ciphertext(N)+tag(16)] CRC(2)
```

- `inc/com/sys/comp` = deviceID 的 4 字节（大端），`len' = N + 24`；
- **CRC 重算**：复用 mavlink 库的 `crc_init` / `crc_accumulate` / `crc_accumulate_buffer` / `crc_extra`，
  范围 = 帧头（从 len 起 9 字节）+ payload block + `crc_extra`；
- **边界防御**（PR 修复）：
  - `encryptFrame` 拒绝过短标准帧、**零长度 payload**（规范 §2.2）、**签名位非法的 deviceID**（规范 §1.4）；
  - `decryptFrame` 校验 `payload block >= 28`（防 `uint16` 下溢/栈越界）与输入长度完整覆盖帧头 + payload block + CRC（防截断帧越界）；
- **超限退化**（规范 §2.3，PR 修复）：`8(counter)+4(deviceID)+payload+16(tag) > 255`（payload > 227）时，
  明文退化为仅 `deviceID(4B)`，payload block = 28 字节照发（维持链路时序与 nonce 序列），并记录日志；接收方还原帧 payload 为空 → 丢弃消息；
- `decryptFrame` 解密后做**密钥绑定**（明文内嵌 deviceID == 帧头 deviceID），不匹配返回 `false`；
- 解密还原标准帧时 `incompat/compat` 清零、`sysid/compid` 从 deviceID 还原（原标准帧的 incompat/compat 信息在加密时已被 deviceID 的 inc/com 字节覆盖，无法还原，对不使用签名机制的 V2 标准消息无影响）。

### 3.7 `CMakeLists.txt`

```cmake
target_sources(${CMAKE_PROJECT_NAME} PRIVATE <7 个组件文件>)
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

if(ANDROID)
    # 复用 cmake/modules/AndroidOpenSSL.cmake 的 add_android_openssl_libraries 链接
    target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE "${android_openssl_SOURCE_DIR}/ssl_3/include")
else()
    # 桌面：系统 OpenSSL，直接链接 OPENSSL_CRYPTO_LIBRARY 文件路径
    find_package(OpenSSL REQUIRED)
    target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${OPENSSL_INCLUDE_DIR})
    target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE ${OPENSSL_CRYPTO_LIBRARY})
endif()
```

> 说明：直接链接 `OPENSSL_CRYPTO_LIBRARY` 文件路径而非 imported target `OpenSSL::Crypto`，
> 以避开 `qt_generate_deploy_qml_app_script` 对 imported target 的 `TARGET_LINKER_FILE` 展开失败。

---

## 4. 修改的现有文件（接线）

### 4.1 `src/Comms/LinkInterface.cc` — 发送加密

`sendMessageThreadSafe()` 在序列化标准帧后插入加密分支：

```cpp
uint8_t buffer[MAVLINK_MAX_PACKET_LEN];
const int len = mavlink_msg_to_send_buffer(buffer, &message);

MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
if (crypto->cryptoEnabled()) {
    if (crypto->state() != State::Active) {
        qCWarning(...) << "crypto enabled, link not Active, dropping msgid" << message.msgid;
        return;                                  // 绝不发明文
    }
    MAVLinkCrypto::Key key; uint64_t counter = 0;
    if (crypto->activeKey(key) && crypto->nextOutgoingCounter(counter)) {
        const uint8_t crcExtra = mavlink_get_crc_extra(&message);
        uint8_t encBuffer[MAVLINK_MAX_PACKET_LEN + 32]; int encLen = 0;
        if (MAVLinkCrypto::encryptFrame(buffer, len, crcExtra, crypto->activeDeviceID(),
                                        counter, key, encBuffer, &encLen)) {
            writeBytesThreadSafe((const char*)encBuffer, encLen);
            return;
        }
        qCWarning(...) << "encryptFrame failed for msgid" << message.msgid;
        return;                                  // 丢弃帧，不回退明文
    }
    qCWarning(...) << "crypto active but no key/counter, dropping msgid" << message.msgid;
    return;
}
writeBytesThreadSafe((const char*)buffer, len);  // 仅 cryptoEnabled=false 时走明文
```

- **帧头 deviceID 用 `activeDeviceID()`（目标无人机），而非 GCS 自身**（PR 修复 C1）——接收方 PX4 按帧头重组 deviceID 查自己的密钥，用 GCS 的 ID 会导致查无密钥而丢弃；
- 仅 **Active 状态**加密发送；**加密已启用但未 Active（Standby/Linking）一律丢弃**（不发明文，避免明文降级 / 必丢）；
- **加密失败丢弃帧**并记录日志，**不回退明文**（PR 修复 C6）。

### 4.2 `src/Comms/MAVLinkProtocol.cc/.h` — 接收解密

`receiveBytes()` 开头路由：

```cpp
if (MAVLinkCrypto::CryptoController::instance()->cryptoEnabled()) {
    _receiveEncryptedBytes(link, linkPtr, data);
    return;
}
```

新增两个私有方法 + 一个 per-channel 缓冲：

- `_receiveEncryptedBytes()`：按 channel 累积字节到 `_cryptoRxBuffer[channel]`，流式重组完整帧（magic `0xFD` 同步 + len 字段定长），按 `msgidFromFrame` 分流——
  - **明文特例：待命心跳（msgID=0）**（规范 §2.2）：不加密、无 counter/tag，`learnDeviceSystemMapping` 学习 deviceID↔sysid 后直接喂 `_feedStandardFrame()`（标准解析器），识别在线/待命；
  - 其余帧 → `_processEncryptedFrame()` 走解密；
- `_feedStandardFrame()`：把一段标准 MAVLink 帧字节逐字节喂 `mavlink_parse_char` 并走常规处理（计数/转发/日志/状态更新），供「解密还原帧」与「明文待命心跳」两处复用；
- `_processEncryptedFrame()`：严格执行规范 §2.6 流程（PR 修复后）——
  1. 长度检查（payload block ≥ 28）
  2. `deviceIDFromFrame` 重组 deviceID、`counterFromFrame` 读 counter
  3. **`learnDeviceSystemMapping` 学习 deviceID↔systemID**（明文帧头即可得；在取密钥前，打破全新启动死锁，PR 修复 C4）
  4. `crypto->isIncomingAcceptable(deviceID, counter)` 防重放**判定**（§2.6 第 3 步，不更新 lastNonce）
  5. `keyForDevice` 取密钥（查无 → **打日志**丢弃）
  6. `msgidFromFrame` + `mavlink_get_msg_entry` 查 crc_extra（未知 msgid → 打日志丢弃）
  7. `decryptFrame` 解密 + 密钥绑定（失败 → 打日志丢弃）
  8. **`crypto->commitIncoming(deviceID, counter)`** 防重放**提交**（§2.6 第 9 步，认证通过后才更新 lastNonce，PR 修复 C2）
  9. 空 payload 退化帧（`plainFrame[1] == 0`）→ 丢弃消息（§2.3/§2.6 第 10 步）
  10. 还原的标准帧逐字节喂 `mavlink_parse_char`，复用原有消息处理（计数/转发/日志/状态更新）

头文件新增：

```cpp
void _receiveEncryptedBytes(LinkInterface*, const SharedLinkInterfacePtr&, const QByteArray&);
void _processEncryptedFrame(LinkInterface*, const SharedLinkInterfacePtr&, uint8_t channel, const QByteArray&);
void _feedStandardFrame(LinkInterface*, const SharedLinkInterfacePtr&, uint8_t channel, const uint8_t* bytes, int len);
QByteArray _cryptoRxBuffer[MAVLINK_COMM_NUM_BUFFERS];
```

### 4.3 `src/MissionManager/MissionController.cc` — 建链触发 + 等待

`sendToVehicle()`（确定航线 + 选定无人机、开始下发任务时）触发建链（PR 修复 C5）：

```cpp
MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
if (crypto->cryptoEnabled()) {
    crypto->beginLinkingForSystemID(static_cast<uint8_t>(_managerVehicle->id()));
    if (crypto->state() == State::Linking) {
        // 建链异步进行中（密钥未缓存）：挂起本次上传，等 linkingConfirmed 后由 _onLinkingConfirmed 补发。
        // 直接发送会产生明文帧（未 Active）→ 接收端丢弃 → 首次航线上传必丢。
        _pendingCryptoUpload = true;
        connect(crypto, &CryptoController::linkingConfirmed, this, &_onLinkingConfirmed);  // 一次性
        connect(crypto, &CryptoController::linkingFailed,    this, &_onLinkingFailed);
        return;
    }
    if (crypto->state() != State::Active) {
        qCWarning(...) << "no device mapping, abort plan upload";  // Standby：映射未知
        return;
    }
    // Active：直接发送
}
_sendPlanItemsToVehicle();
```

- 发送主体抽为 `_sendPlanItemsToVehicle()`；`_onLinkingConfirmed` 在建链成功后补发挂起的上传；
- `_onLinkingFailed` 记录告警（不再静默）；映射未知（Standby）放弃上传并告警。

### 4.4 `src/QGCApplication.cc` — 配置注入

`init()` 中把 CryptoSettings 值注入 CryptoController：

```cpp
CryptoSettings* const cryptoSettings = SettingsManager::instance()->cryptoSettings();
MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
crypto->setCryptoEnabled(cryptoSettings->cryptoEnabled()->rawValue().toBool());
crypto->setGcsDeviceID((DeviceID)cryptoSettings->cryptoGcsDeviceID()->rawValue().toUInt());
crypto->deviceKeyManager()->setServerUrl(cryptoSettings->cryptoGcsServerUrl()->rawValue().toString());
crypto->deviceKeyManager()->setAuthToken(cryptoSettings->cryptoAuthToken()->rawValue().toString());
```

> ⚠️ 本文件同时混入了两处**非加密**改动，详见 §9。

### 4.5 `src/Settings/SettingsManager.h/.cc` + `CMakeLists.txt` — 设置注册

- 头文件：前置声明 `CryptoSettings`、`Q_MOC_INCLUDE`、`Q_PROPERTY(cryptoSettings)`、getter、成员指针；
- `.cc`：`init()` 中 `new CryptoSettings(this)`，新增 `cryptoSettings()` getter；
- `CMakeLists.txt`：`target_sources` 加入 `CryptoSettings.cc/.h`。

### 4.6 `src/MAVLink/CMakeLists.txt` — 模块注册 + parser 补丁

- 末尾新增 `add_subdirectory(Crypto)`。
- 新增 `patch_mavlink_parser` 自定义目标：构建期运行 `tools/generators/patch_mavlink_parser.py`，去掉生成头 `mavlink_helpers.h` 里 `MAVLINK_PARSE_STATE_GOT_LENGTH` 分支对 `incompat_flags & ~MAVLINK_IFLAG_MASK` 的拒绝检查（规范 §1.5）。保持 QGC 仍 pin 上游 mavlink commit，不换 fork；补丁幂等，每次构建在 mavgen 之后、QGC 编译之前执行。

---

## 5. 新增设置：`CryptoSettings`

文件：`src/Settings/Crypto.SettingsGroup.json`（元数据）+ `CryptoSettings.h/.cc`（类）。

| 设置项 | 类型 | 默认 | 说明 |
|--------|------|------|------|
| `cryptoEnabled` | bool | `false` | 启用加密 MAVLink 链路（启用后接收端仅放行明文待命心跳 msgID=0，其余明文帧一律丢弃；发送端仅在 Active 状态加密，其余状态丢弃） |
| `cryptoGcsServerUrl` | string | `""` | gcs_server 地址（提供设备密钥） |
| `cryptoAuthToken` | string | `""` | 取密钥时的 Bearer 认证 token |
| `cryptoGcsDeviceID` | uint32 | `0` | 本地面站自身的 32 位 deviceID（写入帧头） |

---

## 6. 数据流

### 6.1 发送（QGC → 无人机）

```
Vehicle/MissionController 下发消息
  → LinkInterface::sendMessageThreadSafe(message)
  → mavlink_msg_to_send_buffer 序列化标准帧
  → [cryptoEnabled]
       [非 Active] → 丢弃（记录告警）
       activeKey(key) 取目标密钥
       nextOutgoingCounter(counter) 取奇数 counter
       encryptFrame(...)   deviceID(目标无人机)拆入帧头 + payload AES-GCM + CRC 重算
       writeBytesThreadSafe(加密帧)
  → [cryptoEnabled=false] 明文发送
```

### 6.2 接收（无人机 → QGC）

```
LinkInterface 收到字节
  → MAVLinkProtocol::receiveBytes
  → [cryptoEnabled] _receiveEncryptedBytes
       按 channel 累积，流式重组完整加密帧
  → _processEncryptedFrame
       长度检查 → 重组 deviceID/读 counter → 防重放 → 取密钥
       → decryptFrame（解密 + 密钥绑定）→ learnDeviceSystemMapping
       → 还原标准帧逐字节喂 mavlink_parse_char → 复用常规处理
```

### 6.3 握手时序

```
PX4 ──明文 HEARTBEAT（msgID=0，无 counter/tag）──▶ QGC（Standby，从帧头 deviceID 识别在线，不回应）
QGC 确定任务 → MissionController::sendToVehicle
  → beginLinkingForSystemID(vehicleId)
  → fetchKey(deviceID) ──HTTPS GET──▶ gcs_server
  ◀── key（base64）──
  → keyFetched → confirmLinking → Active（奇数 counter 下发指令）
```

---

## 7. 单元测试：`CryptoTest`

文件：`test/MAVLink/CryptoTest.cc/.h`，注册于 `test/MAVLink/CMakeLists.txt`
（`add_qgc_test(CryptoTest LABELS Unit MAVLink)`），`UT_REGISTER_TEST_LIGHTWEIGHT(CryptoTest, TestLabel::Unit)`。

| 测试 | 覆盖 |
|------|------|
| `_testDeviceIDEncodeDecode` | deviceID 编码/解码位操作 |
| `_testDeviceIDSignatureBit` | incompatFlag bit0 约束校验 |
| `_testDeviceIDMessageRoundTrip` | `mavlink_message_t` ↔ deviceID 互转 |
| `_testCryptoRoundTrip` | AES-GCM 加解密往返 |
| `_testCryptoWrongKey` | 错误密钥解密失败 |
| `_testReplayGuard` | 防重放（递增接受/重放乱序拒绝/重置） |
| `_testReplayGuardTwoPhase` | 两阶段防重放（判定不推进、commit 后才推进） |
| `_testCodecRoundTrip` | 标准帧 ↔ 加密帧往返（含帧头 deviceID/counter/msgid 校验） |
| `_testCodecWrongKey` | 错误密钥解密失败 |
| `_testCodecMalformedFrame` | 畸形/截断/过短帧拒绝；零长度 payload、签名位非法 deviceID 拒绝 |
| `_testCodecHeaderTamper` | 帧头 deviceID 篡改 → nonce 变化 + 密钥绑定失败拒绝 |
| `_testCodecOverflowDegrade` | 超限 payload（>227）→ 退化帧（payload block = 28），还原帧 payload 为空 |
| `_testCryptoEmptyPlaintext` | 空明文（退化帧）加解密往返 |
| `_testParserAcceptsHighDeviceID` | parser 放行 deviceID 高字节复用 incompat_flags（bit1~7，规范 §1.4/§1.5） |
| `_testParserSignedFlagPreserved` | bit0（SIGNED）置位 → 进入 SIGNATURE_WAIT（补丁不得破坏 SIGNED 判定） |
| `_testParserRejectsBadCrc` | incompat 置位 + 坏 CRC → BAD_CRC（补丁不得旁路完整性校验） |
| `_testRandomOddCounter` | counter 起点为 62 位奇数（规范 §2.5 防重启 nonce 复用） |
| `_testNextOutgoingCounter` | `nextOutgoingCounter` 端到端：首帧随机奇数、后续 +2、非 Active 拒绝 |

运行：`./build/Debug/QGroundControl --unittest:CryptoTest` → **20 passed, 0 failed**（18 项测试 + init/cleanup）。

---

## 8. 构建集成与平台差异

- **桌面（Linux/macOS/Windows）**：`find_package(OpenSSL REQUIRED)`，链接系统 `libcrypto`；
- **Android**：复用 `cmake/modules/AndroidOpenSSL.cmake` 的 `add_android_openssl_libraries(${CMAKE_PROJECT_NAME})`
  （在顶层 `include(Android)` 时已统一链接 `libssl_3.so`/`libcrypto_3.so`），仅需补齐头文件路径
  `${android_openssl_SOURCE_DIR}/ssl_3/include`；
- Crypto 模块通过 `target_sources(${CMAKE_PROJECT_NAME} ...)` 把源文件加进 QGC 主 target（非独立库），
  与 `add_android_openssl_libraries` 的链接自然合并。

---

## 9. 附带的非加密改动（注意事项）

`src/QGCApplication.cc` 在本次加密提交中，还混入了两处**与加密无关**的改动（因同文件一并 `git add`）：

1. **应用名品牌化**（`#ifdef QGC_DAILY_BUILD` 分支）：
   ```cpp
   - applicationName = QStringLiteral("%1 Daily").arg(QGC_APP_NAME);
   + applicationName = QStringLiteral("ABC 地面站");
   ```
2. **强制中文界面**（`setLanguage()`）：
   ```cpp
   - _locale = QLocale::system();
   + _locale = QLocale(QLocale::Chinese, QLocale::China);  // 强制中文界面
   ```

> 若希望加密提交「纯净」，可将这两处从 commit `11e0ad1ac` 中拆出，作为独立提交。

---

## 10. 待办与后续

### 已修复（PR 审查后）

- ✅ **C1** 上行指令帧 deviceID 用错 → `LinkInterface` 改用目标无人机 `activeDeviceID()`
- ✅ **C2** 防重放 lastNonce 在认证前推进 → `ReplayGuard` 两阶段（`isAcceptable`/`commit`），接收侧认证通过后才提交
- ✅ **C3** 畸形帧长度下溢/越界 → `CryptoCodec` 边界防御（payload block ≥ 28、输入长度完整）
- ✅ **C4** 全新启动死锁 → 映射学习移到取密钥前（明文帧头可得）+ 无密钥/解密失败丢弃打日志
- ✅ **C5** 首次航线竞态 → `MissionController` 建链完成后再补发航线上传
- ✅ **C6** 加密失败回退明文 → 一律丢弃并告警，仅 `cryptoEnabled=false` 走明文
- ✅ **Important** `_onFetchFailed` 守卫、`state()`/`gcsDeviceID()` 加锁、`beginLinking`/`setGcsDeviceID` 目标合法性校验、`encryptFrame` 签名位检查、规范 §2.3 超限退化帧
- ✅ 单测 8 → **13 项**（新增两阶段防重放、畸形帧、帧头篡改、超限退化、空明文）

### 已修复（deviceID ↔ incompat_flags 冲突，见 `docs/11_deviceID与incompat_flags冲突说明.md`）

- ✅ **parser 放行 incompat bit1~7**：标准 parser 把 `incompat_flags` 的 bit1~7 当作「未知保留标志」拒绝整帧，导致 deviceID ≥ `0x01000000` 的链路双向静默全断 → 构建期补丁 `tools/generators/patch_mavlink_parser.py` 去掉 `incompat_flags & ~MAVLINK_IFLAG_MASK` 拒绝检查（规范 §1.4/§1.5），deviceID 恢复 31 位可用
- ✅ 单测 13 → **16 项**（新增 `_testParserAcceptsHighDeviceID` / `_testParserSignedFlagPreserved` / `_testParserRejectsBadCrc`：放行 incompat = 0x02/0x12/0xFE、SIGNED 位进入 SIGNATURE_WAIT、坏 CRC 判 BAD_CRC）

### 已修复（同步 60816.1 规范）

- ✅ **明文待命心跳接收**：PX4 待命心跳改为**明文 HEARTBEAT（msgID=0，无 counter/tag）**（规范 §2.2），`MAVLinkProtocol` 接收路径按 `msgidFromFrame` 分流——msgID=0 走标准解析器识别在线，其余走解密；抽出 `_feedStandardFrame()` 复用常规处理
- ✅ **counter 随机 62 位奇数起点**：`CryptoController::nextOutgoingCounter` 建链首帧从「1」改为 `randomOddCounter()`（`QRandomGenerator::system()` + 最低位置 1，规范 §2.5 防重启后 nonce 复用）
- ✅ **VTOL 扩展消息 ID 重编号**：`51000-51003` → `80000-80003`（避开 mavlink vendor 范围 50000-60099，规范 `mavlink_extension_protocol.md`）
- ✅ 单测 16 → **18 项**（新增 `_testRandomOddCounter` / `_testNextOutgoingCounter`）
- ✅ **明文心跳分流加长度判据**：msgid=0 且 payload block < 28 才走明文分支，避免建链后加密 HEARTBEAT（msgID=0、payload≥28）被误判为明文、密文被解析成垃圾心跳值
- ✅ **counter 越界守卫**：`nextOutgoingCounter` 达 `COUNTER_MAX=2^62` 时拒绝发送（需重新建链换密钥，规范 §2.5）
- ✅ **短帧丢弃打日志**：`_processEncryptedFrame` 的 `<28` 畸形帧丢弃补 `qCWarning`（含 len/msgid/deviceID）

### 仍待办

- [ ] **mavp2p / PX4 联合测试**：端到端加密互通验证（需实机或模拟链路）；
- [ ] **Android 实机验证**：Android 构建产物尚未端到端运行验证（OpenSSL 复用已接线，但未在真机/模拟器跑通加密收发）；
- [ ] **密钥存储加固**：规范 §2.7.1 已标注「开发阶段明码存储」，正式部署前需改为加密存储；
- [ ] **密钥轮换**：规范 §2.7.1 标注「待设计」，QGC 侧当前无轮换流程；
- [ ] **加密帧 CRC 接收端未校验**：解密路径（`_processEncryptedFrame` / `decryptFrame`）未读取并校验加密帧末尾的 2 字节 CRC。GCM tag 仅认证 `counter`（AAD）+ `ciphertext`，**不认证帧头字段**（`len`/`seq`/`msgid`/deviceID）。帧头受传输噪声破坏时不会被 GCM 检测，只能靠 CRC，而当前该 CRC 未在接收端验证（规范 §2.1 已声明帧头不在认证范围，需业务层防范——此项为待补强点）；
- [ ] **建链语义核对**：当前把「gcs_server 取密钥成功」视为建链确认；60816.1 §2.5 下 QGC 以首个加密帧携带随机 62 位奇数 X 建链、PX4 收到后据此初始化下行 lastNonce，无需显式确认——需核对 QGC 首个加密帧的发送时机是否满足该语义。
