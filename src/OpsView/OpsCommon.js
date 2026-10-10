.pragma library

//==========================================================================
// OpsView / RomView 共用的纯函数库（展示映射、交接派生、本地报文判定、流向派生）
//
// ‼️ 为什么必须是 `.pragma library`：QML 里**方法调用不注册绑定依赖**——在 QML 文件内
//    定义的函数，其函数体里读到的属性发生变化**不会**让调用点重估（`OpsView.qml` 的
//    `_isSiteATC` 那处有同类记录：读 `AuthController.roles` 属性而非 `hasRole()` 方法，
//    正是因为方法调用不注册依赖）。搬进库文件后一切输入都必须走**实参**，绑定依赖因此落在调用点的实参
//    ⚠️ 引用用**锚点**（`_isSiteATC`）不用行号：行号会被同文件任何一次增删静默顶偏。
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
// 用户 2026-09-18：「间隔参照任务列表中两个卡片的间隔」。
// 消费者一律经 `OpsShell._taskCardGap` → 各面板的 `cardGap` / `SlotLayout.fixedGap`，
// 别在别处另写字面量。（`AlertListPanel` 是唯一直接读 `OpsCommon.taskCardGap` 的。）
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

// 终态任务状态——`statusLabel` 上面那段注释列的**就是这四个字面量**，与后端
// `gcs_server/handlers/task.go` 的 `finishedTaskStatuses` **逐字对应**。
//
// ‼️ QGC 侧唯一用途：给「到站本站」那半句做**外层闸**（见 `isInbound`）。取**黑名单**
//    （排除终态）而非白名单（只收 IN_FLIGHT/LANDING），方向是**刻意**的——仓内已成文的原则：
//    「过滤是给人看的，宁多勿漏」。两个方向的错法**不对称**：
//      · 白名单漏掉一个中间状态 ⇒ 卡片**静默消失**（用户看到"任务列表里没有它"，而飞机遥测
//        走的是另一条路、照常显示 ⇒ 表现为"轨迹和数据都在、任务卡片不在"）；
//      · 黑名单误放行 ⇒ 多一张卡，看得见、改得动。
//    2026-10-02 实测代价：外层原是白名单，把任务 91103（`status='READY'`、飞机
//    `READY_TO_TAKEOFF`、降落本站）整条挡在门外——而它**正是本次需求要收的那一类**
//    ⇒ 里层刚加的白名单分支被**外层**架空。见 `isInbound` 上方那段"两道闸串联"。
//
// ⚠️ `CANCELED` 与 `CANCELLED` **两个拼写都要**：`table_flight_task` 写 `CANCELED`，
//    而 `arrival_schedule` / `table_task_handover` 写 `CANCELLED`
//    （[[task-status-enum-literal-split]]）。只留一个 ⇒ 另一个字面量的任务被当成"非终态"
//    回流进列表，**且没有任何报错**。真库 2026-10-02 实测：交接表里 16 条全是 `CANCELLED`，
//    任务表里那条是 `CANCELED` —— 两个拼写**同时在用**，不是历史遗留。
//
// ⚠️ 本函数对 `null`/`undefined` 是 **fail-open**（判为"非终态"），后端
//    `NULL NOT IN (...)` 求值为 `NULL`（不为真）是 **fail-closed**。两侧在这里**不一致**，
//    但不可达：`table_flight_task.status` 是 `TEXT NOT NULL DEFAULT 'SCHEDULED'`
//    （`PRAGMA table_info` 实测），NULL 写不进去。写在这里是因为"不可达"是**当前 schema**
//    的事实，schema 一改这条缝就会张开口。
var FINISHED_TASK_STATUSES = ["COMPLETED", "ABORTED", "CANCELED", "CANCELLED"]

/// 该任务状态是否为终态。‼️ 返回**真 bool**：返回 `undefined` 会让 `isInbound` 里那句
/// `if (...) return false` 短路求值成 `undefined` 而不是 `false`。
function isFinishedTaskStatus(s) { return FINISHED_TASK_STATUSES.indexOf(s) >= 0 }

// 交接目标阶段 → 中文
function phaseToLabel(p) { return p === "ROUTE" ? "航线监控" : p === "LANDING" ? "降落指挥" : p }

// 状态文字 = task.status + 本地报文判定叠加（仅显示不落库，2026-09-02 触发语义）：
// task TAKEOFF 且 VTOL 已转前飞 → "飞行中"；task LANDING 且已在地面 → "已落地"。
// ‼️ 后两个实参由**调用点**从 `Vehicle` 上读好再传进来（`vtolInFwdFlight` / `flying`），
//    **不要**改成在函数体里读 `vehicle.xxx`：`.pragma library` 的函数体内读属性**不注册
//    绑定依赖**（同 `resolvePosition` 第二实参的注释），状态字会永远停在第一帧而界面不报错。
// 数据源：加密心跳 EXT 重建的 EXTENDED_SYS_STATE（`Vehicle::_handleExtendedSysState`）。
function displayStatus(task, handoverById, vtolInFwdFlight, landedOnGround) {
    if (!task) return "—"
    if (task.status === "TAKEOFF" && vtolInFwdFlight === true) return qsTr("飞行中")
    if (task.status === "LANDING" && landedOnGround === true) return qsTr("已落地")
    // IN_FLIGHT 阶段文案，与按钮重键一致（§6.0-E/F）：待监控员接管 / 待接收降落 / 已签入待发降落指令
    if (task.status === "IN_FLIGHT") {
        if (pendingPhase(task, "ROUTE", handoverById)) return qsTr("待接管")
        if (pendingPhase(task, "LANDING", handoverById)) return qsTr("待降落")
        if (landingAccepted(task)) return qsTr("待发降落")
    }
    return statusLabel(task.status)
}

