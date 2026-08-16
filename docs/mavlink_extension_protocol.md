# MAVLink 自定义扩展协议

> 本协议定义了 VTOL 飞行安全管理系统与地面站 (QGC) 之间的 MAVLink 自定义消息扩展。
> 消息 ID 使用 80000-80004 (避开 mavlink 标准库 vendor 范围 50000-60099)，
> 对 PX4 飞控透明（静默丢弃），不影响飞行安全。

---

## 1. 架构

```
QGC (扩展) → MAVLink 自定义消息 → mavlink-router (透明转发)
                                        │
                       ┌────────────────┼────────────────┐
                       │                                 │
                  PX4 飞控                      上位机 ROS2
              (静默丢弃, 不受影响)           (旁路监听, 拦截解析)
                                                   │
                                          ┌────────┴────────┐
                                          │                 │
                              mavlink_custom_receiver   gs_comms_monitor
                               (msg_id 80000-80003)     (HEARTBEAT + ACK)
                                          │
                              ┌───────────┼───────────┐
                              │           │           │
                     weather_forecast  alt_landing  sensor/video
                          点存储        备降点存储    ctrl 发布
```

**关键节点**:

| 节点 | 功能 |
|------|------|
| `mavlink_custom_receiver` | 旁路拦截 msg_id 80000-80003，解析为 ROS2 消息，内存存储 |
| `gs_comms_monitor_node` | 监听地面站 HEARTBEAT (msg_id=0) 和 COMMAND_ACK (msg_id=77)，管理通信链路 |
| `video_monitor_node` | 接收 `/vtol/video_control`，管理多摄像头（框架预留） |
| `emergency_actuator_node` | 接收 `/vtol/emergency_decision`，执行应急（备降/迫降） |

**依赖**:
- `pymavlink` — Python MAVLink 解析库
- `mavlink-router` — UDP 端点配置 (`udp://127.0.0.1:14551`)

---

## 2. 消息总览

| msg_id | 名称 | 方向 | 用途 | 实现状态 |
|--------|------|------|------|----------|
| 80000 | `WEATHER_FORECAST` | QGC → ROS2 | 天气预报数据（单点） | ✅ 解析框架 |
| 80001 | `ALTERNATE_LANDING` | QGC → ROS2 | 备降点数据 | ✅ 解析框架 |
| 80002 | `SENSOR_CTRL` | QGC → ROS2 | 传感器控制命令 | ✅ 解析框架 |
| 80003 | `VIDEO_CTRL` | QGC → ROS2 | 视频控制命令 | ⚠️ 框架预留 |
| 80004 | `NONCE_SYNC` | mavros → PX4/abc_vtol | nonce 同步（counter，明文） | ⏳ 待实现 |

> **实现状态说明**: 所有消息的 MAVLink 解析框架和 ROS2 消息映射已完成。
> 模拟模式下使用本地 JSON 数据管道，实时模式需配置 mavlink-router 端点。

---

## 3. 枚举定义

### 3.1 天气类型 (`VTOL_WEATHER_TYPE`)

| 值 | 名称 | 含义 |
|----|------|------|
| 0 | `VTOL_WEATHER_UNKNOWN` | 未知/未指定 |
| 1 | `VTOL_WEATHER_CLEAR` | 晴天 |
| 2 | `VTOL_WEATHER_CLOUDY` | 多云 |
| 3 | `VTOL_WEATHER_RAIN` | 小雨/中雨 |
| 4 | `VTOL_WEATHER_HEAVY_RAIN` | 大雨 |
| 5 | `VTOL_WEATHER_SNOW` | 雪 |
| 6 | `VTOL_WEATHER_FOG` | 雾/低能见度 |
| 7 | `VTOL_WEATHER_THUNDERSTORM` | 雷暴 |
| 8 | `VTOL_WEATHER_STRONG_WIND` | 强风 |
| 9 | `VTOL_WEATHER_HAIL` | 冰雹 |

### 3.2 严重等级 (`VTOL_WEATHER_SEVERITY`)

| 值 | 名称 | 含义 | 对应飞行安全动作 |
|----|------|------|-----------------|
| 0 | `VTOL_SEVERITY_UNKNOWN` | 未知 | — |
| 1 | `VTOL_SEVERITY_ADVISORY` | 信息通报 | 仅记录日志 |
| 2 | `VTOL_SEVERITY_WATCH` | 关注 | 通知飞手 |
| 3 | `VTOL_SEVERITY_WARNING` | 警告 | 考虑备降 |
| 4 | `VTOL_SEVERITY_CRITICAL` | 严重 | 立即返航/备降 |

### 3.3 备降点类型 (`VTOL_ALT_TYPE`)

