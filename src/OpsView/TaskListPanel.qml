import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

//==========================================================================
// 任务列表面板（OpsView / RomView 共用）
//
// 只负责"画列表 + 收点击"：一切判据来自**输入属性**或 `OpsCommon` 纯函数，
// 一切动作以**信号**抛出，本文件不持有网络、弹窗、机位、地图。
//
// 三类输入的来路不同，别混：
//   ① 纯函数判据 → `OpsCommon`，实参显式传入 ⇒ 绑定依赖落在调用点的实参表达式上；
//   ② 依赖 QML 单例的判据（`multiVehicleManager` 在线、机位占用）→ **注入的函数属性**
//      `canTakeoffFn` / `takeoffBlockReasonFn`——`.pragma library` 里读不到单例；
//   ③ 视图状态（选中项、本站、时间）→ 普通属性。
//
// ‼️ 卡片宽度里为左空位**预留**，让位靠 `ListView.leftMargin` —— 纵向 ListView 会把
//    委托的 `x` 压回 **0**，写 `x:` 让位会**静默失效**（宽度是少了、位置却没动 ⇒ 空位
//    全长到右边，正好与要求相反）。见下方两个 ListView 上的 `leftMargin`。
//==========================================================================
ColumnLayout {
    id: panel
    spacing: 0

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    property var    tasks: []
    property var    handoverById: ({})          // {task_id: handover}，仅 PENDING
    property real   nowMs: 0                    // 由视图的 1s Timer 驱动（倒计时/超时/遥测新鲜度）
    property int    mySiteId: -1
    property int    selectedTaskId: -1
    property bool   showSiteActions: false      // 站点视图 ∧ SITE_ATC（出站/进站按钮组）
    property bool   isRouteMonitor: false       // 监控员视图（移交降落指挥）
    property real   cardMargin: 10              // 卡片左空位；站点视图传机位左空隙，与之对齐
    property real   cardRightGap: 20
    property real   cardGap: OpsCommon.taskCardGap
    property real   liveTelemetryWindowMs: 15000
    property string headerText: ""              // 空串则标题行整行不占位（站点视图）

    // 注入的求值函数：依赖 multiVehicleManager / 机位，无法纯函数化。
    // 传 null 时按钮**置灰且提示为空**（fail-closed），不会误放行。
    property var    canTakeoffFn: null
    property var    takeoffBlockReasonFn: null

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    signal taskSelected(var task)
    signal takeoffRequested(var task)
    signal landRequested(var task)
    signal parkRequested(var task)
    signal assignSlotRequested(var task)
    signal handoverProposed(int taskId, string phase)
    // `task` 是可选的第二个载荷（用户 2026-09-23 要求取消/撤回也弹窗确认，弹窗里要写出是哪一单）。
    // 消费端写 `function(handoverId)` 少收一个参数是合法的，RomView 因此不必跟着改。
    signal handoverCancelRequested(int handoverId, var task)
    // 回航（用户 2026-09-23 流程规格）：中段飞行卡片上的【回航】。与上面两条一样**只抛信号**——
    // 确认弹窗、写库、下发 RTL 都在视图/后端，本文件不碰网络也不碰载具。
    signal returnRequested(var task)
    // 中段飞行的【签出】（用户规格：「飞机起飞进入 IN_FLIGHT，site_atc 中段的飞行任务卡片变为：
    // 签出、回航」；三个动作都要弹窗确认）。**刻意不复用 `handoverProposed`**：那个信号同时供
    // TAKEOFF 阶段的「申请切出」和监控员视图的「移交降落指挥」使用，而这次只有 IN_FLIGHT 这一格
    // 要加二次确认；挤进同一个信号就得靠"status 是不是 IN_FLIGHT"来分辨该不该弹窗，
    // 两处判据一旦漂移，要么该弹的不弹、要么不该弹的弹。
    signal checkoutRequested(var task)
    // 接收方**签入**（接管）本航班：站点侧签入 LANDING、监控员侧签入 ROUTE。
    // ‼️ 一条信号服务两个相位、**不带相位参数**——相位由 `handoverId` 唯一确定，提交端点
    //    也只有一个（`POST /handovers/:id/accept`，后端自己按 `phase_to` 分支）。加一个
    //    `phase` 参数只会多出一个**可以填错**的自由度，而填错了没有任何东西会报错：
    //    照样 POST 到同一个端点，后端按库里那条记录的**真实**相位处理 ⇒ 参数自带误导性。
    // ‼️ 与 `handoverProposed` 的分工：那个是**提出**交接（带 `phase`，因为提出时库里还没有
    //    这条记录、相位正是要参数化的东西）；这条是**接受一条已存在的**交接，相位已经写在
    //    那行数据上了。
    // `task` 是可选的第二个载荷，理由同 `handoverCancelRequested`（视图侧要写"是哪一单"）。
    signal checkinRequested(int handoverId, var task)

    //-------------------------------------------------------------------------
    // 可选标题（监控员视图「负责航线 · 执行中」）
    //-------------------------------------------------------------------------
    Text {
        Layout.fillWidth: true
        Layout.leftMargin: 12
        Layout.topMargin: 10
        visible: panel.headerText !== ""
        color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
        text: panel.headerText
    }

    ListView {
        id: taskList
        Layout.fillWidth: true
        Layout.fillHeight: true
        // 横向留白一律交给委托（cardMargin / cardRightGap）单点决定：这里原本另有
        // Layout.leftMargin/rightMargin = 8，与委托的 x 叠加后同一张卡在两个视图里会得到
        // 两种左空位（8+10 vs 10）——两个"决定者"。仅标题存在时留出与标题的间距。
        Layout.topMargin: panel.headerText !== "" ? 4 : 0
        clip: true
        model: panel.tasks
        // 左空位（委托宽度里已为它预留，见 delegate）
        leftMargin: panel.cardMargin
        // 卡片间距：不留缝时相邻两张卡各自 1px 的描边直接贴合，看上去是连成一片的
        // 一张卡（选中态那道亮蓝描边尤其明显）。
        spacing: panel.cardGap

        delegate: Rectangle {
            id: card
            // 本卡的 PENDING 交接（无则 undefined）。原文在同一个 delegate 里调了 6 次
            // `_handoverFor(modelData)`，此处抽成一条绑定——纯函数、依赖不变，行为等价。
            readonly property var  _handover: OpsCommon.handoverFor(modelData, panel.handoverById)
            readonly property bool _timedOut: OpsCommon.isTimeout(_handover, panel.nowMs)
            // 中段飞行卡片：本站责任尚未交出去的**在飞**航班。判据复用 `isOutbound`（出站/进站的
            // 同一份），再叠 `IN_FLIGHT`——起飞前那些状态用的是另一组按钮（起飞 / 申请切出）。
            // ‼️ 写成独立属性而不是在三处按钮里各写一遍：按钮组与提示条必须**同源**，
            //    否则会出现"提示条说签出被驳回、按钮却还是起飞那一套"这种自相矛盾的卡片。
            readonly property bool _inFlightOutbound:
                panel.showSiteActions && modelData.status === "IN_FLIGHT"
                && OpsCommon.isOutbound(modelData, panel.mySiteId, panel.handoverById)
            // 签出提示条文案（驳回理由 / 超时说明；其余状态空串 ⇒ 不占位）。单点在 `checkoutNotice`。
            readonly property string _checkoutNotice: OpsCommon.checkoutNotice(modelData)
            // 这条 PENDING 交接是不是**等我动手**（我是签入方）⇒ 警示条加底色/描边。
            // 判据单点在 `OpsCommon.awaitingMyCheckin`（**待办**口径：`handoverById`，
            // 按角色过滤、提出方不在名单里），与置顶用的是**同一条**——两处若各判各的，
            // 就会出现"卡片长着警示条却没被置顶"这种自相矛盾的画面。
            // ⚠️ 不用 `card._handover`（那是**事实**口径，见 `handoverFor` 上方注释）：
            //    它不按角色过滤，站点视图里**同站点的另一个账号**会被误标成"待我确认"。
            readonly property bool _awaitingMe:
                OpsCommon.awaitingMyCheckin(modelData, panel.handoverById)
            // 待我签入的**那一条**交接（**待办**口径，与 `_awaitingMe` 同源）。
            // ‼️ 签入按钮提交的对象必须与它的 `visible` 判据同源，**不能**用 `card._handover`：
            //    后者走**事实**口径（优先任务自带的 `task.handover`），两者正常情况下是同一条
            //    记录，但一旦不是（事实口径还留着上一条已终结的交接），POST 出去的就是**另一个
            //    id**——而 accept 的并发互斥是 `WHERE id=? AND status='PENDING'`，命中 0 行回
            //    404，`_acceptHandover` 又把 404 当成"已被他端处理"**静默吞掉**（那是幂等收口
            //    的正常代价）⇒ 界面表现为"点了签入，什么都没发生、也没报错"。
            readonly property var _myCheckin:
                panel.handoverById ? panel.handoverById[modelData.task_id] : undefined
            // LANDING 交接作废告知（超时）。`isReceiver` 由**视图**决定：LANDING 的接收方恒为
            // 降落机场，而站点视图就是给 SITE_ATC 的 ⇒ `showSiteActions` 即"我是接收方"。
            readonly property string _landingNotice:
                OpsCommon.landingNotice(modelData, panel.showSiteActions)
            // 监控员侧的「尚未接管」提示条（`signedIn` / `checkinNotice` 一族，2026-09-24）。
            // ‼️ 这是**缺口③的前端半边**：改前「移交降落指挥」只判 `status === "IN_FLIGHT"`，
            //    于是飞机还没交到监控员手上时按钮就已可点，而站点侧此刻看到的仍是"责任在
            //    监控员手上"——责任链中间断了一格。补上 `signedIn` 门控之后，未签入的卡片上
            //    **一个可点按钮都没有**（「撤回交接」也不可见：那条交接是起飞机场提的，不是我），
            //    所以必须同时有这条提示，否则就是"警示条喊着待办、却无处下手"的反面——
            //    "什么都没有、也不说为什么"。两个缺口是同一件事的两半，要一起补。
            // ‼️ 第一个参数传 `panel.isRouteMonitor`，**不是** `!panel.showSiteActions`。
            //    两个属性在**当前接线**下取值恰好相反（`OpsView.qml:927` 硬编码
            //    `isRouteMonitor: false`、`RomView.qml` 硬编码 `showSiteActions: false`），
            //    但语义不同：`showSiteActions` 还叠了 `_isSiteATC`（`OpsView.qml:926`）
            //    ——"不是站点按钮组"并不等于"我是监控员"。用语义正确的那个，将来站点视图
            //    真接上双身份时才不会把"我是谁"和"这张卡给我哪套按钮"混成一个判据。
            readonly property string _checkinNotice:
                OpsCommon.checkinNotice(modelData, panel.isRouteMonitor, panel.handoverById)

            width: taskList.width - panel.cardRightGap - panel.cardMargin
            height: taskBody.height + 12
            radius: 4
            color: "#16233c"
            border.width: 1
            border.color: _timedOut ? "#ff3b3b"
                          : (panel.selectedTaskId === modelData.task_id ? "#2f6bd8" : "#2a3a55")

            // 点整项选中任务（视图侧收到 taskSelected 后自行决定是否同步点亮机位）
            MouseArea {
                anchors.fill: parent
                // ‼️ 命中区上下各外扩 `cardGap/2`，把 `ListView.spacing` 的缝**盖满**：
                //    相邻两张卡各分一半（上半→上面那张，下半→下面那张），**无缝、不重叠**。
                //    动机：`Flickable` 在内容溢出时会抢走按下，落在缝上的点击**谁都收不到**；
                //    而溢出时视口已被卡片铺满，那几 px 的缝是右栏**唯一**的落点（2026-09-23 实测）。
                // ✅ 修法已探针验证（`qmltestrunner` + offscreen，含阴性对照）：
                //    · 未扩时缝中点命中 **0** 次（死区），扩后恰好命中 **1** 张卡；
                //    · 缝上半→上一张、下半→下一张，归属正确；
                //    · **拖动零退化**——四格位移（卡片中心/缝 × 未扩/扩后）全等，
                //      因为 `Flickable` 是在 **move** 阶段偷走事件，与 MouseArea 无关。
                // ⚠️ 视觉零变化：MouseArea 不渲染，改动只落在事件几何上。
                anchors.topMargin:    -panel.cardGap / 2
                anchors.bottomMargin: -panel.cardGap / 2
                onClicked: panel.taskSelected(modelData)
            }

            Column {
                id: taskBody
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 8
                spacing: 5
                Row {
                    width: parent.width
                    spacing: 6
                    // 异常航班 ⇒ 置顶徽标。中段表头写着「航班列表 · 异常/待签入置顶」，**被置顶的
                    // 那一行必须自己说明它为什么在顶上**——否则表头在承诺一件界面没做的事。
                    // ‼️ 判据与置顶判据**同源**：`OpsCommon.middleSectionTasks` 用 `isAbnormal`
                    //    挑出第 1 节的异常那些，这里用同一族的 `abnormalKind` 决定写什么 ⇒ 不可能漂移。
                    // ⚠️ 第 1 节的**另一类**（待我签入，2026-09-24 裁定 丙-2 加入）不走这里，
                    //    它自带那条带底色/描边的警示条（`_awaitingMe`）⇒ 顶上的每一行都有交代。
                    // ‼️ 文案与底色都走 §5.3 的**单点定义**（`abnormalLabel` / `abnormalColor`）
                    //    ——这样同一条航班在中段列表里的徽标与地图上它那架飞机的 marker
                    //    恒等色（`markerColor` 的第一步用的就是同一对函数）。
                    // ⚠️ `visible` 判的是 **label 非空**，不是 `isAbnormal`：kind 未知时
                    //    （`abnormalKind` 对未知 type 返回空串）画出来会是一个**没有字的空方框**。
                    //    按 `abnormalColor` 头部的硬约束，未知值**不得兜底成红**（红是迫降语义，
                    //    兜红会让普通告警看着像坠机）；此处连底色一起不画，最干净。
                    // ⚠️ `anchors.verticalCenter` 要写：`Row` **不设子项 y**，不写就顶端对齐
                    //    （见 `qml-row-does-not-set-child-y`）。同 Row 的状态点也是居中的，
                    //    徽标跟着它对齐才不显得掉下去；两侧那几个 `Text` 没写是既有状态，别顺手统一。
                    Rectangle {
                        visible: OpsCommon.abnormalLabel(OpsCommon.abnormalKind(modelData)) !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        width: badgeText.implicitWidth + 6
                        height: badgeText.implicitHeight + 2
                        radius: 2
                        color: OpsCommon.abnormalColor(OpsCommon.abnormalKind(modelData))
                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            // 底色是三色**实心**，字取卡片底色（深）才够对比：
                            // 回航黄 #ffd54f 上写白字会明显发灰，写深色才清楚。
                            color: "#16233c"
                            font.pixelSize: 10; font.bold: true
                            text: OpsCommon.abnormalLabel(OpsCommon.abnormalKind(modelData))
                        }
                    }
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: OpsCommon.statusColor(modelData, panel.nowMs, panel.handoverById)
                    }
                    Text {
                        color: OpsCommon.statusColor(modelData, panel.nowMs, panel.handoverById)
                        font.pixelSize: 12; font.bold: true
                        text: OpsCommon.displayStatus(modelData, panel.handoverById)
                    }
                    Text {
                        color: "#8fa1bd"; font.pixelSize: 11
                        text: qsTr("性质：") + OpsCommon.taskNature(modelData, panel.mySiteId)
                    }
                }
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: modelData.route_name ? qsTr("航线：") + modelData.route_name : qsTr("航线：—")
                }
                Row {
                    width: parent.width
                    spacing: 8
                    // 未指派无人机的任务**整行不可见**（2026-09-17 用户裁定），过滤落在服务端：
                    // `handlers/ops.go` Overview 的**共享 WHERE** 里有 `COALESCE(t.uav_id,0) <> 0`，
                    // 所以本视图正常**只会拿到已派机的任务**，下面 `uav_id` 为假的那一支走不到。
                    // 保留另一支是**断路器**，不是"这类任务会显示"：万一后端过滤被改回去/绕过，
                    // 界面会明说「未指派无人机」，而不是回落显示 task_no 把任务号伪装成航班号
                    //——那正是本视图改前的老行为，也正是用户报障时看到的那一条。
                    // ‼️ 判据用 uav_id（后端 `COALESCE(t.uav_id,0)`，0=未指派），**不用 uav_no 空串**
                    //——与起飞门控、机位反查同解，全视图对「有没有派机」只有一份判据。
                    Text {
                        color: modelData.uav_id ? "#9fb3d4" : "#ffc107"
                        font.pixelSize: 11
                        text: modelData.uav_id
                              ? qsTr("航班：") + (modelData.uav_no ? modelData.uav_no : "—")
                              : qsTr("航班：未指派无人机（%1）").arg(modelData.task_no ? modelData.task_no : "—")
                    }
                    Text {
                        color: "#9fb3d4"; font.pixelSize: 11
                        text: qsTr("起飞：") + OpsCommon.formatPlanTakeoff(modelData)
                    }
                    Text {
                        color: "#9fb3d4"; font.pixelSize: 11
                        text: qsTr("航线性质：") + OpsCommon.routeNature(modelData)
                    }
                }
                // 交接状态徽标
                // 提出方姓名取 `card._handover.proposed_by_name`（**交接对象**上的字段）——
                // 两个来源都带它（`opsHandoverInfo` 与 `/handovers/pending` 的项各有一份，
                // 都是服务端 join `table_user.display_name` 得来的）。
                // ‼️ 原代码写的是 `modelData.proposed_by_name`——**任务项上压根没有这个字段**
                //    （`opsOverviewItem`/`opsRouteTaskItem` 都没有，它只在交接对象里），
                //    故恒为 `undefined`，非本人提出时这一段恒渲染成空串：
                //    徽标成了「待接管确认 ·  · 28s」，**两个角色都一样**，且不报错。
                // ‼️ 2026-09-24（裁定 丙）：**等我动手**那一侧加底色与描边。改前两个角色看到的是
                //    同一行 11px 无底色小字，而「待我确认」是需要立刻行动的状态、混在航班列表里
                //    极易漏掉（超时扫描器 10 秒一轮，人还没看见就已经作废了）；提出方那侧只是在
                //    等，保持原样式——给两边都加底色反而把"该动手的那个人"淹掉。
                // ⚠️ 只加底色/描边/内边距，**不动字号**：任务卡宽度是按最宽的一行定过尺的
                //    （见 `qgc-task-card-row-metrics`），字号一变那一行就会溢出。
                // ⚠️ 高度链必须是 `宽度(外部给定) → Text.contentHeight → Rectangle.height`：
                //    若反过来让 Text 去 anchor 父矩形（fill/verticalCenter），宽依赖高、高依赖宽，
                //    QML 会报 "Binding loop detected" 并让这一块渲染成 0 高。
                Rectangle {
                    width: parent.width
                    height: noticeText.contentHeight + (card._awaitingMe ? 8 : 0)
                    visible: card._handover ? true : false
                    color: card._awaitingMe
                           ? (card._timedOut ? "#4a1414" : "#463a0e")
                           : "transparent"
                    border.width: card._awaitingMe ? 1 : 0
                    border.color: card._timedOut ? "#ff3b3b" : "#ffc107"
                    radius: 3
                    Text {
                        id: noticeText
                        x: card._awaitingMe ? 6 : 0
                        y: card._awaitingMe ? 4 : 0
                        width: parent.width - (card._awaitingMe ? 12 : 0)
                        color: card._timedOut ? "#ff3b3b" : "#ffc107"
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                        text: card._handover ? (qsTr("待") + OpsCommon.phaseToLabel(card._handover.phase_to) +
                              qsTr("确认 · ") + (OpsCommon.isMine(card._handover, AuthController.userId) ? qsTr("我提出") : (card._handover.proposed_by_name ? card._handover.proposed_by_name : "")) +
                              qsTr(" · ") + OpsCommon.remainingSec(card._handover, panel.nowMs)) : ""
                    }
                }
                // 签出提示条（驳回理由 / 超时说明）
                // ‼️ 用户 2026-09-21：「如果航线监控员拒绝签入，那么在站点操作员一侧**必须有明确的
                //    提示功能**，且可以再次签出」——只把按钮变回【签出】是不够的：那与"从未签出过"
                //    长得一模一样，操作员无从知道刚才那次被驳回了、更不能知道为什么。
                // ⚠️ 文案整条由 `OpsCommon.checkoutNotice` 产出（含 `visible` 所依据的空串约定），
                //    本处**不写任何枚举**——界面不得出现裸枚举，状态→中文只有一个映射点。
                Text {
                    width: parent.width
                    visible: card._checkoutNotice !== ""
                    color: "#ff3b3b"
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    text: card._checkoutNotice
                }
                // 降落指挥交接**作废**提示条（超时）。
                // ‼️ 用户 2026-09-24 裁定「双方都告知」：监控员与降落机场 ATC 各有一句，
                //    差别只在"谁该动手"——监控员是提出方（收到的是「请重新发起」），
                //    降落机场是接收方（收到的是「待其重新发起」）。哪一句由 `landingNotice`
                //    的第二个参数决定，本处传 `panel.showSiteActions`。
                // ⚠️ 为什么必须有这条：这条交接一旦被 `scanTimeout` 置 TIMEOUT 就**立刻从接口
                //    里消失**（改前两个下发接口都只出 PENDING），于是"刚超时作废"与"从未发起"
                //    在界面上**完全不可区分**——监控员手上只剩一个【移交降落指挥】按钮，
                //    无从知道刚才那次已经作废。后端为此专门下发了 `landing_state` /
                //    `landing_changed_at`（见 `ops.go` 的 `lastLandingHandover`）。
                // ⚠️ 同样不写任何枚举：状态→中文的唯一映射点在 `OpsCommon.landingNotice`。
                Text {
                    width: parent.width
                    visible: card._landingNotice !== ""
                    color: "#ff3b3b"
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    text: card._landingNotice
                }
                // 监控员：「起飞机场尚未签出」提示条（未签入 ⇒ 本卡片无可执行动作）。
                // ‼️ 颜色取黄（与「待我确认」警示条同族），**不是红**：飞机在航、责任还在起飞机场
                //    是**正常中间态**，不是异常；红在本视图是迫降/超时那一族的语义，用红了会让
                //    每一架刚起飞的航班看起来都像出了事。
                // ⚠️ 四条判据（含"已有 PENDING 等我签入时让位"这条最容易漏的）全部在
                //    `OpsCommon.checkinNotice` 里，本处只按空串约定决定显隐，不写任何判据——
                //    理由同下面两条提示条：判据写成 inline 的话 QML 测试基础设施**测不到**它。
                Text {
                    width: parent.width
                    visible: card._checkinNotice !== ""
                    color: "#ffc107"
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    text: card._checkinNotice
                }
                // 操作按钮行
                Row {
                    width: parent.width
                    spacing: 6
                    // ── 站点视图：出站 ──
                    Button {
                        visible: panel.showSiteActions
                                 && OpsCommon.isOutbound(modelData, panel.mySiteId, panel.handoverById)
                                 && (modelData.status === "SCHEDULED" || modelData.status === "READY")
                        enabled: panel.canTakeoffFn ? panel.canTakeoffFn(modelData) : false
                        height: 24; padding: 0
                        text: qsTr("起飞")
                        // 置灰时说明**差哪一条**：否则用户只看到灰按钮，不知道是要去停放页
                        // 推「航前检查通过」，还是飞机压根还没连上本地面站——两种处置完全不同。
                        ToolTip.visible: hovered && !enabled
                        ToolTip.delay: 300
                        ToolTip.text: panel.takeoffBlockReasonFn ? panel.takeoffBlockReasonFn(modelData) : ""
                        onClicked: panel.takeoffRequested(modelData)
                    }
                    Button {
                        // 6.0-A 申请切出（签出）：起飞经航迹确认后发起 ROUTE 交接；仅巡航(FW)且有实时遥测可切出，
                        // 无遥测置灰（6.0-C 失联不签发；DB 在 Propose ROUTE 时落 IN_FLIGHT=责任里程碑）。
                        visible: panel.showSiteActions && modelData.status === "TAKEOFF"
                                 && !OpsCommon.pendingPhase(modelData, "ROUTE", panel.handoverById)
                        enabled: OpsCommon.isCruising(modelData)
                                 && OpsCommon.hasLiveTelemetry(modelData, panel.nowMs, panel.liveTelemetryWindowMs)
                        height: 24; padding: 0
                        text: qsTr("申请切出")
                        onClicked: panel.handoverProposed(modelData.task_id, "ROUTE")
                    }
                    // ── 站点视图：中段飞行（IN_FLIGHT 且本站仍是责任方）──
                    // 用户 2026-09-23 流程规格：「飞机起飞进入 IN_FLIGHT，site_atc 中段的飞行任务卡片
                    // 变为：签出、回航；选择签出，则签出按钮变为"取消"、"回航"保留；取消/拒绝/超时，
                    // 按钮变为"签出"、"回航"」。⇒ 前两格是**同一个槽位**的两种形态（按 `checkout_state`
                    // 互斥可见），【回航】两种形态下都在。三个动作各自弹窗确认（在视图侧接）。
                    Button {
                        // 签出：与上面「申请切出」是**同一个动作的两个飞行阶段**——TAKEOFF 时后端还要
                        // 连带把状态落成 IN_FLIGHT（起飞那一刻 QGC 未必已收到 VTOL 转换完成），
                        // IN_FLIGHT 时只建交接。所以后端对两态都收，界面按飞行阶段分开显示。
                        visible: card._inFlightOutbound && !OpsCommon.checkoutPending(modelData)
                        height: 24; padding: 0
                        text: qsTr("签出")
                        onClicked: panel.checkoutRequested(modelData)
                    }
                    Button {
                        // 取消：占据签出那一格（同位置换文案/换动作），撤回自己提的那条 PENDING 交接。
                        // `enabled` 取 `handoverId` 而非 `card._handover`：交接有两个来源、字段名不同，
                        // 判"拿得到 id 吗"才是真正的前置条件（见 `OpsCommon.handoverId` 上方注释）。
                        visible: card._inFlightOutbound && OpsCommon.checkoutPending(modelData)
                        enabled: OpsCommon.handoverId(card._handover) !== undefined
                        height: 24; padding: 0
                        text: qsTr("取消")
                        onClicked: panel.handoverCancelRequested(OpsCommon.handoverId(card._handover), modelData)
                    }
                    Button {
                        // 回航：任何状态下都在（用户规格：「选择签出，则……"回航"保留」）。
                        // 落点是**原机位**——不是这里定的，是 `POST /tasks/:id/return` 在一个事务里
                        // 把到站指派改回原机位、释放机位、并把降落指挥权交回本站；QGC 侧在落库成功后
                        // 才发 RTL（先写库、再下指令）。
                        visible: card._inFlightOutbound
                        height: 24; padding: 0
                        text: qsTr("回航")
                        onClicked: panel.returnRequested(modelData)
                    }
                    // ── 站点视图：进站（accept 交接走 handoverDialog，此处无行内确认按钮）──
                    Button {
                        // 6.0-E 发出降落指令：仅已签入(LANDING)（landing_accepted）且 DB 仍 IN_FLIGHT 时出现；
                        // 点按→红绿确认→机位校验→POST /tasks/:id/land（LANDING 唯一写路径）→引导降落。
                        visible: panel.showSiteActions
                                 && OpsCommon.isInbound(modelData, panel.mySiteId, panel.handoverById)
                                 && modelData.status === "IN_FLIGHT" && OpsCommon.landingAccepted(modelData)
                        enabled: modelData.landing_slot_id ? true : false
                        height: 24; padding: 0
                        text: qsTr("发出降落指令")
                        onClicked: panel.landRequested(modelData)
                    }
                    Button {
                        // 指定机位：签入(LANDING)后可预占（后端 AssignSlot 门控 IN_FLIGHT+ACCEPTED LANDING 或 LANDING）
                        visible: panel.showSiteActions
                                 && OpsCommon.isInbound(modelData, panel.mySiteId, panel.handoverById)
                                 && (modelData.status === "LANDING" ||
                                     (modelData.status === "IN_FLIGHT" && OpsCommon.landingAccepted(modelData)))
                        height: 24; padding: 0
                        text: qsTr("指定机位")
                        onClicked: panel.assignSlotRequested(modelData)
                    }
                    Button {
                        // 6.0-B 停泊门控：已落地(landed bit0) 可停泊；有实时遥测未落地→置灰"停泊（待落地）"；
                        // 失联/无遥测→放行"停泊（无遥测）"；均不隐藏，供人工收尾
                        visible: panel.showSiteActions && modelData.status === "LANDING"
                        enabled: OpsCommon.isLandedOnGround(modelData)
                                 || !OpsCommon.hasLiveTelemetry(modelData, panel.nowMs, panel.liveTelemetryWindowMs)
                        height: 24; padding: 0
                        text: OpsCommon.isLandedOnGround(modelData) ? qsTr("停泊")
                              : (OpsCommon.hasLiveTelemetry(modelData, panel.nowMs, panel.liveTelemetryWindowMs)
                                 ? qsTr("停泊（待落地）") : qsTr("停泊（无遥测）"))
                        onClicked: panel.parkRequested(modelData)
                    }
                    // ── 接收方：签入（两个视图共用一格）──
                    Button {
                        // 【签入】= 接管本航班。**站点侧签 LANDING、监控员侧签 ROUTE**，判据同一条
                        // （`_awaitingMe` 走 `/handovers/pending` 的**待办**口径，而那个接口对
                        // SITE_ATC 只发本站 LANDING、对 ROUTE_MONITOR 只发其航线 ROUTE、且提出方
                        // 不在名单里）⇒ 同一格在两个视图里各自指向正确的相位，不需要在这里再判一次
                        // 相位，也就不存在"两份判据漂移"。
                        // ‼️ 这个按钮同时是**缺口②的修法**：待办到达时 `OpsShell._notifyNewPending`
                        //    会自动弹 `handoverDialog`，但那个弹框关掉之后**没有第二次入口**
                        //    （`_seenHandovers` 去重，重新打开不会弹；`Dialog` 默认还允许点框外关闭）
                        //    ⇒ 误关一次就再也签不进来，只能干等交接超时。卡片上这一格是常驻入口。
                        // ⚠️ 与弹框「确认接管」是同一个提交（`/handovers/:id/accept`）、同一条信号
                        //    处理，两个入口**不是**两套逻辑。
                        visible: card._awaitingMe
                        // 取 id 走 `_myCheckin`（待办口径，与 `visible` 同源），不是 `card._handover`
                        //——理由见 `_myCheckin` 上方注释（拿错 id ⇒ 404 被静默吞掉）。
                        enabled: OpsCommon.handoverId(card._myCheckin) !== undefined
                        height: 24; padding: 0
                        text: qsTr("签入")
                        onClicked: panel.checkinRequested(OpsCommon.handoverId(card._myCheckin), modelData)
                    }
                    // ── 监控员视图 ──
                    Button {
                        // 仅无 PENDING(LANDING) 交接时可发起（防重复 409；已有交接可走"撤回交接"）
                        // ‼️ `signedIn` 是 2026-09-24 补的闸（缺口③）：改前只判 `IN_FLIGHT`，
                        //    于是**飞机还没交给监控员时**他就能把降落指挥交给降落机场——责任链
                        //    中间断了一格，而此刻起飞机场侧看到的仍是"责任在监控员手上"。
                        //    本闸与【签入】按钮是**同一个槽位的两种形态**，互斥由判据天然保证：
                        //    `_awaitingMe`（有 ROUTE PENDING 等我签入）⇒ `signedIn` 必为假。
                        //    ⚠️ 不要再补一条 `!card._awaitingMe`：那会造出第二个判据点，
                        //       两处一旦漂移就是"两个按钮同时出现"或"一个都不出现"。
                        // ⚠️ 后端 `Propose` 的 LANDING 分支有同一道闸（防绕过界面直接 POST），
                        //    两处必须同时存在：前端管"看得见/点得动"，后端管"做不做得到"。
                        visible: !panel.showSiteActions && panel.isRouteMonitor
                                 && modelData.status === "IN_FLIGHT"
                                 && OpsCommon.signedIn(modelData)
                                 && !OpsCommon.pendingPhase(modelData, "LANDING", panel.handoverById)
                        height: 24; padding: 0
                        text: qsTr("移交降落指挥")
                        onClicked: panel.handoverProposed(modelData.task_id, "LANDING")
                    }
                    // 撤回/拒绝（提出方或接收方在交接弹框内处理；此处提供撤回）
                    Button {
                        // ‼️ 必须是三元式而不是 `card._handover && OpsCommon.isMine(...)`：
                        // 无交接时 `handoverFor` 返回 undefined，`&&` 直接在**左操作数**上短路，
                        // 整个表达式求值为 undefined（不是 false）；QML 视其为「绑定无值」，
                        // visible 遂退回 Item 默认值 **true** ⇒ 每一张卡片都显示「撤回交接」。
                        // 判据仍与徽标同源，只有「求值成真 bool」这一条不同。
                        // ‼️ 中段飞行卡片上这一格由【取消】占用（同一动作、同一提交对象、同一个
                        //    `/handovers/:id/cancel`），两者都显示就是同一张卡上两个按钮做同一件事。
                        //    ⚠️ 排除写在 `visible` 里、**不是** `height: 0`：隐藏要整个不参与布局，
                        //    高度置 0 的按钮在 `Row` 里仍然占着宽度，会留一段莫名其妙的空档。
                        visible: (card._handover ? OpsCommon.isMine(card._handover, AuthController.userId) : false)
                                 && !card._inFlightOutbound
                        height: 24; padding: 0
                        text: qsTr("撤回交接")
                        // ‼️ 走 `handoverId()` 而不是写死 `.handover_id`：交接现在有两个来源，
                        // 字段名按各自接口的文档约定不同（任务上的用 `id`、pending 项用 `handover_id`），
                        // 写死一个名字就会在换源时静默变 `undefined`。
                        onClicked: panel.handoverCancelRequested(OpsCommon.handoverId(card._handover), modelData)
                    }
                }
            }
        }
    }
}
