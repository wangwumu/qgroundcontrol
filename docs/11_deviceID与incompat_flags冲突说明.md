# deviceID 高字节与 `incompat_flags` 冲突（已解决）

> 本文档记录 deviceID 复用 `incompat_flags` 字节时与 MAVLink 标准 parser 的冲突，以及对应的解决方案。协议层面的最终约定见 `10_deviceID与payload加密公共规范.md` §1.4、§1.5。

## 一、问题现象

当 `MAV_DEVICE_ID ≥ 0x01000000`（deviceID 第 25 位及以上有非零位）时，MAVLink 链路**双向静默全断**：

- 本机发送的每一帧，被对端（QGC / mavp2p / data_writer）的标准 MAVLink parser **在解密之前就丢弃**；
- 本机接收的每一帧，被 `mavlink_parse_char()` **在进入 `decrypt_message()` 之前就丢弃**；
- 全程**无任何报错**——因为帧在加密层之前就被丢了，加密层根本看不到它，也不会打印日志。

表现就是：链路像「天线断开」一样，但实际是 deviceID 配置值触发了帧格式冲突。

## 二、根因

改造方案把 MAVLink v2 帧头 4 个单字节字段重组为 32-bit deviceID：

```
偏移:   2         3         5         6
     ┌─────────┬─────────┬─────────┬─────────┐
     │ inc(1B) │ com(1B) │ sys(1B) │ comp(1B)│
     └─────────┴─────────┴─────────┴─────────┘
       deviceID  bit24~31  bit16~23  bit8~15   bit0~7
```

即 deviceID 的**最高字节（bit 24~31）被写入帧头的 `incompat_flags` 字节**（偏移 2）。

而 MAVLink v2 标准 parser（`mavlink_helpers.h` 的 `mavlink_frame_char_buffer`）在解析帧头时：

```c
rxmsg->incompat_flags = c;
if ((rxmsg->incompat_flags & ~MAVLINK_IFLAG_MASK) != 0) {  // MAVLINK_IFLAG_MASK == 0x01
    _mav_parse_error(status);   // 直接判为解析错误，丢帧
    ...
}
```

parser **只允许 incompat 字节为 `0x00` 或 `0x01`**（仅 bit0 是合法的 SIGNED 标志），bit1~7 被当作「必须理解但未知的保留标志」而拒绝整帧。

因此：只要 deviceID 的 bit24~31 有**任意一个非零位**，`incompat_flags` 字节就会带上 bit1~7，被 parser 判为非法帧丢弃。

## 三、约束冲突

| 来源 | 约束 | deviceID 可用范围 |
|------|------|------------------|
| 协议设计（spec §1.4） | `deviceID & 0x01000000 == 0`（仅 bit24 = 0） | **31 位** |
| MAVLink 标准 parser（未修改） | `incompat_flags ∈ {0x00, 0x01}`（bit1~7 也必须为 0） | **24 位** |

协议设计只要求 bit24（SIGNED 标志位）恒为 0，即 31 位可用；而标准 parser 额外拒绝 bit1~7，把可用范围压到 24 位。两者冲突。

## 四、解决方案

修改 MAVLink parser，去掉对 `incompat_flags` bit1~7 的拒绝检查，让 deviceID 的 bit25~31 进入 incompat 字节的 bit1~7。bit0 仍保留 SIGNED 判定（协议要求 bit24 恒 0，故 SIGNED 永不误触发）。

修改后 parser 的 `MAVLINK_PARSE_STATE_GOT_LENGTH` 分支：

```c
rxmsg->incompat_flags = c;
// 不再检查 incompat_flags & ~MAVLINK_IFLAG_MASK，放行 bit1~7
mavlink_update_checksum(rxmsg, c);
```

## 五、结果

deviceID 从「仅 24 位」恢复到协议设计的 **31 位**（bit24 恒 0，其余 31 位任意）。

**各组件必须同步**：PX4 / QGC / mavp2p / data_writer / mavros（companion computer 侧 MAVLink 透传桥）都要做同样的 parser 修改，否则仍会拒绝 deviceID ≥ `0x01000000` 的帧。PX4 侧的 fork 与修改位置见 `10_deviceID与payload加密公共规范.md` §1.5；mavros 经其 `libmavconn` 依赖 `mavlink` 包（wangwumu fork，parser 放行补丁已就位）获得同一放行。
