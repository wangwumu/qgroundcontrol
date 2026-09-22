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

import "OpsCommon.js" as OpsCommon

/// @brief 飞行监控主界面**骨架与数据源**（站点操作员 OpsView / 航线监控员 RomView 共用）
/// 设计见 docs/qgc/飞行监控主界面设计.md。
/// 网络层用 QML XMLHttpRequest + AuthController 会话 token（Bearer），
/// 替代文档 §9 建议的 C++ OpsViewController（功能等价、减少 C++ 层改动）。
///
/// 本文件=两个视图**完全相同**的那部分：地图、右栏容器、命令条、底部状态栏、姿态仪/罗盘、
/// 轮询与全部 HTTP、交接确认弹框。差异（机位平面图、出站/进站、飞控动作）通过**两个对称的
/// 注入槽**交给各视图：
///   · `commandBarExtras`  → 命令条中段、操作员名/时间之后
///   · `rightPanelContent` → 右栏中段（姿态仪之上）整块
///
/// ‼️ 本文件**不认识任何角色**：`AuthController.roles` 只在各视图里判。这里只收
///    `overviewView` 这一个**数据源参数**（喂 `GET /api/ops/overview?view=`）。
///    角色判据若进了骨架，两个视图就会各自长出一份副本——副本漂移的后果是静默放行。
///
/// ‼️ 为什么注入槽用 `Component` + `Loader` 而不是 `default property alias`：默认属性别名
///    会被**本文件自己的子项**吃掉（本文件有大量内部 UI，它们正是通过默认属性挂进来的），
///    而 reparent 会重置 anchors。`Component` + `Loader` 是 QML 的标准做法，无 hack。
Item {
    id: opsShell

    //-------------------------------------------------------------------------
    // 注入槽（由视图填充；两个视图对称，谁都能挂自己的专属控件）
    //-------------------------------------------------------------------------
    // 命令条中段扩展区。展开后的根项会被塞进命令条那行 `Row` 里，故根项自带 spacing。
    property Component commandBarExtras:  null
    // 右栏中段（顶部 = 右栏顶，底部 = 姿态仪之上，左右 = 右栏两侧）。
    property Component rightPanelContent: null

    //-------------------------------------------------------------------------
    // 输入（由视图传入）
    //-------------------------------------------------------------------------
    // 数据源参数，**不是**显示开关：吃进 `GET /api/ops/overview?view=`。
    //   "site"  = 本站视图（后端按站点过滤）
    //   "route" = 监控员视图（后端按负责航线过滤 IN_FLIGHT）
    property string overviewView: "site"
    // 右栏宽度。机位平面图在场时由站点视图按所需宽在 340~510 之间伸缩，其余视图恒 340。
    property real   rightPanelWidth: _rightPanelMinW

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    // 每次轮询后发。机位等**视图专属**的请求挂在它上面（OpsView 连、RomView 不连）——
    // 让骨架的 `_poll()` 保持"只拉两视图共用的三份数据"，不必认识机位。
    signal polled()
    // 选中任务（地图 marker 或列表点击都走它）。视图侧据此同步自己的机位高亮等。
    signal taskSelected(var task)

    //-------------------------------------------------------------------------
    // 会话与身份
    //-------------------------------------------------------------------------
    // 读 roles 属性（NOTIFY rolesChanged）而非 hasRole() 方法：方法调用不注册 QML 绑定依赖，
    // 登录后才填充的 roles 不会触发重估 → 视图永不显示。indexOf 读属性值，登录后绑定自动更新。
    readonly property string _apiBase:       AuthController.serverUrl()

    // 供复用组件（FlyViewToolBar 内部 guidedActionMessageDisplay）解析的上下文值，
    // 与 FlyView 定义保持一致；缺省则其内部 _margins 绑定运行时 ReferenceError。
    readonly property real  _margins:       ScreenTools.defaultFontPixelWidth / 2

    //-------------------------------------------------------------------------
    // 数据（轮询刷新；JS 数组整体重建以触发 Repeater 更新）
    //-------------------------------------------------------------------------
    property var  _tasks:          []      // /ops/overview 任务数组（已按角色过滤）
    property var  _pending:        []      // /handovers/pending 待确认交接数组
    property var  _handoverById:   ({})    // task_id -> pending handover
    property var  _seenHandovers:  []      // 已提示过的 handover id（防重复弹框）
    property var  _selectedTaskId: -1
    property var  _confirmHandover: null   // 交接弹框当前对象
    property int   _now:           Date.now()
    property string _handoverActionError: ""  // 交接确认/拒绝/撤回失败提示（handoverDialog 保留可重试）
    // 本站站点 id 来自登录响应 role_sites 单值（AuthController.siteId，仅内存），不再从任务反推。
    property var   _mySiteId:       AuthController.siteId

    // 任务卡片之间的竖直间距。**单点定义**（值在 `OpsCommon.taskCardGap`）：站点视图与监控员
    // 视图是两个任务列表，但用的是同一种卡，间距就得是**同一个值**——两处各写一个字面量就是
    // 两个"决定者"，改一处忘一处会得到两种疏密。机位间距也取它（用户 2026-09-18：
    // 「间隔参照任务列表中两个卡片的间隔」）。
    readonly property real _taskCardGap: OpsCommon.taskCardGap
    // 任务卡片**右**侧留白：就是原代码 `width: ListView.view.width - 20` 里那个 20。
    // ‼️ 加左空位**不得吃掉它**（用户明确要求"不能挤到右侧的滚动条"）⇒ 左空位是从卡片**宽度**里
    // 减出来的，不是把卡片整体右移；右边缘位置因此一个像素都不变。
    // ⚠️ 实测本模块**没有任何 ScrollBar**（`ScrollBar` 在其中零命中；QGC 用 Qt `Basic`
    // 风格，该风格也不会给 ListView 自动附加滚动条），所以这 20 到底是给谁留的无法从代码确认
    // ——按"来历不明的右侧留白"对待，只保持原值、不替它编一个用途。
    property real  _taskCardRightGap: 20
    // 任务卡片**左**空位。原在 `OpsView.qml` 上定义成 `_taskCardMargin: _slotMargin`（机位边距
    // 派生出来的），因为当时监控员视图只是同一实例里的一个分支，借用得到；拆成两个视图后那根
    // 线就断了，故**提升到骨架**做单点定义，与上面两个"任务卡参数"团聚。
    // 站点视图的机位边距 `_slotMargin` 反过来绑它——2026-09-18 用户要求「机位间隔参照任务列表
    // 中两个卡片的间隔」，方向本就该是这个。值不变（10），两个视图因此天然同值。
    readonly property real _taskCardMargin: 10

    // 右边栏宽度：站点视图下按机位图**所需宽**取值（340 ~ 510 = 340×1.5），其余视图恒 340。
    // 510 来自用户给的上限「宽度不足时右边栏可扩至 1.5 倍」。
    readonly property real _rightPanelMinW: 340
    readonly property real _rightPanelMaxW: _rightPanelMinW * 1.5
    // 姿态仪/罗盘宽度**不随边栏加宽**（恒 340×0.8 = 272）：表盘放大没有信息量，
    // 而且会连带吃掉机位区的可用高（仪表高 = (宽−12)/2，宽了高也高）。
    readonly property real _instrBlockW:    _rightPanelMinW * 0.8

    // 右栏/仪表的实际尺寸，**暴露给视图**：站点视图的机位区可用高必须由它们推出
    //（见 OpsView 的 `_siteAreaH`），而 `rightPanel`/`instrumentsBlock` 是本文件的内部 id，
    // 视图侧看不到。转发成属性后绑定链一模一样，绕开了跨文件读 id 这件事。
    readonly property real rightPanelHeight:   rightPanel.height
    readonly property real instrumentsHeight:  instrumentsBlock.height
    readonly property real instrumentsVGap:    instrumentsBlock._vGap

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
    // 实时遥测判定窗口（6.0-C 失联放行判据）：latest.timestamp 距 _now ≤15s 视为在线
    readonly property int _liveTelemetryWindowMs: 15000

    //-------------------------------------------------------------------------
    // 轮询：2s 数据 + 1s 时钟（驱动剩余秒/超时红闪）
    //-------------------------------------------------------------------------
    Timer {
        interval: 2000; repeat: true
        // 门控：仅本视图可见（MainWindow.showOpsView/hideOpsView 切换）且已登录时轮询，
        // 避免切走视图/登出后仍在后台拉接口。
        running: opsShell.visible && AuthController.loggedIn
        onTriggered: _poll()
    }
    Timer {
        interval: 1000; repeat: true
        running: opsShell.visible && AuthController.loggedIn
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
    function _fetchOverview() {
        _get("/api/ops/overview?view=" + opsShell.overviewView, function(status, data) {
            if (status !== 200 || !Array.isArray(data)) { console.warn("OpsView overview", status); return }
            _tasks = data
            _updateMockVehicle()
            // 本站站点 id 由 AuthController.siteId（登录 role_sites 单值）提供，不再从任务 data[i].site_id 反推。
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
    // 只拉**两个视图共用**的两份数据；视图专属的请求（如机位）由视图自己连 `polled()`。
    // 顺序与拆分前一致：overview → pending → （视图的）机位。
    function _poll() {
        if (_apiBase === "") return
        _fetchOverview()
        _fetchPending()
        opsShell.polled()
    }

    //---- 交接动作 ----
    // 动作统一成功即 _poll()（乐观刷新按钮态/landing_accepted，防 2s 轮询窗内重复点按 409 噪音）。
    // 弹框类动作带 onDone(success)：失败返回 false → 调用方保留弹框供重试（防瞬时失败后无入口再确认）。
    // 404 视为"已被他端处理"＝成功（幂等收口）。
    function _proposeHandover(taskId, phaseTo) {
        _post("/api/tasks/" + taskId + "/handover", { phase_to: phaseTo },
              function(status) {
                  if (status === 200) _poll()
                  else console.warn("OpsView propose", status)
              })
    }
    function _acceptHandover(handoverId, onDone) {
        _post("/api/handovers/" + handoverId + "/accept", null,
              function(status) {
                  if (status === 200) _poll()
                  else console.warn("OpsView accept", status)
                  if (onDone) onDone(status === 200 || status === 404)
              })
    }
    function _rejectHandover(handoverId, onDone) {
        _post("/api/handovers/" + handoverId + "/reject", { reason: "" },
              function(status) {
                  if (status === 200) _poll()
                  else console.warn("OpsView reject", status)
                  if (onDone) onDone(status === 200 || status === 404)
              })
    }
    function _cancelHandover(handoverId, onDone) {
        _post("/api/handovers/" + handoverId + "/cancel", null,
              function(status) {
                  if (status === 200) _poll()
                  else console.warn("OpsView cancel", status)
                  if (onDone) onDone(status === 200 || status === 404)
              })
    }

    // 选中任务：**唯一写点**（地图 marker 与列表点击都走它），写状态与发信号成对出现。
    function selectTask(task) {
        if (!task) return
        _selectedTaskId = task.task_id
        opsShell.taskSelected(task)
    }

    function _notifyNewPending(list) {
        for (var i = 0; i < list.length; i++) {
            var h = list[i]
            if (_seenHandovers.indexOf(h.handover_id) >= 0) continue
            _seenHandovers.push(h.handover_id)
            if (_seenHandovers.length > 200) _seenHandovers.shift()   // 防长会话无界增长（缓慢内存泄漏）
            _handoverActionError = ""
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

    //-------------------------------------------------------------------------
    // 顶部命令条：原样复用原主界面（FlyView）的 FlyViewToolBar —— Q 标（☰）打开完整
    // 工具菜单（mainWindow.showToolSelectDialog），含主状态/飞行模式/遥测指示器等原始
    // 部件。自定义工具（操作员名/时间/锁屏/全屏/视图专属控件）叠加在命令条中间空白区，
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
            // 本视图无引导动作滑杆；GuidedActionConfirm 仅在有引导动作时才显示，置 null 安全
            guidedValueSlider:  null
        }

        // 自定义工具——靠右停放（操作员名 + 时间 + 视图专属控件），
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

                // 当前日期时间（中国习惯 yyyy年MM月dd日 hh:mm:ss），每秒刷新
                property date nowTime: new Date()
                Timer {
                    interval: 1000; repeat: true; running: AuthController.loggedIn
                    onTriggered: commandBarExtras.nowTime = new Date()
                }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"
                font.pixelSize: 13; font.bold: true
                text: qsTr("操作员：") + (AuthController.displayName !== "" ? AuthController.displayName : AuthController.currentUser)
            }

            // 当前年月日时分秒（操作员与视图专属控件之间）
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"
                font.pixelSize: 13; font.bold: true
                text: Qt.formatDateTime(commandBarExtras.nowTime, "yyyy年MM月dd日 hh:mm:ss")
            }

            // 视图专属控件注入槽（站点视图：出站/进站、机位朝向；监控员视图：留空或自有控件）。
            // ‼️ 槽位对两个视图**对称**：骨架不给任何一方开小灶，谁都不必改本文件就能挂控件。
            // 展开后的根项是 `Row`，本 Row 的 `spacing: 18` 因此同时作用于"时间↔扩展区"与扩展区内部。
            Loader {
                anchors.verticalCenter: parent.verticalCenter
                sourceComponent: opsShell.commandBarExtras
            }

        }
        }

        // 窗口控制（全屏/锁屏）靠屏幕右侧——与 Q 图标同组件（QGCToolBarButton logo:true）
        // 同尺寸契约（icon 高 = defaultFontPixelHeight*2，按钮高 = 3×行高），透明背景 SVG 徽标。
        // 右距让开 FlyViewToolBar 自带的载具遥测指示器区（电池/卫星/RSSI 等）：那排图标
        // 铺在命令条最右端，若不避让会与扩展区的操作员名/勾选控件叠在一起。让位宽度取实际
        // 占宽而非常数——指示器数量随载具状态变（无载具时≈0，建链后整排出现）。
        // extrasBar 锚在本行的 left，故一并跟着让位。
        Row {
            id: commandBarWindowButtons
            anchors {
                right:         parent.right
                rightMargin:   6 + commandBar.indicatorsWidth
                verticalCenter: parent.verticalCenter
            }
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
                        color: OpsCommon.statusColor(modelData, opsShell._now, opsShell._handoverById)
                        border.color: "#ffffff"; border.width: 2
                        Text {
                            anchors.centerIn: parent
                            color: "#ffffff"; font.pixelSize: 10; font.bold: true
                            text: String(index + 1)
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                opsShell.selectTask(modelData)
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
            // 宽度不再是常量：站点视图下随机位图所需宽在 340~510 之间伸缩（视图侧算好传进来）。
            // 地图是 anchors.fill 铺满的，边栏变宽只是多盖住一点地图，不改变地图自身的尺寸。
            width: opsShell.rightPanelWidth
            color: QGroundControl.globalPalette.windowTransparent
            opacity: 0.8

            // 姿态仪 + 罗盘：右边栏最下方，宽度自适应右边栏宽度，高度随宽等比缩放。
            Item {
                id: instrumentsBlock
                // 上（内容区↔仪表）/下（仪表↔窗口底）各留仪表高度 1/20 的空隙
                readonly property real _vGap: height / 20
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: _vGap }
                // ‼️ 不跟 parent.width：边栏加到 510 时表盘仍恒 272（见 _instrBlockW）
                width: _instrBlockW
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

            // 右栏中段：顶部=右栏顶、底部=姿态仪之上（空隙同原先的 _vGap），左右=右栏两侧。
            // 展开后的根项是 `ColumnLayout`，锚点挂在本 Loader 上——与拆分前那条
            // `anchors { top: parent.top; bottom: instrumentsBlock.top; ... }` 逐字等价。
            Loader {
                id: rightPanelContentLoader
                anchors { top: parent.top; bottom: instrumentsBlock.top; bottomMargin: instrumentsBlock._vGap
                          left: parent.left; right: parent.right }
                sourceComponent: opsShell.rightPanelContent
            }
        }

        //---- 底部状态栏（占满左区宽，高度+50%，内容居中，字号按任务栏登录用户名）----
        Rectangle {
            id: instrumentPanel
            anchors { left: parent.left; right: rightPanel.left; bottom: parent.bottom }
            height: 48
            color: QGroundControl.globalPalette.windowTransparent
            z: 5

            // 选中任务 —— 靠左
            Text {
                anchors.left: parent.left; anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"; font.pixelSize: 13; font.bold: true
                text: qsTr("选中任务：") + OpsCommon.taskNo(_selectedTask())
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
        case "status": return OpsCommon.displayStatus(t, opsShell._handoverById)
        default: return "—"
        }
    }

    //-------------------------------------------------------------------------
    // 交接确认弹框（pending 到达自动弹出）——两个视图共用，故留在骨架
    //-------------------------------------------------------------------------
    Dialog {
        id: handoverDialog
        parent: opsShell
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
                        .arg(OpsCommon.phaseToLabel(_confirmHandover.phase_to))
                    : ""
            }
            Text {
                Layout.fillWidth: true
                color: _confirmHandover && OpsCommon.isTimeout(_confirmHandover, opsShell._now) ? "#ff3b3b" : "#ffc107"
                font.pixelSize: 12
                text: _confirmHandover ? qsTr("剩余 ") + OpsCommon.remainingSec(_confirmHandover, opsShell._now) : ""
            }
            // 操作失败提示：瞬时网络失败时保留弹框供重试（配合 _seenHandovers 去重，关框即无再确认入口）
            Text {
                Layout.fillWidth: true
                color: "#ff6b6b"; font.pixelSize: 12
                wrapMode: Text.Wrap
                visible: _handoverActionError !== ""
                text: _handoverActionError
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("拒绝")
                    onClicked: _rejectHandover(_confirmHandover.handover_id, function(ok) {
                        if (ok) handoverDialog.close()
                        else _handoverActionError = qsTr("操作未送达服务端，请重试；仍失败请通知提出方撤回重提")
                    })
                }
                Button {
                    text: _confirmHandover && OpsCommon.isMine(_confirmHandover, AuthController.userId) ? qsTr("撤回") : qsTr("确认接管")
                    onClicked: {
                        var mine = _confirmHandover && OpsCommon.isMine(_confirmHandover, AuthController.userId)
                        var act = mine ? _cancelHandover : _acceptHandover
                        act(_confirmHandover.handover_id, function(ok) {
                            if (ok) handoverDialog.close()
                            else _handoverActionError = qsTr("操作未送达服务端，请重试；仍失败请通知对方人工处理")
                        })
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
