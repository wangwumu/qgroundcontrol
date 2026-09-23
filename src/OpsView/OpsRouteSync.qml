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
        //    两个来源都要挡：
        //    · **首次**同步：确实是空的 —— ③ 已说明（登录闸挡住了下载）；
        //    · **复用**：**不空**。本组件按 `task_id` 复用同一个 controller
        //      （`OpsView.qml:566-570`：换飞机时 `reset()` 后 `start()`），
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
            //       （另：全仓 `.qml` **零处**使用 `.missionManager`，且 `Vehicle.h:581` 是普通
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
