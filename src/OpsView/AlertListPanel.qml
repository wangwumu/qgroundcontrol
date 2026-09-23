import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

//==========================================================================
// 机载告警面板（**仅监控员视图 RomView**，设计文档 §6 右栏下段）
//
// 与 `RouteListPanel` / `TaskListPanel` 同构：只负责"画列表"，一切判据来自**输入属性**，
// 本文件不持有网络、不发请求、不认识角色。
//
// ‼️ 数据源是 `QGroundControl.multiVehicleManager.vehicles`（**真实** MAVLink 载具），
//    **不是** `OpsShell.qml` 里那个喂姿态仪的 `_mockVehicle`——后者是 REST `latest`
//    包装出来的假对象，身上根本没有告警。两个 vehicle 概念必须分清（§6.1）。
//
// ‼️ 集合是 `vehicles` 而**不是** ③ 的 `devices[]`：飞机落地转 `PARKED` 后会从
//    `devices[]` 里**消失**，但 QGC 的 Vehicle 不会因此断开（§3.6.2"绝不移出登记
//    集合"）。它此刻若还在发 `STATUSTEXT`，那一行恰恰是监控员最需要看见的。
//    `devices[]` 在本面板里**只用来把 `device_id` 翻译成 `uav_no` 与 `task_no`**，
//    不用来决定"这一行该不该显示"（§6.2 步骤 4）。
//
// ‼️ **不设"清空"按钮**（§6.3）：告警是机载事实，界面不该能删掉它。同理，本面板
//    也不消费 `Vehicle::clearMessages()` / `reset*Messages()`——那是"标记已读"，
//    与这份账本无关。
//==========================================================================
ColumnLayout {
    id: panel
    spacing: 0

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    property var devices: []            // ③ 的 `devices[]`（只用于补 `uav_no` / `task_no`）
    property string headerText: ""
    property int perVehicleLimit: 20    // 每架载具最多取最近多少条（§6.2 步骤 2）
    property int rowLimit: 100          // 合并后的总行数上限（截断**最旧**的）

    //-------------------------------------------------------------------------
    // 真实载具集合
    //-------------------------------------------------------------------------
    // ⚠️ `QmlObjectListModel`（`.count` + `.get(i)`），**不是** JS 数组。
    readonly property var _vehicles: QGroundControl.multiVehicleManager.vehicles

    //-------------------------------------------------------------------------
    // 行集合
    //-------------------------------------------------------------------------
    // ‼️ 这里是**手写赋值**，不是绑定——这是故意的，原因是 `.pragma library`：
    //    `OpsCommon.js` 是库文件 ⇒ `alertRows` **函数体内**读到的 `v.statusTextMessages`
    //    **不注册绑定依赖**。若写成
    //        readonly property var _rows: OpsCommon.alertRows(_vehicles, ...)
    //    这一行会在首次求值之后**再也不重估**——而首次求值时通常一条告警都还没有
    //    ⇒ 界面表现是"这个列表永远空着"，**不报错、不刷新、日志里什么都没有**。
    //
    //    习惯上的解法是往绑定表达式里塞一个令牌（`(_bump, OpsCommon.alertRows(...))`），
    //    但那有两个毛病：触发 `[comma]` 告警，以及把触发条件藏在**隐式的依赖推断**里
    //    ——绑定表达式的依赖是可以被漏掉的（见下），而漏掉的表现同样是"静默地不刷新"。
    //
    //    ⇒ 改为把触发源**显式列全**，一处不多一处不少：
    //        ① 首次求值        —— `Component.onCompleted`
    //        ② `uav_no` 翻译表变了 —— `onDevicesChanged`（`devices` 每轮轮询都会换引用）
    //        ③ 来了新告警       —— 每架载具的 `statusTextMessagesChanged`（经去抖）
    //        ④ 载具**增减**     —— `Repeater.onCountChanged`
    //    ⚠️ ④ 不能省：`_vehicles` 是**同一个** `QmlObjectListModel` 对象、引用永不改变，
    //       所以"对象还在但里面少了一架"这件事，**任何**以 `_vehicles` 为依赖的绑定都看不见
    //       ——载具断开后它的告警会永远留在列表里。
    property var _rows: []

    function _rebuild() {
        panel._rebuildQueued = false
        panel._rows = OpsCommon.alertRows(panel._vehicles,
                                          OpsCommon.deviceIndexByDeviceID(panel.devices),
                                          panel.perVehicleLimit,
                                          panel.rowLimit)
    }

    Component.onCompleted: _rebuild()
    // ② `devices` 是 `property var`、每轮轮询换一个新对象 ⇒ 这里每 2s 会跑一次。
    //    不是浪费：`uav_no` 与 `device_id` 的对应关系本来就可能变，而列表上的机号要跟着变。
    onDevicesChanged: _rebuild()

    /// 合并去抖（③ 的入口）：一次事件循环内的多条告警只触发**一次**重算。
    /// ‼️ 不加这个的话，每架载具每来一条 `STATUSTEXT` 都会重算一次，而每次重算要遍历
    ///    **所有**载具、把每架的**全部**历史消息转成 `QVariantMap`
    ///    （`Vehicle::statusTextMessages` 是全量的——`m_messages` 只增不减）。
    ///    80 架各来一条就是 80 次全量转换，而它们本该是一次。
    property bool _rebuildQueued: false

    function _requestRebuild() {
        if (panel._rebuildQueued) return
        panel._rebuildQueued = true
        Qt.callLater(function() { panel._rebuild() })
    }

    // ⚠️ model 用 `_vehicles.count`（数字）而不是 `_vehicles` 本身：数字 model 的委托里
    //    用 `index`、再 `get(index)` 取对象——这条路径不依赖 `QmlObjectListModel` 作为
    //    `QAbstractItemModel` 时暴露的 role 名（那个没有文档保证），而 `.count` / `.get()`
    //    是本仓 `OpsCommon.js` 一直在用的口径。
    Repeater {
        model: panel._vehicles.count
        // ④ 载具增减。⚠️ 与 delegate 内部无关，写在这里是因为 `count` 变化时
        //    多余的 delegate 可能**先**被销毁 ⇒ 不能靠 delegate 的 `Component.onCompleted`
        //    补算（那只覆盖"接入"，覆盖不了"移除"）。
        onCountChanged: panel._requestRebuild()

        Item {
            id: alertPump
            width: 0
            height: 0
            readonly property var _vehicle: panel._vehicles.get(index)
            Connections {
                // ⚠️ 这里必须写 `alertPump._vehicle`：`Connections` 继承的是 `QtObject`，
                //    它**没有 `parent` 属性**（只有 `Item` 有）⇒ 写 `parent.xxx` 会解析成
                //    `undefined`，而 `target` 为 null 只打印一条运行时告警就过去，
                //    表现就是"列表永远不刷新"。
                target: alertPump._vehicle
                // ③ 新告警到达。⚠️ 是 `messagesChanged` 而**不是** `messageCountChanged`：
                //    后者被 `resetAllMessages()` 清零时也会发，而那时 `m_messages` 一个字都
                //    没变（"标记已读"语义）⇒ 挂错信号会让列表白刷，且真正的清空反倒不发。
                function onStatusTextMessagesChanged() { panel._requestRebuild() }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 固定高度（§6.3："下段固定高度、内部滚动"）
    //-------------------------------------------------------------------------
    // ‼️ 高度**不跟内容走**：告警随时会增加，右栏下段若跟着长，中段的航班列表会被
    //    一行一行地挤扁（上段有 `Layout.maximumHeight` 兜底，中段没有——它是
    //    `fillHeight`，只会把空间让出去）。多出来的行靠内部滚动看。
    //    改这个系数就是改"下段占右栏多高"。
    readonly property real _listHeight: ScreenTools.defaultFontPixelHeight * 15

    //-------------------------------------------------------------------------
    // 标题行
    //-------------------------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 12
        Layout.rightMargin: 12
        Layout.topMargin: 10
        Layout.bottomMargin: 4
        spacing: 6

        Text {
            Layout.alignment: Qt.AlignVCenter
            visible: panel.headerText !== ""
            color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
            text: panel.headerText
        }

        Item { Layout.fillWidth: true }

        // 条数：固定高度 + 内部滚动时，用户无从知道下面还压着多少条。
        Text {
            Layout.alignment: Qt.AlignVCenter
            color: "#5f7391"; font.pixelSize: 11
            text: panel._rows.length > 0 ? String(panel._rows.length) : ""
        }
    }

    //-------------------------------------------------------------------------
    // 列表 + 空态（空态与列表**叠放**：ListView 占满容器，空态居中盖在上面）
    //-------------------------------------------------------------------------
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: panel._listHeight
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 8

        ListView {
            id: alertList
            anchors.fill: parent
            clip: true
            model: panel._rows
            // 与 `RouteListPanel` 的卡缝同宽，右栏两段的疏密一致
            spacing: OpsCommon.taskCardGap
            leftMargin: 0

            delegate: Rectangle {
                id: alertRow

                width: alertList.width
                height: alertBody.implicitHeight + 8
                radius: 3
                color: "#16233c"
                border.width: 1
                border.color: "#2a3a55"

                Column {
                    id: alertBody
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    anchors.margins: 4
                    spacing: 2

                    // 「时间 · 航班号 · 机号 · severity」（§6.3 第一段）
                    // ⚠️ 用 `RowLayout` 而不是 `Row`：`Row` **不设置子项的 y**
                    //    （既有教训 `qml-row-does-not-set-child-y`），三个 Text 里
                    //    有一个是 `bold` ⇒ 隐式高度不同 ⇒ 顶端对齐会看得见地错位。
                    //    显式写 `Layout.alignment` 让垂直居中来决定，不靠"它们高度应该一样"。
                    RowLayout {
                        width: parent.width
                        spacing: 6

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            color: "#5f7391"; font.pixelSize: 10
                            text: panel._timeText(alertRow.modelData)
                        }
                        // 航班号在机号**之前**：告警的主体是"哪个航班出事了"，
                        // 机号是次要的定位信息。
                        // ⚠️ 空串时**整个不画**（`visible` 判空，`RowLayout` 会连间距一起省掉）：
                        //    告警可能来自不在监控清单里的飞机（落地转 PARKED 后从 `devices[]`
                        //    消失），那时查不到航班号——画一个空框比不画更让人困惑。
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: alertRow.modelData ? alertRow.modelData.taskNo !== "" : false
                            color: "#4fc3f7"; font.pixelSize: 10
                            text: alertRow.modelData ? alertRow.modelData.taskNo : ""
                        }
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            color: "#8fa1bd"; font.pixelSize: 10
                            text: alertRow.modelData ? alertRow.modelData.who : ""
                        }
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            color: panel._severityColor(alertRow.modelData ? alertRow.modelData.severity : -1)
                            font.pixelSize: 10; font.bold: true
                            // ‼️ 文案走 `OpsCommon.severityLabel`（**单点定义**，八档→中文四档）：
                            //    界面不得出现裸枚举（既有约束 `ui-no-raw-enum-labels`）。
                            text: OpsCommon.severityLabel(alertRow.modelData ? alertRow.modelData.severity : -1)
                        }
                        Item { Layout.fillWidth: true }
                    }

                    // 告警正文（§6.3 第二段）
                    Text {
                        width: parent.width
                        color: "#d6e0f0"; font.pixelSize: 11
                        text: alertRow.modelData ? alertRow.modelData.text : ""
                        wrapMode: Text.Wrap
                        // 最多两行：固定高度的列表里，一条超长告警不该把整段撑开
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // ‼️ 空态**必须区分**两种原因（§6.3）：两者处置完全不同——"暂无告警"是正常，
        //    "未接引到飞机"要去查链路。混成一句话会让监控员在链路断了的时候，
        //    把界面上的"没有告警"读成"一切正常"。
        //    判据是**真实载具集合为空**，不是 `devices[]` 为空：后者为空但载具还在的
        //    情形是常态（飞机落地转 PARKED），那时列表该显示"暂无告警"而不是这句。
        Text {
            anchors.centerIn: parent
            visible: panel._rows.length === 0
            color: "#5f7391"; font.pixelSize: 11
            text: panel._vehicles.count === 0 ? qsTr("未接引到飞机")
                                              : qsTr("暂无告警")
        }
    }

    //-------------------------------------------------------------------------
    // 展示映射
    //-------------------------------------------------------------------------
    // severity → 文字色。**本面板单点定义**：文案映射在 `OpsCommon.js`（那里必须在，
    // 因为测试要测它），颜色是纯展示、且 `OpsCommon.js` 刻意不碰 QML 相关的东西。
    // 色值与 `RomView` 的陈旧提示条同族（红 `#ff3b3b` / 黄 `#ffc107`），
    // 只是提亮了一档——那两条是**底色**，这里是**深底上的文字**。
    function _severityColor(severity) {
        switch (Number(severity)) {
        case 0:                     // EMERGENCY
        case 1:                     // ALERT
        case 2:                     // CRITICAL
        case 3: return "#ff6b6b"    // ERROR
        case 4: return "#ffc107"    // WARNING
        case 5: return "#4fc3f7"    // NOTICE
        default: return "#8fa1bd"   // INFO / DEBUG / 未知
        }
    }

    /// ISO8601 **UTC** 字符串 → 本地 `hh:mm:ss`。
    /// ⚠️ `new Date(iso)` 解析出的是**绝对时刻**，`Qt.formatTime` 按**本地时区**渲染——
    ///    与 `StatusTextHandler` 里 `formattedText` 那个 `hh:mm:ss.zzz`（也是本地时间）
    ///    口径一致。直接把 ISO 串截断显示会是 UTC，比本地时间少 8 小时（本机时区）。
    /// ⚠️ 无时间戳 / 解析失败时给 `—`：`new Date("")` 是 Invalid Date，
    ///    `Qt.formatTime` 会渲染出 "Invalid Date" 这种字面量。
    function _timeText(row) {
        if (!row || !row.time) return "—"
        var d = new Date(row.time)
        return isNaN(d.getTime()) ? "—" : Qt.formatTime(d, "hh:mm:ss")
    }
}