// 状态色：交接超时优先（红），其次按 task.status + 本地落地判定
// `landedOnGround` 同 `displayStatus`：调用点读好传入，不在函数体里读 `vehicle`。
function statusColor(task, nowMs, handoverById, landedOnGround) {
    var s = task ? task.status : ""
    if (isTimeout(handoverFor(task, handoverById), nowMs)) return "#ff3b3b"
    // 已落地（本地报文，显示态）→ 绿；飞行中叠加态沿用黄色
    if (s === "LANDING" && landedOnGround === true) return "#2ecc71"
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

// 交接取数：**优先任务自带的 `task.handover`**，回落到 `handoverById`。
//
// 两个来源的差别是**按角色过滤与否**，缺口正出在这里：
//   - `task.handover`：`Overview`/`RouteTasks` 给**每一项**都附带（后端 `pendingHandover`），
//     **不按角色过滤**。它的语义是一个**事实**——该任务此刻有没有 PENDING 交接；
//   - `handoverById`：由 OpsShell 从 `/handovers/pending` 构建，**按角色过滤**
//     （SITE_ATC 只拿本站 LANDING、ROUTE_MONITOR 只拿其航线 ROUTE）。
//     它的语义是"**待我确认**的交接"。
//
// ‼️ 起飞机场 ATC 是 ROUTE 交接的**提出方**，永远不在「待我确认」名单里 ⇒ 只认后者时，
// 他签出成功的**那一刻**卡片就从自己列表里消失（后端站内视图 SQL 特意保留了
// `IN_FLIGHT + PENDING ROUTE` 这一行，注释写明"签出重叠期出站方仍需见"——**前后端判据相反**），
// 「撤回交接」入口也随之不可达。**可见性用"事实"判，该谁动手用"待办"判，两者不能混用。**
//
// 无交接的任务返回 `undefined`（调用点因此必须用三元式而非 `&&`，见 isMine 上方注释）。
function handoverFor(task, handoverById) {
    if (!task) return undefined
    if (task.handover) return task.handover
    if (!handoverById) return undefined
    return handoverById[task.task_id]
}

// 交接 id 的**两个字段名都是设计文档的约定**，不是笔误：
//   - 任务上的 `handover`（overview/route-tasks 附带）→ `id`（《飞行监控主界面设计》§4.1 响应样例）
//   - `/handovers/pending` 的项 → `handover_id`（同文档 §4 接口表）
// 调用点一律走本函数取值。直接写死其中一个名字，**换源时就静默变 `undefined`**——
// 表现为「撤回交接」POST 到 `/api/handovers/undefined/cancel`（400，且界面无任何提示）。
function handoverId(handover) {
    if (!handover) return undefined
    return handover.handover_id !== undefined ? handover.handover_id : handover.id
}

// 交接操作（accept / reject / cancel）失败时给操作员看的**原因句**。
//
// ‼️ 不假定失败只有一种原因（2026-10-06，审查 C1）。三个调用点原先一律写「操作未送达服务端」，
//    而这三个端点的**实际错误集合是五类**：400 三处、403 九处、404 两处、409 三处、500 十四处。
//    「未送达」**只在 `status === 0` 时成立**——那是 `_send` 在 `_apiBase` 为空、
//    或请求根本发不出去时回调的码。其余四类服务端都**已经答复了**，只是答复是"不许做"或"做不了"。
//
//    ⚠️ **计数口径**（2026-10-06 订正）：按 `c.JSON` 逐档数列，**并**加回经 helper 吐出的那些——
//       `Reject` 的 404 走的是 `helpers.go` 的 `notFoundOrFail`（`sql.ErrNoRows` ⇒ 404），
//       只 grep `c.JSON` 会把它整条漏掉。本条原先写的「404（仅 accept 一处）」就是这么错的。
//       落点：400/403/409 见各分支的 `c.JSON` 字面量；404 = `Accept` 一处直发 ＋ `Reject` 一处经 helper。
//
//    最误导的两类：
//      · 403（「非降落机场操作员」「仅该航线监控员可确认接管」）——被说成"没送到"，
//        操作员会一直重试一个**权限**问题，而该做的是去给降落机场开操作员账号；
//      · 409（「交接已被处理或已超时」）——本该"刷新看最新状态"，被说成"没送到"则会反复重试。
//    两者该做的处置**相反**（开账号 / 刷新），旧文案却让它们在操作员眼里一模一样。
//
// ‼️ **分档透出**（2026-10-06 审查 §1①订正——本条原写"服务端这几句 error 本就是给人看的
//    完整句子，直接透出即可"，**那句对 4xx 成立、对 5xx 为假**）：
//
//      · **4xx 逐字透出**：403/409/400 的 `error` 是后端写好的中文完整句（且**可行动**，
//        如「非降落机场操作员」），前端再译一层只会与后端漂移——后端每加一处分支，
//        前端那张映射表就漏一处，**且漏了不报错**。
//      · **5xx 一律收敛**：这三个端点的 500 出口共 **10/14 处是裸 `err.Error()`**
//        （`Accept` 六、`Reject` 三、`Cancel` 一，见 `ops.go` 各行），吐的是**给机器看的**原文
//        ——`database is locked`、`no such table: ...`、`UNIQUE constraint failed: ...`。
//        而调用点还会在原因句后面拼「；仍失败请通知对方人工处理」⇒ 操作员读到
//        「database is locked；仍失败请通知对方人工处理」，**处置说反了**：那是本地瞬时
//        锁争用，正确动作是过几秒**自己重试**，不是去找人。故此处不透出，只给状态码。
//
// ⚠️ `status === 0` 那条必须写在最前：此时服务端**没有**响应体（`data` 为 `null`）。
// ⚠️ 404 走不到这里：它由调用点判为"已被他端处理"＝成功（幂等收口）。
// ⚠️ 本函数只给**原因句**，"接下来怎么办"由各调用点自己拼——但实际只有**两**种后缀：
//    `_checkinFromCard` 与弹框的 accept/撤回共用「；仍失败请通知对方人工处理」（逐字节相同），
//    拒绝那处单独是「；仍失败请通知提出方撤回重提」。共用一处是**故意**的（同因同果），
//    不是"三处各有各的建议"。
function handoverActionErrorText(status, data) {
    if (status === 0) return qsTr("操作未送达服务端，请重试")
    // 5xx 不透原文（理由见上）。⚠️ 判据是 `>= 500` 而非 `=== 500`：网关侧 502/503/504
    // 的正文同样可能被 `JSON.parse` 成对象带 `error`。
    if (status >= 500) return qsTr("服务端处理失败（HTTP ") + status + qsTr("），请稍后重试")
    if (data && data.error) return data.error
    // 服务端答复了却没带 error（如反代吐的 502/504 HTML 页）：给状态码，别替它编原因。
    return qsTr("服务端返回 HTTP ") + status + qsTr("，请稍后重试")
}

// 某任务是否存在 PENDING 且 phase_to 匹配的交接。
// `landing_accepted` = 已签入(LANDING)（存在 ACCEPTED phase_to=LANDING 交接；
// accept 仅管理交接，DB 状态不变，§6.0-E/F）。
function pendingPhase(task, phase, handoverById) {
    var h = handoverFor(task, handoverById)
    return !!(h && h.phase_to === phase)
}

function landingAccepted(task) { return !!(task && task.landing_accepted) }

// 飞机**至少已 READY_TO_TAKEOFF**（用户 2026-09-22 裁定 2B 的白名单），与
// `gcs_server/handlers/ops.go` 里那份**逐字对应**（`RouteTasks` 与 `view=site` 两处同源）。
//
// ‼️ QGC 侧唯一用途：判定「**到站本站**的航班」算不算进站（见 `isInbound` 第四项）。
//    ⚠️ 原文写"在飞航班"，2026-10-02 起不准了：本条同时放行**还没起飞、正停在他站机位上**
//    的任务（`t.status='READY'` + 飞机 `READY_TO_TAKEOFF`，即用户当日报的那条 91103）。
//    改前站点视图只认「移交过 LANDING 交接」，于是飞机已经飞到本站、监控员还没发起移交的
//    那一段，卡片**根本不出现**；而飞机遥测走的是另一条路（加密心跳 EXT 重建的合成遥测 →
//    `multiVehicleManager`）照常显示 ⇒ 用户看到的是「轨迹和数据都在、任务卡片不在」。
//    那不是"少写了一个过滤条件"，是两条数据路的口径差。
//
// ‼️ 取**白名单**而非"排除法"：`table_uav.status` 无 CHECK 约束，将来多一个状态时排除法会
//    把它**静默**放行（多显示一张不该显示的卡片）；白名单则 fail-closed。
//    两侧名单必须一起改——漂移时没有任何东西会报错，只表现为某些航班卡片时有时无。
function isAirborneReady(uavStatus) {
    return ["READY_TO_TAKEOFF", "TAKEOFF", "IN_FLIGHT", "LANDING", "RETURNING", "EMERGENCY_LANDING"]
        .indexOf(uavStatus) >= 0
}

// ‼️ 判定函数一律返回**真 bool**（`!!` 不可省）：返回 undefined 会让调用点的 `A && B`
// 短路求值成 undefined，而 QML 把 undefined 当成「这个绑定没有值」，属性退回**默认值**——
// `visible`/`enabled` 的默认值都是 true，于是无交接的任务反而长出「撤回交接」按钮。
// 调用点同理：必须是三元式 `h ? isMine(h, id) : false`，不能写 `h && isMine(...)`。
function isMine(handover, userId) { return !!(handover && handover.proposed_by === userId) }

// 「待**我**动手」：这条任务上有一条 PENDING 交接**在等我签入**（用户 2026-09-24 裁定的
// 「待签入航班置顶」与「任务卡醒目警示条」共用本判据）。
//
// ‼️ 判据只取 **`handoverById`**（`/handovers/pending` 构建，**按角色过滤**），
//    **不是** `handoverFor`。理由就是本文件开头划的那条界限：
//    `task.handover` 是**事实**（该任务此刻有没有 PENDING 交接，**不按角色过滤**），
//    `handoverById` 才是**待办**（"待**我**确认的交接"）。本判据问的是"该谁动手"
//    ⇒ 只能走后者。⚠️ 图省事用 `handoverFor`，站点视图里**同站点的另一个账号**就会
//       看到"待我确认"——他既提不出也签入不了，是一条**假警示**（比没有警示更坏）。
//
// 角色过滤由构建侧完成、本函数不复判：SITE_ATC 的名单只含**本站 LANDING**、
// ROUTE_MONITOR 的只含**其航线 ROUTE**，且**提出方自己不在名单里**——于是
// "接收方是不是我"「这条相位该不该我管」「是不是我自己提的」三个问题一次解决，
// 且与本系统既有口径**同源**（不新增第二份会漂移的判据）。
//
// 返回真 bool（`!!` 不可省，理由同 isMine 上方注释）。
function awaitingMyCheckin(task, handoverById) {
    if (!task || !handoverById) return false
    return !!handoverById[task.task_id]
}

// 监控员**已否接管**本航班（设计文档 §0.2.2 裁定 1A）：该任务上存在 `phase_to='ROUTE'`
// 且 `status='ACCEPTED'` 的交接。后端在 `opsOverviewItem` 与 `opsRouteTaskItem` 上各下发
// 一个 `signed_in`（**布尔**，不是枚举），**全设计只此一处判定** ⇒ 前端不再自己从交接
// 记录里推导第二份判据（两份判据必然漂移，且漂移时没有任何东西会报错）。
//
// ‼️ 它在签入门控里的位置（2026-09-24 用户批准的差异 A 修正）：未签入时
// 「移交降落指挥」**不可点**。缺这道闸时责任链会断——飞机还没交给监控员，监控员已经
// 把降落指挥交给了降落机场；而此刻起飞机场侧看到的仍是"责任还在监控员手上"。前后端
// 两侧都要有这道闸（后端在 `Propose` 的 LANDING 分支，防止绕过界面直接 POST）。
//
// 返回真 bool（`!!` 不可省，理由同 isMine 上方注释；在这里的表现是
// **未签入的航班反而能点「移交降落指挥」**，即本函数要防的那个缺陷本身）。
function signedIn(task) { return !!(task && task.signed_in) }

// 监控员侧的「尚未接管」提示条。返回空串 = 不显示。
//
// 四个判据，少一条就会误报：
//   1. `isMonitor`——站点侧不需要：那边同一张卡上有【签出】按钮，"还没签出"本身有出口
//      （且站点侧的对应提示由 `checkoutNotice` 负责，两者是不同的状态）。
//   2. `status === "IN_FLIGHT"`——与「移交降落指挥」按钮的判据**对齐**：那几档本来就没有
//      操作，提示"暂不可操作"等于解释一件用户不会去尝试的事。
//   3. `!signedIn`——已签入还挂着提示，看起来像签入没生效。
//   4. `!awaitingMyCheckin`——**最容易漏的一条**，且与上一条方向相反：已有 PENDING 等我
//      签入时，警示条（"有人在等你动手"）与【签入】按钮已经在讲这件事，而本提示条讲的是
//      "还没有人交给你"。两者同时出现就是自相矛盾的画面，按"有没有在等我"二选一。
//      缺这条时，签出被驳回/撤回/超时之后（PENDING 消失、仍未签入）本提示条才会回来——
//      那正是它该出现的时刻。
function checkinNotice(task, isMonitor, handoverById) {
    if (!isMonitor) return ""
    if (!task || task.status !== "IN_FLIGHT") return ""
    if (signedIn(task)) return ""
    if (awaitingMyCheckin(task, handoverById)) return ""
    return qsTr("起飞机场尚未签出，暂不可操作")
}

// 后端的时间串一律是 **UTC 裸串**（`time.Now().UTC().Format("2006-01-02 15:04:05")` 与
// SQLite 的 `datetime('now')` 两种写法都不带 T、也不带时区标记）；ECMAScript 对无时区串按
// **本地**时区解析（中国 CST=UTC+8 → 整整偏 8 小时，会把"还有 30 秒"读成"已超时"）。
// 此处补 'T' 与 'Z' 使其按 UTC 解析，与后端 `datetime('now')` 的比较口径及遥测 timestamp
// （RFC3339 带 Z）一致；已是 ISO+时区则原样放行。
//
// ‼️ **单点函数**：`deadlineMs`（交接期限）与 `changedAtMs`（交接终结时刻）都经它。
// 两处各抄一遍补串逻辑，将来只改一处就会让其中一类时间**静默**偏 8 小时。
function utcNaiveMs(s) {
    if (!s) return NaN
    if (s.indexOf("T") < 0) s = s.replace(" ", "T")
    if (s.indexOf("Z") < 0 && !/[+-]\d{2}:\d{2}$/.test(s) && !/[+-]\d{4}$/.test(s)) s += "Z"
    return Date.parse(s)
}

function deadlineMs(handover) {
    return utcNaiveMs(handover ? handover.deadline_at : "")
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
// 交接「在监控员眼皮底下消失」的归因（2026-10-10，用户报「操作哪个都有二义性」）
//--------------------------------------------------------------------------

// 一条 PENDING 交接从 `/handovers/pending` 里**消失**的原因分档。
//
// 为什么需要它：`handoverDialog` 是**由那条交接打开**的，框里的按钮仍指着它。
// 站点方在监控员确认接管**之前**按了【取消】或【回航】，后端就把那条 PENDING 终结掉
// ⇒ 下一轮 pending 名单里没有它了，而框还开着 ⇒ 点【确认接管】打到一条已终结的交接上：
// 后端 404，而前端把 404 当**幂等成功**收口（`_acceptHandover` 的
// `status === 200 || status === 404`）⇒ **静默关框、一个字都不说**。
// 本函数供 OpsShell 在框"自己关掉"时给出**是哪一种**，好让通知框说清楚。
//
// ‼️ **优先级就是本函数的主要设计**（自上而下，先命中先返回）：
//
//   1. `TAKEN_ELSEWHERE`（`signedIn`）——**必须排第一**，这条最反直觉：
//      后端把过期 PENDING 置 TIMEOUT 的是 `scanTimeout` 的 **10 秒一轮**扫描
//      （`OPS_HANDOVER_TIMEOUT` 默认 30 秒），而在 deadline 已过、扫描还没轮到的
//      那几秒里 `Accept` **仍会成功**——它只查 `status='PENDING'`，**不查期限**。
//      ⇒ "已过期"与"已被人签入"可以**同时为真**，而那条交接是**被人接管**终结的。
//      把 `TIMEOUT` 排在前面就是**方向性**误报：监控员读到「已超时作废」（可以重新
//      签出），事实却是**已有同事接管**（不用管了）——两句话要他做的下一件事相反，
//      且这个误报恰好促使人**重复发起**一次已经完成的接管。
//
//   2. `RETURNING`（`task.disposition`）——回航是**人做过的动作**。它与 `TIMEOUT`
//      也可能同真（站点方在超时边缘按了回航），此时说"回航"信息量更大。
//      ⚠️ 本函数**不**读 `landing_accepted`：回航会顺手插一条 ACCEPTED 的 LANDING
//      交接（`closeReturnLoopTx` ③），那个字段在**每一次**回航里都为真 ⇒ 拿它当归因
//      判据会让它抢走别的档，且它并不比 `disposition` 更专一。
//      `disposition === 'RETURNING'` 才是回航的**唯一**标记：改降/迫降那条路的
//      `ReportDisposition` **不调用** `closeReturnLoopTx`，但它同样只看这一个字段
//      ⇒ 两侧口径同源（这也是"只有 `/return` 会走到 `closeReturnLoopTx`"的另一面）。
//
//   3. `TIMEOUT`——`isTimeout` 用的 `deadlineMs` 与弹框倒计时**同一个**解析口径
//      （`utcNaiveMs`）⇒ 框上写着"超时"的那一刻，这里给的就是 `TIMEOUT`，不会打架。
//
//   4. `CANCELLED`——兜底档：站点方按了【取消】（撤回签出），**以及**任何本函数认不出
//      的消失方式（含 `task` 为 null：那条任务已不在监控员列表里，`taskById` 回 null）。
//      ⚠️ 正因为它是兜底，它的话术取**最保守**的那句——只说"取消了"，不替后端断言
//      责任归属。将来后端加一种终结方式时界面给的是这句而不是空白：不精确，但**不会
//      把监控员引向一个错误的动作**。
//
// 参数：`handover` 是那条交接（`handover` 也可为 null，其唯一作用见 `handoverGoneText`）；
//       `task` 是它对应的**任务项**（调用点用 `taskById` 取，取不到传 null）；
//       `nowMs` 是**毫秒**（`opsShell._now` 那条 `property real`——‼️ 不能用 `int`，
//       理由见那里的注释：`Date.now()` 会被 ToInt32 取模，超时判定随之恒假）。
// 返回四个字符串常量之一，**恒为字符串**（调用点直接喂 `handoverGoneText`）。
function handoverGoneReason(handover, task, nowMs) {
    // ‼️ 走 `signedIn` 而**不是**裸读 `task.signed_in`：那是全设计**唯一**一处签入判据，
    //    这里再抄一份就是第二份会漂移的判据（而漂移时没有任何东西会报错）。
    if (signedIn(task)) return "TAKEN_ELSEWHERE"
    if (task && task.disposition === "RETURNING") return "RETURNING"
    if (isTimeout(handover, nowMs)) return "TIMEOUT"
    return "CANCELLED"
}

// 上面那四档给操作员看的一句话。`handover` 在这里只用来**点名是哪条任务**。
//
// ⚠️ 四句必须都存在且**互不相同**：这一整个改动的目的就是"别让监控员面对一个没有任何
//    解释就消失的框"——某一档返回空串，等于那一档又退回了静默。用例
//    `test_handoverGoneText_fourDistinctSentences` 钉着"非空 + 四句互异 + 点名任务"。
// ⚠️ `task_no` 缺失时**整段前缀都不要**，不要渲染「飞行任务 —：」这类占位：那是后端
//    join 不到时的异常态，凭空多一个破折号只会让人以为有个叫"—"的任务。
function handoverGoneText(reason, handover) {
    var taskNo = (handover && handover.task_no) ? handover.task_no : ""
    var prefix = taskNo ? qsTr("飞行任务 ") + taskNo + qsTr("：") : ""
    switch (reason) {
    case "TAKEN_ELSEWHERE":
        return prefix + qsTr("交接已由他人接管，这条无需再处理")
    case "RETURNING":
        return prefix + qsTr("站点方已选择回航，飞机正在返回起飞机场")
    case "TIMEOUT":
        return prefix + qsTr("交接已超时作废，站点方可重新签出")
    default:
        return prefix + qsTr("站点方已取消交接")
    }
}


//--------------------------------------------------------------------------
// 本地报文判定（仅显示/门控，不落库；2026-09-02 触发语义）
// 2026-09-27 起**全部改吃加密心跳 EXT 重建的合成遥测**（`CryptoHeartbeatExt.cc`），
// 不再读 `/ops/overview` 的 `latest`（那是数据库里的落库快照，滞后且与链路死活无关）。
// ‼️ 本组函数一律**只做纯计算**：所有需要建立绑定依赖的属性读取都在**调用点的 QML 表达式**
//    里完成，再作为实参传进来。`.pragma library` 的函数体内读属性不注册依赖（同
//    `resolvePosition` 第二实参的注释）——写进去界面**看不出异常**，只是按钮永远停在
//    第一帧的状态，而这类缺陷编译、lint、离屏快照全都发现不了。
//--------------------------------------------------------------------------

// 巡航：EXTENDED_SYS_STATE.vtol_state == MAV_VTOL_STATE_FW ⇒ `Vehicle::vtolInFwdFlight`。
// ⚠️ `Vehicle::_handleExtendedSysState` 里这段被 `if (vtol())` 包着 ⇒ **机型不是 VTOL 时
//    该属性恒 false**，巡航判定随之恒 false。这是 QGC 的既定行为，不是本函数能补救的。
function isCruising(vtolInFwdFlight) {
    return vtolInFwdFlight === true
}

// 已落地：EXTENDED_SYS_STATE.landed_state == ON_GROUND ⇒ `Vehicle::flying === false`。
// ⚠️ `flying` 初值就是 false ⇒ **从未收到过 ESS 时报"在地面"**。起飞前这个结论恰好正确；
//    但 37B 兼容帧不注入 ESS（见 `CryptoHeartbeatExt.cc` 的门控），若整条链路都是 37B，
//    飞机起飞后本判定**仍**报"在地面"。
function isLandedOnGround(flying) {
    return flying === false
}

// 在线：该机还挂在 `multiVehicleManager.vehicles` 里（`vehicle` 由调用点查好传入）。
// 判据不是"最近有过帧"而是**载具对象是否还在模型里**：`VehicleLinkManager` 每
// `_heartbeatMaxElpasedMSecs`(3.5s) 检查一次，超时即移除最后一条链路 → 触发 `allLinksRemoved`
// → `MultiVehicleManager::_deleteVehiclePhase2` 把载具摘掉。故「查得到」⟺「心跳在 3.5s 窗口内」。
// 这比原先那套 `latest.timestamp` 的 15s 窗口**更及时**，且判的是**链路死活**本身——
// 原判据读的是数据库落库时间，飞机掉线后库里那行还留着，会继续报"在线"直到窗口耗尽。
function hasLiveTelemetry(vehicle) {
    return !!vehicle
}


//--------------------------------------------------------------------------
// 流向派生（站点视图用；监控员视图不过滤）
//--------------------------------------------------------------------------

// 中段飞行卡片的**交接状态**（`opsOverviewItem.checkout_state`，取值表与该字段的后端注释同源）：
// "PENDING" / "REJECTED" / "CANCELLED" / "TIMEOUT" / "ACCEPTED"，无交接=空串。
// 一律经本函数取值：直接读字段的地方一多，将来字段改名就会**静默变 undefined**——
// 而 `undefined !== "ACCEPTED"` 恒真，界面会以"还没签出"的姿态渲染一个已经交出去的航班。
function checkoutState(task) { return task && task.checkout_state ? task.checkout_state : "" }

// 签出是否**正在等待接管**。中段飞行卡片的按钮组由它单点决定：
//   PENDING → 【取消】【回航】；其余（空 / REJECTED / CANCELLED / TIMEOUT）→ 【签出】【回航】。
// ‼️ 与 `pendingPhase(task,"ROUTE",…)` 不是同一件事：后者问"当前有没有一条 PENDING 交接"，
// 本函数问"最近一次签出处在什么状态"。被驳回/撤回/超时之后前者为假而后者有值——
// 而用户流程规格（2026-09-23）恰恰要求那三种终态**仍然显示【签出】【回航】**，
// 所以按钮组只认本函数。
function checkoutPending(task) { return checkoutState(task) === "PENDING" }

// 中段飞行卡片上的**签出提示条**（用户 2026-09-21：「如果航线监控员拒绝签入，那么在站点
// 操作员一侧必须有明确的提示功能，且可以再次签出」）。返回空串=不显示。
//   REJECTED → 红字 + 驳回理由（`checkout_reject_reason` 仅该状态非空）
//   TIMEOUT  → 红字说明未获接管（`scanTimeout` 置的终态，**没有**理由字段，别读成空理由）
//   其余     → 不显示：PENDING 已有「待接管确认 · 剩余秒数」徽标；CANCELLED 多半是自己刚点的
//              【取消】，再补一条只是噪音；ACCEPTED 说明责任已交出去，卡片本就该离开出站。
// ‼️ `default` 回空串而不是兜底成红字：后端将来加状态时，界面**不显示**，
//    而不是先自己喊一句没头没脑的错误（红=异常在本视图是**迫降/超时**那一族的语义）。
function checkoutNotice(task) {
    switch (checkoutState(task)) {
    case "REJECTED":
        return task.checkout_reject_reason
               ? qsTr("签出被航线监控员驳回：%1").arg(task.checkout_reject_reason)
               : qsTr("签出被航线监控员驳回，可重新签出或选择回航")
    case "TIMEOUT":
        return qsTr("签出超时：航线监控员未在规定时间内接管，可重新签出或选择回航")
    default:
        return ""
    }
}

//--------------------------------------------------------------------------
// LANDING（移交降落指挥）交接 —— 与上面 `checkoutState` 一族**同手法、另一相位**
//--------------------------------------------------------------------------
// `checkout_state` 只看 ROUTE（站点把飞机签出给监控员），本族只看 LANDING（监控员把飞机
// 移交给降落机场）。两个相位各有自己的提出方与接收方，判据、文案、时效都不同，别合并。

// 最近一条 LANDING 交接的状态（`opsOverviewItem` / `opsRouteTaskItem` 上的同名字段）。
// 取值 "PENDING" / "ACCEPTED" / "REJECTED" / "CANCELLED" / "TIMEOUT"，无交接 = 空串。
//
// ‼️ 与 `pendingPhase(task,"LANDING",…)` **不是同一件事**：后者问"现在有没有一条 PENDING"，
// 本函数问"上一条 LANDING 交接收在什么结果上"。超时作废之后前者为假、后者仍是 "TIMEOUT"——
// 而"作废之后"与"从未发起"在界面上必须能分开（2026-09-24 裁定 乙）。
function landingState(task) { return task && task.landing_state ? task.landing_state : "" }

// 交接终结时刻的 HH:MM（**本地**时钟，与 `remainingSec` 的倒计时同一时区）。
// 空/解析不出 ⇒ 空串（调用方据此降级成不带时刻的文案，而不是渲染一个 "NaN:NaN"）。
function changedAtMs(task) { return utcNaiveMs(task ? task.landing_changed_at : "") }

function changedAtClock(task) {
    var ms = changedAtMs(task)
    if (isNaN(ms)) return ""
    var d = new Date(ms)
    return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
}

// LANDING 交接**作废之后的告知条**。返回空串 = 不显示。
//
// `isReceiver` = 看这条的人是**接收方**（降落机场 SITE_ATC）还是**提出方**（航线监控员）：
// 「请重新发起」只有提出方做得到，接收方看到的是"待其重新发起"——两边说同一件事，
// 但**动作的主语不同**，写反了就是让一个点不动按钮的角色去点按钮。
// 由调用点按**视图**决定（站点视图 = 接收方）：LANDING 交接的接收方恒为降落机场，
// 而站点视图就是给 SITE_ATC 的，不必再等一个 `proposed_by` 字段下发。
//
//   TIMEOUT  → 红字 + 作废时刻。`scanTimeout` 置的终态，正是本项目"人员不知道"的病灶：
//              改前它一置 TIMEOUT 这条交接就从接口里消失，界面上与"从未发起"不可区分。
//   其余     → 不显示。PENDING 已有「待…确认 · 剩余秒数」徽标；ACCEPTED 是正常闭环；
//              CANCELLED 多半是自己刚点的【取消】。REJECTED 后端**已经能区分**，但本轮
//              不下发 `reject_reason`，没有理由的"被拒绝"提示说不清该改什么 ⇒ 一并留空
//              （要补时连同理由字段一起下发，参照 `checkout_reject_reason`）。
// ‼️ `default` 回空串而不是兜底成红字：后端将来加状态时界面**不显示**，
//    而不是先自己喊一句没头没脑的错误（红=异常在本视图是**迫降/超时**那一族的语义）。
function landingNotice(task, isReceiver) {
    if (landingState(task) !== "TIMEOUT") return ""
    var t = changedAtClock(task)
    if (isReceiver) {
        return t ? qsTr("航线监控员移交降落指挥已于 %1 超时作废，待其重新发起").arg(t)
                 : qsTr("航线监控员移交降落指挥已超时作废，待其重新发起")
    }
    return t ? qsTr("移交降落指挥已于 %1 超时作废，请重新发起").arg(t)
             : qsTr("移交降落指挥已超时作废，请重新发起")
}

//--------------------------------------------------------------------------
// 指令权（控制权）持有方 —— 起/终维的**唯一**判据（规范 §2.7.2 h）
//--------------------------------------------------------------------------
// 责任链四段（权威表述见 `gcs_server/handlers/handover_propose_requires_checkin_test.go` 的头注）
// 把「谁对一架飞机说话」切成**三个互斥区间**：
//
//   起飞站持有 ⟺ ROUTE 交接**尚未** ACCEPTED（监控员还没签入）
//   监控员持有 ⟺ ROUTE 已 ACCEPTED ∧ LANDING 尚未 ACCEPTED
//   降落站持有 ⟺ LANDING 已 ACCEPTED
//
// 三者是同一个真值轴上的三段，**不是**三个各自独立的开关；任取两个同时为真 = 两端同时上行
// = 两侧各取一个 counter = nonce 重复 ⇒ GCM keystream 泄漏（规范 §2.5）。故本节的函数必须
// 成对使用：站点侧 `siteHoldsControl`、监控员侧 `monitorHoldsControl`。
//
// ‼️ **站点字段必须与状态位合取**，任一半都不能单独当判据：
//   · 只用站点字段（`takeoff_site_id == 本端`）⇒ 终点站在起飞阶段就抢到指令权（它**同样**
//     拿得到密钥——可接引范围 = 出站 ∪ **进站**），与起飞站同时上行；同站起降时更是
//     起飞站在**监控员阶段**仍霸着不放。
//   · 只用状态位 ⇒ 平台级账号（无站点身份）或**别的**站点也会开闸——状态位描述的是
//     「**这条任务**的交接走到哪了」，**不含任何站点条件**。

/// 本端（站点侧，吃 `/api/ops/overview?view=site` 的行）此刻是不是这架飞机的指令权持有方。
/// 无站点身份（平台级账号 / `role_sites` 为空）⇒ 恒 false。
///
/// ⚠️ 起飞档读 `checkout_state` 而**不是**「有没有 ACCEPTED 的 ROUTE 交接」：`opsOverviewItem`
///    上**只有**前者——`signed_in` 只下发在 `opsRouteTaskItem` / `opsMonitorDevice` 上。
///    两者等价**依赖后端一道闸**：`OpsHandler.Propose` 的 ROUTE 分支在
///    `status IN ('PENDING','ACCEPTED')` 时回 409（拒绝重签）⇒ ACCEPTED 之后不可能再插一条
///    新的 ROUTE 交接 ⇒ `checkout_state`（取 `MAX(h.id)` 那条）恒停在 ACCEPTED、**不会回退**。
///    ⚠️ 那道闸若被放宽，本函数会**静默**把起飞站的指令权还回去——没有任何东西会报错。
function siteHoldsControl(task, mySiteId) {
    if (!task) return false
    var sid = Number(mySiteId)
    if (!(sid > 0)) return false
    if (Number(task.landing_site_id) === sid && landingAccepted(task)) return true
    if (Number(task.takeoff_site_id) === sid && checkoutState(task) !== "ACCEPTED") return true
    return false
}

/// 本端（监控员侧，吃 ③ 的 `devices[]` 行）此刻是不是这架飞机的指令权持有方。
///
/// ‼️ `!landingAccepted` 不可省：LANDING 被签入后降落站接手，本端必须**当场让出**。
/// ⚠️ 用**单调**的 `landing_accepted` 而**不是**任何形态的"最近一条交接的状态"：
///    `opsMonitorDevice`（= 本函数的入参形状）上**根本没有** `landing_state` 字段；而
///    `opsRouteTaskItem`（`tasks[]`）**有**它——于是"改成从 `tasks[]` 读 `landing_state`"
///    看起来更省事，**那是陷阱**：`landing_state` 取的是**最近一条** LANDING 交接的状态，
///    只要有人签入后再提一条，它就被打回 PENDING，基于它的判据随即翻假，两端又
///    同时持有（nonce 重复，规范 §2.5）。**`landing_accepted` 这个字段就是为这条判据
///    才加到 `opsMonitorDevice` 上的**（2026-10-06）；读 `tasks[]` 与 `devices[]` 是**两个数组**，
///    跨数组关联是明令禁止的（`ops.go` 的 `RouteTasks` 段有警告）。
///
///    ⚠️ **`landing_accepted` 不是无条件单调的**（2026-10-06 订正——此处原写「ACCEPTED 的行
///    永不被改写（超时扫描器只碰 PENDING）⇒ EXISTS 形态单调」，那句被当日的改降修复**证伪**）。
///    「重提」不翻假（`EXISTS` 对新增行不敏感）——这仍是它优于 `landing_state` 的**全部**理由；
///    但「**改降**」会翻假，且是**设计意图**：降落目的地真的变了，原降落站那条 ACCEPTED 被作废
///    （`recordDispositionTx` ③b），责任当场退回监控员。那一格安全是因为作废与
///    `landing_site_id` 的改写**同事务**，而 ③ 档是合取（`landing_site_id == 本端` ∧ 本字段）
///    ⇒ 原降落站靠前一个合取项当场出局。⇒ 靠的是**原子性 + 合取**，不是"这行不会被改"。
///
///    ⚠️ "签入后再提一条"那个入口已于 2026-10-06 被堵（`Propose` 两个相位的生效中交接判据
///    现在同形，都挡 `IN ('PENDING','ACCEPTED')`）。**本条仍不得改用 `landing_state`**：
///    单调性必须由本判据自己的数据源保证，**不能寄望于另一个组件的闸**——那道闸若回归，
///    这里翻假的表现是两端同时持有上行权而**链路上零报错**，没有任何一处会发现。
///    ⚠️ 反过来说，`landing_state` 在**前端按钮门控**里是**合适**的：那边问的是"**此刻**这一
///    相位还有没有活着的交接单"，正是"最近一条的状态"这个语义——见 `TaskListPanel.qml`
///    的【移交降落指挥】。**同一个字段在两条判据上一个该用一个不该用**，因为问的不是同一件事：
///    这里问"是否**曾经**签入过"（必须单调），那里问"**此刻**是否已交接"（取当前态才对）。
function monitorHoldsControl(device) {
    if (!device) return false
    return signedIn(device) && !landingAccepted(device)
}

// 出场=本站=起飞点且**责任尚未交出去**：SCHEDULED/READY/TAKEOFF，以及落库 IN_FLIGHT 之后
// 尚未被监控员接管的整段（§6.0-F：签出=责任里程碑；接管后退出出场）。
//
// ‼️ 判据是"**有没有 ACCEPTED 的 ROUTE 交接**"，不是"有没有 PENDING 的"——这两者互为**相反**判据
// （2026-09-23 实测：后端站点出站分支已改成 `NOT EXISTS(ACCEPTED)`，前端还停在 PENDING 上）。
// 后果不是"少显示一行"：签出被驳回/撤回/超时之后，PENDING 判据为假 ⇒ 卡片**整个从本站列表消失**
// ⇒ 用户流程规格里的【签出】【回航】两个按钮**没有落点**，界面表现为"点了拒绝，飞机就没人管了"。
//
// ‼️ `!landingAccepted` 不可省：回航，以及监控员正常移交降落指挥之后，**本站已签入(LANDING)**
// （`landing_accepted`），飞机已经进入本站的降落流程（`isInbound` 为真）⇒ 它不再是出站航班。
// 少了这一条，同一张卡会**同时**满足出站与进站，而 `siteTasks` 是 `if / else if`（出站优先）
// ⇒ 用户看到的是"回航之后卡片没去进站、按钮还是出站那一套"，真正该露出来的
// 【切换多旋翼降落】永远露不出来。
// ⚠️ 第三个参数 `handoverById` 自 2026-09-23 起**本函数不再使用**（判据改读任务上的
// `checkout_state`），保留在签名里只是让四个调用点保持同一形状；将来清理时可删，多传无副作用。
function isOutbound(task, mySiteId, handoverById) {
    if (!task) return false
    if (task.takeoff_site_id === undefined || task.takeoff_site_id === null) return false
    if (Number(task.takeoff_site_id) !== Number(mySiteId)) return false
    if (task.status === "SCHEDULED" || task.status === "READY" || task.status === "TAKEOFF") return true
    return task.status === "IN_FLIGHT"
           && checkoutState(task) !== "ACCEPTED"
           && !landingAccepted(task)
}

// 入场=本站=降落点。四项 **OR**（与 `gcs_server/handlers/ops.go` 的 `view=site` 进站半句
// **逐项对应**）：
//   ① 已发降落指令（`status === "LANDING"`）
//   ② 有 PENDING(LANDING) 交接——监控员已发起移交、等本站【签入】
//   ③ 已接引（`landing_accepted`）——用户 2026-10-02 裁定⑤「接引后置顶」那一段的入口
//   ④ **飞机至少 READY_TO_TAKEOFF**（`isAirborneReady`）——2026-10-02 新增，本次 bug 的正面判据
//
// ‼️ ④ 是 **OR 并上**，不是替换 ①②③。替换会收窄成"只看飞机状态"，而飞机接引后往往很快
//    落地停稳（`PARKED`，白名单外）⇒ **刚被置顶的卡片在停稳那一刻整条消失**（置顶"时好时坏"），
//    且 `status === "LANDING"` 那条也一起丢。
//    ⚠️ 这形状的破坏面**不在**正常路径上：后端 2026-10-02 实测过——把交接分支换成白名单，
//    六格白名单用例与三条交接用例里**只有「PREFLIGHT + 交接」那一格红**，因为它需要
//    "任务状态不在飞、但交接存在"这个结构锁才构造得出来。故两侧各留一格（本文件
//    `test_isInbound_keepsExistingBranches`，后端 `TestOverviewSiteInboundKeepsHandoverBranch`）。
//
// ‼️ 外层闸是**终态黑名单**（`isFinishedTaskStatus`），**不是** `IN_FLIGHT/LANDING` 白名单。
//    改前是白名单，与四项**取交集**——那道更窄的闸把里层整个架空了：任务 91103
//    （`status='READY'`、飞机 `READY_TO_TAKEOFF`、降落本站）根本走不到四项判定，卡片不出现，
//    而飞机遥测走另一条路照常显示。用户 2026-10-02 报的就是这个："应该显示 10000385 对应的任务"。
//    ⚠️ 里层的注释、单测、变异测试当时**全部照绿**——没有任何东西在测"外层放它过去了吗"。
//    这就是那条教训的形状：**两道闸串联时，只有更窄的那道有判据**。
//
// ⚠️ 这一层**必须留**（不能删了"交给四项自己判"）：四项里的 ② 只问"有没有 PENDING(LANDING)
//    交接"，**不看任务状态**。而交接行在任务飞完之后**不会消失**（`table_task_handover` 是
//    历史表）⇒ 少这一层，一条 `COMPLETED` 的历史任务会靠 ② 或 ③ 永久回流到降落场的列表里。
//    本文件与后端各有一格钉这个（`test_isInbound_dropsFinishedTask` /
//    `TestOverviewSiteDropsFinishedTask`）；夹具**只**让这一层挡得住，其余四项全真。
//
// ⚠️ 放宽这一层**同时放宽了分支②③的定义域**（不只是新增的 ④）。这是一处**已知副作用**：
//    任务还没起飞、却挂着一笔已 `CANCELLED`/`REJECTED` 的降落交接 ⇒ 现在也会出现在降落场
//    的列表里。它是否合意**尚未经用户裁定**；当前真库实测**多出 0 行**（全库 17 条 LANDING
//    交接**全部**属于任务 91103，而它本来就靠 ④ 进来）。方向上这符合 2026-09-25 那条既有
//    口径「看得见 ⟺ 移交过（不论结局）」，但那是针对**在飞**航班定的，别当成已授权。
//
// ⚠️ 放宽这一层还**作废了一个等价关系**：原先"不是 LANDING ⟺ 是 IN_FLIGHT"成立，靠的正是
//    这道白名单 ⇒ 见 `inboundActionable` 上方那段（那里有一个合取项被加回来）。
function isInbound(task, mySiteId, handoverById) {
    if (!task) return false
    if (task.landing_site_id === undefined || task.landing_site_id === null) return false
    if (Number(task.landing_site_id) !== Number(mySiteId)) return false
    if (isFinishedTaskStatus(task.status)) return false
    return task.status === "LANDING"
           || pendingPhase(task, "LANDING", handoverById)
           || landingAccepted(task)
           || isAirborneReady(task.uav_status)
}

// ---- 站点视图的四段（用户 2026-10-02 裁定）：排序与配色**同源** ----
// 取值：0=待我签入 1=已接引 2=出站 3=未接引进站 -1=两个勾选框都不收它。
// ‼️ **单点定义**：`siteTasks` 用它落桶（决定顺序），QML 用 `sectionIsInbound` 判配色。
//    两处各写一份判据的话，"卡片排在进站那一段、却涂着出站的颜色"在结构上就会出现，
//    而它**不会报任何错**——只是看起来像列表错位，没人能凭现象找到这里。
// 定义在前是因为 `var` 的**赋值**不 hoist：文件顶层若在赋值之前调用 `siteTasks`，
// 五个常量全是 `undefined`，`switch` 一个都匹配不上 ⇒ 整个列表静默变空。
var SEC_AWAITING = 0, SEC_ACCEPTED = 1, SEC_OUTBOUND = 2, SEC_INBOUND = 3, SEC_NONE = -1

// 站点视图的行集合：出站/进站两个勾选框分别过滤，然后**分四段**拼接。
//
// 段的顺序（用户 2026-10-02 裁定，两处原话）：
//   ① 待**我**签入（`awaitingMyCheckin`，2026-09-24 裁定 丙-2）：超时是硬性的（10 秒一轮的
//      `scanTimeout`，期限默认 5 分钟），而这条交接混在几十条航班里就是一行 11px 小字
//      ⇒ 排序是「让人来得及动手」的最后一道手段。
//   ② **已接引**（`isInbound && landingAccepted`）：「当该飞行任务被成功接引后，该任务卡片
//      将被置顶」+「如果当前站点有多个已经接引、但是未降落的任务，那么置顶项按照接引的
//      顺序显示」⇒ 段内按 `landing_accepted_at` 升序（`sortedByAcceptedAt`）。
//   ③ 出站（`isOutbound`）。
//   ④ **未接引的进站**（`isInbound && !landingAccepted`）：「到站任务卡片显示在出站任务卡片的后面」。
//
// ⚠️ ② 与③ 的先后是**用户明确指定**的：原话「原则上有签入的航班的话应该优先降落，暂缓起飞。
//    所以入站签入的靠前放」。同站起降的航班两条都真（`isOutbound` 与 `isInbound` 可同时成立），
//    被 ③ 收走——与改前一致（改前也是出站优先，`else if`）。
//
// ⚠️ 是**分桶再拼接**，不是排序函数：一条任务只落一段（`if / else if` 链），不会重复出现。
//    段内**保持输入顺序**；只有 ② 段额外排序——那是用户点名要的顺序。
// ⚠️ 「已接引但**未降落**」这个限定不必另判：后端 `view=site` 的外层是**终态黑名单**
//    （与 `isFinishedTaskStatus` 同源），飞完的任务根本不下发到客户端 ⇒ ② 段收到的 `status`
//    只可能是非终态，`COMPLETED` 之类顶不到最前。
//    ‼️ 这段注释改前写的是「**若将来**后端放宽了外层状态，② 段就会把已完成的任务也顶到最前，
//    而这里不会有任何报错」——2026-10-02 **那个放宽真的发生了**（白名单 → 终态黑名单），
//    而这里**果然**没有任何报错，是人工核对时想起来的。教训：注释里"将来会坏"的预言
//    **不会**变成判据；它只会变成一句被人读过就忘的话。要么当时就补一格，要么别写成预言。
//    残留面（当前真库 0 行，但结构上可达）：任务被人工复位回 `READY` 之类之后仍带着
//    `landing_accepted` ⇒ 一张"飞机还停在地上"的卡片被顶到最前。它的**动作**被
//    `inboundActionable` 挡着（卡上无按钮），但**排序**这一层没有判据。
function siteTasks(tasks, outbound, inbound, mySiteId, handoverById) {
    var awaiting = [], accepted = [], out = [], restIn = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        switch (siteSection(t, outbound, inbound, mySiteId, handoverById)) {
        case SEC_AWAITING: awaiting.push(t); break
        case SEC_ACCEPTED: accepted.push(t); break
        case SEC_OUTBOUND: out.push(t);        break
        case SEC_INBOUND:  restIn.push(t);     break
        }
    }
    return awaiting.concat(sortedByAcceptedAt(accepted), out, restIn)
}

function siteSection(task, outbound, inbound, mySiteId, handoverById) {
    var isOut = !!(outbound && isOutbound(task, mySiteId, handoverById))
    var isIn = !!(inbound && isInbound(task, mySiteId, handoverById))
    if (!isOut && !isIn) return SEC_NONE
    if (awaitingMyCheckin(task, handoverById)) return SEC_AWAITING
    if (isIn && landingAccepted(task)) return SEC_ACCEPTED
    if (isOut) return SEC_OUTBOUND
    return SEC_INBOUND
}

/// 该段是否用**进站配色**（青绿底 / 青绿边框，用户 2026-10-02 裁定⑥）。
/// ‼️ 段 0（待我签入）**两种都可能**：站点视图收到的是 LANDING 待办、监控员视图是 ROUTE 待办
///    ——同一条判据（`awaitingMyCheckin`）在两个视图里指向**不同相位** ⇒ 段号答不了这个问题，
///    追问一次 `isInbound` 当场判。写成"段 0 恒为进站色"就是断言 `/handovers/pending` 的
///    角色过滤永不改：那个断言在别处有它自己的位置，配色没有理由依赖它。
/// ⚠️ 段 2（出站）**即使 `isInbound` 也为真**（同站起降且未接引）仍取**出站色**：
///    配色必须与**排序位置**一致——否则用户看到的是"它排在出站那一段、却涂着进站的颜色"，
///    而用户裁定②的原话正是用"排在哪"来定义这两类的。
function sectionIsInbound(section, task, mySiteId, handoverById) {
    if (section === SEC_AWAITING) return isInbound(task, mySiteId, handoverById)
    return section === SEC_ACCEPTED || section === SEC_INBOUND
}

// 站点视图**地图 marker** 的两色（用户 2026-10-02 从三组候选里裁定这一组）。
// ⚠️ 这三组是按**意图**挑的、由用户拍板，**不是**实测排序：`#ffd400` / `#00e676` 取"亮而不荧光"
//    ——另两组候选 `#ffee00`/`#00ff66` 更接近纯色、`#ffb300`/`#00c853` 更暗更稳。哪个在真实
//    底图上更醒目，要在跑起来的界面上截图对比才知道，本注释不声称做过那件事。
// ⚠️ 与 `statusColor` 的"已落地绿" `#2ecc71` **刻意不同色**：那个绿说的是**状态**（已停稳），
//    这个绿说的是**归属**（朝本站来）。同色会让人把"停稳了"读成"归本站"。
var OUTBOUND_MARKER_COLOR = "#ffd400"
var INBOUND_MARKER_COLOR = "#00e676"

/// 站点视图地图 marker 的填色：**告警优先**，其余出站黄 / 进站绿。
///
/// ‼️ "告警优先"（用户 2026-10-02 裁定）不是修饰语：下面三档承载的是**告警与既成事实**，
///    被黄绿盖掉就等于把它们从地图上删掉——
///      · `isTimeout` ⇒ 交接**已超时**，接手窗口正在关闭；
///      · `ABORT`/`ABORTED`/`FAILED` ⇒ 任务中止 / 异常；
///      · `LANDING` 且**已落地**（本地报文）⇒ 已停稳。
///    ⚠️ 前两档**不是**"反正会落进 `SEC_NONE` 兜底"：`ABORT` 与 `FAILED` **不在**
///       `FINISHED_TASK_STATUSES`（那里只有 `COMPLETED`/`ABORTED`/`CANCELED`/`CANCELLED`）
///       ⇒ 它们**不是终态**，一条降落本站、飞机 `IN_FLIGHT` 的 `ABORT` 任务会被判成
///       **进站** ⇒ 少了这一档就会被涂成进站绿。只有 `ABORTED` 那一支能靠兜底变红。
///       （同族坑：`ABORT` vs `ABORTED` 是两个字面量，`task-status-enum-literal-split`。）
///    ⚠️ 判据是**逐档列举**，不是"`statusColor` 的返回值是不是某个色值"——后者会在有人调
///       `statusColor` 的色板时**静默失效**（改一个 hex，这里的分支跟着错，没有任何报错）。
///    ‼️ 但**取色**一律委派回 `statusColor`（不在这里写死 hex）：色板是单点的，改一次
///       卡片与地图一起变。写死的话，"卡片说中止是橙、地图还写着红"不会有任何报错。
///
/// 第三类 `SEC_NONE`（出站/进站两个勾选框都没勾到它；或"飞机已 PARKED 而任务仍 IN_FLIGHT"
/// 的人工收尾）**沿用现状的状态色**（用户 2026-10-02 裁定）：地图上"所有飞机都在"这个既有
/// 行为不变，只是被分进两类的那些换了颜色。
/// ⚠️ 因此本函数**不是** `statusColor` 的替代品，只是它的一个前置分支——`SEC_NONE` 那支必须
///    原样回落，别在那边自作主张涂灰（"取消勾选后飞机变灰"是一次没人要过的行为变更）。
///
/// ‼️ 段号与卡片配色（`TaskListPanel._inboundCard`、`OpsView._focusMapOnInbound`）用
///    **同一对函数、同一组实参**（`siteSection` + `sectionIsInbound`）：卡片被算进进站那一段
///    ⟺ 地图上这架取进站色。**说的只是"落哪一支"同源**——⚠️ 两处的**取色刻意不同**
///    （卡片边框 `#26a69a` 是既有的青绿，地图是本次裁定的 `#00e676`）：卡片是"这一行归哪类"，
///    地图要在 24px 的箭头上从深色底里跳出来，判据不同。判据多一份拷贝，下次改口径就多一处
///    静默漏掉的地方；**色板**则是各管各的，别为了"看起来统一"把它们并成一个常量。
///
/// ‼️ `nowMs` / `handoverById` / `outbound` / `inbound` / `mySiteId` 全部是**实参**：本文件是
///    `.pragma library`，函数体内读属性**不注册绑定依赖**（见文件头部）⇒ 写成内部读取的话，
///    用户勾选/取消勾选出站/进站时**地图颜色不跟着变**（列表变了、地图没变，且不报错），
///    交接超时红也永远不会出现。
function siteMarkerColor(task, outbound, inbound, mySiteId, handoverById, nowMs, landedOnGround) {
    // ① 告警 / 既成事实优先（逐档列举，理由见上；取色委派 `statusColor`）
    var s = task ? task.status : ""
    if (isTimeout(handoverFor(task, handoverById), nowMs)
        || s === "ABORT" || s === "ABORTED" || s === "FAILED"
        || (s === "LANDING" && landedOnGround === true)) {
        return statusColor(task, nowMs, handoverById, landedOnGround)
    }
    // ② 出站黄 / 进站绿
    var sec = siteSection(task, outbound, inbound, mySiteId, handoverById)
    if (sec === SEC_NONE) return statusColor(task, nowMs, handoverById, landedOnGround)
    return sectionIsInbound(sec, task, mySiteId, handoverById) ? INBOUND_MARKER_COLOR
                                                             : OUTBOUND_MARKER_COLOR
}

/// 进站卡片的**动作闸**：本站**已接管降落指挥**才可操作。
/// 判据＝「任务已进入 `LANDING`，**或**（任务在航线中 **且** 已接引）」。
///
/// ‼️ 那个 `status === "IN_FLIGHT"` 合取项是 2026-10-02 外层闸放宽当天**加回来**的。
///    它一度被删掉，理由写的是"冗余"：那时 `isInbound` 的外层是 `IN_FLIGHT`/`LANDING`
///    白名单 ⇒ 走到这里「不是 LANDING」⟺「是 IN_FLIGHT」，
///    `LANDING || landingAccepted` 与 `LANDING || (IN_FLIGHT && landingAccepted)` **逐值等价**。
///    ⚠️ 那个等价的**前提是外层闸**，不是本函数。外层一放宽成"非终态"，定义域里就多了
///    `SCHEDULED`/`READY`/`TAKEOFF` 三档，"不是 LANDING"不再蕴含"是 IN_FLIGHT"
///    ⇒ 一条**还没起飞**却带着 `landing_accepted` 的任务会让这里放行，而卡上的
///    【切换多旋翼降落】【指定机位】对一架停在地上的飞机没有意义。
///    ‼️ 教训不是"别删冗余代码"，而是：**"冗余"永远是相对某一道闸说的**——删的时候必须把
///    那道闸**写进注释**，否则将来放宽那道闸的人不会知道这里有个隐含前提。
///    （反方向的坑见 `isInbound` 里"两道闸串联时只有更窄的那道有判据"。）
///
/// ‼️ 用户 2026-10-02 裁定③「到站任务卡片……除了选中外，不能对其做任何操作」；第二轮裁定
///    「需要『航线监控员』执行签出后，隐藏的按钮才被点亮」。**当晚已就"点亮时刻"裁定完毕**
///    （原话：「就航线管理员而言，签出，就是提请把该无人机的控制权限交给站点操作员；
///    这个状态你来查；站点操作员的 qgc 收到该指令后（状态变化），自动点亮签入按钮」）。
///
///    ⇒ 那句"签出"＝**监控员发起 LANDING 移交那一刻**，状态落点是 `table_task_handover` 的
///      `phase_to='LANDING' AND status='PENDING'`，下发通道 `/api/handovers/pending`
///      （后端按 `hasRole(SITE_ATC)` 过滤 `t.landing_site_id IN (本站)`）。
///      **那一刻亮的是卡片上的【签入】按钮**，判据是 `awaitingMyCheckin`（`_awaitingMe`），
///      与 `handoverById` 同源 ⇒ 2 秒轮询内**自动**出现，无须任何手动刷新，还会自动弹接管框
///      （`OpsShell._notifyNewPending`）。已在云端生产入口实测（阳性/阴性对照见交付报告）。
///      ‼️ 但那个按钮**不归本函数管**——本函数的两个消费方是【切换多旋翼降落】与【指定机位】。
///
///    ⚠️ 那两格**不能**跟着提到签出那一刻：**后端对两者都硬校验**「存在 `phase_to='LANDING'
///      AND status='ACCEPTED'` 的交接」（同一条子查询，两处各一份）——
///      `AssignSlot` 的 `accepted == 0` ⇒ 409「任务须已签入(LANDING)或处于降落阶段，才能指定机位」；
///      `Land` 的 `accepted == 0` ⇒ 409「本站尚未签入(LANDING)，无法发出降落指令」。
///      提前点亮＝"按钮能点、点下去必然失败"，正是 CLAUDE.md 说的那种坏状态。
///    ⇒ 本站卡片上"点亮"分两格，**各自与后端闸对齐**：
///      监控员签出(PENDING) → 【签入】；本站签入(ACCEPTED) → 【切换多旋翼降落】【指定机位】。
///
/// ⚠️ 本函数**不**枚举"卡片上有哪些按钮"：那是各按钮自己的判据（还叠了 `_awaitingMe` 等）。
///    它是**上限**——为假时进站动作一个都不该亮；为真也只是"允许"。
/// ⚠️ 本次新增的那一类卡片（到站本站、飞机在飞、零交接，即 `isInbound` 第四项放行的那类）
///    在本函数上**恒为假** ⇒ 它们身上没有任何进站动作。这正是需求③要的，而且它**不依赖**
///    "两个按钮恰好各自叠了别的条件"这个巧合——那是会被下一次改动静默破坏的东西。
function inboundActionable(task, mySiteId, handoverById) {
    if (!isInbound(task, mySiteId, handoverById)) return false
    return task.status === "LANDING"
           || (task.status === "IN_FLIGHT" && landingAccepted(task))
}

// 「已接引」段的排序键：**接引时刻**升序（先接引的排前面）——用户 2026-10-02裁定⑤
// 「如果当前站点有多个已经接引、但是未降落的任务，那么置顶项按照接引的顺序显示」。
//
// ‼️ 缺时刻时给一个**比任何真实时刻都大**的哨兵 `"9999"`，不是空串也不是 undefined：
//    `""` 在字符串比较里比任何 `"2026-…"` 都**小** ⇒ 缺时刻的那条会排到最前、顶掉真正
//    有时刻的（顺序错，且**没有任何报错**）。
//    这形状后端标注为不可达（`Accept` 把状态与时刻写在同一句 UPDATE 里），但"缺信息的
//    不能顶掉有信息的"这条不依赖可达性——真出现时宁可它排在后面。
function acceptedAtKey(task) {
    var s = task ? task.landing_accepted_at : undefined
    return (typeof s === "string" && s) ? s : "9999"
}

// 装饰-排序-还原：用**原下标**做 tie-break，这样"时刻相同 ⇒ 保持输入顺序"是自己保证的，
// 不依赖 JS 引擎 `sort` 是否稳定（Qt 的 V4 引擎在这一点上不做承诺，而"顺序看起来偶尔会变"
// 是那种没人会报、也没法复现的故障）。
function sortedByAcceptedAt(list) {
    var d = []
    for (var i = 0; i < list.length; i++) d.push({ t: list[i], k: acceptedAtKey(list[i]), i: i })
    d.sort(function (x, y) { return x.k < y.k ? -1 : (x.k > y.k ? 1 : x.i - y.i) })
    var r = []
    for (var j = 0; j < d.length; j++) r.push(d[j].t)
    return r
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

// 异常种类 → 中文短标签，用于置顶徽标（§4.1 中段第 1 节）。
// ‼️ 与 `abnormalColor` 是**同组入参**（都吃 `abnormalKind()` 的返回值）：一处加枚举，
//    另一处**必须同加**，否则会出现"有底色没字"或"有字没底色"的半截徽标。
// ‼️ 返回的是**中文**不是枚举值——界面不出现裸枚举（`ui-no-raw-enum-labels`）。
// ⚠️ 未知 kind 返回**空串**，调用方据此**整个徽标不画**，而不是画一个空方框。
//    `abnormalKind` 已把未知 type 收成空串，正常路径到不了这里；留着 default 是
//    **断路器**：万一枚举扩容而这里忘补，"没有徽标"（看得见）好过"编一个中文"
//    （编错了没人会发现）。
function abnormalLabel(kind) {
    switch (kind) {
    case "DIVERT":          return "备降"
    case "RETURN":          return "回航"
    case "FORCED_LANDING":  return "迫降"
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

// 轨迹线配色，**按载具序号轮换**（图上是"每架已建链飞机各一条线"）。
// ‼️ 为什么不全部用同一个颜色（`FlyViewMap.qml:243` 就是一条写死的 `"red"`）：
//    FlyView 只画**当前选中**那一架，本视图按 model 同时画**多架**——同色时两条线在图上
//    无从区分，而"哪架飞的是哪条"正是本图要回答的问题。`index` 由 `MapItemView` 注入。
// ‼️ 取值首先避开**航线色**（三条都是青/蓝系：`#00bfff` / `#9fc4e8` / `#00e5ff`）：
//    轨迹线与航线线是**同一图层上叠加的两组线**，撞色的代价是"分不清哪条是航线"，
//    比与异常 marker 撞色大得多——异常 marker 是 24px 且带中文标签的点，形状维度已区分开。
//    ⇒ 用红/绿/紫/黄/橙，整族远离青蓝。
// ⚠️ 与 L1/L2 色值同一批教训：这些取值只在**深色卫星底图**上验过；亮底图上 `#ffea00`
//    偏弱。最终以用户在 GL 后端目视为准（VNC 下 `MapPolyline.line.color` 的 R/B 会互换，
//    在那里截图判色会得出完全错误的结论）。
function trajectoryColor(index) {
    var palette = ["#ff1744", "#00e676", "#d500f9", "#ffea00", "#ff6d00"]
    var i = Number(index)
    if (!(i >= 0)) i = 0                 // 非数字/负数一律回第 0 个，别让 NaN 传进下标
    // ‼️ `Math.floor` 不是装饰：下标必须**整数**，否则 `palette[2.9]` 是 `undefined`
    //    ⇒ `line.color: undefined`（QML 不报错，线会变成一个说不清的颜色）。
    //    调用点传的是委托的 `index`（恒为整数），这里防的是今后换调用点。
    return palette[Math.floor(i) % palette.length]
}

// `device.task_id` → ③ 的 `tasks[]` 里对应的那条任务。找不到回 `null`。
// ‼️ 两侧来自**同一条 WHERE 的两个投影**（后端 `RouteTasks`："一处判据、两处投影"），
//    所以这个关联是可靠的；返回 null 只可能是数据缺失，不是正常态。
// ⚠️ 按**数值**比较：两端一个是 JSON 数字、一个可能是字符串。
// ⚠️ `task_id` 为 0（未指派）、null、undefined 一律按找不到处理——用 `!taskId` 一个判据
//    覆盖三种，**不要**写成 `taskId === null`，那会让 0 走进循环去跟别的 0 误配。
function taskById(tasks, taskId) {
    if (!tasks || !taskId) return null
    for (var i = 0; i < tasks.length; i++) {
        if (Number(tasks[i].task_id) === Number(taskId)) return tasks[i]
    }
    return null
}

// 地图 L3 marker 的着色（用户 2026-09-23 定的口径）。
// 优先级：异常 > **航班**状态色 > 兜底回飞机状态色。
//
// ‼️ 第 2 条从「飞机状态」改成「航班状态」是**用户明确要求的**（"颜色可以参照航班列表中
//    图标的颜色"），它推翻了 `deviceColor` 上方那段注释记录的**原**取舍（§5.3 第 3 条
//    主张"三个判据的主语都是飞机"）。改的理由是**可见性**：中段列表行首那个状态点用的
//    就是 `statusColor(task, …)`，地图与它同色之后，"列表里的那条航班"与"地图上的那架
//    飞机"才是一眼能对上的同一个东西——否则同一件事在两处显示两种颜色，监控员无从对照。
// ‼️ `deviceColor` 里"不能拿飞机状态喂 `statusColor`"那条告诫**依然成立**，本函数没有
//    违反它：喂进去的是经 `taskById` 关联拿到的**真 task 对象**，不是 device。两者形状
//    不同，混喂才会让 `RETURNING`/`EMERGENCY_LANDING` 掉进 default 变蓝。
//
// ⚠️ `task` 为 null（关联失败 / `task_id` 为 0）时兜底回 `deviceColor(device)`，
//    **不要**写成 `statusColor(null, …)`：那个回中性蓝 `#3b9cff`，会让"关联失败"在界面上
//    看起来与"一切正常"一模一样。
// `landedOnGround` 同样由调用点在实参位置读好（`.pragma library` 不注册依赖），
// 与 `statusColor` 的第 4 参是同一条链——漏传的后果是"已落地"的航班在地图上不变绿。
function markerColor(device, task, nowMs, handoverById, landedOnGround) {
    var c = abnormalColor(abnormalKind(device))
    if (c !== "") return c
    if (task) return statusColor(task, nowMs, handoverById, landedOnGround)
    return deviceColor(device)
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

// 飞机位置（§5.2 的"位置主源"）。**只有报文一个源**；取不到就返回 **null**（调用方不画 marker）。
// ‼️ 2026-10-03 裁定（用户原话：「qgc 上包括箭头、状态栏数据、位置、方向轨迹都是从 mavlink
//    报文中来，不是取数据库」「web 链路走固定数据，mavlink 走动态数据」
//    「数据库也来源于 mavlink 报文，如果你从报文读不到，意味着数据库中也没有」）：
//    **原先那条 `device.latest` 的 REST 兜底已删除**。理由：库里的遥测本身就是报文的派生副本
//    （`data_writer` 落 `table_telemetry`）⇒ **报文读不到，库里也不会有新值**，兜底最多拿到
//    一份冻结的旧快照，**没有任何信息增益**，却让一架「本地从未接引」的飞机在地图上被画成
//    一枚位置陈旧、机头静默朝北的**假 marker**（2026-10-03 实测 `10000385`：库快照陈旧 **9 小时**，
//    在界面上与在飞那架无从区分——用户报障「箭头方向始终指向北」）。
//    ⇒ **不要**把 `device.latest` 加回来；也**不要**再加任何"从库里取动态值"的兜底。
// ‼️ 第二个实参 `vehicleCoord` **不是冗余**：`.pragma library` 里函数体读属性**不注册绑定依赖**
//    （见本文件头部）。把坐标作为**实参**传进来，绑定依赖才落在调用点的表达式上——
//    这样 MAVLink 坐标一变，marker 的 `coordinate` 绑定才会重估。写成 `vehicle.coordinate`
//    在函数体内，界面**看不出异常**，只是位置永远停在第一帧。
function resolvePosition(vehicle, vehicleCoord) {
    if (vehicle && vehicleCoord && vehicleCoord.isValid) {
        return { lat: vehicleCoord.latitude, lon: vehicleCoord.longitude }
    }
    return null
}
// 注：原先返回的 `source`（"mavlink" / "rest"）随兜底一并删除——单源之下它恒为一个值，
//     留着只会让人以为"还有第二种位置来源"。设计文档 §5.2 那张四行表随之只剩"有报文就画、
//     没有就不画"两档（第 2/3 行的 REST 回落已作废）。

// 按 `deviceID` 找真实 Vehicle。**第一个实参是"任何带 `device_id` 的行"**：站点/监控员的
// 设备行（`device`）与任务行（`task`）用的是同一个字段、同一个查法，故两处共用本函数
// （`OpsView.qml` 原来的 `_vehicleForTask()` 是它的逐字复制，已并入）。
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

// 中段（航班列表）的**两节切分**（§4.1 中段）= 第 1 节 ∪ 第 2 节（拍平版见 `middleSectionTasks`）：
//   第 1 节 **异常航班 ∪ 待我签入**，**与是否选中航线无关、置顶常驻**。
//          前半是裁定 ⑥ 的硬约束——用户指出过「异常飞机应该常驻在屏幕上，而我们又说选择航线，
//          则在列表中显示该航班的航班，这个冲突了」。
//          后半是 2026-09-24 裁定 丙-2 加的（用户：「人员不知道/或者没有注意到才是问题」）
//          ——超时作废前，接管提示必须**一直在最上面**，理由见 `awaitingMyCheckin`。
//   第 2 节 **在航航班**，随选中状态换口径（用户 2026-09-23 定）：
//          **选中航线 ⇒ 只列该航线的**；**一条都没选中 ⇒ 列全部在航航班**。
//          ‼️ "全部在航"不需要在这里再筛一次状态：③ 端点自己的 WHERE 就是
//             `u.status IN ('READY_TO_TAKEOFF','TAKEOFF','IN_FLIGHT','LANDING','RETURNING',
//              'EMERGENCY_LANDING') OR 有未闭环异常` ⇒ **`tasks` 整个集合本来就是"在航"**，
//             直接全收即对。在这里另写一遍状态白名单＝多一份会与后端漂移的判据。
//          ⚠️ 在这之前，未选中时第 2 节是**整体为空**的（只显示异常）。那是旧口径，已废。
// ‼️ 两节可能包含**同一个航班**（选中了一条有异常航班的航线）⇒ **必须按 `task_id` 去重**，
//    去重后**仍留在第 1 节**（第 1 节的位置更高）。去重漏了的表现是同一条航班在列表里出现两次，
//    看起来像"重复的数据"，不报错。
//
// ‼️ **两节分开返回**（`{first, second}`）而不是拍平：2026-09-29 用户报障「点航线，航班列表
//    不变」——第 1 节**本就**不受航线选中过滤（上面那条硬约束），但拍平渲染让用户看不出
//    「这几条为什么留在列表里」⇒ 读起来就是"点了航线没反应"。裁定：**补分段标题、过滤不动**。
//    分段是**渲染层**的事，判据仍只有这一份（`middleSectionTasks` 也走这里）。
function middleSectionSplit(tasks, selectedRouteId, handoverById) {
    // ‼️ 2026-09-24（裁定 丙-2）：第 1 节除异常之外**再收"待我签入"**（ROUTE 交接等着
    //    监控员接管），理由与 `siteTasks` 同上——超时到期这条交接就作废了。
    // ⚠️ 判据写在**调用 `isAbnormal` 的这里**、**不写进 `isAbnormal` 本身**：那个函数
    //    被 `abnormalKind`/`abnormalColor` 与**地图 marker 着色**共用（见其上方注释），
    //    往里加一条"待签入也算异常"会让地图上的飞机跟着变色。
    // ⚠️ 第 1 节**不受 `selectedRouteId` 过滤**（原有口径，异常航班常驻置顶）；"待签入"
    //    沿用同一口径。此处不会因此多收：`handoverById` 对监控员本就**只含其航线**。
    var seen = {}, first = [], second = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        if (!isAbnormal(t) && !awaitingMyCheckin(t, handoverById)) continue
        if (seen[t.task_id]) continue
        seen[t.task_id] = true
        first.push(t)
    }
    // 未选中（null / undefined）与"选中了某条"共用下面这一轮循环，只差**过不过滤 route_id**：
    // 早返回式的写法（`if (未选中) return second`）会让"全收"与"按航线收"变成两段各自演化的代码。
    var filterByRoute = (selectedRouteId !== null && selectedRouteId !== undefined)
    for (var j = 0; j < tasks.length; j++) {
        var u = tasks[j]
        if (filterByRoute && Number(u.route_id) !== Number(selectedRouteId)) continue
        if (seen[u.task_id]) continue          // 已在异常节里：保持它在前面
        seen[u.task_id] = true
        second.push(u)
    }
    return { first: first, second: second }
}

// 中段的**行集合**（拍平版）= `middleSectionSplit` 的两节按序拼接。
// ‼️ 保留这个函数、而不是让调用方自己拼：它是**拼接顺序的单点**——顺序写反
//    （`second.concat(first)`）的症状是**异常航班沉到底部**，而"异常常驻置顶"正是用户
//    裁定 ⑥ 的核心，沉底看起来只是"排序怪怪的"。
// ⚠️ 生产调用点实测**只有 `RomView._panelTasks` 一处**。本条注释 2026-09-29 曾写成
//    「调用点有多个（站点视图 / 监控员视图 / 历史）」——逐处 `rg` 核实后**无一存在**，
//    那是凭印象写的。同日那个供分段标题取 `first.length` 的 `_panelSplit` 也已随段头
//    删除（用户裁定「两行段头全删」）⇒ `middleSectionSplit` 现在**只**被本函数调用。
//    ⚠️ 但**不要**因此把 `middleSectionSplit` 并回本函数：两节的分法（第 1 节不受航线
//      过滤）是裁定 ⑥ 的落点，留着它才有一条能单独测的边界。
//    动这个函数之前先重新数一遍调用点，别照抄上面的结论。
function middleSectionTasks(tasks, selectedRouteId, handoverById) {
    var s = middleSectionSplit(tasks, selectedRouteId, handoverById)
    return s.first.concat(s.second)
}

// 航线列表面板的显示顺序：**有告警的航线置顶**，组内保持原自然顺序（稳定分区）。
// 用户 2026-09-29 要求：「如果有航班告警，则航线列表、航班列表中告警对应的航线、
// 航班置顶」。航班侧由 `middleSectionSplit` 的第 1 节承担（现状即符合，本函数不碰）。
// ‼️ 判据 = **真值即告警**（`!!r.has_abnormal`），该字段由 `OpsShell._routeRows` 用
//    `g.some(isAbnormal)` 算出，是真 bool。ⓐ 写成 `r.has_abnormal !== false`
//    （"不是明确的 false 就算告警"）的后果不是"多置顶几条"，而是**缺键的行全被判成
//    告警** ⇒ 整张表都在置顶组里、顺序反而不变，症状只是"排序没生效"，不报错。
//    ⓑ 反过来写成 `=== true` 则会把真值 1 / 非空串静默漏掉（不置顶），同样不报错。
// ‼️ 稳定分区而非重新排序：`_routeOrder` 是后端给的**名册顺序**，客户熟悉它；
//    组内一旦按告警数 / route_id 之类重排，用户看到的顺序会随告警多少而整体错位。
// ⚠️ 生产调用点**只有 `OpsShell._routeRows` 一处**
//    （`return OpsCommon.routesAbnormalFirst(OpsCommon.routesWithTasks(out))` —— 2026-10-01 逐字核对）。
//    动它之前先现场复跑 `rg -n 'routesAbnormalFirst' src/ test/` 重新数一遍。
// ⚠️ 纯函数、不就地排序：`_routeRows` 是 `readonly property var` 绑定，入参那个数组
//    可能正被别的绑定持有；`sort()` 原地改会让无关视图跟着变，且**没有报错**。
function routesAbnormalFirst(routes) {
    if (!routes || !routes.length) return []
    var top = [], rest = []
    for (var i = 0; i < routes.length; i++) {
        var r = routes[i]
        if (r && r.has_abnormal) top.push(r)
        else rest.push(r)
    }
    return top.concat(rest)
}

// 规则 1（用户 2026-09-29 原话）：「航线列表中列出当前有执行任务的航线」
// ⇒ 只保留**当前有航班**的航线行，没有航班的整行不进右栏列表。
//
// 此前 `_routeRows` 对名册里每条航线都 push 一行，哪怕它一条航班都没有——
// 界面上就是一行 `active_count: 0` 的空行。名册（`table_route_monitor`）是**长期绑定**，
// 而"当前有没有航班"是 2s 一变的状态，两者本来就不同寿命。
//
// ‼️ 判据 `Array.isArray(t) && t.length > 0`，**不是** `t.length > 0`、更不是 `t != null`：
//   · `t != null` ⇒ `[]` 也算有航班 ⇒ 本规则整个失效；
//   · `t.length > 0` ⇒ 数据源从数组变成别的真值（如字符串）时，`.length` 恰好也是个正数
//     ⇒ 多出一行渲染不出卡片的航线，且不报错；
//   · `{}` 的 `.length` 是 `undefined`，`undefined > 0` 为 false ⇒ 两条写法都拦住它，
//     所以**光靠 `{}` 试不出这个洞**（本函数单测里 `"ab"` 那一格才是抓它的）。
//
// ⚠️ 只管收窄，**不管排序**——顺序是 `routesAbnormalFirst` 的事，两个函数串起来用：
//   `routesAbnormalFirst(routesWithTasks(rows))`。先收窄再置顶，与先置顶再收窄等价
//   （收窄是纯筛选、不改相对顺序），但把收窄放里层少一次遍历。
function routesWithTasks(routes) {
    if (!routes || !routes.length) return []
    var out = []
    for (var i = 0; i < routes.length; i++) {
        var r = routes[i]
        if (!r) continue
        if (!Array.isArray(r.tasks) || r.tasks.length === 0) continue
        out.push(r)
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

// 从 ③ 的 `devices[]` 提取**监控员侧**的**指令权**名单（起/终维，§2.7.2 h）。
//
// ‼️ 与 `monitorDeviceIds` **不是同一份清单，不要合并**——两者管的是两件事：
//   · `monitorDeviceIds` = 80005 登记集合（本端名册上的**全部**飞机；收了帧才不掉线），
//     它的失败形状是"飞机 60s TTL 后集体掉线"（§3.5.4）；
//   · 本函数 = 建链权（**当前**签入的那一架），它的失败形状是"两端同时说话 ⇒ nonce 重复"。
//   合并的后果不是"多推了几个 id"，而是**用可接引范围去顶替责任方判据**——两回事。
//
// ⚠️ 与站点侧同口径：**整份替换**、每轮重推（`checkout_state` / `landing_accepted` 都能在
//    行集完全不变时翻转），且**无监控员身份时不推**而不是推空集（「没推过」与「推了空集」
//    在建链答案上相反，见 `OpsShell._fetchOverview` 里同一条注释）。
// ⚠️ 重复项过滤与 `<= 0` 过滤照抄 `monitorDeviceIds`：后端已按 `device_id` 去重，此处是第二道。
function initiatorDeviceIds(devices) {
    var seen = {}
    var out = []
    if (!devices) return out
    for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (!d) continue
        var id = Number(d.device_id)
        if (!(id > 0)) continue
        if (seen[id]) continue
        if (!monitorHoldsControl(d)) continue
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

//--------------------------------------------------------------------------
// 最小包围圆（Welzl）—— **通用几何工具，范围圈已不用它**

/// ⚠️ 现状（2026-09-23）：地图上的本站范围圈已改用 `siteCenteredCircle`（圆心锁定站点
///    坐标）。本组函数因此**没有生产调用点** —— 保留是因为它被测试完整覆盖，且
///    `tst_OpsCommon.qml` 拿它当「偏心簇」用例的**对照**（证明两者确实不同）。
///    ⇒ **别**以为两个都在用：范围圈只有 `siteCenteredCircle` 一个实现。

// 一度纬度对应的米数。**与 `tst_OpsCommon.qml` 的 `_distM` 取同一个地球半径**
// （6371000 m）——测试用 haversine 独立复算距离，两者若各取各的半径，几百米量级上
// 就会差近 1 m，把「覆盖性」断言的容差吃到贴边。同 R 之后，两套公式的残差只剩
// 「经度用常数 cos 还是逐点 cos」，实测 < 0.1 m。
function _mecMetersPerDeg() { return 6371000 * Math.PI / 180 }

// 「在圆内」的容差：**相对 + 绝对**。定得过严只会让 Welzl 多做一次重算（结果不变，
// 只是慢），定得过松则会把真正在圆外的点漏掉 —— 所以宁可偏松一点点。
function _mecEps(c) { return c.r * 1e-9 + 1e-9 }

function _mecContains(c, p) {
    var dx = p.x - c.x, dy = p.y - c.y, rr = c.r + _mecEps(c)
    return dx * dx + dy * dy <= rr * rr
}

// 以两点为直径的圆。
function _mecDiameter(a, b) {
    var dx = a.x - b.x, dy = a.y - b.y
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, r: Math.sqrt(dx * dx + dy * dy) / 2 }
}

// 三点外接圆；共线返回 null。
// ‼️ 半径是**圆心到三个定义点的最大距离**，**不是** `√(ux²+uy²)`。`(ux, uy)` 是圆心
//    相对「三点包围盒中心 (ox, oy)」的偏移，而 (ox, oy) 一般**不是圆心** —— 拿它当
//    半径会算出偏小的圆（锐角构型实测差 4.3 倍），且小圆不含定义点，静默出错。
function _mecCircumcircle(a, b, c) {
    var ox = (Math.min(a.x, b.x, c.x) + Math.max(a.x, b.x, c.x)) / 2
    var oy = (Math.min(a.y, b.y, c.y) + Math.max(a.y, b.y, c.y)) / 2
    var ax = a.x - ox, ay = a.y - oy
    var bx = b.x - ox, by = b.y - oy
    var cx = c.x - ox, cy = c.y - oy
    var d = (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by)) * 2
    if (d === 0) return null
    var ux = ((ax * ax + ay * ay) * (by - cy) +
              (bx * bx + by * by) * (cy - ay) +
              (cx * cx + cy * cy) * (ay - by)) / d
    var uy = ((ax * ax + ay * ay) * (cx - bx) +
              (bx * bx + by * by) * (ax - cx) +
              (cx * cx + cy * cy) * (bx - ax)) / d
    var px = ox + ux, py = oy + uy
    var da = Math.sqrt((px - a.x) * (px - a.x) + (py - a.y) * (py - a.y))
    var db = Math.sqrt((px - b.x) * (px - b.x) + (py - b.y) * (py - b.y))
    var dc = Math.sqrt((px - c.x) * (px - c.x) + (py - c.y) * (py - c.y))
    return { x: px, y: py, r: Math.max(da, Math.max(db, dc)) }
}

// 已知 `p`、`q` 在圆上时，含 `pts` 的最小圆（Welzl 的内层）。
// ‼️ 候选圆按 `p→q` 的**左右两侧**分开维护，各自取「最外侧」的那个，最后取两者中
//    **半径小的**。不能合成一个：一个候选圆只保证覆盖它那一侧的点，跨侧比较半径会
//    选出不覆盖另一侧点的小圆。
function _mecTwoPoints(pts, p, q) {
    var circ = _mecDiameter(p, q)
    var left = null, right = null
    var pqx = q.x - p.x, pqy = q.y - p.y
    for (var i = 0; i < pts.length; i++) {
        var r = pts[i]
        if (_mecContains(circ, r)) continue
        var cross = pqx * (r.y - p.y) - pqy * (r.x - p.x)
        if (cross === 0) continue                    // 落在 p→q 直线上，对圆没有约束
        var c = _mecCircumcircle(p, q, r)
        if (c === null) continue
        var cc = pqx * (c.y - p.y) - pqy * (c.x - p.x)
        if (cross > 0) {
            if (left === null || cc > pqx * (left.y - p.y) - pqy * (left.x - p.x)) left = c
        } else {
            if (right === null || cc < pqx * (right.y - p.y) - pqy * (right.x - p.x)) right = c
        }
    }
    if (left === null) return right === null ? circ : right
    if (right === null) return left
    return left.r <= right.r ? left : right
}

// 已知 `p` 在圆上时，含 `pts` 的最小圆（Welzl 的内层）。
// ‼️ `c.r === 0` 判的是「圆还在退化态」，此时不能走两点分支（`_mecTwoPoints` 要求
//    两个**不同的**边界点）。p 与 q 重合时直径圆半径也是 0，会再次进这个分支 —— 结果
//    仍然正确（重合点的最小包围圆本就由后续点决定）。
function _mecOnePoint(pts, p) {
    var c = { x: p.x, y: p.y, r: 0 }
    for (var i = 0; i < pts.length; i++) {
        var q = pts[i]
        if (_mecContains(c, q)) continue
        c = (c.r === 0) ? _mecDiameter(p, q) : _mecTwoPoints(pts.slice(0, i + 1), p, q)
    }
    return c
}

// Welzl 最小包围圆（迭代形式）。
// ⚠️ **不打乱点序**：随机化只影响**期望**复杂度，不影响结果。不打乱换来确定性
//    （同输入必同输出，测试才可复现），代价是最坏 O(n³) —— 机位数量级下可忽略。
function _mecSolve(pts) {
    var c = null
    for (var i = 0; i < pts.length; i++) {
        if (c === null || !_mecContains(c, pts[i])) {
            c = _mecOnePoint(pts.slice(0, i + 1), pts[i])
        }
    }
    return c
}

// 本站所有机位的**最小包围圆**。返回 `{lat, lon, radiusM, count}` 或 **null**。
//
// ⚠️ **当前无生产调用点**（见上方段落标题）：范围圈已改用 `siteCenteredCircle`。
//    **不要**把它接回地图图层 —— 那会退回"圆心跟着机位簇跑"的旧口径，与用户
//    2026-09-23「改为以站点坐标为中心」的裁定相反。
//
// ‼️ 半径是**几何半径**，不含任何「最小可见尺寸」——那是**调用方**（地图图层）的事。
//    在这里兜底会让「只有一个机位的站点」画出一个比真实范围大的圈，而调用方再也
//    拿不回真值。两个量在调用点各自独立：`max(真实半径, 最小可见半径)`。
//
// ⚠️ 坐标无效（(0,0) / NaN / 缺字段）一律跳过，**与 `isValidWaypoint` 同一口径**。
//    把 (0,0) 放进去会把圆心拉到几内亚湾、半径变成几千公里 —— 而界面上只是「圈变大
//    了」，看不出是错的。
//
// 投影用**等距圆柱**：站点尺度（百米）下与球面距离偏差 < 0.1 m，换来把二维问题降成
// 平面问题，才能直接用 Welzl。经度按机位簇的**平均纬度**收缩（`cos` 取常数）。
function minEnclosingCircle(slots) {
    if (!Array.isArray(slots)) return null

    var lats = [], lons = [], sumLat = 0
    for (var i = 0; i < slots.length; i++) {
        var s = slots[i]
        var la = Number(s ? s.lat : NaN)
        var lo = Number(s ? s.lon : NaN)
        if (!isValidWaypoint(la, lo)) continue
        lats.push(la); lons.push(lo)
        sumLat += la
    }
    var n = lats.length
    if (n === 0) return null

    var kx = Math.cos((sumLat / n) * Math.PI / 180)
    // 极区（或异常纬度）下 cos → 0，经度会被放大到无意义。退回不收缩：宁可圈画大，
    // 也不要 NaN 顺着圆心/半径把整个图层搞坏。本站不在极区，这是纯粹的兜底。
    if (!(Math.abs(kx) > 1e-6)) kx = 1

    var flat = []
    for (i = 0; i < n; i++) flat.push({ x: lons[i] * kx, y: lats[i] })

    var c = _mecSolve(flat)
    if (c === null) return null

    return {
        lat: c.y,                       // y 就是纬度，无需换算
        lon: c.x / kx,                  // 反投影回经度
        radiusM: c.r * _mecMetersPerDeg(),
        count: n
    }
}

//--------------------------------------------------------------------------
// 站点范围圆（圆心 = **站点坐标**）

/// 两点间大圆距离（米）。
/// ‼️ R **必须**与 `_mecMetersPerDeg()` 取同一个值（6371000），也与
///    `tst_OpsCommon.qml` 的独立复算 `_distM` 同 R —— 三者若各取各的半径，
///    几百米量级上会差出近 1 m，把测试容差吃到贴边（那条容差不是摆设）。
function _greatCircleM(la1, lo1, la2, lo2) {
    var R = 6371000
    var p1 = la1 * Math.PI / 180
    var p2 = la2 * Math.PI / 180
    var dp = (la2 - la1) * Math.PI / 180
    var dl = (lo2 - lo1) * Math.PI / 180
    var h = Math.sin(dp / 2) * Math.sin(dp / 2) +
            Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2)
    // 浮点误差可能让 h 略大于 1 ⇒ `asin` 出 NaN。钳一下，别让 NaN 顺半径扩散到整个图层。
    return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)))
}

/// 以**站点坐标**为中心、圈住所有机位的圆。返回 `{lat, lon, radiusM, count}` 或 **null**。
///
/// ‼️ 与 `minEnclosingCircle` 的差别**不是精度，是语义**：
///    · `minEnclosingCircle` —— 圆心取几何最优点（Welzl），圆**最小**；
///    · 本函数 —— 圆心**锁定为站点坐标**，半径 = 站点到各机位的**最大**距离。
///    机位簇偏心时本函数的圆**明显更大**，这是刻意的：用户 2026-09-23 裁定
///    「改为以站点坐标为中心，圈住各个机位」。**不要**为"更紧凑"把圆心挪向簇心。
///
/// ⚠️ 两个形参的字段名**故意不同**，别"顺手统一"：
///    `siteCoord` 吃 `QtPositioning.coordinate()`（`.latitude`/`.longitude`，首字母大写），
///    `slots` 吃后端 JSON（`.lat`/`.lon`）。生产里它们本就是两种东西，
///    统一名字只会让传错对象时的失败从"立刻 NaN"退化成"静默算出错圆"。
function siteCenteredCircle(siteCoord, slots) {
    if (!siteCoord) return null
    var la0 = Number(siteCoord.latitude)
    var lo0 = Number(siteCoord.longitude)
    if (!isValidWaypoint(la0, lo0)) return null
    if (!Array.isArray(slots) || slots.length === 0) return null

    var maxD = -1, n = 0
    for (var i = 0; i < slots.length; i++) {
        var s = slots[i]
        var la = Number(s ? s.lat : NaN)
        var lo = Number(s ? s.lon : NaN)
        if (!isValidWaypoint(la, lo)) continue
        n++
        var d = _greatCircleM(la0, lo0, la, lo)
        if (d > maxD) maxD = d
    }
    if (n === 0) return null
    // `maxD` 初值 -1（不是 0）：单机位且正好落在站点上时结果是 0（合法），
    // 必须与"一个有效机位都没有"（上面已提前返回 null）区分开。
    return { lat: la0, lon: lo0, radiusM: maxD, count: n }
}

//--------------------------------------------------------------------------
// 机载告警（设计文档 §6）

// `MAV_SEVERITY`（八档）→ 中文（四档）——**单点定义**。
// ‼️ 界面不得出现裸枚举（既有约束 `ui-no-raw-enum-labels`）：浏览器自动翻译会把
//    `MAV_SEVERITY_WARNING` 这类裸标识曲解成别的词，而 severity 恰恰是这一列的核心信息。
// ‼️ 八档合一不是偷懒：0~3（EMERGENCY/ALERT/CRITICAL/ERROR）在 MAVLink 语义里同属
//    "错误级"（`StatusText::severityIsError()` 就是这四个 case 一起判的），对监控员而言
//    "需要立刻处理"是同一个动作 ⇒ 分成四档是**有用**的四档，不是丢失信息。
// ⚠️ 未知值（越界的 MAVLink 扩展、或字段缺失求值成 undefined/NaN）**必须**有一档兜底：
//    返回空串会让那一行只剩"时间 · 机号 · 空 · 文本"，返回裸数字则直接违反上面的约束。
function severityLabel(severity) {
    switch (Number(severity)) {
    case 0:                     // EMERGENCY
    case 1:                     // ALERT
    case 2:                     // CRITICAL
    case 3: return qsTr("严重")  // ERROR
    case 4: return qsTr("警告")  // WARNING
    case 5: return qsTr("提示")  // NOTICE
    default: return qsTr("信息") // INFO(6) / DEBUG(7) / 未知
    }
}

// 由 ③ 响应的 `devices[]` 按 `device_id` 建索引，供 `alertRows` 补 `uav_no`。
// ‼️ 过滤 `device_id <= 0`，理由与 `monitorDeviceIds` 同源：0 是"未学到映射"的缺省值，
//    把它建成 `out[0]` 之后，任何 `deviceID()` 也是 0 的载具都会**认领到这一行**的
//    `uav_no`——界面看起来完全正常，只是显示的是别人的机号。
// ⚠️ 同一 `device_id` 出现多次时**后写覆盖**（取最后一行）。后端已按 `device_id` 去重
//    （§3.5.2），这里是第二道；真要撞上，确定性也比"看哪个先来"好。
function deviceIndexByDeviceID(devices) {
    var out = {}
    if (!devices) return out
    for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        var id = Number(d ? d.device_id : 0)
        if (!(id > 0)) continue
        out[id] = d
    }
    return out
}

