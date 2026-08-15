# MAVLink 改造公共规范：32 位 deviceID 与 payload 加密

> 本文档是 **mavp2p 工程（本仓库）、PX4 固件工程、QGC 地面站工程** 共同遵守的协议规范与改造蓝本。
> 目的：把「MAVLink 帧头 deviceID 升级为 4 字节」与「MAVLink payload 字段加密」这两项改造，作为**一份统一、无异议的协议约定**固化下来，供各工程独立实现时对照。
> 约定：本文档**只表述协议约定与各组成部分必须满足的行为契约，不涉及任何一方如何实现**。各工程实现细节由其自身决定。
> 状态：方案已论证（见 `05_32位系统ID方案论证.md`、`06_MAVLink协议格式与调整方案.md`），本文档为公共蓝本。
>
> **覆盖声明**：本文档在 §2.5 用「**单密钥 + 奇偶分家（PX4 偶数 / QGC 奇数）+ 按需建链 + `本次 > lastNonce` 判定**」**取代** 06 文档第三部分的「GPS 单调计数器 + `counter > lastSeen` 判定」及本文档早前草稿的「+10 / +1 步长」「待命心跳 counter=0」。其余协议要素（deviceID 字节重组、AES-256-GCM、payload block 结构、密钥管理、组件职责）与 05/06 一致。**实现时以本文档为准，勿再对照 06 的 counter 方案。** 另：06 §2.6 的"外部标准明文设备放行"路径与本文档"明文帧一律丢弃"冲突——本协议为加密私有链路，**外部明文设备路径在本链路内废除**（如需兼容外部设备，另行约定旁路，不在本协议范围）。

---

# 第一部分：32 位设备标识（deviceID）

## 1.1 动机与目标

MAVLink V2 帧头中 `systemID` 仅 1 字节（0~255），不足以支撑多租户 SaaS 场景下数千架无人机的全局唯一标识。改造目标：**每架无人机拥有一个全局唯一的 32 位设备标识（deviceID），该标识直接编入 MAVLink 帧头**，作为链路路由、遥测归属、密钥取用的统一依据。

## 1.2 帧头字节重组

**唯一改动**：将 MAVLink V2 帧头的 4 个单字节字段——`incompatFlag`（偏移 2）、`compatFlag`（偏移 3）、`systemID`（偏移 5）、`componentID`（偏移 6）——合并解读为一个 **32 位无符号整型 deviceID**。

```
帧头字节偏移:   2         3         5         6
             ┌─────────┬─────────┬─────────┬─────────┐
             │ inc(1B) │ com(1B) │ sys(1B) │ comp(1B)│
             └─────────┴─────────┴─────────┴─────────┘
             ◄─────────── 本系统解读：deviceID ──────────►
                      （uint32，4 字节，大端组装）
```

**编码公式**（发送方写入帧头）：

```
deviceID = (inc << 24) | (com << 16) | (sys << 8) | comp
```

**解码公式**（接收方从帧头重组）：

```
inc  = (deviceID >> 24) & 0xFF
com  = (deviceID >> 16) & 0xFF
sys  = (deviceID >> 8)  & 0xFF
comp =  deviceID        & 0xFF
```

**示例**：`deviceID = 0x00010203` → 帧头 4 字节分别为 `0x00, 0x01, 0x02, 0x03`。

## 1.3 deviceID 的语义与来源

- **deviceID 是一个纯 32 位长整数，不对字节做分层含义定义**（哪段是租户、哪段是站点，由数据库表决定，帧内无分层语义）。
- **出厂预置**：无人机出厂烧录固件时线下写入全局唯一的 deviceID（类比 MAC 地址），避免线上分配。
- **入网登记**：deviceID 写入 `table_uav.device_id` 字段（BIGINT），并登记对应的 AES-256 通信密钥（见第二部分）。
- **1 字节 systemID 被取代**：`mav_sys_id` 不再作为独立设备标识字段。按 1.2 编码公式，systemID 占 deviceID 的第 3 字节（bit 8~15），**deviceID 的低 8 位是 componentID**；二者均无独立语义。

## 1.4 协议约束

