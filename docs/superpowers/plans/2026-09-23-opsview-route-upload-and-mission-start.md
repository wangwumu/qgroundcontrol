# 站点操作员：航线下发与进航线 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 站点操作员点「起飞」后，飞机**沿任务航线飞行**，而不是升到 20 m 悬停。

**Architecture:** 纯 QML + JS（零 C++ 源码改动，仅把一个新 `.qml` 加进 `CMakeLists.txt` 的 `QML_FILES`）。新增一个职责单一的组件 `OpsRouteSync.qml`（拉航点 → 构造 mission → 下发到**指定**飞机），由 `OpsView.qml` 在飞机握手完成时自动触发；起飞按钮的可用性读它的状态字。

**Tech Stack:** Qt 6.11.1 / QML / QtQuickTest (`QGCQmlQuickTests`) / `PlanMasterController` + `MissionController`（既有 C++ API）/ MAVLink mission 协议。

**Spec:** 无独立 spec 文档。用户 2026-09-23 明确裁定「**直接写实施计划**」（不要先写 spec）。设计裁定逐条记在下方 §设计依据，本计划从那些裁定论证。

---

## 设计依据（用户 2026-09-23 原话裁定）

| # | 裁定原文 | 落在本计划的哪一步 |
|---|---|---|
| a | 「必须把航线下发和进航线都做……**a. 在qgc与px4完成握手，即自动上传航线，航线传完了，在点亮"起飞"按钮**」 | Task 3（自动触发）+ Task 4（闸） |
| b | 「**起飞确认后自动进航线**」 | Task 5 |
| c | 「px4的gps必须完成定位后，才能起飞。我建议采用**2**」（＝用飞机当前 home 位置） | Task 4 的第二件判据 |
| d | 「我们每个航点都设置了高度，使用设置的高度（**不同的是，这个应该是一个绝对高度，不是对地高度**，你需要看看px4要什么高度，需要的话要做转换）」 | Task 1（`frame=0` = AMSL，零转换） |
| e | 起飞高度取「**第一个航点的高度**」 | Task 1 的 `takeoffAltitude()` |
| f | 「至于降落点的话，我们**稍后再做讨论**……把关于降落的流程**稍后再议**」 | **降落整个移出本次范围**；`command=21` 的站点航点本次按普通航点插入 |

---

## Global Constraints

以下每条对**所有** Task 生效，不再逐条重复。

1. **界面不得出现裸枚举值。** 任何状态字（`SCHEDULED` / `TAKEOFF` / `syncing` …）都必须先经映射函数转成中文再上屏。
2. **多机场景一律按 `deviceID` 取机，绝不用 `activeVehicle`。** 本站有两架同时在连时，`activeVehicle` 是"当前选中"的那架，会把指令/航线下到**另一架飞机**上。既有先例：`OpsView._vehicleForTask()`。
3. **注释里引用代码位置一律用函数锚点（`_guidedTakeoff`），不写裸行号。** 行号会被同文件任何一次增删静默顶偏（本项目已复发两次）。
4. **高度一律 AMSL，`frame = MAV_FRAME_GLOBAL(0)`。** `table_waypoint.altitude` 存的就是 AMSL（实测依据见 §现状与缺口），**零转换**直传。
5. **QML 改动后必须重新构建**：`src/OpsView/CMakeLists.txt` 用 `qt_add_qml_module(... QML_FILES ...)`，QML 是**编进资源**的，不是读盘。新增 `.qml` 文件必须同时加进那个 `QML_FILES` 列表并重新 configure。
6. **跑 `just` 前先 `source .venv/bin/activate`**（系统 `just` 1.21 太老）。
7. **本文档不授权任何 git 写操作。** 每个 Task 末尾的 commit 步骤需**逐次**明确授权后执行；默认不动 git。绝不 `git add -A`。
8. **`grep` 在本机是包装 `ugrep --ignore-files` 的 shell function**，会静默跳过 gitignore 目录。核查"是否存在 X"一律用 `command grep`。
9. **QGC 仓库根是 `~/qgroundcontrol`**；真库 `/home/wangsl/uavm/uavm/db_uavm.db`（只读访问一律 `mode=ro`）。

---

## 现状与缺口（实测，非推断）

用户报障：「**起飞后，px4升空到20米，悬停**」。根因是**两个叠加缺口**，本计划各修一个：

**缺口 ①（Task 5 修）：`OpsView` 的起飞动作只发 `MAV_CMD_NAV_TAKEOFF`。**

- `_guidedTakeoff(task)` 的全部内容是 `v.guidedModeTakeoff(20)`（硬编码 20 m）。
- `PX4FirmwarePlugin::guidedModeTakeoff` 只发一条 `MAV_CMD_NAV_TAKEOFF`。
- **该指令本来就不负责沿航线飞** —— PX4 执行完它进 `AUTO_LOITER` 悬停。所以"升到 20 m 悬停"是 PX4 **完整执行完它被要求做的事**。
- 佐证（飞行现场抓的飞机自述心跳）：`nav=4`（`AUTO_LOITER`）、`curr=-32768`（无当前航点哨兵值）。
- 「起飞并进入航线」的原子动作在 PX4 侧是「**切 AUTO_MISSION + 解锁**」：`PX4FirmwarePlugin::startMission` 的全部内容就是这两步，PX4 在 AUTO_MISSION 下遇第一个 takeoff item 自动起飞。QGC 自己的提示语也写着 `"Takeoff and start the current mission"`。
- **可调用性已核实**：`Vehicle::startMission()` 是 `Q_INVOKABLE`（`Vehicle.h`），QML 直接可调。

**缺口 ②（Task 1–4 修）：航线从未下发到 PX4。**

- PX4 的 `dataman` 文件 mtime 停在 **2026-08-28**，本次联调期间从未被写过。
- `OpsView.qml` 对 `MissionManager` / `MissionController` 是 **0 处引用**；动作全集只有 6 种（`checkout` / `cancelHandover` / `return` / `takeoff` / `land` / `park`）。
- 进航线的唯一实现在 `PX4FirmwarePlugin::startMission`，全仓调用者只有 `FlyView/GuidedActionsController.qml` —— 而本项目**不走 FlyView**。
- 飞机上挂的是 8 月遗留的 3 个苏黎世航点。

**关键事实（均已实测核实，实施时不要再猜）：**

| 事实 | 值 / 结论 | 核实方式 |
|---|---|---|
| 航点数据接口 | `GET /api/routes/:id/waypoints`，路由**无角色闸**（登录即可访问） | `router.go` |
| 前端能否拿到 `route_id` | **能**。`common/models/models.go` 的 `FlightTask.RouteID` 有 `json:"route_id"` | 读结构体定义 |
| `route_snapshot` 能否用 | **不能**。task 91103 与 route 20 的都是 `'{}'`（2 字节） | 真库只读查询 |
| `table_waypoint.altitude` 的参考系 | **AMSL**。route 4 的 `.plan` 为 `home 413 + z 50`，库内对应行是 **463.0** | 真库只读查询 |
| `command` 编号 | **两套同名不同义**，详见 Task 1 | 真库分布 + `.plan` 解析 |
| 飞机握手完成信号 | `Vehicle.initialConnectComplete`（`Q_PROPERTY`，参数同步之后） | 读 `Vehicle.h` |
| 握手顺序 | `InitialConnectStateMachine` 严格线性；参数（State 4）「完成」或「跳过」才进 Mission（State 5）。**State 5 是"下载"**，上传不在状态机里且 `sendToVehiclePreCheck()` 不查参数 | 读状态机源码 |
| 会不会被下载覆盖 | **不会**。`PlanMasterController::_autoLoadPlanFromManagerVehicle()` 被 `AuthController::backendLoggedIn()` 闸住直接 return | 读 `PlanMasterController.cc` |
| 自动下载的时序 | `startStaticActiveVehicle()` **同步**走完 `_activeVehicleChanged()`，闸住后立即返回 ⇒ 调用返回时 mission 是空的，**无竞态** | 同上 |
| QML 可达的 mission 构造 API | `MissionController::insertTakeoffItem()` / `insertSimpleMissionItem()`，均 `Q_INVOKABLE`，`visualItemIndex = -1` 表示追加到末尾 | 读 `MissionController.h/.cc` |
| 高度参考系怎么在 QML 里设 | `SimpleMissionItem.altitudeFrame`（`Q_PROPERTY`，**可写**）；`AltitudeFrameAbsolute` = `MAV_FRAME_GLOBAL` = AMSL | 读 `SimpleMissionItem.h` + `QGroundControlQmlGlobal.h` |
| 高度值怎么设 | `SimpleMissionItem.altitude` 是 `Fact*`（`Q_PROPERTY`）⇒ QML 里写 `item.altitude.rawValue = 463.0` | 读 `SimpleMissionItem.h` |
| ‼️ **为什么是 `rawValue` 不是 `value`** | `Fact.h:53` 的 `value` 是 `Q_PROPERTY(QVariant value READ cookedValue WRITE setCookedValue)` ⇒ **走用户单位换算**；`setCookedValue` = `setRawValue(_metaData->cookedTranslator()(value))`。该 Fact 的 metaData 由 `SimpleMissionItem.cc:194-200` 建（`setRawUnits("m")` ⇒ `setBuiltInTranslator()` ⇒ `_setAppSettingsTranslators()` **读 `UnitsSettings`**，注意 `setRawUserMax(121.92) // 400 feet` 就是按英尺定的）⇒ **用户把垂直距离单位设成英尺时，写 `value = 50` 会落库 50 ft = 15.24 m**，界面看不出来。`rawValue` 恒为米：QGC 自己内部传值即 `_param7Fact.setRawValue(_altitudeFact.rawValue())`（`SimpleMissionItem.cc:768`，MAVLink `param7` 单位就是米） | 读 `Fact.h` / `Fact.cc` / `SimpleMissionItem.cc` |
| 起飞项怎么插 | `insertTakeoffItem(home, **-1**)` —— **必须是 `-1`（append），不是 `0`**，理由见 Task 2 §④（`removeAll()` 清完的列表是 `[MissionSettingsItem]` 而非空表）；返回值当 `SimpleMissionItem` 用（实际类型是 `TakeoffMissionItem`，继承自它，QML 属性查找是运行时的）。坐标还要**另外显式写**（形参被忽略 + `flyView:true` 早退，见 §④b） | 读 `MissionController.cc` |
| `PlanMasterController` 的 QML 可达性 | `QML_ELEMENT`，`PlanView.qml` 只 `import QGroundControl` 即可实例化 | 读 `PlanView.qml` + 头文件 |
| 单测基础设施 | `QGCQmlQuickTests`（QtQuickTest，offscreen），用例在 `test/UnitTestFramework/QmlTesting/tests/tst_*.qml` | 读 `QmlTesting/CMakeLists.txt` |

**route 20 的真实数据**（Task 1 的期望值取自这里）：

```
seq 0  command=16  房山镇政府  39.748800   116.143400   altitude=50.0
seq 1  command=21  良乡区政府  39.748823   116.143486   altitude=50.0
```

⇒ 起飞高度（第一个航点的高度）= **50.0**（AMSL）。

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `src/OpsView/OpsCommon.js` | **修改** | 新增两个纯函数：`routeMissionItems()`（后端航点 → mission 描述数组）、`takeoffAltitude()`。放这里是因为它必须可单测，而 `.pragma library` 文件的顶层函数在测试里可直接访问（既有先例：`tst_OpsCommon.qml` 直接调 `OpsCommon._mecTwoPoints`）。 |
| `src/OpsView/OpsRouteSync.qml` | **新建** | 把一条航线同步到**指定的一架**飞机。对外只暴露 `state` / `statusText` / `synced`。 |
| `src/OpsView/CMakeLists.txt` | **修改** | 把新文件加进 `QML_FILES`（漏了会"文件在、运行时找不到类型"）。 |
| `src/OpsView/OpsView.qml` | **修改** | ① 接入自动同步触发（Task 3）；② 起飞闸加两件判据（Task 4）；③ 起飞动作换成 `startMission()`（Task 5）。 |
| `test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml` | **修改** | 新增 `routeMissionItems` / `takeoffAltitude` 的用例（Task 1）。 |

