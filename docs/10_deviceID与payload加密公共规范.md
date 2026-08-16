# MAVLink 改造公共规范：32 位 deviceID 与 payload 加密

> 本文档是 **mavp2p 工程、PX4 固件工程、QGC 地面站工程、companion computer（abc_vtol）、data_writer** 共同遵守的协议规范与改造蓝本。
> 目的：把「MAVLink 帧头 deviceID 升级为 4 字节」与「MAVLink payload 字段加密」这两项改造，作为**一份统一、无异议的协议约定**固化下来，供各工程独立实现时对照。
> 约定：本文档**只表述协议约定与各组成部分必须满足的行为契约，不涉及任何一方如何实现**。各工程实现细节由其自身决定。
> 状态：方案已论证（见 `05_32位系统ID方案论证.md`、`06_MAVLink协议格式与调整方案.md`），本文档为公共蓝本。
>
> **覆盖声明**：本文档在 §2.5 用「**单密钥 + 奇偶分家（下行偶数 / 上行奇数）+ 按需建链 + `本次 > lastNonce` 判定**」**取代** 06 文档第三部分的「GPS 单调计数器 + `counter > lastSeen` 判定」及本文档早前草稿的「+10 / +1 步长」「待命心跳 counter=0」。其余协议要素（deviceID 字节重组、AES-256-GCM、payload block 结构、密钥管理、组件职责）与 05/06 一致。**实现时以本文档为准，勿再对照 06 的 counter 方案。** 另：06 §2.6 的"外部标准明文设备放行"路径与本文档"明文帧一律丢弃"冲突——本协议为加密私有链路，**外部明文设备路径在本链路内废除**（如需兼容外部设备，另行约定旁路，不在本协议范围）。

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
- **incompatFlag 的 bit1~7（deviceID bit25~31）必须由各组件 parser 放行**。MAVLink 标准 parser 会把 bit1~7 当作"必须理解但未知的保留标志"而拒绝整帧（`incompatFlag & ~0x01 != 0` 即丢帧）。各组件（PX4/QGC/mavp2p/data_writer/companion computer abc_vtol）**必须去掉这一拒绝检查**（见 §1.5），否则 deviceID 只能用到低 24 位。放行后 deviceID 可用 **31 位**（bit24 恒 0，其余 31 位任意）。
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

**其他组件（QGC / mavp2p / data_writer）**：各自 fork 其 MAVLink 库，做同样的 parser 修改（去掉 `incompat_flags & ~MAVLINK_IFLAG_MASK` 拒绝检查）。**companion computer abc_vtol 不自行 fork**，经 mavros 的 `libmavconn` 依赖 `mavlink` 包（wangwumu fork）获得同一放行（见文档 11）。

---

# 第二部分：payload 字段加密

## 2.1 安全模型

对 MAVLink 帧的 **payload 部分**做密码学加密，同时实现三项安全属性：

| 安全属性 | 机制 | 说明 |
| --------- | ------ | ------ |
| 保密性 | AES-256-GCM 加密 | payload 内容不可被窃听者读取 |
| 完整性 | GCM 认证标签（tag） | 篡改 payload（ciphertext 或明文 counter）任意 1 bit → tag 校验失败 → 帧丢弃。**注：仅 payload 部分受密码学认证；帧头字段（msgID/len/seq）不在认证范围，篡改帧头 msgID 会导致消息被按错误类型解析，需业务层防范** |
| 防重放 | 全局单调递增 nonce + `本次 > lastNonce` 判定 | 重放任意旧帧 → nonce ≤ lastNonce → 丢弃 |

## 2.2 算法与范围

- **算法**：AES-256-GCM（Galois/Counter Mode），密钥 256 位（32 字节）。
- **密钥**：每台设备**一把**通信密钥，PX4 与 QGC 双向共用（见 2.7）。
- **范围**：仅加密 **payload** 部分。帧头（含 deviceID）**保持明文**——路由、设备识别、nonce 构造、密钥绑定均依赖明文帧头。
- **CRC 保留**：CRC 计算覆盖整个加密后的 payload block，作为传输层（噪声/丢包）校验，与 GCM 认证标签（防篡改/伪造）互补。
- **加密前提（明文特例除外）**：升级组件（PX4、mavp2p、QGC、companion computer abc_vtol、data_writer）之间的**任务帧全部加密**；**明文特例仅两个**：
  - **待命心跳**：PX4 上电无时钟/GPS 授时，无法安全初始化加密 nonce，**以标准 HEARTBEAT（msgID=0）明文承载**——不加密、无 counter/tag、不参与 nonce 序列（见 §2.5）；
  - **NONCE_SYNC（msgid=80004）**：mavros 发出的 nonce 同步报文，仅同步 counter，不加密（见 §2.5「mavros 同步」）。
  接收方收到这两个特例之外的**非加密帧**（明文 payload）一律丢弃并记录日志。
  > **在线状态公开可见**：帧头 deviceID 为明文，任何观察者（QGC、mavp2p、gcs_server、companion computer abc_vtol）无需解密即可感知"某 deviceID 在发帧（在线）"；payload 内的状态/位置等为密文，需密钥解密。**待命/心跳用标准 HEARTBEAT（msgID=0）明文承载**，识别靠帧头 deviceID + 明文 msgID=0。