- **deviceID 第 3 字节（帧头 incompatFlag）的 bit0 必须为 0**（等价 `deviceID & 0x01000000 == 0`）。原因是 MAVLink 标准解析器以 `incompatFlag & 0x01` 判断"帧带签名"并读取 13 字节签名；只要 bit0 置位（0x01、0x03、0x05…任一奇数）就会误判。本方案不使用签名机制，此约束确保任何一方（包括标准 MAVLink 解析器）都不会误判帧格式。
- **incompatFlag 的 bit1~7（deviceID bit25~31）必须由各组件 parser 放行**。MAVLink 标准 parser 会把 bit1~7 当作"必须理解但未知的保留标志"而拒绝整帧（`incompatFlag & ~0x01 != 0` 即丢帧）。各组件（PX4/QGC/mavp2p/data_writer）**必须去掉这一拒绝检查**（见 §1.5），否则 deviceID 只能用到低 24 位。放行后 deviceID 可用 **31 位**（bit24 恒 0，其余 31 位任意）。
- **帧头其余字段不变**：`magic`（0xFD）、`len`、`seq`、`msgID`、payload、CRC 仍按 MAVLink V2 标准处理。
- **CRC 计算范围不变**：仍覆盖帧头 + payload block，作为传输层校验。

## 1.5 MAVLink parser 修改约定（各组件必须同步）

deviceID 的 bit25~31 复用 `incompatFlag` 字节的 bit1~7，而 MAVLink 标准 parser 会拒绝这些位（见 §1.4）。各组件必须修改其 MAVLink C 库的 parser，去掉 `incompat_flags & ~MAVLINK_IFLAG_MASK` 的拒绝检查（保留 bit0 的 SIGNED 判定），否则会拒绝 deviceID ≥ `0x01000000` 的帧。

**PX4 侧修改位置（本仓库）**：

- `pymavlink` submodule（`src/modules/mavlink/mavlink/pymavlink`）：
  - 文件：`generator/C/include_v2.0/mavlink_helpers.h`
  - 修改：`mavlink_frame_char_buffer()` 的 `MAVLINK_PARSE_STATE_GOT_LENGTH` 分支，去掉 `if ((rxmsg->incompat_flags & ~MAVLINK_IFLAG_MASK) != 0) { ... }` 拒绝块。
  - fork 与分支：`wangwumu/pymavlink`，分支 `deviceid-incompat-flags`。
- `mavlink` submodule（`src/modules/mavlink/mavlink`）：
  - 修改：更新其内 `pymavlink` 子模块指针，指向上述 fork 分支的 commit。
  - fork 与分支：`wangwumu/mavlink`，分支 `deviceid-incompat-flags`。

**其他组件（QGC / mavp2p / data_writer）**：各自 fork 其 MAVLink 库，做同样的 parser 修改（去掉 `incompat_flags & ~MAVLINK_IFLAG_MASK` 拒绝检查）。

---

# 第二部分：payload 字段加密

## 2.1 安全模型

对 MAVLink 帧的 **payload 部分**做密码学加密，同时实现三项安全属性：

| 安全属性 | 机制 | 说明 |
|---------|------|------|
| 保密性 | AES-256-GCM 加密 | payload 内容不可被窃听者读取 |
| 完整性 | GCM 认证标签（tag） | 篡改 payload（ciphertext 或明文 counter）任意 1 bit → tag 校验失败 → 帧丢弃。**注：仅 payload 部分受密码学认证；帧头字段（msgID/len/seq）不在认证范围，篡改帧头 msgID 会导致消息被按错误类型解析，需业务层防范** |
| 防重放 | 全局单调递增 nonce + `本次 > lastNonce` 判定 | 重放任意旧帧 → nonce ≤ lastNonce → 丢弃 |

## 2.2 算法与范围

