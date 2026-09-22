import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

//==========================================================================
// 航线列表面板（**仅监控员视图 RomView**，设计文档 §4.1 上段）
//
// 与 `TaskListPanel.qml` 同构：只负责"画列表 + 收点击"，一切判据来自**输入属性**，
// 一切动作以**信号**抛出；本文件不持有网络、不读 QML 单例、不认识角色。
//
// ‼️ 这一段的**常驻**是裁定 ③ 的硬约束：**航线永远显示**，不看它有没有航班在飞。
//    所以 model 是 ① 的缓存（`_routeRows`），**不是** ③ 的轮询结果；`active_count`
//    只是行尾的一个数字，为 0 时显示灰字 `0`，**不是**把这一行藏掉。
//    留空会与"这条航线正在加载"分不清——这是设计文档明写的理由。
//
// ‼️ 与任务列表**刻意不同**的一点：本面板的点击是**航线级**（`routeSelected`），
//    任务列表的是**任务级**（`taskSelected`）。两者互不替代，别为了"统一"合并成一个信号。
//==========================================================================
ColumnLayout {
    id: panel
    spacing: 0

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    property var  routes: []            // 骨架的 `_routeRows`（已算好 active_count / has_abnormal）
    property var  selectedRouteId: null // null = 未选中
    property bool ready: false          // ① 是否已经拉到过（区分"空"与"还没回来"）
    property real cardMargin: 10        // 与任务卡同一个左空位，两段天然对齐
    property real cardRightGap: 20
    property real cardGap: OpsCommon.taskCardGap
    property string headerText: ""

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    signal routeSelected(var routeId)

    //-------------------------------------------------------------------------
    // 标题行
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
        id: routeList
        Layout.fillWidth: true
        Layout.fillHeight: true
        // ‼️ 高度**由内容决定**（`contentHeight`），**不在本文件里设上限**：上限是"占右栏多少"
        //    的布局决定，属于使用方的排版，由 RomView 用 `Layout.maximumHeight` 给
        //    （本文件若自己写 `height * 系数`，会与使用方给的高度形成**自引用绑定**）。
        //    内在高度交给布局 ⇒ "只有 4 条航线"时上段只占 4 行，不会把中段挤到底部。
        Layout.preferredHeight: contentHeight
        Layout.topMargin: panel.headerText !== "" ? 4 : 0
        clip: true
        model: panel.routes
        // 左空位（委托宽度里已为它预留，见 delegate）
        leftMargin: panel.cardMargin
        spacing: panel.cardGap

        delegate: Rectangle {
            id: routeCard
            readonly property bool _selected: panel.selectedRouteId !== null &&
                                              Number(panel.selectedRouteId) === Number(modelData.route_id)

            width: routeList.width - panel.cardRightGap - panel.cardMargin
            // 高度＝两行内容 + 7px 留白。**7 不是随手写的**：实测（pixelSize 12/13 字体下）
            // 旧单行卡恰为 28px，+6 得 41（1.46×），+7 得 **42 = 28×1.5**，正好是用户
            // 2026-09-23 要的"1.5 倍"。改字号/内边距后这个比例会变，需重量。
            height: cardBody.implicitHeight + 7
            radius: 4
            color: "#16233c"
            border.width: 1
            border.color: routeCard._selected ? "#2f6bd8" : "#2a3a55"

            // 点整行 ⇒ 选中该航线（再点一次是取消，由骨架的 `selectRoute` toggle）
            MouseArea {
                anchors.fill: parent
                onClicked: panel.routeSelected(modelData.route_id)
            }

            // 两行：上行是**元信息与状态**（代号 + 异常标记 + 活跃数量），
            // 下行是**航线名**独占一行。原来四个控件挤在一行里，航线名被左右夹住、
            // 稍长就省略号，等于把最该看清的信息压在最窄的位置。
            ColumnLayout {
                id: cardBody
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                anchors.leftMargin: 8; anchors.rightMargin: 8
                spacing: 2

                // ---- 上行 ----
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    // 该航线有异常航班 ⇒ 警示标记（判据在后端/骨架算好，此处只画）
                    Text {
                        visible: modelData.has_abnormal
                        color: "#ff3b3b"; font.pixelSize: 12; font.bold: true
                        text: "⚠"
                    }
                    // 航线代号（灰字，等宽感知的编号位）
                    Text {
                        color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
                        text: modelData.route_code ? modelData.route_code : ("#" + modelData.route_id)
                    }
                    // 弹簧：把活跃数量推到最右
                    Item { Layout.fillWidth: true }
                    // 活跃飞机**数量**（裁定 ③ 原话：「后面显示飞机的数量」——是数量，不是徽标列表）
                    // ⚠️ 0 也要显示（灰字），**不是**留空：留空会与"这条航线正在加载"分不清。
                    Text {
                        color: modelData.active_count > 0 ? "#2ecc71" : "#6b7a90"
                        font.pixelSize: 12; font.bold: true
                        text: qsTr("活跃 ") + modelData.active_count
                    }
                }

                // ---- 下行：航线名（主信息，独占整行宽度）----
                Text {
                    Layout.fillWidth: true
                    color: "#e6edf7"; font.pixelSize: 13
                    elide: Text.ElideRight
                    text: modelData.route_name ? modelData.route_name : "—"
                }
            }

        }

    }

    // 空态 / 加载态。**必须分开**：`ready` 为 false 是"还没拉到"，为 true 而列表为空
    // 是"确实没被指派负责航线"。两者在界面上长得一样的话，一个失败的请求与一个
    // 真的没有航线的监控员就无法区分（§2.1 的 `_routeCacheReady` 就是为这个存在的）。
    // ⚠️ 这一段是 ListView 的**兄弟**，不是子项——ListView 的子项会被 reparent 到
    //    `contentItem`，`anchors.centerIn: parent` 会以内容项为父（高度可能为 0）而错位。
    Text {
        Layout.fillWidth: true
        Layout.topMargin: 14
        Layout.leftMargin: 12; Layout.rightMargin: 12
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: "#8fa1bd"; font.pixelSize: 12
        visible: panel.routes.length === 0
        text: panel.ready ? qsTr("未被指派负责航线") : qsTr("航线加载中…")
    }
}
