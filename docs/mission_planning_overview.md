# QGroundControl 航线规划系统文档

## 1. 概述

航线（Mission）规划是 QGC 的核心功能之一,允许用户在地图上创建一系列飞行路径点（Waypoints）供无人机自动执行。QGC 支持多种任务类型：简单航点、起降、区域测绘、走廊扫描、建筑物扫描等。

---

## 2. 关联模块与关键文件

| 模块 | 文件 | 说明 |
|------|------|------|
| **PlanMasterController** | `src/MissionManager/PlanMasterController.h/cc` | 航线管理的顶层控制器,统筹 mission/geofence/rally 三大子模块 |
| **MissionController** | `src/MissionManager/MissionController.h/cc` | 航线可视化和管理界面控制器 |
| **MissionManager** | `src/MissionManager/MissionManager.h/cc` | 继承自 PlanManager,负责与飞控的航线传输 |
| **PlanManager** | `src/MissionManager/PlanManager.h/cc` | 底层协议实现：上下载、清除、断点续传 |
| **MissionItem** | `src/MissionManager/MissionItem.h/cc` | 单条航线项：command、frame、param1-7 等数据 |
| **SimpleMissionItem** | `src/MissionManager/SimpleMissionItem.h/cc` | 可视化包装层,添加 UI 相关属性（altitudeFact 等） |
| **VisualMissionItem** | `src/MissionManager/VisualMissionItem.h/cc` | 所有可视航线项的抽象基类 |
| **ComplexMissionItem** | `src/MissionManager/ComplexMissionItem.h/cc` | 复杂航线项基类（测绘、扫描等） |
| **MissionCommandTree** | `src/MissionManager/MissionCommandTree.h/cc` | 固件/机型 → 支持的命令分类树 |
| **MissionSettingsItem** | `src/MissionManager/MissionSettingsItem.h/cc` | 航线全局设置项（起点相机设置、速度设置） |
| **PlanView QML** | `src/PlanView/PlanView.qml` | 航线规划 UI |
| **PlanManager** | `src/MissionManager/PlanManager.h/cc` | **实际执行 MAVLink 协议**（MISSION_COUNT/REQUEST_INT/ITEM_INT/ACK） |
| **MissionController** | `src/MissionManager/MissionController.h/cc` | `save(missionJson)` 序列化所有航线项,`load(missionJson)` 反序列化 |

### 类继承关系

```
QObject
├── PlanManager                      # 底层协议：与飞控的 MISSION_PROTOCOL 通信
│   └── MissionManager               # 航线特有扩展（MISSION_CURRENT 跟踪、引导模式等）
│   └── GeoFenceManager              # 地理围栏管理
│   └── RallyPointManager            # 集结/返航点管理
├── PlanMasterController             # 顶层管理器：统筹 mission/geofence/rally 三大模块
├── VisualMissionItem                # 可视航线项抽象基类
│   ├── SimpleMissionItem            # 单个简单航点（包装 MissionItem）
│   │   └── TakeoffMissionItem       # 起飞航点（特殊子类）
│   └── ComplexMissionItem           # 复杂航线项抽象
│       ├── SurveyComplexItem        # 区域测绘
│       ├── CorridorScanComplexItem  # 走廊扫描（管线/道路）
│       ├── StructureScanComplexItem # 建筑物扫描
│       ├── FixedWingLandingComplexItem  # 固定翼着陆
│       └── VTOLLandingComplexItem       # VTOL 着陆
├── MissionItem                      # 底层数据项：command + param1-7 + frame
├── MissionCommandTree               # 命令分类树（按固件+机型筛选可用命令）
└── PlanCreator / 子类               # "新建航线" 向导
    ├── SurveyPlanCreator
    ├── CorridorScanPlanCreator
    ├── StructureScanPlanCreator
    └── BlankPlanCreator
```

---

## 3. 本地存储

### 3.1 存储路径

```
{savePath}/Missions/
```

- **savePath**: QGC 设置中的保存路径（`AppSettings::savePath()`）
- **Linux/Mac**: `~/Documents/QGroundControl/Missions/`
- **Windows**: `Documents/QGroundControl/Missions/`

### 3.2 文件格式

#### 3.2.1 `.plan`（JSON,主格式）

一个 `.plan` 文件包含 mission（航线）、geoFence（地理围栏）、rallyPoints（集结/返航点）三个独立章节：