**为什么航线下发放进独立文件而不是继续堆在 `OpsView.qml`：** `OpsView.qml` 已经 58 KB。判断依据沿用该文件头部自己写的规则 —— 职责边界的判据是"**换个视图还要不要**"：`.qml` 里现在装的是"站点专属的**判定**与**动作**"（机位、出站/进站过滤）。而"拉航点 → 构造 mission → 下发"是一条自带状态机的**独立流程**（6 个状态、重试、失败原因），它与具体视图无关，只是被站点视图调用。把它留在 `OpsView.qml` 会让那个文件再多出一个与视图无关的状态机。

---

## Task 1: `OpsCommon.js` 新增航点→mission 的纯函数

**Files:**
- Modify: `src/OpsView/OpsCommon.js`（在文件末尾追加）
- Test: `test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml`（在末尾 `}` 之前追加）

**Interfaces:**
- Consumes: 无（纯函数，只吃实参）
- Produces:
  - `OpsCommon.routeMissionItems(wps) -> Array<{command:int, lat:double, lon:double, alt:double, frame:int}>`
  - `OpsCommon.takeoffAltitude(wps) -> double`（航线不可用时为 `NaN`）
  - `OpsCommon.MAV_CMD_NAV_WAYPOINT === 16`、`OpsCommon.MAV_FRAME_GLOBAL === 0`

**背景（写代码前必须知道）：`command` 有两套同名不同义的编号。**

| 来源 | `16` | `21` | `84` / `85` |
|---|---|---|---|
| `table_waypoint.command`（**航线设计域**） | 普通航点 | **站点**（"可降落的站点类型"标记，`site.go` 用它做闸） | 未使用 |
| MAVLink / `.plan`（**指令号**） | `MAV_CMD_NAV_WAYPOINT` | `MAV_CMD_NAV_LAND` | VTOL 起飞 / VTOL 降落 |

只有 `16` 恰好同值。**设计域的 `21` 与 MAVLink 的 `21` 数值巧合、语义无关** —— 看到 21 就当成降落指令是本项目最容易踩的坑之一（`route 20` 的 seq 1 就是 `command=21` 的"良乡区政府"）。本次按用户裁定 (f)，站点航点**下发时就是普通航点**。

实测依据：真库 `table_waypoint.command` 只有 `16`(×12) 与 `21`(×13) 两个值；而 `route 4` 的 `.plan` 里是 `84 / 16 / 85 / 16`（那是 VTOL 飞机上传的，走的是另一套编号）。

- [ ] **Step 1: 写失败的测试**

在 `test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml` 的**最后一个** `}` 之前追加：

```qml
    //-------------------------------------------------------------------------
    // routeMissionItems / takeoffAltitude：航线 → 待下发的 mission
    //（2026-09-23 站点操作员起飞前置动作：握手完成后自动下发航线）
    //-------------------------------------------------------------------------

    /// 与 `GET /routes/:id/waypoints` 响应**同形**。只列被读到的键：
    /// `lat` / `lon` / `altitude` / `command`。接口还下发 `id`/`name`/`code`/
    /// `company_id` 等，但**下发逻辑不该依赖它们**——多写会让下一个人以为
    /// 函数还读了别的字段，从而不敢动那些字段。
    function _wp(lat, lon, alt, cmd) {
        return { lat: lat, lon: lon, altitude: alt, command: cmd }
    }

    /// route 20 的两个真实航点（2026-09-23 从真库抄）。
    function _route20() {
        return [_wp(39.748800, 116.143400, 50.0, 16),
                _wp(39.748823, 116.143486, 50.0, 21)]
    }

    function test_routeMissionItems_emptyReturnsEmpty() {
        compare(OpsCommon.routeMissionItems([]).length, 0, "空数组应回空")
        compare(OpsCommon.routeMissionItems(null).length, 0, "null 应回空")
        compare(OpsCommon.routeMissionItems(undefined).length, 0, "undefined 应回空")
    }

    /// ‼️ 本用例钉死整条链路的**量纲**：高度原样透传 + `frame = 0`（AMSL）。
    /// 真值来自真库 route 4 的交叉验证 —— 该航线的 `.plan` 写 `home 413 + z 50`，
    /// 而库里对应的 `table_waypoint.altitude` 就是 **463.0** ⇒ 库值即 AMSL。
    /// 阴性对照：把 `frame` 写成 `3`（QGC `MissionItem` 的**默认值**，相对 home）
    /// ⇒ 463 会被当成"离地 463 米"⇒ 本用例必红。
    function test_routeMissionItems_altitudeIsAmslWithGlobalFrame() {
        var items = OpsCommon.routeMissionItems([_wp(39.7488, 116.1434, 463.0, 16)])
        compare(items.length, 1)
        compare(items[0].alt, 463.0, "高度必须原样透传，不得做任何转换")
        compare(items[0].frame, 0,
                "frame 必须是 MAV_FRAME_GLOBAL(0)=AMSL；写成 3 会让 463 被当成离地高度")
        compare(items[0].command, 16)
    }

    /// ‼️ `command=21` 是**航线设计域**的"站点"标记，不是 `MAV_CMD_NAV_LAND`
    ///（后者也恰好是 21，纯属数值巧合）。本次裁定"降落稍后再议"⇒ 站点航点
    /// 按普通航点下发。这条防的是"看到 21 就发降落指令"这个误读 ——
    /// 一旦误读，飞机会在中途**直接降落**，而界面上看不出任何异常。
    function test_routeMissionItems_siteWaypointBecomesPlainWaypoint() {
        var items = OpsCommon.routeMissionItems([_wp(39.748823, 116.143486, 50.0, 21)])
        compare(items.length, 1)
        compare(items[0].command, 16, "站点航点(设计域 cmd=21)下发时必须映射成 NAV_WAYPOINT(16)")
    }

    /// 未知的设计域 `command` ⇒ **整条航线作废**（回空数组），不做"跳过这一点"。
    /// ‼️ 跳过会让飞机飞出一条用户没画过的路径，而界面上点的编号仍然连续、
    ///    看不出少了哪一个。这里是 fail-closed：宁可起飞按钮不亮。
    function test_routeMissionItems_unknownCommandVoidsWholeRoute() {
        var wps = [_wp(39.7488, 116.1434, 50.0, 16), _wp(39.7489, 116.1435, 50.0, 99)]
        compare(OpsCommon.routeMissionItems(wps).length, 0,
                "含未知 command 时应整体作废，而不是静默跳过那一点")
    }

    /// 坐标无效（`(0,0)` / NaN / 缺字段）⇒ 同样整体作废，理由同上。
    /// `(0,0)` 是"没有定位"的常见缺省值，与 `isValidWaypoint` 同一口径。
    function test_routeMissionItems_invalidCoordinateVoidsWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        compare(OpsCommon.routeMissionItems([good, _wp(0, 0, 50.0, 16)]).length, 0, "(0,0) 应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(NaN, 116.1, 50.0, 16)]).length, 0, "NaN 纬度应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 116.1, NaN, 16)]).length, 0, "NaN 高度应作废")
        compare(OpsCommon.routeMissionItems([good, null]).length, 0, "null 元素应作废")
    }

    /// 顺序即输入顺序（调用方已按 `seq` 取好），且**不掺任何私货** ——
    /// 本函数不生成起飞项（起飞点的坐标是"飞机当前 home"，运行时才知道）。
    function test_routeMissionItems_preservesOrderAndAddsNoTakeoff() {
        var items = OpsCommon.routeMissionItems(_route20())
        compare(items.length, 2, "不该额外插入起飞项——起飞项由调用方在拿到 home 之后插")
        verify(Math.abs(items[0].lat - 39.748800) < 1e-9, "第 0 点顺序错了")
        verify(Math.abs(items[1].lat - 39.748823) < 1e-9, "第 1 点顺序错了")
    }

    /// 起飞高度 = **第一个航点的高度**（用户 2026-09-23 裁定 e）。
    /// route 20 两个点都是 50.0 ⇒ 期望 50.0。
    function test_takeoffAltitude_isFirstWaypointAltitude() {
        compare(OpsCommon.takeoffAltitude(_route20()), 50.0)
    }

    /// 航线不可用 ⇒ `NaN`（**不是 0**）。调用方据此拦住起飞。
    /// ‼️ 回 0 会让飞机起飞到"AMSL 0 米"——一个在界面上看不出错的数字。
    function test_takeoffAltitude_isNaNWhenRouteUnusable() {
        verify(isNaN(OpsCommon.takeoffAltitude([])), "空航线应回 NaN 而不是 0")
        verify(isNaN(OpsCommon.takeoffAltitude(null)), "null 应回 NaN")
        verify(isNaN(OpsCommon.takeoffAltitude([_wp(0, 0, 50.0, 16)])), "坐标无效应回 NaN")
        verify(OpsCommon.takeoffAltitude([]) !== 0, "回 0 是危险的兜底值")
    }
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol/build && ctest -R QmlQuickTests --output-on-failure
```

Expected: FAIL —— 报 `OpsCommon.routeMissionItems is not a function`（或 QML 的 `TypeError: Property 'routeMissionItems' of object ... is not a function`）。

若没构建过 `QGCQmlQuickTests`，先 `cd /home/wangsl/qgroundcontrol && cmake --build build --target QGCQmlQuickTests -j$(nproc)`。

⚠️ 测试文件是 `QUICK_TEST_SOURCE_DIR` 在**源码目录**里按文件系统 URL 直接读的，改 `.qml` 测试文件**不需要重新 configure**。

- [ ] **Step 3: 写最小实现**

在 `src/OpsView/OpsCommon.js` 的**末尾**追加：

