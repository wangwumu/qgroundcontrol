import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "."
import "OpsCommon.js" as OpsCommon

/// 备降选点弹窗（2026-11-09，《备降选点-设计稿》§7）。只负责展示与选择，不发请求。
///
/// 与回航弹窗的两处结构性差异：
///   · 行来源是 `candidates.candidates`（后端已按距离排序、已过滤不可用场地），
///     不是 `candidates.waypoints`（那条是**本航线全部航点**，回航才需要）；
///   · 每行带**类别色块 + 类别中文**，以及第三列「沿原航线 / 直线可达」。
///
/// ‼️ 信号名**不叫** `accepted` / `cancelled`：`OpsDialog` 继承自 `Dialog`，而
///    `Dialog` 自己就有 `accepted()` / `rejected()`。在派生组件里声明同名信号会与基类
///    信号冲突（连接落空、编译期也可能报重复定义），故用 `waypointAccepted` /
///    `waypointCancelled` 这两个不撞名的。
OpsDialog {
    id: root
    title: qsTr("选择备降点")

    /// `GET /divert-candidates` 的完整响应。
    property var candidates: null
    /// 任务对象（overview 里的一项），只用于标题行。
    property var task: null
    /// 当前选中那一行的 `seq`（后端数组下标，唯一键）；`< 0` 表示未选。
    /// ‼️ 不能用 `waypoint_id`：同一航点可被多条航线引用，也可能在同一批候选里重复出现。
    property int selectedSeq: -1
    property bool busy: false

    signal waypointAccepted(int seq)
    signal waypointCancelled()

    // 宽度按现有 OpsDialog 实例的规则折算：内容基线 × 字号因子。
    width: Math.round(520 * ScreenTools.uiTextScaleFactor)
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
                  ? qsTr("任务 %1 · 航线 %2")
                        .arg(root.task.task_no || "—")
                        .arg(root.task.route_name || "—")
                  : ""
        }

        // 飞机已偏离本航线：本航线候选按**直达**构造（设计稿 §5.2 B11）。
        // 这句话必须常驻——否则用户会以为"本航线"那一行仍会沿原航线飞。
        Text {
            Layout.fillWidth: true
            visible: root.candidates ? root.candidates.departed === true : false
            color: "#ffca28"
            font.pixelSize: Math.round(12 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: qsTr("飞机已偏离原航线：所有候选都将按直线直达")
        }
        // 本航线数据降级（快照/版本问题）：候选仍然可用，但「本航线」这一类是空的。
        Text {
            Layout.fillWidth: true
            visible: root.candidates && root.candidates.degrade_reason
            color: "#9fb3d4"
            font.pixelSize: Math.round(12 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: root.candidates ? qsTr("本航线数据暂不可用（%1），仅显示其它航线候选")
                                      .arg(root.candidates.degrade_reason) : ""
        }

        // 用 `QGCListView` 而不是裸 `ListView`：裸 ListView 不画滚动条（同一坑见
        // `TaskListPanel.qml` 的注释）。
        QGCListView {
            id: _list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 320)
            clip: true
            // 「由近及远」由**后端**排好（`divert_candidates.go` 的 `sort.SliceStable`，
            // 同距离按 site_id 升序）；前端再排一次会引入第二份口径。
            model: root._rows()
            delegate: ItemDelegate {
                width: _list.width
                enabled: modelData.landable !== false
                opacity: modelData.landable === false ? 0.45 : 1.0
                onClicked: root.selectedSeq = modelData.seq
                background: Rectangle {
                    color: root.selectedSeq === modelData.seq ? "#1f4a45" : "transparent"
                    radius: 4
                }
                contentItem: RowLayout {
                    spacing: 10
                    // 类别色块：绿=本航线、蓝=名册航线、橘黄=其它（色值单点在 OpsCommon.js）
                    Rectangle {
                        // 在 RowLayout 里必须用 Layout.preferred*：直接设 width/height 是
                        // undefined behavior（qmllint Quick.layout-positioning）。
                        Layout.preferredWidth: 12
                        Layout.preferredHeight: 12
                        radius: 3
                        color: OpsCommon.divertCategoryColor(modelData.category)
                    }
                    ColumnLayout {
                        spacing: 2
                        Text {
                            color: "#e6edf7"
                            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
                            text: modelData.site_name || ("#" + modelData.site_id)
                        }
                        Text {
                            color: "#9fb3d4"
                            font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                            text: (modelData.category_zh || modelData.category || "")
                                  + " · " + (modelData.waypoint_name || "")
                        }
                        // 「到站可能无人接引」是**标注**不是过滤（2026-11-09 用户裁定）：
                        // 备降时距离优先，缺操作员的场地照样可选，但必须让人看见。
                        Text {
                            visible: modelData.receivable === false
                            color: "#ffca28"
                            font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                            text: modelData.receivable_reason
                                  || qsTr("该场地未配置站点操作员，到站后可能无人接引")
                        }
                    }
                    Item { Layout.fillWidth: true }
                    ColumnLayout {
                        spacing: 2
                        Text {
                            Layout.alignment: Qt.AlignRight
                            color: "#e6edf7"
                            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
                            text: root._fmtM(modelData.distance_m)
                        }
                        // 第三列：航线形态标注（「沿原航线」/「直线可达（未评估）」/「已偏离」）。
                        Text {
                            Layout.alignment: Qt.AlignRight
                            color: "#9fb3d4"
                            font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                            text: OpsCommon.divertRouteNote(modelData,
                                                            root.candidates
                                                                ? root.candidates.departed === true
                                                                : false)
                        }
                    }
                }
            }
        }

        Text {
            visible: _list.count === 0
            Layout.fillWidth: true
            color: "#9fb3d4"
            font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
            wrapMode: Text.Wrap
            text: qsTr("附近没有可用的备降场地")
        }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            OpsDialogButton {
                text: qsTr("取消")
                kind: "cancel"
                onClicked: { root.waypointCancelled(); root.close() }
            }
            // 备降是**应急**动作 ⇒ 红（`OpsCommon.confirmButtonKind` 的 danger 档语义）。
            OpsDialogButton {
                text: qsTr("备降")
                kind: "danger"
                enabled: !root.busy && root.selectedSeq >= 0
                onClicked: root.waypointAccepted(root.selectedSeq)
            }
        }
    }

    /// 弹窗展示的行：后端已过滤可用性并排好序，这里只挡掉 `seq < 0` 的异常行。
    /// model 与「有没有行」共用它——两处各算一遍会漂移。
    function _rows() {
        if (!root.candidates || !root.candidates.candidates) return []
        return root.candidates.candidates.filter(function (c) { return c.seq >= 0 })
    }

    function _fmtM(m) {
        if (!m && m !== 0) return "—"
        return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"
    }

    /// 每次打开重置选择态：上一次选中的点在新列表里可能已不存在（409 重拉）。
    onOpened: selectedSeq = -1
}