// 跨**全部**载具聚合机载告警（`STATUSTEXT`），按时间倒序，返回
// `[{ time, ts, who, taskNo, severity, text }, ...]`。
//
// ‼️ 数据源是 `QGroundControl.multiVehicleManager.vehicles`，**不是** `_activeVehicle`
//    （`VehicleMessageList.qml` 那种单机写法，监控员要跨机看）。原文此处另与 `OpsShell.qml`
//    那个喂仪表的 `_mockVehicle` 划界——**那个对象已于 2026-09-27 删除**，仪表现在也直接吃
//    真实 Vehicle，REST `latest` 包装的假对象在 OpsView 里已不存在。
//
// ‼️ `vehicles` 是 `QmlObjectListModel`：`.count` + `.get(i)`，**不是 JS 数组**
//    （写 `vehicles.length` 得到 `undefined` ⇒ 循环零次 ⇒ 静默返回空列表，界面表现为
//    "永远没有告警"，不报错）。与 `matchDeviceToVehicle` 同一口径。
//
// ‼️ `deviceID()` 是 `Q_INVOKABLE uint deviceID()` —— **方法不是属性**，少写括号恒得
//    `undefined` ⇒ `Number(undefined)` 是 `NaN` ⇒ 查不到 device ⇒ 全部走 systemID 分支。
//    而那个分支**看起来是对的**（显示了机号 `#5` 而不是报错），所以这个错法极难发现。
//
// ‼️ **找不到 device 的行必须保留**（§6.2 步骤 4），用 `vehicle.id`（systemID）标识。
//    这不是边角情形：飞机在 `READY_TO_TAKEOFF` 时被接引，落地转 `PARKED` 后从
//    `devices[]` 里**消失**，但 QGC 的 Vehicle 不会因此断开（§3.6.2"绝不移出登记集合"）。
//    它此刻若还在发 `STATUSTEXT`，那一行恰恰是监控员最需要看见的。
//    ⇒ 所以本列表的集合是 `vehicles`，**不是** `devices[]`。
//
// ⚠️ 每机取**末尾** N 条：`StatusTextHandler` 是 `append`（`m_messages.append(message)`），
//    所以"最近"= 数组尾部。取成前 N 条的话，界面上会长期停在开机那几条，
//    而最近的告警一条都看不见——**同样不报错**。
//
// ‼️ 告警取自 `Vehicle::statusTextMessages`（`Vehicle` 自己上的 `QVariantList`），
//    **不是** `vehicle.statusTextHandler.messages`：`Vehicle.h` 只**前向声明**了
//    `StatusTextHandler`，把裸指针暴露到 QML 要过 MOC 对不完整类型的处理，而 QML
//    那边其实一个字都不需要认识那个类型——转发数据即可。两者在 QML 侧的形状不同
//    （前者直接是数组），所以这不是"换个写法"，是换了一个接口。
//
// ‼️ **调用方必须信号驱动重算**：本节在 `.pragma library` 里，函数体读到的
//    `v.statusTextMessages` **不注册绑定依赖**（本文件头部那条）。写成
//    `property var rows: OpsCommon.alertRows(...)` 且不加别的依赖，列表会**永远停在
//    首次求值的那一帧**——而那一帧通常是空的，界面表现是"这个列表永远没有告警"，
//    不报错、也不刷新。`AlertListPanel.qml` 里的做法是：对每架载具的
//    `statusTextMessagesChanged` 建连接，收到就 `_bump++`，而 `rows` 的绑定表达式里
//    读 `_bump` ⇒ 依赖落在 `_bump` 上。
function alertRows(vehicles, deviceByDeviceID, perVehicleLimit, totalLimit) {
    var per = (perVehicleLimit > 0) ? perVehicleLimit : 20
    var cap = (totalLimit > 0) ? totalLimit : 200
    var index = deviceByDeviceID || {}
    var out = []
    if (!vehicles) return out

    var n = vehicles.count
    for (var i = 0; i < n; i++) {
        var v = vehicles.get(i)
        if (!v) continue
        var msgs = v.statusTextMessages
        if (!msgs || !msgs.length) continue

        var devId = Number(v.deviceID())
        var dev = (devId > 0) ? index[devId] : null
        var who = (dev && dev.uav_no) ? dev.uav_no : ("#" + v.id)

        var start = Math.max(0, msgs.length - per)
        for (var j = start; j < msgs.length; j++) {
            var m = msgs[j]
            if (!m) continue
            var iso = m.timestamp ? String(m.timestamp) : ""
            var ts = Date.parse(iso)
            // ⚠️ `NaN` 参与 `a - b` 会让排序结果**未定义**（比较函数返回 NaN 时实现可任选
            //    顺序）⇒ 一条没有时间戳的告警足以把整张表的次序打乱，而且每次重算还可能
            //    不一样。缺时间戳的排到最后（0 = 纪元），不比"随机位置"更坏。
            if (isNaN(ts)) ts = 0
            out.push({
                time: iso,
                ts: ts,
                who: who,
                // 航班号与 `who` 是**同一次查表**得来的（后端 `opsMonitorDevice` 同时带
                // `uav_no` 与 `task_no`）。⚠️ 缺值时给**空串**而不是 `undefined`：后者直接
                // 喂 QML 的 `text` 会渲染出字面量 "undefined"。
                taskNo: (dev && dev.task_no) ? dev.task_no : "",
                severity: Number(m.severity),
                text: m.text ? String(m.text) : ""
            })
        }
    }

    out.sort(function(a, b) { return b.ts - a.ts })
    return out.length > cap ? out.slice(0, cap) : out
}


