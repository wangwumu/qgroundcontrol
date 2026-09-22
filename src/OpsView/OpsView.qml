import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

/// @brief 飞行监控主界面 —— **站点操作员（SITE_ATC）视图**
/// 设计见 docs/qgc/飞行监控主界面设计.md。
///
/// 骨架/数据源/轮询/命令条/地图/底部状态栏/姿态仪/交接弹框全在 `OpsShell.qml`；
/// 本文件只写**站点专属**的那部分：机位平面图、出站/进站过滤、起飞/降落/停泊三个飞控动作
/// 及其红绿确认，并用两个注入槽挂进骨架。
///
/// ‼️ 职责边界的判据是"**换个视图还要不要**"：机位、飞控动作、出站/进站只要站点视图要，
///    就留在本文件。放进骨架会让航线监控员也拿到"能不能起飞"这类判据，而它没有机位上下文
///    ——那正是两个视图各长一份判据副本、然后静默漂移的起点。
OpsShell {
    id: opsView

    //-------------------------------------------------------------------------
    // 骨架输入
    //-------------------------------------------------------------------------
    // 数据源参数（吃进 GET /api/ops/overview?view=）。本视图**只**服务站点操作员。
    // 用户 2026-09-21 裁定两个身份不允许重叠、不存在双身份 ⇒ 监控员不走这里，它是并列的
    // `RomView.qml`；分流判据只有一处，在 `MainWindow._onLoginSucceededForRole()`。
    overviewView: "site"
    // 右栏宽度：按机位图**所需宽**取值（340 ~ 510 = 340×1.5）。510 来自用户给的上限
    //「宽度不足时右边栏可扩至 1.5 倍」。机位图所需宽由 `_slotDesiredPanelWidth` 回送。
    rightPanelWidth: _isSiteATC
                     ? Math.min(_rightPanelMaxW, Math.max(_rightPanelMinW, _slotDesiredPanelWidth))
                     : _rightPanelMinW

    //-------------------------------------------------------------------------
    // 会话与身份
    //-------------------------------------------------------------------------
    // 读 roles 属性（NOTIFY rolesChanged）而非 hasRole() 方法：方法调用不注册 QML 绑定依赖，
    // 登录后才填充的 roles 不会触发重估 → 视图永不显示。indexOf 读属性值，登录后绑定自动更新。
    readonly property bool  _isSiteATC:      AuthController.roles.indexOf("SITE_ATC") >= 0

    //-------------------------------------------------------------------------
    // 站点数据（骨架只拉两视图共用的任务/交接；机位是站点专属，挂轮询信号自己拉）
    //-------------------------------------------------------------------------
    // ‼️ 两个机位集合**刻意分开**，别合并（2026-09-18）：
    //   `_slots`    = 缺省档「**可用**机位」（已核准 ∧ status='FREE'）——**使用面**的唯一来源：
    //                 「指定机位」弹窗的按钮、`_slotById`、`_slotForTask`。维护/故障机位必须不在其中，
    //                 否则操作员会拿到一个永不成功的起降目标。
    //   `_slotsAll` = 第二档「**已核准**机位」（不论 status）——**只喂机位平面图**，见 `_slotsMapView`。
    // 两档由**后端** `site.go ListSlots` 的参数分流（QGC 侧不做任何过滤，判据全程在后端）。
    property var  _slots:          []      // 本站可用机位（site_id=_mySiteId）
    property var  _slotsAll:       []      // 本站已核准机位（含维护/故障；仅平面图用）
    property var  _assignSlotTask: null    // 机位选择弹框当前任务
    property var  _pendingAction:  null    // 红绿确认动作：{kind:"takeoff"|"land"|"park", task}
    property bool  _outbound:      true    // 站点视图勾选：出站
    property bool  _inbound:       true    // 站点视图勾选：进站
    // 右边栏重构：选中机位 / 降落拦截原因
    // 本站站点 id 来自登录响应 role_sites 单值（AuthController.siteId，仅内存），不再从任务反推。
    property var   _selectedSlotId:   -1
    property string _landBlockReason: ""
    property string _assignSlotError: ""      // 指定机位失败原因（slotDialog 展示，成功/重开时清空）

    //-------------------------------------------------------------------------
    // 布局常量（站点专属部分）
    //-------------------------------------------------------------------------
    // 机位区四周留白。与任务卡片左留白**同源**：2026-09-17 用户要求卡片左留白"参照机位左侧的
    // 空位"，2026-09-18 又要求"机位间隔参照任务列表中两个卡片的间隔"——两者要的其实是同一个数。
    // ‼️ 该数的**单点定义现在在骨架**（`OpsShell._taskCardMargin`，10），不再是本文件：监控员
    // 视图也要用它，而监控员没有机位，定义留在这里拆出去的那个视图就够不着了（2026-09-21 拆
    // RomView 时暴露）。方向仍是"任务卡是源、机位是派生"。
    property real  _slotMargin:    _taskCardMargin
    // 机位图朝向：N = 上为北（缺省）/ E = 上为东。**只驱动本机位图的投影**，不改动别的任何东西。
    //
    // 落盘复用 QGC 既有的**通用键值接口** `QGroundControl.saveGlobalSetting / loadGlobalSetting`
    //（Q_INVOKABLE，写进 .ini 的 `[QGCQml]` 组）——与 `PipView.qml` 的 `_pipExpandedSettingsKey`
    // 同源：那是 QGC 里"界面偏好要落盘"的既有先例，**零 C++、零 CMake 改动**。
    // 不必走 SettingsGroup（那要 json + cc/h + SettingsManager 注册 + 设置页条目），
    // 而本项的**操作入口就在这条工具栏上**，再放一份到设置页只会多一个决定者。
    //
    // ‼️ 这个键是**整机（QSettings）级**的：不区分登录用户、不区分站点。换个人登录、或换场地，
    //    读到的都是上一次在本机改过的值。用户原话「有人修改朝向，则下次登陆采用上次设置的值」
    //    要的正是这个形状。哪天要按用户/站点各存一份，得把键名换成带 userId/siteId 的形式
    //    ——那时 `QGroundControl` 这对接口就不够用了（它只吃一个扁平键名）。
    readonly property string _slotOrientSettingsKey: "OpsViewSlotOrient"
    property string _slotOrient:   "N"
    // 缺省朝北 ⇒ `loadGlobalSetting` 的缺省值就取 "N"（键根本没写过时返回它）。
    // ⚠️ **必须过一遍白名单**，不能把读到的串直接赋给 `_slotOrient`：手工改过 .ini、
    //    或将来枚举扩展，都能塞进垃圾值。后果不是崩溃而是**静默**——`SlotLayout` 里所有
    //    `orient === "E"` 判断会一律按北处理（fail-safe，画面仍画得出来），但两个切换按钮
    //    **都不高亮**，界面进入"看起来一项都没选中"的状态，且不报任何错。所以非 "E" 一律回落 "N"。
    function _loadSlotOrient() {
        return QGroundControl.loadGlobalSetting(_slotOrientSettingsKey, "N") === "E" ? "E" : "N"
    }
    // 用 `Component.onCompleted` 赋值而**不是**写成属性绑定 `property string _slotOrient: _loadSlotOrient()`：
    // 方法调用不注册 QML 绑定依赖（见本文件顶部 roles 那条同源教训），两者此刻等价，
    // 但绑定一旦将来因任何原因被重估，就会把用户**本次会话内**改的朝向悄悄冲回文件里的旧值。
    // 显式赋值把"只在启动时读一次"这件事写死。
    Component.onCompleted: _slotOrient = _loadSlotOrient()
    // 站点视图整块（任务列表之上、仪表区之下）的高度；其**一半**是机位图的可用高上限。
    // ‼️ 必须由 rightPanel 与仪表区推出，**不能**直接读 siteViewArea.height —— 那会成环
    //（可用高 → 比例系数 → 卡片高 → 机位簇自然高 → 机位区高 → 可用高），
    // 而改造前的 _slotAreaH 正是那种写法，QML 只能靠"沿用上一轮的值"勉强收敛。
    // 三个被减数由骨架转发（`rightPanel`/`instrumentsBlock` 是骨架的内部 id，本文件看不到）。
    readonly property real _siteAreaH:      Math.max(0, rightPanelHeight
                                                     - instrumentsHeight
                                                     - instrumentsVGap * 2)
    readonly property real _slotAreaMaxH:   _siteAreaH / 2
    // 机位卡片用的视图数据：在机位对象上补三个**呈现字段**
    //（`uav_status` / `uav_status_label` / `slot_status_label`）。
    // 补在这里而不是卡片里，是因为"停放无人机状态"要回退到 overview 的 uav_status
    //（见 _uavStatusForSlot），而那个回退要读 _tasks —— SlotLayout 拿不到、也不该拿到。
    // 枚举→中文的唯一来源仍是 OpsCommon.uavStatusLabel / _slotStatusLabel（卡片不许出现裸枚举）。
    //
    // ‼️ 源是 **`_slotsAll`（平面图那一档）**，不是 `_slots`：平面图必须画出维护/故障机位，
    // 否则其余机位的投影相对方位整体错位（用户 2026-09-18 报障，见 SlotLayout.qml 文件头）。
    readonly property var _slotsMapView: _decorateSlots(_slotsAll)
    function _decorateSlots(src) {
        if (!src || !src.length) return []
        var out = []
        for (var i = 0; i < src.length; i++) {
            var s = src[i]
            var c = {}
            for (var k in s) c[k] = s[k]      // 整体浅拷贝：将来后端加字段不必回来补这里
            c.uav_status = _uavStatusForSlot(s)
            c.uav_status_label = OpsCommon.uavStatusLabel(c.uav_status)
            c.slot_status_label = _slotStatusLabel(s.status)
            out.push(c)
        }
        return out
    }
    // 机位图是否在场。原先还要 `&& _showSiteView`（双身份可切到监控员子视图，那时机位图不在场）；
    // 拆出 RomView 后本视图只剩站点一种形态，判据收敛为 `_isSiteATC` 一个条件。
    // 「机位图在场」直接决定边栏要不要加宽、朝向按钮要不要出现。
    readonly property bool _showSlotLayout: _isSiteATC
    // 机位图**所需的右边栏宽**，由右栏内容组件内的 `Binding` 回送（见下方 rightPanelContent）。
    // ‼️ 不能在骨架里直接读 `slotLayout.desiredPanelWidth`：`slotLayout` 声明在注入的
    //    `Component` 里，骨架展开它之前那个 id 根本不存在 ⇒ 第一次求值拿到 null、
    //    此后**没有任何 NOTIFY 会让它重估**，边栏宽就被永久钉死在 340。
    //    回送到一个普通属性上，依赖就落在"属性变化"这件有信号的事上。
    property real _slotDesiredPanelWidth: _rightPanelMinW

    //-------------------------------------------------------------------------
    // 轮询：骨架每轮拉完任务/交接后发 polled()，机位在这里自己接
    //-------------------------------------------------------------------------
    // 顺序与拆分前一致（overview → pending → slots）。
    onPolled: {
        _fetchSlots()
        _fetchSlotsAll()
    }
    // 选中任务（地图 marker 或列表点击都由骨架发）→ 找到停放其无人机的机位，点亮之
    onTaskSelected: function(task) { _syncSlotForSelection(task) }

    function _fetchSlots() {
        if (!_isSiteATC || _mySiteId <= 0) return
        // 使用闸（2026-09-05）：仅**可用**机位作降落/停靠点——过滤判据全程在**后端** ListSlots
        // （缺省档 = 已核准 ∧ status='FREE'，旧构建不带参也一样被过滤；?only_validated=1 保留
        // 仅为对旧后端兼容的无害显式），「指定机位」弹窗因此不含未核准/维护/故障机位；
        // 审批入口在 webui 站点与机位。本端不再重复实现列表过滤。
        _get("/api/sites/" + _mySiteId + "/slots?only_validated=1", function(status, data) {
            if (status === 200 && Array.isArray(data)) _slots = data
            else console.warn("OpsView slots", status)   // 失败留痕，避免机位区空白且无人知晓
        })
    }
    // 机位**平面图**那一档（2026-09-18）：`include_unusable=1` ⇒ 已核准、**不论**机位状态
    //（维护/故障机位也要画出来，否则其余机位的相对方位会错——见 SlotLayout.qml 文件头）。
    //
    // ‼️ 与 `_fetchSlots` 是**两次请求**，不是"取一次再在前端 filter"：两个集合的判据都由后端定义
    //（缺省档的语义就是后端给的"可用"），前端自己 filter 等于把使用闸在客户端重实现一遍——
    // 那正是上面那条注释说的"本端不重复实现列表过滤"。多一个轮询请求，本站几十个机位，代价可忽略。
    function _fetchSlotsAll() {
        if (!_isSiteATC || _mySiteId <= 0) return
        _get("/api/sites/" + _mySiteId + "/slots?include_unusable=1", function(status, data) {
            if (status === 200 && Array.isArray(data)) _slotsAll = data
            else console.warn("OpsView slots(all)", status)
        })
    }

    //-------------------------------------------------------------------------
    // 站点飞控动作（机位 / 起飞 / 降落 / 停泊）
    //-------------------------------------------------------------------------
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
                if (status === 200) _guidedTakeoff(task)
                else console.warn("OpsView takeoff", status)
            })
        } else if (a.kind === "land") {
            _execLand(task)
        } else if (a.kind === "park") {
            _post("/api/tasks/" + task.task_id + "/park", null, function(status) {
                if (status !== 200) { console.warn("OpsView park", status); return }
                // 停泊离线命令（路径 C：gcs_server 只落库，命令由 QGC 发）：
                // MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN(246)，param1=4 autopilot 下电、param2=2 强制
                // 经该机自己的加密上行链路（LinkInterface）下发——同样按 deviceID 取机，
                // 而不是 activeVehicle（多机在连会把指令下到别的飞机上）。
                var v = _vehicleForTask(task)
                if (v) v.sendCommand(1, 246, false, 4, 2)
                else console.warn("OpsView 停泊：该机未连接，无法下发离线命令")
            })
        }
        _pendingAction = null
    }
    //---- 起飞/降落（MAVLink guided 指令）----
    // 取**本任务指定的那架**载具，不用 `activeVehicle`：后者是"当前选中"的载具，
    // 本站有两架同时在连时会**把指令发给另一架飞机**（原实现即如此）。
    function _guidedTakeoff(task) {
        var v = _vehicleForTask(task)
        if (!v) {
            // 原实现只 console.warn：后端已把任务落库成 TAKEOFF，本机却什么都没发、界面零反馈。
            QGroundControl.showMessageDialog(opsView, qsTr("起飞指令未发出"),
                qsTr("未找到该任务无人机（deviceID %1）的连接，起飞指令未下发，请检查现场链路。")
                    .arg(task && task.device_id ? task.device_id : "—"))
            return
        }
        v.guidedModeTakeoff(20)
    }
    function _guidedLand(task) {
        var v = _vehicleForTask(task)
        if (!v) {
            QGroundControl.showMessageDialog(opsView, qsTr("降落指令未发出"),
                qsTr("未找到该任务无人机（deviceID %1）的连接，降落指令未下发，请检查现场链路。")
                    .arg(task && task.device_id ? task.device_id : "—"))
            return
        }
        v.guidedModeLand()
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
                        _guidedLand(task)
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
    // 派生/过滤（站点专属：机位、流向）
    //-------------------------------------------------------------------------
    // **机位**状态文案（≠ 无人机状态；占用与否由 `current_uav_id` 派生，不是机位状态）。
    // 取值域 = `table_slot.status`，后端白名单单点在 `handlers/site.go` 的 `validSlotStatus`
    //（FREE / MAINTENANCE / FAULT）——三值三译名必须与 webui `src/utils/statusLabels.js` 的
    // `SLOT_STATUS_LABELS` **逐字对齐**（那边是同一个界面的另一个端，措辞漂了就对不上）。
    // 未知/空回退原样或 "—"：**fail-visible**——宁可让一个没跟上值域的机位显示原始枚举，
    // 也不要静默显示成「空闲」（那是在撒谎，维护中的机位会看着和可用机位一模一样）。
    function _slotStatusLabel(s) {
        switch (s) {
        case "FREE":        return "空闲"
        case "MAINTENANCE": return "维护"
        case "FAULT":       return "故障"
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
    // ⚠️ 只查**使用面** `_slots`（可用机位）：调用它的都是"能不能在这个机位起降/停靠"的判断，
    // 平面图里那些维护/故障机位不该在这里被找到。
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
        // 平面图上画着维护/故障机位，但它们**不在使用面** `_slots` 里 ⇒ 点了不亮。
        // 高亮一个不能起降的机位，等于告诉操作员"这台可以选"。
        var s = _slotById(slotId)
        if (!s) return
        _selectedSlotId = slotId
        var t = _taskForSlot(s)
        if (t) _selectedTaskId = t.task_id
    }
    // 取本任务**指定**的那架载具（按 deviceID 精确匹配），没有则 null。
    // 判据用 deviceID 而非 uav_no：后者是人工编号、与链路无关，无从据此认领载具。
    // 遍历 `multiVehicleManager.vehicles` 而不是反查 `CryptoController` 的 deviceID↔sysid 表：
    // 那张表**只增不删**，载具断开后记录仍在 ⇒ 判据会"粘住"恒真；vehicles 在断开时移除，
    // 遍历它天然自洽。
    function _vehicleForTask(task) {
        if (!task || !task.device_id) return null
        var vs = QGroundControl.multiVehicleManager.vehicles
        for (var i = 0; i < vs.count; i++) {
            if (vs.get(i).deviceID() === task.device_id) return vs.get(i)
        }
        return null
    }
    // 该任务的无人机是否已连到 QGC。
    function _uavOnline(task) { return _vehicleForTask(task) !== null }
    // 起飞按钮置灰的原因：逐条对应 _canTakeoff 的判据、顺序也一致。
    // 枚举一律转中文（界面不出现原始枚举是既定规则）。
    function _takeoffBlockReason(task) {
        if (!task) return ""
        if (!task.uav_id) return qsTr("任务未指派无人机")
        if (!task.uav_current_slot_id) return qsTr("无人机未停在任何机位，请先在停放页派位")
        if (task.uav_status !== "READY_TO_TAKEOFF") return qsTr("无人机尚未通过航前检查，请在停放页确认航前检查通过")
        if (!_uavOnline(task)) return qsTr("无人机尚未连接到本地面站，等待其心跳")
        return ""
    }
    // 起飞门控：**已完成航前预检 + 已停在机位 + 该机已连到 QGC**。
    // 2026-09-21 用户裁定（05 §6.0-D 由"建议"转正），与后端 `ops.Takeoff` 同一份判据：
    //   · `uav_status` 必须 READY_TO_TAKEOFF —— 原实现**完全不读 uav_status**，于是
    //     「只把飞机放进机位、状态还停在航前检查」按钮就亮了，正是用户报障的现象；
    //   · 该机明文心跳须已送达 QGC —— 否则后端落了库、本机却发不出 MAVLink 指令
    //     （见 _guidedTakeoff 的失败分支）。
    // 同时**删去**「有 takeoff_slot_id 则须与当前机位一致」的比对：05 §3.3 已于 2026-09-13
    // 令删除（该列是实际值快照、起飞时才写，拿它比对会造出"实际停 A、任务写 B ⇒ 拒绝起飞"的伪冲突）。
    function _canTakeoff(task) {
        if (!task || !OpsCommon.isOutbound(task, _mySiteId, _handoverById)) return false
        if (task.status !== "SCHEDULED" && task.status !== "READY") return false
        if (!task.uav_id || !task.uav_current_slot_id) return false
        if (task.uav_status !== "READY_TO_TAKEOFF") return false
        if (!_uavOnline(task)) return false
        return true
    }

    //=========================================================================
    // 注入槽 ①：命令条中段扩展区（骨架把它塞进命令条那行 Row 的末尾）
    //=========================================================================
    commandBarExtras: Component {
        // 根项是 `Row`：外层 Row 的 `spacing: 18` 同时作用于"时间↔本扩展区"与下面三组之间。
        Row {
            spacing: 18

            // 出站/进站勾选（站点操作员；控制右侧列表过滤）
            //
            // ‼️ 本条 Row 的**每个**子项（含下面三组 Row）都要自己 `anchors.verticalCenter`：
            // QML 的 `Row` 定位器**不改子项的 y** —— 不设就恒为 0 ⇒ 顶端对齐。而这里各组高度不同
            //（勾选框 46px = indicator 34 + 样式内边距；按钮组 22px），不设就各贴各的顶，
            // 看上去就是「机位 北 东」比「进站 / 出站」高了半个勾选框（2026-09-18 实测偏 **12px**，
            // 用户报的就是这个）。加了锚点之后本 Row 的中线实测 23 == 勾选框中线 23。
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                visible: opsView._isSiteATC
                CheckBox {
                    id: outboundCheck
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("出站")
                    checked: opsView._outbound
                    onToggled: opsView._outbound = checked
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
                    checked: opsView._inbound
                    onToggled: opsView._inbound = checked
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

            // 机位图朝向：北（上为北）/ 东（上为东）。样式与"双身份切换"同一套（56×22、
            // radius 3、选中 #2f6bd8、未选中描边 #9aa7bd），两个并排的切换组才不会看起来是两种控件。
            // ⚠️ 两个按钮的文案**不是枚举**（"N"/"E" 只活在代码里），故不需要走 uavStatusLabel 那类映射。
            Row {
                anchors.verticalCenter: parent.verticalCenter   // 见上：本 Row 比勾选框矮 24px
                spacing: 4
                // 只在机位图真的在场时出现：监控员视图里没有机位图，切了也没有东西会转
                visible: opsView._showSlotLayout
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#8fa1bd"; font.pixelSize: 11
                    text: qsTr("机位")
                }
                Repeater {
                    model: [qsTr("北"), qsTr("东")]
                    Rectangle {
                        width: 56; height: 22
                        radius: 3
                        color: (opsView._slotOrient === (index === 0 ? "N" : "E")) ? "#2f6bd8" : "transparent"
                        border.color: "#9aa7bd"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            // 选中/未选中**都是白字**（用户 2026-09-21 裁定：「图标东在没有选中的情况下，
                            // 也显示白色，不然看不到字」）。原先未选中用 #5c6b84，压在本命令条那层透明
                            // 背景（直接透出地图）上实测只有 **1.72:1**，肉眼只剩一个空框。
                            // 状态差异改由**底色**（选中 #2f6bd8）与**框线**表达，文字不再承担状态编码。
                            color: "#ffffff"
                            font.pixelSize: 11
                            text: modelData
                        }
                        MouseArea {
                            anchors.fill: parent
                            // 这是 `_slotOrient` 在全仓的**唯一写点**（含启动读取那条赋值）。
                            // 改状态与落盘必须成对出现：只改状态 ⇒ 本次会话生效、重启回落；
                            // 只落盘 ⇒ 界面当场不变。两句写在一起，别拆到别的信号里。
                            onClicked: {
                                opsView._slotOrient = (index === 0 ? "N" : "E")
                                QGroundControl.saveGlobalSetting(opsView._slotOrientSettingsKey, opsView._slotOrient)
                            }
                        }
                    }
                }
            }

            // 双身份切换控件（「站点／监控员」那组）**已删除**（2026-09-21）：
            // 用户裁定两个身份不允许重叠、不存在双身份，webui 建用户时已做两级角色互斥，
            // 故这组按钮永远不可见。视图分流改由 `MainWindow._onLoginSucceededForRole()` 承担，
            // 监控员是并列的 `RomView.qml`。此处不再保留——留着就是一份会漂移的死判据。
        }
    }

    //=========================================================================
    // 注入槽 ②：右栏中段（顶部=右栏顶、底部=姿态仪之上、左右=右栏两侧）
    //=========================================================================
    rightPanelContent: Component {
        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // 站点视图（SITE_ATC）：上部任务列表 + 下部两列机位（从底向上，高≤本区一半）
            Item {
                id: siteViewArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: opsView._isSiteATC
                clip: true

                // 机位图**所需右边栏宽**回送给视图（右栏宽由骨架持有，而 `slotLayout` 只活在本
                // 组件里）。见 `_slotDesiredPanelWidth` 的注释：跨出去直接读会在展开前拿到一次
                // null 且永不重估。Binding 非可视化对象，不参与下面的布局。
                Binding {
                    target: opsView
                    property: "_slotDesiredPanelWidth"
                    value: slotLayout.desiredPanelWidth
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    // ── 上部：任务列表（吃掉机位之外的剩余高度）──
                    TaskListPanel {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        tasks: OpsCommon.siteTasks(opsView._tasks, opsView._outbound, opsView._inbound,
                                                   opsView._mySiteId, opsView._handoverById)
                        handoverById: opsView._handoverById
                        nowMs: opsView._now
                        mySiteId: opsView._mySiteId
                        selectedTaskId: opsView._selectedTaskId
                        showSiteActions: opsView._isSiteATC
                        isRouteMonitor: false
                        cardMargin: opsView._taskCardMargin
                        cardRightGap: opsView._taskCardRightGap
                        cardGap: opsView._taskCardGap
                        liveTelemetryWindowMs: opsView._liveTelemetryWindowMs
                        canTakeoffFn: opsView._canTakeoff
                        takeoffBlockReasonFn: opsView._takeoffBlockReason
                        // 点整项：选中任务 + 同步点亮对应机位（骨架负责写 _selectedTaskId）
                        onTaskSelected: function(task) { opsView.selectTask(task) }
                        onTakeoffRequested: function(task) { opsView._pendingAction = {kind:"takeoff", task:task}; actionConfirmDialog.open() }
                        onLandRequested: function(task) { opsView._pendingAction = {kind:"land", task:task}; actionConfirmDialog.open() }
                        onParkRequested: function(task) { opsView._pendingAction = {kind:"park", task:task}; actionConfirmDialog.open() }
                        onAssignSlotRequested: function(task) { opsView._assignSlotError = ""; opsView._assignSlotTask = task; slotDialog.open() }
                        onHandoverProposed: function(taskId, phase) { opsView._proposeHandover(taskId, phase) }
                        onHandoverCancelRequested: function(handoverId) { opsView._cancelHandover(handoverId) }
                    }
                    // ── 下部：机位（按经纬度投影、贴底、装不下时可滚动）──
                    Flickable {
                        id: slotFlick
                        Layout.fillWidth: true
                        // = min(可用高上限, 机位簇自然高 + 底部留白)。原本是视图上的 `_slotAreaH`，
                        // 因 `slotLayout` 只活在本组件内（见上）而就地展开——`_slotAreaMaxH` 仍来自
                        // 骨架转发的 rightPanel/instrumentsBlock 尺寸，故那条"不许读 siteViewArea.height"
                        // 的防成环纪律原样保留。这个 min 也不能省：自然高**并不总**被 _slotAreaMaxH 夹住
                        //（求解器在"可读下限 lo 压过纵向解 sH"时会突破可用高，如 6 机位排成南北一线，
                        // maxAreaHeight=304 实测自然高 454），此时若不夹，机位区会取 464px 把整块场地吃掉、
                        // 上方任务列表只剩 145px。夹住之后由本 Flickable 纵向滚动兜底（滚动本来就是正解）。
                        readonly property real _areaH: Math.min(opsView._slotAreaMaxH,
                                                                slotLayout.naturalHeight + opsView._slotMargin)
                        Layout.preferredHeight: slotFlick._areaH
                        Layout.maximumHeight: slotFlick._areaH
                        clip: true
                        // 横向：机位簇比可见宽更宽时（可读下限撑破了边栏）才真的能滚；
                        // 纵向：同样只是在自然高被 _slotAreaMaxH 夹住时才滚。都是兜底，不是常态。
                        contentWidth: Math.max(slotLayout.naturalWidth + opsView._slotMargin * 2, width)
                        contentHeight: Math.max(slotLayout.naturalHeight + opsView._slotMargin, height)
                        boundsBehavior: Flickable.StopAtBounds
                        Column {
                            // 顶部弹性空白：机位少时把机位簇推到最底部（用户要求"机位靠下显示"）
                            Item {
                                width: 1
                                height: Math.max(0, slotFlick.height
                                                    - slotLayout.naturalHeight - opsView._slotMargin)
                            }
                            SlotLayout {
                                id: slotLayout
                                // ‼️ 宽度只由容器给，**不要**写成 max(naturalWidth, 容器宽)：
                                // naturalWidth 依赖 width（求解比例系数要用可用宽）⇒ 成环。
                                // 溢出交给外面 Flickable 的 contentWidth 表达。
                                width: slotFlick.width
                                height: slotLayout.naturalHeight
                                edgeMargin: opsView._slotMargin
                                // 机位间隔 = 任务列表两张卡之间的间隔（用户 2026-09-18：
                                // 「间隔参照任务列表中两个卡片的间隔」）。**单点定义**在
                                // `OpsCommon.taskCardGap`，这里只绑、不另写字面量。
                                fixedGap: opsView._taskCardGap
                                orient: opsView._slotOrient
                                slots: opsView._slotsMapView
                                maxAreaHeight: opsView._slotAreaMaxH
                                selectedSlotId: opsView._selectedSlotId
                                panelMinWidth: opsView._rightPanelMinW
                                panelMaxWidth: opsView._rightPanelMaxW
                                onSlotClicked: function (slotId) { opsView._selectSlot(slotId) }
                            }
                        }
                    }
                }
            }

            // 监控员的任务列表**已移出本文件**（2026-09-21）：它现在是并列的 `RomView.qml`。
            // 原先这里是 `visible: (!_showSiteView || !_isSiteATC) && _isRouteMon` 的第二个分支，
            // 靠命令条上那组「站点／监控员」切换显示。用户裁定不存在双身份后，这两个身份是两个
            // 独立视图、由登录身份直接决定，本视图内不再有任何"另一个视图"的判据。
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
                text: opsView._landBlockReason
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
                text: opsView._assignSlotTask ? qsTr("任务 %1 指定降落机位：").arg(OpsCommon.taskNo(opsView._assignSlotTask)) : ""
            }
            // 指派失败原因（保留弹框可换机位重试）
            Text {
                Layout.fillWidth: true
                color: "#ff6b6b"; font.pixelSize: 12
                wrapMode: Text.Wrap
                visible: opsView._assignSlotError !== ""
                text: opsView._assignSlotError
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: opsView._slots
                    delegate: Button {
                        width: 96; height: 32
                        text: modelData.slot_code + opsView._slotAssignHint(modelData)
                        enabled: opsView._slotAssignable(modelData)
                        onClicked: {
                            if (opsView._assignSlotTask) opsView._assignSlot(opsView._assignSlotTask.task_id, modelData.id, function(ok) {
                                if (ok) { slotDialog.close(); opsView._assignSlotTask = null }
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
        title: opsView._pendingAction
               ? (opsView._pendingAction.kind === "takeoff" ? qsTr("起飞确认")
                  : opsView._pendingAction.kind === "land"    ? qsTr("降落确认")
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
                    if (!opsView._pendingAction || !opsView._pendingAction.task) return ""
                    var t = opsView._pendingAction.task
                    var hint = opsView._pendingAction.kind === "takeoff" ? qsTr("将确认起飞并控制无人机升空")
                             : opsView._pendingAction.kind === "land"    ? qsTr("将发出降落指令：任务进入降落(LANDING)，引导无人机在本场着陆")
                             : qsTr("将终结本任务并对无人机下电停泊（不可撤销）")
                    return qsTr("%1\n任务「%2」 · 无人机 %3")
                        .arg(hint).arg(OpsCommon.taskNo(t)).arg(t.uav_no ? t.uav_no : "—")
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
                    onClicked: { actionConfirmDialog.close(); opsView._execPendingAction() }
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
}