- **零长度消息禁止**：加密明文 = `deviceID(4B) || 原始消息 payload`，且 **原始消息 payload 长度必须 ≥ 1 字节**——避免与"超限退化帧"（明文仅 deviceID、payload 为空，见 2.3）在接收端形态相同而无法区分。任何一方不得发送 payload 为空的合法消息。
  > **链路范围边界**：本协议适用于**升级组件之间经 mavp2p 的链路**。数传直连链路（PX4 TELEM1 ↔ GCS，应急/监控旁路）是否纳入本加密方案，或作为独立明文旁路，**需另行约定**，不在本协议范围。
  > **当前约定（PX4 实现）**：PX4 侧不提供 per-link opt-out，**所有 MAVLink 实例（TELEM1 / TELEM2 / USB 等）统一按本协议加解密**——任务帧全部加密，仅上述两个明文特例（待命心跳、NONCE_SYNC）豁免，除此之外的明文帧一律丢弃。即 TELEM1 直连也纳入本协议，不保留明文旁路。若后续需要明文应急旁路，需新增参数（按实例指定加密开关）。

## 2.3 加密后的 payload block 结构

```
┌───────────────┬─────────────────────────────┬──────────┐
│  counter(8B)  │  ciphertext(NB)             │  tag(16B)│
│   明文        │   AES-256-GCM 密文           │  认证标签│
└───────────────┴─────────────────────────────┴──────────┘
```

| 字段 | 长度 | 传输方式 | 作用 |
| ------ | ------ | --------- | ------ |
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

- **下行方向（deviceID=D，无人机 → QGC）用偶数 counter**：
  - PX4（飞控）：心跳/遥测/命令应答，步长 +2；
  - companion computer abc_vtol（PX4 的马甲，共用 deviceID=D）：命令应答/通知，步长 +100；
- **上行方向（QGC → 无人机）用奇数 counter**：QGC（地面站）命令/指令，步长 +2。

奇偶分家保证上下行 nonce 不相交。**下行偶数方向内**，PX4 与 abc_vtol 共享同一偶数 nonce 空间（nonce = counter || D），须协调 counter——见下文「下行偶数的协调」。上行奇数方向仅 QGC 一方，无协调问题。

两端各自保证**本方向单调递增**；因奇偶不相交，上下行 nonce 永不相等。发送规则：**建链起点由 QGC 取加密安全随机 62 位奇数（见下）；此后任一方向发送时，取"严格大于该 deviceID 全局 lastNonce 的本方向奇偶值"递增**（下行偶数步长见下，上行奇数 +2）。

**下行偶数的协调（PX4 与 abc_vtol 共享 deviceID）**：

abc_vtol 是 PX4 的 companion computer，经 §2.8 握手获得 PX4 的 deviceID 与密钥，其发出的下行帧与 PX4 无法区分（均为 deviceID=D）。两者共享同一偶数 nonce 空间，须协调 counter：

- 两者共享**单一下行偶数 lastNonce**（**恒为偶数**，仅跟踪下行偶数 counter；区别于接收方防重放的「全局 lastNonce」，后者含上下行、见下「防重放判定」），经 mavros 同步；
- **下行 lastNonce 初始值**：PX4 建链收到 QGC 的奇数 X 后，下行 lastNonce 初始化为「最小偶数 > X」= X+1（非 X，因 X 是奇数）；
- PX4 发帧：`counter = 下行 lastNonce + 2`（下行 lastNonce 恒偶，+2 仍偶）；
- abc_vtol 发帧：`counter = 下行 lastNonce + 100`（+100 仍偶）；
- 步长错开（+2 vs +100）使「几乎并发」的两帧 counter 天然错开，消除单次并发的 nonce 碰撞；即便 PX4 连发 50 次心跳（每次 +2）仍追不上 abc_vtol 的 +100 步长，碰撞需同步不及时超过 50 个心跳间隔，稀疏通信下概率可忽略。