//--------------------------------------------------------------------------
// 航线 → mission items（站点操作员起飞前的航线下发）
//
// ‼️ 本文件是 `.pragma library`，顶层函数与 `var` 在 import 方和测试里**都可见**
//    （既有先例：`tst_OpsCommon.qml` 直接调 `OpsCommon._mecTwoPoints`）。
//--------------------------------------------------------------------------

/// `MAV_CMD_NAV_WAYPOINT`。
var MAV_CMD_NAV_WAYPOINT = 16

/// `MAV_CMD_NAV_VTOL_LAND` —— **垂起着陆**：飞向指定坐标（高度不变），
/// 过渡到多旋翼并着陆。即单机版航线编辑器「选择航线任务指令」里的那一项。
///
/// ‼️ **不要和设计域的 `21` 混**：本值是 **85**。`21` 在 MAVLink 里是
///    `MAV_CMD_NAV_LAND`（在指定坐标降落，**不换机型**），与本函数要表达的"转多旋翼着陆"
///    是两条不同的指令 —— 数值上差得远，但设计域的站点标记恰好也叫 21，
///    极易顺手写错。
///    （2026-09-29 审查 A7 修正：原注释写「就地/固定翼降落」——"固定翼"是错的，
///      `MAV_CMD_NAV_LAND` 与机型无关；"就地"也是用户 2026-09-28 明确否掉的措辞。）
///    断言在 `test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml`（**不在 `src/OpsView/`**）：
///    `:1180` / `:1244` 断 `items[..].command === 85`，写成 21 会当场变红。
var MAV_CMD_NAV_VTOL_LAND = 85

