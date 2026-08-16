# MAVLink 与 mavros 扩展记录

> 本文档汇总本项目对 **MAVLink 协议** 以及 **mavros 通信桥** 的全部扩展改造，作为实现与维护的索引。
> 分两部分：第一部分索引历史 MAVLink 扩展（指向已有详细文档）；第二部分详细记录本次 mavros 扩展。

---

# 第一部分：MAVLink 协议扩展（历史）

| 扩展 | 内容 | 状态 | 详细文档 |
|------|------|------|---------|
| deviceID 帧头重组 | 帧头 4 字节重组为 32 位 deviceID | ✅ 已论证 | `10_deviceID与payload加密公共规范.md` §1 |
| incompat_flags parser 放行 | 放行 bit1~7 承载 deviceID 高位 | ✅ 已就位（wangwumu fork） | `11_deviceID与incompat_flags冲突说明.md` |
| payload AES-256-GCM 加密 | counter(8B)+ciphertext(N)+tag(16B)，nonce=counter‖deviceID | ✅ 已论证 | `10_deviceID与payload加密公共规范.md` §2 |
| 待命心跳明文特例 | 标准 HEARTBEAT（msgID=0）明文，无 counter/tag、不加密 | ✅ 已约定 | `10_deviceID与payload加密公共规范.md` §2.2/§2.5 |
| 下行偶数步长错开 | PX4 +2、abc_vtol +100，共享 lastNonce | ✅ 已约定 | `10_deviceID与payload加密公共规范.md` §2.5 |
| 断连机制 | 任务结束专用加密指令+应答（软重置 lastNonce） | ⏳ TODO | `10_deviceID与payload加密公共规范.md` §2.9 |
| 自定义消息 | 4 业务消息（80000-80003）+ 7 枚举（另有 80004 NONCE_SYNC，见第二部分 §2.2） | ✅ 定义 | `mavlink_extension_protocol.md` |

## 1.1 自定义消息（vtol_safety.xml）

4 个自定义消息，ID 80000-80003（MAVLink 自定义保留范围），对 PX4 透明（静默丢弃）：

| msg_id | 名称 | 方向 | 用途 |
|--------|------|------|------|
| 80000 | `WEATHER_FORECAST` | QGC → ROS2 | 天气预报数据（单点） |
| 80001 | `ALTERNATE_LANDING` | QGC → ROS2 | 备降点数据 |
| 80002 | `SENSOR_CTRL` | QGC → ROS2 | 传感器控制命令 |
| 80003 | `VIDEO_CTRL` | QGC → ROS2 | 视频控制命令 |

7 个枚举：`VTOL_WEATHER_TYPE`、`VTOL_WEATHER_SEVERITY`、`VTOL_ALT_TYPE`、`VTOL_SENSOR_ID`、`VTOL_SENSOR_CMD`、`VTOL_CAMERA_ID`、`VTOL_VIDEO_CMD`。

**字段、ROS2 转换映射、存储、安全机制详见 `mavlink_extension_protocol.md`。**

---

# 第二部分：mavros 扩展（本次）

## 2.1 Router 透传加密帧 ✅ 已实现

**背景**：payload 加密后是密文，mavros 的 UAS 插件会把密文当标准 MAVLink 消息解析出垃圾值。因此 mavros 必须以 **router-only** 模式运行，只透传不解析。

**实现**（`px4_bridge.launch.py`）：

```python
ComposableNode(
    package='mavros', plugin='mavros::router::Router',
    name='mavros_router',
    parameters=[
        {'fcu_urls': [fcu]},        # FCU 连接 (PX4)
        {'gcs_urls': gcs_list},     # GCS 连接 (QGC, 可空)
        {'uas_urls': ['/uas1']},    # ROS 端点 (透传话题前缀)
    ],
)
```

**透传话题**（由 Router 的 ROSEndpoint 提供，类型 `mavros_msgs/msg/Mavlink`）：

| 话题 | 方向 | 说明 |
|------|------|------|
| `/uas1/mavlink_source` | mavros → abc_vtol | mavros 收到的加密帧，发布给 abc_vtol 解密 |
| `/uas1/mavlink_sink` | abc_vtol → mavros | abc_vtol 加密的帧，mavros 转发给 PX4 |

**关键点**：
- 只起 Router，不起 UAS 插件（否则密文被解析成垃圾）
- 之前误加的 `fcu_protocol` 参数已删除（它是 UAS 插件参数，Router 不认识，会报 "unknown parameter"）
- Router 硬编码 `Protocol::V20`（`mavros_router.cpp:519`），协议版本透传无需配置