```json
{
    "fileType": "Plan",             // 文件类型标识
    "version": 1,                   // 文件格式版本
    "groundStation": "QGroundControl",
    "mission": {                    // 航线章节
        "version": 2,               // 航线数据版本
        "plannedHomePosition": [    // 预设起飞点 [纬度, 经度, 高度(米)]
            47.63338976,
            -122.090763,
            20.0
        ],
        "firmwareType": 12,         // MAV_AUTOPILOT enum: 12=ARDUPILOTMEGA, 14=PX4
        "vehicleType": 2,           // MAV_TYPE enum: 2=QUADROTOR
        "cruiseSpeed": 15.0,        // 巡航速度 (m/s)
        "hoverSpeed": 5.0,          // 悬停速度 (m/s)
        "items": [                  // 航线项列表（核心内容）
            {
                "type": "SimpleItem",        // 类型: SimpleItem | ComplexItem
                "command": 22,               // MAV_CMD 命令编号
                "frame": 3,                  // MAV_FRAME: 3=GLOBAL_RELATIVE_ALT
                "autoContinue": true,        // 执行完自动进入下一项
                "doJumpId": 1,               // 唯一标识序号（内部管理）
                "coordinate": [              // [纬度, 经度, 高度(米)]
                    47.63311996,
                    -122.090763,
                    20.0
                ],
                "params": [0, 0, 0, null],   // params[1-4]（已废弃的旧格式遗留）
                "altitude": 20.0,             // 高度（可选）
                "altitudeMode": 2,            // 高度模式（可选）
                "cameraSection": {},           // 相机设置（可选）
                "speedSection": {}             // 速度设置（可选）
            },
            {
                "type": "ComplexItem",
                "complexItemType": "Survey",  // 复杂项类型标识
                "transectStyleComplexItem": { // 测绘/扫描专用结构
                    "altitude": 50.0,
                    "gridAngle": 45.0,
                    "gridSpacing": 10.0,
                    "turnaroundDiameter": 20.0,
                    ...
                }
            }
        ]
    },
    "geoFence": {                   // 地理围栏章节
        "version": 1,
        "polygon": [],              // 围栏多边形顶点列表
        "circles": []               // 圆形围栏（可选）
    },
    "rallyPoints": {                // 集结/安全返航点章节
        "version": 1,
        "points": []                // 返航点坐标列表
    }
}
```

JSON key 定义参考 `PlanMasterController`：
- `kPlanFileVersion` = `1`
- `kPlanFileType` = `"Plan"`
- `kJsonMissionObjectKey` = `"mission"`
- `kJsonGeoFenceObjectKey` = `"geoFence"`
- `kJsonRallyPointsObjectKey` = `"rallyPoints"`

#### 3.2.2 `.waypoints` / `.txt`（文本旧格式,兼容导入）

制表符分隔的文本格式,每行 12 个字段：

```
<seq> <isCurrent> <frame> <command> <param1> <param2> <param3> <param4> <param5> <param6> <param7> <autoContinue>
```

示例：
```
0	1	3	22	0	0	0	null	47.63311996	-122.090763	20	1
```

#### 3.2.3 `.kml`（导出格式）

QGC 可将航线导出为 KML（Keyhole Markup Language）,用于 Google Earth 等工具展示。不用于导入（仅导出）。

### 3.3 文件操作接口

| 操作 | QML Q_INVOKABLE | 说明 |
|------|-----------------|------|
| 保存 | `saveToFile(filename)` | 保存 .plan JSON 到指定路径 |
| 保存（当前文件） | `saveWithCurrentName()` | 使用当前文件名保存 |
| 打开 | `loadFromFile(filename)` | 加载 .plan / .waypoints / .txt |
| 从车辆加载 | `loadFromVehicle()` | 从飞控下载当前航线 |
| 发送到车辆 | `sendToVehicle()` | 将当前航线上传到飞控 |
| 发送到指定车辆 | `sendPlanToVehicle(vehicle, filename)` | 直接发送文件到指定车辆 |
| 清除 | `removeAll()` | 清除本地航线 |
| 全部清除（含飞控） | `removeAllFromVehicle()` | 同时清除飞控上航线 |
| 保存为 KML | `saveToKml(filename)` | 导出为 KML 格式 |

---

## 4. MAVLink 协议

### 4.1 协议标准

**MAVLink Mission Protocol**（标准 MAVLink 协议,非自定义扩展）：

