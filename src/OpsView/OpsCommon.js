.pragma library

//==========================================================================
// OpsView / RomView 共用的纯函数库（展示映射、交接派生、本地报文判定、流向派生）
//
// ‼️ 为什么必须是 `.pragma library`：QML 里**方法调用不注册绑定依赖**——在 QML 文件内
//    定义的函数，其函数体里读到的属性发生变化**不会**让调用点重估（`OpsView.qml:23-24`
//    有同类记录：读 `AuthController.roles` 属性而非 `hasRole()` 方法，正是因为方法调用
//    不注册依赖）。搬进库文件后一切输入都必须走**实参**，绑定依赖因此落在调用点的实参
//    表达式上——这正是两个视图能共用同一份判据、又各自正确刷新的原因。
//
// ‼️ 本文件里**不许**读任何 QML 属性、**不许**用 QML 单例（`multiVehicleManager` /
//    `AuthController` / `QtPositioning` / `ScreenTools` …）：库文件里它们不存在，写了
//    也不报错，只在运行时求值为 `undefined`。依赖 QML 单例的判定（如 `_canTakeoff`
//    要遍历 `multiVehicleManager.vehicles`）一律留在视图侧，用**函数属性**注入给
//    `TaskListPanel`。
//
// ‼️ `qsTr` 在本文件中**已实测可用**（`typeof qsTr === "function"`，离屏 QML 探针
//    实测返回 "飞行中"），故文案层可逐字搬运。副作用是翻译上下文归属本库文件而非
//    调用组件——当前无 `.ts` 翻译文件时两者都返回原文，运行时行为不变。
//==========================================================================


//--------------------------------------------------------------------------
// 常量
//--------------------------------------------------------------------------

// 任务列表两张卡之间、以及机位平面图相邻机位之间的间隔，**单点定义**在这里。
// 用户 2026-09-18：「间隔参照任务列表中两个卡片的间隔」——`SlotLayout.fixedGap` 与
// 两个 ListView 的 `spacing` 都绑它，别在别处另写字面量（`OpsView.qml:68` 原文）。
var taskCardGap = 6


//--------------------------------------------------------------------------
// 展示映射
//--------------------------------------------------------------------------

// 任务显示号：优先航班号（无人机号），无则回退任务号
function taskNo(task) { return task ? (task.uav_no ? task.uav_no : task.task_no) : "—" }

// task.status → 中文。**界面不出现裸枚举**（用户长期规则）。
// ⚠️ 原文如此**没有** `qsTr`，不要"顺手统一"加上。
// ⚠️ `default: return s` 是**断路器不是译文**：未知状态原样露出，好过编一个错的中文。
//    它是"这里有个没收录的状态"的显式信号——看到它就该补 case，别把它当正常输出。
// ‼️ 收录范围以**后端会写进 `table_flight_task.status` 的字面量**为准。`finishedTaskStatuses`
//    （`handlers/task.go`）用的是 `"COMPLETED","ABORTED","CANCELED","CANCELLED"`——
//    注意 **`ABORTED` 与这里的 `ABORT` 是两个不同字面量**（[[task-status-enum-literal-split]]
//    的三套枚举之一），所以两个都得收，只留 `ABORT` 会让 `ABORTED` 裸奔。
//    2026-09-23 实测真库在用的是 `READY` 与 **`CANCELED`**（各 7 / 2 条）。
function statusLabel(s) {
    switch (s) {
    case "SCHEDULED": return "待起飞"; case "READY": return "就绪"; case "TAKEOFF": return "起飞中"
    case "IN_FLIGHT": return "航线中"; case "LANDING": return "降落中"; case "COMPLETED": return "已完成"
    case "ABORT": case "ABORTED": return "中止"; case "FAILED": return "异常"
    case "CANCELED": case "CANCELLED": return "已取消"
    default: return s
    }
}

// 交接目标阶段 → 中文
function phaseToLabel(p) { return p === "ROUTE" ? "航线监控" : p === "LANDING" ? "降落指挥" : p }

