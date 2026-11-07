import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "."

/// 回航选点弹窗（2026-11-07，设计稿 §6.1）。只负责展示与选择，不发请求。
///
/// ‼️ 信号名**不叫** `accepted` / `cancelled`：`OpsDialog` 继承自 `Dialog`，而
///    `Dialog` 自己就有 `accepted()` / `rejected()`。在派生组件里声明同名信号会与基类
///    信号冲突（连接落空、编译期也可能报重复定义），故用 `waypointAccepted` /
///    `waypointCancelled` 这两个不撞名的。
OpsDialog {
    id: root
    title: qsTr("选择回航降落点")

    /// `GET /return-candidates` 的完整响应。
    property var candidates: null
    /// 任务对象（overview 里的一项），只用于标题行。
    property var task: null
    /// 当前选中那一行的 `seq`（后端数组下标，唯一键）；`< 0` 表示未选。
    /// ‼️ 不能用 `waypoint_id`：同一航点可被航线引用两次（后端不去重），按 id 选会
    ///    「点近的那行、退到远的那次」。
    property int selectedSeq: -1
    property bool busy: false

    signal waypointAccepted(int seq)
    signal waypointCancelled()

    // 宽度按现有 OpsDialog 实例的规则折算：内容基线 × 字号因子（字号放大后宽度不跟着变
    // 会让内容与留白比例失衡）。
    width: Math.round(480 * ScreenTools.uiTextScaleFactor)
    modal: true
    // 必须由用户显式选择或取消：点框外关闭会让「选了但没确认」留下一个悬空的选择态。
    closePolicy: Popup.NoAutoClose

    ColumnLayout {
        // `Dialog.contentItem` 缺省宽度不跟弹窗走；不显式给宽度，布局会按 implicitWidth
        // 收窄、比弹窗窄一截，右侧留白随内容跳动。
        width: parent.width
        spacing: 10

        Text {
            Layout.fillWidth: true
            color: "#e6edf7"
            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: root.task
                  ? qsTr("任务 %1 · 航线 %2 · 已飞 %3")
                        .arg(root.task.task_no || "—")
                        .arg(root.task.route_name || "—")
                        .arg(root._fmtM(root.candidates ? root.candidates.flown_distance_m : 0))
                  : ""
        }

        // 用 `QGCListView` 而不是裸 `ListView`：裸 ListView 不画滚动条（同一坑见
        // `TaskListPanel.qml` 的注释）。
        QGCListView {
            id: _list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 320)
            clip: true
            // 「由近及远」（设计稿 §6.1）：后端按**航线顺序**返回，排序在这一侧做。
            // ⚠️ `filter` 已返回新数组，再 `sort` 不会原地改 `candidates.waypoints`；
            //    直接对原数组排序会让下一次打开弹窗继承上一次的排列。
            model: root._rows()
            delegate: ItemDelegate {
                width: _list.width
                enabled: modelData.landable
                opacity: modelData.landable ? 1.0 : 0.45
                onClicked: root.selectedSeq = modelData.seq
                background: Rectangle {
                    color: root.selectedSeq === modelData.seq ? "#1f4a45" : "transparent"
                    radius: 4
                }
                contentItem: RowLayout {
                    spacing: 10
                    Rectangle {  // 红/绿圆点：只表达「此刻能不能降」
                        // 在 RowLayout 里必须用 Layout.preferred*：直接设 width/height 是
                        // undefined behavior（qmllint Quick.layout-positioning）。
                        Layout.preferredWidth: 12
                        Layout.preferredHeight: 12
                        radius: 6
                        color: modelData.landable ? "#4caf50" : "#ff6b6b"
                    }
                    ColumnLayout {
                        spacing: 2
                        Text {
                            color: modelData.landable ? "#e6edf7" : "#9fb3d4"
                            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
                            text: modelData.site_name || ("#" + modelData.site_id)
                        }
                        Text {
                            visible: modelData.name && modelData.name !== modelData.site_name
                            color: "#9fb3d4"
                            font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                            text: modelData.name + " · " + modelData.kind
                        }
                        // 设计稿 §6.1 写的是「悬停显示 landable_reason」。这里改成**常驻**：
                        // 触屏（Android）没有 hover，悬停提示在这些设备上等于不存在；不可用项
                        // 本该让人一眼看出原因。
                        Text {
                            visible: !modelData.landable && modelData.landable_reason
                            color: "#ff6b6b"
                            font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                            text: modelData.landable_reason
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        color: "#e6edf7"
                        font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
                        text: root._fmtM(modelData.distance_m)
                    }
                }
            }
        }

        // 列表为空（没有已飞过的关联站点）与「有候选但**全部**不可降」是两件事：
        // 后者列表非空、红点一排，如果只说「没有可降落的站点」会与屏幕上的行矛盾。
        Text {
            visible: _list.count === 0
            Layout.fillWidth: true
            color: "#9fb3d4"
            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: qsTr("来路上没有可降落的站点")
        }
        Text {
            visible: _list.count > 0 && !root._hasLandable()
            Layout.fillWidth: true
            color: "#ff6b6b"
            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: qsTr("来路上的站点此刻都不可降落，请稍后再试或联系场地操作员")
        }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            // 2026-11-07 用户裁定：回航是**正常业务流程**（不是应急/救济）⇒ 绿；取消 ⇒ 白。
            OpsDialogButton {
                text: qsTr("取消")
                kind: "cancel"
                onClicked: { root.waypointCancelled(); root.close() }
            }
            OpsDialogButton {
                text: qsTr("回航")
                kind: "primary"
                enabled: !root.busy && root.selectedSeq >= 0
                onClicked: root.waypointAccepted(root.selectedSeq)
            }
        }
    }

    /// 弹窗展示的行：有站点 + 已飞，按距离由近及远。
    /// model 与「有没有可降落的行」共用它——两处各算一遍会漂移。
    function _rows() {
        if (!root.candidates || !root.candidates.waypoints) return []
        return root.candidates.waypoints
                .filter(function (w) { return w.site_id > 0 && w.flown })
                .sort(function (a, b) { return a.distance_m - b.distance_m })
    }

    function _hasLandable() {
        var rows = _rows()
        for (var i = 0; i < rows.length; i++)
            if (rows[i].landable) return true
        return false
    }

    function _fmtM(m) {
        if (!m && m !== 0) return "—"
        return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"
    }

    /// 每次打开重置选择态：上一次选中的点在新列表里可能已不存在（409 重拉）。
    onOpened: selectedSeq = -1
}