| 值 | 名称 | 含义 |
|----|------|------|
| 0 | `VTOL_ALT_RUNWAY` | 铺装跑道 |
| 1 | `VTOL_ALT_FIELD` | 开阔地/草地 |
| 2 | `VTOL_ALT_WATER` | 水面（应急） |
| 3 | `VTOL_ALT_HELIPAD` | 直升机/VTOL 停机坪 |
| 4 | `VTOL_ALT_ROAD` | 道路 |
| 5 | `VTOL_ALT_OTHER` | 其他/未指定 |

### 3.4 传感器 ID (`VTOL_SENSOR_ID`)

| 值 | 名称 | 对应 ROS2 节点 |
|----|------|---------------|
| 0 | `VTOL_SENSOR_FRONT_LIDAR` | `front_lidar_driver` |
| 1 | `VTOL_SENSOR_REAR_LIDAR` | `rear_lidar_driver` |
| 2 | `VTOL_SENSOR_FRONT_MMWAVE` | `front_mmwave_driver` |
| 3 | `VTOL_SENSOR_TEMP_HUMIDITY` | `temp_humidity_sensor` |
| 4 | `VTOL_SENSOR_RAIN` | `rain_sensor` |
| 15 | `VTOL_SENSOR_ALL` | 全部传感器（广播） |

### 3.5 传感器命令 (`VTOL_SENSOR_CMD`)

| 值 | 名称 | 含义 |
|----|------|------|
| 0 | `VTOL_SENSOR_CMD_DISABLE` | 禁用传感器 |
| 1 | `VTOL_SENSOR_CMD_ENABLE` | 启用传感器 |

> **安全约定**: 应急状态（EMERGENCY）下，`px4_command_bridge` 状态机拒绝 GCS 传感器控制命令，
> 确保关键传感器不被误关。

### 3.6 摄像头 ID (`VTOL_CAMERA_ID`)

| 值 | 名称 | 含义 | 默认配置 |
|----|------|------|----------|
| 0 | `VTOL_CAMERA_NOSE` | 机头前视 | 1920×1080 @30fps, 4000kbps |
| 1 | `VTOL_CAMERA_DOWN` | 机腹下视 | 1280×720 @15fps, 2000kbps |
| 2 | `VTOL_CAMERA_TAIL` | 机尾后视 | 1280×720 @15fps, 2000kbps |
| 15 | `VTOL_CAMERA_ALL` | 全部摄像头（广播） | — |

### 3.7 视频命令 (`VTOL_VIDEO_CMD`)

| 值 | 名称 | 含义 |
|----|------|------|
| 0 | `VTOL_VIDEO_CMD_START_STREAM` | 开始推流 |
| 1 | `VTOL_VIDEO_CMD_STOP_STREAM` | 停止推流 |
| 2 | `VTOL_VIDEO_CMD_SET_RESOLUTION` | 设置分辨率 |
| 3 | `VTOL_VIDEO_CMD_SET_FRAMERATE` | 设置帧率 |
| 4 | `VTOL_VIDEO_CMD_SET_BITRATE` | 设置码率 |
| 5 | `VTOL_VIDEO_CMD_SNAPSHOT` | 拍快照 |
| 6 | `VTOL_VIDEO_CMD_RECONFIGURE` | 全参数重配置 |
| 7 | `VTOL_VIDEO_CMD_QUERY` | 查询状态 |

---

## 4. 消息详细定义

### 4.1 WEATHER_FORECAST (msg_id=80000)

**用途**: 地面站下发单点天气预报数据。多预报点通过发送多条消息实现，ROS2 端聚合。

**MAVLink 字段**:

| 字段名 | 类型 | 单位 | 说明 |
|--------|------|------|------|
| `latitude` | `int32` | degE7 | WGS84 纬度 (×10⁷) |
| `longitude` | `int32` | degE7 | WGS84 经度 (×10⁷) |
| `altitude` | `int32` | mm | MSL 高度 (mm) |
| `valid_from` | `uint32` | s | 预报有效起始 (UTC 秒) |
| `valid_to` | `uint32` | s | 预报有效结束 (UTC 秒) |
| `weather_type` | `uint8` | enum | 天气类型 (VTOL_WEATHER_TYPE) |
| `severity` | `uint8` | enum | 严重等级 (VTOL_WEATHER_SEVERITY) |
| `confidence` | `uint8` | % | 置信度 (0-100) |
| `wind_speed` | `uint16` | cm/s | 风速 (cm/s) |
| `wind_direction` | `uint16` | cdeg | 风向 (0=北, 厘度) |
| `temperature` | `int16` | cdegC | 温度 (摄氏 × 100) |
| `rainfall` | `uint16` | mm/h×10 | 降雨强度 (mm/h × 10) |
| `visibility` | `uint16` | m | 能见度 (m, 0=无限制) |
| `description` | `char[21]` | — | 文本描述 (非 null-terminated) |