// 状态文字 = task.status + 本地报文判定叠加（仅显示不落库，2026-09-02 触发语义）：
// task TAKEOFF 且 vtol_state=FW(4) → "飞行中"；task LANDING 且 landed bit0(ON_GROUND) → "已落地"。
function displayStatus(task, handoverById) {
    if (!task) return "—"
    var l = task.latest
    if (task.status === "TAKEOFF" && l && Number(l.vtol_state) === 4) return qsTr("飞行中")
    if (task.status === "LANDING" && l && (Number(l.landed) & 1) !== 0) return qsTr("已落地")
    // IN_FLIGHT 阶段文案，与按钮重键一致（§6.0-E/F）：待监控员接管 / 待接收降落 / 已签入待发降落指令
    if (task.status === "IN_FLIGHT") {
        if (pendingPhase(task, "ROUTE", handoverById)) return qsTr("待接管")
        if (pendingPhase(task, "LANDING", handoverById)) return qsTr("待降落")
        if (landingAccepted(task)) return qsTr("待发降落")
    }
    return statusLabel(task.status)
}

// 状态色：交接超时优先（红），其次按 task.status + 本地落地判定
function statusColor(task, nowMs, handoverById) {
    var s = task ? task.status : ""
    if (isTimeout(handoverFor(task, handoverById), nowMs)) return "#ff3b3b"
    var l = task ? task.latest : null
    // 已落地（本地报文 landed bit0，显示态）→ 绿；飞行中叠加态沿用黄色
    if (s === "LANDING" && l && (Number(l.landed) & 1) !== 0) return "#2ecc71"
    switch (s) {
    case "TAKEOFF": case "IN_FLIGHT": case "LANDING": return "#ffc107"
    case "COMPLETED": return "#2ecc71"
    // ‼️ `ABORTED` **必须与 `ABORT` 并列**：两者是**不同的字面量**（`handlers/task.go` 的
    //    `finishedTaskStatuses` 写的是 `ABORTED`），而 `statusLabel` 早已两个都收 ⇒ 只收
    //    一个的后果是状态字写「中止」、颜色却是 default 的中性蓝，语义正好相反。
    //    可达性：③ 的状态白名单不含 `ABORTED`，只有该航班**同时挂着未闭环异常**时才进列表。
    // ⚠️ `CANCELED`/`CANCELLED` 同样落 default 蓝——那是有意的（"已取消"用中性色）。
    case "ABORT": case "ABORTED": case "FAILED": return "#ff3b3b"
    default: return "#3b9cff"
    }
}

// 任务性质：本站相对航线的角色（起飞点→出场，降落点→入场）
function taskNature(task, mySiteId) {
    if (!task) return "—"
    if (task.takeoff_site_id !== undefined && Number(task.takeoff_site_id) === Number(mySiteId)) return qsTr("出场")
    if (task.landing_site_id !== undefined && Number(task.landing_site_id) === Number(mySiteId)) return qsTr("入场")
    return "—"
}

// 航线性质：固定/临时。暂假定固定；后端 overview 已带 route_type（协议保留状态位），空回退"固定"。
function routeNature(task) {
    var rt = task ? task.route_type : ""
    if (/temporary|temp/i.test(rt)) return qsTr("临时")
    return qsTr("固定")
}

// 计划起飞时刻 → "HH:mm"。
// ⚠️ 原文用 `new Date(plan_takeoff_at)`：若后端给的是 UTC 裸串（无时区标记），ECMAScript 按
// **本地时区**解析 ⇒ CST 下显示偏 +8h。这是**既有行为**，本轮抽取原样搬运、不顺手"修"它
//（`deadlineMs` 那处补 T/Z 是原代码就有的，两者口径本就不同，别统一）。
// 无效日期回退原串——与 `taskNo`/`taskNature` 回退 "—" 的写法刻意不同，也是原文如此。
function formatPlanTakeoff(task) {
    if (!task || !task.plan_takeoff_at) return "—"
    var d = new Date(task.plan_takeoff_at)
    if (isNaN(d.getTime())) return task.plan_takeoff_at
    return d.toLocaleTimeString(Qt.locale(), "HH:mm")
}