/// `MAV_FRAME_GLOBAL` —— 高度按 **AMSL**（绝对高度）解释。
///
/// ‼️ 依据：**本计划 brief（2026-09-23）转述的真库观察**，**未经本任务独立复核**
///    （本任务无数据库访问权限）。该转述为：`table_waypoint.altitude` 存的就是 AMSL
///    ⇒ **零转换**直传，只需把参考系说清楚；其证据是 `route 4` 的 `.plan` 写
///    `plannedHomePosition` 高度 413、航点 `z = 50`，而库内对应的
///    `table_waypoint.altitude` 是 **463.0**（= 413 + 50）。
///    ⚠️ 该前提**决定 `frame` 的取值**：若库值其实是 AGL，`frame = 0` 会让每个航点都
///    偏高一个 home 高程，而任务卡上显示的高度看着完全正常。下游落地前须在有库环境核验。
///    ⚠️ 反过来，QGC 的 `MissionItem` **默认** `frame = MAV_FRAME_GLOBAL_RELATIVE_ALT(3)`
///    （相对 home）——构造 mission 时不显式覆盖，463 会被当成"离地 463 米"。
var MAV_FRAME_GLOBAL = 0

/// `MAV_VTOL_STATE_MC` —— 飞机**已在多旋翼档**（转换已完成，悬停/平飞在旋翼模式）。
///
/// ‼️ 判「切换多旋翼完成了没」**只能用这个取值**，不能去问「机型是不是多旋翼」：
///    `Vehicle::multiRotor()` 读的是 `vehicleType()`，而 VTOL 机体的 `MAV_TYPE` 是
///    `MAV_TYPE_VTOL_*`、**永远不会**变成 `MAV_TYPE_QUADROTOR`
///    （`QGCMAVLink::vehicleClass()` 是纯 switch，两类不相交）
///    ⇒ 该判据对 VTOL 机体**恒为 false**，切成功了也判不出来（2026-09-28 实测：
///    飞机确实切了多旋翼，界面却报「未报告转换完成」并放弃发出回航）。
///    同理 `vehicleTypeChanged` 也永不触发，别拿它当信号。
///    数据源：`EXTENDED_SYS_STATE.vtol_state`，由加密心跳 EXT 帧重建
///    （`CryptoHeartbeatExt.cc`），与 MAVLink `MAV_VTOL_STATE_*` 及 PX4
///    `VtolVehicleStatus.vehicle_vtol_state` 三者 1:1。
var MAV_VTOL_STATE_MC = 3

/// `MAV_VTOL_STATE_TRANSITION_TO_MC` —— 正在转多旋翼，**还没转完**。
///
/// ‼️ 单独列出来，是因为它是最容易漏掉的一档：转多旋翼一开始 `vtol_state` 就不再是
///    `FW`，于是 `!vtolInFwdFlight`（＝「不在固定翼档」）这类判据会**在转换途中就为真**。
///    此刻发出回航，PX4 仍视机体为固定翼，回航会重新落回那个卡死的 `LOITER_DOWN` 格
///    —— 症状与修复前一模一样，且看起来像是"修了没效果"。
///    `tst_OpsCommon.qml` 有专门一格钉住它。
var MAV_VTOL_STATE_TRANSITION_TO_MC = 2

/// 航线**设计域**的 `command` → MAVLink 指令号。未知 ⇒ `null`。
///
/// ‼️ **两套编号同名不同义**，别按数值猜：设计域的 `21` 是"站点"（可降落的站点类型
///    标记），而 MAVLink 的 `21` 是 `MAV_CMD_NAV_LAND`——数值巧合，语义无关。
///    本函数是这两套编号之间**唯一**的翻译点（已复核：`src/OpsView/` 下除本块外无第二处映射）。
///
/// ⚠️ 值域 `{16, 21}` 的依据：**本计划 brief（2026-09-23）转述的真库观察**（真库
///    `table_waypoint.command` 只有 16×12 与 21×13 两个值），**未经本任务独立复核**。
///    紧随其后的"`site.go` 用它做闸"同样只是 brief 转述，来自**另一个仓库**，本任务未读过它。
///    若真实库存在第三种设计域取值，那条航线会**静默**变成"不可下发"（回 `[]`，且零诊断）
///    ⇒ 下游落地前须在有库环境核验该值域是否封闭。
///
/// 【2026-09-28 用户裁定】**垂起着陆**：**终点站**的站点航点在 VTOL 机型上映射为
///    `MAV_CMD_NAV_VTOL_LAND(85)` —— 飞机在终点**转多旋翼着陆**，而不是像固定翼
///    那样绕终点一直盘旋（用户实测的故障现象）。用户不用额外操作，画完航线就带降落。
///
/// ❌ **【2026-10-01 裁定 R-A1：`isEnd === true` 这一支在生产路径上永不可达】**
///    `OpsRouteSync.qml` 调用 `routeMissionItems` 时第三个实参（`endWaypointId`）**刻意传
///    `undefined`** ⇒ `_endWaypointIndex` 恒回 `-1` ⇒ 没有 `i === endIdx` 的点 ⇒
///    `isEnd` 恒为 `false` ⇒ 本函数的 21 分支**恒走 `return MAV_CMD_NAV_WAYPOINT`**。
///    依据是用户 A1 原话「是由一系列航点组成」+ 运行红线「除非要坠机了，否则飞机只能在
///    机位上降落」（85 会落在**站点航点**上，坐标 ≠ 机位坐标）。详见 `_endWaypointIndex`。
///    ⚠️ 本行**只是说明可达性**，不是说要把 `isEnd` 那一支删掉 —— 留着以便将来若 R-A1 被推翻时恢复。
///
/// 未知值一律 `null`（fail-closed），由调用方把整条航线作废。
///
/// @param c      设计域 command（`16` 普通航点 / `21` 站点）
/// @param isEnd  本点是否为**该航线的终点站**。判据由 `routeMissionItems` 按
///                `id === 航线的终点航点 id` 算出 —— **不许按"列表里的最后一项"推断**，
///                那个推断已被真库实测推翻（理由与证据见 `_endWaypointIndex`）。
///                站点航点在你们模型里**首尾都用**（始发站 + 目的站），把 `21` 整体
///                映射成降落会让航线在**始发站就被截断**。
/// @param isVtol 机型是否为 VTOL。**只认真布尔 `true`**（理由见 `routeMissionItems`）。
function _designCommandToMavCmd(c, isEnd, isVtol) {
    var n = Number(c)
    if (n === 16) return MAV_CMD_NAV_WAYPOINT   // 普通航点
    if (n === 21) {
        // 终点站 + VTOL ⇒ 垂起着陆；其余几支（始发站 / 中间站 / 非 VTOL）继续按用户
        // 2026-09-23 的裁定「降落稍后再议」当普通航点下发。
        if (isEnd === true && isVtol === true) return MAV_CMD_NAV_VTOL_LAND
        return MAV_CMD_NAV_WAYPOINT
    }
    return null
}