- **算法**：AES-256-GCM（Galois/Counter Mode），密钥 256 位（32 字节）。
- **密钥**：每台设备**一把**通信密钥，PX4 与 QGC 双向共用（见 2.7）。
- **范围**：仅加密 **payload** 部分。帧头（含 deviceID）**保持明文**——路由、设备识别、nonce 构造、密钥绑定均依赖明文帧头。
- **CRC 保留**：CRC 计算覆盖整个加密后的 payload block，作为传输层（噪声/丢包）校验，与 GCM 认证标签（防篡改/伪造）互补。
- **全加密前提（含待命心跳）**：本协议假设**升级组件（PX4、mavp2p、QGC、data_writer）之间所有帧均为加密帧，包括待命心跳**——不设明文特例，统一处理。接收方收到**非加密帧**（明文 payload）一律丢弃并记录日志。
  > **在线状态公开可见**：帧头 deviceID 为明文，任何观察者（QGC、mavp2p、gcs_server）无需解密即可感知"某 deviceID 在发帧（在线）"；payload 内的状态/位置等为密文，需密钥解密。**待命/心跳用标准 HEARTBEAT（msgID=0）承载**，识别靠解密后的 msgID。
- **零长度消息禁止**：加密明文 = `deviceID(4B) || 原始消息 payload`，且 **原始消息 payload 长度必须 ≥ 1 字节**——避免与"超限退化帧"（明文仅 deviceID、payload 为空，见 2.3）在接收端形态相同而无法区分。任何一方不得发送 payload 为空的合法消息。
  > **链路范围边界**：本协议适用于**升级组件之间经 mavp2p 的链路**。数传直连链路（PX4 TELEM1 ↔ GCS，应急/监控旁路）是否纳入本加密方案，或作为独立明文旁路，**需另行约定**，不在本协议范围。
  > **当前约定（PX4 实现）**：PX4 侧不提供 per-link opt-out，**所有 MAVLink 实例（TELEM1 / TELEM2 / USB 等）统一加密，明文帧一律丢弃**——即 TELEM1 直连也纳入加密，不保留明文旁路。若后续需要明文应急旁路，需新增参数（按实例指定加密开关）。

## 2.3 加密后的 payload block 结构

```
┌───────────────┬─────────────────────────────┬──────────┐
│  counter(8B)  │  ciphertext(NB)             │  tag(16B)│
│   明文         │   AES-256-GCM 密文           │  认证标签  │
└───────────────┴─────────────────────────────┴──────────┘
```

| 字段 | 长度 | 传输方式 | 作用 |
|------|------|---------|------|
| counter | 8 字节 | 明文 | 每帧唯一：**PX4 用偶数、QGC 用奇数**，各自单调递增、奇偶不相交 → 全局不碰撞；作为 GCM 的 **AAD**（附加认证数据），被篡改则 tag 校验失败；接收方据此做防重放检测并构造 nonce |
| ciphertext | N 字节 | 密文 | 加密后的明文内容，与明文等长 |
| tag | 16 字节 | 附带 | GCM 认证标签，密码学完整性校验 |

**长度计算**：

```
len(payload block) = 8(counter) + N(ciphertext) + 16(tag) = N + 24
N = 4(deviceID) + 原始 MAVLink 消息 payload 长度
```

**超限检查与处理（各组包方强制约定）**：

payload block 受 MAVLink `len` 字段上限 **255 字节**约束，即 `N + 24 ≤ 255`、原始消息 payload ≤ 227 字节。由于本系统自身已对 MAVLink 协议做了扩展，且未来协议仍可能继续扩展，**不能保证任何消息加密后都不超过 255**。因此每个组包方（PX4 发遥测、QGC 发指令）在加密**前**必须检查：

```
8(counter) + 4(deviceID) + 原始消息 payload 长度 + 16(tag) ≤ 255
```

- **未超限**：正常组装、加密、发送。
- **超限**：
  1. **本地写入日志**（记录消息类型 msgID、原始长度、超限量，供排查）；
  2. **报文照发**，但加密明文退化为仅 `deviceID(4B)`，消息 payload 部分为空（ciphertext = 4 字节，payload block = 8+4+16 = 28 字节）；
  3. 接收方解密后得到空消息，**丢弃该消息**（帧本身已通过认证，仅无有效内容）。

> 超限帧照发的目的：**维持链路时序与 nonce 序列连续**（见 2.5），避免因丢弃导致接收方状态错乱；同时不阻塞后续正常帧。超限只影响该条消息本身。

## 2.4 加密前明文结构