| 消息 | ID | 方向 | 说明 |
|------|-------|------|------|
| `MISSION_COUNT` | 44 | QGC → 飞控 / 飞控 → QGC | 告知对方有多少条航线项 |
| `MISSION_REQUEST_INT` | 51 | 飞控 → QGC | 飞控请求指定序号的航线项（使用 int32 坐标） |
| `MISSION_ITEM_INT` | 73 | QGC → 飞控 | 发送具体航线项数据（坐标使用 degE7） |
| `MISSION_ACK` | 47 | 双方 | 传输结束确认（成功/错误码） |
| `MISSION_REQUEST_LIST` | 43 | 飞控 → QGC | 飞控请求获取航线列表 |
| `MISSION_CLEAR_ALL` | 45 | QGC → 飞控 | 清除所有航线项 |
| `MISSION_SET_CURRENT` | 41 | QGC → 飞控 | 设置当前执行的航线项 |
| `MISSION_CURRENT` | 42 | 飞控 → QGC | 飞控报告当前执行的航线项索引 |

**协议流程（上传航线）**:

```
QGC                                Flight Controller
  |                                       |
  |—— MISSION_COUNT (count=N) ————————→    |
  |                                       |
  |←—— MISSION_REQUEST_INT (seq=0) ————   |
  |—— MISSION_ITEM_INT (seq=0) ———————→    |
  |                                       |
  |←—— MISSION_REQUEST_INT (seq=1) ————   |
  |—— MISSION_ITEM_INT (seq=1) ———————→    |
  |              ...                       |
  |←—— MISSION_ACK (MAV_MISSION_ACCEPTED)   |
  |                                       |
```

**协议流程（下载航线）**:

```
QGC                                Flight Controller
  |                                       |
  |—— MISSION_REQUEST_LIST ————————————→    |
  |                                       |
  |←—— MISSION_COUNT (count=N) ————————   |
  |—— MISSION_REQUEST_INT (seq=0) —————→    |
  |←—— MISSION_ITEM_INT (seq=0) ————————   |
  |              ...                       |
  |←—— MISSION_ACK (MAV_MISSION_ACCEPTED)   |
  |                                       |
```

### 4.2 `MISSION_ITEM_INT` 字段详解

`mavlink_mission_item_int_t` 结构（`src/MissionManager/PlanManager.cc:376-430`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `seq` | uint16_t | 航线项序号（从 0 开始） |
| `frame` | uint8_t | 坐标系（MAV_FRAME enum） |
| `command` | uint16_t | MAV_CMD 命令编号 |
| `current` | uint8_t | 是否为当前活跃项（仅第一项=1） |
| `autocontinue` | uint8_t | 完成后自动进入下一项 |
| `param1` | float | 参数 1（含义取决于 command） |
| `param2` | float | 参数 2 |
| `param3` | float | 参数 3 |
| `param4` | float | 参数 4（常用于航向 yaw） |
| `x` / `param5` | int32_t | 纬度 degE7（×10⁷）或本地方位 |
| `y` / `param6` | int32_t | 经度 degE7（×10⁷）或本地偏移 |
| `z` / `param7` | float | 高度（米,参考系由 frame 决定） |
| `mission_type` | uint8_t | 任务类型（MAV_MISSION_TYPE） |

**坐标系 (MAV_FRAME)**:

| 值 | 名称 | 说明 |
|-----|------|------|
| 0 | GLOBAL | WGS84 经纬度 + MSL 高度 |
| 1 | LOCAL_NED | 本地 NED 坐标系 |
| 2 | MISSION | 任务坐标系 |
| 3 | **GLOBAL_RELATIVE_ALT** | **WGS84 + 相对起飞点高度（最常用）** |
| 4 | LOCAL_ENU | 本地 ENU 坐标系 |
| 5 | GLOBAL_INT | WGS84 + MSL 高度（int32） |
| 6 | GLOBAL_RELATIVE_ALT_INT | WGS84 + 相对高度（int32） |
| 7 | LOCAL_OFFSET_NED | 本地偏移 NED |

**任务类型 (MAV_MISSION_TYPE)**:

| 值 | 名称 | 说明 |
|-----|------|------|
| 0 | MISSION | 普通航线（默认） |
| 1 | FENCE | 地理围栏 |
| 2 | RALLY | 集结/返航点 |