```js
//--------------------------------------------------------------------------
// 航线 → mission items（站点操作员起飞前的航线下发）
//
// ‼️ 本文件是 `.pragma library`，顶层函数与 `var` 在 import 方和测试里**都可见**
//    （既有先例：`tst_OpsCommon.qml` 直接调 `OpsCommon._mecTwoPoints`）。
//--------------------------------------------------------------------------

/// `MAV_CMD_NAV_WAYPOINT`。
var MAV_CMD_NAV_WAYPOINT = 16

/// `MAV_FRAME_GLOBAL` —— 高度按 **AMSL**（绝对高度）解释。
///
/// ‼️ `table_waypoint.altitude` 存的就是 AMSL，故**零转换**直传，只需把参考系说清楚。
///    实测依据：`route 4` 的 `.plan` 写 `plannedHomePosition` 高度 413、航点 `z = 50`，
///    而库内对应的 `table_waypoint.altitude` 是 **463.0**（= 413 + 50）。
///    ⚠️ 反过来，QGC 的 `MissionItem` **默认** `frame = MAV_FRAME_GLOBAL_RELATIVE_ALT(3)`
///    （相对 home）——构造 mission 时不显式覆盖，463 会被当成"离地 463 米"。
var MAV_FRAME_GLOBAL = 0

/// 航线**设计域**的 `command` → MAVLink 指令号。未知 ⇒ `null`。
///
/// ‼️ **两套编号同名不同义**，别按数值猜：设计域的 `21` 是"站点"（可降落的站点类型
///    标记），而 MAVLink 的 `21` 是 `MAV_CMD_NAV_LAND`——数值巧合，语义无关。
///    本函数是这两套编号之间**唯一**的翻译点。
///
/// 未知值一律 `null`（fail-closed），由调用方把整条航线作废。
function _designCommandToMavCmd(c) {
    var n = Number(c)
    if (n === 16) return MAV_CMD_NAV_WAYPOINT   // 普通航点
    if (n === 21) return MAV_CMD_NAV_WAYPOINT   // 站点航点（用户 2026-09-23 裁定：降落稍后再议，本次按普通航点下发）
    return null
}

/// 把后端 `GET /routes/:id/waypoints` 的航点转成待下发的 mission 描述数组。
///
/// 产出**不含起飞项**——起飞项的坐标是"飞机当前 home 位置"（运行时才知道）。调用方
/// 拿到 home 后用 `MissionController::insertTakeoffItem()` 插在第 0 位。
///
/// 顺序即 `wps` 顺序（调用方已按 `seq` 取好）。
///
/// ‼️ **任何一点不可用 ⇒ 整条航线作废（回 `[]`）**，不做"跳过这一点"。跳过会让飞机
///    飞出一条用户没画过的路径，而界面上点的编号仍然连续、看不出少了哪个。
///
/// @param wps 航点数组，每项 `{lat, lon, altitude, command}`
/// @return `[{command, lat, lon, alt, frame}]`；任一输入不可用 ⇒ `[]`
function routeMissionItems(wps) {
    if (!wps || !wps.length) return []
    var out = []
    for (var i = 0; i < wps.length; i++) {
        var w = wps[i]
        if (!w) return []
        var mavCmd = _designCommandToMavCmd(w.command)
        if (mavCmd === null) return []
        // ⚠️⚠️ 【计划初稿 —— Task 1 已执行完毕，且**此处判据已被审查修正，不要照抄本块**】
        //    初稿这两条判据经首轮审查判定有两处缺陷：
        //      ① 坐标判据 `(lat === 0 && lon === 0)` 与注释自称的「与 `isValidWaypoint` 同一口径」
        //         **方向相反** —— `isValidWaypoint` 的判据是「**任一轴**为 0 即无效」。
        //         同一文件上方那段注释**逐字记录过这个错误的第一次**，并写着「假的一致比不一致更坏」。
        //      ② `Number(null) === 0`、`Number("") === 0`，而 `isFinite(0)` 为真
        //         ⇒ 0 从高度检查的正门走进来，`takeoffAltitude` 回 0 而非 NaN，调用方的起飞闸随之失效。
        //    复审进一步指出：**列黑名单治不了本** —— `Number(" ")`/`Number("0")`/`Number(false)`/`Number([])`
        //    同样都是 0，逐个列举永远漏。
        //
        //    **判据的唯一权威是 `src/OpsView/OpsCommon.js` 的 `routeMissionItems` 本体**，它现在：
        //      · 三个字段**前置**类型检查（不做隐式 `Number()` 转换 —— 治本是别隐式转换，不是列坏值）
        //      · 坐标有效性**直接调用**本文件的单点定义 `isValidWaypoint`
        //      · 数值 `0` **有意放行**（属数据问题而非类型问题），留给 Task 4 的起飞闸去判，且已钉成断言
        //    演变过程见 ledger Ruling 8–9、15–16；证据见 `task-1-review-report.md`。
        var lat = w.lat, lon = w.lon, alt = w.altitude   // 见 OpsCommon.js 的最终实现
        if (!isValidWaypoint(lat, lon)) return []
        if (!isFinite(alt)) return []
        out.push({ command: mavCmd, lat: lat, lon: lon, alt: alt, frame: MAV_FRAME_GLOBAL })
    }
    return out
}

/// 起飞高度 = **第一个航点的高度**（用户 2026-09-23 裁定 e）。
///
/// 航线不可用 ⇒ `NaN`（**不是 0**）：回 0 会让飞机起飞到"AMSL 0 米"，
/// 而那个数字在界面上看不出错。调用方靠 `isNaN` 拦住起飞。
function takeoffAltitude(wps) {
    var items = routeMissionItems(wps)
    return items.length ? items[0].alt : NaN
}
```

- [ ] **Step 4: 跑测试，确认全绿**

```bash
cd /home/wangsl/qgroundcontrol/build && ctest -R QmlQuickTests --output-on-failure
```

Expected: PASS，且 `tst_OpsCommon.qml` 里**既有**的 40+ 条用例同样全绿（本 Task 只加函数，不动既有函数）。

- [ ] **Step 5: 变异验证（证明这组用例有鉴别力）**

逐条做，**每次只改一处、跑完立刻还原**：

| 变异 | 必须变红的那一条 |
|---|---|
| `MAV_FRAME_GLOBAL` 改成 `3` | `test_routeMissionItems_altitudeIsAmslWithGlobalFrame` |
| `_designCommandToMavCmd` 里 `if (n === 21)` 那行的返回值改成 `21` | `test_routeMissionItems_siteWaypointBecomesPlainWaypoint` |
| `if (mavCmd === null) return []` 改成 `continue` | `test_routeMissionItems_unknownCommandVoidsWholeRoute` |
| `takeoffAltitude` 的 `: NaN` 改成 `: 0` | `test_takeoffAltitude_isNaNWhenRouteUnusable` |

⚠️ 变异期间工作区处于**不可编译/半成品**状态。**变异一结束立刻还原**，并用 `command grep` 复核磁盘（`git status` 干净也可能被异步后台扫描读到中间态）。

- [ ] **Step 6: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/OpsCommon.js test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml
git commit -m "feat(opsview): 航线→mission 的纯函数（AMSL 高度 + 两套 command 编号翻译）"
```

⚠️ **需用户逐次授权后才执行。**

---

## Task 2: `OpsRouteSync.qml` —— 把航线同步到指定飞机

**Files:**
- Create: `src/OpsView/OpsRouteSync.qml`
- Modify: `src/OpsView/CMakeLists.txt`（加进 `QML_FILES`）

**Interfaces:**
- Consumes: `OpsCommon.routeMissionItems()` / `OpsCommon.takeoffAltitude()`（Task 1）
- Produces:
  - `OpsRouteSync.state` ∈ `{"idle","fetching","building","sending","done","failed"}`（`readonly string`）
  - `OpsRouteSync.statusText`（`readonly string`，中文，界面只显示它）
  - `OpsRouteSync.synced`（`readonly bool`，`state === "done"`）
  - `OpsRouteSync.vehicle`（`Vehicle*`，可写）、`OpsRouteSync.routeId`（`int`，可写）、`OpsRouteSync.get`（`function(path, onDone)`，可写）
  - `OpsRouteSync.start()`（`function`）
  - `OpsRouteSync.reset()`（`function`）

**三个必须写进代码注释的理由（否则下一个人会"顺手改回去"）：**

1. **为什么不用 `activeVehicle`。** `PlanMasterController.managerVehicle` 缺省取 `MultiVehicleManager.activeVehicle()`（"当前选中"的那架）。本站两架同时在连时会把航线**下到另一架飞机**。故一律 `startStaticActiveVehicle(vehicle)` 把目标钉死 —— 与 `OpsView._guidedTakeoff` 注释里记录的是同一个坑。
2. **为什么 `flyView: true`。** `PlanMasterController::_activeVehicleChanged()` 的 `_flyView` 分支调 `_autoLoadPlanFromManagerVehicle()`（从飞机**下载** mission）。已登录后台时该函数被 `AuthController::backendLoggedIn()` 闸住直接 return ⇒ **不会**覆盖我们刚构造的航线。而 `flyView: false`（Plan 视图分支）在 `containsItems()` 时会走进弹窗路径。
3. **为什么高度要显式设 `altitudeFrame`。** `insertSimpleMissionItem()` 会从**前一个 item** 复制高度与 frame（`_findPreviousAltitude`），而 frame 只在全局设置为 `AltitudeFrameMixed` 时才复制。**不显式覆盖就是 QGC 的默认值 `AltitudeFrameRelative`** ⇒ 463 被当成离地高度。必须每个 item 都设。

- [ ] **Step 1: 写组件**

创建 `src/OpsView/OpsRouteSync.qml`：

```qml
import QtQuick
import QtPositioning

import QGroundControl

import "OpsCommon.js" as OpsCommon

