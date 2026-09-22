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
    signal handoverCancelRequested(int handoverId)

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
                // ⚠️ 提出方姓名取的是 `modelData.proposed_by_name`（**task** 上的字段），而不是
                //    `card._handover.proposed_by_name`（交接对象上的同名字段）。原代码如此，
                //    本轮抽取**原样搬运**未改——是既有可疑点，不是本次引入的。
                Text {
                    width: parent.width
                    visible: card._handover ? true : false
                    color: card._timedOut ? "#ff3b3b" : "#ffc107"
                    font.pixelSize: 11
                    text: card._handover ? (qsTr("待") + OpsCommon.phaseToLabel(card._handover.phase_to) +
                          qsTr("确认 · ") + (OpsCommon.isMine(card._handover, AuthController.userId) ? qsTr("我提出") : (modelData.proposed_by_name ? modelData.proposed_by_name : "")) +
                          qsTr(" · ") + OpsCommon.remainingSec(card._handover, panel.nowMs)) : ""
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
                    // ── 监控员视图 ──
                    Button {
                        // 仅无 PENDING(LANDING) 交接时可发起（防重复 409；已有交接可走"撤回交接"）
                        visible: !panel.showSiteActions && panel.isRouteMonitor
                                 && modelData.status === "IN_FLIGHT"
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
                        visible: card._handover ? OpsCommon.isMine(card._handover, AuthController.userId) : false
                        height: 24; padding: 0
                        text: qsTr("撤回交接")
                        onClicked: panel.handoverCancelRequested(card._handover.handover_id)
                    }
                }
            }
        }
    }
}