**mavros 同步下行 lastNonce**：

mavros 作为下行帧的中转点，中转时提取每帧 payload 明文前 8 字节的 counter，经**扩展报文 NONCE_SYNC（msgid=80004，消息定义见 `mavlink_mavros扩展记录.md` §2.2）**广播给另一方（PX4 ↔ abc_vtol），双方据此更新本地**下行 lastNonce**。该同步须用 **reliable QoS**（不丢同步报文）。扩展报文仅同步 counter（明文，不涉密），**不加密**。

**mavros 重复检查（兜底）**：

mavros 维护单一**下行 lastNonce**（单无人机、单一 deviceID，无需按 deviceID 索引；只跟踪下行偶数帧的 counter），中转时检查每帧 counter：`counter ≤ lastNonce` 即拦截（丢弃该帧并告警）。作用：① 防重放；② 若 PX4 与 abc_vtol 因同步不及时而撞了相同 counter，拦截后到帧，避免两个同 nonce 密文都流出导致 keystream 泄露。发送方亦须在加密前检查 `counter > 本地 lastNonce`，不满足则**停止发送并告警**，宁可停发不可 nonce 复用。

- **待命心跳（明文特例）**：PX4 上电后无论有无可靠时钟，一律发**明文待命心跳**——不加密、无 counter/tag、不参与 nonce 序列，用标准 HEARTBEAT（msgID=0）明文承载。各 QGC 从帧头 deviceID 即可感知在线，**未确定任务前对所有心跳保持静默**（不响应、不发指令）。
- **QGC 建链**：当某 QGC 确定航线并选定要执行的无人机时，经 gcs_server（HTTPS）获取该 deviceID 密钥，对该 deviceID 发送**加密心跳**，counter 取**加密安全随机 62 位奇数起点**（`secrets.randbits(62) | 1`，非 timestamp 派生）——该 QGC 成为此无人机的指令发送端。**仅首次随机，之后每次 +2**；QGC 不需确认 PX4 是否收到，按自身节奏发送。
- **PX4 建链**：收到首个加密帧的奇数 counter X 后，更新**接收方全局 lastNonce = X**（防重放），并将**下行偶数 lastNonce 初始化为 X+1**（最小偶数 > X，恒为偶数），进入正常发送（后续遥测 counter = 下行 lastNonce + 2，见「下行偶数的协调」）。
- **回到待命**：任务结束（见 §2.9 断连机制）后，**PX4 软重置全局 lastNonce（防重放，清空为 unset）**，回到待命（继续发明文心跳，无 counter）；**任务 QGC 放弃其奇数序列、abc_vtol 放弃其偶数序列**，停止发送，下次建链由 QGC 重新随机 62 位奇数起点。

> **多无人机 / 多 QGC**：每个 deviceID 的序列独立。同一 deviceID 的指令方向（上行奇数）同一时刻只有一个发送端（发起任务的那个 QGC）；abc_vtol 是下行偶数方（PX4 的马甲，见「下行偶数的协调」），不参与指令方向的互斥。其他 QGC 只读（可取密钥解密遥测、监控），但不得响应握手、不得发指令。mavp2p 按 deviceID 路由与边缘去重，不参与握手仲裁。
>
> **重启边界**：接收方重启后 lastNonce 清零仅重新打开防重放窗口（可重放旧帧），属已知残余风险。**但发送方重启后 counter 从最小值重来，会在同一密钥下复用 nonce（AES-GCM keystream 泄露）——这是必须避免的硬性约束：QGC 建链须以加密安全随机 62 位奇数作为 counter 起点，或持久化 lastNonce，不得简单清零从最小值重来；PX4 与 abc_vtol 的下行偶数序列由 QGC 的奇数起点派生（下行 lastNonce 初始化为 X+1），其 nonce 不重叠由 QGC 随机起点的充足性保证。** 随机起点位宽须小于 counter 位宽（64 位）至少 2 位，否则可能随机到右边界导致 `+2` 快速 wrap-around；counter 为 64 位无符号，实现须监测：达到 `COUNTER_MAX = 2^62` 时停止发送并重新建链（换密钥），不得越界。

**防重放判定（各端一致，按 deviceID 维护全局 lastNonce）**：

攻击者可截获整个报文、不解密直接复制重发。**每个接收方（PX4、QGC、companion computer abc_vtol、mavp2p、data_writer）按 deviceID 维护全局 lastNonce**（初值 unset，首个合法帧即接受并登记），收到帧后：

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