### 4.3 重试与超时

PlanManager 中的协议参数（`src/MissionManager/PlanManager.h:58-63`）：

| 参数 | 值 | 说明 |
|------|-----|------|
| `_ackTimeoutMilliseconds` | 1500ms | 等待 ACK 超时（被动等待） |
| `_retryTimeoutMilliseconds` | 250ms | 主动重试请求超时 |
| `_maxRetryCount` | 5 次 | 最大重试次数 |

---

## 5. 航线项（Mission Item）可设置参数

### 5.1 命令 (MAV_CMD)

`command` 决定航线项的类型和行为。常用命令：

| MAV_CMD | 值 | 说明 | 坐标 | 必须参数 |
|---------|-----|------|------|----------|
| **NAV_WAYPOINT** | 16 | 普通航点 | ✅ | 悬停时间(s) + 接受半径(m) |
| **NAV_LOITER_UNLIM** | 17 | 无限盘旋 | ✅ | 半径(m) + 航向 |
| **NAV_LOITER_TURNS** | 18 | 指定圈数盘旋 | ✅ | 圈数 + 半径(m) |
| **NAV_LOITER_TIME** | 19 | 定时盘旋 | ✅ | 时间(s) + 半径(m) |
| **NAV_RETURN_TO_LAUNCH** | 20 | 返航 | ❌ | — |
| **NAV_LAND** | 21 | 降落 | ✅ | 精准降落(x/y) |
| **NAV_TAKEOFF** | 22 | 起飞 | ✅ | 俯仰角 + 高度 |
| **NAV_CONTINUE_AND_CHANGE_ALT** | 30 | 连续爬升/下降 | ✅ | 目标高度 + 速率 |
| **NAV_LOITER_TO_ALT** | 31 | 盘旋到指定高度 | ✅ | 半径 + 航向 + 目标高度 |
| **NAV_SPLINE_WAYPOINT** | 82 | 样条曲线航点 | ✅ | 悬停时间(s) |
| **NAV_GUIDED_ENABLE** | 92 | 进入引导模式 | ❌ | 1=开启 |
| **NAV_VTOL_TAKEOFF** | 84 | VTOL 起飞 | ✅ | — |
| **NAV_VTOL_LAND** | 85 | VTOL 降落 | ✅ | — |
| **NAV_FENCE_RETURN_POINT** | 5000 | 围栏返航点 | ✅ | — |
| **NAV_FENCE_POLYGON_VERTEX_INCLUSION** | 5001 | 围栏包含多边形顶点 | ✅ | — |
| **NAV_FENCE_POLYGON_VERTEX_EXCLUSION** | 5002 | 围栏排除多边形顶点 | ✅ | — |
| **NAV_FENCE_CIRCLE_INCLUSION** | 5003 | 围栏包含圆形区域 | ✅ | 半径(m) |
| **NAV_FENCE_CIRCLE_EXCLUSION** | 5004 | 围栏排除圆形区域 | ✅ | 半径(m) |
| **DO_JUMP** | 177 | 跳转到指定序号 | ❌ | 目标序号 + 执行次数 |
| **DO_CHANGE_SPEED** | 178 | 改变速度 | ❌ | 速度类型 + 速度(m/s) |
| **DO_SET_HOME** | 179 | 设置家点 | ✅ | — |
| **DO_SET_ROI** | 201 | 关注兴趣点 | ✅ | x/y/z 坐标 |
| **DO_SET_ROI_NONE** | 202 | 取消关注 | ❌ | — |
| **DO_MOUNT_CONTROL** | 205 | 云台控制 | ❌ | pitch/roll/yaw |
| **DO_VTOL_TRANSITION** | 3000 | VTOL 模式切换 | ❌ | 1=固定翼, 2=多旋翼 |

### 5.2 参数含义

每个 MAV_CMD 对 param1-4 + x/y/z(coord) 有不同含义。例如 `NAV_WAYPOINT` (16):

| 字段 | 含义 | 默认值 |
|------|------|--------|
| param1 | 悬停时间 (秒) | 0 |
| param2 | 到达/接纳半径 (米) | 0（使用默认） |
| param3 | 过点比例 (0=直线, 1=精确过点) | 0 |
| param4 | 预期航向 (度, NaN=不变) | NaN |
| x/param5 | 纬度 (度) | — |
| y/param6 | 经度 (度) | — |
| z/param7 | 高度 (米,由 frame 决定参考系) | — |

