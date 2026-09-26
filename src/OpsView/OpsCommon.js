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
// 【发出降落指令】永远露不出来。
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

// 入场=本站=降落点：PENDING(LANDING) 待确认 / landing_accepted 已签入待发降落指令 / LANDING 已发降落指令。
function isInbound(task, mySiteId, handoverById) {
    return task.landing_site_id !== undefined && task.landing_site_id !== null &&
           Number(task.landing_site_id) === Number(mySiteId) &&
           (task.status === "LANDING" || pendingPhase(task, "LANDING", handoverById) || landingAccepted(task))
}

// 站点视图的行集合：出站/进站两个勾选框分别过滤
// ‼️ 2026-09-24（裁定 丙-2）：**待我签入的排在最前**。超时是硬性的（10 秒一轮的
//    `scanTimeout`，期限默认 5 分钟），而这条交接混在几十条航班里就是一行 11px 小字
//    ⇒ 排序是「让人来得及动手」的最后一道手段。判据单点在 `awaitingMyCheckin`。
// ⚠️ 是**分桶再拼接**，不是排序函数：一条任务只出现一次（原先 outbound/inbound
//    是 `else if`，改成 `||` 后仍是"收一次"，语义未变），拼接后桶内**保持原顺序**。
function siteTasks(tasks, outbound, inbound, mySiteId, handoverById) {
    var first = [], rest = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        if (!((outbound && isOutbound(t, mySiteId, handoverById)) ||
              (inbound && isInbound(t, mySiteId, handoverById)))) continue
        if (awaitingMyCheckin(t, handoverById)) first.push(t)
        else rest.push(t)
    }
    return first.concat(rest)
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
function markerColor(device, task, nowMs, handoverById) {
    var c = abnormalColor(abnormalKind(device))
    if (c !== "") return c
    if (task) return statusColor(task, nowMs, handoverById)
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
function middleSectionTasks(tasks, selectedRouteId, handoverById) {
    // ‼️ 2026-09-24（裁定 丙-2）：第 1 节除异常之外**再收"待我签入"**（ROUTE 交接等着
    //    监控员接管），理由与 `siteTasks` 同上——超时到期这条交接就作废了。
    // ⚠️ 判据写在**调用 `isAbnormal` 的这里**、**不写进 `isAbnormal` 本身**：那个函数
    //    被 `abnormalKind`/`abnormalColor` 与**地图 marker 着色**共用（见其上方注释），
    //    往里加一条"待签入也算异常"会让地图上的飞机跟着变色。
    // ⚠️ 第 1 节**不受 `selectedRouteId` 过滤**（原有口径，异常航班常驻置顶）；"待签入"
    //    沿用同一口径。此处不会因此多收：`handoverById` 对监控员本就**只含其航线**。
    var seen = {}, out = []
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i]
        if (!isAbnormal(t) && !awaitingMyCheckin(t, handoverById)) continue
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
//    （`VehicleMessageList.qml` 那种单机写法，监控员要跨机看），**更不是** `OpsShell.qml`
//    里那个喂仪表的 `_mockVehicle`——那个是 REST `latest` 包装出来的假对象，没有告警。
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
        out.push({ command: mavCmd, lat: lat, lon: lon, alt: alt, frame: MAV_FRAME_GLOBAL })
    }
    return out
}

/// 起飞高度 = **第一个航点的高度**（用户 2026-09-23 裁定 e）。
///
/// 航线不可用 ⇒ `NaN`（**不是 0**）：回 0 会让飞机起飞到"AMSL 0 米"，
/// 而那个数字在界面上看不出错。
/// ‼️ 但**数值 0 是本函数有意放行的**（理由见 `routeMissionItems` 内注释）⇒ 调用方
///    **只判 `isNaN` 是拦不住起飞的**，必须用值域判据。真实调用方
///    `OpsRouteSync.qml` 用的是 `!(takeoffAlt > 0)`（`NaN > 0` 为 false ⇒ 取反为真 ⇒ 拦住）。
function takeoffAltitude(wps) {
    var items = routeMissionItems(wps)
    return items.length ? items[0].alt : NaN
}