接收方（解密方）对每个收到的**加密帧**，必须按序执行以下判定，任一步不满足即丢弃整帧（两个明文特例——待命心跳与 NONCE_SYNC（msgid=80004）——不走本流程：待命心跳按帧头 deviceID 直接感知在线，NONCE_SYNC 按明文解析更新下行 lastNonce，见 §2.5）：

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
| ------ | ------ |
| 密钥生成 | 制造/运维环节为每台设备生成**一把** 256 位随机密钥（32 字节） |
| 写入无人机 | 线下/工厂预置，烧录到无人机安全存储；**密钥不通过 MAVLink 链路传输** |
| 登记 | 通过 gcs_server 管理接口登记 deviceID ↔ key |
| 分发到 QGC | QGC 经 HTTPS/REST 向 gcs_server 获取该设备的通信密钥 key（解密遥测 + 加密指令）；**不走 MAVLink** |
| 分发到 companion computer | companion computer（abc_vtol）经**本地 DDS/uXRCE** 向 PX4 握手获取（三向握手，见 §2.8），不走 MAVLink、不走公网 |
| 存储 | 独立映射表 `table_device_key`（**device_id 为业务唯一键**、key、key_version、status、时间戳），密钥加密存储，不与业务表混用；是否另设自增 id 主键见 `01_requirements.md` §3.16 |
| 访问权限 | data_writer 与 QGC 可取 key（解密遥测）；QGC 另用 key 加密指令；mav_gateway 无任何密钥访问权 |
| 轮换 | 通过 NFC / Type-C 等非线上方式发起，用设备 `uid` 派生的密钥加密轮换请求报文，经线下通道交运维；云端用库中 uid 校验后**轮换该密钥**并递增 key_version |

**uid 信任根**：

- `table_uav.uid`（飞控芯片唯一标识，如 STM32 96-bit UID）作为密钥轮换的信任根；
- **uid 永不进入 MAVLink 帧**（协议层面禁止，任何组件不得解析/转发携带 uid 的消息）；
- 轮换密钥派生：`rotation_key = HKDF-SHA256(uid, salt=deviceID, info="key-rotation")` → 32 字节 AES-256 密钥，用于加密密钥更新报文。

### 2.7.1 实现状态

| 环节 | 状态 | 说明 |
| ------ | ------ | ------ |
| 密钥登记接口 | ✅ 已实现 | gcs_server `POST /api/device-keys`（校验 device 存在 + key 为 Base64/32 字节） |
| QGC 取密钥接口 | ✅ 已实现 | gcs_server `GET /api/device-keys/:deviceId`（HTTPS，登录鉴权） |
| 密钥列表/删除接口 | ✅ 已实现 | `GET /api/device-keys`、`DELETE /api/device-keys/:deviceId` |
| 密钥存储 | ⏳ **开发阶段明码存储** | 当前 `table_device_key.key` 裸存（Base64）；**正式部署（网络版）前必须改为加密存储**——需引入服务器级主密钥（保管方式待定：环境变量/配置文件/KMS）加密 key 列，取回时解密 |
| 密钥轮换接口 | ⏳ **待设计** | NFC/Type-C 线下轮换流程、`uid` 派生的 rotation_key 校验、`key_version` 递增、旧密钥转 REVOKED 过渡期——接口待设计实现 |
| 密钥自动注入无人机 | ⏳ 待实现 | 出厂预置流程与登记工具（线下/工厂环节） |
| companion computer 密钥握手 | ⏳ CC 已实现 / PX4 待实现 | CC 侧（abc_vtol `mavlink_crypto_node`）已实现；PX4 侧 uORB 消息 + uXRCE-DDS 配置 + 握手服务端待实现（见 §2.8） |

## 2.8 companion computer 密钥握手（DDS/uXRCE）

companion computer（本方案中为 **abc_vtol**，PX4 的 ROS2 上位机）需与 PX4 共享同一把通信密钥，才能对 MAVLink 帧做 payload 加解密。密钥出厂预置于 PX4（§2.7），companion computer 通过**本地 DDS/uXRCE 链路**向 PX4 握手获取，不走 MAVLink、不走公网。

### 2.8.1 传输链路

- 复用避障系统的 DDS/uXRCE 链路：PX4 `uxrce_dds_client` ↔ `micro_ros_agent` ↔ ROS2
- **仿真**：`udp4:8888`（PX4 SITL 与 ROS2 同机/同网络）
- **物理**：`serial`（`--dev /dev/ttyXXX --baudrate 921600`，飞控 TELEM UART / USB CDC ACM 直连上位机，密钥不进 IP 网络）
- 与避障状态/控制共用同一 agent，不新增传输通道；launch 参数 `agent_transport` 在 `udp4`/`serial` 间切换