```
┌──────────────┬──────────────────────────────┐
│ deviceID(4B) │  原始 MAVLink 消息 (变长)      │
│  设备标识     │  按 msgID 标准格式序列化        │
└──────────────┴──────────────────────────────┘
```

- **明文 = deviceID(4B) || 原始 MAVLink payload**。
- 明文内嵌 deviceID 用于**密钥绑定**：解密后与帧头重组出的 deviceID 比对，防止"攻击者用自己的密钥加密后冒充他人设备"（见 2.6 安全分析）。
- **明文内不冗余存放时间戳**：防重放直接使用明文 counter，counter 已作为 GCM AAD 被认证，无需在密文中重复。
- **超限退化**：当原始消息超限时（见 2.3），明文退化为仅 `deviceID(4B)`（payload 为空），仅用于维持时序，不含有效消息。

## 2.5 nonce 构造、唯一性与防重放

**nonce 构造（加密方与解密方一致）**：

```
nonce = counter(8B) || deviceID(4B)   // 共 12 字节，标准 GCM nonce 长度
counter 以 8 字节大端序写入 payload block 前 8 字节
```

- 无人机侧：`counter` 为每帧唯一的值（来源规则见下）；`deviceID` 为自身设备标识。
- 接收方侧：`counter` 从 payload block 明文前 8 字节读取；`deviceID` 从帧头重组。

**单密钥 + 奇偶分家的全局 nonce 序列（协议硬性约束）**：

AES-GCM 在同一密钥下 nonce 绝不能重复，否则 keystream 泄露。系统对每台设备使用**一把通信密钥**，PX4 与 QGC 共用。为保证两端 nonce 永不碰撞，采用**奇偶分家**：

- **PX4 所有发送帧（含待命心跳、正常遥测）一律用偶数 counter**；
- **QGC 所有发送帧（含建链回应、正常指令）一律用奇数 counter**。

两端各自保证**本方向单调递增**；因奇偶不相交，两端 nonce 永不相等，天然满足 AES-GCM 同密钥 nonce 唯一。发送规则：**任一方向发送时，取"严格大于该 deviceID 全局 lastNonce 的最小本方向奇偶值"**（PX4 取偶数、QGC 取奇数）。

- **待命心跳**：PX4 上电后无论有无可靠时钟，一律发**加密待命心跳**，**counter 为偶数递增**（非固定 0，避免 GCM nonce 复用）。**待命心跳使用标准 HEARTBEAT 消息（msgID=0）**，与其他心跳无区别——payload 按标准 HEARTBEAT 序列化后加密，无需自定义消息。各 QGC 解密后（有密钥时）识别该无人机在线/待命，但**不回应与自己无关的心跳**；无任务时不响应、不发指令。
- **QGC 建链**：当某 QGC 确定航线并选定要执行的无人机时，经 gcs_server（HTTPS）获取该 deviceID 密钥，加密回传**奇数起点 X**（严格大于全局 lastNonce 的最小奇数）——该 QGC 成为此无人机的指令发送端。
- **PX4 建链**：收到 X 后更新全局 lastNonce = X，进入正常发送（后续遥测偶数递增）。
- **回到待命**：任务结束/链路断开后，PX4 回到待命（继续发加密心跳，偶数递增）。

> **多无人机 / 多 QGC**：每个 deviceID 的序列独立。同一 deviceID 的指令方向同一时刻只有一个发送端（发起任务的那个 QGC，奇偶分家保证其奇数序列与 PX4 偶数序列永不冲突）；其他 QGC 只读（可取密钥解密遥测、监控），但不得响应握手、不得发指令。mavp2p 按 deviceID 路由与边缘去重，不参与握手仲裁。
>
> **极小概率边界（不处理）**：接收方重启后 lastNonce 清零、以及极少数情况下新握手起点与历史序列重叠——这些属于极小概率事件，本协议不为其设计专门机制，视为已知残余风险。

**防重放判定（各端一致，按 deviceID 维护全局 lastNonce）**：

攻击者可截获整个报文、不解密直接复制重发。**每个接收方（PX4、QGC、mavp2p、data_writer）按 deviceID 维护全局 lastNonce**（初值 unset，首个合法帧即接受并登记），收到帧后：