### 5.3 可选节（Sections）

SimpleMissionItem 可附加以下可选节：

| 节 | 类 | 字段 |
|----|----|------|
| 速度 | `SpeedSection` | `specifyFlightSpeed` + `flightSpeed` |
| 相机 | `CameraSection` | 相机触发设置、照片间隔等 |
| 云台偏航 | (内建) | `specifiedGimbalYaw` |
| 云台俯仰 | (内建) | `specifiedGimbalPitch` |
| 到达盘旋 | (内建) | `loiterRadius` |

### 5.4 坐标系高度模式

SimpleMissionItem 支持三种高度模式（`AltitudeFrame`）：

| 模式 | 说明 |
|------|------|
| Relative | 相对起飞点高度（对应 MAV_FRAME_GLOBAL_RELATIVE_ALT） |
| Absolute (AMSL) | 绝对海拔高度（对应 MAV_FRAME_GLOBAL） |
| Above Terrain | 地面以上高度（QGC 自动查询地形数据换算为 AMSL） |
| Calc Above Terrain | 自动计算的地面以上高度 |

### 5.5 全局航线设置项

`MissionSettingsItem` 提供以下全局设置：

| 设置 | 说明 | 位置 |
|------|------|------|
| `plannedHomePositionAltitude` | 预设起飞点高度 | 航线起始处 |
| `cameraSection` | 相机初始设置（照片/视频参数） | 航线起始处 |
| `speedSection` | 任务默认速度设置 | 航线起始处 |
| 任务结束动作 | MAV_CMD_NAV_LAND / DO_JUMP 等 | 航线最后 |

### 5.6 命令数据结构层次

```
MissionItem (底层数据)
  ├── sequenceNumber: int
  ├── command: MAV_CMD
  ├── frame: MAV_FRAME
  ├── autoContinue: bool
  ├── isCurrentItem: bool
  ├── param1 (double), param2, param3, param4, param5, param6, param7
  ├── doJumpId: int (= sequenceNumber 的别名)
  └── coordinate(): QGeoCoordinate (从 param5+6+7 转换)

SimpleMissionItem (可视化包装)
  ├── missionItem() : MissionItem& — 底层数据引用
  ├── altitude: Fact* — 高度（受 altitudeFrame 影响）
  ├── altitudeFrame: AltitudeFrame
  ├── amslAltAboveTerrain: Fact* — 实际 AMSL 高度
  ├── speedSection: SpeedSection*（可选）
  ├── cameraSection: CameraSection*（可选）
  ├── loiterRadius: double（如果是盘旋型）
  ├── specifiedFlightSpeed: double
  ├── specifiedGimbalYaw/Yaw: double
  └── appendMissionItems(items) → 将自身展开为原始 MissionItem 列表
```

### 5.7 PlanView 设置

`PlanView.SettingsGroup.json` 定义的航线规划相关设置：

```json
{
    "PlanView": {
        "defaultMissionAltitude": { "default": 50.0 },     // 默认航线高度(米)
        "defaultMissionSpeed": { "default": 5.0 },         // 默认航线速度(m/s)
        "defaultLandingAltitude": { "default": 10.0 },     // 默认降落高度(米)
        "defaultPatternAltitude": { "default": 50.0 },     // 默认复杂航线高度(米)
        "surveyAreaMaxSize": { "default": 10000 },         // 测绘区域最大面积
        "structureScanMaxHeight": { "default": 200 }       // 扫描最大建筑物高度
    }
}
```

---

## 6. 航点数量限制

### 6.1 协议层限制

- **MAVLink MISSION_COUNT** 中的 count 字段为 `uint16_t` → **最大 65535 个航点**
- **MAVLink 2.0** 单帧最大 payload 253 字节,每个 MISSION_ITEM_INT 约 37 字节 → 无单边限制

### 6.2 飞控固件限制

| 固件 | 最大航点数 | 说明 |
|------|-----------|------|
| PX4 | 取决于存储空间 | `MIS_COUNT` 默认为 -1（自动） |
| ArduPilot | **有限制** | 取决于 `MISSION_TOTAL` 参数和 flash 空间 |
| 实用限制 | 通常 ~100-500 | 超长航线在实际使用中不推荐 |

### 6.3 QGC 层限制