/// 在 `wps` 里找出**航线终点航点**的下标；找不到、或命中多于一处 ⇒ `-1`
///（＝这条列表里没有可确认的终点 ⇒ **不产生降落指令**，fail-closed）。
///
/// ‼️ 判据是 `id === endWaypointId`，**不是**"最后一项"。这个推断曾被我写进实现，
///    2026-09-28 真库实测将其**推翻**：
///
///  · `GET /routes/:id/waypoints`（后端 `route.go` 的 `ListWaypoints`）**不返回起降点**：
///    它读 `table_route_waypoint`（+JOIN `table_waypoint`）拿中间航点，**再**读
///    `table_route.plan_data`，用 `mission.items[i].command` 覆写各点 command、并在头部
///    插一个 home 点（`command=-1`）；**唯独不读** `table_route.start_waypoint_id` /
///    `end_waypoint_id` 这两列 ⇒ 始发站 / 终点站**不在返回列表里**。
///    （2026-09-29 审查 A5 修正：原注释写「只读 `table_route_waypoint` 一张表」——错，
///      它还读 `plan_data`。⚠️ 这个过简的措辞是从后端照抄的，`handlers/ops.go` 的
///      `MyRouteWaypoints` 一带亦然 —— **按函数名定位，别按行号**。）
///    对照：`handlers/ops.go` 的 `buildTaskWaypoints` 才额外把这两列读进来拼在首尾
///    （该口径差记在 `handlers/ops.go` 的 `MyRouteWaypoints` 函数头注释里，写着「已知且本次不修
///     的口径差」—— **按函数名 / 那句话定位，别按行号**；原注释引 `ops.go` 两个行号区间，
///     是 2026-09-29 审查 A3 修正的错行号，本轮 2026-10-01 把行号定位本身也去掉）。
///
/// ⚠️ **本段以下所有「云端权威库」读数的出处等级**：它们不是本任务测的，是
///    **控制方（编排者）2026-10-01 只读实测**；采集口径 = `ssh root@39.97.235.226`、
///    库 `/opt/uavm/var/db_uavm.db`、**只读**打开（`file:...?mode=ro&immutable=1`）、
///    范围 = `table_route` 中 `deleted_at IS NULL` 的**全量 7 条**（口径可当场重跑，见
///    **计划工作区**里的 `~/uavm/uavm/.superpowers/sdd/新航线设定方式-实施计划-20260930/cloud-readings-20261001.txt`
///    的逐字原始输出；该文件在**计划工作区根**，**不在 `src/` 或 `test/` 下的任何相对路径上**）。
///    **本任务（QGC 仓）无云端凭据，未独立复核** —— 读成"实现者查过云端"即是误读。
///  · 实测样本 **RT-003**（**云端权威库**，2026-10-01 逐条复核；本机 `db_uavm.db` 是
///    2026-09-26 的陈旧副本、**连 NRRSM 的列都没有**，别拿它当判据）：
///    `start=2` 北七家镇政府 / `end=5` 保定市政府，
///    而返回列表只有 `seq=0 → wp3` 良乡区政府(cmd 21) 与 `seq=1 → wp4` 房山镇政府(cmd 16)
///    ⇒ 列表"最后一项"是**中途点**。按它打 85 ⇒ **飞机在房山镇政府降落**，
///    而任务的目的地是保定市政府 —— 正是用户红线上"只能在机位上降落"那一类事故。
///  · 反例 **RT-006**（云端权威库航线 id 23，2026-10-01 复核）：`start=1` / `end=2`
///    **恰好也在** `table_route_waypoint` 里（两行 → wp1 / wp2，且 wp2 排在末位）
///    ⇒ "最后一项"在那条航线上**恰好**对。
///    ⚠️ **这正是该推断最危险的地方**：拿这条航线当判据的样本，会得到一个假绿的 ✓。
///    ⚠️ 出处更正（修复轮 2 / 3）：本节原先引的反例是 **`RT-SITL01`**。
///       **该航线在权威库里存在**（航线 id 24，`route_code='RT-SITL01'`，
///       `route_name='SITL 苏黎世调试航线'`）—— **变的是它的数据**：
///       权威库现行值为 `start_waypoint_id=NULL` / `end_waypoint_id=NULL`，
///       且 `table_route_waypoint` **零行**；另据同一次控制方读数，
///       该行 `deleted_at='2026-10-01 00:58:29'` ⇒ **它已被软删除**。
///       （‼️ 本句只登记"同时存在"这两类事实，**不推断**「被软删 ⇒ 关联行被清空」的因果 ——
///         控制方没有那个因果的证据。出处等级同本段上文那条标注。）
///       而原注释引的 `start=26` / `end=28`、三行 `wp 26/27/28`，在
///       **2026-09-26 的本机 `db_uavm.db` 陈旧副本**里**逐字可复现**
///       ⇒ 那组数字取自该副本，**09-26 之后数据被改动过**，样本已不可用。
///       结论不变（"按位置推断终点"照样被推翻），样本已换成权威库现行的 **RT-006**（id 23）。
///
/// ⚠️ 于是本函数在**当前调用方式**下恒回 `-1`：调用方 `routeMissionItems` 收到的第三个实参
///    恒为 `undefined`（裁定 R-A1，见下）⇒ `endWaypointId` 不可用 ⇒ 第 0 行就回 `-1`。
///    （**别把它写成"列表里没有 id 等于 `endWaypointId` 的点"** —— 云端 4 / 5 / 23 三条
///     的列表里**就有**这样的点；本条恒 `-1` 的原因是**实参**，不是数据。）
///    ⇒ 垂起着陆**不会触发**，行为与本改动之前完全一致。
///
/// ❌ **【2026-10-01 裁定 R-A1：不解封，且永不靠它产生 85】** —— 本节原文写的是"解封条件与
///    下一步动作"，已被裁定**推翻**，别再把它读成"待办"：
///    · 用户 A1 原话：「qgc发给px4的航线中**没有降落点**，是由一系列航点组成」⇒ 末项是
///      **普通航点**；末尾那一点由 `appendLandingWaypoint`（A1）**追加**，而不是把某点打成 85。
///    · 用户的运行红线「**除非要坠机了，否则飞机只能在机位上降落**」：85 会让 PX4 落在
///      **站点航点**上，而站点航点坐标 **≠ 机位坐标** ⇒ 打 85 就是把飞机落在站上而不是机位上。
///      真正的降落走的是**另一条链**（Guided goto 到接机机位）。
///    ⇒ `OpsRouteSync.qml` 调用 `routeMissionItems` 时**第三个实参继续传 `undefined`**：
///      那是**裁定**，不是"忘了接"。本函数因此在**生产路径上恒不被命中**。
///
/// ‼️ **若将来有人推翻 R-A1 去打 85**：NRRSM 的降落高度会在「85 恰好落在末项」的航线上
///    静默失效（设计稿 `新航线设定方式-设计稿-20260930.md` §5.3 用「必须」点名了这条耦合）。
///    **触发条件是"打 85"本身，与是否把两个判据合并无关**；届时**没有任何测试会红**。
///    ⚠️ 会不会咬人，用**两条充要条件**自己判（别去记情形清单，清单只是举例）：
///      · 「会打出 85」 ⟺ 该项 `command === 21` ∧ `i === endIdx` ∧ 机型为 VTOL；
///      · 「降落高度真的被覆盖」 ⟺ 上一条成立 **且** 那个 85 正好落在 `items.length - 1` 上。
///    ⇒ **本函数既不判断两者是否同一项，也不判断该项是不是站点**（见 `applyLandingAltitude`
///    的注释）。逐情形实测可复跑：`final-fix3-calib.js`。
///
/// @param endWaypointId 航线终点航点 id（`table_route.end_waypoint_id`）。
///        只认 JSON number 且 `> 0`；其余一切取值（含 `undefined` / `0` / `null`
///        / `"5"`）一律按"没有可确认的终点"处理。
function _endWaypointIndex(wps, endWaypointId) {
    if (typeof endWaypointId !== "number" || !isFinite(endWaypointId) || endWaypointId <= 0) return -1
    var found = -1
    for (var i = 0; i < wps.length; i++) {
        var w = wps[i]
        if (!w) continue
        if (typeof w.id === "number" && w.id === endWaypointId) {
            // 命中多于一处 ⇒ 无法确定"哪一个是终点" ⇒ 不降落（fail-closed）。
            // 两条 85 会让飞机在航路中途落一次，后果不可撤销。
            if (found >= 0) return -1
            found = i
        }
    }
    return found
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
/// @param wps 航点数组，每项 `{id, lat, lon, altitude, command}`
/// @param isVtol 机型是否为 VTOL（调用点从 `vehicle.vtol` 读好再传进来 ——
///        本文件是 `.pragma library`，函数体内读属性**不注册绑定依赖**）。
///        ‼️ **只认真布尔 `true`**，其余一切取值（含 `1` / `"true"` / `"false"`）
///        一律按"非 VTOL"处理。选 fail-closed 这一侧的理由：**漏掉降落**的后果是
///        飞机在终点**可见地**盘旋（与今天的行为一致，现场一眼能看出不对）；
///        **多插一个降落**的后果是飞机真的落下去，不可撤销。
///        ⚠️ 尤其 `"false"` 在 JS 里是**真值** —— 凡用 `if (isVtol)` 强转的实现都会放行它。
/// @param endWaypointId 航线终点航点 id（`table_route.end_waypoint_id`）。只有它能在
///        列表里**指认出**终点；指认不出（含不传 / `undefined`）⇒ 本函数**不产生**
///        垂起着陆。判据与真库证据见 `_endWaypointIndex` 的注释。
/// @param cruiseAGL 本架次飞行高度（**AGL，米**）。中间项按其「该航点地面海拔 + `cruiseAGL`」
///        组装（设计稿 §5.2 规则表第 2 行）。**数值 `0` 是合法输入**（本仓口径：`0` = 未设定）
///        ⇒ 输出与加本参数之前**逐字相同**；「`0` 该不该起飞」是**闸**的事（`takeoffAGL > 0`），
///        不是本函数的事 —— 本函数只做算术。
///        ‼️ 不可用（`undefined` / `NaN` / 非数字）⇒ **整条航线作废（回 `[]`）**，与下面
///        「任何一点不可用 ⇒ 整条航线作废」同一取向：把不可用的 `cruiseAGL` 静默当 `0`
///        正是本函数要杀的那种「少一个偏移、零报错」缺陷；回 `[]` 让调用方看到**响亮**的失败。
/// @return `[{command, lat, lon, alt, frame}]`；任一输入（含 `cruiseAGL`）不可用 ⇒ `[]`
function routeMissionItems(wps, isVtol, endWaypointId, cruiseAGL) {
    if (!wps || !wps.length) return []
    // ‼️ `cruiseAGL` 不可用 ⇒ 整条航线作废（回 `[]`），**不是**"按 0 处理"。
    //    判据形式与下面各点同口径：按类型 + 有限性收。负数是**业务校验**的事
    //    （后端 `cruise_alt_agl < 0 ⇒ 报错`），本函数**不做额外拒绝**、照常参与算术。
    if (typeof cruiseAGL !== "number" || !isFinite(cruiseAGL)) return []
    // ‼️ 「哪一点是终点」由**航线自己的终点航点 id** 指定，不许按"列表最后一项"推断
    //    （真库实测推翻了那个推断，证据见 `_endWaypointIndex`）。
    //    当前数据源下恒为 `-1` ⇒ 垂起着陆不触发，行为与改动前一致。
    var endIdx = _endWaypointIndex(wps, endWaypointId)
    var out = []
    // ‼️ 「末项」的下标。它同时是「要不要给这一点加 `cruiseAGL`」的分界（见下方注释）。
    //    口径与 `applyLandingAltitude` 的 `items.length - 1` **一致**：都是"出参的最后一项"。
    var lastIdx = wps.length - 1
    for (var i = 0; i < wps.length; i++) {
        var w = wps[i]
        if (!w) return []
        var mavCmd = _designCommandToMavCmd(w.command, i === endIdx, isVtol)
        if (mavCmd === null) return []
        // ‼️ **三个字段统一只按类型收**：必须是 JSON number。依据是"后端 `table_waypoint`
        //    的这三个字段是非空/可空 REAL 列 ⇒ Go 读成 `float64` ⇒ 序列化成 JSON number"，
        //    故字符串等形态在真实链路上不会出现，拒绝它们**不会误伤生产路径**。
        //    为什么不逐个枚举"坏形态"：`Number(null)`、`Number(undefined)`、`Number("")`、
        //    `Number(" ")`、`Number("\t")`、`Number("0")`、`Number(false)`、`Number([])`
        //    **全都** `=== 0`，而 `isFinite(0)` 为真 —— 枚举永远会漏，漏掉的那个就从这道门
        //    正门走进来，让 `takeoffAltitude` 回 **0 而不是 `NaN`** ⇒ **只判 `isNaN` 的
        //    起飞闸会失效**（飞机被指令到 AMSL 0 米，而界面上看不出错）。按类型收把这个
        //    "需要穷举"的问题整个消掉。
        //    ⚠️ `typeof NaN === "number"` ⇒ 本行**替代不了**下面的 `isValidWaypoint`
        //       与 `isFinite(alt)`，那两步（值域）必须保留。
        //    ⚠️ **数值 `0`（及 `0.0`）仍会通过本函数并原样透传** —— 这是**有意的裁量**：
        //       "高度恰好为 0"是**数据问题**（后端该不该存 0），不是**类型问题**；本函数
        //       只负责类型，业务判定留给调用方的起飞闸（那里能给出中文文案）。
        //       **别把本段读成"0 已被关闭"** —— 它有专门用例钉着（见 `tst_OpsCommon.qml`
        //       的 `test_routeMissionItems_numericZeroAltitudeIsDeliberatelyAllowed`）。
        if (typeof w.lat !== "number" || typeof w.lon !== "number" || typeof w.altitude !== "number") return []
        var lat = Number(w.lat), lon = Number(w.lon), alt = Number(w.altitude)
        // 坐标有效性**直接复用本文件的单点定义** `isValidWaypoint`：它已内含 `isFinite`，
        // 且口径是"任一轴为 0 即无效"，比原先自写的"两轴同时为 0"更严。
        if (!isValidWaypoint(lat, lon)) return []
        if (!isFinite(alt)) return []
        // 中间项 = 该航点地面海拔 + 本架次飞行高度（设计稿 §5.2 规则表第 2 行）。
        // ‼️ 条件是 `i < lastIdx`（即出参里"不是最后一项"），**不是** `0 < i`。
        //    「起飞项」是 QGC 自己插的 `NAV_TAKEOFF`，**不在本函数的产出里** ⇒
        //    本函数的**第 0 项是航线的第一个中间航点**，它**要**加 `cruiseAGL`。
        //    写成 `i > 0` 会让首个中间航点少一个巡航高度偏移 —— 整条航线的第一个点
        //    比其余中间点低 `cruiseAGL` 米，**界面上完全看不出来**。
        //    「末项」保持原样（`alt` 逐字不变），由 `applyLandingAltitude` 覆盖成
        //    降落站点地面海拔 + max(...)。
        var missionAlt = (i < lastIdx) ? alt + cruiseAGL : alt
        out.push({ command: mavCmd, lat: lat, lon: lon, alt: missionAlt, frame: MAV_FRAME_GLOBAL })
    }
    return out
}

/// 把「**降落站点对应的航点**」追加为航点序列的**末项**（NRRSM A1，2026-10-01）。
///
/// 用户 A1 原话：「qgc发给px4的航线中**没有降落点**，是由一系列航点组成。A1 就是**最后一个航点**
/// （同时也是降落站点所在位置，**经纬度由降落站点对应的航点的经纬度定**，高度由
/// `max(table_route.landing_alt_agl, table_site.clear_alt_agl) + table_waypoint.altitude`
/// （降落站点对应航点）定）」。
/// 「降落站点对应的航点」= `table_route.end_waypoint_id` 所指的那一个航点
/// （既有派生链 `handlers/task.go` 的 `landingSiteOfRouteEnd` 已确认两者同一，
/// 见后端 `route_end_site_test.go` 的 `TestRouteEndSiteMatchesTaskDerivation`）。
///
/// ‼️ **这是一条普通航点，不产生 `85 NAV_VTOL_LAND`**（裁定 R-A1，2026-10-01）：
///    用户原话是「是由一系列航点组成」；而 85 会让 PX4 落在**站点航点**上，
///    与用户红线「除非要坠机了，否则飞机只能在机位上降落」冲突 —— 真正的降落走的是
///    **另一条链**（Guided goto 到接机机位），**站点航点坐标 ≠ 机位坐标**。
///    所以本函数产出的追加项 `command` 取**设计域的 `21`（"站点"标记）**，它在
///    `_designCommandToMavCmd(21, false, …)` 下映射成 `16 NAV_WAYPOINT` —— 正是要的落点。
///    ⚠️ 设计域的 `21` 与 MAVLink 的 `NAV_LAND(21)` **数值巧合、语义无关**（见 `_designCommandToMavCmd`）。
///
/// 为什么必须追加：`GET /api/routes/:id/waypoints`（后端 `route.go` 的 `ListWaypoints`）
/// **不返回起降点** ⇒ 固定航线的 mission 现在结束在一个**中途点**上，而不是降落站点。
///
/// ‼️ **覆盖声明按"形状"写，不按航线号写**（航线号会随库漂移，且读的人会把它当覆盖证明）：
///    · 走**行为 1（追加分支）**的样本形状 =「返回列表**非空**、且终点**不在**其中」；
///    · 走**行为 2（原样返回）**的样本形状 =「终点**在**列表里且**恰为末项**」；
///    · 返回列表**为空**的航线会先被**行为 7** 拦成 `[]`，**根本不经过追加分支**
///      —— 别把它算进行为 1 的覆盖里。
///    ⚠️ 出处（2026-10-01 **云端权威库**逐条复核；本机 `db_uavm.db` 是 2026-09-26 的陈旧副本、
///       连 NRRSM 的列都没有，**别拿它当判据**）：非空且终点不在其中的有 1 / 20 / 21；
///       终点恰为末项的有 4 / 5 / 23；返回列表为空的有一条（零行）。
///    ⚠️ **出处等级**：上面这些读数**不是本任务测的**，是**控制方（编排者）2026-10-01
///       只读实测**；采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、
///       **只读**打开（`file:...?mode=ro&immutable=1`）、范围 `table_route` 中
///       `deleted_at IS NULL` 的全量 7 条。**本任务（QGC 仓）无云端凭据，未独立复核。**
///
/// 失败一律回 `[]`（**整条作废，fail-closed**）—— 与 `routeMissionItems` 同一取向：
/// 把不可用的输入静默按 0 / 跳过处理，会让飞机飞出一条用户没画过的路径，而界面上零报错。
/// ‼️ 但"要看哪些输入"是**可计算**的：只有**会被本函数用到的**输入不可用才作废。
///    `endLat` / `endLon` / `endGroundMSL` **只在追加分支被读到** ⇒ 它们不参与
///    「末项已是终点」那一档的判定（裁定 B，2026-10-01）。签名里出现 ≠ 会被用到。
///
/// @param wps 航点数组（`GET /api/routes/:id/waypoints` 的响应，调用方已摘掉 `command === -1` 的 home 项）
/// @param endWaypointId 航线终点航点 id（`route.end_waypoint_id`）。只认 JSON number 且 `> 0`
///        ——口径与 `_endWaypointIndex` **逐字相同**。
/// @param endLat 终点航点纬度（`route.end_waypoint_lat`）—— 仅追加分支消费
/// @param endLon 终点航点经度（`route.end_waypoint_lon`）—— 仅追加分支消费
/// @param endGroundMSL 终点航点的**地面海拔**（`route.landing_ground_msl`，MSL 米）
///        —— 仅追加分支消费
/// @return 新数组（**不原地改入参**）。判据 =「**会被本函数用到的**输入不可用 ⇒ `[]`」
///        （整条作废，fail-closed）；**不是**「签名里出现过的每个参数」。
function appendLandingWaypoint(wps, endWaypointId, endLat, endLon, endGroundMSL) {
    // 行为 7：空 / 非数组 ⇒ 作废。
    if (!Array.isArray(wps) || !wps.length) return []
    // 行为 4：与 `_endWaypointIndex` 逐字同口径（只认 JSON number 且 `> 0`）。
    if (typeof endWaypointId !== "number" || !isFinite(endWaypointId) || endWaypointId <= 0) return []
    // 行为 2：末项**恰好**就是终点 ⇒ 原样返回（浅拷贝），**不重复追加**。
    //  云端真库 4 / 5 / 23 就是这个形状；重复追加会让飞机到终点后再多飞一段回头路。
    //  ⚠️ 出处等级：「云端真库 4 / 5 / 23」这条读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
    //     采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
    //     （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    //     **本任务（QGC 仓）无云端凭据，未独立复核。**
    //  ‼️ **本档不读 `endLat` / `endLon` / `endGroundMSL`** —— 点已经在列表里，那三个值
    //     在这条路上一次都用不到。要求它们也可用＝守卫过宽，会平白砍掉本来能发的航线
    //     （裁定 B：真相是"**会被用到的**输入不可用才作废"）。末项坐标真坏掉时，
    //     下游 `routeMissionItems` 会逐点校验 `lat` / `lon` / `altitude` 并回 `[]`
    //     （`isValidWaypoint` 口径），由那边报**更贴近真相**的那句话。
    //  行为 3 的判据也必须在坐标校验**之前** —— 见本函数末尾的"顺序是承重点"注。
    var last = wps[wps.length - 1]
    if (last && typeof last.id === "number" && last.id === endWaypointId) return wps.slice()
    // 行为 3：终点**在列表里但不是末项** ⇒ 作废（fail-closed）。
    //  追加会**绕回**、不追加则末项不是降落点 —— 两条路都会飞出一条用户没画过的路径，
    //  所以选"响亮地失败"。
    //  ‼️ 出处（2026-10-01，**云端权威库全量**、7 条航线逐一核算落点）：行为 1 = 1 / 20 / 21；
    //     行为 2 = 4 / 5 / 23；行为 7 = 22（零行）；**无一落到行为 3**。
    //     写"不存在"必须能指到**哪台机、哪个库、多大范围** —— 本句指的是云端权威库全量 7 条，
    //     不是"我没见过"。库一变这句就可能过期，届时以现场复跑为准。
    //  ⚠️ 出处等级：上面这组读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
    //     采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
    //     （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    //     **本任务（QGC 仓）无云端凭据，未独立复核。**
    for (var i = 0; i < wps.length; i++) {
        var w = wps[i]
        if (w && typeof w.id === "number" && w.id === endWaypointId) return []
    }
    // ⛔ 以上是「终点已经在 `wps` 里」的两档；以下是**追加分支**（终点不在序列里）。
    //    ↑ 顺序是承重点：把下面两道守卫挪到行为 2 之前，4 / 5 / 23 那三条本来能发的
    //      航线会因一个与它们正确性无关的后端字段而拒发。
    // 行为 5：坐标复用本文件的单点定义 `isValidWaypoint`。后端在**没有终点航点**时把
    //  `end_waypoint_lat` / `end_waypoint_lon` 两键 `COALESCE` 成 `0`，而它的口径是
    //  "任一轴为 0 即无效" ⇒ 这一条同时也是"后端没给终点"的第二道闸。
    //  ‼️ 先 `Number()` 收敛：`null` ⇒ `0`、`undefined` ⇒ `NaN`，两者都过不了 `isValidWaypoint`。
    var lat = Number(endLat), lon = Number(endLon)
    if (!isValidWaypoint(lat, lon)) return []
    // 行为 6：地面海拔必须是有限的 JSON number（字符串 / `null` / `NaN` 一律作废）。
    if (typeof endGroundMSL !== "number" || !isFinite(endGroundMSL)) return []
    // 行为 1：追加为**末项**。入参不被修改（`slice()` 后再 push）。
    var out = wps.slice()
    out.push({ id: endWaypointId, lat: lat, lon: lon, altitude: endGroundMSL, command: 21 })
    return out
}

/// 起飞高度 = **第一个航点的高度**（用户 2026-09-23 裁定 e）。
///
/// 航线不可用 ⇒ `NaN`（**不是 0**）：回 0 会让飞机起飞到"AMSL 0 米"，
/// 而那个数字在界面上看不出错。
/// ‼️ 但**数值 0 是本函数有意放行的**（理由见 `routeMissionItems` 内注释）⇒ 调用方
///    **只判 `isNaN` 是拦不住起飞的**，必须用值域判据。本函数**当前的**调用方只有用例；
///    历史上 `OpsRouteSync.qml` 用的是 `!(takeoffAlt > 0)`（`NaN > 0` 为 false ⇒ 取反为真 ⇒ 拦住），
///    那道闸现在读的是航线的 `takeoff_alt_agl`，但**判据形状一字未改** —— 形状是本条的承重点。
/// ⚠️ NRRSM（2026-09-30）：本函数的语义（取**首个中间航点**的高度）在 NRRSM 下**已不是**起飞高度 ——
///    起飞项高度改由航线的 `takeoff_alt_agl` 提供（见 `routeAltitudeBounds`）。**别再往新代码里接。**
///    ⏱️ 时点说明（2026-09-30 fix round 2 重写）：**产线调用点已归零** —— `src/` 之内除本定义处
///    以外**没有任何调用**（"调用"＝标识符后紧跟左括弧的形态），调用方只剩单测
///    `test/UnitTestFramework/QmlTesting/tests/tst_OpsCommon.qml`。
///    `OpsRouteSync.qml` 里那道旧闸已换成读航线 `takeoff_alt_agl` 的两道同形闸（起飞 / 降落各一）。
///    ⚠️ **核验时请搜"调用形态"，不要搜裸标识符** —— 裸标识符会把**引用它的注释**一并数进来：
///    本文件里 `routeMissionItems` 的注释就引了它（讲 `0` 为何被放行那一段），本注释自己也曾引它
///    ⇒ 任何"只剩定义处"式的结论都会被注释自己证伪。
///    （fix round 1 正是这么错了一次：判据的表达式不得出现在它自己统计的语料里。）
///    保留实现与既有用例，**仅供回退**。
function takeoffAltitude(wps) {
    // ‼️ **有意不接 `isVtol` / `endWaypointId`**（下面显式传 `false` / `null`）：垂起着陆只改**终点站那一点**的
    //    `command`，既不改变航线是否可用（`length`），也不碰**首点**的高度
    //    ⇒ 本函数与机型、与终点在哪都无关。
    //    传了也不会错，但那会让下一个人以为"起飞高度跟机型/终点有关"。
    // ‼️ 显式传 `0` 是**刻意**的：本函数在 NRRSM 下已不是"起飞高度"（见其函数头注释），
    //    保留仅为回退。传 `0` 让它的输出与改动前**逐字相同** —— 别在这里传真值，
    //    那会让一个已作废的函数看起来还在产线上。
    //    （`false` / `null` 与原先的隐式 `undefined` 语义等价：`isVtol` 只认真布尔 `true`，
    //     `endWaypointId` 只认 JSON number 且 `> 0`。显式写出来是为了让"这里没接线"看得见。）
    var items = routeMissionItems(wps, false, null, 0)
    return items.length ? items[0].alt : NaN
}

/// NRRSM **D6 硬下限**（`生效值 = max(航线值, 站点最低安全高度)`）的**单点定义**（B7，2026-10-01）。
///
/// 起飞侧 / 降落侧各调一次，两处都是它的**调用点**，本仓内不再有第二份 `Math.max` 实现：
///   · `routeAltitudeBounds` 的两个合成键 `takeoffAGL` / `landingAGL`；
///   · `OpsRouteSync.qml` 的两个绑定 `_takeoffAGL` / `_landingAGL`。
/// 要核对当前有哪些调用点，**现场复跑**（别记计数 —— 计数会被下一轮增删当场证伪）：
///   在 QGC 仓根跑 `rg -n 'nrrsmEffectiveAGL' src/`。
///
/// `orZero` 把 `null` / `NaN` / 非数字**一律按 `0` 计**：合成量因此**恒为有限数字**，
/// `null` 不外传（调用方的闸写的是值域判据 `!(x > 0)`，遇 `null` 会走 JS 隐式转换 ——
/// 结论碰巧一样，但那是巧合，不是代码）。
/// ⇒ 两个输入都不可用 ⇒ 合成 `0` ⇒ 闸拦住 ⇒ fail-closed；这与「填了 0（未勘测）」
///   在闸上**同义**，所以合并成 `0` 不损失分辨力。
///
/// ⚠️ **本仓之外还有一处同一规则**（不是本函数的调用点，故意各自独立）：
///    后端 `gcs_server/handlers/route.go` 的 `nrrsmEffectiveLandingAGL` —— 它只喂
///    `max_cruise_alt_agl` 的反解与梯度判，**不参与航点飞行高度的组装**。
///
/// @param routeAGL     航线侧的 AGL 值（起飞 = `takeoff_alt_agl`；降落 = `landing_alt_agl`）
/// @param siteClearAGL 该端站点的最低安全高度（AGL）
/// @return 两侧大者；任一不可用按 `0` 计 ⇒ 恒为有限数字
function nrrsmEffectiveAGL(routeAGL, siteClearAGL) {
    function orZero(v) { return (typeof v === "number" && isFinite(v)) ? v : 0 }
    return Math.max(orZero(routeAGL), orZero(siteClearAGL))
}

/// NRRSM **「一个 AGL 米值是否已设定」的单点定义**（W1，2026-10-01）。
///
/// ‼️ `0` 在本系统里是「未设定」的**编码**，不是「贴地飞」这个合法高度 ——
///    判据 4（`table_flight_task.cruise_alt_agl` = 离地飞行高度，AGL 米，`0` = 未设定）
///    与判据 7（飞行高度 = `table_waypoint.altitude + cruise_alt_agl`）下，
///    `cruise_alt_agl = 0` 算出的「飞行高度」就是**航点地面海拔本身** ——
///    也就是飞机降到**地形高度平飞**。起飞端 / 降落端同（同一份「AGL 米，`0` = 未设定」语义）。
///    ⇒ 这不是防御性编程：云端实测 `table_flight_task.cruise_alt_agl` **存量 100% 为 `0`**。
///
/// **三道高度闸共用这一个谓词**（`OpsRouteSync.qml` 的 `start()` 里：起飞 / 降落 / 飞行），
/// 别再各写各的 `> 0` —— 同一件事有两个判据 ⇒ 下一轮改一处漏一处，且两道之间未必等价。
/// ⚠️ 判的**只是「AGL 项」**。**地面海拔项不要用本谓词** —— 它的 `> 0` 那一步会把
///    `0`（海平面）/ 负数的**合法**地面海拔误拒；地面海拔项用 `nrrsmFiniteGroundMSL`（紧随其后）。
///
/// 判据**三步缺一不可**（按类型 → 有限性 → 值域收）：
///   · **非 number ⇒ `false`**（含字符串 `"50"` / `undefined` / `null` / 布尔）。
///     ‼️ 少了这一步，`return v > 0` 这种实现会**静默放行**字符串 `"50"`
///     —— JS 里 `"50" > 0` 为真（`undefined > 0` 为假只是巧合，不是判据）。
///   · **非有限 ⇒ `false`**（`NaN` / `±Infinity`）。`NaN` 尤其重要：QML 的 `property real`
///     缺省值就是它，而 `!isFinite` 与 `!(x > 0)` 都能拦住 `NaN`，但拦不住 `Infinity`
///     （`Infinity > 0` 为真 ⇒ 会把一个荒谬的巡航高度放进航线）。
///   · **`<= 0` ⇒ `false`**。**边界是 `<= 0` 不是 `< 0`**：`0` 正是「未设定」的编码。
///
/// ⚠️ 本函数**只**回答「这个值可用吗」，**不做**任何取默认值的动作：把不可用值折成 `0`
/// 或某个缺省高度，正是本条要杀的症状（下游闸会被折出来的合法值架空）。
///
/// @param v 待判的 AGL 值（米）
/// @return 真布尔（`true` / `false`）。非 number / 非有限 / `<= 0` 一律 `false`
function nrrsmUsableAGL(v) {
    if (typeof v !== "number") return false
    if (!isFinite(v)) return false
    return v > 0
}

/// NRRSM **地面海拔项**的可用性谓词（I2，2026-10-01）。与 `nrrsmUsableAGL` **并列**，
/// 但判据**刻意比它宽**：本函数**只判「是不是有限数」**，**不判值域**。
///
/// ‼️ **不许拿 `nrrsmUsableAGL` 代替本函数**：它的最后一步是 `v > 0`，而**站点地面海拔
///    可以是 `0`（海平面）甚至负数（低于海平面）**，那都是**合法**取值 —— 复用会把这类
///    合法航线一并拒掉。起飞侧 / 降落侧都可能落在海平面机场上，这不是假想输入。
///
/// 为什么需要它：`assembledAltitude(groundMSL, agl)` 有**两个**输入项，而三道高度闸
/// （`nrrsmUsableAGL`）判的都只是 **AGL 项** ⇒ 地面海拔项此前**两侧都没有闸**，三个消费点
/// （末项 `applyLandingAltitude`、起飞项 `_applyAltitude`、`_statusText` 的两个 `arg`）
/// **全部无守卫且完全静默**（末项会退回"中间项口径"，即按**巡航高度**飞向降落点）。
///
/// 判据两步（缺一不可）：
///   · **非 number ⇒ `false`**（含字符串 / `undefined` / `null` / 布尔 = 键缺失或类型不符）；
///   · **非有限 ⇒ `false`**（`NaN` / `±Infinity`）。QML 侧"键缺失"由 `routeAltitudeBounds`
///     的 `null` 落成 `NaN`，正是靠这一步拦住（fail-closed）。
///
/// ⚠️ 与 `nrrsmUsableAGL` 一样，本函数**只**回答「这个值可用吗」，**不做**任何取默认值的动作。
///
/// @param v 待判的**地面海拔**（MSL，米）
/// @return 真布尔（`true` / `false`）。非 number / 非有限一律 `false`
function nrrsmFiniteGroundMSL(v) {
    if (typeof v !== "number") return false
    if (!isFinite(v)) return false
    return true
}

/// NRRSM **判据 5 / 6 的最后一跳**（A2，2026-10-01）：**组装式高度** =
/// 该端**站点航点地面海拔** + 该端 **AGL 生效值**。
///   · 起飞项 = `assembledAltitude(_takeoffGroundMSL, _takeoffAGL)`   // 判据 5
///   · 降落项 = `assembledAltitude(_landingGroundMSL, _landingAGL)`   // 判据 6
/// 它就是用户七条语义里第 5 / 6 条的字面算式
/// （`max(takeoff_alt_agl, clear_alt_agl) + waypoint.altitude`，其中 `waypoint.altitude`
///  是**该端站点航点的地面海拔（MSL）**）。收成单点定义，是为了让这一跳**有测试**：
///  改动前它以裸算式散在 `OpsRouteSync.qml` 的多个使用点上，而该文件**全仓零测试**。
///
/// ‼️ 两个加数**单位不同**（MSL 与 AGL），**同名互换不会报错、只会静默算错**，别混用。
/// ‼️ 任一加数非有限数 ⇒ **`NaN`（不是 `0`）**：`0` 会让下游闸的 `!(x > 0)` 失效
///    —— 那正是"未设定却被当成有效高度"的症状。
/// ‼️ **数值 `0` 是合法加数**（`assembledAltitude(0, 50) === 50`）：站点地面海拔为 0 是真实取值，
///    不是"缺"。类型不符（`null` / `undefined` / 字符串 / `NaN`）才回 `NaN`。
///
/// @param groundMSL 该端站点航点的**地面海拔（MSL，米）**
/// @param agl       该端 **AGL 生效值**（米；见 `nrrsmEffectiveAGL`）
/// @return `groundMSL + agl`；任一非有限数 ⇒ `NaN`
function assembledAltitude(groundMSL, agl) {
    if (typeof groundMSL !== "number" || !isFinite(groundMSL)) return NaN
    if (typeof agl !== "number" || !isFinite(agl)) return NaN
    return groundMSL + agl
}

/// NRRSM（2026-09-30）：取航线的六个起降相关高度原始量 + 三个终点航点量，
/// 并合成两个 D6 生效值。
/// ‼️ **别在本注释里找键数**（"共 N 键"这类计数会被同文件任何一次增删静默腐化，
///    且会被读成**穷举**）：**键集以本函数 `return` 的字面量为准** ——
///    下面那份清单若与 `return` 不符，**以 `return` 为准**。
///
/// 入参 `route` 是 `GET /api/routes/<id>` 的响应体（**不是** `/waypoints` —— 那是航点数组，
/// 不含航线级字段）。
///
/// 任一项不是有限数 ⇒ 该项回 **`null`**，不是 `0`、也不是 `NaN`。这里的 `null` 只表示
/// **类型层不可用**（字段缺失 / 非数字）。
/// ‼️ **别把它读成「后端没给」**：后端把「未设定」也发成 `0`（读出口用的是
///    `COALESCE(takeoff_alt_agl,0)` / `COALESCE(landing_alt_agl,0)`，且模型里这两个字段是
///    不带 `omitempty` 的 `float64`）⇒ 两个键**永远存在、永远是 JSON number**，
///    **调用方区分不出「没给」与「填了 0」—— 两者都是 `0`**。
///    所以闸**必须**把 `0` 也判为不可用：用值域判据 `!(x > 0)`，**不能**写成 `isNaN(x)`
///    或 `x === null`（那会把 `0` 放行）。另注 `0` 是 falsy，`!x` 会再混一次。
function routeAltitudeBounds(route) {
    // ‼️ 键**分三类**（2026-10-01 A1/B7）：六个高度原始量 + 三个终点航点量 + 两个合成量。
    //    **键集以本函数末尾 `return` 的字面量为准**；下面这份清单若与 `return` 不符，
    //    **以 `return` 为准**（"共 N 键"这类计数会被下一次增删静默腐化，别按它核）。
    //    六个高度原始量（来源就是 `GET /api/routes/<id>` 的同名响应键），**值单位各不相同、别混用**：
    //      · `takeoffAltAGL`     ← `route.takeoff_alt_agl`                航线起飞高度（**AGL，米**）
    //      · `takeoffClearAGL`   ← `route.takeoff_site_clear_alt_agl`     **起飞站点**最低安全高度（**AGL，米**；0=未勘测）
    //      · `takeoffGroundMSL`  ← `route.takeoff_ground_msl`             `G_t`，起飞站点**地面海拔**（**MSL，米**）
    //      · `landingAltAGL`     ← `route.landing_alt_agl`                航线降落高度（**AGL，米**）
    //      · `landingClearAGL`   ← `route.landing_site_clear_alt_agl`     **降落站点**最低安全高度（**AGL，米**）
    //      · `landingGroundMSL`  ← `route.landing_ground_msl`             `G_l`，降落站点**地面海拔**（**MSL，米**）
    //    三个终点航点量（2026-10-01 A1；**不是**高度，单位是 id / 度）：
    //      · `endWaypointId`     ← `route.end_waypoint_id`                航线终点航点 id（**只认 number > 0**）
    //      · `endLat`            ← `route.end_waypoint_lat`              该航点纬度（**WGS84 度**）
    //      · `endLon`            ← `route.end_waypoint_lon`              该航点经度（**WGS84 度**）
    //      ‼️ 后端在**没有终点航点**时把后两键 `COALESCE` 成 `0`（键仍存在）
    //         ⇒ 它们经 `pick` 后是**数字 0**、不是 `null`；在 `appendLandingWaypoint` 的
    //         **追加分支**里由 `isValidWaypoint`（任一轴为 0 即无效）拦下 ⇒ 整条作废（fail-closed）。
    //         （「末项已是终点」那一档**不读**这两键 —— 见 `appendLandingWaypoint` 与裁定 B。）
    //    两个合成量（D6 硬下限的生效值，各取两侧大者）：
    //      · `takeoffAGL = max(takeoffAltAGL, takeoffClearAGL)`
    //      · `landingAGL = max(landingAltAGL, landingClearAGL)`
    //    ‼️ **闸的判据项是这两个 AGL 合成量**（`takeoffAGL > 0` / `landingAGL > 0`），
    //       **不是**"组装后的 AMSL"：地面海拔会把 `0` 救活 —— 某站点地面海拔 100 米、而航线
    //       起飞高度与站点安全高度**都没设**（都是 0）时，合成的 AMSL 是 100 > 0 ⇒ 闸放行 ⇒
    //       飞机被指令到**贴地 100 米**飞，而这**正是 NRRSM 要杀的症状**。
    //    ‼️ 合成时 `null` 一律按 `0` 计 ⇒ 两个合成量**恒为有限数字**，`null` 不外传。
    //       两个输入都是 `null`（后端没给键）⇒ 合成 0 ⇒ 闸拦住 ⇒ fail-closed；
    //       这与「填了 0（未勘测）」在闸上**同义**，所以合并成 0 不损失分辨力。
    //       （别让 `null` 传播出去：调用方的闸写 `!(x > 0)`，遇 `null` 会走
    //       `null > 0 === false` ⇒ 取反为真 ⇒ 拦住 —— 结论碰巧一样，但那是靠 JS 的
    //       隐式转换，不是靠代码。）
    //    ‼️ D6 合成规则（`max` 那一步）的**单点定义是 `nrrsmEffectiveAGL`**（见其函数头注释）。
    //       本函数这两个键、以及 `OpsRouteSync.qml` 的两个绑定，**都只是它的调用点** ——
    //       改 D6 只改那一个函数，别在这里就地重写 `Math.max`。
    //       要核对当前有哪些调用点，**现场复跑**：在 QGC 仓根跑 `rg -n 'nrrsmEffectiveAGL' src/`。
    //       （⚠️ 本函数这两个键在**生产路径上零读取** —— `OpsRouteSync.qml` 取走的是合成前的
    //        两个原始量，它自己按同一单点定义合成。读这两个键的目前只有单测 `tst_OpsCommon.qml`。）
    function pick(v) {
        if (typeof v !== "number" || !isFinite(v)) return null
        return v
    }
    // `pick` 回 `null` 表示**类型层不可用**。合成交给 `nrrsmEffectiveAGL`（D6 的**单点定义**）：
    // 它内部的 `orZero` 把 `null` / `NaN` / 非数字一并按 `0` 计（口径与本函数原先那个
    // `v === null ? 0 : v` 在**可达输入上等价** —— 这里传进去的已经过 `pick`，非数都成了 `null`）。
    // `null` / `undefined` 入参不得抛错（`route.x` 会 TypeError）⇒ 先归零成空对象。
    var r = route || {}
    var takeoffAltAGL    = pick(r.takeoff_alt_agl)
    var takeoffClearAGL  = pick(r.takeoff_site_clear_alt_agl)
    var takeoffGroundMSL = pick(r.takeoff_ground_msl)
    var landingAltAGL    = pick(r.landing_alt_agl)
    var landingClearAGL  = pick(r.landing_site_clear_alt_agl)
    var landingGroundMSL = pick(r.landing_ground_msl)
    // 终点航点三量（A1）。`end_waypoint_id` 是**可空列**（`route.go` 有两处 UPDATE 会把它置 NULL）
    // ⇒ `pick(null)` 回 `null` ⇒ 调用方落成 `NaN` ⇒ `appendLandingWaypoint` 作废整条（fail-closed）。
    // 后两键后端 `COALESCE(...,0)` ⇒ 键恒存在、无终点时是**数字 0**（不是 `null`）。
    var endWaypointId    = pick(r.end_waypoint_id)
    var endLat           = pick(r.end_waypoint_lat)
    var endLon           = pick(r.end_waypoint_lon)
    return {
        takeoffAltAGL: takeoffAltAGL,
        takeoffClearAGL: takeoffClearAGL,
        takeoffGroundMSL: takeoffGroundMSL,
        landingAltAGL: landingAltAGL,
        landingClearAGL: landingClearAGL,
        landingGroundMSL: landingGroundMSL,
        endWaypointId: endWaypointId,
        endLat: endLat,
        endLon: endLon,
        takeoffAGL: nrrsmEffectiveAGL(takeoffAltAGL, takeoffClearAGL),
        landingAGL: nrrsmEffectiveAGL(landingAltAGL, landingClearAGL)
    }
}

/// NRRSM：把航线的**降落高度**盖到航点序列的**最后一项**上。
///
/// ‼️ 「最后一项」= `items.length - 1`，**不是** `_endWaypointIndex` 那一项。
///    两个「末项」语义不同、这里**故意解耦**：
///      · `_endWaypointIndex`（由 `endWaypointId` 驱动）判的是「终点站，要打 85 垂起着陆」。
///        **裁定 R-A1（2026-10-01）之后它永不触发**：`OpsRouteSync.qml` 那次
///        `OpsCommon.routeMissionItems(landed, vehicle.vtol, undefined, _cruiseAGL)`
///        第三个实参**刻意传 `undefined`**（理由见 `_endWaypointIndex` 的函数头注释）；
///      · 本函数的「最后一项」判的是「末段降落的进入点」，与 command 无关。
///    ⇒ 两个「末项」**故意解耦**，且 R-A1 下 `_endWaypointIndex` 那一支恒为 `-1` ⇒
///      **「本函数改哪一项」与该支无关**（恒为 `items.length - 1`，与上面那句一致）；85 由
///      `routeMissionItems` 自己打出，**不需要**把两个判据合并。
///    ‼️ **会不会咬人，用这两条充要条件自己判**（下面的情形清单只是**举例**，不是穷举）：
///      · 「会打出 85」 ⟺ 该项 `command === 21` ∧ `i === endIdx` ∧ 机型为 VTOL；
///      · 「本函数的降落高度被覆盖」 ⟺ 上一条成立 **且** 那个 85 正好落在 `items.length - 1` 上。
///    举例（逐情形实测可复跑：`final-fix3-calib.js`）：
///      · **「会打出 85」的充要条件成立**、`end_waypoint_id` 是数字 id 且**恰为末项**（常规）：打出 85、且就落在末项 ⇒
///        本函数逐字保留 `last.command` ⇒ 高度被 PX4 的 `handleLanding` 覆盖 ⇒ **静默失效**；
///      · **「会打出 85」的充要条件成立**、`end_waypoint_id` 是数字 id 但**不是末项**：打出 85，却落在**航路中途**的一点上 ⇒ 本函数的降落
///        高度**不受影响**（红线：除非要坠机，否则飞机只能在机位上降落）；
///      · **指认不出终点**（`undefined` / `null` / `0` / 非数字 / 不在列表里 ⇒ `endIdx === -1`）：
///        **一个 85 都不会产生**，本函数行为照旧。⚠️ 这一档**并不罕见** ——
///        `table_route.end_waypoint_id` 是可空列，且 `route.go` 有两处 UPDATE
///        会在解除航点引用时把它置成 NULL；
///      · 指认得出终点、但**该项 `command !== 21`**（后端对 `end_waypoint_id` 没有
///        「必须指向站点」的校验）：同样**一个 85 都不会产生**。
///      **以上各档都没有任何测试会红。**
///
/// **`items` 为空 ⇒ 原样返回**（没有可覆盖的末项）；不可用的 `amsl`（null / NaN / 非数字）同理。
/// ‼️ 形参名是 `amsl`（**AMSL 组装值** = 该站点地面海拔 + `max(landing_alt_agl, clear_alt_agl)`），
///    与起飞项那个对称的 `_applyAltitude(vi, amsl)` 同名同义。**别再叫回 `landingAltAGL`** ——
///    那个名字在本模块另有所指（`routeAltitudeBounds` 的返回键 = 航线的 `landing_alt_agl`，
///    **真 AGL**），两者同名不同义，读代码的人会把"组装后的绝对高度"当成"航线那个相对高度"。
/// **不改入参**：回新数组，调用方可能还要用原始的 items。
///
/// ‼️ 旧守卫是 `items.length < 2`，理由写的是"只有一个点时它既是起飞又是降落，语义不清" ——
///    **那条前提在 A1 之后已不成立**：起飞项**不在 `items` 里**（它由 `OpsRouteSync.qml`
///    用 `MissionController::insertTakeoffItem()` 单独插进 plan 的第 0 位），
///    `items` 就是**航点序列**，其末项**恒为降落站点航点**（行为 1 追加来的，或行为 2
///    本来就在末位；行为 3 会先回 `[]`，到不了这里）。
///    单点序列（`wps = [X]` 且 `X.id === endWaypointId`）因而不是畸形输入，而是
///    **正常编辑可得到的形状**：云端权威库全量 7 条里**暂无**这个精确形状，
///    但"列表只有一行"是**已存在的正常形状**（航线 21 的列表就只一行 wp4，
///    既非起点也非终点 —— 云端权威库 2026-10-01 复核）⇒ 把唯一那个点选成降落站点，
///    即可得到"一行、且该行就是 `end_waypoint_id`"。**是可达的编辑产物，不是假想输入。**
///    ⚠️ **出处等级**：上面「全量 7 条里暂无该形状」「航线 21 只有一行」两条读数**不是本任务测的**，
///       是**控制方（编排者）2026-10-01 只读实测**；采集口径 = `ssh root@39.97.235.226`、
///       库 `/opt/uavm/var/db_uavm.db`、**只读**打开（`file:...?mode=ro&immutable=1`）、
///       范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
///       **本任务（QGC 仓）无云端凭据，未独立复核。**
///    ⇒ 旧守卫下这种航线的末项高度会**停在航点地面海拔**（不加 `max(landing_alt_agl,
///      clear_alt_agl)`）⇒ 飞机被指令到**贴地**飞；而两道闸读的是 AGL 项 ⇒ **全绿放行**。
///      （用例 `test_singleWaypointChain_lastAltitudeIsAssembled` 与
///       `test_applyLandingAltitude_singleItemIsCovered` 共同钉这一格：前者端到端串链断言
///       末项 = 230、后者断言 `out[0].alt === 999` 并注明旧行为会让它停在 10。）
/// ⚠️ `items` 必须是**普通 JS 数组**（本函数用 `items.slice()`），元素形状与
///    `routeMissionItems` 的输出一致；重建末项时**只保留 5 个键** `{command, lat, lon, alt, frame}`
///    ⇒ 调用方若在元素上挂了额外键，**末项的那一个会静默丢失**。
function applyLandingAltitude(items, amsl) {
    if (!items || !items.length) return items
    if (typeof amsl !== "number" || !isFinite(amsl)) return items
    var out = items.slice()
    var n = out.length - 1
    var last = out[n]
    out[n] = {
        command: last.command,
        lat: last.lat,
        lon: last.lon,
        alt: amsl,
        frame: last.frame
    }
    return out
}

//------------------------------------------------------------------------------
// 起飞点（cmd 84）：按起飞机位朝向偏移
//------------------------------------------------------------------------------

/// 只认**有限数字**。`isFinite("90")` 是 `true`（会强转），所以 `typeof` 前置不可省 ——
/// 少了它，后端若把数字发成字符串就会静默放行，而算出来的点看不出错。
function _finiteNumber(v) { return typeof v === "number" && isFinite(v) }

/// 从任务响应取出**可用的起飞机位朝向**（度）；不可用 ⇒ `null`，调用方据此回落 `home`。
///
/// 读的是后端三个字段 `current_slot_lat` / `current_slot_lon` / `current_slot_heading`
/// （`ops.go` 由 `table_uav.current_slot_id` → `table_slot` 拼好）。
///
/// ⚠️ **只返回朝向，不返回坐标**：起飞点的**起点**是飞机当前 `home`（用户 2026-09-23
///    裁定 c），机位坐标在本功能里**只用来判哨兵**，不参与计算。
///
/// ‼️ 返回 **`0` 是合法结果**（正北）。调用方**必须**用 `!== null` 判"有没有"，
///    **不能**写 `if (heading)` —— `0` 是 falsy，那样会把"正北"当成"没有"，
///    于是恰好朝正北的机位静默回落 `home`。本函数回 `null`（而非 `0`）表示"没有"，
///    就是为了让这个区分**在代码里看得见**。
///
/// ‼️ 哨兵只由**坐标**判定，**不能**拿 `heading === 0` 当"没填"：
///    0° 是正北，是**合法朝向**，而真库 12 个机位的朝向恰恰只有 0 和 1.0 两种取值。
///    把 0 当哨兵 ⇒ 绝大多数机位静默回落 `home`，现象与"这功能根本没做"完全一样，
///    且没有任何一处会报错（`tst_OpsCommon.qml` 有专门一格钉住这一点）。
///
/// ‼️ 坐标**半填**（只有一个 0）同样当无效：中国境内不可能出现经度或纬度为 0 的机位，
///    拿它去偏移会得到一个**看似正常、实际错在地球另一边**的点。
function takeoffSlotHeading(task) {
    if (!task) return null
    var lat = task.current_slot_lat
    var lon = task.current_slot_lon
    var heading = task.current_slot_heading
    if (!_finiteNumber(lat) || !_finiteNumber(lon) || !_finiteNumber(heading)) return null
    // 后端「未指定机位」时下发 0/0/0（`omitempty` 会让字段整个消失 ⇒ 上面的
    // `_finiteNumber` 先拦住，两种"没有"都落到 `null`）。
    if (lat === 0 || lon === 0) return null
    return heading
}

/// 从 `(lat, lon)` 出发、沿 `headingDeg` 方位走 `distM` 米后的落点。
///
/// 方位语义：**0 = 正北，顺时针**（与 `table_slot.heading` 同口径 —— `SiteList.vue`
/// 的「朝向(°)」输入框就是度；也与 Qt 的 `QGeoCoordinate::atDistanceAndAzimuth` 一致）
/// ⇒ **无需任何换算**。
///
/// 用途：起飞点（MAVLink `cmd 84`）的坐标 = `home` 沿**起飞机位朝向**偏移
/// `vtolTransitionDistance` 米。依据是 PX4 的 84 项状态机把 `yaw` 设为
/// 「飞机当前位置 → 84 项坐标」的方位角并 `force_heading=true`
///（`PX4-Autopilot/src/modules/navigator/mission.cpp:365-370`：`:366-368` 把 `yaw` 赋成
///  「飞机当前位置 → 84 项坐标」的方位角，`:370` 再置 `_mission_item.force_heading = true`。
///  ⚠️ 2026-09-29 审查 A6 修正：原注释写 `:365-367`，那只覆盖了 yaw 赋值、**漏掉了
///  `force_heading`**（它在 `:370`）—— 而"朝向能被强制执行"恰恰是这两句合起来的效果。）
/// ⇒ **该坐标就是"起飞后朝哪飞"的唯一决定者**。
///
/// ⚠️ 纯 JS 球面公式（`.pragma library` 文件里**没有 Qt 对象可用**），地球半径取
///    **6371000 m**。离屏探针实测（`/tmp/calib_azimuth.qml`，用 Qt 自己的
///    `atDistanceAndAzimuth` 当权威）：四方位上与 Qt 的最大偏差 3.98e-9 度 ≈ **0.44 mm**，
///    远小于 GPS 精度、也远小于 PX4 的接受半径（`acceptance_radius` 默认 10 m）⇒ 同口径。
///    （反过来说：若误用赤道半径 6378137，四方位上偏 3.02e-6 度 ⇒ `tst_OpsCommon.qml`
///     的 1e-6 度容差会红，见 `_nearDeg` 的注释。）
///
/// 无效输入一律回 `null`（调用方回落 `home`），**不猜**：坐标非有限/越界、
/// 朝向非数字、距离非有限或为**负**。
///   - `distM === 0` 是**合法**输入（偏移 0），原样返回起点；
///   - 朝向可以是任意实数，内部归一化到 [0,360)；
///   - ⚠️ **不处理跨换日线**（算出的经度不会折回 ±180）：本业务的地面站与机位
///     全在中国境内，加一个无人会走到的分支不如不加。
function takeoffTransitionPoint(lat, lon, headingDeg, distM) {
    if (!_finiteNumber(lat) || !_finiteNumber(lon)) return null
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null
    if (!_finiteNumber(headingDeg) || !_finiteNumber(distM)) return null
    if (distM < 0) return null

    var R = 6371000.0
    var d = distM / R
    var brng = (((headingDeg % 360) + 360) % 360) * Math.PI / 180
    var p1 = lat * Math.PI / 180
    var l1 = lon * Math.PI / 180

    var p2 = Math.asin(Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(brng))
    var l2 = l1 + Math.atan2(Math.sin(brng) * Math.sin(d) * Math.cos(p1),
                             Math.cos(d) - Math.sin(p1) * Math.sin(p2))
    return { lat: p2 * 180 / Math.PI, lon: l2 * 180 / Math.PI }
}

/// 「切换到多旋翼」是否**已完成**。`Vehicle::vtolState` 传进来，回的必是布尔。
///
/// 只有 `MAV_VTOL_STATE_MC` 一个取值代表完成；其余四档（未定义 / 转固定翼中 /
/// **转多旋翼中** / 固定翼）都不算。为什么不能改用「机型是不是多旋翼」来判，
/// 见 `MAV_VTOL_STATE_MC` 的注释。
///
/// 非法 / 缺失输入一律回 `false`（不宣布完成）：宁可让操作员看到超时提示，
/// 也不在没有证据时宣布完成 —— 后者会发出一份落在错误状态机上的回航指令，
/// 而界面上一切正常、无人知道出了事。
/// 只认数字类型：字符串 `"3"` 不算（`===` 已排除，但要写明，免得后来者改成 `==`）。
function vtolTransitionDone(vtolState) {
    return typeof vtolState === "number" && vtolState === MAV_VTOL_STATE_MC
}

/// 飞机是否已飞抵**接机机位**（方案 A 的到达判定）。回的必是布尔。
///
/// 用户 2026-09-29 裁定：降落落点从 `home`（= 起飞点）改为**接机机位坐标**。
/// 本函数只回答「飞机到没到那个坐标」这一问，不承担任何后续动作。
///
/// ⚠️ 本函数**当前没有生产调用方**：它原有的两处调用 —— 一处是「转多旋翼后回航」那个
///    函数（已删除），一处是 `_landFlowTick` 的 `"goto"` 支 —— 随降落统一链一起退役
///    （设计稿 §9.8，2026-10-07）。那两处走的是「Guided 飞向坐标 → Guided 降落」那条
///    应用层驱动链，已整条删除；取而代之的是「上传两航点 + 切 AUTO_MISSION」交 PX4 自主。
///    保留本体是因为它是纯函数、且下面这批单测直接钉着它
///    （同 `Vehicle::hoverAndTransitionToMultirotor` 的处理）。
///
///    ‼️ 本注释刻意不写那两个已退役的 Guided 接口名与那个已删函数名 ——
///    `src/OpsView/` 全目录（含注释）对这些名字保持零出现，是 Task 4 的静态判据之一；
///    想知道原先是谁在调它，用 `git log -S` 查那次提交。
///
/// ‼️ 假阳性的代价是不对称的：说"到了"而其实没到 ⇒ 飞机在多旋翼模式下 `AUTO.LAND`
///    是**原地降落**（`PX4-Autopilot/src/modules/navigator/land.cpp` 里唯一的
///    `DO_REPOSITION` 是"中止降落"用的，不是水平接近）⇒ 落在机位之外的任意位置，
///    违反用户 2026-09-28 定的红线「除非要坠机了，否则飞机只能在机位上降落」。
///    反之"没到"的代价只是多盘旋几秒，最后走超时提示。
///    ⇒ **一切存疑输入一律回 `false`**（同一个理由贯穿 `vtolTransitionDone`、本函数、
///      以及后端的 `assign_slot_lat/lon` 三字段哨兵）。
///
/// `slotLat`/`slotLon` 直接吃后端 `opsOverviewItem.assign_slot_lat/lon`：
/// **0/0 是「无可用接机机位」的哨兵**（未指派，或机位已软删 —— 见后端
/// `ops_overview_assign_slot_coord_test.go`），由 `isValidWaypoint` 拦下。
/// ‼️ 别改成"按 `assign_slot_id != null` 判有没有落点"：机位软删时那个 id **仍在**
///    而坐标是 0/0 —— 那样判会让飞机带着目标 (0, 0) 起飞。
///
/// `radiusM <= 0` 也回 `false`，而**不是**"半径 0 表示必须精确重合"：后者在 GPS 噪声下
/// 永不成立 ⇒ 飞机一直盘旋到超时，而界面上显示"正在飞往机位"，与真实故障无法区分。
///
/// 距离口径与本站范围圈**同一个函数**（`_greatCircleM`，R=6371000）：不另写一份，
/// 免得"圈画得下但到不了"这种两套公式才有的形状。
function reachedSlot(lat, lon, slotLat, slotLon, radiusM) {
    if (!_finiteNumber(lat) || !_finiteNumber(lon)) return false
    if (!_finiteNumber(slotLat) || !_finiteNumber(slotLon)) return false
    if (!_finiteNumber(radiusM) || radiusM <= 0) return false
    // 0 哨兵与越界值一并拦下（与包围盒/范围圈同一口径，见 `isValidWaypoint`）。
    if (!isValidWaypoint(lat, lon) || !isValidWaypoint(slotLat, slotLon)) return false
    return _greatCircleM(lat, lon, slotLat, slotLon) <= radiusM
}

// ============================================================================
// 降落端统一框架（设计稿 §9.8）
// ============================================================================
//
// F1 / F2 / F3 三条路 = 两个**正交维度**的三种组合（§9.8.2）：
//
//                 进近方式：保持 FW       先转 MC
//   正常降落       F1「降落」              F2「切换多旋翼降落」
//   救济          （不存在）               F3「MC方式降落」
//
// 「保持 FW + 救济」这一格**不存在**：保持 FW 进近需要一段几百米的直线空间和
// 可预测的航迹，而救济的触发前提恰恰是「位置、姿态、高度都不可预测」
// （用户 2026-10-07 逐字）——两条硬约束互斥。
//
// ‼️ 下面两个函数是这两个维度在**全仓的唯一编码处**。QML 只许调它们，不许在别处
//    再写一份 `kind === "..."` 的判据 —— 否则将来加一条路时，两处判据会各自演化出
//    不同答案。同形的教训见 `OpsView.qml` 的 `_pendingConfirmTitle` 头注：
//    「加了三个 kind 之后，新的三种会静默落进最后那一档」。

/// F1「降落」：保持固定翼进近，落地交 PX4 自主。正常降落（读库、写库）。
var LAND_KIND_KEEP_FW = "keepFwLand"

/// F2「切换多旋翼降落」：先转多旋翼再进近。正常降落（读库、写库）。
///
/// ⚠️ 取值 `"land"` 是**沿用**既有的 `_pendingAction.kind` 字面量，不是新造的名字：
///    历史调用点全部落在 F2 语义上。改这个字面量会让所有既有 case 静默落进 default。
var LAND_KIND_TO_MC = "land"

/// F3「MC方式降落」（救济）：先转多旋翼再进近，**不读库、不写库**（§9.7 定义第 2 条）。
var LAND_KIND_MC_RESCUE = "mcRescueLand"

// ⚠️ 这里**曾经**有一个 `LAND_FW_APPROACH_OFFSET_M = 300`（F1 的进近点偏移量，硬编码）。
//    2026-10-09 用户裁定①把它**移进后端运营常数表**：`vtol_landing_pushout_distance`，
//    初值 400 m，由 `OpsView.qml` 取回后**当实参传进来**（本文件是 `.pragma library`，
//    读不到任何 QML 属性）。
//    ⇒ 本文件**不再持有**这个量的取值，只持有「它该怎么用」。别在这里再加一个同名的硬编码
//      兜底 —— 兜底在 `OpsView.qml` 的 `_onVtolDistancesArrived()`，与后端
//      `handlers/operational_constant.go` 同口径。

/// `MAV_CMD_DO_VTOL_TRANSITION` —— 请求 VTOL 转换。参数 1 是目标状态。
/// 取自 MAVLink 生成的头文件（本仓 `build/_deps/mavlink-build/include/mavlink/`）。
/// ⚠️ 本值与下面要引的 `MAV_VTOL_STATE_*` **不在同一个头文件里**（本次构建实测）：
///    `MAV_CMD_DO_VTOL_TRANSITION` 在 `all/all.h`，`MAV_VTOL_STATE_MC` 在 `common/common.h`。
///    这两份都是**构建产物**，行号会随依赖更新漂移 ⇒ 要核就现搜，别照抄行号。
/// ⚠️ 与 `MAV_VTOL_STATE_*` 同处一族，但**别按数值猜**：`MAV_VTOL_STATE_MC` 是 3 不是 2
///    （2 是 `TRANSITION_TO_MC`，转换途中那一档 —— 发错了就变成"要求它正在转换"）。
var MAV_CMD_DO_VTOL_TRANSITION = 3000

/// 进近方式维度：本 kind 是否「先转多旋翼再进近」。
///
/// F2 与 F3 为真，F1 为假。**未知 kind 回 `false`** —— 这里保守的方向是
/// 「不要擅自转 MC」：转 MC 是不可逆的机体动作，而"不转"最坏只是航线不合预期。
function landKindTransitionToMc(kind) {
    return kind === LAND_KIND_TO_MC || kind === LAND_KIND_MC_RESCUE
}

/// 统一链第 ① 步（§9.8.4）：由 kind、机位坐标、以及（仅 F1）**飞机**的位置与航向
/// 算出**落点与进近点**。
///
/// 落点恒为**接机机位**（§9.7 定义第 1 条：无条件 ≠ 随便落）。
/// 进近点 P 随进近方式变：
///   先转 MC（F2/F3）⇒ **P = 机位同坐标**（§9.7 三次实测 #2/#3/#4）
///   保持 FW（F1）  ⇒ **P = 飞机当前位置沿飞机当前航向偏 `pushoutM` 米**（2026-10-09 用户裁定①）
///
/// ‼️ F1 的原点与方位**在 2026-10-09 变了**：改前是「机位沿**机位朝向**偏 300 m」，
///    改后是「**飞机**沿**飞机航向**偏 `pushoutM`」。改变的目的不是几何本身 ——
///    飞机在接机机位附近做**小半径盘旋**时，旧口径算出的 P 可能落在盘旋圈**内**，
///    航线第一条腿不足以把它从盘旋中改出；新口径把 P 摆在飞机正前方几百米处，
///    第一条腿就**把飞机从盘旋中拉直**、留出转弯半径（用户 2026-10-09 逐字口径）。
///    ⇒ 「P 从哪来」这一维的取值来源**同时换了原点、方位、距离**三者，不是只换距离。
///
/// ⚠️ **机位朝向（`table_slot.heading`）从此不再参与降落**：
///    F2/F3 按 §9.5.9 第 1、2 条本来就不读朝向，F1 改后改读**飞机**航向
///    ⇒ 旧的 `slotHeadingDeg` 形参已删。
///    ‼️ **订正（2026-10-10 审查 C-1）**：这里原写「后端仍在下发 `assign_slot_heading`，
///    那字段现在只有**起飞端**（`takeoffSlotHeading()`）在消费」—— 那句话**两半都错**：
///      · `takeoffSlotHeading()` 读的是 `task.current_slot_heading`（见上面那个函数），
///        与本字段是**两个不同的字段**；
///      · `assign_slot_heading` 在 QGC 仓里**只写不读**。它唯一的出现是 `OpsView.qml` 的
///        `_taskWithSlot`（往传给 `_execLand`/`_startLandFlow` 的临时副本上盖值），
///        而**那个副本的唯一读者就是本函数的第四个实参** —— 随本次改动被删掉了
///        ⇒ 该字段已成死数据（`OpsView.qml` 那处写入 2026-10-10 一并删除）。
///    ⚠️ 后端仍在响应体里下发它（`gcs_server/handlers/ops.go:157`）—— 那是**下行字段**，
///      与本条无关，别把它读成"还有人在消费"。
///    留这段订正而不是直接删句：下一个人若在别处撞见 `assign_slot_heading`，
///    需要知道它**已经没有消费方**，而不是去 `takeoffSlotHeading` 里找一个不存在的调用。
///
/// `fwOrigin` = `{ lat, lon, headingDeg, pushoutM }`，**只有 F1 读它**：
///    · `lat` / `lon` —— 飞机当前位置（QML 侧读 `vehicle.coordinate`），
///    · `headingDeg` —— 飞机当前航向（QML 侧读 `vehicle.heading.value`），
///    · `pushoutM`   —— 推远距离，来自运营常数 `vtol_landing_pushout_distance`。
/// ⚠️ **F2/F3 那两支不读它**（函数体里在碰 `fwOrigin` 之前就 `return` 了）——
///    所以「F2/F3 该传什么」**不是**一份契约，传 `null`、传真对象、传垃圾都行。
///    ‼️ 调用方 `_startLandFlow` 因此**无条件**构造它再传进来，**没有** `kind === ...` 判据：
///    在这里写一份"哪种 kind 需要飞机状态"的判据，等于把本文件钉成全仓唯一编码处的
///    那个维度**再写一遍**（本函数头注 + `landKindTransitionToMc` 那条规矩）。
///    ⇒ 别把本行改回「F2/F3 传 `null`」那种**读起来像要求**的措辞：调用点不遵守它，
///      而"两条判据各自演化"正是上面那条规矩要防的事。
///
/// 回 `{ lat, lon }`；kind 未知、或 F1 的 `fwOrigin` 不可用时回 `null`。
///    F1 下 `fwOrigin` 的三条闸（缺一不可，任一不过都回 `null`）：
///      ① 坐标 —— 走 `isValidWaypoint`（**不是** `coordinate.isValid`：那个对 (0,0) 为真）；
///      ② 航向 —— 有限数即可，**判不出「没填」**（见下）；
///      ③ 距离 —— 有限且 **> 0**。`takeoffTransitionPoint` 把 `distM === 0` 当**合法**
///         （起飞端确实需要「偏移 0」这一档），但**降落端不是**：`pushoutM === 0` 会让
///         P 落在飞机正上方 ⇒ 航线第一条腿零长度 ⇒ 恰好退回本改动要消灭的那个形状，
///         而且**全程静默**（PX4 照收、界面无痕）⇒ 必须在这里挡掉。
///
/// ‼️ **航向没有「存活」判据，这是刻意的、也是本函数唯一一处"看不出来"的地方。**
///    `VehicleFactGroup` 的 `heading` Fact 没有 `defaultValue` ⇒ 首帧 ATTITUDE 之前
///    `vehicle.heading.value` 就是 `0`，而 `0°` 是**合法正北** —— 两者在数值上**不可分辨**。
///    `OpsCommon.js:2328`（`takeoffSlotHeading` 的注释）已明文禁止拿 `heading === 0` 当"没填"。
///    ⇒ 这里**不假装**能分辨：航向只做"是不是数"这一道，真正的"遥测在不在这架飞机上"
///      由 **①的飞机坐标**代理（坐标有效 ⇔ 已收到过 GPS 位置 ⇔ 链路与遥测在流）。
///      二者不同帧（航向来自 `ATTITUDE`、坐标来自 `GLOBAL_POSITION_INT`），这个代理
///      **不是等价**，只是同一时刻两者同时缺失的概率极低；代价是理论上存在
///      "坐标有效但航向还停在初值 0"的一瞬 ⇒ 那一次算出的 P 会朝正北，
///      而它是**一次有限偏差**、不是静默失败（操作员看得到飞机往哪飞）。
///
/// ‼️ **坐标是不是 0/0 不是本函数的判据**。本函数只回答「由 kind + 机位 + 飞机算出 P」；
///    这个坐标是不是业务上有效的机位，是**调用方**的事 ⇒ `0/0` 对 F2/F3 仍是**合法输入**、
///    原样传出。
///    ‼️ **订正（2026-10-10 审查 I-5）：原句写「F3 是救济，零闸」，已被实现推翻。**
///       三条路**都要过** `_startLandFlow` 开头那道**落点**坐标闸（`OpsView.qml` 里
///       `isValidWaypoint(slotLat, slotLon)` 那一段：落点不可用 ⇒ 弹可见的失败、不发航线）；
///       `_execLand` 那条另有一道读库时的闸。说「F3 零闸」会让人以为救济路的坐标可以从
///       任何地方来 —— 事实相反：它恰恰是三条路里**最后**拿到闸的那条
///       （2026-10-08 终局审查 F2 加），因为只有它绕过 `_execLand` 直达本函数。
///       §9.7 逐字「不推演『尚未指派』的中间窗口，本节因此不设『坐标是否为 0』之类的前置
///       校验」说的是**业务状态**判据不该有；而"机位坐标有没有正常取回"是那条裁定赖以
///       成立的**前提**，不是它禁止的东西（完整论证见 `OpsView.qml` 那道闸上方的注释）。
///    ⚠️ 同一批改动里 `tst_OpsLandingCommon.qml` 已把这句话标为「已被推翻」，本行此前是
///       **唯一**没跟上的那一处 ⇒ 三份文件曾并存两套口径。
///    ⚠️ F1 那一支不同：它的**原点**是飞机坐标，而 `0/0` 的飞机不是"未指派"而是"数据错"
///       ⇒ 走上面 ① 的闸、回 `null`。
///    NaN 与越界由 C++ 侧 `QGeoCoordinate::isValid()` 在组 `MissionItem` 时挡 ——
///    那是**输入合法性**，不是业务状态判据，与上面那条分工不冲突。
/// ‼️ **调用方必须把 `null` 当失败处理**，不许拿它去组航线 —— 那会变成 (0,0)。
function landApproachPoint(kind, slotLat, slotLon, fwOrigin) {
    if (kind === LAND_KIND_TO_MC || kind === LAND_KIND_MC_RESCUE) {
        return { lat: slotLat, lon: slotLon }
    }
    if (kind === LAND_KIND_KEEP_FW) {
        if (!fwOrigin) return null
        // 复用起飞端的球面偏移几何（`takeoffTransitionPoint` 只算距离与方位，
        // 与"起飞/降落"的语义无关）—— 变的是**实参从哪来**，几何本身没变。
        // ⚠️ 用 `isValidWaypoint` 而**不是** `isFinite`：飞机坐标为 0/0 时后者放行，
        //    算出的 P 会落在几内亚湾。同一**判据**起飞端也内联写过一份
        //    （`takeoffSlotHeading` 的 `_finiteNumber` + `lat === 0 || lon === 0`）。
        //    ⚠️ 是同一个判据、**不是**同一个函数（2026-10-10 审查 S-5 订正）：
        //      `takeoffSlotHeading` 里**没有** `isValidWaypoint` 的调用，别去那边找。
        if (!isValidWaypoint(fwOrigin.lat, fwOrigin.lon)) return null
        if (!_finiteNumber(fwOrigin.headingDeg)) return null
        if (!_finiteNumber(fwOrigin.pushoutM) || fwOrigin.pushoutM <= 0) return null
        return takeoffTransitionPoint(fwOrigin.lat, fwOrigin.lon,
                                      fwOrigin.headingDeg, fwOrigin.pushoutM)
    }
    return null
}