```
本次 nonce > lastNonce[deviceID]  → 正常处理，并更新 lastNonce 为本帧
本次 nonce ≤ lastNonce[deviceID]  → 判定为重放/乱序，丢弃（不解密）
```

> 判定的核心是"**单调递增判定**"：全局序列严格递增（奇偶分家 + 双方各自递增保证），正常帧必然满足 `>`；攻击者重放任意**旧帧**（不只是紧邻上一帧）nonce 必然 `≤ lastNonce` → 被拦截。
>
> 乱序代价：网络重排导致 nonce 倒退的帧会被当作重放丢弃。对高频遥测可接受（丢帧无妨）；5G/串口链路通常保序，对关键指令风险低。如某链路确实存在乱序，接收方可维护"滑动窗口（最近 N 个已见 nonce）"，仅拒绝窗口内重复与 `≤ 窗口最小值` 的帧——这是可选增强，不改变基本判定。

**为什么 counter 用明文而非 hash(timestamp)**：
- 明文 counter 接收方（含不解密的 mavp2p）可直接从 payload 前 8 字节读取做防重放，无需解密；
- 避免"解密需要 nonce、nonce 在密文中"的循环依赖；
- counter 是 GCM AAD，被篡改会被 tag 检测，安全性与 hash 方案等价且实现简单。

## 2.6 接收方处理流程（协议约定）

接收方（解密方）对每个收到的加密帧，必须按序执行以下判定，任一步不满足即丢弃整帧：

```
0. 长度检查：payload block 长度 len < 28（8 counter + 4 deviceID + 16 tag 最小块）→ 丢弃（畸形帧）
1. 解析帧头，重组 deviceID₁（解码公式见 1.2）
2. 读取 payload block 前 8 字节 → counter（明文，大端序）
3. 防重放：若 lastNonce[deviceID₁] 未登记（unset，首帧）→ 通过；否则 counter ≤ lastNonce → 丢弃（重放/乱序帧，不解密）；counter > lastNonce → 通过
4. 构造 nonce = counter || deviceID₁（deviceID₁ 按 1.2 大端字节序）
5. 取该 deviceID 的通信密钥（见 2.7，经 gcs_server HTTPS）；查无密钥 → 丢弃（未登记设备）
6. AES-256-GCM 解密 + tag 校验 → 失败 → 丢弃（篡改/伪造帧）
7. 提取明文前 4 字节 → deviceID₂
8. 密钥绑定：deviceID₂ == deviceID₁？否 → 丢弃（密钥绑定失败）
9. 更新 lastNonce[deviceID₁] = counter（超限退化帧也更新，维持序列连续）
10. 取明文剩余部分，按 msgID 标准格式解析；若 payload 为空（超限退化帧）→ 丢弃该消息
```

## 2.7 密钥管理

| 环节 | 约定 |
|------|------|
| 密钥生成 | 制造/运维环节为每台设备生成**一把** 256 位随机密钥（32 字节） |
| 写入无人机 | 线下/工厂预置，烧录到无人机安全存储；**密钥不通过 MAVLink 链路传输** |
| 登记 | 通过 gcs_server 管理接口登记 deviceID ↔ key |
| 分发到 QGC | QGC 经 HTTPS/REST 向 gcs_server 获取该设备的通信密钥 key（解密遥测 + 加密指令）；**不走 MAVLink** |
| 存储 | 独立映射表 `table_device_key`（**device_id 为业务唯一键**、key、key_version、status、时间戳），密钥加密存储，不与业务表混用；是否另设自增 id 主键见 `01_requirements.md` §3.16 |
| 访问权限 | data_writer 与 QGC 可取 key（解密遥测）；QGC 另用 key 加密指令；mav_gateway 无任何密钥访问权 |
| 轮换 | 通过 NFC / Type-C 等非线上方式发起，用设备 `uid` 派生的密钥加密轮换请求报文，经线下通道交运维；云端用库中 uid 校验后**轮换该密钥**并递增 key_version |