/// @brief 把**一条**航线同步到**指定的一架**无人机（站点操作员起飞前的自动动作）。
///
/// 职责单一：给定 `vehicle` + `routeId`，拉航点 → 构造 mission → 下发；对外只暴露
/// 一个状态字 `state`。起飞按钮的可用性读它（见 `OpsView._takeoffBlockReason`）。
///
/// ‼️ **为什么不用 `activeVehicle`**：`PlanMasterController.managerVehicle` 缺省取
///    `MultiVehicleManager.activeVehicle()`（"当前选中"的那架）。本站有两架同时在连时
///    会把航线**下到另一架飞机**上——与 `OpsView._guidedTakeoff` 注释记录的是同一个坑。
///    这里一律 `startStaticActiveVehicle(vehicle)` 把目标钉死。
///
/// ‼️ **为什么 `flyView: true`**：`PlanMasterController::_activeVehicleChanged` 的
///    `_flyView` 分支会调 `_autoLoadPlanFromManagerVehicle()`（从飞机**下载** mission）。
///    已登录后台时它被 `AuthController::backendLoggedIn()` 闸住直接 return ⇒ **不会**
///    覆盖我们刚构造的航线。而 `flyView: false`（Plan 视图分支）在 `containsItems()`
///    时会走 `promptForPlanUsageOnVehicleChange` 弹窗路径。
///
/// ⚠️ 一次只服务一架飞机。同步完成后再 `startStaticActiveVehicle` 切到另一架是安全的
///    ——航线已经写进飞机，controller 里那份内容不再重要。
Item {
    id: root

    //-------------------------------------------------------------------------
    // 输入（由调用方注入）
    //-------------------------------------------------------------------------
    /// 目标无人机（`Vehicle*`）。null ⇒ `start()` 直接失败。
    property var    vehicle:  null
    /// 要下发的航线 id（后端 `table_flight_task.route_id`）。
    property int    routeId:  0
    /// 注入的 GET 函数：`function(path, onDone(status, data))`。
    /// 骨架的 `_get`（`OpsShell.qml`）签名的子集，这里只用到两参形式。
    property var    get:      null

    //-------------------------------------------------------------------------
    // 输出（调用方只读）
    //-------------------------------------------------------------------------
    /// `idle` / `fetching` / `building` / `sending` / `done` / `failed`。
    /// ‼️ 界面**永不**显示这个字面量——只显示 `statusText`（界面不得出现裸枚举）。
    readonly property string state:      _state
    /// 面向用户的一句话。失败时说明原因，中间态说明正在做什么。
    readonly property string statusText: _statusText
    /// 航线已在飞机上。**这是起飞闸的判据**。
    readonly property bool   synced:     _state === "done"

    property string _state:      "idle"
    property string _statusText: ""
    /// 本次下发的**真实航点数**（不含注入的起飞项）—— 完成文案用它。
    /// ‼️ **不要**改用 `missionController.visualItems.count` 做算术：那是 QGC 的内部结构。
    ///    实测 `visualItems` = 1 个 `MissionSettingsItem`（`MissionController.cc:104`
    ///    `_addMissionSettings(_visualItems)`，`:504` 的 `value<MissionSettingsItem*>(0)` 佐证）
    ///    + 1 个起飞项（`insertTakeoffItem` 走 append/insert，`:397-401`）+ N 个航点
    ///    = **N+2**，且各部分是否计入会随版本变。
    ///    这里报的是"我们构造了几个点"，单点定义、零猜测。
    property int    _waypointCount: 0

    //-------------------------------------------------------------------------
    // mission 容器
    //-------------------------------------------------------------------------
    /// ⚠️ `PlanMasterController` 的 `QML_ELEMENT` 挂在 `QGroundControl` URI 下
    ///    （`MissionManager/CMakeLists.txt` 的 `qt_add_qml_module` 是注释掉的，
    ///    既有先例 `PlanView.qml` 只 `import QGroundControl`）。
    PlanMasterController {
        id: _plan
        flyView: true
    }

    //-------------------------------------------------------------------------
    // 流程
    //-------------------------------------------------------------------------

    /// 开始同步。重复调用是幂等的：非 `idle` / 非 `failed` 时直接返回。
    function start() {
        if (_state !== "idle" && _state !== "failed") return
        if (!vehicle)      return _fail(qsTr("未指定无人机"))
        if (routeId <= 0)  return _fail(qsTr("该任务未关联航线"))
        if (!get)          return _fail(qsTr("缺少网络访问能力"))

        _state = "fetching"
        _statusText = qsTr("正在获取航线…")
        get("/api/routes/" + routeId + "/waypoints", function(status, data) {
            if (status !== 200 || !data) {
                // 后端对未知路由 / 无权限一律非 200；这里不区分，统一报"获取失败"，
                // 免得把 403 猜成 404 误导现场排查。
                return _fail(qsTr("航线获取失败（HTTP %1）").arg(status))
            }
            var wps = Array.isArray(data) ? data : (data.waypoints || data.data || [])
            if (!Array.isArray(wps)) wps = []
            // ‼️ 后端 `buildWaypoints`（uavm 仓 `gcs_server/handlers/route.go:1107-1113`）对**含 plan_data
            //    的航线**（QGC 上传的临时航线）会在序列**头部**插一个 `command = -1` 的 home 项
            //    （条件：`mission.plannedHomePosition` 恰好 3 个元素）。
            //    home **不是航点**：混进来会被 `routeMissionItems` 当成"未知命令"而**作废整条航线**
            //    ——那是 fail-closed 的静默失败，界面只显示"没有可用航点"，排查时看不出真凶。
            //    这里**只**摘掉这一个已知的接口附加项，**不放宽** `routeMissionItems` 对未知命令的作废语义：
            //    用户真正画的点少一个，仍然必须整条作废。
            //    （2026-09-23 真库实测：7 条未删航线中 4 条 TEMPORARY 会插 home；但任务按现行前端约束
            //     只能关联 FIXED 航线 ⇒ 本系统的任务链路**当前不触发**。按廉价防御处理，不定级为缺陷。）
            //    ⚠️ **本过滤只覆盖一半，不要把它当成"临时航线已支持"**：同一个 `buildWaypoints`
            //    在 plan_data 非空时还会用 `mission.items[i].command` **覆盖** `wps[i].Command`
            //    （起飞=84、降落=85，见 route.go:1102-1106）——`_designCommandToMavCmd(84|85)`
            //    同样回 `null` ⇒ 整条航线照样作废、且同样零诊断。
            //    两者**同源**（都只在 plan_data 非空时发生）⇒ 等到"任务能引用临时航线"的那天，
            //    -1 被摘掉、84/85 仍会让整条作废 ⇒ 这行过滤**不是完整修复**。
            //    84/85 的正确处置牵着「起飞项坐标必须是飞机当前 home」与「降落稍后再议」
            //    （用户 2026-09-23 裁定 f），**明确不在本次范围**。
            //    本行的实际价值仅限于一个子场景：plan_data 里有 plannedHomePosition、但 items 为空
            //    （此时覆盖不发生，只有 home 会被插进来）。
            wps = wps.filter(function(w) { return !w || w.command !== -1 })
            _buildAndSend(wps)
        })
    }

    /// 回到 `idle`，允许 `start()` 重来。切换目标飞机（同一任务重新同步）时调用。
    ///
    /// ‼️ **必须把轮询定时器一并停掉。** ［2026-09-23 fix round 2 修订］
    ///    只置 `_state` / `_statusText` 是不够的：`_sendPoll` 是 `repeat: true` 的，
    ///    `reset()` 返回后它**继续在跑**；而它读的 `_plan.syncInProgress` 来自
    ///    **同一个** controller 对象（下一轮 `_buildAndSend` 只是
    ///    `startStaticActiveVehicle` 换了飞机，对象没换）⇒ 旧轮询会在**新一轮**里
    ///    把状态置成 `done` —— 判据是那一刻恰好 `syncInProgress == false`
    ///    （比如新一轮还没走到 `sendToVehicle()`）。
    ///    ⇒ 表现：**航线还没下发，起飞按钮就亮了**。
    function reset() {
        _sendPoll.stop()
        _sendPoll.ticks = 0
        _state = "idle"
        _statusText = ""
    }

    function _buildAndSend(wps) {
        // ① 航点先过一遍纯函数的闸：任何一点不可用都会让整条航线作废（回 []）。
        //    这样"构造到一半才发现第 3 点没坐标"不会留下一个半成品 mission。
        var items = OpsCommon.routeMissionItems(wps)
        if (!items.length) return _fail(qsTr("航线没有可用航点，无法下发"))
        _waypointCount = items.length

        // ② 起飞点取**飞机当前 home 位置**（用户 2026-09-23 裁定 c）。
        //    GPS 未定位 ⇒ home 无效 ⇒ 没有可用的起飞坐标。这一步在闸上还会再判一次
        //    （Task 4），两处都留是有意的：这里防"下发一条起点错误的航线"，
        //    闸那里防"按钮亮着却点不动"。
        var home = vehicle.homePosition
        if (!home || !home.isValid) return _fail(qsTr("无人机尚未完成 GPS 定位，无法下发航线"))

        // ‼️ 判据写成 `!(takeoffAlt > 0)`，**不是** `takeoffAlt <= 0`、也**不再**是 `isNaN(takeoffAlt)`：
        //    · 数值 `0` 会**刻意**从 `routeMissionItems` 放行（那是数据问题不是类型问题，理由见
        //      OpsCommon.js 的注释），于是 `takeoffAltitude` 回 **0 而不是 NaN** ⇒ 原来的 `isNaN` 拦不住，
        //      飞机会被指令到 **AMSL 0 米**，而界面上看不出错；
        //    · 而 JS 里 `NaN <= 0` 是 **false** ⇒ 写成 `<= 0` 反而连 NaN 也漏（陷阱）。
        //    · `!(x > 0)` 一条同时覆盖 NaN 与 ≤0（`NaN > 0` 为 false ⇒ 取反为 true ⇒ 拦住）。
        //    （2026-09-23 真库实测：25 条航点全部 alt > 0，本场景当前不触发；且后端 `waypoint.Create`
        //      **不校验** altitude ⇒ 将来可以由接口建出 alt=0 的航点。按"廉价且严格更强"的替换处理。）
        var takeoffAlt = OpsCommon.takeoffAltitude(wps)
        if (!(takeoffAlt > 0)) return _fail(qsTr("航线起飞高度无效（首个航点高度必须大于 0），无法下发"))

        _state = "building"
        _statusText = qsTr("正在构造航线…")

        // ③ 绑定目标飞机。这一步**同步**走完 `_activeVehicleChanged()`；因为已登录
        //    后台，`_autoLoadPlanFromManagerVehicle()` 被闸住 ⇒ 不下载 ⇒ 无竞态，
        //    返回时 mission 是空的，可以安全地往下插。
        //    `deleteWhenSendCompleted = false`：本组件要复用，不能让 controller 自毁。
        _plan.startStaticActiveVehicle(vehicle, false)

        // ③b 无条件清一次残留条目。
        // ‼️ 正常路径下这里**本来就是空的**（已登录后台 ⇒ `_autoLoadPlanFromManagerVehicle()`
        //    被登录闸挡住 ⇒ 不下载）。但**不能把正确性押在那个闸上**：闸一旦因为任何原因
        //    没生效（登出瞬间、`backendLoggedIn()` 尚未置位、今后有人改了那段逻辑），
        //    下载回来的航点会留在 controller 里，我们再追加的结果是**整条航线被下成两遍**，
        //    而界面上完全看不出来——飞机会把每个点飞两次。
        //    这一行把"依赖上游闸生效"换成"本组件自己保证"。零成本，判据是 `containsItems`。
        if (_plan.containsItems) _plan.removeAll()

        _plan.missionController.setHomePosition(home)

        // ④ 起飞项。高度用**第一个航点的高度**（裁定 e），坐标用 home。
        //
        //    ‼️ 索引必须是 **-1（append）**，**不能**是 `0`。 ［2026-09-23 fix round 2 修订］
        //
        //    本行一度写的是 `0`，理由写在下面那句"此刻 mission 必为空 ⇒ 索引 0 等价于追加"。
        //    **那个理由本身是错的**（这是计划作者的错，不是实现者的错）：
        //    `MissionController::removeAll()`（`MissionController.cc:645`）走 `_setupNewVisualItems()`，
        //    而它（`:639-641`）在清空后**立刻**执行 `_addMissionSettings(_visualItems)`
        //    ⇒ 清完的列表是 **`[MissionSettingsItem]`，count == 1，并不是空表**。
        //    ⇒ 传 `0` 会走 `insert(0, …)`（`:400`）把起飞项插到 MissionSettings **前面**：
        //      `[Takeoff, Settings, wp1…]`；
        //    ⇒ 而 `MissionSettingsItem::appendMissionItems`（`MissionSettingsItem.cc:128-141`）
        //      会**无条件**追加 planned-home ⇒ 打包结果是 `[NAV_TAKEOFF, HOME, wp1…]`；
        //    ⇒ PX4 的 `sendHomePositionToVehicle()` 为 false ⇒ `PlanManager::writeMissionItems:70-75`
        //      取 `skipFirstItem = true` ⇒ **`delete missionItems[0]` 删掉的正是 NAV_TAKEOFF**；
        //    ⇒ 机上只拿到 `[HOME, wp1…]`，**根本没有起飞指令**，而界面看不出任何异常。
        //    ⇒ 传 `-1` 才对：`[Settings, Takeoff, wp1…]` ⇒ 打包 `[HOME, NAV_TAKEOFF, wp1…]`
        //      ⇒ `delete[0]` 删掉 HOME ⇒ 机上 `[NAV_TAKEOFF, wp1…]` ✓
        //
        //    旁证：QGC 自己的三个 PlanCreator —— `SurveyPlanCreator.cc:15`、
        //    `CorridorScanPlanCreator.cc:15`、`StructureScanPlanCreator.cc:15` —— **一律传 `-1`**：
        //    它们同样是"先在 `[Settings]` 上插起飞项、再 append 航点"这个顺序。
        //
        //    ⚠️ 高度不受这次改动影响：`insertTakeoffItem` 自己也会设高度
        //    （`_findPreviousAltitude`，`:392-395`），但下一行的 `_applyAltitude` 会**覆盖**它。
        var takeoff = _plan.missionController.insertTakeoffItem(home, -1)
        _applyAltitude(takeoff, takeoffAlt)

        // ④b 起飞项的**坐标**必须显式写。 ［2026-09-23 fix round 2 修订］
        //
        //    ‼️ 上面那个 `home` 实参**根本没被读过**：`insertTakeoffItem` 的签名是
        //    `(QGeoCoordinate /*coordinate*/, int, bool)`（`MissionController.h:120`）——
        //    形参被**显式注释掉**了，函数体从头到尾不碰它。
        //
        //    坐标本该由 `TakeoffMissionItem::_init` 来设（`.cc:66-68`：
        //    `if (_launchTakeoffAtSameLocation && homePosition.isValid()) SimpleMissionItem::setCoordinate(homePosition);`），
        //    但同一函数开头（`.cc:44-47`）是 `if (_flyView) { _initLaunchTakeoffAtSameLocation(); return; }`
        //    —— **提前 return**，而本文件用的正是 `flyView: true`（理由见上方 §为何 flyView）。
        //    ⇒ 那句 `setCoordinate` 永远不会执行，坐标停在 `SimpleMissionItem` 的默认值上：
        //      `_setDefaultsForCommand`（`:810-826`）把 `_mapCenterHint` 写进 param5/6，
        //      而 `SimpleMissionItem.h:180 QGeoCoordinate _mapCenterHint;` 是**默认构造** ⇒ lat/lon 是 **NaN**。
        //    ⇒ 结果是一条 param5/6 为 NaN 的 NAV_TAKEOFF —— 下到飞机上行为不可预期（也可能整项被拒）。
        //    ⇒ 显式写一次即可；`TakeoffMissionItem::setCoordinate`（`.cc:97-105`）会**顺带**
        //      把 `_settingsItem` 的坐标也设成同一个值，与我们已做的 `setHomePosition(home)` 一致，无副作用。
        if (takeoff) takeoff.coordinate = home

        // ⑤ 逐点追加。`visualItemIndex = -1` = append 到末尾。
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            var vi = _plan.missionController.insertSimpleMissionItem(
                        QtPositioning.coordinate(it.lat, it.lon), -1)
            _applyAltitude(vi, it.alt)
        }

        _state = "sending"
        _statusText = qsTr("正在下发航线…")
        _plan.sendToVehicle()

        // ⑥ `sendToVehicle()` 是异步的（MAVLink 逐项传输 + 等 MISSION_ACK）。这里用
        //    controller 自己的 `syncInProgress` 判定完成，而不是定时器猜。
        //    ⚠️ 不能只看一次：`sendToVehicle()` 返回时 `syncInProgress` 可能还没置起来。
        _waitForSendComplete()
    }

    /// 把高度与**参考系**一起写进一个 mission item。
    ///
    /// ‼️ `altitudeFrame` 必须**显式**设：`insertSimpleMissionItem()` 会从前一个 item
    ///    复制 frame，而只在全局设置为 `AltitudeFrameMixed` 时才真的复制；缺省路径
    ///    留下的是 QGC 的默认值 `AltitudeFrameRelative` ⇒ 库里的 AMSL 值会被当成
    ///    离地高度（用户 2026-09-23 裁定 d 明确要求"绝对高度，不是对地高度"）。
    function _applyAltitude(vi, amsl) {
        if (!vi) return
        vi.altitudeFrame = QGroundControl.AltitudeFrameAbsolute   // = MAV_FRAME_GLOBAL = AMSL
        vi.altitude.rawValue = amsl
    }

    /// 等 `syncInProgress` 走完一轮。用 `Timer` 轮询而不是 `Connections`：
    /// `PlanMasterController.syncInProgress` 的 `NOTIFY` 在一次发送里会**抖动多次**
    ///（mission / geoFence / rallyPoints 三个 manager 各自置一次），绑到信号上会提前
    /// 判定"完成"。轮询只看最终值，判据是**它稳定为 false**。
    function _waitForSendComplete() {
        _sendPoll.ticks = 0
        _sendPoll.restart()
    }

    Timer {
        id: _sendPoll
        interval: 500
        repeat: true
        property int ticks: 0
        onTriggered: {
            ticks++
            // 超时兜底：60 秒（120 个 tick）。现场链路慢时航线可能有几十个点。
            if (ticks > 120) {
                stop()
                return root._fail(qsTr("航线下发超时，请检查现场链路后重试"))
            }
            // ⚠️ `syncInProgress` 在发送开始后可能还没置起来 ⇒ 头几个 tick 看到 false
            //    不代表完成。用 `ticks < 2` 跳过头一秒，避开这个假完成。
            //
            // ‼️ 第二个条件 `!dirtyForUpload` 是**必需**的，不是保险。 ［2026-09-23 fix round 2 修订］
            //
            //    `PlanMasterController::sendToVehicle`（`.cc:307-329`）有**两条静默 return**：
            //      · `:315-318` —— `sharedLink` 为空（飞机正在关机 / 链路没了）⇒ 直接 return；
            //      · `:320-323` —— `offline()` 或 `syncInProgress()` ⇒ **只打 qCCritical**（日志），
            //        用户界面**看不到任何东西** ⇒ 照样 return。
            //    这两种情况下 `syncInProgress` **从来没有被置起来过** ⇒ 只看它的话，
            //    1 秒后 `ticks >= 2 && !syncInProgress` 就成立 ⇒ 报 `done` ⇒ **起飞按钮亮**
            //    ⇒ 用户点起飞，飞机按 **PX4 上的残留航线**飞（就是 8 月遗留的那 3 个苏黎世航点），
            //      界面上完全看不出来 —— **这正是用户报障的形状**。
            //
            //    `dirtyForUpload` 能判出这件事，理由是：
            //      · 我们插入航点后它**必为 true** —— `PlanMasterController.cc:57` 把
            //        `MissionController::dirtyChanged` 接到 `_updateOverallDirty`，后者
            //        （`:759-761`）调 `_setDirtyForSave(true)`，而 `_setDirtyForSave`（`:772`）
            //        会把 `_setDirtyForUpload(true)` 一并置上；
            //      · 它只在**整条**发送链（mission → geofence → rally，`:269` / `:284` / `:298`）
            //        全部走完后，才在 `_sendRallyPointsComplete`（`:301`）复位成 false；
            //      · 而上面那两条静默 return **一个槽都不会触发** ⇒ 它**保持 true**
            //        ⇒ 本轮永远不 done ⇒ 走到上面的超时分支 ⇒ **失败变成显式的** ✓
            //
            //    ⚠️ 这个判据**不会**像"要求曾观察到 `syncInProgress == true`"那样卡死：
            //       发送够快时（整段落在两次 tick 之间）两个条件在 tick 时刻**都已经满足**，
            //       `ticks >= 2` 照样能 done。（"曾观察到 true"那种写法在快发送下**永不 done**，
            //       只能等 60 秒超时 —— 比原缺陷更糟，已被否决。）
            //
            //    ⚠️ **已知残余（勿当成疏漏）**：飞机若回 **NACK**，这一路**仍会假 done** ——
            //       `MissionManager::sendComplete` 的信号签名是 `void()`（`:137` 的 connect
            //       没有 error 形参）⇒ 失败也照样推进整条链 ⇒ `dirtyForUpload` 照常复位。
            //       要根治得给 `MissionController` / `PlanMasterController` **新增**一个转发
            //       `PlanManager::sendComplete(bool error)` 的信号（对上游 fork 是**追加式**改动，
            //       不破坏兼容）。那是**独立的 C++ 工作包**，已记入 ledger 待裁决，
            //       **明确不在本计划范围内** —— 不要在这里顺手加 C++。
            if (ticks >= 2 && !_plan.syncInProgress && !_plan.dirtyForUpload) {
                stop()
                root._state = "done"
                // ‼️ 用 `_waypointCount`（本次构造的**真实航点数**），**不是**
                //    `missionController.visualItems.count`。后者实测 = 1 个
                //    `MissionSettingsItem` + 1 个起飞项 + N 个航点 = **N+2**
                //    （`MissionController.cc:104` / `:504` / `:397-401`），
                //    照它报数会把"N 个航点"说成"N+2 个" —— 用户直接看得见的错。
                root._statusText = qsTr("航线已下发（%1 个航点）").arg(root._waypointCount)
            }
        }
    }

    function _fail(msg) {
        _sendPoll.stop()
        _state = "failed"
        _statusText = msg
    }
}
```

- [ ] **Step 2: 把新文件注册进 `QML_FILES`**

修改 `src/OpsView/CMakeLists.txt`，在 `QML_FILES` 里按**字母序**插入 `OpsRouteSync.qml`（放在 `OpsCommon.js` 之后、`OpsShell.qml` 之前）：

```cmake
qt_add_qml_module(OpsViewModule
    URI QGroundControl.OpsView
    VERSION 1.0
    RESOURCE_PREFIX /qml
    QML_FILES
        AlertListPanel.qml
        OpsCommon.js
        OpsRouteSync.qml
        OpsShell.qml
        OpsView.qml
        RomView.qml
        RouteListPanel.qml
        SlotLayout.qml
        TaskListPanel.qml
    NO_PLUGIN
)
```

⚠️ **漏了这一步的失败形状**：文件在磁盘上、lint 可能过，但运行时 `OpsRouteSync is not a type` —— 因为 QML 是从**编译进二进制**的资源里加载的，不是读盘。

- [ ] **Step 3: 构建，确认能编译过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
cmake --build build -j$(nproc) 2>&1 | tail -30
```