## 2.2 nonce 同步扩展报文 ⏳ 方案设计

**背景**：abc_vtol 是 PX4 的马甲（经 DDS 握手获得 PX4 的 deviceID 与密钥，见文档 10 §2.8），其发出的下行帧与 PX4 无法区分（均为 deviceID=D）。两者共享同一偶数 nonce 空间（nonce = counter‖D），须协调 counter。

**机制**：

1. mavros 作为下行帧中转点，中转时提取每帧 **payload 明文前 8 字节的 counter**
2. 将 counter 封入**扩展报文**，广播给另一方（PX4 ↔ abc_vtol）
3. 双方据此更新本地**下行 lastNonce**（恒为偶数）

**约束**：
- 同步须用 **reliable QoS**（不丢同步报文）
- 扩展报文仅同步 counter（明文，不涉密），**不加密**
- 攻击者伪造同步报文最多导致判重丢帧，不会造成 nonce 复用

**步长错开**（配合同步，降低并发碰撞概率）：
- 两者共享**下行 lastNonce**（恒为偶数，初始为 QGC 建链奇数 X 的最小偶数后继 X+1）
- PX4 发帧：`counter = 下行 lastNonce + 2`
- abc_vtol 发帧：`counter = 下行 lastNonce + 100`
- 步长错开使「几乎并发」的两帧 counter 天然错开，消除单次并发 nonce 碰撞

**状态**：消息格式已定义，**待实现 mavros 提取 counter + 封装 NONCE_SYNC + 收发逻辑**。

**消息定义（NONCE_SYNC，msgid=80004）**：

```xml
<message id="80004" name="NONCE_SYNC">
  <description>
    mavros 发出的 nonce 同步报文（明文，内部控制）。
    中转某帧时提取其 counter，封入本消息发给另一方（PX4 ↔ abc_vtol），
    对方据此更新本地 lastNonce。仅 mavros 发出。
  </description>
  <field type="uint64_t" name="counter">
    counter 值（从被中转帧 payload 前 8 字节提取）
  </field>
</message>
```

- **消息 ID**：`80004`（紧接 80000-80003，同一自定义范围）
- **字段**：单字段 `uint64_t counter`，payload 即 8 字节
- **通道**：mavros → PX4 走 `fcu_url`（MAVLink 帧）；mavros → abc_vtol 走 `/uas1/mavlink_source`（`mavros_msgs/msg/Mavlink`，msgid=80004）
- **字节序**：加密帧 payload 前 8 字节的 counter 是**大端**，而 MAVLink `uint64` 字段序列化是**小端**——mavros 提取时须做「大端→小端」转换，对方解析时转回
- **明文特例**：不加密（mavros 无密钥、counter 本就不涉密），是 §2.2「全加密」的**第二个明文特例**（同待命心跳）；接收方按 msgid=80004 明文处理，不套 §2.6 解密流程、也不按「非加密帧一律丢弃」拒收

## 2.3 nonce 重复检查 ⏳ 方案设计

**背景**：即便步长错开 + 可靠同步，极端情况下 PX4 与 abc_vtol 仍可能撞相同 counter。碰撞的后果是 **nonce 复用（keystream 泄露）**，不是丢帧，必须兜底。

**机制**：mavros 维护**单一下行 lastNonce**（单无人机、单一 deviceID，无需按 deviceID 索引；只跟踪下行偶数帧的 counter），中转时检查每帧 counter：

```
counter ≤ lastNonce  → 拦截（丢弃该帧并告警）
counter >  lastNonce  → 放行，更新 lastNonce
```

**双重作用**：
1. **防重放**：攻击者重放旧帧，counter ≤ lastNonce 被拦截
2. **防 nonce 复用**：若 PX4 与 abc_vtol 撞相同 counter，拦截后到帧，避免两个同 nonce 密文都流出导致 keystream 泄露

**发送方约束**：加密前须检查 `counter > 本地 lastNonce`，不满足则**停止发送并告警**，宁可停发不可 nonce 复用。

**边界**：mavros 只能拦截不能改写（counter 是 GCM AAD，改写破坏 tag），被拦的帧即丢失——对心跳无妨（周期发），对 abc_vtol 应答可能丢一条（步长错开使其几乎不发生）。

**状态**：方案已定（见文档 10 §2.5「mavros 重复检查」），**待实现**。

## 2.4 串口传输支持 ✅ 已实现

