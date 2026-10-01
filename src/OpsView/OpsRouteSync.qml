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
    /// 任务对象（`GET /api/ops/overview` 响应里 `tasks[]` 的一项），只读 `current_slot_lat/lon/heading` 与 `cruise_alt_agl`。
    /// ⚠️ 来源端点**不是** `/tasks`：注入方是 `OpsView.qml`，它的 `_tasks` 来自
    ///    `OpsShell._fetchOverview()` 的 `GET /api/ops/overview?view=`（`/tasks` 是另一族端点，
    ///    本组件**没有**读过它）。
    ///
    /// 用途 ①：算出**起飞机位朝向**，把起飞项（MAVLink `cmd 84`）的坐标从
    /// 「`home` 本身」改成「`home` 沿该朝向偏移 `vtolTransitionDistance` 米」——
    /// 理由见下方 §④c。
    ///
    /// 用途 ②（NRRSM）：提供 `cruise_alt_agl`（本架次飞行高度，AGL）—— 中间项组装式的加数。
    ///
    /// ‼️ NRRSM 之后整个 `null` **不再是合法输入**：没有 `cruise_alt_agl` 就组装不出中间项，
    ///    `start()` 会直接 `_fail`。改动前这里写的是「默认 `null` 是合法输入（不是错误）：
    ///    缺省 ⇒ `takeoffSlotHeading` 回 `null` ⇒ 起飞点回落 `home`，与本次改动之前的行为逐字一致」——
    ///    `takeoffSlotHeading` 对**缺字段**（不是整个 `null`）的回落**仍在**，
    ///    但「整个 `task` 为 `null`」这一档已经**被拒**（见 `start()` 里那道飞行高度闸）。
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

    // NRRSM：本航线 / 本架次的起降与飞行高度**快照**，来自 GET /api/routes/<id>（航线级）与 `task`。
    // NaN = 尚未取到。名字里的 `AGL` / `MSL` 是**单位**，不是装饰 —— 六个原始量分属两种
    // 单位（AGL 三个 / MSL 三个），**同名互换不会报错**，只会静默算错，别混用。
    // ‼️ 下面这些**高度 / 飞行高度 / 终点航点快照**都必须在 reset() 里清成 NaN —— 本组件是**复用**的
    //    （同一任务切换目标飞机时只换 vehicle，对象不换）。不清的话，第二次同步会用**上一条航线**
    //    的值（包括**上一条航线的终点航点**）去构造新航线的末项，而界面上一切正常、没有任何报错。
    //    ⚠️ 这里**刻意不写「共 N 个」** —— 计数会被下一轮增删当场证伪；要核对就现场 grep 本文件的 `NaN` 初值。
    property real _takeoffAltAGL:    NaN   // 航线起飞高度（AGL）
    property real _takeoffClearAGL:  NaN   // 起飞站点最低安全高度（AGL）
    property real _takeoffGroundMSL: NaN   // 起飞站点地面海拔（MSL）
    property real _landingAltAGL:    NaN   // 航线降落高度（AGL）
    property real _landingClearAGL:  NaN   // 降落站点最低安全高度（AGL）
    property real _landingGroundMSL: NaN   // 降落站点地面海拔（MSL）
    property real _cruiseAGL:        NaN   // 本架次飞行高度（AGL），取自 task.cruise_alt_agl
    // A1（2026-10-01）：**降落站点对应的航点**三量 —— 由 `appendLandingWaypoint` 追加成 mission 末项。
    // 用 `real` 是本文件既有风格；`NaN` 是"没取到"的哨兵，`appendLandingWaypoint` 按
    // `typeof x === "number" && isFinite(x)` 口径收（**是 `typeof` + 全局 `isFinite`，
    // 不是 `Number.isFinite`** —— 后者不做隐式转换，两者语义不同，别按名字记）。
    // ⚠️ `_endWaypointId` 承载的是航点 id（整数），与上面那些米 / 度**单位不同**，别与它们混用。
    property real _endWaypointId:    NaN   // 航线终点航点 id（table_route.end_waypoint_id）
    property real _endLat:           NaN   // 该航点纬度（WGS84 度）
    property real _endLon:           NaN   // 该航点经度（WGS84 度）

    // D6 生效值 = 两侧大者（航线的 `*AltAGL` 与站点的 `*ClearAGL`）。
    // ‼️ **D6 合成规则（`max` 那一步）的单点定义 = `OpsCommon.nrrsmEffectiveAGL`**（B7，2026-10-01）；
    //    下面这两行**只是它的调用点**，不在这里就地写 `Math.max`。
    //    本仓内另一个调用点是 `OpsCommon.routeAltitudeBounds` 的两个合成键
    //    `takeoffAGL` / `landingAGL`（那两个键在**生产路径上零读取** —— 本文件只取走六个原始量，
    //    读它们的目前只有单测 `tst_OpsCommon.qml`）。
    //    ⇒ 想改 D6（例如给 `max` 再加一个下限），**只改 `nrrsmEffectiveAGL` 一处**。
    //    ‼️ **别按「共几处」记** —— 计数会被下一次增删当场证伪；**现场复跑**：
    //       在 QGC 仓根跑 `rg -n 'nrrsmEffectiveAGL' src/`，列出本仓全部调用点。
    //    ‼️ **本仓之外还有一处同一规则**（不是本函数的调用点，故意各自独立）：
    //       后端仓 `gcs_server/handlers/route.go` 的 `nrrsmEffectiveLandingAGL` —— 它只喂
    //       `max_cruise_alt_agl` 的反解与梯度判，**不参与航点飞行高度的组装**。
    //
    // 下面各使用点（起飞项组装 `_applyAltitude` 的实参 / 降落项组装 `applyLandingAltitude` 的实参 /
    // 起飞闸 / 降落闸 / `_statusText` 的两个 `arg`）都读这两个绑定，不就地重算 ——
    // 每处各写一遍就是会漂移的多份口径。
    // ⚠️ **刻意不写「共 N 处」**：这种计数会被下一轮增删当场证伪（旧文案漏的正是与
    //    `applyLandingAltitude` 对称的起飞项 `_applyAltitude`）。要核对就现场 grep。
    // ‼️ 这两个是**绑定**，不是快照 ⇒ **不进 reset()**：QML 里对绑定属性赋值即解除绑定，
    //    手工赋 NaN 会把绑定打断。它们自会跟着被绑定的快照走。
    //
    // ‼️ **为什么是"组件属性"而不是从 `bounds` 里取**：`bounds` 只是 `start()` 里那次 `get()`
    //    回调的**局部量**，出不了回调；而这两个量要在**回调返回之后**的多个落点被读 ——
    //    起飞闸、降落闸、`_statusText` 的两个 `arg`、起飞项 `_applyAltitude` 的实参、
    //    末项 `applyLandingAltitude` 的实参。
    //
    // ‼️ 本文件这侧用 `NaN` 表示"键缺失"，`nrrsmEffectiveAGL` 里的 `orZero` 把 `NaN` / `null`
    //    一并按 `0` 计 ⇒ 与 `routeAltitudeBounds` 那侧**在可达输入上无行为差异**：
    //    后端那六个键是**同一条 SELECT 出、同一个 Scan 入**的 —— 见 `handlers/route.go` 的
    //    `RouteHandler.Get`：`takeoff_alt_agl` / `landing_alt_agl` 与四个子查询列（起降站点的
    //    `clear_alt_agl` 与起降航点的 `altitude`）同写在一条 `QueryRow` 的列清单里、同一次 `Scan`
    //    落进 `models.Route`，六个都 `COALESCE(...,0)`，且六个在 `models.Route` 里都是
    //    **不带 `omitempty`** 的 `float64` ⇒ **要么六个一起有值、要么整行取不到**
    //    （整行取不到时走 `notFoundOrFail` ⇒ 404 ⇒ 上面那次 `get()` 的回调在 `status !== 200`
    //    就 `_fail` 了，根本走不到 `routeAltitudeBounds`）—— **不存在「一部分有、一部分没有」**。
    //    退一步说，即便真落到「六个全无」：两侧都会合成 `0` ⇒ 下面两道闸读到的 AGL 项是 `0`
    //    ⇒ `OpsCommon.nrrsmUsableAGL(0)` 回 `false` ⇒ **拒发**。
    property real _takeoffAGL: OpsCommon.nrrsmEffectiveAGL(_takeoffAltAGL, _takeoffClearAGL)   // D6 生效值
    property real _landingAGL: OpsCommon.nrrsmEffectiveAGL(_landingAltAGL, _landingClearAGL)   // D6 生效值

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

        // NRRSM：本架次的飞行高度（AGL，米）—— 中间项组装式的加数。
        // ‼️ `task` 为 null 在本组件里**不再是合法输入**。改动前它的注释写的是
        //    「缺省 ⇒ 起飞点回落 home，与改动前逐字一致」；NRRSM 之后中间项高度
        //    **必须**有这个加数，拿不到就只能拒绝下发 —— 静默按 0 会让整条航线的
        //    中间点少一个巡航高度偏移，而界面上零报错。**（`task` 属性上那段旧注释已随之改掉。）**
        // 判据**收敛到单点定义** `OpsCommon.nrrsmUsableAGL`（W1，2026-10-01）：
        //    它按「类型 → 有限性 → 值域 `> 0`」三步收 ⇒ 字符串 / `undefined` / `NaN` / **`0`**
        //    一律拒绝。**`0` 必须拒**：`0` 是本设计里「未设定」的编码，判据 7
        //    （飞行高度 = `waypoint.altitude + cruise_alt_agl`）下它会算出「飞行高度 =
        //    航点地面海拔」⇒ 飞机降到**地形高度平飞**。改动前本闸只判有限性 ⇒ `0` 畅通。
        //    （`!task` 仍在：`task` 为 null 时不进 `nrrsmUsableAGL`。）
        // ‼️ 拒发的文案必须是「未设定飞行高度」这一句：若把不可用值直接喂给
        //    `routeMissionItems`，它会回 `[]`，而那边的文案是「航线没有可用航点」——
        //    指向错误的方向（用户会去查航线，而不是查任务）。
        // ‼️ 本闸在 `start()` 里、**`_cruiseAGL` 赋值处的上方**：**读 `task.cruise_alt_agl`
        //    （后端给的字段），不读下面赋的值 `_cruiseAGL`**，且**次序必须保持
        //    「闸在前、赋值紧邻在后」**：一旦挪到赋值之后改读 `_cruiseAGL`，
        //    检的就变成「我自己刚赋的值」—— 将来谁把那行写成带**正数**缺省值的形状
        //    （如 `_cruiseAGL || 50`），闸就**恒真**了。
        //    ⚠️ 缺省写成 `0`（`task.cruise_alt_agl || 0`）**不**恒真：`0 || 0` 仍是 `0`，闸照样拒。
        //    ⚠️ 「没有任何测试会红」**已被证伪**：实测把闸挪到赋值之后并配正数缺省时，
        //       **第 2 格（`cruise_alt_agl` 为 `0`）与第 4 格（`cruise_alt_agl` 为字符串）会红**
        //       （格号按 `OpsRouteSyncUITest` 的 `flight / …` 各格**声明序**计）；第 3 格（`task`
        //       整个为 `null`）也会红 —— 赋值提到 `!task` 之前，`task.cruise_alt_agl` 先抛 TypeError。
        if (!task || !OpsCommon.nrrsmUsableAGL(task.cruise_alt_agl)) {
            return _fail(qsTr("该任务未设定飞行高度，无法下发"))
        }
        _cruiseAGL = task.cruise_alt_agl

        _state = "fetching"
        _statusText = qsTr("正在获取航线…")
        // NRRSM（2026-09-30）：先取**航线**（起降高度是航线级字段），再取**航点**。
        // 为什么不在 `/waypoints` 的响应里带：那个接口的返回值被 webui 的 RouteList.vue
        // **直接当作要保存的 waypoint_ids**（见下方 _buildAndSend 里 **① 段**尾部以 `🔓` 开头的那块解封条件注释），
        // 把它改成对象会连带打断保存航线。两次 GET 是最小侵入。
        // `/api/routes/:id` 无角色闸（uavm 仓 `gcs_server/router/router.go` 里注册
        // `api.GET("/routes/:id", routeH.Get)` 那一行 —— **按符号定位，别按行号**；行号会漂），SITE_ATC 能读。
        get("/api/routes/" + routeId, function(status, route) {
            if (status !== 200 || !route) {
                return _fail(qsTr("航线详情获取失败（HTTP %1）").arg(status))
            }
            var bounds = OpsCommon.routeAltitudeBounds(route)
            // 六个原始量各取一份快照。`=== null ? NaN : …` 的形状**保留**：
            // C5 的 `pick()` 回 `null` 表示「类型层不可用」（键缺失 / 非数字），
            // 落成 NaN 才能让下面两道闸（`OpsCommon.nrrsmUsableAGL`，非有限那一步）把它拦住（fail-closed）。
            _takeoffAltAGL    = bounds.takeoffAltAGL    === null ? NaN : bounds.takeoffAltAGL
            _takeoffClearAGL  = bounds.takeoffClearAGL  === null ? NaN : bounds.takeoffClearAGL
            _takeoffGroundMSL = bounds.takeoffGroundMSL === null ? NaN : bounds.takeoffGroundMSL
            _landingAltAGL    = bounds.landingAltAGL    === null ? NaN : bounds.landingAltAGL
            _landingClearAGL  = bounds.landingClearAGL  === null ? NaN : bounds.landingClearAGL
            _landingGroundMSL = bounds.landingGroundMSL === null ? NaN : bounds.landingGroundMSL
            // A1（2026-10-01）：终端航点三量。同一形状（`=== null ? NaN : …`）——
            // `pick()` 回 `null` 表示"类型层不可用"，落成 NaN 才能让 `appendLandingWaypoint` 的
            // `typeof x === "number" && isFinite(x)` 判据（**`typeof` + 全局 `isFinite`，
            // 不是 `Number.isFinite`**）把它拦住（fail-closed）。
            // ‼️ route 响应的**唯一**读取入口就是 `routeAltitudeBounds` —— 别在这里直接读
            //    `route.end_waypoint_id`，那会又开一个口径（见属性区注释）。
            _endWaypointId   = bounds.endWaypointId === null ? NaN : bounds.endWaypointId
            _endLat          = bounds.endLat        === null ? NaN : bounds.endLat
            _endLon          = bounds.endLon        === null ? NaN : bounds.endLon
            _fetchWaypoints(routeId)
        })
    }

    /// 取航点并下发。从 `start()` 里拆出来，因为 NRRSM 之后它是**第二步**。
    function _fetchWaypoints(routeId) {
        get("/api/routes/" + routeId + "/waypoints", function(status, data) {
            if (status !== 200 || !data) {
                // 后端对未知路由 / 无权限一律非 200；这里不区分，统一报"获取失败"，
                // 免得把 403 猜成 404 误导现场排查。
                return _fail(qsTr("航线获取失败（HTTP %1）").arg(status))
            }
            var wps = Array.isArray(data) ? data : (data.waypoints || data.data || [])
            if (!Array.isArray(wps)) wps = []
            // ‼️ 后端 `buildWaypoints`（uavm 仓 `gcs_server/handlers/route.go` 的同名函数 ——
            //    **按函数名定位，别按行号**）对**含 plan_data
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
            //    （起飞=84、降落=85，同在 `handlers/route.go` 的 `buildWaypoints` 里 ——
            //     **按函数名定位，别按行号**）——`_designCommandToMavCmd(84|85)`
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
        // 所有**快照**一起清（含 `_cruiseAGL` 与 A1 的终点航点三量）—— 漏清一个就是
        // 「第二次同步用上一条航线的值去构造新航线的末项」。
        // ⚠️ **不**在这里清 `_takeoffAGL` / `_landingAGL`：它们是**绑定**、不是快照，
        //    对绑定属性赋值会解除绑定；跟着上面那些快照自动走即可（声明见属性区）。
        _takeoffAltAGL    = NaN
        _takeoffClearAGL  = NaN
        _takeoffGroundMSL = NaN
        _landingAltAGL    = NaN
        _landingClearAGL  = NaN
        _landingGroundMSL = NaN
        _cruiseAGL        = NaN
        _endWaypointId    = NaN
        _endLat           = NaN
        _endLon           = NaN
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
        // ⏸️ **垂起着陆（`85 NAV_VTOL_LAND`）在本链路恒不触发 —— 这是【2026-10-01 裁定 R-A1】
        //    的结果，不是"还没接上"。**（本节原写的是一大段「🔓 解封条件」，已随该裁定**作废**，
        //    不要再按它去"解封"。）
        //    · 用户 A1 原话：「qgc发给px4的航线中**没有降落点**，是由一系列航点组成」⇒ 末项是
        //      **普通航点**；它由 `OpsCommon.appendLandingWaypoint`（A1，见下面那一行）**追加**，
        //      **不是**把某一点打成 85。
        //    · 用户的运行红线「**除非要坠机了，否则飞机只能在机位上降落**」：85 会让 PX4 落在
        //      **站点航点**上，而站点航点坐标 **≠ 机位坐标** ⇒ 打 85 就是把飞机落在站上而不是机位上。
        //      真正的降落走的是**另一条链**（Guided goto 到接机机位）。
        //    ⇒ 第三个实参 `endWaypointId` **刻意传 `undefined`** ⇒ `OpsCommon._endWaypointIndex`
        //      恒回 `-1` ⇒ 没有 `i === endIdx` 的点 ⇒ `isEnd` 恒为 `false` ⇒ 追加项的
        //      `command: 21` 经 `_designCommandToMavCmd` 恒映射成 `16 NAV_WAYPOINT` —— 正是 A1
        //      要的落点。"若将来推翻 R-A1 会咬到谁"详见 `OpsCommon._endWaypointIndex` 的函数头注释。
        //
        // ‼️ **为什么不能按"列表位置"推断终点**（与上面那条裁定无关，本条**仍然成立**）：
        //    `GET /routes/:id/waypoints`（后端 `route.go` 的 `ListWaypoints`）**不返回起降点**：
        //    它读 `table_route_waypoint`（+JOIN `table_waypoint`）拿中间航点，**再**读
        //    `table_route.plan_data`，用 `mission.items[i].command` 覆写各点 command、并在头部
        //    插一个 home 点（`command=-1`）；**唯独不读** `table_route.start_waypoint_id` /
        //    `end_waypoint_id` 这两列 ⇒ 始发站 / 终点站**不在返回列表里**。
        //    （2026-09-29 审查 A5 修正：原注释写「只读 `table_route_waypoint` 一张表」——错，
        //      它还读 `plan_data`。⚠️ 这个过简措辞是从后端照抄来的，`handlers/ops.go` 的
        //      `MyRouteWaypoints` 一带亦然 —— **按函数名定位，别按行号**。）
        //    （对照：`handlers/ops.go` 的 `buildTaskWaypoints` 才把这两列读进来拼在首尾，
        //      两处口径差记在 `handlers/ops.go` 的 `MyRouteWaypoints` 函数头注释里（写着
        //      「已知且本次不修的口径差」）—— **按函数名 / 那句话定位，别按行号**。
        //      原注释此处曾引 `ops.go` 的两个行号区间，是 2026-09-29 审查 A3 修正掉的错行号，
        //      本轮（2026-10-01）把**行号定位本身**一并去掉 —— 行号必漂。）
        //    **云端权威库**全量复核（2026-10-01，7 条航线逐一核算；**本机 `db_uavm.db` 是陈旧副本、
        //    连 NRRSM 的列都没有，别拿它当判据**）：
        //      · 4 / 5 / 23 的 `end_waypoint_id` **就在**返回列表里且**恰为末项** ⇒ 行为 2（原样返回）；
        //      · **1 / 20 / 21** 的返回列表**非空**、终点**不在**其中 ⇒ 行为 1（追加），列表末项是**中途点**；
        //      · 22 的 `table_route_waypoint` 是**零行** ⇒ 先撞**行为 7（空序列）**，**不经过追加分支**。
        //    ⚠️ 别把这三条并成「1/20/21/22 都不在序列里」—— 22 落到的是行为 7，不是行为 1。
        //    ⚠️ 反面的教训仍然适用：拿一条"终点恰好也在列表中"的航线做样本，会得到**假绿的 ✓**
        //    （该形状在权威库里确实存在 —— 4/5/23 就是），所以两种形状都必须有用例。
        //    ⚠️ **出处等级**：上面这些读数**不是本任务测的**，是**控制方（编排者）2026-10-01
        //    只读实测**；采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、
        //    **只读**打开（`file:...?mode=ro&immutable=1`）、范围 `table_route` 中
        //    `deleted_at IS NULL` 的全量 7 条。**本任务（QGC 仓）无云端凭据，未独立复核。**
        //
        // ‼️ 第 4 个实参 `_cruiseAGL` 是 NRRSM 新增的：中间项在 `routeMissionItems` 内
        //    组装成「该航点地面海拔 + `_cruiseAGL`」。
        //
        // 【A1 顺带修好的潜伏缺陷】`routeMissionItems` 里 `missionAlt = (i < lastIdx) ? alt + cruiseAGL : alt`
        //    的分界是 `lastIdx = wps.length - 1`。**改动前**列表末项是**中途点**（降落点不在列表里）
        //    ⇒ 真正的末段中途点**少加了一个 `cruiseAGL`**。追加之后 `lastIdx` 正好是降落项
        //    ⇒ 该缺陷消失。**这不是"顺手改的无关事"** —— 它就是判据 7
        //    （飞行高度 = `waypoint.altitude + cruise_alt_agl`）此前会算错的那一格。
        //
        // ‼️ 空序列必须在**这里**先拦下，原因见下一行注释。
        if (!wps || !wps.length) return _fail(qsTr("航线没有可用航点，无法下发"))
        // A1：把「降落站点对应的航点」追加为**末项**（裁定 R-A1，2026-10-01）。
        // ‼️ 空序列必须在**上面那一行**拦下，不能只靠本行：
        //    `appendLandingWaypoint` 对空输入也回 `[]`（它是纯函数，"空"与"降落点不可用"
        //    不能混在一个返回值里），而下面那句文案是「未设定可用的**降落站点**」——
        //    那会把用户指向降落站点，而真正的原因是**航线自己一个航点都没有**。
        //    这个坑本文件 `start()` 里「未设定飞行高度」那道拒发闸的注释已明文警告过一次
        //    （"若把不可用值直接喂给 `routeMissionItems` ⇒ 文案指向错误的方向"），别在它旁边再犯一次。
        //    （⚠️ 原写的是行号 `:171-173` —— 行号会被同文件增删行顶偏，故改为函数锚点。）
        //    **云端权威库**航线 22（`RT-005`）就是这个形态：`end_waypoint_id=2` 但
        //    `table_route_waypoint` 里**一行都没有**（2026-10-01 全量 7 条逐一核算；
        //    **可达，非假想**）。
        //    ⚠️ **出处等级**：本句读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
        //    采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
        //    （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
        //    **本任务（QGC 仓）无云端凭据，未独立复核。**
        var landed = OpsCommon.appendLandingWaypoint(wps, _endWaypointId, _endLat, _endLon, _landingGroundMSL)
        // ‼️ 本条文案能盖到的 `[]` 成因（**以 `OpsCommon.appendLandingWaypoint` 内的 `return`
        //    字面量为准**；下面的条数是本次清点的结果，**别按计数记**）：
        //      ① 空 / 非数组 `wps` —— 已被**上面那道前置闸**用另一句文案（「航线没有可用航点」）
        //         先拦下 ⇒ 走不到本行（两句话必须分开：本句说的是"降落站点"，那句说的是
        //         "航线自己一个航点都没有"）；
        //      ② `endWaypointId` 不可用（`undefined` / `null` / `0` / 非 number）—— 真库最常见的一类
        //         （`end_waypoint_id` 是可空列，后端有两处 UPDATE 会把它置 NULL）；
        //      ③ 终点航点**在列表里但不是末项** —— fail-closed；
        //         云端权威库全量 7 条**无一**落到这一档（落点：1/20/21 → 行为 1；4/5/23 → 行为 2；22 → 行为 7）；
        //      ④ `endLat` / `endLon` 过不了 `isValidWaypoint`（任一轴为 0）—— **仅追加分支**；
        //         后端在无终点航点时把这两键 `COALESCE` 成 `0`，所以它同时也是"后端没给终点"的第二道闸；
        //      ⑤ `endGroundMSL` 不是有限的 JSON number —— **仅追加分支**；
        //      ⑥ （**下一行**的路径，不是本函数）`routeMissionItems` 因某点或 `cruiseAGL` 不可用回 `[]`
        //         —— 由紧跟的那句「航线没有可用航点，无法下发」接住。
        //    ⚠️ **本句文案只对 ②④⑤ 准确**：③ 的实情是"降落站点**设了**、只是不在序列末位"，
        //       被说成"未设定"属于**指向偏**。（裁定：为一条云端不可达的路径引入"带原因的富返回值"
        //       会牵动既有调用点 ⇒ **park**；此处仅登记，供日后维护者判断。）
        //    ⚠️ **出处等级**：③ 那句「全量 7 条无一落到这一档」**不是本任务测的**，是
        //       **控制方（编排者）2026-10-01 只读实测**；采集口径 = `ssh root@39.97.235.226`、
        //       库 `/opt/uavm/var/db_uavm.db`、**只读**打开（`file:...?mode=ro&immutable=1`）、
        //       范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
        //       **本任务（QGC 仓）无云端凭据，未独立复核。**
        if (!landed.length) return _fail(qsTr("该航线未设定可用的降落站点，无法下发"))
        // ‼️‼️ 第三个实参 `undefined` 是**裁定 R-A1 的落点 —— 不是随手写的、也不是"忘了接"**：
        //    改成 `_endWaypointId` 会让该项被打成 **85 `NAV_VTOL_LAND`** ⇒ 飞机落在**站点航点**上，
        //    而**不是接机机位** —— 撞用户的运行红线「除非要坠机了，否则飞机只能在机位上降落」。
        //    ⚠️ 本仓 QML 侧**没有任何测试框架覆盖**（裁定：park 为技术债）⇒ 改这一行**不会有测试变红**，
        //    详据见 `OpsCommon._endWaypointIndex` 函数头的 R-A1 一节。
        var items = OpsCommon.routeMissionItems(landed, vehicle.vtol, undefined, _cruiseAGL)
        if (!items.length) return _fail(qsTr("航线没有可用航点，无法下发"))
        // NRRSM：末项高度换成**降落端的组装式 AMSL** ——
        // `OpsCommon.assembledAltitude(_landingGroundMSL, _landingAGL)`（判据 6 的最后一跳）。
        // 中间航点在 `routeMissionItems` 内已组装成「该航点地面海拔 + `_cruiseAGL`」，
        // 本行**不动**它们，只覆盖末项。
        // ‼️ 这一步必须在 `routeMissionItems` **之后**、`_waypointCount` **之前**：
        //    长度不变，但让「下载的报文」与「界面显示的点数」都基于最终形态。
        items = OpsCommon.applyLandingAltitude(items,
            OpsCommon.assembledAltitude(_landingGroundMSL, _landingAGL))
        _waypointCount = items.length

        // ② 起飞点取**飞机当前 home 位置**（用户 2026-09-23 裁定 c）。
        //    GPS 未定位 ⇒ home 无效 ⇒ 没有可用的起飞坐标。这一步在闸上还会再判一次
        //    （Task 4），两处都留是有意的：这里防"下发一条起点错误的航线"，
        //    闸那里防"按钮亮着却点不动"。
        var home = vehicle.homePosition
        if (!home || !home.isValid) return _fail(qsTr("无人机尚未完成 GPS 定位，无法下发航线"))

        // NRRSM（2026-09-30）：起飞高度改取**航线**的 takeoff_alt_agl（并受起飞站点最低
        // 安全高度的硬下限约束），不再取首个航点的高度。
        // 理由（用户 2026-09-28 原话）：VTOL 需要转换，所以必须升到安全高度才会转换
        // ⇒ 起飞项是**转换门槛高度**，独立取自起飞机场，与第一个中间航点无关。
        // ‼️ 判据必须是 **AGL 项** `_takeoffAGL`，**不是**组装后的 AMSL（`_takeoffGroundMSL + _takeoffAGL`）：
        //    若判组装后的 AMSL > 0，那么「航线值与站点值都没设（都是 0）、而站点地面海拔 100 米」时，
        //    合成的 AMSL = 100 > 0 ⇒ 闸放行 ⇒ 飞机被指令到**贴地 100 米**飞 ——
        //    这正是 NRRSM 要杀的症状。**地面海拔会把 0「救活」。**
        // ‼️ 判据形状由**单点定义** `OpsCommon.nrrsmUsableAGL` 给出（W1，2026-10-01，
        //    与本文件另两道高度闸同源）：它一条同时覆盖非数（字符串 / `undefined`）、
        //    非有限（`NaN` / `Infinity`）与 `<= 0`（含 `0` = 「未设定」的编码）。
        //    ‼️ **`0` 必须拒** —— 本闸改动前的形状 `!(x > 0)` 碰巧也拒 `0`，
        //    但那是两道闸**各写各的**；收敛成单点定义是为了「改一处不漏另一处」。
        var takeoffAGL = _takeoffAGL
        if (!OpsCommon.nrrsmUsableAGL(takeoffAGL)) return _fail(qsTr("该航线未设定有效的起飞高度，无法下发"))

        // NRRSM（2026-09-30 fix round 1，复审 C1）：降落高度**必须与起飞高度同形地判**。
        // ‼️ 判据**三项高度闸共用同一个单点定义** `OpsCommon.nrrsmUsableAGL`（W1，2026-10-01），
        //    与上面那道闸**同源**，理由也同形 —— `0` 是本设计里
        //    「未设定」的编码（见 `handlers/route.go` 的字段注释、v35 的 `REAL DEFAULT 0`），
        //    而 `0` 能穿过**两道**既有守卫：
        //      · `OpsCommon.routeAltitudeBounds` 的 `pick()` 只拦非数/非有限
        //        （`typeof 0 === "number"` 与 `isFinite(0)` 都为真 ⇒ 0 原样返回）；
        //      · `OpsCommon.applyLandingAltitude` 的守卫是同一条。
        //    ⇒ 末项会以 **AMSL 0 米**下发，而帧是 `AltitudeFrameAbsolute`（绝对高度，
        //    不是对地高度）⇒ 字面意义地撞地。
        //    ⚠️ D6 起本闸的被读量是**合成量** `_landingAGL = max(_landingAltAGL, _landingClearAGL)`，
        //    链路的第一环从 `routeAltitudeBounds.pick` 变成了这个 **`max(...)` 合成** ——
        //    但「`0` 能穿过上面两道守卫」的结论**不变**：`0` 仍是合法数字（`max(0, 0) = 0`），
        //    合出来的还是 `0` ⇒ 闸照样要拦。判据仍是 `nrrsmUsableAGL` 那三步里的值域那一步
        //    （`> 0`，**不是**只判 `isNaN`）。
        //    实测链路（复审逐环确认，一环未断；D6 把第一环换成了合成）：
        //      routeAltitudeBounds.pick →（D6：`_landingAltAGL` 与 `_landingClearAGL` 经 `max` 合成
        //      `_landingAGL`）→ `_landingAGL = 0` → applyLandingAltitude 直传
        //      → `{ command, lat, lon, alt: amsl, frame }` → `_applyAltitude(vi, 0)`。
        // ⇒ 未设定就该拒绝下发，而不是构造出一条高度为 0 的、能飞出去的航线。
        //
        // 顺带：本闸也关掉了 `_statusText` 渲染出字面 `nan` 的**其中一条**路 ——
        // ‼️ **只覆盖 AGL 项**（`_landingAGL`）为非有限的那一条：它为 NaN 时 `nrrsmUsableAGL`
        //    回 `false`（非有限那一步）⇒ 在那条**插值两个高度**的 `_statusText` 赋值之前就返回了。
        //    ［2026-10-01 I2 收窄］原文写的是「关掉了那条路」（无限定），**对地面海拔项不成立**：
        //    `_landingGroundMSL` 为 NaN 时本闸照常放行、`_statusText` 照样渲染 `nan`。
        //    地面海拔项改由**下面那道新闸**（`nrrsmFiniteGroundMSL`）负责。
        // 说的是**那一条特定**的赋值，不是「任何一次」—— 下面的 `_fail` 自己也会写 `_statusText`（失败原因就是它写的）。
        if (!OpsCommon.nrrsmUsableAGL(_landingAGL)) return _fail(qsTr("该航线未设定有效的降落高度，无法下发"))

        // NRRSM（I2，2026-10-01）：**地面海拔项**两侧都要有闸 —— 上面三道高度闸判的都只是 **AGL 项**。
        // `OpsCommon.assembledAltitude(groundMSL, agl)` 有**两个**输入项，而地面海拔项此前
        // **两侧都没有闸**：三个消费点（末项 `applyLandingAltitude`、起飞项 `_applyAltitude`、
        // `_statusText` 的两个 `arg`）**全部无守卫**，且后果都是**静默**的 ——
        //   · 末项：`applyLandingAltitude` 的守卫 `!isFinite(amsl)` 直接 `return items`
        //     ⇒ 末项**留在「中间项口径」**（该航点地面海拔 + `_cruiseAGL`），**不是降落端组装式**
        //     ⇒ 飞机按**巡航高度**飞向降落点，界面上零报错；
        //   · 起飞项：`_applyAltitude` 无守卫 ⇒ 写进 `NaN`；
        //   · `_statusText`：渲染出字面 `nan`。
        // ‼️ 这一条对**真实数据可达**，不是假想：`OpsCommon.appendLandingWaypoint` 的「行为 2」
        //    （`last.id === endWaypointId` ⇒ 原样返回）在坐标 / 地面海拔两道守卫**之前**返回
        //    ⇒ 那些守卫**结构上盖不到它**；行为 2 正是云端权威库 4 / 5 / 23 三条的形状。
        // ‼️ 判据由**单点定义** `OpsCommon.nrrsmFiniteGroundMSL` 给出（与 `nrrsmUsableAGL` 并列），
        //    它**只判有限性、不判值域**：地面海拔 `0`（海平面）/ 负数（低于海平面）都是**合法**值，
        //    复用 `nrrsmUsableAGL` 的 `> 0` 会把这类合法航线一并拒掉。
        // ‼️ 位置**必须**在 `_state = "building"` **之前**，也就是**早于**上面那三个消费点
        //    （末项在 `_buildAndSend` 的 ① 段、起飞项在 ④ 段、`_statusText` 紧接本行之后）。
        if (!OpsCommon.nrrsmFiniteGroundMSL(_takeoffGroundMSL) ||
            !OpsCommon.nrrsmFiniteGroundMSL(_landingGroundMSL)) {
            return _fail(qsTr("该航线未取到起降站点的地面海拔，无法下发"))
        }

        _state = "building"
        // ‼️ 插值的是**组装后的 AMSL**（`该端地面海拔 + 该端 AGL 合成值`），**不是**用户填的 AGL 值。
        //    本句要传达的是「飞机**实际会飞到多少米**」，故取 AMSL。
        // ⚠️ 用户填的是 AGL ⇒ 这两个数字**不等于**他填的那个值（差一个站点地面海拔）——
        //    这是一个**可撤销的展示选择**，不是行为：日后若认为该显示 AGL，
        //    只改这两个 `arg` 的表达式即可，**文案一字不动**。
        _statusText = qsTr("正在构造航线…（起飞 %1 m / 降落 %2 m）")
            .arg(OpsCommon.assembledAltitude(_takeoffGroundMSL, _takeoffAGL))
            .arg(OpsCommon.assembledAltitude(_landingGroundMSL, _landingAGL))

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

        // ④ 起飞项。坐标用 home（见上面第 ② 段，用户 2026-09-23 裁定 c 的落点）；
        //    高度用**起飞端的组装式 AMSL** —— `_takeoffGroundMSL + _takeoffAGL`，
        //    其中 `_takeoffAGL = max(_takeoffAltAGL, _takeoffClearAGL)`（D6 生效值）。
        //    NRRSM 之后**不再**取首个航点的高度
        //    （裁定 e 的原文是「起飞高度 = 第一个航点的高度」，见 `OpsCommon.js` 里
        //     `takeoffAltitude` 的函数头注释；
        //     NRRSM 起该语义作废，高度改由航线的 `takeoff_alt_agl`（配起飞站点最低安全高度的
        //     硬下限）提供，理由见上面那道起飞闸）。
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
        // ‼️ 这里写进去的是**组装后的 AMSL** `OpsCommon.assembledAltitude(_takeoffGroundMSL, _takeoffAGL)`
        //    （判据 5 的最后一跳），与上面那道闸读的 **AGL 项** `_takeoffAGL`
        //    **单位不同、不可互换**：闸判「离地多高」，这里写「实际海拔」
        //    （帧是 `AltitudeFrameAbsolute` / AMSL，见 `_applyAltitude`）。
        var takeoff = _plan.missionController.insertTakeoffItem(home, -1)
        _applyAltitude(takeoff, OpsCommon.assembledAltitude(_takeoffGroundMSL, _takeoffAGL))

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