Expected: 构建成功。新增 QML 文件会触发 CMake 重新 configure（`qt_add_qml_module` 的 `QML_FILES` 变化）。

⚠️ QML 语法错**不会**在此暴露（QML 是运行时解析的）。`just lint` 的 QML 部分在本机**必红**，是工具链版本问题、与文件无关 —— **不要**拿它当判据（要用 `~/Qt/6.11.1/gcc_64/bin` 那份工具链，且查漏 import 必须把文件复制到模块外再 lint）。

- [ ] **Step 4: 冒烟 —— 确认类型能被实例化**

在 `OpsView.qml` 里临时加一个**不可见**的探针（验证完**立刻删掉**）：

```qml
    // 临时冒烟探针：确认 OpsRouteSync 类型可解析、且默认状态是 idle。验证后删除。
    OpsRouteSync { id: _smokeProbe; visible: false }
    Timer {
        interval: 0; running: true
        onTriggered: console.log("SMOKE OpsRouteSync state =", _smokeProbe.state,
                                 "synced =", _smokeProbe.synced)
    }
```

> ‼️ **探针为什么用 `Timer` 而不是 `Component.onCompleted`（2026-09-23 实测，别改回去）**
>
> `OpsView.qml` **已经有一个** `Component.onCompleted`（用于 `_slotOrient` 的装载，在文件靠上的位置）。
> QML 里同一个对象**不能有两个**，而这个错误的表现是**灾难性且无声**的：
>
> `Property value set multiple times` ⇒ `Type OpsView unavailable` ⇒ `MainWindow` 加载失败、
> `mainWindow` 为 NULL、`VideoManager` Critical ⇒ **整个应用变空壳**（不是"探针没打出来"那么轻）。
>
> `Timer { interval: 0; running: true }` 在下一个事件循环 tick 触发 —— 那时组件树已构造完毕，
> 探针对象必定存在，且**不碰任何既有成员**。本 Task 的实现者踩过这个坑并按此形状绕过；
> 复核时确认 `OpsView.qml` 与基线**逐字节一致**（探针已精确还原）。
>
> ⚠️ 后续 Task（3/4/5）若也要写探针，**先 grep 确认目标文件有没有现成的 `Component.onCompleted`**：
>
> ```bash
> command grep -n "Component.onCompleted" /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
> ```
>
> **有** ⇒ 用上面的 `Timer` 形状（或折进既有的那个 handler）；**无** ⇒ 才能直接用 `Component.onCompleted`。
> （Task 3 的补扫入口**必须**用 `Component.onCompleted`，它的 brief 里已写了同样的先 grep 再决定的要求。）

启动 QGC（离屏、独立配置目录，**不干扰用户正在跑的实例**）：

```bash
cd /home/wangsl/qgroundcontrol
cp -r ~/.config/QGroundControl /tmp/qgc-rt-smoke-config
XDG_CONFIG_HOME=/tmp/qgc-rt-smoke-config QT_QPA_PLATFORM=offscreen \
  ./build/Debug/QGroundControl --allow-multiple 2>&1 | command grep "SMOKE"
```