### 2.8.2 消息定义

握手消息为 PX4 侧自定义 uORB 消息，经 uXRCE-DDS 桥接到 ROS2。**type hash 由发起侧（CC，即 ROS2 `vtol_msgs` 包）定义并生成，PX4 侧 uORB 消息按 CC 定义逐字段镜像**（字段名、类型、顺序完全一致），保证两侧 XTypes type hash 一致、DDS 可匹配。使用 `vtol_msgs`（而非 `px4_msgs`）以区分本系统自定义消息与 PX4 原生消息，便于维护与纠错。

**三则消息的权威字段定义（CC 侧 `vtol_msgs` 与 PX4 侧 uORB 两侧镜像，`uint64 timestamp` 首字段为 PX4 uORB 惯例，两侧一致；timestamp 用纯 `uint64`，**不是** ROS2 的 `builtin_interfaces/Time`，否则 type hash 不匹配）**：

| 消息 | 字段（顺序即 type hash 顺序） | 方向 | DDS 话题 |
| ------ | ------------------------------- | ------ | ------ |
| 凭证请求 `DeviceCredentialRequest` | `uint64 timestamp`、`uint32 req_id` | CC → PX4 | `/fmu/in/device_credential_request` |
| 凭证应答 `DeviceCredential` | `uint64 timestamp`、`uint32 device_id`、`uint8[32] aes_key`、`uint32 req_id`、`uint32 cred_seq` | PX4 → CC | `/fmu/out/device_credential` |
| 凭证确认 `DeviceCredentialAck` | `uint64 timestamp`、`uint32 cred_seq` | CC → PX4 | `/fmu/in/device_credential_ack` |

- `req_id`：CC 每次发起请求递增的序号，PX4 原样回显（供 CC 匹配应答）。
- `cred_seq`：PX4 凭证序号；同一未确认凭证保持不变（重发幂等），收到新请求时递增。
- `device_id`：= `MAV_DEVICE_ID` 参数值（§2.8.7）。
- `aes_key`：通信密钥，= `/fs/microsd/mavlink_key.bin`（§2.8.7）。

**PX4 侧 uORB `.msg` 文件（`msg/` 目录，与上表字段一一对应）**：

`msg/device_credential_request.msg`：
```
uint64 timestamp   # time since system start (microseconds)

uint32 req_id
```

`msg/device_credential.msg`：
```
uint64 timestamp   # time since system start (microseconds)

uint32 device_id
uint8[32] aes_key
uint32 req_id
uint32 cred_seq
```

`msg/device_credential_ack.msg`：
```
uint64 timestamp   # time since system start (microseconds)

uint32 cred_seq
```

**CC 侧 `vtol_msgs` `.msg`**：字段与上表完全一致（含 `uint64 timestamp`，顺序不变），消息名用 CamelCase（`DeviceCredentialRequest` / `DeviceCredential` / `DeviceCredentialAck`）。

**PX4 侧 `uxrce_dds_client/dds_topics.yaml` 配置**（`generate_dds_topics.py` 不硬编码 `px4_msgs`，`type:` 写 `vtol_msgs::msg::Xxx` 即可；生成器按 snake_case 定位 uORB 消息，DDS 类型名为 `vtol_msgs::msg::dds_::Xxx_`）：

```yaml
publications:
  - topic: /fmu/out/device_credential
    type: vtol_msgs::msg::DeviceCredential

subscriptions:
  - topic: /fmu/in/device_credential_request
    type: vtol_msgs::msg::DeviceCredentialRequest
  - topic: /fmu/in/device_credential_ack
    type: vtol_msgs::msg::DeviceCredentialAck
```

> 握手消息为事件型、非高频，无需 `rate_limit`；QoS 用默认 reliable。

### 2.8.3 握手流程（三向握手，CC 发起）

```
CC (abc_vtol)                              PX4
    │ ① DeviceCredentialRequest(req_id++)                    │
    │───────────────────────────────────────────────────────>│
    │ ② DeviceCredential(device_id, key, req_id, cred_seq++) │
    │<───────────────────────────────────────────────────────│
    │ ③ DeviceCredentialAck(cred_seq)                        │
    │───────────────────────────────────────────────────────>│
    │                    握手完成                             │
```

