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

// 任务状态 → 中文。⚠️ 原文如此**没有** `qsTr`，不要"顺手统一"加上。
function statusLabel(s) {
    switch (s) {
    case "SCHEDULED": return "待起飞"; case "READY": return "就绪"; case "TAKEOFF": return "起飞中"
    case "IN_FLIGHT": return "航线中"; case "LANDING": return "降落中"; case "COMPLETED": return "已完成"
    case "ABORT": return "中止"; case "FAILED": return "异常"; default: return s
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
    case "ABORT": case "FAILED": return "#ff3b3b"
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