// **无人机**状态文案（机位卡片用）。≠ 机位状态文案（机位状态见 SlotLayout.qml 的 _slotStyles）。
function uavStatusLabel(s) {
    switch (s) {
    case "PARKED": return "已停放"; case "PREFLIGHT": return "准备中"; case "READY_TO_TAKEOFF": return "待飞"; case "TAKEOFF": return "起飞中"; case "IN_FLIGHT": return "飞行中"
    case "RETURNING": return "返航中"; case "DIVERTED": return "备降"; case "EMERGENCY_LANDING": return "迫降"; case "LANDING": return "降落中"; case "LANDED": return "已落地"
    case "PARKED_YARD": return "停放场"
    default: return s || "—"
    }
}


//--------------------------------------------------------------------------
// 交接派生
//--------------------------------------------------------------------------

// `handoverById` 由 OpsShell 从 pending 列表构建：`{task_id: handover}`，**仅含 PENDING 交接**。
// 无交接的任务返回 `undefined`（调用点因此必须用三元式而非 `&&`，见 isMine 上方注释）。
function handoverFor(task, handoverById) {
    if (!task || !handoverById) return undefined
    return handoverById[task.task_id]
}

// 某任务是否存在 PENDING 且 phase_to 匹配的交接。
// `landing_accepted` = 已签入(LANDING)（存在 ACCEPTED phase_to=LANDING 交接；
// accept 仅管理交接，DB 状态不变，§6.0-E/F）。
function pendingPhase(task, phase, handoverById) {
    var h = handoverFor(task, handoverById)
    return !!(h && h.phase_to === phase)
}

function landingAccepted(task) { return !!(task && task.landing_accepted) }

// ‼️ 判定函数一律返回**真 bool**（`!!` 不可省）：返回 undefined 会让调用点的 `A && B`
// 短路求值成 undefined，而 QML 把 undefined 当成「这个绑定没有值」，属性退回**默认值**——
// `visible`/`enabled` 的默认值都是 true，于是无交接的任务反而长出「撤回交接」按钮。
// 调用点同理：必须是三元式 `h ? isMine(h, id) : false`，不能写 `h && isMine(...)`。
function isMine(handover, userId) { return !!(handover && handover.proposed_by === userId) }

// deadline_at 由后端以 UTC 裸串落库/返回（time.Now().UTC().Format("2006-01-02 15:04:05")，无 T/时区标记）；
// ECMAScript 对无时区串按本地时区解析（中国 CST=UTC+8 → 会提前 8h 判"超时"）。此处补 'T' 与 'Z' 使其按 UTC
// 解析，与后端 datetime('now') 比较口径及遥测 timestamp（RFC3339 带 Z）一致；已是 ISO+时区则原样放行。
function deadlineMs(handover) {
    var s = handover ? handover.deadline_at : ""
    if (!s) return NaN
    if (s.indexOf("T") < 0) s = s.replace(" ", "T")
    if (s.indexOf("Z") < 0 && !/[+-]\d{2}:\d{2}$/.test(s) && !/[+-]\d{4}$/.test(s)) s += "Z"
    return Date.parse(s)
}

function remainingSec(handover, nowMs) {
    if (!handover || !handover.deadline_at) return ""
    var deadline = deadlineMs(handover)
    if (isNaN(deadline)) return ""
    var sec = Math.ceil((deadline - nowMs) / 1000)
    return sec > 0 ? sec + "s" : "超时"
}

function isTimeout(handover, nowMs) {
    if (!handover || !handover.deadline_at) return false
    var deadline = deadlineMs(handover)
    return !isNaN(deadline) && nowMs > deadline
}


//--------------------------------------------------------------------------
// 本地报文判定（仅显示/门控，不落库；2026-09-02 触发语义）
// vtol_state=FW(4)=巡航；landed 取 bit0（起降位掩码 bit0=ON_GROUND）；遥测新鲜=latest.timestamp 在窗口内。
//--------------------------------------------------------------------------

function isCruising(task) {
    var l = task ? task.latest : null
    return !!(l && Number(l.vtol_state) === 4)
}