1. CC 启动 → 发布 `request(req_id++)`
2. PX4 收到 → 发布 `credential(device_id, key, req_id 回显, cred_seq++)`
3. CC 收到 → **校验 req_id 匹配（且必须已发出过请求）** → 存 device_id/key → 发布 `ack(cred_seq)`
4. PX4 收到 ack → 握手完成

### 2.8.4 重试 / 超时

- **CC**：请求后 `timeout_s`（默认 2s）未收到应答 → 重发（req_id 递增）；超 `max_retries`（默认 5）后重置计数继续重试
- **PX4**：应答后未收到 ack → 周期重发（cred_seq 不变，幂等）
- **握手未完成前**：CC 不处理任何 MAVLink 加解密帧，进入持续重试循环

### 2.8.5 安全说明

- **物理部署（serial）**：密钥经串口传递，不进 IP 网络，无 UDP 扩散/嗅探/注入风险，仅依赖串口物理链路
- **仿真（UDP）**：deviceID + key 经 DDS **明文**传输（本地 UDP，无加密）；`micro_ros_agent` 的 UDP 传输监听 `INADDR_ANY`（所有接口），若上位机另有 WiFi/以太网接口，8888 端口会暴露到该网络，存在嗅探/注入风险——仿真环境通常隔离，风险低
- 与 §2.7「密钥不走 MAVLink」兼容（DDS/串口 ≠ MAVLink），但不具备密码学认证
- CC 侧仅接受「已发请求且 req_id 匹配」的应答，拒绝未请求的凭证
- 增强方向（可选，后续按需，仅 UDP 场景）：SROS2 安全 enclave / 预共享 boot key 做 HMAC 挑战应答 / 防火墙限流 8888 端口
- 密钥在 CC 内存中以明文持有（Python 无安全内存），属已知限制

### 2.8.6 实现状态

| 环节 | 状态 | 说明 |
|------|------|------|
| CC 侧（abc_vtol） | ✅ 已实现 | `vtol_communication/mavlink_crypto_node.py`：握手状态机 + 订阅 `/uas1/mavlink_source` 解密 + 加密发布 `/uas1/mavlink_sink`；核心加解密 `mavlink_crypto.py` |
| PX4 侧 | ⏳ 待实现（规格已定，见 §2.8.7） | ① 新增三个 uORB 消息（§2.8.2）；② `dds_topics.yaml` 加 3 个 topic（§2.8.2）；③ `MavlinkCrypto` 加只读 getter；④ 独立模块 `src/modules/device_credential/` 实现握手服务端逻辑（§2.8.7） |

### 2.8.7 PX4 侧实现约定（已定）

针对 PX4 侧握手服务端的实现方式，明确以下约定（消除二义性）：

| 项 | 约定 |
| --- | --- |
| **密钥来源** | 与 MAVLink 加密共用同一把密钥：`/fs/microsd/mavlink_key.bin`（缺失回退内置 dev-key，语义同 `MavlinkCrypto::configure`）。握手服务端通过 `MavlinkCrypto` 新增的只读 getter 获取，**不得另建密钥存储** |
| **device_id 来源** | `MAV_DEVICE_ID` 参数（即 `MavlinkCrypto` 校验后的值，含 §1.4 的 bit24=0 约束） |
| **服务端落点** | **独立模块** `src/modules/device_credential/`（不并入 `uxrce_dds_client` / `mavlink`），与原生模块区分、便于维护与纠错 |
| **职责划分** | `uxrce_dds_client` 仅负责传输（`dds_topics.yaml` 加 3 个 topic，见 §2.8.2）；握手逻辑（订阅 request → 发布 credential → 订阅 ack + 重试）由独立模块 `device_credential` 实现 |
| **req_id 语义** | PX4 侧**回显不校验**：收到合法 request 即回显 req_id 并发布 credential；req_id 的匹配/单调性校验是 CC 侧职责（§2.8.3 第 3 步） |
| **cred_seq 语义** | 同一未确认凭证保持不变（重发幂等）；收到新的（不同 req_id 的）请求时递增 |
| **握手完成后的行为** | PX4 收到 ack 后**停止重发**该凭证，无其他附加动作（PX4 不依赖握手状态 gate 任何 MAVLink 行为；是否 gate 是 CC 侧职责，见 §2.8.4） |
| **QoS** | 默认 reliable（事件型、非高频，无需 `rate_limit`） |

## 2.9 断连机制（任务完成 / 解绑）—— TODO 待实现

### 背景

- **心跳不是必须的**：PX4 在外飞行可能出现通信中断，收不到心跳也必须继续执行任务——不能靠心跳判定任务状态。
- **任务完成必须有明确、无异议的指令和应答**。

