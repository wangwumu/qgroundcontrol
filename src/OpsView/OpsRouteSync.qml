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
/// ‼️ **为什么 `flyView: true`**：`PlanMasterController::_activeVehicleChanged` 按
///    `_flyView` 分成两支（`.cc:146` / `:157`），**本组件要的是 Fly 支**。
///    · **Fly 支**（`.cc:146-156`）：无载具时 `removeAll()`，否则调
///      `_autoLoadPlanFromManagerVehicle()`（`:155`）—— 而该函数**第一句就是登录闸**
///      `if (AuthController::backendLoggedIn()) { … return; }`（`.cc:711-714`）
///      ⇒ 已登录后台时**被挡住、什么都不做**。这正是本组件要的：别让飞机上的旧航线
///      覆盖我们刚构造的那一份。
///    · **Plan 支**（`.cc:157-192`，即 `flyView: false` 时走）：一旦 `containsItems()`
///      就**无条件** `_setDirtyForUpload(true)`（`:161`），且 `dirtyForSave()` 时弹
///      `promptForPlanUsageOnVehicleChange`（`:167`）—— **那才是这里要避开的**。
///    ⚠️ 另注：`startStaticActiveVehicle()`（`.cc:93-100`）的**第一句就是 `_flyView = true;`**
///       （`:95`）⇒ 本文件里那行 `flyView: true` **在运行期是冗余的**，留着只为显式表达意图；
///       真正决定走哪一支的是 `:95`。
///    ⚠️ 「成功下发后 `_visualItems` 会被重装」是**另一条链**（属于 `MissionController`），
///       **别混进这一段** —— 它只与本文下方 §③b 有关。
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
    /// 任务对象（`/tasks` 响应里的一项），只读 `current_slot_lat/lon/heading` 三个字段。
    ///
    /// 用途：算出**起飞机位朝向**，把起飞项（MAVLink `cmd 84`）的坐标从
    /// 「`home` 本身」改成「`home` 沿该朝向偏移 `vtolTransitionDistance` 米」——
    /// 理由见下方 §④c。
    ///
    /// ⚠️ 默认 `null` 是**合法输入**（不是错误）：缺省 ⇒ `takeoffSlotHeading` 回 `null`
    ///    ⇒ 起飞点回落 `home`，与本次改动之前的行为**逐字一致**。
    property var    task:     null

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
            //
            //  ［2026-09-28 更新］用户已裁定**垂起着陆**方案（见下方 ⑤a）。⚠️ 但**本条依然成立**：
            //    设计域的值域仍是 `{16, 21}`，`85` 在本链路里是**产出**不是**输入** ⇒
            //    plan_data 里带着 85 过来的航线**照样整条作废**。别把新增的垂起着陆
            //    当成"临时航线 84/85 已支持"——那两件事没有关系。
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
        // ‼️ 第二个实参 `vehicle.vtol` 由**本组件**（调用点）读好再传进 `.pragma library`
        //    的纯函数 —— 放在 `OpsCommon.js` 的函数体里读属性**不注册绑定依赖**。
        //    ⚠️ 它**只认真布尔 `true`**：`vtol` 是 `Q_PROPERTY(bool)`（`Vehicle.h:169`），
        //    QML 读出来就是 JS boolean，正好满足那道严格判据。
        //
        // ❌❌ **【2026-09-28】垂起着陆在本链路当前恒不触发 —— 这一行是死的。**
        //    第三个实参 `endWaypointId` 刻意**没传**：它必须来自 `table_route.end_waypoint_id`，
        //    而本组件手上**没有任何来源**（本文件唯一那次 `get()` 只取
        //    `/api/routes/<id>/waypoints`，其响应体里**不含** `end_waypoint_id`）。
        //    缺省 ⇒ `OpsCommon._endWaypointIndex` 恒回 `-1` ⇒ 恒不产生 85。
        //    ⇒ **本次改动的净行为变化 ＝ 零**（这正是 fail-closed 想要的落点，不是意外）。
        //
        // ‼️ **为什么"没传"是对的，而不是"忘了接"**：即使把终端站**按列表中的位置**推出来
        //    也不能用 —— `GET /routes/:id/waypoints`（后端 `route.go` 的 `ListWaypoints`）
        //    **不返回起降点**：它读 `table_route_waypoint`（+JOIN `table_waypoint`）拿中间航点，
        //    **再**读 `table_route.plan_data`，用 `mission.items[i].command` 覆写各点 command、
        //    并在头部插一个 home 点（`command=-1`）；**唯独不读**
        //    `table_route.start_waypoint_id` / `end_waypoint_id` 这两列 ⇒ 始发站/终点站
        //    **不在返回列表里**。
        //    （2026-09-29 审查 A5 修正：原注释写「只读 `table_route_waypoint` 一张表」——
        //      错，它还读 `plan_data`。⚠️ 这个过简措辞是从后端照抄来的，`ops.go:584-586` 亦然。）
        //    （对照：`handlers/ops.go` 的 `buildTaskWaypoints`（`:414`）才把这两列读进来拼在首尾，
        //      两处口径差在 `ops.go:584-586` 记为"已知且不修" —— 原注释引 `545-548`，
        //      是 2026-09-29 审查 A3 修正的错行号。）
        //    真库实测 **RT-003**：`end=5 保定市政府`，而本接口只回 `wp3 良乡区政府(21)`、
        //    `wp4 房山镇政府(16)` ⇒ 列表末项是**中途点**。按它打 85
        //    ⇒ **飞机在房山镇政府降落**，而任务目的地是保定市政府。
        //    ⚠️ 反例 **RT-SITL01** 的 start/end **恰好也在** `table_route_waypoint` 里
        //    ⇒ "末项即终点"在那条航线上**恰好**成立 —— 这正是该错判据能在 SITL 上验出
        //    "能用"的原因，也是它最危险的地方。
        //
        // 🔓 **解封条件（两件都做完才生效，缺一不可）**：
        //    ① 后端在 `/routes/:id/waypoints` 的响应里带上 `end_waypoint_id`
        //       （或在列表里补上起降点两点）；② 把该值作为第三个实参传进本行。
        //    ⚠️ 若走"列表里补起降点"那条，会**连带改变** webui 的
        //    `RouteList.vue`（它把本接口的返回值直接当作要保存的 `waypoint_ids`）
        //    ⇒ 前端必须同步改，否则保存航线会**把起降点塞进中途点集合**。
        //    ❗ 另有一个**语义**问题未决、且不是接线能解决的：终点站航点坐标 ≠ 机位坐标，
        //    而用户的运行红线是「**除非要坠机了，否则飞机只能在机位上降落**」
        //    ⇒ 即使接线通了，"落在终点站航点"是否合规仍需用户裁定。**已上报待裁决。**
        //    详见 `OpsCommon._endWaypointIndex` 的注释。
        var items = OpsCommon.routeMissionItems(wps, vehicle.vtol)
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
        //    两个来源都要挡：
        //    · **首次**同步：确实是空的 —— ③ 已说明（登录闸挡住了下载）；
        //    · **复用**：**不空**。本组件按 `task_id` 复用同一个 controller
        //      （`OpsView.qml:690`：换飞机时 `reset()` 后 `start()`），
        //      而上一轮**成功下发**后 `MissionController` 会把 `_visualItems`
        //      重装成飞机上那一份（`MissionController.cc:1971-1972`）；
        //      本文件的 `reset()` 函数**只清状态与轮询、不碰 `_plan`**
        //      ⇒ `containsItems()`（`_visualItems->count() > 1`，`.cc:1863-1866`）为**真**。
        //    不清的结果：我们再 append 一次 ⇒ **整条航线被下成两遍**，
        //    而界面上完全看不出来 —— 飞机会把每个点飞两次。
        //    这一行把"依赖上游行为"换成"本组件自己保证"。判据是 `containsItems`。
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
        //    ‼️ 上面那个 `home` 实参**根本没被读过**：`insertTakeoffItem` 的**实现**签名是
        //    `(QGeoCoordinate /*coordinate*/, int, bool)`（`MissionController.cc:381`）——
        //    形参被**显式注释掉**了，函数体从头到尾不碰它。
        //    ⚠️ 出处是 `.cc` 而**不是** `.h` ［2026-09-23 fix round 2 复核修订］：`.h:120` 是
        //       **声明**，那里的形参是**具名**的（`QGeoCoordinate coordinate`）——
        //       照 `.h:120` 去核对的人，会以为本论断是错的。
        //
        //    坐标本该由 `TakeoffMissionItem::_init` 来设（`.cc:66-68`：
        //    `if (_launchTakeoffAtSameLocation && homePosition.isValid()) SimpleMissionItem::setCoordinate(homePosition);`），
        //    但同一函数开头（`.cc:44-47`）是 `if (_flyView) { _initLaunchTakeoffAtSameLocation(); return; }`
        //    —— **提前 return**，而本文件用的正是 `flyView: true`（理由见上方 §为何 flyView）。
        //    ⇒ 那句 `setCoordinate` 永远不会执行，坐标停在 `SimpleMissionItem` 的默认值上：
        //      `_setDefaultsForCommand`（`:810-826`）把 `_mapCenterHint` 写进 param5/6，
        //      而 `SimpleMissionItem.h:180 QGeoCoordinate _mapCenterHint;` 是**默认构造** ⇒ lat/lon 是 **NaN**。
        //    ⇒ 结果是一条 param5/6 为 NaN 的 NAV_TAKEOFF —— 下到飞机上行为不可预期（也可能整项被拒）。
        //    ⇒ 显式写一次即可。副作用方面 ［2026-09-23 fix round 2 复核修订］：
        //      `TakeoffMissionItem::setCoordinate`（`.cc:97-105`）**只在 `_launchTakeoffAtSameLocation`
        //      为真时**才会把 `_settingsItem` 的坐标一并设为同值（`.cc:101-103` 的那个 `if`，
        //      brief 修订前写成"顺带"，偏绝对），为假时只改 takeoff item 自己。
        //      **但两种取值下本行都成立** —— 我们要的正是「takeoff item 自己的坐标 = home」；
        //      为真那支与已做的 `setHomePosition(home)` 同值，无害。
        //
        // ④c 坐标不再直接取 `home`，而是「`home` 沿**起飞机位朝向**偏移 `vtolTransitionDistance` 米
        //    后的点」。 ［2026-09-28］
        //
        //    ‼️ **为什么起飞点要有方向**：PX4 的 84 项状态机里，`WORK_ITEM_TYPE_CLIMB` 把 `yaw`
        //    设为「飞机当前位置 → 84 项坐标」的方位角，并且 `force_heading = true`
        //    （`PX4-Autopilot/src/modules/navigator/mission.cpp:365-370`：`:366-368` 赋 `yaw`，
        //      `:370` 置 `_mission_item.force_heading = true`。
        //      ⚠️ 2026-09-29 审查 A6 修正：原注释写 `:365-367`，那只覆盖 yaw 赋值、**漏掉了
        //      `force_heading`** —— 而「朝向能被强制执行」恰恰是这两句合起来的效果。
        //      与 `OpsCommon.js` 的 `takeoffTransitionPoint` 注释同口径。）
        //    ⇒ **84 项坐标就是「起飞后朝哪飞」的唯一决定者**。用户要求「站点的机位都有一个朝向，
        //    应该按照该朝向飞」，所以坐标必须偏到朝向上去。
        //    ⚠️ 转 FW 与否**不由本点决定**：`ALIGN_HEADING` 里那句 `set_vtol_transition_item(FW)`
        //    在 `if (do_need_move_to_takeoff())` **之外**，是无条件的，由**时间**参数
        //    `VT_F_TRANS_DUR`（默认 5 s）决定。别把「点给多远」当成「什么时候转固定翼」的旋钮。
        //
        //    ⚠️ 偏移的**起点是 `home`，不是机位坐标**（用户 2026-09-23 裁定 c：起飞点取飞机当前
        //    home 位置）。后端下发的 `current_slot_lat/lon` 在本文件里**只用于判哨兵**
        //    （「到底有没有起飞机位」），**不参与计算** —— 这也是 `takeoffSlotHeading`
        //    只返回朝向、不返回坐标的原因。
        //
        //    ‼️ **三处回落，全部回到 `home`**（= 与本次改动之前逐字一致的旧行为）：
        //      ① `task` 没注入 / 响应里没有那三个字段；② 后端下发 0/0/0 哨兵（未指定机位）；
        //      ③ 偏移算失败（`takeoffTransitionPoint` 对无效输入一律回 `null`）。
        //    ⇒ 功能失效时的现象是「起飞后朝正北」，**不会**是「没有起飞点」或「报错」，
        //      排查时先看这一层。
        //
        //    ‼️ 判据必须写 `!== null`，**不能**写 `if (slotHeading)`：`0` 是**合法的正北朝向**
        //      同时也是 falsy ⇒ 写成 `if (slotHeading)` 会让恰好朝正北的机位**静默**回落 `home`，
        //      而现象与「这功能根本没做」完全一样。（真库 12 个机位的朝向恰恰只有 `0` 和 `1.0`
        //      两种取值，这一支不是理论边角。）`OpsCommon.takeoffSlotHeading` 刻意用 `null`
        //      （而不是 `0`）表示「没有」，就是为了让这个区分在代码里看得见。
        var takeoffPoint = home
        var slotHeading = OpsCommon.takeoffSlotHeading(task)
        if (slotHeading !== null) {
            var transitionM = Number(QGroundControl.settingsManager.planViewSettings
                                     .vtolTransitionDistance.rawValue)
            var moved = OpsCommon.takeoffTransitionPoint(home.latitude, home.longitude,
                                                         slotHeading, transitionM)
            if (moved) takeoffPoint = QtPositioning.coordinate(moved.lat, moved.lon)
        }
        if (takeoff) takeoff.coordinate = takeoffPoint

        // ⑤ 逐点追加。`visualItemIndex = -1` = append 到末尾。
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            var vi = _plan.missionController.insertSimpleMissionItem(
                        QtPositioning.coordinate(it.lat, it.lon), -1)

            // ⑤a ‼️ 把 `it.command` **真正写进** mission item —— 这一行是垂起着陆的落地判据。
            //
            //     ❗ **本行当前恒不执行**（条件 `it.command !== 16` 永不成立，理由见 §① 那段
            //     "垂起着陆恒不触发"）。**但它绝不能因此被删**：
            //     · 它是**用户已裁定方案的实现**，缺了它即使 §① 的解封条件全部满足，
            //       85 也**一个字节都到不了飞机**，且纯函数层单测**全绿**（它们只看返回值）
            //       ⇒ 会退化成"看起来做完了、实际没接线"，比没做更难查；
            //     · 它**不改变任何现有行为**（条件不成立 ⇒ 不赋值），删除它也不改变现状
            //       ⇒ "删掉死代码"在这里的收益是零、风险是把已裁定方案悄悄拆掉。
            //
            //     为什么必需：`insertSimpleMissionItem`（`MissionController.cc:376-379`）
            //     把命令**硬编码**成 `MAV_CMD_NAV_WAYPOINT`，**没有**命令形参
            //     ⇒ 少了本行，`routeMissionItems` 算出来的 `command` **一个字节都到不了飞机**，
            //       终点站点的垂起着陆(85)会静默退化成普通航点(16)，
            //       而纯函数层的单测**全绿**（它们只看返回值）。
            //
            //     ‼️ **顺序不可交换：必须在本行的 `_applyAltitude` 之前。**
            //     `SimpleMissionItem` 把 `_commandFact` 的 `valueChanged` 接到了
            //     `_setDefaultsForCommand`（`SimpleMissionItem.cc:158`），后者会
            //     **把 `_altitudeFrame` 重置为 `AltitudeFrameRelative`、并把高度重置成
            //     应用默认值**（`.cc:829-834`）。若先写高度再改命令，本项目的
            //     `frame = MAV_FRAME_GLOBAL(0)`（AMSL）会被翻回"相对 home"
            //     ⇒ 463 米 AMSL 被当成"离地 463 米"，而界面上看不出任何异常。
            //     坐标不受影响：`_setDefaultsForCommand` 只重置 param1-4，仅在
            //     "无坐标命令"时才清 param5/6（`.cc:812-826`），而 85 是
            //     `specifiesCoordinate: true` ⇒ 坐标原样保留。
            //
            //     ⚠️ 只对**非普通航点**赋值：普通航点本来就等于 C++ 侧的默认值，
            //     写一次会白白触发 `_setDefaultsForCommand` 那一整套重置。
            if (vi && it.command !== OpsCommon.MAV_CMD_NAV_WAYPOINT) vi.command = it.command

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
    /// ‼️ 高度写 `rawValue` 而**不是** `value`：
    ///    `Fact.h:53` 的 `value` 是 `Q_PROPERTY(QVariant value READ cookedValue WRITE setCookedValue)`
    ///    ⇒ **走用户单位换算**（`setCookedValue(v)` = `setRawValue(_metaData->cookedTranslator()(v))`，
    ///    `Fact.cc:163-170`）。本 Fact 的 metaData 由 `SimpleMissionItem.cc:194-200` 建：
    ///    `setRawUnits("m")` ⇒ `setBuiltInTranslator()` ⇒ `_setAppSettingsTranslators()`
    ///    **读 `UnitsSettings`**（注意 `setRawUserMax(121.92) // 400 feet` —— 界就是按英尺定的）。
    ///    ⇒ **用户把垂直距离单位设成英尺时，写 `value = 50` 会落库 50 ft = 15.24 m**，
    ///    航线照发、日志无异常，飞机就按 15 米飞。
    ///    `rawValue` 恒为米：QGC 自己内部传值即
    ///    `_param7Fact.setRawValue(_altitudeFact.rawValue())`（`SimpleMissionItem.cc:768`，
    ///    MAVLink `param7` 的单位就是米）。
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
            //    `PlanMasterController::sendToVehicle`（`.cc:307-329`）在
            //    `_sendGeoFence = true`（`:326`）**之前**有**三条不发送就离开函数**的出口
            //    —— 全函数只有**两个 `return`**（`:313` / `:317`），第三条（`:320-323`）
            //    是打日志后**落到函数末尾**：
            //      · `:311-314` —— **高延迟链路**：会弹
            //        `QGC::showAppMessage("Upload not supported on high latency links.")`
            //        ⇒ **不静默**，现场会先看到这句、再看到 60 秒超时文案；
            //      · `:315-318` —— `sharedLink` 为空（飞机正在关机 / 链路没了）⇒ 纯 `return`，无提示；
            //      · `:320-323` —— `offline()` ⇒ **只打 qCCritical**（日志），
            //        用户界面**看不到任何东西**；同行还有 `syncInProgress()` 子情形，
            //        那意味着**另一次发送正在跑**，`dirtyForUpload` 归那一次管，此处不下断言。
            //    **静默的两条**（`:315-318` 与 `:320-323` 的 `offline()`）下，
            //    **本次调用根本没有发生发送** ⇒ `syncInProgress` 不会因它而变真 ⇒ 只看它的话，
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
            //      · 而上面那两条静默出口 **一个槽都不会触发** ⇒ 它**保持 true**
            //        ⇒ 本轮永远不 done ⇒ 走到上面的超时分支 ⇒ **失败变成显式的** ✓
            //
            //    ⚠️ 这个判据**不会**像"要求曾观察到 `syncInProgress == true`"那样卡死：
            //       发送够快时（整段落在两次 tick 之间）两个条件在 tick 时刻**都已经满足**，
            //       `ticks >= 2` 照样能 done。（"曾观察到 true"那种写法在快发送下**永不 done**，
            //       只能等 60 秒超时 —— 比原缺陷更糟，已被否决。）
            //
            //    ⚠️ **已知残余（勿当成疏漏）**：飞机若回 **NACK**，这一路**仍会假 done** ——
            //       **信号本身是带 error 的**：`PlanManager.h:75` 是 `void sendComplete(bool error)`，
            //       `PlanManager.cc:845` 也照发 `emit sendComplete(!success /* error */)`；
            //       `MissionManager` 派生自 `PlanManager`（`MissionManager.h:9`）且**未重声明**
            //       ⇒ 它继承的就是带 error 的那个。
            //       断链在**槽**：`PlanMasterController.cc:137` 把它连到
            //       `:269 void PlanMasterController::_sendMissionComplete(void)` —— 该槽
            //       **不收形参、也不判 error** ⇒ 失败照样推进整条链 ⇒ `dirtyForUpload` 照常复位。
            //       要根治得让**这一路把 error 传下去**（改该槽签名 + 在链尾据此判失败），
            //       **不是**"新增一个转发信号"—— 同名同签名的信号加不出来（原注释的处方是错的）。
            //       那是**独立的 C++ 工作包**，已记入 ledger 待裁决，
            //       **明确不在本计划范围内** —— 不要在这里顺手加 C++。
            //       （另：全仓 `.qml` **零处**使用 `.missionManager`，且 `Vehicle.h:592` 是普通
            //        getter（无 `Q_PROPERTY` / `Q_INVOKABLE`）⇒ **别指望在 QML 侧接这个信号绕开 C++**。）
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