function isLandedOnGround(task) {
    var l = task ? task.latest : null
    return !!(l && (Number(l.landed) & 1) !== 0)
}

// `windowMs` 原为视图上的 `_liveTelemetryWindowMs`（15000）
function hasLiveTelemetry(task, nowMs, windowMs) {
    var l = task ? task.latest : null
    if (!l || !l.timestamp) return false
    var ts = Date.parse(l.timestamp)
    if (isNaN(ts)) return false
    var age = nowMs - ts
    return age <= windowMs && age >= -5000   // 容忍服务器时钟超前 ≤5s
}


//--------------------------------------------------------------------------
// 流向派生（站点视图用；监控员视图不过滤）
//--------------------------------------------------------------------------

// 出场=本站=起飞点且尚未完成切出：SCHEDULED/READY/TAKEOFF，以及落库 IN_FLIGHT 后 PENDING(ROUTE)
// 交接待监控员确认的重叠期（§6.0-F：签出=责任里程碑；确认接管后退出出场）。
function isOutbound(task, mySiteId, handoverById) {
    if (task.takeoff_site_id === undefined || task.takeoff_site_id === null) return false
    if (Number(task.takeoff_site_id) !== Number(mySiteId)) return false
    if (task.status === "SCHEDULED" || task.status === "READY" || task.status === "TAKEOFF") return true
    return task.status === "IN_FLIGHT" && pendingPhase(task, "ROUTE", handoverById)
}

// 入场=本站=降落点：PENDING(LANDING) 待确认 / landing_accepted 已签入待发降落指令 / LANDING 已发降落指令。
function isInbound(task, mySiteId, handoverById) {
    return task.landing_site_id !== undefined && task.landing_site_id !== null &&
           Number(task.landing_site_id) === Number(mySiteId) &&
           (task.status === "LANDING" || pendingPhase(task, "LANDING", handoverById) || landingAccepted(task))
}

// 站点视图的行集合：出站/进站两个勾选框分别过滤
function siteTasks(tasks, outbound, inbound, mySiteId, handoverById) {
    var out = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        if (outbound && isOutbound(t, mySiteId, handoverById)) out.push(t)
        else if (inbound && isInbound(t, mySiteId, handoverById)) out.push(t)
    }
    return out
}

// 监控员视图的行集合：overview 已按负责航线过滤 IN_FLIGHT，原样返回
function routeTasks(tasks) { return tasks }


//--------------------------------------------------------------------------
// 航线监控员：航线缓存派生与异常判定（设计文档 §2.3 / §4 / §5.3）
//--------------------------------------------------------------------------

// 异常：**唯一判据点**。`obj.event != null` ⇔ 该对象背后有一条未闭环的异常事件
// （后端 ③ 只在 `event_type IN ('DIVERT','RETURN','FORCED_LANDING') AND status IN ('OPEN','STAGE_DONE')`
//  时才填这个字段，所以"有没有 event"本身就是后端判完的结果，QGC 侧不再复判 type/status）。
// ‼️ 入参 **task 或 device 都可以**——两者的 `event` 是**同一个对象**（§1.4）。
//    **不要**因为两处调用长得不一样就复制出第二个函数：那会让"什么算异常"有两个定义。
function isAbnormal(obj) { return !!(obj && obj.event != null) }

// 异常种类。未知值返回**空串**而不是原值——界面不出现裸枚举（`ui-no-raw-enum-labels`）。
function abnormalKind(obj) {
    if (!isAbnormal(obj)) return ""
    var t = obj.event.type
    return (t === "DIVERT" || t === "RETURN" || t === "FORCED_LANDING") ? t : ""
}

// 异常三色，**单点定义**（§5.3 第 1 条）。
// ⚠️ 未知 type 返回 `""`，调用方必须回退到常规色——**不要兜底成红色**：
//    红色是迫降的语义，未知值兜底成红会让一条普通告警看起来像坠机（§5.3 明写）。
function abnormalColor(kind) {
    switch (kind) {
    case "DIVERT":          return "#ff9800"   // 备降 橙
    case "RETURN":          return "#ffd54f"   // 回航 黄
    case "FORCED_LANDING":  return "#ff3b3b"   // 迫降 红
    default:                return ""
    }
}