### 设计（待实现）

- 扩展 MAVLink 报文，提供专门的**「任务结束 / 解绑」指令 + 应答**，**必须是加密帧**（复用 §2.3/§2.6 的加解密流程）。
- 流程：
  1. 任务 QGC 发送「任务结束」加密指令（奇数 counter 递增）；
  2. PX4 收到后回「解绑确认」加密应答（偶数 counter 递增）；
  3. 双方**软重置全局 lastNonce（防重放，清空为 unset）**，回到待命（PX4 发明文心跳 counter=0，任务 QGC 放弃奇数序列、abc_vtol 放弃偶数序列，见 §2.5）。
- 解绑后：该 deviceID 可被另一任务 QGC 再次建链；原 QGC 放弃奇数序列，下次建链重新随机起点。

### 明确不做

- ❌ 不靠关机重启来解绑（软重置即可，见 §2.5「重启边界」）
- ❌ 不靠心跳超时判定任务结束
- ❌ 不靠 mavp2p 仲裁解绑（mavp2p 只透传）

### 状态

⏳ **待实现**：专用 MAVLink 报文（指令 + 应答）的消息 ID、字段定义、加密承载方式后续定义，本协议暂不约束具体格式。

---

# 第三部分：各组成部分行为契约

以下列出 mavp2p 与各外部工程必须遵守的**协议行为**（不含实现）。每一方只需对照其职责列执行，无需关心其他方如何实现。

| 组成部分 | 所在工程 | 对 deviceID 改造的契约 | 对 payload 加密的契约 |
| --------- | --------- | ---------------------- | ---------------------- |
| **无人机飞控（PX4 固件）** | PX4 | ① 出厂写入全局唯一 deviceID；② 发送时按 1.2 编码公式把 deviceID 拆入帧头 4 字节；③ 遵守 1.4 约束（incompatFlag 高位 bit0 置位禁止） | ① **待命**：上电后一律发**明文 HEARTBEAT 待命心跳**（不加密、无 counter/tag），等待任务 QGC 建链；② **建链**：收到 QGC 回传的奇数 X 后更新全局 lastNonce = X（防重放）、下行 lastNonce 初始化为 X+1，进入正常遥测（**counter = 下行 lastNonce + 2**），组包前做超限检查（见 2.3）；③ 上行指令：用 key 解密（同 2.6 流程）；④ 维护该 deviceID 全局 lastNonce（含 QGC 指令），判重 `本次 > lastNonce`；⑤ 任务结束/断链后回到待命；⑥ 密钥由硬件预置 |
| **mav_gateway（mavp2p）** | 本仓库 `~/mavp2p` | 从帧头按 1.2 解码公式重组 deviceID，用 deviceID 做节点识别与路由查找 | **不解密、不加密**：把加密帧按原样透传路由给地面站与 data_writer；无密钥访问权；**但读取 payload 明文 counter 参与防重放**——按 deviceID 维护全局 lastNonce，收到 `≤ lastNonce` 的帧即丢弃（不解密 ciphertext 即可完成；为尽力而为的边缘去重，权威防重放由解密层完成，见 3.1） |
| **data_writer** | 本仓库 `~/uavm/data_writer` | 从帧头重组 deviceID，写入遥测记录的设备归属字段 | 对下行遥测执行 2.6 完整流程（长度检查 → 防重放 `> lastNonce` → 用 key 解密 → 密钥绑定 → 解析写库；空 payload 消息丢弃）；对待命心跳（按明文 msgID=0 识别）更新该无人机在线状态；密钥取自 `table_device_key` 表 |
| **gcs_server** | 本仓库 `~/uavm/gcs_server` | 无人机注册 API 提供 `device_id` 字段登记；设备标识以 deviceID 为准 | ① 管理密钥（登记、查询、轮换）；② 向 QGC 提供 HTTPS 取密钥接口；③ 不接触实时加密帧 |
| **QGC 地面站** | QGC | 从帧头重组 deviceID 显示/关联设备 | ① **感知在线**：从明文帧头 deviceID 识别在线无人机，不回应与自己无关的心跳；② **任务建链**：确定航线+选定无人机后，从 gcs_server 取该 deviceID 密钥，加密回传**随机 62 位奇数起点 X**（`secrets.randbits(62)\|1`，见 2.5）；③ 解密下行遥测：用 key（2.6 流程）；④ 加密上行指令：用 key，**counter 从建链起点 +2 递增**，组包前做超限检查；⑤ 维护该 deviceID 全局 lastNonce（含 PX4 遥测），判重 `本次 > lastNonce`；⑥ key 经 HTTPS 向 gcs_server 获取，不落 MAVLink；⑦ 非任务 QGC 只读，不响应握手、不发指令 |
| **companion computer（abc_vtol）** | 本仓库 abc_vtol | 从帧头重组 deviceID，用于解密密钥绑定 | ① 密钥经本地 DDS/uXRCE 握手获取（§2.8）；② 解密 PX4 下行遥测（2.6 流程）；③ 加密下行应答/通知，counter 用偶数（步长 +100，见 §2.5「下行偶数的协调」）；④ 维护下行 lastNonce（经 mavros 同步，协调）与全局 lastNonce（防重放），判重 `本次 > lastNonce`；⑤ 是 PX4 的马甲（共用 deviceID=D），下行偶数方，与 PX4 共享 nonce 序列 |
| **table_device_key 表** | 数据库（本仓库） | 以 deviceID 为主键 | 存 deviceID ↔ key、密钥版本、状态（active/revoked），密钥加密存储 |
| **table_uav 表** | 数据库（本仓库） | `device_id`（BIGINT，全局唯一）为新设备标识；`uid` 为信任根（加密存储、API 不返回） | — |