**uid 信任根**：
- `table_uav.uid`（飞控芯片唯一标识，如 STM32 96-bit UID）作为密钥轮换的信任根；
- **uid 永不进入 MAVLink 帧**（协议层面禁止，任何组件不得解析/转发携带 uid 的消息）；
- 轮换密钥派生：`rotation_key = HKDF-SHA256(uid, salt=deviceID, info="key-rotation")` → 32 字节 AES-256 密钥，用于加密密钥更新报文。

### 2.7.1 实现状态

| 环节 | 状态 | 说明 |
|------|------|------|
| 密钥登记接口 | ✅ 已实现 | gcs_server `POST /api/device-keys`（校验 device 存在 + key 为 Base64/32 字节） |
| QGC 取密钥接口 | ✅ 已实现 | gcs_server `GET /api/device-keys/:deviceId`（HTTPS，登录鉴权） |
| 密钥列表/删除接口 | ✅ 已实现 | `GET /api/device-keys`、`DELETE /api/device-keys/:deviceId` |
| 密钥存储 | ⏳ **开发阶段明码存储** | 当前 `table_device_key.key` 裸存（Base64）；**正式部署（网络版）前必须改为加密存储**——需引入服务器级主密钥（保管方式待定：环境变量/配置文件/KMS）加密 key 列，取回时解密 |
| 密钥轮换接口 | ⏳ **待设计** | NFC/Type-C 线下轮换流程、`uid` 派生的 rotation_key 校验、`key_version` 递增、旧密钥转 REVOKED 过渡期——接口待设计实现 |
| 密钥自动注入无人机 | ⏳ 待实现 | 出厂预置流程与登记工具（线下/工厂环节） |

---

# 第三部分：各组成部分行为契约

以下列出 mavp2p 与各外部工程必须遵守的**协议行为**（不含实现）。每一方只需对照其职责列执行，无需关心其他方如何实现。

| 组成部分 | 所在工程 | 对 deviceID 改造的契约 | 对 payload 加密的契约 |
|---------|---------|----------------------|----------------------|
| **无人机飞控（PX4 固件）** | PX4 | ① 出厂写入全局唯一 deviceID；② 发送时按 1.2 编码公式把 deviceID 拆入帧头 4 字节；③ 遵守 1.4 约束（incompatFlag 高位 bit0 置位禁止） | ① **待命**：上电后一律发**加密 HEARTBEAT 待命心跳**，**counter 取偶数**递增，等待任务 QGC 建链；② **建链**：收到 QGC 回传的奇数 X 后更新全局 lastNonce = X，进入正常遥测（**counter 取 > lastNonce 的最小偶数**），组包前做超限检查（见 2.3）；③ 上行指令：用 key 解密（同 2.6 流程）；④ 维护该 deviceID 全局 lastNonce（含 QGC 指令），判重 `本次 > lastNonce`；⑤ 任务结束/断链后回到待命；⑥ 密钥由硬件预置 |
| **mav_gateway（mavp2p）** | 本仓库 `~/mavp2p` | 从帧头按 1.2 解码公式重组 deviceID，用 deviceID 做节点识别与路由查找 | **不解密、不加密**：把加密帧按原样透传路由给地面站与 data_writer；无密钥访问权；**但读取 payload 明文 counter 参与防重放**——按 deviceID 维护全局 lastNonce，收到 `≤ lastNonce` 的帧即丢弃（不解密 ciphertext 即可完成；为尽力而为的边缘去重，权威防重放由解密层完成，见 3.1） |
| **data_writer** | 本仓库 `~/uavm/data_writer` | 从帧头重组 deviceID，写入遥测记录的设备归属字段 | 对下行遥测执行 2.6 完整流程（长度检查 → 防重放 `> lastNonce` → 用 key 解密 → 密钥绑定 → 解析写库；空 payload 消息丢弃）；对待命心跳（按 msgID 识别）解密后更新该无人机在线状态；密钥取自 `table_device_key` 表 |
| **gcs_server** | 本仓库 `~/uavm/gcs_server` | 无人机注册 API 提供 `device_id` 字段登记；设备标识以 deviceID 为准 | ① 管理密钥（登记、查询、轮换）；② 向 QGC 提供 HTTPS 取密钥接口；③ 不接触实时加密帧 |
| **QGC 地面站** | QGC | 从帧头重组 deviceID 显示/关联设备 | ① **感知在线**：从明文帧头 deviceID 识别在线无人机，不回应与自己无关的心跳；② **任务建链**：确定航线+选定无人机后，从 gcs_server 取该 deviceID 密钥，加密回传**奇数起点 X**（严格大于全局 lastNonce 的最小奇数）；③ 解密下行遥测：用 key（2.6 流程）；④ 加密上行指令：用 key，**counter 取 > 全局 lastNonce 的最小奇数**，组包前做超限检查；⑤ 维护该 deviceID 全局 lastNonce（含 PX4 遥测），判重 `本次 > lastNonce`；⑥ key 经 HTTPS 向 gcs_server 获取，不落 MAVLink；⑦ 非任务 QGC 只读，不响应握手、不发指令 |
| **table_device_key 表** | 数据库（本仓库） | 以 deviceID 为主键 | 存 deviceID ↔ key、密钥版本、状态（active/revoked），密钥加密存储 |
| **table_uav 表** | 数据库（本仓库） | `device_id`（BIGINT，全局唯一）为新设备标识；`uid` 为信任根（加密存储、API 不返回） | — |