// 飞机 marker 的着色（§5.3，**入参是 device 不是 task**）。
// 优先级：异常 > 按飞机状态。
// ⚠️ 第 2 条**没有**复用 `statusColor`：那个函数的 switch 判的是**任务**状态
//    （TAKEOFF/IN_FLIGHT/LANDING/COMPLETED/ABORT/FAILED），拿**飞机**状态喂进去时
//    `RETURNING`/`EMERGENCY_LANDING`/`READY_TO_TAKEOFF` 全会掉进 default 变蓝
//    ——「返航中」被画成待命蓝。§5.3 写的是"复用既有色表"，此处按**该表表达的颜色语义**
//    写死映射，取值与 `statusColor` 逐字相同（飞行黄 / 其余蓝）。
function deviceColor(device) {
    var c = abnormalColor(abnormalKind(device))
    if (c !== "") return c
    switch (device ? device.uav_status : "") {
    case "TAKEOFF": case "IN_FLIGHT": case "LANDING": case "RETURNING": case "EMERGENCY_LANDING":
        return "#ffc107"
    default:
        return "#3b9cff"
    }
}

// 选中航线时的显隐（§5.3）。返回 "lit" | "dimmed" | "normal"。
// ‼️ **异常飞机恒 "lit"**：用户同时要求「异常航班常驻」与「选中点亮、其余淡化」，
//    机械执行后者会让一架**正在迫降**的飞机变成 35% 不透明。**异常优先于选中淡化。**
//    （这是设计文档 §5.3 里作者自己标注的裁定，不是用户原话；若用户不同意，改这一个函数即可。）
function visibleForSelection(device, selectedRouteId) {
    if (selectedRouteId === null || selectedRouteId === undefined) return "normal"
    if (isAbnormal(device)) return "lit"
    return Number(device ? device.route_id : -1) === Number(selectedRouteId) ? "lit" : "dimmed"
}

// 淡化不透明度（数值本身无依据，§5.3 注明"按真机截图调"）
var dimmedOpacity = 0.35

// 位置主源选择（§5.2）。返回 `{lat, lon, source}` 或 **null**（调用方不画 marker）。
//   source = "mavlink"（实时） | "rest"（最多陈旧 2s）
// ‼️ 第三个实参 `vehicleCoord` **不是冗余**：`.pragma library` 里函数体读属性**不注册绑定依赖**
//    （见本文件头部）。把坐标作为**实参**传进来，绑定依赖才落在调用点的表达式上——
//    这样 MAVLink 坐标一变，marker 的 `coordinate` 绑定才会重估。写成 `vehicle.coordinate`
//    在函数体内，界面**看不出异常**，只是位置永远停在第一帧。
function resolvePosition(device, vehicle, vehicleCoord) {
    if (vehicle && vehicleCoord && vehicleCoord.isValid) {
        return { lat: vehicleCoord.latitude, lon: vehicleCoord.longitude, source: "mavlink" }
    }
    // ⚠️ `device.latest` 为 null 是**常态不是异常**（该机尚无任何遥测）⇒ 必须先判 `!!`。
    //    直接写 `device.latest.lat` 会抛 TypeError，而 QML 绑定异常**不中断渲染**，
    //    只把该属性留在 undefined（`qml-undefined-binding-falls-back-to-default-true`）。
    var l = device ? device.latest : null
    if (l && l.lat) return { lat: l.lat, lon: l.lon, source: "rest" }
    return null
}

