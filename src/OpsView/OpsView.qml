import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtLocation
import QtPositioning

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FlightMap
import QGroundControl.Toolbar

/// @brief 飞行监控主界面（站点操作员 SITE_ATC / 航线监控员 ROUTE_MONITOR）
/// 设计见 docs/qgc/飞行监控主界面设计.md。
/// 网络层用 QML XMLHttpRequest + AuthController 会话 token（Bearer），
/// 替代文档 §9 建议的 C++ OpsViewController（功能等价、减少 C++ 层改动）。
Item {
    id: opsView

    //-------------------------------------------------------------------------
    // 会话与身份
    //-------------------------------------------------------------------------
    // 读 roles 属性（NOTIFY rolesChanged）而非 hasRole() 方法：方法调用不注册 QML 绑定依赖，
    // 登录后才填充的 roles 不会触发重估 → 视图永不显示。indexOf 读属性值，登录后绑定自动更新。
    readonly property bool  _isSiteATC:      AuthController.roles.indexOf("SITE_ATC") >= 0
    readonly property bool  _isRouteMon:     AuthController.roles.indexOf("ROUTE_MONITOR") >= 0
    readonly property bool  _isDual:         _isSiteATC && _isRouteMon   // 双身份并存：可切换子视图
    property bool           _showSiteView:   true                        // true=站点视图 false=监控员视图
    readonly property string _apiBase:       AuthController.serverUrl()

    // 供复用组件（FlyViewToolBar 内部 guidedActionMessageDisplay）解析的上下文值，
    // 与 FlyView 定义保持一致；缺省则其内部 _margins 绑定运行时 ReferenceError。
    readonly property real  _margins:       ScreenTools.defaultFontPixelWidth / 2

    //-------------------------------------------------------------------------
    // 数据（轮询刷新；JS 数组整体重建以触发 Repeater 更新）
    //-------------------------------------------------------------------------
    property var  _tasks:          []      // /ops/overview 任务数组（已按角色过滤）
    property var  _pending:        []      // /handovers/pending 待确认交接数组
    property var  _slots:          []      // 本站机位（site_id=_siteIDs[0]）
    property var  _siteIDs:        []      // SITE_ATC 角色站点 id（从任务 site_id 去重）
    property var  _handoverById:   ({})    // task_id -> pending handover
    property var  _seenHandovers:  []      // 已提示过的 handover id（防重复弹框）
    property var  _selectedTaskId: -1
    property var  _confirmHandover: null   // 交接弹框当前对象
    property var  _assignSlotTask: null    // 机位选择弹框当前任务
    property bool  _outbound:      true    // 站点视图勾选：出站
    property bool  _inbound:       true    // 站点视图勾选：进站
    property int   _now:           Date.now()
    // 地图中心跟随：默认跟随首个任务；用户平移地图/点选 marker 后转手动。
    // 手动中心走属性而非直接赋值 opsMap.center —— 直接赋值会破坏 center 绑定，
    // 且 2s 轮询（_tasks 重建）会触发绑定重估把地图拽回首个任务（抢占用户视野）。
    property bool  _mapFollowFirst:  true
    property var   _mapManualCenter: null
    // 喂给原版姿态仪/罗盘组件的 mock vehicle：云平台遥测（/ops/overview.latest）需转成
    // QGC Fact 形（`{rawValue}`），组件 vehicle 为 null 时会显示 0/"OFF"；null 时才不崩，
    // 故提供完整 Fact 契约对象，随一次轮询重建触发组件内部绑定重估。
    property var   _mockVehicle:    null

    // 超时/剩余秒阈值（与后端 OPS_HANDOVER_TIMEOUT 联动；显示用）
    readonly property int _handoverTimeoutSec: 30

    //-------------------------------------------------------------------------
    // 轮询：2s 数据 + 1s 时钟（驱动剩余秒/超时红闪）
    //-------------------------------------------------------------------------
    Timer {
        interval: 2000; repeat: true
        // 门控：仅 OpsView 可见（MainWindow.showOpsView/hideOpsView 切换）且已登录时轮询，
        // 避免切走视图/登出后仍在后台拉接口。
        running: opsView.visible && AuthController.loggedIn
        onTriggered: _poll()
    }
    Timer {
        interval: 1000; repeat: true
        running: opsView.visible && AuthController.loggedIn
        onTriggered: _now = Date.now()
    }

    //-------------------------------------------------------------------------
    // 网络层：XHR + Bearer（仿 PlanUploader 的 Bearer 鉴权方式）
    //-------------------------------------------------------------------------
    function _send(method, path, body, onDone) {
        if (_apiBase === "") {
            console.warn("OpsView: gcs_server 地址未配置")
            return
        }
        var xhr = new XMLHttpRequest()
        xhr.open(method, _apiBase + path)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthController.authToken())
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                var data = null
                if (xhr.responseText && xhr.responseText.length) {
                    try { data = JSON.parse(xhr.responseText) } catch (e) { console.warn("OpsView 响应非 JSON:", xhr.responseText) }
                }
                onDone(xhr.status, data)
            }
        }
        xhr.send(body ? JSON.stringify(body) : null)
    }
    function _get(path, onDone) { _send("GET", path, null, onDone) }
    function _post(path, body, onDone) { _send("POST", path, body, onDone) }

    //---- 接口封装 ----
    function _currentView() {
        // Overview 按视图过滤：双身份并存时随当前子视图切换，单身份固定
        if (_showSiteView && _isSiteATC) return "site"
        return "route"
    }
    function _fetchOverview() {
        _get("/api/ops/overview?view=" + _currentView(), function(status, data) {
            if (status !== 200 || !Array.isArray(data)) { console.warn("OpsView overview", status); return }
            _tasks = data
            _updateMockVehicle()
            var ids = []
            for (var i = 0; i < data.length; i++) {
                var s = data[i].site_id
                if (s && ids.indexOf(s) < 0) ids.push(s)
            }
            _siteIDs = ids
        })
    }
    function _fetchPending() {
        _get("/api/handovers/pending", function(status, data) {
            if (status !== 200 || !Array.isArray(data)) { console.warn("OpsView pending", status); return }
            _pending = data
            var map = {}
            for (var i = 0; i < data.length; i++) map[data[i].task_id] = data[i]
            _handoverById = map
            _notifyNewPending(data)
        })
    }
    function _fetchSlots() {
        if (_isSiteATC && _siteIDs.length) {
            _get("/api/sites/" + _siteIDs[0] + "/slots", function(status, data) {
                if (status === 200 && Array.isArray(data)) _slots = data
            })
        }
    }
    function _poll() {
        if (_apiBase === "") return
        _fetchOverview()
        _fetchPending()
        _fetchSlots()
    }

    //---- 交接动作 ----
    function _proposeHandover(taskId, phaseTo) {
        _post("/api/tasks/" + taskId + "/handover", { phase_to: phaseTo },
              function(status) { if (status !== 200) console.warn("OpsView propose", status) })
    }
    function _acceptHandover(handoverId) {
        _post("/api/handovers/" + handoverId + "/accept", null,
              function(status) { if (status !== 200) console.warn("OpsView accept", status) })
    }
    function _rejectHandover(handoverId) {
        _post("/api/handovers/" + handoverId + "/reject", { reason: "" },
              function(status) { if (status !== 200) console.warn("OpsView reject", status) })
    }
    function _cancelHandover(handoverId) {
        _post("/api/handovers/" + handoverId + "/cancel", null,
              function(status) { if (status !== 200) console.warn("OpsView cancel", status) })
    }
    //---- 机位 / 落地 ----
    function _assignSlot(taskId, slotId) {
        _post("/api/tasks/" + taskId + "/assign-slot", { slot_id: slotId },
              function(status) { if (status !== 200) console.warn("OpsView assign-slot", status) })
    }
    function _landingComplete(taskId) {
        _post("/api/tasks/" + taskId + "/landing-complete", null,
              function(status) { if (status !== 200) console.warn("OpsView landing-complete", status) })
    }
    //---- 起飞/降落（MAVLink guided 指令，需已连接 activeVehicle）----
    function _guidedTakeoff() {
        var v = QGroundControl.multiVehicleManager.activeVehicle
        if (!v) { console.warn("OpsView 起飞：无已连接飞行器"); return }
        v.guidedModeTakeoff(20)
    }
    function _guidedLand() {
        var v = QGroundControl.multiVehicleManager.activeVehicle
        if (!v) { console.warn("OpsView 降落：无已连接飞行器"); return }
        v.guidedModeLand()
    }

    //-------------------------------------------------------------------------
    // 派生/过滤
    //-------------------------------------------------------------------------
    function _handoverFor(task) { return task ? _handoverById[task.task_id] : undefined }
    function _isOutbound(t) { return t.status === "SCHEDULED" || t.status === "READY" || t.status === "TAKEOFF" }
    function _isInbound(t)  { return t.status === "LANDING" || (t.status === "IN_FLIGHT" && _handoverFor(t) && _handoverFor(t).phase_to === "LANDING") }
    function _siteTasks() {
        var out = []
        for (var i = 0; i < _tasks.length; i++) {
            var t = _tasks[i]
            if (_outbound && _isOutbound(t)) out.push(t)
            else if (_inbound && _isInbound(t)) out.push(t)
        }
        return out
    }
    function _routeTasks() { return _tasks }   // overview 已按负责航线过滤 IN_FLIGHT
    function _taskNo(task) { return task ? (task.uav_no ? task.uav_no : task.task_no) : "—" }
    function _statusLabel(s) {
        switch (s) {
        case "SCHEDULED": return "待起飞"; case "READY": return "就绪"; case "TAKEOFF": return "起飞中"
        case "IN_FLIGHT": return "航线中"; case "LANDING": return "降落中"; case "COMPLETED": return "已完成"
        case "ABORT": return "中止"; case "FAILED": return "异常"; default: return s
        }
    }
    function _phaseToLabel(p) { return p === "ROUTE" ? "航线监控" : p === "LANDING" ? "降落指挥" : p }
    function _isMine(handover) { return handover && handover.proposed_by === AuthController.userId }
    function _remainingSec(handover) {
        if (!handover || !handover.deadline_at) return ""
        var deadline = Date.parse(handover.deadline_at)
        if (isNaN(deadline)) return ""
        var sec = Math.ceil((deadline - _now) / 1000)
        return sec > 0 ? sec + "s" : "超时"
    }
    function _isTimeout(handover) {
        if (!handover || !handover.deadline_at) return false
        var deadline = Date.parse(handover.deadline_at)
        return !isNaN(deadline) && _now > deadline
    }
    function _notifyNewPending(list) {
        for (var i = 0; i < list.length; i++) {
            var h = list[i]
            if (_seenHandovers.indexOf(h.handover_id) >= 0) continue
            _seenHandovers.push(h.handover_id)
            _confirmHandover = h
            handoverDialog.open()
        }
    }
    // 地图中心：首个有效任务坐标，否则全局设置位置兜底
    function _firstTaskCoord() {
        for (var i = 0; i < _tasks.length; i++) {
            var t = _tasks[i]
            if (t.latest && t.latest.lat) return QtPositioning.coordinate(t.latest.lat, t.latest.lon)
            if (t.waypoints && t.waypoints.length) return QtPositioning.coordinate(t.waypoints[0].lat, t.waypoints[0].lon)
        }
        return null
    }
    function _statusColor(t) {
        var s = t ? t.status : ""
        if (_isTimeout(_handoverFor(t))) return "#ff3b3b"
        switch (s) {
        case "TAKEOFF": case "IN_FLIGHT": case "LANDING": return "#ffc107"
        case "COMPLETED": return "#2ecc71"
        case "ABORT": case "FAILED": return "#ff3b3b"
        default: return "#3b9cff"
        }
    }

    //-------------------------------------------------------------------------
    // 顶部命令条：原样复用原主界面（FlyView）的 FlyViewToolBar —— Q 标（☰）打开完整
    // 工具菜单（mainWindow.showToolSelectDialog），含主状态/飞行模式/遥测指示器等原始
    // 部件。自定义工具（操作员名/出站进站/双身份切换/锁屏/全屏）叠加在命令条中间空白区，
    // 不再单开右侧栏（原版中间区无 GuidedActionConfirm 时为空，可安全叠放）。
    //-------------------------------------------------------------------------
    Item {
        id: commandBarWrap
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: ScreenTools.toolbarHeight
        opacity: 0.8
        z: 100

        FlyViewToolBar {
            id:                 commandBar
            anchors.fill:       parent
            // OpsView 无引导动作滑杆；GuidedActionConfirm 仅在有引导动作时才显示，置 null 安全
            guidedValueSlider:  null
        }

        // 自定义工具——靠右停放（操作员名 + 出站/进站勾选 + 双身份切换），
        // 锚到最右侧全屏/锁屏按钮组的左边。外层加深色圆角底条，
        // 保证白色文字/白色对勾在命令条浅底上清晰可见。
        Rectangle {
            id: extrasBar
            anchors { right: commandBarWindowButtons.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
            height: ScreenTools.defaultFontPixelHeight * 3
            width: commandBarExtras.width + 24
            radius: 6
            color: "transparent"

            Row {
                id: commandBarExtras
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 18
                visible: AuthController.loggedIn

            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"
                font.pixelSize: 13; font.bold: true
                text: qsTr("操作员：") + (AuthController.displayName !== "" ? AuthController.displayName : AuthController.currentUser)
            }

            // 出站/进站勾选（站点操作员；控制右侧列表过滤）
            Row {
                spacing: 6
                visible: _isSiteATC
                CheckBox {
                    id: outboundCheck
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("出站")
                    checked: _outbound
                    onToggled: _outbound = checked
                    // 文字用 QGCCheckBox 的 textColor 不生效（palette.text 无效），
                    // 直接覆盖 contentItem 为白色 Text（兼容 Qt/QGC 两种 CheckBox）
                    contentItem: Text {
                        leftPadding: parent.indicator.width + parent.spacing
                        verticalAlignment: Text.AlignVCenter
                        text: parent.text
                        color: "#ffffff"
                        font.pixelSize: 13
                    }
                    // 勾选框两个状态各一个图标（Q 图标风格对勾徽标）：
                    // 选中=实心对勾 /res/selected.svg；未选中=半透明对勾 /res/unselected.svg（清晰可见）。
                    // indicator 尺寸仿 Q 图标（QGCToolBarButton icon 高 = defaultFontPixelHeight*2）
                    indicator: Rectangle {
                        implicitWidth: ScreenTools.defaultFontPixelHeight * 2; implicitHeight: ScreenTools.defaultFontPixelHeight * 2
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 6
                        color: "transparent"
                        border.color: "transparent"
                        Image {
                            anchors.fill: parent
                            source: outboundCheck.checked ? "/res/selected.svg" : "/res/unselected.svg"
                            fillMode: Image.PreserveAspectFit
                            mipmap: true
                        }
                    }
                }
                CheckBox {
                    id: inboundCheck
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("进站")
                    checked: _inbound
                    onToggled: _inbound = checked
                    // 文字用 QGCCheckBox 的 textColor 不生效（palette.text 无效），
                    // 直接覆盖 contentItem 为白色 Text（兼容 Qt/QGC 两种 CheckBox）
                    contentItem: Text {
                        leftPadding: parent.indicator.width + parent.spacing
                        verticalAlignment: Text.AlignVCenter
                        text: parent.text
                        color: "#ffffff"
                        font.pixelSize: 13
                    }
                    // 进站独立勾选框：选中=实心对勾 /res/selected.svg；未选中=半透明对勾 /res/unselected.svg
                    indicator: Rectangle {
                        implicitWidth: ScreenTools.defaultFontPixelHeight * 2; implicitHeight: ScreenTools.defaultFontPixelHeight * 2
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 6
                        color: "transparent"
                        border.color: "transparent"
                        Image {
                            anchors.fill: parent
                            source: inboundCheck.checked ? "/res/selected.svg" : "/res/unselected.svg"
                            fillMode: Image.PreserveAspectFit
                            mipmap: true
                        }
                    }
                }
            }

            // 双身份切换（仅 SITE_ATC+ROUTE_MONITOR 并存时）
            Row {
                spacing: 4
                visible: _isDual
                Repeater {
                    model: [qsTr("站点"), qsTr("监控员")]
                    Rectangle {
                        width: 56; height: 22
                        radius: 3
                        color: (_showSiteView === (index === 0)) ? "#2f6bd8" : "transparent"
                        border.color: "#9aa7bd"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            color: (_showSiteView === (index === 0)) ? "#ffffff" : "#5c6b84"
                            font.pixelSize: 11
                            text: modelData
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: _showSiteView = (index === 0)
                        }
                    }
                }
            }

        }
        }

        // 窗口控制（全屏/锁屏）靠屏幕右侧——与 Q 图标同组件（QGCToolBarButton logo:true）
        // 同尺寸契约（icon 高 = defaultFontPixelHeight*2，按钮高 = 3×行高），透明背景 SVG 徽标。
        Row {
            id: commandBarWindowButtons
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 4
            visible: AuthController.loggedIn

            QGCToolBarButton {
                anchors.verticalCenter: parent.verticalCenter
                icon.source:  "/res/OpsFullScreen.svg"
                logo:         true
                onClicked: {
                    if (mainWindow.visibility === Window.FullScreen) mainWindow.showNormal()
                    else mainWindow.showFullScreen()
                }
            }
            QGCToolBarButton {
                anchors.verticalCenter: parent.verticalCenter
                icon.source:  "/res/OpsLockScreen.svg"
                logo:         true
                onClicked:    AuthController.lockScreen()
            }
        }
    }

    //-------------------------------------------------------------------------
    // 主体：左侧地图+仪表（flex:1） / 右侧边栏（~340px）
    //-------------------------------------------------------------------------
    Item {
        id: body
        anchors.fill: parent

        //---- 左侧：地图 ----
        FlightMap {
            id: opsMap
            anchors.fill: parent
            allowGCSLocationCenter:     false
            allowVehicleLocationCenter: false
            planView:                   false
            zoomLevel:                  _tasks.length ? 14 : QGroundControl.flightMapInitialZoom
            center:                     _mapFollowFirst && _firstTaskCoord() !== null
                                        ? _firstTaskCoord()
                                        : (_mapManualCenter !== null
                                           ? _mapManualCenter
                                           : (QGroundControl.flightMapPosition.isValid
                                              ? QGroundControl.flightMapPosition
                                              : QtPositioning.coordinate(31.2, 121.5)))
            // 用户平移地图：先冻结当前中心（此时仍=跟随值，无跳变）再退出跟随，
            // 顺序不可颠倒（先退跟随会回落到 GCS 位置兜底，画面跳变）。
            onMapPanStart: { _mapManualCenter = opsMap.center; _mapFollowFirst = false }
            onMapPanStop:  { _mapManualCenter = opsMap.center }

            // 航路（全部任务 waypoints 连线）
            Repeater {
                model: _tasks
                delegate: MapPolyline {
                    line.width: 2
                    line.color: "#00bfff"
                    path: modelData.waypoints ? modelData.waypoints.map(
                              function(wp) { return QtPositioning.coordinate(wp.lat, wp.lon) }) : []
                }
            }

            // 无人机 marker
            Repeater {
                model: _tasks
                delegate: MapQuickItem {
                    visible: modelData.latest && modelData.latest.lat ? true : false
                    coordinate: modelData.latest && modelData.latest.lat
                                ? QtPositioning.coordinate(modelData.latest.lat, modelData.latest.lon)
                                : QtPositioning.coordinate(0, 0)
                    anchorPoint: Qt.point(12, 12)
                    sourceItem: Rectangle {
                        width: 24; height: 24; radius: 12
                        color: _statusColor(modelData)
                        border.color: "#ffffff"; border.width: 2
                        Text {
                            anchors.centerIn: parent
                            color: "#ffffff"; font.pixelSize: 10; font.bold: true
                            text: String(index + 1)
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                _selectedTaskId = modelData.task_id
                                // 走属性更新中心（而非直接赋值 opsMap.center）：保留绑定，
                                // 防止后续轮询/再次点击时中心被不期望地覆盖或绑定失效
                                _mapFollowFirst = false
                                _mapManualCenter = QtPositioning.coordinate(modelData.latest.lat, modelData.latest.lon)
                            }
                        }
                    }
                }
            }
        }

        //---- 右侧边栏 ----
        Rectangle {
            id: rightPanel
            anchors { top: parent.top; topMargin: ScreenTools.toolbarHeight; bottom: parent.bottom; right: parent.right }
            width: 340
            color: QGroundControl.globalPalette.window
            opacity: 0.8

            // 姿态仪 + 罗盘：右边栏最下方，宽度自适应右边栏宽度，高度随宽等比缩放。
            Item {
                id: instrumentsBlock
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom }
                width: parent.width * 0.8
                height: (instrumentsBlock.width - 12) / 2

                QGCAttitudeWidget {
                    id: attitudeWidget
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    size: (instrumentsBlock.width - 12) / 2
                    vehicle: _mockVehicle
                }
                QGCCompassWidget {
                    id: compassWidget
                    anchors.left: attitudeWidget.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    size: (instrumentsBlock.width - 12) / 2
                    vehicle: _mockVehicle
                }
            }

            ColumnLayout {
                anchors { top: parent.top; bottom: instrumentsBlock.top; left: parent.left; right: parent.right }
                spacing: 0

                // 站点视图（SITE_ATC）
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: _showSiteView && _isSiteATC
                    clip: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        // 任务列表
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 12; Layout.topMargin: 10
                            color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
                            text: qsTr("任务")
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: _siteTasks()
                            delegate: taskDelegate
                        }
                        // 机位布局
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 12; Layout.topMargin: 8
                            color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
                            text: qsTr("机位布局")
                        }
                        Flow {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10; Layout.rightMargin: 10; Layout.bottomMargin: 10
                            spacing: 6
                            Repeater {
                                model: _slots
                                delegate: Rectangle {
                                    width: slotBox.width; height: slotBox.height
                                    radius: 4
                                    color: modelData.current_uav_no ? "#3a4c6e" : "#1c2942"
                                    border.color: "#4a5f85"; border.width: 1
                                    Column {
                                        id: slotBox
                                        width: 90
                                        padding: 6
                                        spacing: 2
                                        Text {
                                            width: parent.width
                                            color: "#9fb3d4"; font.pixelSize: 11
                                            elide: Text.ElideMiddle
                                            text: modelData.slot_code
                                        }
                                        Text {
                                            width: parent.width
                                            color: modelData.current_uav_no ? "#ffd27f" : "#5c6b84"
                                            font.pixelSize: 10
                                            elide: Text.ElideMiddle
                                            text: modelData.current_uav_no ? modelData.current_uav_no : qsTr("空闲")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 监控员视图（ROUTE_MONITOR）
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: (!_showSiteView || !_isSiteATC) && _isRouteMon
                    clip: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 12; Layout.topMargin: 10
                            color: "#8fa1bd"; font.pixelSize: 12; font.bold: true
                            text: qsTr("负责航线 · 执行中")
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.leftMargin: 8; Layout.rightMargin: 8; Layout.topMargin: 4
                            clip: true
                            model: _routeTasks()
                            delegate: taskDelegate
                        }
                    }
                }
            }
        }

        //---- 底部状态栏（占满左区宽，高度+50%，内容居中，字号按任务栏登录用户名）----
        Rectangle {
            id: instrumentPanel
            anchors { left: parent.left; right: rightPanel.left; bottom: parent.bottom }
            height: 48
            color: Qt.rgba(QGroundControl.globalPalette.window.r, QGroundControl.globalPalette.window.g, QGroundControl.globalPalette.window.b, 0.8)
            z: 5

            // 选中任务 —— 靠左
            Text {
                anchors.left: parent.left; anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"; font.pixelSize: 13; font.bold: true
                text: qsTr("选中任务：") + _taskNo(_selectedTask())
            }

            // 参数排：标题：数值横向一行 —— 靠右
            Row {
                id: telemetryRow
                anchors.right: parent.right; anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 18
                Repeater {
                    model: [["alt", qsTr("高度")], ["speed", qsTr("水平速度")], ["airspeed", qsTr("空速")],
                            ["climb", qsTr("爬升")], ["battery", qsTr("电量")], ["heading", qsTr("航向")],
                            ["status", qsTr("状态")]]
                    delegate: Text {
                        textFormat: Text.RichText
                        font.pixelSize: 13; font.bold: true
                        color: "#e6edf7"
                        text: "<span style='color:#8fa1bd;'>%1：</span>%2".arg(modelData[1]).arg(_instrumentValue(modelData[0]))
                    }
                }
            }
        }
    }

    // 仪表取值（云平台遥测 latest；无数据返回 "—"）
    function _instrumentValue(key) {
        var t = _selectedTask()
        if (!t || !t.latest) return "—"
        var l = t.latest
        switch (key) {
        case "alt": return (l.alt_rel || 0).toFixed(0) + " m"
        case "speed": return (l.ground_speed || 0).toFixed(1) + " m/s"
        case "airspeed": return (l.air_speed || 0).toFixed(1) + " m/s"
        case "climb": return (l.climb_rate || 0).toFixed(1) + " m/s"
        case "battery": return (l.battery_pct || 0).toFixed(0) + "%"
        case "heading": return (l.heading || 0).toFixed(0) + "°"
        case "status": return _statusLabel(t.status)
        default: return "—"
        }
    }

    //---- 任务项 delegate（右侧边栏复用）----
    Component {
        id: taskDelegate
        Rectangle {
            width: ListView.view.width - 20
            height: taskBody.height + 12
            radius: 4
            color: "#16233c"
            border.width: 1
            border.color: _isTimeout(_handoverFor(modelData)) ? "#ff3b3b"
                          : (_selectedTaskId === modelData.task_id ? "#2f6bd8" : "#2a3a55")
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
                        color: _statusColor(modelData)
                    }
                    Text {
                        color: "#e6edf7"; font.pixelSize: 13; font.bold: true
                        text: _taskNo(modelData)
                    }
                    Text {
                        color: "#8fa1bd"; font.pixelSize: 12
                        text: modelData.task_no
                    }
                    Text {
                        color: _statusColor(modelData); font.pixelSize: 12; font.bold: true
                        text: _statusLabel(modelData.status)
                    }
                }
                Text {
                    width: parent.width
                    color: "#8fa1bd"; font.pixelSize: 11
                    elide: Text.ElideMiddle
                    text: modelData.route_name ? qsTr("航线: ") + modelData.route_name : ""
                }
                // 交接状态徽标
                Text {
                    width: parent.width
                    visible: _handoverFor(modelData) ? true : false
                    color: _isTimeout(_handoverFor(modelData)) ? "#ff3b3b" : "#ffc107"
                    font.pixelSize: 11
                    text: _handoverFor(modelData) ? (qsTr("待") + _phaseToLabel(_handoverFor(modelData).phase_to) +
                          qsTr("确认 · ") + (_isMine(_handoverFor(modelData)) ? qsTr("我提出") : (modelData.proposed_by_name ? modelData.proposed_by_name : "")) +
                          qsTr(" · ") + _remainingSec(_handoverFor(modelData))) : ""
                }
                // 操作按钮行
                Row {
                    width: parent.width
                    spacing: 6
                    // ── 站点视图：出站 ──
                    Button {
                        visible: _showSiteView && _isSiteATC && _isOutbound(modelData)
                                 && (modelData.status === "SCHEDULED" || modelData.status === "READY")
                        height: 24; padding: 0
                        text: qsTr("起飞")
                        onClicked: _guidedTakeoff()
                    }
                    Button {
                        visible: _showSiteView && _isSiteATC && modelData.status === "TAKEOFF"
                                 && !(_handoverFor(modelData) && _handoverFor(modelData).phase_to === "ROUTE")
                        height: 24; padding: 0
                        text: qsTr("移交监控")
                        onClicked: _proposeHandover(modelData.task_id, "ROUTE")
                    }
                    // ── 站点视图：进站 ──
                    Button {
                        visible: _showSiteView && _isSiteATC && _isInbound(modelData)
                                 && modelData.status === "IN_FLIGHT"
                                 && _handoverFor(modelData) && _handoverFor(modelData).phase_to === "LANDING"
                        height: 24; padding: 0
                        text: qsTr("确认降落")
                        onClicked: _acceptHandover(_handoverFor(modelData).handover_id)
                    }
                    Button {
                        visible: _showSiteView && _isSiteATC && modelData.status === "LANDING"
                        height: 24; padding: 0
                        text: qsTr("指定机位")
                        onClicked: { _assignSlotTask = modelData; slotDialog.open() }
                    }
                    Button {
                        visible: _showSiteView && _isSiteATC && modelData.status === "LANDING"
                        height: 24; padding: 0
                        text: qsTr("确认降落完成")
                        onClicked: _landingComplete(modelData.task_id)
                    }
                    // ── 监控员视图 ──
                    Button {
                        visible: (!_showSiteView || !_isSiteATC) && _isRouteMon
                                 && modelData.status === "IN_FLIGHT"
                        height: 24; padding: 0
                        text: qsTr("移交降落指挥")
                        onClicked: _proposeHandover(modelData.task_id, "LANDING")
                    }
                    // 撤回/拒绝（提出方或接收方在交接弹框内处理；此处提供撤回）
                    Button {
                        visible: _handoverFor(modelData) && _isMine(_handoverFor(modelData))
                        height: 24; padding: 0
                        text: qsTr("撤回交接")
                        onClicked: _cancelHandover(_handoverFor(modelData).handover_id)
                    }
                }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 交接确认弹框（pending 到达自动弹出）
    //-------------------------------------------------------------------------
    Dialog {
        id: handoverDialog
        parent: opsView
        width: 400
        modal: true
        title: qsTr("交接确认")

        ColumnLayout {
            width: parent.width
            spacing: 8
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"; font.pixelSize: 13
                wrapMode: Text.Wrap
                text: _confirmHandover
                    ? qsTr("%1 · %2 请求把任务「%3」移交 %4")
                        .arg(_confirmHandover.uav_no || _confirmHandover.task_no)
                        .arg(_confirmHandover.proposed_by_name || _confirmHandover.proposed_by)
                        .arg(_confirmHandover.task_no)
                        .arg(_phaseToLabel(_confirmHandover.phase_to))
                    : ""
            }
            Text {
                Layout.fillWidth: true
                color: _confirmHandover && _isTimeout(_confirmHandover) ? "#ff3b3b" : "#ffc107"
                font.pixelSize: 12
                text: _confirmHandover ? qsTr("剩余 ") + _remainingSec(_confirmHandover) : ""
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("拒绝")
                    onClicked: { _rejectHandover(_confirmHandover.handover_id); handoverDialog.close() }
                }
                Button {
                    text: _confirmHandover && _isMine(_confirmHandover) ? qsTr("撤回") : qsTr("确认接管")
                    onClicked: {
                        if (_confirmHandover && _isMine(_confirmHandover)) _cancelHandover(_confirmHandover.handover_id)
                        else _acceptHandover(_confirmHandover.handover_id)
                        handoverDialog.close()
                    }
                }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 机位选择弹框（SITE_ATC 指定降落机位）
    //-------------------------------------------------------------------------
    Dialog {
        id: slotDialog
        parent: opsView
        width: 360
        modal: true
        title: qsTr("指定降落机位")

        ColumnLayout {
            width: parent.width
            spacing: 6
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"; font.pixelSize: 12
                text: _assignSlotTask ? qsTr("任务 %1 指定降落机位：").arg(_taskNo(_assignSlotTask)) : ""
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: _slots
                    delegate: Button {
                        width: 96; height: 32
                        text: modelData.current_uav_no
                              ? modelData.slot_code + "（占用）"
                              : modelData.slot_code
                        enabled: modelData.current_uav_no ? false : true
                        onClicked: {
                            if (_assignSlotTask) _assignSlot(_assignSlotTask.task_id, modelData.id)
                            slotDialog.close()
                        }
                    }
                }
            }
        }
    }

    function _selectedTask() {
        for (var i = 0; i < _tasks.length; i++) {
            if (_tasks[i].task_id === _selectedTaskId) return _tasks[i]
        }
        return _tasks.length ? _tasks[0] : null
    }

    // 构造 QGC Fact 形对象（`{ rawValue }`）—— 供原版姿态仪/罗盘组件消费。
    function _fact(v) { return { rawValue: (v === undefined || v === null) ? 0 : v } }
    // 按选中任务最新遥测重建 mock vehicle（每次轮询调用；新建对象 → vehicle 属性变化 →
    // 组件内部 `vehicle.xxx.rawValue` 绑定重估 → 仪表刷新）。headingToHome/headingToNextWP
    // 云平台无此数据，补 0 兜底以免罗盘 property 立即评估时报 undefined 错误。
    function _buildMockVehicle(t) {
        var l = t ? t.latest : null
        if (!l) return null
        return {
            armed: true,
            roll:      _fact(l.roll),
            pitch:     _fact(l.pitch),
            heading:   _fact(l.heading),
            groundSpeed: _fact(l.ground_speed),
            headingToHome:  _fact(0),
            headingToNextWP: _fact(0),
            gps: { courseOverGround: _fact(l.heading) }
        }
    }
    function _updateMockVehicle() {
        _mockVehicle = _buildMockVehicle(_selectedTask())
    }
}