## 3.1 关键协同约束

- **帧头 deviceID 明文**是两部分协同的基础：mav_gateway 靠它路由，接收方靠它取密钥、构造 nonce、做密钥绑定。因此**帧头永不明文之外再加密**。
- **两套机制无冲突**：deviceID（帧头 4 字节）与 AES-GCM（payload）互不影响；MAVLink V2 原生签名机制**不被使用**，1.4 约束（incompatFlag 高位 bit0 置位禁止）天然避免触发。
- **CRC 与 GCM tag 职责分离**：CRC 防传输噪声，GCM tag 防篡改伪造；两者都保留。
- **防重放分层协同**：mavp2p 读明文 counter 在网络边缘做尽力而为的去除重（不解密、不认证，可被垃圾帧扰动）；data_writer/QGC/PX4 在解密层以 `> lastNonce` 做权威防重放并认证，后者才是安全边界。各接收方按 deviceID 维护全局 lastNonce。
- **单密钥 + 奇偶分家的全局 nonce 序列**：同一 deviceID 一把密钥，两端共用；**PX4 用偶数、QGC 用奇数**，各自取"严格大于全局 lastNonce 的最小本方向奇偶值"递增，奇偶不相交、永不碰撞，不依赖 GPS 更新频率或跨端时钟同步。
- **按需建链（握手）**：PX4 待命时发加密心跳（偶数递增），各 QGC 不回应与自己无关的心跳；仅当某 QGC 确定任务并选定该无人机时，取密钥加密回传奇数起点 X 建链，PX4 以 X 为起点。**同一 deviceID 指令方向同一时刻只有一个发送端（任务 QGC）**，其余 QGC 只读。
- **待命与建链闭环**：任务结束/断链后 PX4 回到待命（继续发加密心跳），可被另一任务 QGC 再次建链。
- **超限帧照发**：超限消息仍发送空 payload 帧（见 2.3），维持链路活跃，接收方解密后丢弃该消息；各端必须保留这一行为，不得因"消息为空"而中断链路。

---

# 附录：与标准 MAVLink V2 签名机制对比

| 维度 | MAVLink V2 原生签名 | 本方案（AES-256-GCM） |
|------|--------------------|----------------------|
| 机密性 | 不加密 | 加密 payload |
| 完整性 | SHA-256 签名（6 字节截断） | GCM 认证标签（16 字节，全强度） |
| 防重放 | 10 秒时间窗口（粗粒度） | 全局单调递增逐帧判定（精粒度，拦截任意旧帧重放；mavp2p 边缘去重） |
| 密钥分发 | MAVLink 链路内 | HTTPS 带外 + 线下预置 |
| 与 deviceID 关联 | 无 | 帧头 + payload 双重绑定 |
| 额外开销 | 13 字节签名 | 28 字节（counter + deviceID + tag） |
| incompatFlag | 必须 = 0x01 | 第 3 字节 bit0 = 0（与 deviceID 约束一致） |