Expected: 打出 `SMOKE OpsRouteSync state = idle synced = false`。

若打出 `OpsRouteSync is not a type` ⇒ 回 Step 2 检查 `CMakeLists.txt` 是否漏加、以及是否真的重新 configure 过。

- [ ] **Step 5: 删除探针并复核**

删掉 Step 4 加的两行。用 `command grep` 复核磁盘（**不要**只看 `git status`）：

```bash
command grep -n "SMOKE\|_smokeProbe" /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
```

Expected: 无输出（数到 0 才算收口）。

- [ ] **Step 6: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/OpsRouteSync.qml src/OpsView/CMakeLists.txt
git commit -m "feat(opsview): 新增 OpsRouteSync 组件——把航线同步到指定飞机"
```

⚠️ **需用户逐次授权后才执行。**

---

## Task 3: `OpsView.qml` 接入自动同步触发

**Files:**
- Modify: `src/OpsView/OpsView.qml`

**Interfaces:**
- Consumes: `OpsRouteSync`（Task 2）；`_tasks`（骨架 `OpsShell.qml:97` 的 `property var`，派生类直接可读）；`_get`（`OpsShell.qml` 提供）
- Produces: `OpsView._routeSyncs`（`{taskId: OpsRouteSync}`）、`OpsView._onVehicleConnected(vehicle)`、`OpsView._syncRouteForTask(task, vehicle)`

**触发点的三处（缺任一处都会漏掉一整类时序）：**

| # | 触发点 | 覆盖的时序 | 在哪一步 |
|---|---|---|---|
| 1 | 信号 `initialConnectComplete` | 飞机**晚于**视图加载才连上 | Step 1（`Repeater` + `Item`） |
| 2 | `Component.onCompleted` | 飞机与任务**都早于**视图加载就位 | Step 2 入口① |
| 3 | `on_TasksChanged` | 任务**晚于**视图加载才到手 | Step 2 入口② |

三者都调同一个幂等函数，重复触发无害。判据用 `vehicle.initialConnectComplete` **属性**（`Vehicle.h` 的 `Q_PROPERTY`），不是等信号——信号只发一次。

**幂等判据是 `_routeSyncs[task.task_id]` 是否存在**，不是"同步成功"——正在同步中（`fetching`/`building`/`sending`）也不能重开一份，否则两路 XHR + 两个 `sendToVehicle()` 会互相打架。

- [ ] **Step 1: 加同步容器与触发**

在 `OpsView.qml` 里、`_vehicleForTask()` **正上方**（紧邻它，因为两者是配套的多机取机逻辑）插入：

```qml
    //=========================================================================
    // 航线下发（2026-09-23 用户裁定 a）
    //
    // 「在qgc与px4完成握手，即自动上传航线，航线传完了，在点亮"起飞"按钮」
    //
    // 每个任务一份 `OpsRouteSync`，值挂在 `_routeSyncs[task_id]` 上。
    // 起飞闸（`_takeoffBlockReason`）读它的 `synced`。
    //=========================================================================
    property var _routeSyncs: ({})

    /// 取出任务对应的同步器（没有就造一个）。**幂等**：已存在时直接返回旧的。
    ///
    /// ‼️ 幂等判据是"这个 key 存不存在"，**不是**"同步成功没" —— 正在同步中也不能
    ///    重开一份，否则两路 XHR + 两个 `sendToVehicle()` 会互相打架，且后一份的
    ///    `startStaticActiveVehicle` 会把前一份刚绑定的 mission 清掉。
    function _syncRouteForTask(task, vehicle) {
        if (!task || !task.task_id || !task.route_id) return null
        // ‼️ **只对尚未起飞的任务下发航线。** 判据是 `status ∈ {SCHEDULED, READY}`，
        //    与起飞按钮的渲染条件（`TaskListPanel.qml` 里那个 `visible`）、`_canTakeoff`（本文件同函数名）
        //    是**同一个集合** —— 三处要同步改。
        //
        //    为什么必须有这道闸（2026-09-23 真库实测，**不是假想**）：
        //    `/ops/overview` 的 WHERE 是
        //    `t.deleted_at IS NULL AND COALESCE(t.uav_id,0) <> 0`（uavm 仓
        //    `gcs_server/handlers/ops.go:180`）—— **没有 status 过滤**；而 `device_id`
        //    来自 `JOIN table_uav`（`:167`）⇒ **历史任务也带着 device_id**。
        //
        //    真库当前就有：`device_id=91002` 挂着 **2 个**任务 —— `91102:READY`（活跃）
        //    与 `91104:CANCELED`（历史）。两者 `device_id` 相同 ⇒ 都会匹配。
        //
        //    没有这道闸的后果：两个任务各建一个 sync、各自 `sendToVehicle()`，
        //    两条航线**互相覆盖**，最终飞机上是哪条**取决于 XHR 返回时序（不确定）**；
        //    而两个 sync 各自都会报 `done` ⇒ 起飞闸照样放行 ⇒
        //    **飞机可能按已取消任务的航线飞，界面上完全看不出来** —— 比"没下发"更危险。
        //
        //    `TAKEOFF` / `IN_FLIGHT` 等已在飞的状态同样要挡：那时下发会打断正在执行的任务。
        if (task.status !== "SCHEDULED" && task.status !== "READY") return null
        var ex = _routeSyncs[task.task_id]
        if (ex) {
            // 目标飞机换了（同一任务改派了另一架）⇒ 重置后重发。
            if (ex.vehicle !== vehicle) { ex.reset(); ex.vehicle = vehicle; ex.start() }
            return ex
        }
        var sync = _routeSyncComponent.createObject(opsView, {
            "vehicle": vehicle,
            "routeId": task.route_id,
            "get":     _get
        })
        if (!sync) {
            // `createObject` 失败在 QML 里**不报错**，只静默回 null。
            console.warn("OpsView: OpsRouteSync 创建失败，任务", task.task_id, "的航线不会下发")
            return null
        }
        // ‼️ **必须整体重新赋值 `_routeSyncs`，不能写 `_routeSyncs[task.task_id] = sync`。**
        //
        //    `property var` 持有 JS 对象时**按引用比身份**：`_routeSyncs[id] = sync` 是
        //    **原地改内容**，**不发 `_routeSyncsChanged`** ⇒ 读它的绑定**不重估**。
        //
        //    而 Task 4 的 `_canTakeoff` 会通过 `_routeSyncs[task.task_id]` 建立绑定依赖，
        //    那个绑定是**起飞按钮的 `enabled`**（`TaskListPanel.qml:270`：
        //    `enabled: panel.canTakeoffFn ? panel.canTakeoffFn(modelData) : false`），
        //    它由「函数调用」间接读 —— QML 的依赖捕获跟着整个调用栈走，**所以能建立**。
        //
        //    **时序才是问题**：QML 的属性绑定在**子组件初始化时首次求值**，
        //    **早于**根组件的 `Component.onCompleted`。而"飞机早于视图加载就连好"
        //    这一路（正是最常见的一路：用户准备起飞时飞机必然已连）走的恰是
        //    `Component.onCompleted` → `_syncRoutesForAlreadyConnected()` → 本函数。
        //    ⇒ 首次求值时 `_routeSyncs` 还是空的 `({})`，`sync` 是 `undefined`，
        //    **那次求值没有建立对任何 sync 属性的依赖**。
        //    ⇒ 若这里不发信号，按钮会**一直灰着**，只能等 `_tasks` 指纹变化
        //    （而它有内容指纹守卫，`OpsShell.qml:543-545`；飞机静止时可能很久不变）
        //    或 `multiVehicleManager.vehicles` 变化才偶然重估。
        //    ⇒ 用户看到的是"航线早就传完了，起飞按钮却一直不亮"—— 正是裁定 (a) 要消灭的现象。
        //
        //    先例同源：`OpsShell.qml:543-545` 的 `_tasks = data` 也是**整体替换**
        //    （那边是为了让委托重建，这边是为了让绑定重估；同一个 QML 语义）。
        var m = _routeSyncs
        m[task.task_id] = sync
        _routeSyncs = m
        sync.start()
        return sync
    }

    Component {
        id: _routeSyncComponent
        OpsRouteSync { }
    }

    /// 某架飞机握手完成（参数已同步、`initialConnectComplete` 已置位）⇒ 把它名下
    /// 尚未同步的任务挂上航线下发。
    ///
    /// ‼️ 用 `deviceID` 匹配，**不用** `activeVehicle`（多机场景会把航线发错飞机）。
    function _onVehicleConnected(vehicle) {
        if (!vehicle) return
        var ts = _tasks
        if (!ts) return
        for (var i = 0; i < ts.length; i++) {
            var t = ts[i]
            if (!t || !t.device_id || t.device_id !== vehicle.deviceID()) continue
            if (!t.route_id) continue
            _syncRouteForTask(t, vehicle)
        }
    }

    /// 补扫：QGC 启动时飞机**已经**连好的那一批——`initialConnectComplete` 早发过了，
    /// 信号等不到。判据用属性而不是信号。
    function _syncRoutesForAlreadyConnected() {
        var vs = QGroundControl.multiVehicleManager.vehicles
        for (var i = 0; i < vs.count; i++) {
            var v = vs.get(i)
            if (v && v.initialConnectComplete) _onVehicleConnected(v)
        }
    }

    /// 飞机名单变化的监听：**每架飞机挂一个 `Connections`**，`Repeater` 会随
    /// `vehicles` 自动增删委托。
    ///
    /// ‼️ 为什么是 `Repeater` + 空 `Item` 包装，而不是看起来更省事的
    ///    `Instantiator { delegate: Connections { ... } }`：
    ///    `Instantiator` 确实能创建非 `Item` 对象，但**本仓库的两个非 Item 先例
    ///    （`ShapePath`、`QGCMenuItem`）都把创建出来的对象交给了别人保管**
    ///    （`onObjectAdded` 插进 Shape 的 data list / 插进菜单）——「`Instantiator`
    ///    自己持有一个非 `Item` 且不转手」**没有任何先例**，是在赌 Qt 的生命周期语义。
    ///    而空 `Item` 包装（多一个不可见 Item，代价可忽略）走的是全标准用法：
    ///    `Repeater` + `Item` delegate + `modelData`（全仓 **324 处**先例）。
    ///    先例：`FlyView/FlyViewMap.qml` 的 `Repeater { model: ...multiVehicleManager.vehicles }`。
    ///
    /// ‼️ `onInitialConnectComplete` 这个处理器名**不是笔误**：`Vehicle` 的
    ///    `initialConnectComplete` 属性用的 NOTIFY 信号就叫 `initialConnectComplete`
    ///    （`Vehicle.h:214`，没有 `Changed` 后缀——QGC 的非标准命名）。
    ///    处理器名 = `on` + 信号名首字母大写。
    Repeater {
        model: QGroundControl.multiVehicleManager.vehicles
        Item {
            visible: false
            Connections {
                target: modelData
                function onInitialConnectComplete() { opsView._onVehicleConnected(modelData) }
            }
        }
    }
```

- [ ] **Step 2: 补两个补扫入口**

⚠️ **不要**去找 `_bootstrap` 挂——它在骨架 `OpsShell.qml:742`，**不在本文件**；而且它有 `if (!routeLayersEnabled)` 的早返回分支（站点视图正是这条），补扫会落在返回之后、永远不执行。

补扫要加**两个**入口，因为 `initialConnectComplete` 信号只发一次，视图晚加载就漏了。先在 `OpsView.qml` 里 grep 确认有没有现成的 `Component.onCompleted`：

```bash
command grep -n "Component.onCompleted" /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
```

**已经核验过：本文件有一处**，在 `OpsView.qml` 的 `_loadSlotOrient` 被赋值处
（`Component.onCompleted: _slotOrient = _loadSlotOrient()`，其上方有一段注释解释
为什么必须用 `Component.onCompleted` 而不是属性绑定）。

⇒ **走"有"这一支，且必须把它改写成块**，把补扫**放进同一个块里**：

```qml
    Component.onCompleted: {
        _slotOrient = _loadSlotOrient()
        // 补扫入口①：视图加载时，飞机可能**早已**连好（握手信号早发过、等不到）。
        _syncRoutesForAlreadyConnected()
    }