**背景**：物理部署下 PX4 飞控与上位机走串口（TELEM UART / USB CDC ACM），密钥经串口传递不进 IP 网络，无 UDP 扩散风险。

**实现**（`px4_bridge.launch.py`）：

```python
if transport == 'serial':
    agent_args = [transport, '--dev', dev, '--baudrate', baudrate]
else:
    agent_args = [transport, '--port', port]
```

**新增 launch 参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `agent_transport` | `udp4` | `udp4`(仿真) / `serial`(物理) |
| `agent_dev` | `/dev/ttyACM0` | serial 设备路径 |
| `agent_baudrate` | `921600` | serial 波特率 |

**物理部署启动**：
```bash
ros2 launch vtol_bringup vtol_full.launch.py \
  sim_mode:=false agent_transport:=serial \
  agent_dev:=/dev/ttyACM0 agent_baudrate:=921600
```

**安全性**：serial 传输下密钥不进 IP 网络，无嗅探/注入风险（见文档 10 §2.8.5）。

## 2.5 fcu_protocol 死参数删除 ✅ 已实现

`px4_bridge.launch.py` 曾给 Router 传 `fcu_protocol: 'v2.0'`，但该参数是 **UAS 插件**（`mavros_uas.cpp:85`）的参数，Router 的参数回调只认 `fcu_urls/gcs_urls/uas_urls`，收到 `fcu_protocol` 会返回 "unknown parameter"。已删除。

## 2.6 device_credential 握手消息契约 ✅ 规格已定（PX4 侧待实现）

companion computer 经本地 DDS/uXRCE 向 PX4 握手获取 deviceID 与密钥的**消息契约**已在文档 10 §2.8 完整定义（§2.8.2 精确字段 / §2.8.7 实现约定），此处只列 CC 侧需要对齐的要点：

| 消息 | vtol_msgs 类型 | 方向 | 字段（顺序即 type hash 顺序） |
|------|----------------|------|------|
| 凭证请求 | `vtol_msgs::msg::DeviceCredentialRequest` | CC → PX4 | `uint64 timestamp`、`uint32 req_id` |
| 凭证应答 | `vtol_msgs::msg::DeviceCredential` | PX4 → CC | `uint64 timestamp`、`uint32 device_id`、`uint8[32] aes_key`、`uint32 req_id`、`uint32 cred_seq` |
| 凭证确认 | `vtol_msgs::msg::DeviceCredentialAck` | CC → PX4 | `uint64 timestamp`、`uint32 cred_seq` |

- **type hash 以 CC 侧 `vtol_msgs` 为权威**，PX4 uORB 逐字段镜像（含 `uint64 timestamp`，用纯 `uint64` 而非 `builtin_interfaces/Time`）。
- PX4 侧 uORB `.msg` 与 `dds_topics.yaml` 配置见文档 10 §2.8.2。

---

# 文件索引

| 文件 | 说明 |
|------|------|
| `src/vtol_communication/mavlink_dialect/vtol_safety.xml` | MAVLink 自定义消息方言（协议源头） |
| `src/mavlink/pymavlink/generator/C/include_v2.0/mavlink_helpers.h` | parser 放行补丁（L653） |
| `src/vtol_bringup/launch/px4_bridge.launch.py` | mavros Router + micro_ros_agent 配置（serial/UDP） |
| `src/vtol_bringup/launch/vtol_full.launch.py` | 主 launch，透传 agent 参数 + 启动 crypto 节点 |
| `src/vtol_communication/vtol_communication/mavlink_crypto.py` | 加解密核心（AES-256-GCM） |
| `src/vtol_communication/vtol_communication/mavlink_crypto_node.py` | 握手 + 加解密节点 |
| `tools/setup_mavlink.sh` | mavlink 定制包恢复脚本（固定 commit） |
| `abc_vtol.rosinstall` | mavros/micro_ros_agent 依赖声明 |

# 待实现清单

| 项 | 优先级 | 说明 |
|----|--------|------|
| nonce 同步扩展报文 | 高 | mavros 提取 counter 广播，消息定义 + PX4/abc_vtol 解析 |
| mavros nonce 重复检查 | 高 | 单一 lastNonce，拦截 counter ≤ lastNonce |
| 断连专用指令 + 应答 | 中 | 任务结束/解绑，文档 10 §2.9 |
| PX4 侧握手服务端 | 高 | device_credential uORB + uXRCE-DDS 配置 + 独立模块 `device_credential`（规格已定，见文档 10 §2.8.2 / §2.8.7） |