## 3.1 关键协同约束

- **帧头 deviceID 明文**是两部分协同的基础：mav_gateway 靠它路由，接收方靠它取密钥、构造 nonce、做密钥绑定。因此**帧头永不明文之外再加密**。
- **两套机制无冲突**：deviceID（帧头 4 字节）与 AES-GCM（payload）互不影响；MAVLink V2 原生签名机制**不被使用**，1.4 约束（incompatFlag 高位 bit0 置位禁止）天然避免触发。
- **CRC 与 GCM tag 职责分离**：CRC 防传输噪声，GCM tag 防篡改伪造；两者都保留。
- **防重放分层协同**：mavp2p 读明文 counter 在网络边缘做尽力而为的去除重（不解密、不认证，可被垃圾帧扰动）；data_writer/QGC/companion computer abc_vtol/PX4 在解密层以 `> lastNonce` 做权威防重放并认证，后者才是安全边界。各接收方按 deviceID 维护全局 lastNonce。
- **单密钥 + 奇偶分家的全局 nonce 序列**：同一 deviceID 一把密钥，两端共用；**下行（PX4 与 abc_vtol，deviceID=D）用偶数、上行（QGC）用奇数**；下行偶数内 PX4 步长 +2、abc_vtol 步长 +100（见 §2.5），建链起点取加密安全随机 62 位奇数，奇偶不相交、永不碰撞，不依赖 GPS 更新频率或跨端时钟同步。
- **按需建链（握手）**：PX4 待命时发明文心跳（counter=0），各 QGC 不回应与自己无关的心跳；仅当某 QGC 确定任务并选定该无人机时，取密钥加密回传随机 62 位奇数起点 X 建链，PX4 以 X 为起点。**同一 deviceID 指令方向（上行奇数）同一时刻只有一个发送端（任务 QGC）**，其余 QGC 只读；abc_vtol 为下行偶数方（马甲），不参与上行互斥。
- **待命与建链闭环**：任务结束/断链后 PX4 软重置全局 lastNonce（防重放，清空为 unset）回到待命（继续发明文心跳，无 counter），任务 QGC 放弃奇数序列、abc_vtol 放弃偶数序列，可被另一任务 QGC 再次建链。
- **超限帧照发**：超限消息仍发送空 payload 帧（见 2.3），维持链路活跃，接收方解密后丢弃该消息；各端必须保留这一行为，不得因"消息为空"而中断链路。

---

# 附录：与标准 MAVLink V2 签名机制对比

| 维度 | MAVLink V2 原生签名 | 本方案（AES-256-GCM） |
| ------ | -------------------- | ---------------------- |
| 机密性 | 不加密 | 加密 payload |
| 完整性 | SHA-256 签名（6 字节截断） | GCM 认证标签（16 字节，全强度） |
| 防重放 | 10 秒时间窗口（粗粒度） | 全局单调递增逐帧判定（精粒度，拦截任意旧帧重放；mavp2p 边缘去重） |
| 密钥分发 | MAVLink 链路内 | HTTPS 带外 + 线下预置 |
| 与 deviceID 关联 | 无 | 帧头 + payload 双重绑定 |
| 额外开销 | 13 字节签名 | 28 字节（counter + deviceID + tag） |
| incompatFlag | 必须 = 0x01 | 第 3 字节 bit0 = 0（与 deviceID 约束一致） |