```

‼️ **绝不能把 `Component.onCompleted: _syncRoutesForAlreadyConnected()` 作为新的一行插进去。**
QML 里同一个对象**不能有两个** `Component.onCompleted`：后一个**静默覆盖**前一个，
不报错、不警告、构建也过 ⇒ 那一行 `_slotOrient = _loadSlotOrient()` 被丢掉，
**用户存过的机位朝向偏好每次都回到默认 `"N"`**（该偏好 2026-09-18 经真机验收）。
这是"改一处、静默弄坏另一处"的典型形状 —— 所以**必须**并进同一个块。

改完自查：

```bash
command grep -n "Component.onCompleted" /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
```

Expected: **恰好两行** —— 一行在注释里（以 `//` 开头那句解释），一行是**代码**。
**代码行只能有一条**（块形式，带 `{`）。⚠️ 改前实测该文件 `Component.onCompleted`
字样共出现 **2 次**（1 处注释 + 1 处代码）⇒ 改后**次数仍是 2**，
所以**不能**用 `grep -c` 的数值变化当判据，要看**代码那一行是不是块**。

紧接着再加补扫入口②：

```qml
    // 补扫入口②：任务列表到位后。`_tasks` 是骨架的属性（`OpsShell.qml:97`），
    // 本文件是 `OpsShell` 的派生类，可以直接给它写信号处理器。
    // ⚠️ QML 对下划线开头属性的处理器命名是 `on_` + **保持首字符、第二个字母大写**
    //    （先例：`on_ActiveVehicleChanged` / `on_FlightModeChanged`）。
    // ‼️ `_tasks` 的赋值**带内容指纹守卫**（`OpsShell.qml:543`：`json !== _tasksJson`
    //    才赋）⇒ 本处理器**只在任务载荷真的变了时**触发，**不是** 2s 心跳。
    //    所以入口①不可省——"飞机与任务都早已就位"这一路只有它能覆盖。
    on_TasksChanged: _syncRoutesForAlreadyConnected()
```

三个入口（本步两个 + Step 1 的 `initialConnectComplete`）都调同一个**幂等**函数 `_syncRoutesForAlreadyConnected()`，重复触发无害。

- [ ] **Step 3: 构建**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
cmake --build build -j$(nproc) 2>&1 | tail -30
```

Expected: 构建成功。

- [ ] **Step 4: 离屏冒烟 —— 确认触发链不崩**

用**真库的副本**起一个本地实例（真库零改动），看日志里有没有 `OpsRouteSync 创建失败`：

```bash
cp /home/wangsl/uavm/uavm/db_uavm.db /tmp/smoke.db
cp /home/wangsl/uavm/uavm/db_uavm.db-wal /tmp/smoke.db-wal 2>/dev/null
cp /home/wangsl/uavm/uavm/db_uavm.db-shm /tmp/smoke.db-shm 2>/dev/null
```

⚠️ 拷贝运行中的 sqlite 必须连 `-wal` / `-shm` 一起拷。

Expected: 无 `OpsRouteSync 创建失败`、无 `OpsRouteSync is not a type`。

⚠️ 这一条**只能证明不崩**，证明不了"航线真的下去了" —— 那要 Task 6 的端到端。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/OpsView.qml
git commit -m "feat(opsview): 飞机握手完成后自动下发该任务航线"
```

⚠️ **需用户逐次授权后才执行。**

---

## Task 4: 起飞闸加两件判据

**Files:**
- Modify: `src/OpsView/OpsView.qml`（`_takeoffBlockReason` 与 `_canTakeoff`）

**Interfaces:**
- Consumes: `_routeSyncs`（Task 3）、`OpsRouteSync.synced` / `.statusText` / `.state`（Task 2）、`Vehicle.homePosition.isValid`
- Produces: 无（行为变更）

**判据顺序必须与 `_canTakeoff` 严格一致。** 两条新增判据**放在最后**：前四条是"现场条件够不够"，后两条是"起飞动作本身有没有原料"。顺序错会让用户看到不准确的原因（比如明明没连上，却提示"GPS 未定位"）。

- [ ] **Step 0: 先处理一段会被本次改动**作废**的既有注释**

`OpsView.qml` 在 `_canTakeoff` **上方**有一段长注释，开头写着「与后端 `ops.Takeoff` 同一份判据」。本 Task 之后**这句不再成立** —— 前端会比后端**更严**。

⚠️ **这是有意的，不要去改后端对齐**：新增的两条判据（航线已下发、GPS 已定位）都是**地面站侧**的事实，后端根本观测不到（后端不知道 QGC 有没有把航线下发到飞机）。不对称是必然而非疏漏。

在该段注释末尾追加一行，免得下一个人照着"同一份判据"去给后端补校验：

```qml
    // ⚠️ 2026-09-23 起本判据**比后端 `ops.Takeoff` 多两条**（航线已下发、GPS 已定位）。
    //    这两条是**地面站侧**的事实——后端观测不到 QGC 有没有把航线下发到飞机，
    //    故不对称是必然而非疏漏。**不要**为了"对齐"去给后端补校验，它做不到。
```

- [ ] **Step 1: 改 `_takeoffBlockReason`**

在 `_takeoffBlockReason` 里、`if (!_uavOnline(task)) return qsTr("无人机尚未连接到本地面站，等待其心跳")` 这行**之后**插入。

⚠️ **锚点是 `_uavOnline` 那一行，不要按 `return ""` 定位** —— 该函数**有两条** `return ""`：
开头 `if (!task) return ""` 是**守卫**（不是判据），结尾那条才是正常出口。
（控制者 2026-09-23 核验：`_uavOnline` 那一行在文件里唯一。）

```qml
        // 新增①：航线下发（2026-09-23 用户裁定 a：「航线传完了，在点亮"起飞"按钮」）。
        // 不判就会让飞机按 **PX4 上的残留航线**飞 —— 现场实测的那个残留是 8 月遗留的
        // 3 个苏黎世航点，而界面上完全看不出来。
        var sync = _routeSyncs[task.task_id]
        if (!sync) return qsTr("航线尚未开始下发，请稍候")
        if (sync.state === "failed") return sync.statusText
        if (!sync.synced) return qsTr("航线下发中：%1").arg(sync.statusText)
        // 新增②：GPS 定位（2026-09-23 用户裁定 c：「px4的gps必须完成定位后，才能起飞」）。
        // 起飞点取**飞机当前 home 位置**，home 无效 ⇒ 没有可用的起飞坐标。
        var v = _vehicleForTask(task)
        if (!v || !v.homePosition.isValid) return qsTr("无人机尚未完成 GPS 定位，无法起飞")
```

- [ ] **Step 2: 改 `_canTakeoff`**

在 `_canTakeoff` 的 `if (!_uavOnline(task)) return false` **之后**、`return true` **之前**插入：

```qml
        var sync = _routeSyncs[task.task_id]
        if (!sync || !sync.synced) return false
        var v = _vehicleForTask(task)
        if (!v || !v.homePosition.isValid) return false
```

⚠️ `_takeoffBlockReason` 与 `_canTakeoff` 是**同一份判据的两个消费者**（前者给文案、后者给可用性）。两者的条件必须**逐条对应、顺序一致** —— 不一致的失败形状是"按钮亮着但文案说不能起飞"或反过来，且**没有任何一处会报错**。

⚠️ **但「逐条对应」指的是语义与先后顺序，不是 `if` 的行数。** 上面两处插入的行数**刻意不等**
（`_takeoffBlockReason` 加 4 条 `if`、`_canTakeoff` 加 2 条）：前者要为同一件事出**三种不同文案**
（尚未开始 / 下发失败 / 下发中），后者只要真假 ⇒ 可以合并成一个条件。
**照行数去对齐反而有害**：会把"下发中"的进度文案并掉，或给 `_canTakeoff` 添出冗余分支。
（Step 4 那张表记的就是 `if` 行数：改前各 5 条，改后 9 与 7 —— 两个数都对，**不要**去"修"成相等。）

- [ ] **Step 3: 构建**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
cmake --build build -j$(nproc) 2>&1 | tail -30
```

Expected: 构建成功。

- [ ] **Step 4: 交叉核对两条判据**

这是一条**人工**核对，没有自动化判据（两个函数的条件表达式形状不同，无法机械比对）。

```bash
command grep -n "function _takeoffBlockReason" -A 24 /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
command grep -n "function _canTakeoff" -A 16 /home/wangsl/qgroundcontrol/src/OpsView/OpsView.qml
```

**预期 `if` 计数（改前的实测值，不是估计）：**

| 函数 | 改前 | 本 Task 新增 | 改后 |
|---|---|---|---|
| `_takeoffBlockReason` | 5 | 4 | **9** |
| `_canTakeoff` | 5 | 2 | **7** |

⚠️ **两个函数的 `if` 数不相等，这是对的，别去凑平。** 对应的是**语义**不是分支数：
`_takeoffBlockReason` 要给三种不同的失败态**各自的文案**（未开始下发 / 下发失败 / 下发中），
故新增 4 个 `if`；`_canTakeoff` 只需要一个布尔（`synced`），故 2 个。
把后者也拆成 3 个 `if` 是纯粹的重复，且一旦有人只改了其中一处就会静默漂移。

核对要点（按语义逐条对）：① 两条新增判据在**两侧都存在**；② 两侧的**顺序一致**（已有的 5 条一律在前，新增的在最后）；③ `_canTakeoff` 的第 1 个 `if` 里多一个 `!OpsCommon.isOutbound(...)` —— 那是"这张卡在不在本站的集合里"，不是"能不能起飞"，两侧本就不该相同。

‼️ **两侧"已有的 5 条"本来就不逐条对应 —— 这是现状，本 Task 不许去"补齐"**
（控制者 2026-09-23 逐条比对过改前的两段代码）：

| # | `_takeoffBlockReason`（改前基线 `:512-516`） | `_canTakeoff`（改前基线 `:528-532`） |

⚠️ **那两个行号是"改前"的基线数字，到 Task 4 执行时早已失效** —— Task 3 会在
`_vehicleForTask` 上方插入一整块（约 70 行），**位置在这两个函数之前** ⇒ 两者行号都会往下漂。
**按函数名找，不要按行号找**（`command grep -n "function _takeoffBlockReason"`）。
|---|---|---|
| 1 | `!task` → `""` | `!task \|\| !isOutbound(...)` → `false` |
| 2 | `!task.uav_id` | `task.status !== "SCHEDULED" && !== "READY"` |
| 3 | `!task.uav_current_slot_id` | `!uav_id \|\| !uav_current_slot_id` |
| 4 | `uav_status !== "READY_TO_TAKEOFF"` | 同左 |
| 5 | `!_uavOnline(task)` | 同左 |

⇒ 左侧**缺 `status` 判据**、右侧**缺独立的 `!task.uav_id`**。

**这条差异不可达**（控制者已核验，故不定级为缺陷）：按钮的 `visible` 条件本身就要求
`status ∈ {SCHEDULED, READY}`（`TaskListPanel.qml:269-271`）⇒「状态不对 ⇒ 灰按钮却没提示」
这个组合**根本渲染不出来**。

**本 Task 只做两件事**：两侧各加「航线下发」「GPS 定位」两条新判据、都放在最后。
**不要**顺手给 `_takeoffBlockReason` 补 `status`、也不要给 `_canTakeoff` 补 `!task.uav_id`
—— 那是独立的行为变更，超出本 Task 范围，需要单独裁定。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/OpsView.qml
git commit -m "feat(opsview): 起飞闸加「航线已下发」与「GPS 已定位」两件判据"
```