// 按 `deviceID` 找真实 Vehicle（复用 `OpsView.qml` 的 `_vehicleForTask()` 手法）。
// ⚠️ 是 **deviceID**（MAVLink 帧头那个 32 位数），**不是 `uav_no`、不是 `uav_id`**
//    ——库里的 `table_uav.device_id` 就是这个值。用错字段的后果是永远匹配不上，
//    而匹配不上时的回退正好是 REST `latest` ⇒ 界面看起来完全正常，只是永远不实时。
function matchDeviceToVehicle(device, vehicles) {
    if (!device || !vehicles) return null
    var want = Number(device.device_id)
    if (!(want > 0)) return null          // device_id 缺失/0：**不要**拿 0 去匹配，会认领到别人的机
    // `multiVehicleManager.vehicles` 是 `QmlObjectListModel`：`.count` + `.get(i)`，
    // **不是** JS 数组（`vehicles[i]` / `vehicles.length` 都是 undefined）。
    // `deviceID` 是 `Q_INVOKABLE uint deviceID()` ——**方法不是属性**，少写括号恒得 undefined。
    var n = vehicles.count
    for (var i = 0; i < n; i++) {
        var v = vehicles.get(i)
        if (v && Number(v.deviceID()) === want) return v
    }
    return null
}

// 某条航线下的**活跃飞机数量**（§2.3 / §4.1 上段），用于航线行后面的数字。
// ‼️ 裁定 ③ 的原话是「后面显示飞机的数量」——**数量不是徽标列表**，不要改成逐个列 `uav_no`。
// ‼️ 按 `uav_id` **去重**：③ 的 `tasks[]` 是**一个任务一行**，同一架飞机可能挂多条任务
//    （真库实测：91102 与 91104 共用 uav）。数"条数"会把 1 架飞机显示成 2。
// ‼️ 过滤 `uav_id <= 0`（未指派）——那是"这条任务还没有飞机"，不是"有一架编号为 0 的飞机"。
function activeUavCount(tasks) {
    var seen = {}
    var n = 0
    for (var i = 0; i < tasks.length; i++) {
        var id = Number(tasks[i] ? tasks[i].uav_id : 0)
        if (!(id > 0)) continue
        if (seen[id]) continue
        seen[id] = true
        n++
    }
    return n
}

// 按 `route_id` 把 ③ 的 `tasks[]` 分组，返回 `{ "12": [task, ...] }`。
// ‼️ **按 `routeOrder` 保证键的存在与次序**：无航班的航线 → **空数组，不是缺键**
//    （缺键会让"这条航线没有航班"与"这条航线的数据还没加载"在界面上长得一样）。
function groupTasksByRoute(tasks, routeOrder) {
    var out = {}
    for (var i = 0; i < routeOrder.length; i++) out[String(routeOrder[i])] = []
    for (var j = 0; j < tasks.length; j++) {
        var k = String(tasks[j].route_id)
        if (out[k] === undefined) continue     // ③ 里出现了不在名册里的航线：不新增键
        out[k].push(tasks[j])
    }
    return out
}

// 中段（航班列表）的行集合（§4.1 中段）= 第 1 节 ∪ 第 2 节：
//   第 1 节 **异常航班**：`isAbnormal` 为真的全部航班，**与是否选中航线无关、置顶常驻**。
//          这是裁定 ⑥ 的硬约束——用户指出过「异常飞机应该常驻在屏幕上，而我们又说选择航线，
//          则在列表中显示该航班的航班，这个冲突了」。
//   第 2 节 **在航航班**，随选中状态换口径（用户 2026-09-23 定）：
//          **选中航线 ⇒ 只列该航线的**；**一条都没选中 ⇒ 列全部在航航班**。
//          ‼️ "全部在航"不需要在这里再筛一次状态：③ 端点自己的 WHERE 就是
//             `u.status IN ('READY_TO_TAKEOFF','TAKEOFF','IN_FLIGHT','LANDING','RETURNING',
//              'EMERGENCY_LANDING') OR 有未闭环异常` ⇒ **`tasks` 整个集合本来就是"在航"**，
//             直接全收即对。在这里另写一遍状态白名单＝多一份会与后端漂移的判据。
//          ⚠️ 在这之前，未选中时第 2 节是**整体为空**的（只显示异常）。那是旧口径，已废。
// ‼️ 两节可能包含**同一个航班**（选中了一条有异常航班的航线）⇒ **必须按 `task_id` 去重**，
//    去重后**仍留在第 1 节**（异常的位置更高）。去重漏了的表现是同一条航班在列表里出现两次，
//    看起来像"重复的数据"，不报错。
function middleSectionTasks(tasks, selectedRouteId) {
    var seen = {}, out = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        if (!isAbnormal(t)) continue
        if (seen[t.task_id]) continue
        seen[t.task_id] = true
        out.push(t)
    }
    // 未选中（null / undefined）与"选中了某条"共用下面这一轮循环，只差**过不过滤 route_id**：
    // 早返回式的写法（`if (未选中) return out`）会让"全收"与"按航线收"变成两段各自演化的代码。
    var filterByRoute = (selectedRouteId !== null && selectedRouteId !== undefined)
    for (var j = 0; j < tasks.length; j++) {
        var u = tasks[j]
        if (filterByRoute && Number(u.route_id) !== Number(selectedRouteId)) continue
        if (seen[u.task_id]) continue          // 已在异常节里：保持它在前面
        seen[u.task_id] = true
        out.push(u)
    }
    return out
}