QGC 本**代码不设硬性上限**（无 `MAX_WAYPOINT` 常量）。实际限制由：
1. 目标飞控固件决定
2. 传输时的重试/超时机制在长达数千航点时可能超时
3. JSON 序列化时内存使用可能成为瓶颈

---

## 7. 复杂航线项

复杂航线项（`ComplexMissionItem`）在保存时会展开为多个底层 `MissionItem`。展开逻辑在 `appendMissionItems()` 中：

| 复杂类型 | `canonicalName` | 展开为 | 典型航点数 |
|----------|-----------------|--------|-----------|
| Survey | `"Survey"` | `DO_SET_CAM_TRIGG_DIST` + 多个 `NAV_WAYPOINT` | 不定（取决于网格密度） |
| Corridor Scan | `"CorridorScan"` | 类似 Survey 的扫描线 | 不定 |
| Structure Scan | `"StructureScan"` | 绕建筑物飞行的航点序列 | 取决于层数和分辨率 |
| FixedWing Landing | `"FixedWingLanding"` | `DO_CHANGE_SPEED` + `NAV_LOITER_TO_ALT` + `NAV_LAND` | ~5-10 |
| VTOL Landing | `"VTOLLanding"` | 减速+转换+降落 | ~5-8 |

**JSON 存储示例**（ComplexItem 嵌套结构）：

```json
{
    "type": "ComplexItem",
    "complexItemType": "Survey",
    "transectStyleComplexItem": {
        "altitude": 80.0,
        "cameraSection": { ... },
        "gridAngle": 30.0,
        "gridSpacing": 15.0,
        "turnaroundDiameter": 25.0,
        "visualTransectPoints": [ ... ],
        "items": [ ... ]
    }
}
```

---

## 8. 发送与同步流程

### 8.1 状态标记

PlanMasterController 通过两个 dirty 标志位追踪变更：

| 状态 | 说明 | 触发条件 |
|------|------|----------|
| `dirtyForSave` | 有未保存的本地修改 | 添加/删除/编辑航线项 |
| `dirtyForUpload` | 有未上传到飞控的修改 | 本地修改后、或从飞控下载后 |

### 8.2 发送流程

```
用户点击 "Send to Vehicle"
  ↓
PlanMasterController::sendToVehicle()
  ↓
MissionController::sendItems()  →  收集所有 VisualMissionItem
  ↓
PlanManager::writeMissionItems()
  ↓
MissionController::_appendMissionItems()  → 展平可视化项为 MissionItem[]
  ↓
PlanManager::_writeMissionCount()  →  发送 MISSION_COUNT
  ↓
MISSION_REQUEST_INT ↔ MISSION_ITEM_INT  →  逐项发送
  ↓
MISSION_ACK  →  完成
```

### 8.3 断点续传

`MissionManager::generateResumeMission(resumeIndex)` 支持从指定序号生成"断点续传"航线,包含从起始到 resumeIndex 的所有 DO_CMD 项,以及 resumeIndex 之后的完整航线。

---

## 9. 扩展点

| 扩展方式 | 方法 | 参考 |
|----------|------|------|
| 自定义复杂航线项 | 继承 `ComplexMissionItem`,实现 `appendMissionItems()` | `custom-example/src/MissionManager/PerimeterScanComplexItem.*` |
| 自定义 Plan Creator | 继承 `PlanCreator` | `custom-example/src/MissionManager/PerimeterScanPlanCreator.*` |
| 自定义命令分类 | `MissionCommandTree` 使用固件+机型分类树 | `src/MissionManager/MissionCommandList.json` |
| 保存/加载 Hook | `QGCCorePlugin::pre/post Save/Load To/From Json()` | `src/API/QGCCorePlugin.h` |

---

## 10. 参考

- **MAVLink Mission Protocol**: [https://mavlink.io/en/services/mission.html](https://mavlink.io/en/services/mission.html)
- **QGC 开发者指南**: [https://dev.qgroundcontrol.com/](https://dev.qgroundcontrol.com/)
- **PX4 航线文档**: [https://docs.px4.io/main/en/flying/missions.html](https://docs.px4.io/main/en/flying/missions.html)
- **ArduPilot 航线文档**: [https://ardupilot.org/copter/docs/common-mission-planning.html](https://ardupilot.org/copter/docs/common-mission-planning.html)
- 关键源码路径: `src/MissionManager/` (完整实现), `src/PlanView/` (UI), `test/MissionManager/` (测试)