⚠️ **需用户逐次授权后执行。**

---

## Task 5: 起飞动作换成 `startMission()`

**Files:**
- Modify: `src/OpsView/OpsView.qml`（`_guidedTakeoff`）

**Interfaces:**
- Consumes: `Vehicle.startMission()`（`Q_INVOKABLE`，已核实）
- Produces: 无（行为变更）

**这是"起飞后悬停"的直接修复。** 原实现 `v.guidedModeTakeoff(20)` 只发一条 `MAV_CMD_NAV_TAKEOFF`；该指令**本来就不负责沿航线飞**，PX4 执行完它进 `AUTO_LOITER` 悬停。所以"升到 20 m 悬停"是 PX4 完整执行完它被要求做的事，不是故障。

- [ ] **Step 1: 改 `_guidedTakeoff`**

把 `_guidedTakeoff` 末尾的 `v.guidedModeTakeoff(20)` 一行替换为：

```qml
        // ‼️ 2026-09-23 由 `guidedModeTakeoff(20)` 改为 `startMission()`。
        //
        // 原实现只发 `MAV_CMD_NAV_TAKEOFF`，PX4 完整执行完它该做的事 —— **升到 20 m
        // 进 AUTO_LOITER 悬停**（用户报障现象：「起飞后，px4升空到20米，悬停」）。
        // 该指令**本来就不负责沿航线飞**；「起飞并进入航线」的原子动作在 PX4 侧是
        // 「切 AUTO_MISSION + 解锁」：`PX4FirmwarePlugin::startMission` 的全部内容
        // 就是这两步，PX4 在 AUTO_MISSION 下遇第一个 takeoff item 自动起飞。
        // QGC 自己的提示语也写着 "Takeoff and start the current mission"。
        //
        // 硬编码的 20 m 一并去掉：高度由**航线的第一个航点**决定（用户 2026-09-23
        // 裁定 e），已在 Task 1/2 里写进 mission 的起飞项。
        v.startMission()
```

- [ ] **Step 2: 确认 `guidedModeTakeoff` 在 `OpsView.qml` 里已无残留调用**

```bash
command grep -n "guidedModeTakeoff" /home/wangsl/qgroundcontrol/src/OpsView/*.qml
```

Expected: **无输出**。若还有（比如别处也有一份起飞入口），逐个确认它们是否也该改 —— 只改被点名的那一处会造出"两个入口、两种行为"。

- [ ] **Step 3: 构建**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
cmake --build build -j$(nproc) 2>&1 | tail -30
```

Expected: 构建成功。

⚠️ **"界面出现了新控件但行为不变" 的典型成因是前端 build 了、后端没 build** —— 本项目 QGC 侧是单一二进制，这里不适用；但改完**必须重启用户的 QGC 进程**才会生效，别对着旧进程验。

- [ ] **Step 4: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/OpsView.qml
git commit -m "fix(opsview): 起飞改用 startMission()——切 AUTO_MISSION 并进航线，不再原地悬停"
```

⚠️ **需用户逐次授权后执行。**

---

## Task 6: 端到端验收

**Files:** 无（纯验证）

**前置条件**（缺一不可）：

- PX4 SITL 已起（`setsid ... &` 脱离，且**带 `-d`** 关掉 NSH 控制台 —— 漏 `-d` 会让 pxh 空转 86% CPU）
- `mavp2p` 已起（⚠️ QGC 的**出厂默认** `autoConnectUDP=true` + `udpListenPort=14550` 会无条件 `bind(AnyIPv4, 14550)` 挡住 mavp2p —— 必须先关掉自动连接 UDP）
- `gcs_server` 在跑，QGC 已登录后台
- task 91103 / uav 6 的现场已清理为 `READY` / `READY_TO_TAKEOFF`（见文末 §待办）

- [ ] **Step 1: 清掉 PX4 上的残留航线，确保观察到的行为不是旧数据的**

⚠️ **这一步是关键阴性对照**。PX4 的 `dataman` 现在还挂着 8 月遗留的 3 个苏黎世航点；不先清掉，"飞机飞了航线"这个观察就分不清是**我们下发的**还是**残留的**。

观察点：`dataman` 文件的 mtime。基线是 **2026-08-28 22:43:53**；本步骤之后它必须变成"刚刚"。

```bash
ls -l --time-style=full-iso <PX4 工作目录>/build/px4_sitl_default/rootfs/dataman
```

（或连上后从 QGC 发 `MISSION_CLEAR_ALL`。）

- [ ] **Step 2: 逐条核对链路的四段**

| # | 观察点 | 期望 | 判据 |
|---|---|---|---|
| 1 | QGC 日志 `_autoLoadPlanFromManagerVehicle: backend logged in, skipping auto plan load` | 出现 | 证明登录闸生效、我们构造的航线不会被下载覆盖 |
| 2 | 握手完成后 ≤ 数秒，**起飞按钮由灰转亮** | 转亮 | 证明 Task 3 + Task 4 的闸生效 |
| 3 | PX4 的 `dataman` mtime | 变成刚刚 | 证明航线上传真的落到了飞机 |
| 4 | 下发帧里的 `MISSION_COUNT` | **恰好 = 航点数 + 1** | 证明①起飞项在、②③b 的清理生效（**没有重复下发**）。route 20 有 2 个航点 ⇒ 期望 **3** |
| 5 | 点起飞后，飞机**上升后水平移动** | 移动 | 证明 Task 5 生效（不是原地悬停） |

第 4 行的取数办法（工具已就绪，**不要现造**）：

```bash
# QGC 飞行中原始帧实时写在 /tmp/FlightDataXXXXXX.mavlink（.tlog 要会话结束才另存）
python3 /tmp/mission_dump.py $(ls -t /tmp/FlightData*.mavlink | head -1)
```

看输出里 `COUNT count=N` 那一行；同一次输出里的 `ITEM_INT seq=… cmd=…` 应当能看到 `cmd=22`（`MAV_CMD_NAV_TAKEOFF`）作 seq 0、随后两个 `cmd=16`。

⚠️ route 20 的 `.plan` 历史记录里出现过 `cmd=84/85`（VTOL 起飞/降落）——那是 VTOL 机型走 `insertTakeoffItem` 时的分支（`MissionController.cc` 里 `_controllerVehicle->vtol() ? MAV_CMD_NAV_VTOL_TAKEOFF : MAV_CMD_NAV_TAKEOFF`）。**本机 PX4 SITL 是固定翼还是 VTOL 决定了期望值是 22 还是 84**，核对时按实际机型判，别拿 22 硬套。

- [ ] **Step 3: 高度量纲对照（Task 1 的核心风险）**

「升空到 20 米悬停」那个 20 是**硬编码的相对高度**。改完之后高度应当来自航线首点（route 20 = **50.0 AMSL**）。

⚠️ 起飞后高度若约等于 **50 + 机场海拔**，说明 AMSL 正确；若约等于 **50**，说明被当成了相对高度 —— 但那与 `frame=0` 的实现矛盾，出现即说明 `_applyAltitude` 的 `altitudeFrame` 没生效（Task 2 Step 1 的 `_applyAltitude` 是重点排查对象）。

- [ ] **Step 4: 飞行中核对航点推进**

飞机自述心跳的 `nav` 应为 **`AUTO_MISSION`（不是 `AUTO_LOITER`）**，且 `curr` 从 `-32768`（无航点哨兵值）变成真实序号并随时间推进。

⚠️ 不要拿 `last_heartbeat_at` 判断链路 —— 它只由**明文待命心跳**更新，加密链路 Active 后**必然冻结**，不是链路判据。

- [ ] **Step 5: 记录结论**

把四段的实测值记进 `.superpowers/sdd/` 的账本（若走 subagent 执行）或本计划文件末尾。

---

## 自检（写完后逐条核对）

**1. 裁定覆盖度**

| 裁定 | 落在哪 | 覆盖 |
|---|---|---|
| a（握手后自动上传、传完才亮按钮） | Task 1（数据）+ 2（下发）+ 3（触发）+ 4（闸） | ✅ |
| b（起飞确认后自动进航线） | Task 5 | ✅ |
| c（GPS 定位后方可起飞，用飞机当前 home） | Task 2 Step 1（构造时用 `vehicle.homePosition`）+ Task 4（闸） | ✅ |
| d（用航点高度，需绝对高度） | Task 1（`frame = MAV_FRAME_GLOBAL`，AMSL 零转换）+ Task 2（`_applyAltitude` 显式设 frame） | ✅ |
| e（起飞高度取第一个航点） | Task 1 的 `takeoffAltitude()` + Task 2 Step 1 的 ④ | ✅ |
| f（降落稍后再议） | 全篇无降落逻辑；`command=21` 按下发口径映射成普通航点（Task 1） | ✅ |

**2. 占位符扫描** —— 无 `TBD` / `TODO` / "稍后实现" / "类似 Task N"。所有代码块是可直接抄的完整内容。

**3. 类型一致性** —— `routeMissionItems` / `takeoffAltitude` 在 Task 1 定义、Task 2 消费，名字一致；`OpsRouteSync` 的 `state` / `statusText` / `synced` / `start()` / `reset()` 在 Task 2 定义、Task 3/4 消费，名字一致；`_routeSyncs` 在 Task 3 定义、Task 4 消费，一致。

**4. 已知的未覆盖项（有意，非遗漏）**

- **降落流程**：用户裁定 f 明确移出本次范围。
- **`ops.go` 的 `_onVehicleConnected` 不处理飞机断开**：飞机断开后 `_routeSyncs` 里那份仍留着。若飞机重连，`_syncRouteForTask` 会走"目标飞机换了"分支重置重发 —— 这是**对的行为**（新链路上的飞机没有 mission）。故不留额外代码。
- **多任务的并发同步**：`PlanMasterController` 是**每任务一个实例**，各自的 `_plan` 对象独立，互不干扰。但若操作员在**同一时刻**让三架飞机都完成握手，三个 `sendToVehicle()` 会并发 —— MAVLink 层各自按 systemID 寻址，理论安全，但**本次不做并发压力验证**（YAGNI：现场是一次一架）。

---

## 待办（不在本计划范围内，但阻塞 Task 6）

**task 91103 / uav 6 的现场需要清理。** 用户于 **2026-09-23 16:50:27** 又跑了一次起飞，把现场推回了：

- `table_flight_task` id=91103：`status = TAKEOFF`、`actual_takeoff_at = '2026-09-23 08:50:27'`
- `table_uav` id=6：`status = TAKEOFF`
- `table_task_status_history` id=33 重现（`READY → TAKEOFF`，`08:50:27`）

用户此前的裁定是「强制修改数据库数据……清理上一次操作的现场为一个上下文正常的状态」。复用脚本 `/tmp/repair_uav6_context2.py`（**只改 `TAKEOFF_AT = '2026-09-23 08:50:27'`** 这一处；三条语句各带守卫、要求 `RowsAffected` 恰好为 1，任一不满足即整体回滚）。

⚠️ 清理**需用户明确点头**后才执行，且**必须在真库的副本上先跑只读模式确认基线**。

**PX4 上 8 月遗留的 3 个苏黎世航点**：Task 6 Step 1 会处理（清掉或让新上传覆盖）。⚠️ 若走"让新上传覆盖"这条路，Step 1 的阴性对照失效 —— 必须**先清**。