// 从 ③ 的 `devices[]` 提取要推给 C++ 的 device_id 清单（§2.3 / §3.5.3）。
// ‼️ 这是 QML → C++ 的**唯一入口**，漏掉 `<= 0` 的过滤就会在 mavp2p 侧建出一个
//    `deviceID=0` 的 pair——**没有任何一处会报错**。重复项同样过滤（后端已去重，此处是第二道）。
function monitorDeviceIds(devices) {
    var seen = {}
    var out = []
    for (var i = 0; i < devices.length; i++) {
        var id = Number(devices[i] ? devices[i].device_id : 0)
        if (!(id > 0)) continue
        if (seen[id]) continue
        seen[id] = true
        out.push(id)
    }
    return out
}

// 航点坐标是否有效 —— **单点定义**，`routeBounds` 与 QML 的 `OpsShell.routePathOf` 共用。
// ‼️ 口径与 `MapFitFunctions.qml:58` **逐字一致**：两轴都要是有限数，且**任一轴为 0 即无效**
//    （(0,0) 是"没有定位"的常见缺省值；本站航线不会落在赤道或本初子午线上）。
// ⚠️ 这里原先写的是"两轴**同时**为 0 才跳过"，而注释却声称"与 MapFitFunctions 的过滤口径一致"
//    ——**假的一致比不一致更坏**，它会让人不再去比对。而 QML 的 `routePathOf` 更是完全不过滤 0
//    ⇒ 同一个 diff 里的三个消费点三种口径：包围盒丢掉 (0,0)，折线却画到 (0,0)
//    （一条甩到几内亚湾的长线），视野又按不含它的盒子套。现在三处共用本函数。
function isValidWaypoint(la, lo) {
    return isFinite(la) && isFinite(lo) && la !== 0 && lo !== 0
}

// 全部负责航线的包围盒（§7.4）。返回 `{minLat, minLon, maxLat, maxLon}` 或 **null**。
// ‼️ **不复用 `MapFitFunctions.fitMapViewportToAllCoordinates()`**，它有三处不匹配（§7.4）：
//    绑 planMasterController、视口矩形硬编码整图（不扣右栏）、循环从 `i = 1` 起
//    ⇒ **首点不做有效性检查**。这里从 0 起，逐点过滤 `isFinite` 与 0。
// 退化情形由调用方处理：空集合返回 null（**不要**拿它去调 setVisibleRegion）。
function routeBounds(routes) {
    var minLat = NaN, minLon = NaN, maxLat = NaN, maxLon = NaN
    var n = 0
    for (var i = 0; i < routes.length; i++) {
        var wps = routes[i] ? routes[i].waypoints : null
        if (!Array.isArray(wps)) continue
        for (var j = 0; j < wps.length; j++) {
            var wp = wps[j]
            var la = Number(wp ? wp.lat : NaN), lo = Number(wp ? wp.lon : NaN)
            if (!isValidWaypoint(la, lo)) continue
            if (n === 0) { minLat = maxLat = la; minLon = maxLon = lo }
            else {
                if (la < minLat) minLat = la
                if (la > maxLat) maxLat = la
                if (lo < minLon) minLon = lo
                if (lo > maxLon) maxLon = lo
            }
            n++
        }
    }
    return n === 0 ? null : { minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon }
}