**→ ROS2 `WeatherForecastPoint` 转换**:

| MAVLink | → ROS2 | 转换公式 |
|---------|---------|----------|
| `latitude` (degE7) | `latitude` (float64) | ÷ 10⁷ |
| `longitude` (degE7) | `longitude` (float64) | ÷ 10⁷ |
| `altitude` (mm) | `altitude_msl` (float32) | ÷ 1000 |
| `valid_from` (s) | `valid_from` (uint32) | 直通 |
| `valid_to` (s) | `valid_to` (uint32) | 直通 |
| `weather_type` | `weather_type` (uint8) | 直通 |
| `severity` | `severity` (uint8) | 直通 |
| `confidence` (%) | `confidence` (uint8) | 直通 |
| `wind_speed` (cm/s) | `wind_speed` (float32) | ÷ 100 |
| `wind_direction` (cdeg) | `wind_direction` (float32) | ÷ 100 |
| `temperature` (cdegC) | `temperature` (float32) | ÷ 100 |
| `rainfall` (mm/h×10) | `rainfall` (float32) | ÷ 10 |
| `visibility` (m) | `visibility` (float32) | 直通 |
| `description` (char[21]) | `description` (string) | `rstrip('\x00')` |

**存储**: 最多 50 个预报点（内存字典，键=`"lat,lon,from,to"`）

---

### 4.2 ALTERNATE_LANDING (msg_id=80001)

**用途**: 地面站下发备降点数据。每条消息承载一个备降点，多发多收。

**MAVLink 字段**:

| 字段名 | 类型 | 单位 | 说明 |
|--------|------|------|------|
| `site_id` | `char[16]` | — | 备降点唯一标识 (e.g. "alt_01") |
| `latitude` | `int32` | degE7 | WGS84 纬度 (×10⁷) |
| `longitude` | `int32` | degE7 | WGS84 经度 (×10⁷) |
| `altitude` | `int32` | mm | MSL 高度 (mm) |
| `site_type` | `uint8` | enum | 类型 (VTOL_ALT_TYPE) |
| `priority` | `uint8` | — | 优先级 (1=最高) |
| `runway_length` | `uint16` | m | 跑道长度 (m, 不适用时为 0) |
| `runway_heading` | `uint16` | cdeg | 跑道方向 (厘度, 不适用时为 0) |
| `surface_condition` | `uint8` | — | 场地条件 (0=未知, 1=干, 2=湿, 3=雪, 4=冰) |
| `distance_from_current` | `uint32` | m | 距当前飞行器直线距离 (由 QGC 计算) |
| `description` | `char[31]` | — | 文本描述 |

**→ ROS2 `AlternateLanding` 转换**:

| MAVLink | → ROS2 | 转换公式 |
|---------|---------|----------|
| `site_id` (char[16]) | `site_id` (string) | `rstrip('\x00')` |
| `latitude` (degE7) | `latitude` (float64) | ÷ 10⁷ |
| `longitude` (degE7) | `longitude` (float64) | ÷ 10⁷ |
| `altitude` (mm) | `altitude_msl` (float32) | ÷ 1000 |
| `site_type` | `site_type` (uint8) | 直通 |
| `priority` | `priority` (uint8) | 直通 |
| `runway_length` (m) | `runway_length` (float32) | 直通 |
| `runway_heading` (cdeg) | `runway_heading` (float32) | ÷ 100 |
| `surface_condition` | `surface_condition` (uint8) | 直通 |
| `distance_from_current` (m) | `distance_from_current` (float32) | 直通 |
| `description` (char[31]) | `description` (string) | `rstrip('\x00')` |

**存储**: 最多 20 个备降点（内存字典，键=`site_id`）

---

### 4.3 SENSOR_CTRL (msg_id=80002)

**用途**: 地面站远程控制上位机传感器的启用/禁用。

**MAVLink 字段**:

| 字段名 | 类型 | 说明 |
|--------|------|------|
| `target_system` | `uint8` | 目标系统 (1=上位机) |
| `target_component` | `uint8` | 目标组件 |
| `sensor_id` | `uint8` | 传感器 ID (VTOL_SENSOR_ID) |
| `command` | `uint8` | 命令 (0=DISABLE, 1=ENABLE) |
| `reserved` | `uint8[4]` | 保留 (设为 0) |

**→ ROS2 `SensorControl` 转换**:

| MAVLink | → ROS2 |
|---------|--------|
| `sensor_id` (uint8) | `sensor_id` (string) — 查表映射: 0→"front_lidar", 1→"rear_lidar", 2→"front_mmwave", 3→"temp_humidity", 4→"rain", 15→"all" |
| `command` (uint8) | `command` (uint8) — 直通 (0=DISABLE, 1=ENABLE) |
| — | `source` = `SOURCE_MAVLINK` (0) |

**ROS2 Topic**: `/vtol/sensor_control`

**安全机制**: `px4_command_bridge` 状态机有最终决定权 — EMERGENCY 状态下拒绝关闭关键传感器。

---

### 4.4 VIDEO_CTRL (msg_id=80003)

**用途**: 地面站远程控制视频监控节点。支持多摄像头选择、分辨率/帧率/码率调整。

> ⚠️ 当前为框架预留 — 视频采集、编码、推流逻辑尚未实现。

**MAVLink 字段**:

| 字段名 | 类型 | 单位 | 说明 |
|--------|------|------|------|
| `target_system` | `uint8` | — | 目标系统 |
| `target_component` | `uint8` | — | 目标组件 |
| `camera_id` | `uint8` | enum | 摄像头 (VTOL_CAMERA_ID) |
| `command` | `uint8` | enum | 命令 (VTOL_VIDEO_CMD) |
| `resolution_w` | `uint16` | px | 水平像素 (0=不变) |
| `resolution_h` | `uint16` | px | 垂直像素 (0=不变) |
| `framerate` | `uint8` | Hz | 帧率 (0=不变) |
| `bitrate_kbps` | `uint16` | kbps | 码率 (0=不变) |
| `codec` | `char[8]` | — | 编码格式 ("h264", "h265", "mjpeg"; 空=不变) |
| `reserved` | `uint8[6]` | — | 保留 (设为 0) |

**ROS2 Topic**: `/vtol/video_control` → `VideoControl` (直通映射，单位不变)

**状态反馈**: `/vtol/video_status` — `video_monitor_node` 发布 (1 Hz)

---

## 5. MAVLink 链路管理

### 5.1 地面站心跳监听

`gs_comms_monitor_node` 监听地面站 HEARTBEAT (`msg_id=0`):

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `heartbeat_timeout` | 3.0s | 超时判定通信中断 |
| `lost_timeout` | 5.0s | 判定地面站离线 |
| `response_timeout` | 10.0s | 紧急通知无 ACK 时自主行动 |
| `rssi_warn_threshold` | -80 dBm | 信号弱警告 |
| `link_quality_warn` | 50% | 链路质量差警告 |

### 5.2 自定义 MAV_CMD

| 命令 | 用途 | 状态 |
|------|------|------|
| `MAV_CMD_USER_DEFINED_EMERGENCY` | 飞行安全紧急通知 (TBD) | ⚠️ 命令号待注册 |

> **TBD**: 需要通过 MAVLink 官方注册自定义 MAV_CMD ID，避免与现有命令冲突。

---

## 6. PX4 安全性

所有自定义消息 (80000-80003) 对 PX4 飞控完全透明：

1. **静默丢弃**: PX4 不识别这些消息 ID，自动丢弃，不触发任何处理逻辑
2. **不占用带宽**: 自定义消息通过 mavlink-router 转发到上位机专用端口，不经过 PX4 的串口/MAVLink 链路
3. **不修改 PX4**: 无需修改 PX4 固件、mavlink 配置或参数
4. **故障隔离**: 上位机崩溃不影响 PX4；QGC 不发送自定义消息也不影响 ROS2 安全逻辑（使用本地 JSON 模拟数据）

---

## 7. 文件索引

| 文件 | 说明 |
|------|------|
| `mavlink_dialect/vtol_safety.xml` | MAVLink XML 方言定义（协议源头） |
| `mavlink_custom_receiver.py` | 消息拦截 + 解析 + 存储节点 |
| `gs_comms_monitor_node.py` | 地面站心跳监听 + 链路管理 |
| `weather_forecast_client.py` | 天气预报 HTTP API 客户端（备用） |
| `video_monitor_node.cpp` | 视频监控/图传节点 |

---

## 8. 待实现项

| 项目 | 优先级 | 说明 |
|------|--------|------|
| QGC 自定义插件 | 低 | QGC 需扩展 UI 以发送自定义消息（目前通过 JSON 模拟） |
| mavlink-router 端点配置 | 中 | 实飞时配置 UDP 14551 端口旁路监听 |
| MAV_CMD ID 注册 | 低 | 通过 MAVLink 官方注册 `MAV_CMD_USER_DEFINED_EMERGENCY` |
| weather_forecast 实时 API | 低 | 备用 HTTP API 客户端 (`weather_forecast_client`) |
| 视频推流 | 低 | GStreamer/V4L2 采集 + RTSP/WebRTC 推流 |
