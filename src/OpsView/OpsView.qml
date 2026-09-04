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
    property var  _slots:          []      // 本站机位（site_id=_mySiteId）
    property var  _handoverById:   ({})    // task_id -> pending handover
    property var  _seenHandovers:  []      // 已提示过的 handover id（防重复弹框）
    property var  _selectedTaskId: -1
    property var  _confirmHandover: null   // 交接弹框当前对象
    property var  _assignSlotTask: null    // 机位选择弹框当前任务
    property var  _pendingAction:  null    // 红绿确认动作：{kind:"takeoff"|"land"|"park", task}
    property bool  _outbound:      true    // 站点视图勾选：出站
    property bool  _inbound:       true    // 站点视图勾选：进站
    property int   _now:           Date.now()
    // 右边栏重构：选中机位 / 降落拦截原因 / 本站站点 id
    // 本站站点 id 来自登录响应 role_sites 单值（AuthController.siteId，仅内存），不再从任务反推。
    property var   _selectedSlotId:   -1
    property string _landBlockReason: ""
    property string _assignSlotError: ""      // 指定机位失败原因（slotDialog 展示，成功/重开时清空）
    property string _handoverActionError: ""  // 交接确认/拒绝/撤回失败提示（handoverDialog 保留可重试）
    property var   _mySiteId:       AuthController.siteId
    // 机位两列 Grid 几何（宽随 rightPanel，高=宽/2；机位区高≤站点区一半）
    property int   _slotCols:      2
    property real  _slotGap:       6
    property real  _slotMargin:    10
    property real  _slotBoxW:      (rightPanel.width - _slotMargin * 2 - _slotGap) / _slotCols
    property real  _slotBoxH:      _slotBoxW / 2
    property int   _slotRows:      Math.max(1, Math.ceil(_slots.length / _slotCols))
    property real  _slotGridH:     _slotRows * _slotBoxH + (_slotRows - 1) * _slotGap
    property real  _slotAreaH:     Math.min(_slotGridH, Math.max(0, siteViewArea.height / 2))
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
    function _fetchSlots() {
        if (_isSiteATC && _mySiteId > 0) {
            // 使用闸（2026-09-05）：仅已核准机位作降落/停靠点——过滤判据全程在**后端** ListSlots
            // （2026-09-05 起缺省即只下发 VALIDATED 机位，旧构建不带参也一样被过滤；?only_validated=1
            // 保留仅为对旧后端兼容的无害显式），OpsView 概览网格与"指定机位"弹窗因此不含未核准机位；
            // 审批入口在 webui 站点与机位。本端不再重复实现列表过滤。
            _get("/api/sites/" + _mySiteId + "/slots?only_validated=1", function(status, data) {
                if (status === 200 && Array.isArray(data)) _slots = data
                else console.warn("OpsView slots", status)   // 失败留痕，避免机位区空白且无人知晓
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
    //---- 机位 / 落地 ----
    function _assignSlot(taskId, slotId, onDone) {
        _post("/api/tasks/" + taskId + "/assign-slot", { slot_id: slotId },
              function(status, data) {
                  if (status === 200) { _poll(); if (onDone) onDone(true) }
                  else {
                      _assignSlotError = (data && (data.error || data.reason)) || ("HTTP " + status)
                      console.warn("OpsView assign-slot", status, JSON.stringify(data))
                      if (onDone) onDone(false)
                  }
              })
    }
    // 红绿确认动作执行（kind: takeoff→DB 落库 + 起飞指令；land→机位校验 + 降落指令；park→DB 停泊收尾 + 离线下电）
    function _execPendingAction() {
        var a = _pendingAction
        if (!a || !a.task) return
        var task = a.task
        if (a.kind === "takeoff") {
            _post("/api/tasks/" + task.task_id + "/takeoff", null, function(status) {
                if (status === 200) _guidedTakeoff()
                else console.warn("OpsView takeoff", status)
            })
        } else if (a.kind === "land") {
            _execLand(task)
        } else if (a.kind === "park") {
            _post("/api/tasks/" + task.task_id + "/park", null, function(status) {
                if (status !== 200) { console.warn("OpsView park", status); return }
                // 停泊离线命令（路径 C：gcs_server 只落库，命令由 QGC 发）：
                // MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN(246)，param1=4 autopilot 下电、param2=2 强制
                // 经 activeVehicle 加密上行链路（LinkInterface）自动下发
                var v = QGroundControl.multiVehicleManager.activeVehicle
                if (v) v.sendCommand(1, 246, false, 4, 2)
                else console.warn("OpsView 停泊：无已连接飞行器，无法下发离线命令")
            })
        }
        _pendingAction = null
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
    // 交接派生：某任务是否存在 PENDING phase_to 交接（_handoverById 仅含 pending）；landing_accepted=
    // 已签入(LANDING)（存在 ACCEPTED phase_to=LANDING 交接；accept 仅管理交接，DB 状态不变，§6.0-E/F）。
    function _pendingPhase(task, phase) {
        var h = _handoverFor(task)
        return !!(h && h.phase_to === phase)
    }
    function _landingAccepted(task) { return !!(task && task.landing_accepted) }
    // 本地报文判定（仅显示/门控，不落库；2026-09-02 触发语义）：
    // vtol_state=FW(4)=巡航；landed 取 bit0（起降位掩码 bit0=ON_GROUND）；遥测新鲜=latest.timestamp 在窗口内。
    function _isCruising(task) {
        var l = task ? task.latest : null
        return !!(l && Number(l.vtol_state) === 4)
    }
    function _isLandedOnGround(task) {
        var l = task ? task.latest : null
        return !!(l && (Number(l.landed) & 1) !== 0)
    }
    function _hasLiveTelemetry(task) {
        var l = task ? task.latest : null
        if (!l || !l.timestamp) return false
        var ts = Date.parse(l.timestamp)
        if (isNaN(ts)) return false
        var age = _now - ts
        return age <= _liveTelemetryWindowMs && age >= -5000   // 容忍服务器时钟超前 ≤5s
    }
    // 出场=本站=起飞点且尚未完成切出：SCHEDULED/READY/TAKEOFF，以及落库 IN_FLIGHT 后 PENDING(ROUTE)
    // 交接待监控员确认的重叠期（§6.0-F：签出=责任里程碑；确认接管后退出出场）。
    function _isOutbound(t) {
        if (t.takeoff_site_id === undefined || t.takeoff_site_id === null) return false
        if (Number(t.takeoff_site_id) !== Number(_mySiteId)) return false
        if (t.status === "SCHEDULED" || t.status === "READY" || t.status === "TAKEOFF") return true
        return t.status === "IN_FLIGHT" && _pendingPhase(t, "ROUTE")
    }
    // 入场=本站=降落点：PENDING(LANDING) 待确认 / landing_accepted 已签入待发降落指令 / LANDING 已发降落指令。
    function _isInbound(t) {
        return t.landing_site_id !== undefined && t.landing_site_id !== null &&
               Number(t.landing_site_id) === Number(_mySiteId) &&
               (t.status === "LANDING" || _pendingPhase(t, "LANDING") || _landingAccepted(t))
    }
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
    // 状态文字 = task.status + 本地报文判定叠加（仅显示不落库，2026-09-02 触发语义）：
    // task TAKEOFF 且 vtol_state=FW(4) → "飞行中"；task LANDING 且 landed bit0(ON_GROUND) → "已落地"。
    function _displayStatus(task) {
        if (!task) return "—"
        var l = task.latest
        if (task.status === "TAKEOFF" && l && Number(l.vtol_state) === 4) return qsTr("飞行中")
        if (task.status === "LANDING" && l && (Number(l.landed) & 1) !== 0) return qsTr("已落地")
        // IN_FLIGHT 阶段文案，与按钮重键一致（§6.0-E/F）：待监控员接管 / 待接收降落 / 已签入待发降落指令
        if (task.status === "IN_FLIGHT") {
            if (_pendingPhase(task, "ROUTE")) return qsTr("待接管")
            if (_pendingPhase(task, "LANDING")) return qsTr("待降落")
            if (_landingAccepted(task)) return qsTr("待发降落")
        }
        return _statusLabel(task.status)
    }
    function _phaseToLabel(p) { return p === "ROUTE" ? "航线监控" : p === "LANDING" ? "降落指挥" : p }
    function _isMine(handover) { return handover && handover.proposed_by === AuthController.userId }
    // deadline_at 由后端以 UTC 裸串落库/返回（time.Now().UTC().Format("2006-01-02 15:04:05")，无 T/时区标记）；
    // ECMAScript 对无时区串按本地时区解析（中国 CST=UTC+8 → 会提前 8h 判"超时"）。此处补 'T' 与 'Z' 使其按 UTC
    // 解析，与后端 datetime('now') 比较口径及遥测 timestamp（RFC3339 带 Z）一致；已是 ISO+时区则原样放行。
    function _deadlineMs(handover) {
        var s = handover ? handover.deadline_at : ""
        if (!s) return NaN
        if (s.indexOf("T") < 0) s = s.replace(" ", "T")
        if (s.indexOf("Z") < 0 && !/[+-]\d{2}:\d{2}$/.test(s) && !/[+-]\d{4}$/.test(s)) s += "Z"
        return Date.parse(s)
    }
    function _remainingSec(handover) {
        if (!handover || !handover.deadline_at) return ""
        var deadline = _deadlineMs(handover)
        if (isNaN(deadline)) return ""
        var sec = Math.ceil((deadline - _now) / 1000)
        return sec > 0 ? sec + "s" : "超时"
    }
    function _isTimeout(handover) {
        if (!handover || !handover.deadline_at) return false
        var deadline = _deadlineMs(handover)
        return !isNaN(deadline) && _now > deadline
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
    function _statusColor(t) {
        var s = t ? t.status : ""
        if (_isTimeout(_handoverFor(t))) return "#ff3b3b"
        var l = t ? t.latest : null
        // 已落地（本地报文 landed bit0，显示态）→ 绿；飞行中叠加态沿用黄色
        if (s === "LANDING" && l && (Number(l.landed) & 1) !== 0) return "#2ecc71"
        switch (s) {
        case "TAKEOFF": case "IN_FLIGHT": case "LANDING": return "#ffc107"
        case "COMPLETED": return "#2ecc71"
        case "ABORT": case "FAILED": return "#ff3b3b"
        default: return "#3b9cff"
        }
    }
    // 任务性质：本站相对航线的角色（起飞点→出场，降落点→入场）
    function _taskNature(t) {
        if (!t) return "—"
        if (t.takeoff_site_id !== undefined && Number(t.takeoff_site_id) === Number(_mySiteId)) return qsTr("出场")
        if (t.landing_site_id !== undefined && Number(t.landing_site_id) === Number(_mySiteId)) return qsTr("入场")
        return "—"
    }
    // 航线性质：固定/临时。暂假定固定；后端 overview 已带 route_type（协议保留状态位），空回退"固定"。
    function _routeNature(t) {
        var rt = t ? t.route_type : ""
        if (/temporary|temp/i.test(rt)) return qsTr("临时")
        return qsTr("固定")
    }
    // 机位状态文案；未知/空回退原样或 "—"（表字段可扩展）
    function _uavStatusLabel(s) {
        switch (s) {
        case "PARKED": return "已停放"; case "PREFLIGHT": return "准备中"; case "READY_TO_TAKEOFF": return "待飞"; case "TAKEOFF": return "起飞中"; case "IN_FLIGHT": return "飞行中"
        case "RETURNING": return "返航中"; case "DIVERTED": return "备降"; case "EMERGENCY_LANDING": return "迫降"; case "LANDING": return "降落中"; case "LANDED": return "已落地"
        case "PARKED_YARD": return "停放场"
        default: return s || "—"
        }
    }
    // 机位停放无人机状态：优先 slots 返回的 current_uav_status，否则用 overview 的 uav_status 兜底
    function _uavStatusForSlot(slot) {
        if (slot && slot.current_uav_status) return slot.current_uav_status
        if (slot && slot.current_uav_id) {
            for (var i = 0; i < _tasks.length; i++)
                if (_tasks[i].uav_id === slot.current_uav_id) return _tasks[i].uav_status || ""
        }
        return ""
    }
    function _formatPlanTakeoff(t) {
        if (!t || !t.plan_takeoff_at) return "—"
        var d = new Date(t.plan_takeoff_at)
        if (isNaN(d.getTime())) return t.plan_takeoff_at
        return d.toLocaleTimeString(Qt.locale(), "HH:mm")
    }
    function _slotById(id) {
        for (var i = 0; i < _slots.length; i++) if (_slots[i].id === id) return _slots[i]
        return null
    }
    // 指定机位可用判定（使用闸 2026-09-05）：未被占用且 slot.status 为空或 FREE（维护/故障机位不可指派
    // 为停靠落点）。是否已核准由后端 ListSlots 缺省过滤保证（本列表只含 VALIDATED 机位），此处 review
    // 判断仅作异常数据防御，不再承担审批过滤；归属场地是否 VALIDATED 无机位级数据可查（载荷不含场地审核态），
    // 由后端在点按时 400 兜底（SITE_NOT_VALIDATED）。
    function _slotAssignable(s) {
        return !!s && !s.current_uav_no
               && s.review_status === "VALIDATED"
               && (!s.status || s.status === "FREE")
    }
    // 指定机位不可用原因标注（弹窗机位按钮后缀；未核准正常不会出现在列表中，分支仅作防御）
    function _slotAssignHint(s) {
        if (!s) return ""
        if (s.current_uav_no) return qsTr("（占用）")
        if (s.review_status && s.review_status !== "VALIDATED") return qsTr("（未核准）")
        if (s.status === "MAINTENANCE") return qsTr("（维护）")
        if (s.status === "FAULT") return qsTr("（故障）")
        return ""
    }
    // 选中任务 → 找到停放其无人机的机位，点亮之
    function _slotForTask(task) {
        if (!task || !task.uav_id) return null
        for (var i = 0; i < _slots.length; i++)
            if (_slots[i].current_uav_id && _slots[i].current_uav_id === task.uav_id) return _slots[i]
        return null
    }
    function _syncSlotForSelection(task) {
        var s = _slotForTask(task)
        _selectedSlotId = s ? s.id : -1
    }
    // 选中机位 → 反向点亮停放其无人机的任务
    function _taskForSlot(slot) {
        if (!slot || !slot.current_uav_id) return null
        for (var i = 0; i < _tasks.length; i++)
            if (_tasks[i].uav_id && _tasks[i].uav_id === slot.current_uav_id) return _tasks[i]
        return null
    }
    function _selectSlot(slotId) {
        _selectedSlotId = slotId
        var t = _taskForSlot(_slotById(slotId))
        if (t) _selectedTaskId = t.task_id
    }
    // 起飞门控：任务已关联无人机且已停在指定起飞机位才允许起飞
    function _canTakeoff(task) {
        if (!task || !_isOutbound(task)) return false
        if (task.status !== "SCHEDULED" && task.status !== "READY") return false
        if (!task.uav_id || !task.uav_current_slot_id) return false
        if (task.takeoff_slot_id && task.uav_current_slot_id !== task.takeoff_slot_id) return false
        return true
    }
    // 发出降落指令（6.0-E，LANDING 唯一写路径）：机位空闲校验 → POST /tasks/:id/land（DB→LANDING）→ 引导降落。
    function _execLand(task) {
        if (!task) return
        if (!task.landing_slot_id) { console.warn("OpsView 发出降落指令：未指定降落机位"); return }
        var tid = task.task_id
        _get("/api/tasks/" + tid + "/landing-slot-check", function(status, data) {
            if (status === 200 && data && data.free === true) {
                _post("/api/tasks/" + tid + "/land", null, function(landStatus, data) {
                    if (landStatus === 200) {
                        _guidedLand()
                        _poll()   // 任务→LANDING 后立即刷新列表（按钮转 指定机位/停泊）
                    } else {
                        // 透传服务端业务原因（如机位占用/状态已变），避免只显 "HTTP 409" 无法处置
                        _landBlockReason = qsTr("降落指令下发失败：") +
                            ((data && (data.error || data.reason)) || ("HTTP " + landStatus))
                        landBlockDialog.open()
                        console.warn("OpsView 发出降落指令失败:", landStatus, JSON.stringify(data))
                    }
                })
            } else {
                _landBlockReason = qsTr("降落校验未通过：") +
                    ((data && (data.reason || data.error)) || ("HTTP " + status))
                landBlockDialog.open()
                console.warn("OpsView 发出降落指令被阻止:", status, JSON.stringify(data))
            }
        })
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

            // 当前年月日时分秒（操作员与出站之间）
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: "#e6edf7"
                font.pixelSize: 13; font.bold: true
                text: Qt.formatDateTime(commandBarExtras.nowTime, "yyyy年MM月dd日 hh:mm:ss")
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
                                _syncSlotForSelection(modelData)
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
            color: QGroundControl.globalPalette.windowTransparent
            opacity: 0.8

            // 姿态仪 + 罗盘：右边栏最下方，宽度自适应右边栏宽度，高度随宽等比缩放。
            Item {
                id: instrumentsBlock
                // 上（场地↔仪表）/下（仪表↔窗口底）各留仪表高度 1/20 的空隙
                readonly property real _vGap: height / 20
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: _vGap }
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
                anchors { top: parent.top; bottom: instrumentsBlock.top; bottomMargin: instrumentsBlock._vGap; left: parent.left; right: parent.right }
                spacing: 0

                // 站点视图（SITE_ATC）：上部任务列表 + 下部两列机位（从底向上，高≤本区一半）
                Item {
                    id: siteViewArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: _showSiteView && _isSiteATC
                    clip: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        // ── 上部：任务列表（吃掉机位之外的剩余高度）──
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: _siteTasks()
                            delegate: taskDelegate
                        }
                        // ── 下部：机位（两列、从底向上、内容超出可滚动）──
                        Flickable {
                            id: slotFlick
                            Layout.fillWidth: true
                            Layout.preferredHeight: _slotAreaH
                            Layout.maximumHeight: _slotAreaH
                            clip: true
                            contentWidth: width
                            contentHeight: Math.max(_slotGridH, height)
                            boundsBehavior: Flickable.StopAtBounds
                            Column {
                                // 顶部弹性空白：机位少时把方格推到最底部（从底向上排列）
                                Item { width: 1; height: Math.max(0, slotFlick.height - _slotGridH) }
                                Grid {
                                    width: slotFlick.width
                                    columns: _slotCols
                                    columnSpacing: _slotGap
                                    rowSpacing: _slotGap
                                    leftPadding: _slotMargin
                                    rightPadding: _slotMargin
                                    bottomPadding: _slotMargin
                                    Repeater {
                                        model: _slots
                                        delegate: slotBar
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
            color: QGroundControl.globalPalette.windowTransparent
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
        case "status": return _displayStatus(t)
        default: return "—"
        }
    }

    //---- 任务项 delegate（右侧边栏复用）----
    Component {
        id: slotBar
        Rectangle {
            width: _slotBoxW
            height: _slotBoxH
            radius: 6
            color: _selectedSlotId === modelData.id ? "#2f6bd8"
                   : (modelData.current_uav_no ? "#3a4c6e" : "#1c2942")
            border.width: _selectedSlotId === modelData.id ? 2 : 1
            border.color: _selectedSlotId === modelData.id ? "#7fb3ff" : "#4a5f85"
            Column {
                anchors.fill: parent
                anchors.margins: 5
                spacing: 2
                Text {
                    width: parent.width
                    color: "#9fb3d4"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: modelData.slot_code
                }
                Text {
                    width: parent.width
                    color: modelData.current_uav_no ? "#ffd27f" : "#5c6b84"
                    font.pixelSize: 11
                    elide: Text.ElideMiddle
                    text: modelData.current_uav_no
                          ? modelData.current_uav_no + " · " + _uavStatusLabel(_uavStatusForSlot(modelData))
                          : qsTr("空")
                }
            }
            // 点机位 → 选中该机位，并反向点亮停放其无人机的任务
            MouseArea {
                anchors.fill: parent
                onClicked: _selectSlot(modelData.id)
            }
        }
    }

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

            // 点整项选中任务（并同步点亮对应机位）
            MouseArea {
                anchors.fill: parent
                onClicked: { _selectedTaskId = modelData.task_id; _syncSlotForSelection(modelData) }
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
                        color: _statusColor(modelData)
                    }
                    Text {
                        color: _statusColor(modelData); font.pixelSize: 12; font.bold: true
                        text: _displayStatus(modelData)
                    }
                    Text {
                        color: "#8fa1bd"; font.pixelSize: 11
                        text: qsTr("性质：") + _taskNature(modelData)
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
                    Text {
                        color: "#9fb3d4"; font.pixelSize: 11
                        text: qsTr("航班：") + (modelData.uav_no ? modelData.uav_no : (modelData.task_no ? modelData.task_no : "—"))
                    }
                    Text {
                        color: "#9fb3d4"; font.pixelSize: 11
                        text: qsTr("起飞：") + _formatPlanTakeoff(modelData)
                    }
                    Text {
                        color: "#9fb3d4"; font.pixelSize: 11
                        text: qsTr("航线性质：") + _routeNature(modelData)
                    }
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
                        enabled: _canTakeoff(modelData)
                        height: 24; padding: 0
                        text: qsTr("起飞")
                        onClicked: { _pendingAction = {kind:"takeoff", task:modelData}; actionConfirmDialog.open() }
                    }
                    Button {
                        // 6.0-A 申请切出（签出）：起飞经航迹确认后发起 ROUTE 交接；仅巡航(FW)且有实时遥测可切出，
                        // 无遥测置灰（6.0-C 失联不签发；DB 在 Propose ROUTE 时落 IN_FLIGHT=责任里程碑）。
                        visible: _showSiteView && _isSiteATC && modelData.status === "TAKEOFF"
                                 && !_pendingPhase(modelData, "ROUTE")
                        enabled: _isCruising(modelData) && _hasLiveTelemetry(modelData)
                        height: 24; padding: 0
                        text: qsTr("申请切出")
                        onClicked: _proposeHandover(modelData.task_id, "ROUTE")
                    }
                    // ── 站点视图：进站（accept 交接走 handoverDialog，此处无行内确认按钮）──
                    Button {
                        // 6.0-E 发出降落指令：仅已签入(LANDING)（landing_accepted）且 DB 仍 IN_FLIGHT 时出现；
                        // 点按→红绿确认→机位校验→POST /tasks/:id/land（LANDING 唯一写路径）→引导降落。
                        visible: _showSiteView && _isSiteATC && _isInbound(modelData)
                                 && modelData.status === "IN_FLIGHT" && _landingAccepted(modelData)
                        enabled: modelData.landing_slot_id ? true : false
                        height: 24; padding: 0
                        text: qsTr("发出降落指令")
                        onClicked: { _pendingAction = {kind:"land", task:modelData}; actionConfirmDialog.open() }
                    }
                    Button {
                        // 指定机位：签入(LANDING)后可预占（后端 AssignSlot 门控 IN_FLIGHT+ACCEPTED LANDING 或 LANDING）
                        visible: _showSiteView && _isSiteATC && _isInbound(modelData)
                                 && (modelData.status === "LANDING" ||
                                     (modelData.status === "IN_FLIGHT" && _landingAccepted(modelData)))
                        height: 24; padding: 0
                        text: qsTr("指定机位")
                        onClicked: { _assignSlotError = ""; _assignSlotTask = modelData; slotDialog.open() }
                    }
                    Button {
                        // 6.0-B 停泊门控：已落地(landed bit0) 可停泊；有实时遥测未落地→置灰"停泊（待落地）"；
                        // 失联/无遥测→放行"停泊（无遥测）"；均不隐藏，供人工收尾
                        visible: _showSiteView && _isSiteATC && modelData.status === "LANDING"
                        enabled: _isLandedOnGround(modelData) || !_hasLiveTelemetry(modelData)
                        height: 24; padding: 0
                        text: _isLandedOnGround(modelData) ? qsTr("停泊")
                              : (_hasLiveTelemetry(modelData) ? qsTr("停泊（待落地）") : qsTr("停泊（无遥测）"))
                        onClicked: { _pendingAction = {kind:"park", task:modelData}; actionConfirmDialog.open() }
                    }
                    // ── 监控员视图 ──
                    Button {
                        // 仅无 PENDING(LANDING) 交接时可发起（防重复 409；已有交接可走"撤回交接"）
                        visible: (!_showSiteView || !_isSiteATC) && _isRouteMon
                                 && modelData.status === "IN_FLIGHT" && !_pendingPhase(modelData, "LANDING")
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
    // 降落被阻止弹框（发出降落指令前机位空闲校验未通过 / 指令下发失败时弹出）
    //-------------------------------------------------------------------------
    Dialog {
        id: landBlockDialog
        parent: opsView
        width: 400
        modal: true
        title: qsTr("降落被阻止")

        ColumnLayout {
            width: parent.width
            spacing: 8
            Text {
                Layout.fillWidth: true
                color: "#ff6b6b"; font.pixelSize: 13
                wrapMode: Text.Wrap
                text: qsTr("降落操作已被阻止，请人工确认机位/状态后重试。")
            }
            Text {
                Layout.fillWidth: true
                color: "#ffc107"; font.pixelSize: 12
                wrapMode: Text.Wrap
                text: _landBlockReason
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
                    text: _confirmHandover && _isMine(_confirmHandover) ? qsTr("撤回") : qsTr("确认接管")
                    onClicked: {
                        var mine = _confirmHandover && _isMine(_confirmHandover)
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
            // 指派失败原因（保留弹框可换机位重试）
            Text {
                Layout.fillWidth: true
                color: "#ff6b6b"; font.pixelSize: 12
                wrapMode: Text.Wrap
                visible: _assignSlotError !== ""
                text: _assignSlotError
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: _slots
                    delegate: Button {
                        width: 96; height: 32
                        text: modelData.slot_code + _slotAssignHint(modelData)
                        enabled: _slotAssignable(modelData)
                        onClicked: {
                            if (_assignSlotTask) _assignSlot(_assignSlotTask.task_id, modelData.id, function(ok) {
                                if (ok) { slotDialog.close(); _assignSlotTask = null }
                            })
                        }
                    }
                }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 飞行控制动作红绿确认弹框（起飞/降落/停泊；迁入交接走 handoverDialog 一次确认）
    // 红=确认执行（危险动作警示）、绿=取消（安全退出）。未来专用控制台做大红/大绿实体按钮。
    //-------------------------------------------------------------------------
    Dialog {
        id: actionConfirmDialog
        parent: opsView
        width: 460
        modal: true
        title: _pendingAction
               ? (_pendingAction.kind === "takeoff" ? qsTr("起飞确认")
                  : _pendingAction.kind === "land"    ? qsTr("降落确认")
                  : qsTr("停泊确认"))
               : qsTr("飞行控制确认")

        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.fillWidth: true
                color: "#ffc107"; font.pixelSize: 13
                wrapMode: Text.Wrap
                text: {
                    if (!_pendingAction || !_pendingAction.task) return ""
                    var t = _pendingAction.task
                    var hint = _pendingAction.kind === "takeoff" ? qsTr("将确认起飞并控制无人机升空")
                             : _pendingAction.kind === "land"    ? qsTr("将发出降落指令：任务进入降落(LANDING)，引导无人机在本场着陆")
                             : qsTr("将终结本任务并对无人机下电停泊（不可撤销）")
                    return qsTr("%1\n任务「%2」 · 无人机 %3")
                        .arg(hint).arg(_taskNo(t)).arg(t.uav_no ? t.uav_no : "—")
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                Item { Layout.fillWidth: true }
                // 红 = 确认执行（醒目危险色）
                Button {
                    text: qsTr("确认执行")
                    background: Rectangle { color: "#d63031"; radius: 3; implicitHeight: 40; implicitWidth: 132 }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 15; font.bold: true
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: { actionConfirmDialog.close(); _execPendingAction() }
                }
                // 绿 = 取消（安全退出）
                Button {
                    text: qsTr("取消")
                    background: Rectangle { color: "#2ecc71"; radius: 3; implicitHeight: 40; implicitWidth: 96 }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 15; font.bold: true
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: actionConfirmDialog.close()
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
