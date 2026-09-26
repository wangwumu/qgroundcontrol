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
    // 机位范围圈的**原料** → 骨架（`OpsShell._slotList` 声明处有完整说明）。
    // ‼️ 递过去的是**机位数组**，不是算好的圆：圆的圆心 = 站点坐标，而站点坐标是在**骨架里**
    //    异步到手的（`_fetchMySite` 的回调）⇒ 在本视图命令式算圆，站点坐标后到**不会**触发
    //    重算，圆永远画不出来。同 `rightPanelWidth`，用**绑定**把原料递进去
    //    （`OpsShell` 根项的 id `opsShell` 只暴露给声明它的那个组件，派生类型够不着）。
    // ⚠️ 源 `_slotListValue` 由 `_updateSlotList()` 按**几何指纹**维护，不是每次轮询都换数组：
    //    换身份会让地图上那个 `MapQuickItem` 的 `coordinate`/尺寸每 2s 重估一次。
    _slotList: _slotListValue

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
    property var  _slotsAll:       []      // 本站已核准机位（含维护/故障；平面图 + 范围圈用）
    // 范围圈的**原料**（本站已核准机位数组），绑定给骨架的 `_slotList`（见实例化处）。
    // 由 `_updateSlotList()` 按几何指纹维护，**不是**直接把 `_slotsAll` 递过去——理由见该函数。
    property var  _slotListValue:  []
    property string _slotRangeKey: ""   // 上一轮**几何指纹**（只含参与算圆的字段）
    property var  _assignSlotTask: null    // 机位选择弹框当前任务
    // 红绿确认动作。六个 kind 的载荷**不统一**，别照一个形状去读：
    //   takeoff / land / park / checkout / return → {kind, task}
    //   cancelHandover                            → {kind, handoverId, task}（task 可能为 undefined）
    // 标题与提示语按 kind 分派，见 `_pendingConfirmTitle` / `_pendingConfirmHint`。
    property var  _pendingAction:  null
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
    Component.onCompleted: {
        _slotOrient = _loadSlotOrient()
        // 补扫入口①：视图加载时，飞机可能**早已**连好（握手信号早发过、等不到）。
        _syncRoutesForAlreadyConnected()
    }
    // 补扫入口②：任务列表到位后。`_tasks` 是骨架的属性（`OpsShell.qml:97`），
    // 本文件是 `OpsShell` 的派生类，可以直接给它写信号处理器。
    // ⚠️ QML 对下划线开头属性的处理器命名是 `on_` + **保持首字符、第二个字母大写**
    //    （先例：`on_ActiveVehicleChanged` / `on_FlightModeChanged`）。
    // ⚠️ 这个处理器**多久**触发一次［2026-09-23 Task 3 评审订正：原文写"**不是** 2s 心跳"，
    //    在联机现场**不成立**］：
    //    `_tasks` 的赋值**带内容指纹守卫**（`OpsShell.qml:543`：`json !== _tasksJson` 才赋），
    //    但该指纹是 `JSON.stringify(data)`、**含每个任务的 `latest` 遥测**（`ops.go:243`
    //    `item.Latest = h.fetchLatestTelemetry(r.uavID)`）；而 `OpsShell.qml:540-541`
    //    的注释**自己就写着**「这一层**挡不住遥测**（`data` 带 `latest`，飞机一动就变）」。
    //    ⇒ **遥测链活着时，本处理器约每 2s 触发一次**；只有遥测不再产生新行（链路断/静止）
    //      时载荷才真的静止。
    //    ⇒ 入口①**仍然不可省**：它覆盖的是"**视图加载那一刻**飞机与任务就都已在位、
    //      且此后载荷不再变化"这一路（遥测链断时正是这种情形）。
    //    ⚠️ 它与入口③（"飞机**晚于**视图加载才连上"）覆盖的是**不同**场景，
    //      **谁也替代不了谁**［2026-09-23 复评订正：原文写"也正是入口③ 唯一要覆盖的场景"
    //      **是错的** —— 入口① 只在视图加载那一刻跑一次，按定义覆盖不到"之后才连上"这一路；
    //      而那正是入口③ 存在的唯一理由。］
    //    三条入口互为兜底，重复触发无害。
    on_TasksChanged: _syncRoutesForAlreadyConnected()
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
            if (status === 200 && Array.isArray(data)) { _slotsAll = data; _updateSlotList(data) }
            else console.warn("OpsView slots(all)", status)
        })
    }

    /// 本站机位范围圈的**原料**身份守卫
    ///（用户 2026-09-23：「…改为以站点坐标为中心，圈住各个机位，圆圈用虚线」）。
    /// 机位几何没变就保持原数组身份，不换。
    ///
    /// ‼️ 为什么不能直接把 `_slotsAll` 递给骨架：`_fetchSlotsAll` 每 2s 无条件给它赋一个
    ///    **新数组**，绑定会跟着每 2s 重估、并让骨架里的圆每 2s 产出**新对象**
    ///    ⇒ 地图上 `MapQuickItem` 的 `coordinate`/尺寸每 2s 重估一次。单次代价不大（不重建
    ///    item），但"轮询驱动的无谓重算"正是本项目反复踩的那类问题的起点
    ///    （`_taskGeom` / `_routeGeom` 的指纹守卫都是为同一个原因加的）。
    ///
    /// ‼️ **算圆不在这里**：圆心 = 站点坐标，而它在**骨架里**异步到手 ⇒ 必须由骨架做成绑定，
    ///    本函数只负责把原料按稳定身份递过去。见 `OpsShell._slotList` 声明处的完整说明。
    ///
    /// ⚠️ 指纹**只取参与几何的字段**（`id` / `lat` / `lon`）：`status`、`current_uav_*` 变了不
    ///    影响圆的形状，不该触发重算。也正因如此**不能**用 `JSON.stringify(data)` 整包比——
    ///    那会把"某架飞机停进来了"也算成几何变化。
    /// ⚠️ 机位全没了时 `key` 回落成空串、`siteCenteredCircle(_mySiteCoord, [])` 返回 `null`
    ///    ⇒ 圆圈消失 ✓
    function _updateSlotList(data) {
        var parts = []
        for (var i = 0; i < data.length; i++) {
            var s = data[i]
            parts.push((s ? s.id : "") + ":" + (s ? s.lat : "") + ":" + (s ? s.lon : ""))
        }
        var key = parts.join("|")
        if (key === _slotRangeKey) return
        _slotRangeKey = key
        _slotListValue = data
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
    // 红绿确认弹窗的标题/提示语（kind: takeoff / land / park / checkout / cancelHandover / return）。
    //
    // ‼️ 抽成函数是为了**消灭嵌套三元式的兜底分支**：原来标题是
    //   `kind==="takeoff" ? … : kind==="land" ? … : qsTr("停泊确认")`
    // 加了三个 kind 之后，新的三种会**静默落进最后那一档**——点【回航】看到的是
    // 「停泊确认 / 将终结本任务并对无人机下电停泊（不可撤销）」。QML 不会因此报错，
    // 只有人点开弹窗才看得见，而那时他正照着一句错误的话去确认一个危险动作。
    // `switch` 的 default 分支同理**不猜**：给一句明确说不清的提示，让人当场发现，
    // 也好过伪装成某个业务动作的文案。
    function _pendingConfirmTitle() {
        switch (_pendingAction ? _pendingAction.kind : "") {
        case "takeoff":        return qsTr("起飞确认")
        case "land":           return qsTr("降落确认")
        case "park":           return qsTr("停泊确认")
        case "checkout":       return qsTr("签出确认")
        case "cancelHandover": return qsTr("取消签出确认")
        case "return":         return qsTr("回航确认")
        default:               return qsTr("未识别的操作")
        }
    }
    function _pendingConfirmHint() {
        var a = _pendingAction
        if (!a) return ""
        var h = ""
        switch (a.kind) {
        case "takeoff":        h = qsTr("将发出起飞指令：无人机升空后沿该航线飞行"); break
        case "land":           h = qsTr("将发出降落指令：任务进入降落(LANDING)，引导无人机在本场着陆"); break
        case "park":           h = qsTr("将终结本任务并对无人机下电停泊（不可撤销）"); break
        // ⚠️ 一条 qsTr 只放**一个字符串字面量**：写成 `qsTr("甲" + "乙")` 时 lupdate 抽不出来，
        // 译文表里永远缺这一条，界面上就它一个不跟着语言走。
        case "checkout":       h = qsTr("将把本任务的飞行责任签出给航线监控员，等待其签入接管；无人机继续按原航线飞行，签出后本站仍可取消或回航"); break
        case "cancelHandover": h = qsTr("将撤回本次签出，飞行责任仍留在本站；无人机继续按原航线飞行"); break
        case "return":         h = qsTr("将发出回航指令：无人机返回起飞机场，并降落回原机位（不可撤销）"); break
        default:               return qsTr("无法识别的操作类型，请点「取消」并联系维护人员。")
        }
        // 「任务「%1」 · 无人机 %2」这一行是弹窗里**唯一**指明"对哪一单下手"的信息。
        // `task` 可能缺失（老调用点只传 id），此时不编造编号，直接说明缺了什么。
        var t = a.task
        if (!t) return h + qsTr("\n（未能取到任务信息，请确认操作对象后再执行）")
        return qsTr("%1\n任务「%2」 · 无人机 %3")
            .arg(h).arg(OpsCommon.taskNo(t)).arg(t.uav_no ? t.uav_no : "—")
    }

    // 红绿确认动作执行（kind: takeoff→DB 落库 + 起飞指令；land→机位校验 + 降落指令；park→DB 停泊收尾 + 离线下电；
    //                          checkout→建 ROUTE 交接；cancelHandover→撤回自己提的交接；return→回航落库 + RTL）
    function _execPendingAction() {
        var a = _pendingAction
        if (!a) return
        var task = a.task
        if (a.kind === "checkout") {
            // 签出（用户 2026-09-23 要求二次确认）：纯管理动作，**没有 MAVLink 指令**——
            // 它只建一条 ROUTE 交接待监控员接管，飞机照原样飞。
            if (task) _proposeHandover(task.task_id, "ROUTE")
            _pendingAction = null
            return
        }
        if (a.kind === "cancelHandover") {
            // 取消/撤回签出：同样是纯管理动作。`cancelHandover` 的幂等口径见 `_cancelHandover`
            //（404 视为已被他端处理＝成功）。
            if (a.handoverId) _cancelHandover(a.handoverId)
            _pendingAction = null
            return
        }
        if (a.kind === "return") {
            if (task) _execReturn(task)
            _pendingAction = null
            return
        }
        if (!task) return
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
    //---- 起飞 / 降落 ----
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
        // ‼️ 2026-09-23 由 `guidedModeTakeoff(20)` 改为 `startMission()`。
        //
        // 原实现只发 `MAV_CMD_NAV_TAKEOFF`，PX4 完整执行完它该做的事 —— **升到 20 m
        // 进 AUTO_LOITER 悬停**（用户报障现象：「起飞后，px4升空到20米，悬停」）。
        // 该指令**本来就不负责沿航线飞**；「起飞并进入航线」的原子动作在 PX4 侧是
        // 「切 AUTO_MISSION + 解锁」：`PX4FirmwarePlugin::startMission` 的全部内容
        // 就是这两步，PX4 在 AUTO_MISSION 下遇第一个 takeoff item 自动起飞。
        // QGC 自己的提示语也写着 "Takeoff and start the current mission"。
        //
        // 硬编码的 20 m 一并去掉：高度由**航线的第一个航点**决定（用户 2026-09-23
        // 裁定 e），已在 Task 1/2 里写进 mission 的起飞项。
        v.startMission()
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

    // 回航（用户 2026-09-23）：「任何时候，执行"回航"都导致飞机原机位降落」。
    //
    // ‼️ 顺序是硬的——**先写库、再下指令**（同日用户工程指令：「任何操作先写数据库状态，再执行
    // 相应指令」）。后端在一个事务里做完全部落库：`landing_site_id` 改回起飞机场、原机位写回
    // 到站指派、释放 `uav.current_slot_id`、作废在途交接、补一条已签入(LANDING)——**没有这一步，
    // 飞机飞回来也落不下来**（`Land` 的机位占用与"本站尚未签入(LANDING)"两道闸）。
    // 反过来先发 RTL 的话：指令下去了而库里没记，界面显示飞机还在航线上，它却已经在往回飞
    // ——正是本项目反复防的那类"谎报成功"。
    //
    // 指令用 `guidedModeRTL(false)`＝PX4 AUTO.RTL（"Return"）。取**本任务指定的那架**载具而不是
    // `activeVehicle`，理由与 `_guidedTakeoff` 同一份：本站有两架在连时会把指令发给另一架飞机。
    function _execReturn(task) {
        if (!task) return
        _post("/api/tasks/" + task.task_id + "/return", null, function(status, data) {
            if (status !== 200) {
                // 透传服务端业务原因（403 的「签出已由航线监控员接管，回航决策权归航线监控员」
                // 是操作员最需要看到的一句），避免只显示 "HTTP 403" 无从处置。
                QGroundControl.showMessageDialog(opsView, qsTr("回航未生效"),
                    ((data && (data.error || data.reason)) || ("HTTP " + status)) +
                    qsTr("\n数据库未做任何改动，飞机仍在原航线上。"))
                console.warn("OpsView 回航失败:", status, JSON.stringify(data))
                return
            }
            var v = _vehicleForTask(task)
            if (!v) {
                QGroundControl.showMessageDialog(opsView, qsTr("回航指令未发出"),
                    qsTr("未找到该任务无人机（deviceID %1）的连接，RTL 指令未下发，请检查现场链路。")
                        .arg(task && task.device_id ? task.device_id : "—"))
                _poll()   // 库已改：卡片要立刻从出站移到进站，别让界面停在旧状态上
                return
            }
            v.guidedModeRTL(false)
            _poll()
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
    //=========================================================================
    // 航线下发（2026-09-23 用户裁定 a）
    //
    // 「在qgc与px4完成握手，即自动上传航线，航线传完了，在点亮"起飞"按钮」
    //
    // 每个任务一份 `OpsRouteSync`，值挂在 `_routeSyncs[task_id]` 上。
    // 起飞闸（`_takeoffBlockReason`）读它的 `synced`。
    //=========================================================================
    property var _routeSyncs: ({})

    /// 取出任务对应的同步器（没有就造一个）。**幂等**：已存在时直接返回旧的。
    ///
    /// ‼️ 幂等判据是"这个 key 存不存在"，**不是**"同步成功没" —— 正在同步中也不能
    ///    重开一份，否则两路 XHR + 两个 `sendToVehicle()` 会互相打架，且后一份的
    ///    `startStaticActiveVehicle` 会把前一份刚绑定的 mission 清掉。
    function _syncRouteForTask(task, vehicle) {
        if (!task || !task.task_id || !task.route_id) return null
        // ‼️ **只对尚未起飞的任务下发航线。** 判据是 `status ∈ {SCHEDULED, READY}`，
        //    与起飞按钮的渲染条件（`TaskListPanel.qml` 里那个 `visible`）、`_canTakeoff`（本文件同函数名）
        //    是**同一个集合** —— 三处要同步改。
        //
        //    为什么必须有这道闸（2026-09-23 真库实测，**不是假想**）：
        //    `/ops/overview` 的 WHERE 是
        //    `t.deleted_at IS NULL AND COALESCE(t.uav_id,0) <> 0`（uavm 仓
        //    `gcs_server/handlers/ops.go:180`）—— **没有 status 过滤**；而 `device_id`
        //    来自 `JOIN table_uav`（`:167`）⇒ **历史任务也带着 device_id**。
        //
        //    真库当前就有：`device_id=91002` 挂着 **2 个**任务 —— `91102:READY`（活跃）
        //    与 `91104:CANCELED`（历史）。两者 `device_id` 相同 ⇒ 都会匹配。
        //
        //    没有这道闸的后果：两个任务各建一个 sync、各自 `sendToVehicle()`，
        //    两条航线**互相覆盖**，最终飞机上是哪条**取决于 XHR 返回时序（不确定）**；
        //    而两个 sync 各自都会报 `done` ⇒ 起飞闸照样放行 ⇒
        //    **飞机可能按已取消任务的航线飞，界面上完全看不出来** —— 比"没下发"更危险。
        //
        //    `TAKEOFF` / `IN_FLIGHT` 等已在飞的状态同样要挡：那时下发会打断正在执行的任务。
        if (task.status !== "SCHEDULED" && task.status !== "READY") return null
        var ex = _routeSyncs[task.task_id]
        if (ex) {
            // 目标飞机换了（同一任务改派了另一架）⇒ 重置后重发。
            if (ex.vehicle !== vehicle) { ex.reset(); ex.vehicle = vehicle; ex.start() }
            return ex
        }
        var sync = _routeSyncComponent.createObject(opsView, {
            "vehicle": vehicle,
            "routeId": task.route_id,
            "get":     _get
        })
        if (!sync) {
            // `createObject` 失败在 QML 里**不报错**，只静默回 null。
            console.warn("OpsView: OpsRouteSync 创建失败，任务", task.task_id, "的航线不会下发")
            return null
        }
        // ‼️ **必须整体重新赋值 `_routeSyncs`，不能写 `_routeSyncs[task.task_id] = sync`。**
        //
        //    `property var` 持有 JS 对象时**按引用比身份**：`_routeSyncs[id] = sync` 是
        //    **原地改内容**，**不发 `_routeSyncsChanged`** ⇒ 读它的绑定**不重估**。
        //
        //    而 Task 4 的 `_canTakeoff` 会通过 `_routeSyncs[task.task_id]` 建立绑定依赖，
        //    那个绑定是**起飞按钮的 `enabled`**（`TaskListPanel.qml:270`：
        //    `enabled: panel.canTakeoffFn ? panel.canTakeoffFn(modelData) : false`），
        //    它由「函数调用」间接读 —— QML 的依赖捕获跟着整个调用栈走，**所以能建立**。
        //
        //    **时序才是问题**：QML 的属性绑定在**子组件初始化时首次求值**，
        //    **早于**根组件的 `Component.onCompleted`。而"飞机早于视图加载就连好"
        //    这一路（正是最常见的一路：用户准备起飞时飞机必然已连）走的恰是
        //    `Component.onCompleted` → `_syncRoutesForAlreadyConnected()` → 本函数。
        //    ⇒ 首次求值时 `_routeSyncs` 还是空的 `({})`，`sync` 是 `undefined`，
        //    **那次求值没有建立对任何 sync 属性的依赖**。
        //    ⇒ 若这里不发信号，按钮会**一直灰着**，只能等 `_tasks` 指纹变化
        //    （而它有内容指纹守卫，`OpsShell.qml:543-545`；飞机静止时可能很久不变）
        //    或 `multiVehicleManager.vehicles` 变化才偶然重估。
        //    ⇒ 用户看到的是"航线早就传完了，起飞按钮却一直不亮"—— 正是裁定 (a) 要消灭的现象。
        //
        //    先例同源：`OpsShell.qml:543-545` 的 `_tasks = data` 也是**整体替换**
        //    （那边是为了让委托重建，这边是为了让绑定重估；同一个 QML 语义）。
        // ‼️ **必须是新对象**［2026-09-23 Task 3 评审订正］：`_routeSyncs = _routeSyncs`
        //    （把同一个引用赋回去）在 QML 里**不发 `Changed` 信号** —— `property var`
        //    按引用/值比较，"赋回自己"在**两种语义下都判定相等** ⇒ 绑定不重估
        //    ⇒ 起飞按钮**永远灰着**，而这正是本段注释要消灭的现象。
        //    `Object.assign({}, …)` 造出新对象，**在两种语义下都必然发信号**，代价为零。
        var m = Object.assign({}, _routeSyncs)
        m[task.task_id] = sync
        _routeSyncs = m
        sync.start()
        return sync
    }

    Component {
        id: _routeSyncComponent
        OpsRouteSync { }
    }

    /// 某架飞机握手完成（参数已同步、`initialConnectComplete` 已置位）⇒ 把它名下
    /// 尚未同步的任务挂上航线下发。
    ///
    /// ‼️ 用 `deviceID` 匹配，**不用** `activeVehicle`（多机场景会把航线发错飞机）。
    function _onVehicleConnected(vehicle) {
        if (!vehicle) return
        var ts = _tasks
        if (!ts) return
        for (var i = 0; i < ts.length; i++) {
            var t = ts[i]
            if (!t || !t.device_id || t.device_id !== vehicle.deviceID()) continue
            if (!t.route_id) continue
            _syncRouteForTask(t, vehicle)
        }
    }

    /// 补扫：QGC 启动时飞机**已经**连好的那一批——`initialConnectComplete` 早发过了，
    /// 信号等不到。判据用属性而不是信号。
    function _syncRoutesForAlreadyConnected() {
        var vs = QGroundControl.multiVehicleManager.vehicles
        for (var i = 0; i < vs.count; i++) {
            var v = vs.get(i)
            if (v && v.initialConnectComplete) _onVehicleConnected(v)
        }
    }

    /// 飞机名单变化的监听：**每架飞机挂一个 `Connections`**，`Repeater` 会随
    /// `vehicles` 自动增删委托。
    ///
    /// ‼️ 为什么是 `Repeater` + 空 `Item` 包装，而不是看起来更省事的
    ///    `Instantiator { delegate: Connections { ... } }`：
    ///    `Instantiator` 确实能创建非 `Item` 对象，但**本仓库的两个非 Item 先例
    ///    （`ShapePath`、`QGCMenuItem`）都把创建出来的对象交给了别人保管**
    ///    （`onObjectAdded` 插进 Shape 的 data list / 插进菜单）——「`Instantiator`
    ///    自己持有一个非 `Item` 且不转手」**没有任何先例**，是在赌 Qt 的生命周期语义。
    ///    而空 `Item` 包装（多一个不可见 Item，代价可忽略）走的是全标准用法：
    ///    `Repeater` + `Item` delegate + **角色名 `object`**。
    ///    先例：`src/FlyView/FlyViewMap.qml`（`:264` / `:275` / `:300`）、`src/PlanView/PlanView.qml:381`
    ///    都是 `Repeater { model: QGroundControl.multiVehicleManager.vehicles }`。
    ///
    /// ‼️‼️ **这个模型不能用 `modelData`，必须用角色名 `object`**［2026-09-23 Task 3 评审订正，
    ///    原文写 `modelData` 是错的，会让入口③ 变成**永不触发的死代码**］：
    ///    · `multiVehicleManager.vehicles` 是 `QmlObjectListModel`，其 `roleNames()` 继承
    ///      `ObjectItemModelBase::roleNames()`（`src/QmlControls/ObjectItemModelBase.cc:30-36`），
    ///      返回**两个**角色：`{ObjectRole,"object"}` 与 `{TextRole,"text"}`；
    ///    · Qt 对 QAbstractItemModel 型 delegate 的角色注入：**只有一个角色时** `modelData`
    ///      才是那个角色的值，**否则拼成 `QVariantMap`** ⇒ 这里是
    ///      `{object: Vehicle*, text: "…"}`，**不是 `Vehicle`**；
    ///    · 后果：`Connections.target: modelData` 把 map 赋给 `QObject*` ⇒
    ///      **`Unable to assign QVariantMap to QObject*`**、`target` 保持 null、
    ///      该 `Connections` **从未连到任何飞机** ⇒ 握手完成时航线**不会**下发。
    ///      （`opsView._onVehicleConnected(modelData)` 收到 map 也会抛 `TypeError`，双重失效。）
    ///    · **全仓先例一律是 `object`**：`FlyViewMap.qml:266/277/287`、`:308`（`property var _vehicle: object`）
    ///      —— **零处**对该模型用 `modelData`。用 `modelData` 的那几处
    ///      （`MultiVehicleSelector.qml:64`、`VehicleSummary.qml:93`）**都是 JS 数组 / `QVariantList`**，
    ///      不是这个模型；原文"全仓 324 处 `modelData` 先例"**套错了模型**。
    ///
    /// ‼️ `onInitialConnectComplete` 这个处理器名**不是笔误**：`Vehicle` 的
    ///    `initialConnectComplete` 属性用的 NOTIFY 信号就叫 `initialConnectComplete`
    ///    （`Vehicle.h:214`，没有 `Changed` 后缀——QGC 的非标准命名）。
    ///    处理器名 = `on` + 信号名首字母大写。
    Repeater {
        model: QGroundControl.multiVehicleManager.vehicles
        Item {
            visible: false
            Connections {
                target: object
                function onInitialConnectComplete() { opsView._onVehicleConnected(object) }
            }
        }
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
        // 新增①：航线下发（2026-09-23 用户裁定 a：「航线传完了，在点亮"起飞"按钮」）。
        // 不判就会让飞机按 **PX4 上的残留航线**飞 —— 现场实测的那个残留是 8 月遗留的
        // 3 个苏黎世航点，而界面上完全看不出来。
        var sync = _routeSyncs[task.task_id]
        if (!sync) return qsTr("航线尚未开始下发，请稍候")
        if (sync.state === "failed") return sync.statusText
        if (!sync.synced) return qsTr("航线下发中：%1").arg(sync.statusText)
        // 新增②：GPS 定位（2026-09-23 用户裁定 c：「px4的gps必须完成定位后，才能起飞」）。
        // 起飞点取**飞机当前 home 位置**，home 无效 ⇒ 没有可用的起飞坐标。
        var v = _vehicleForTask(task)
        if (!v || !v.homePosition.isValid) return qsTr("无人机尚未完成 GPS 定位，无法起飞")
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
    // ⚠️ 2026-09-23 起本判据**比后端 `ops.Takeoff` 多两条**（航线已下发、GPS 已定位）。
    //    这两条是**地面站侧**的事实——后端观测不到 QGC 有没有把航线下发到飞机，
    //    故不对称是必然而非疏漏。**不要**为了"对齐"去给后端补校验，它做不到。
    function _canTakeoff(task) {
        if (!task || !OpsCommon.isOutbound(task, _mySiteId, _handoverById)) return false
        if (task.status !== "SCHEDULED" && task.status !== "READY") return false
        if (!task.uav_id || !task.uav_current_slot_id) return false
        if (task.uav_status !== "READY_TO_TAKEOFF") return false
        if (!_uavOnline(task)) return false
        var sync = _routeSyncs[task.task_id]
        if (!sync || !sync.synced) return false
        var v = _vehicleForTask(task)
        if (!v || !v.homePosition.isValid) return false
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
                        // 用户 2026-09-23：「执行"签出"、"取消"、"回航"都需要弹窗确认」。
                        // ‼️ 三者都是**先落库、再下指令**——写库那步在服务端事务里（见 `_execReturn`），
                        //    前端这里只负责"别让一次误触就直接发出去"。
                        onCheckoutRequested: function(task) { opsView._pendingAction = {kind:"checkout", task:task}; actionConfirmDialog.open() }
                        onReturnRequested: function(task) { opsView._pendingAction = {kind:"return", task:task}; actionConfirmDialog.open() }
                        // 【取消】(中段卡片) 与【撤回交接】(其余阶段) 是同一个动作的两个入口，
                        // 因此共用这一个信号、也共用同一次确认。`task` 可能缺失（老调用点只传 id）——
                        // 弹窗的提示语对 task 缺失是有兜底的，见 `_pendingConfirmHint`。
                        onHandoverCancelRequested: function(handoverId, task) {
                            opsView._pendingAction = {kind:"cancelHandover", handoverId:handoverId, task:task}
                            actionConfirmDialog.open()
                        }
                        // 【签入】**刻意不弹窗**，与上面三条**不同族**：签出/取消/回航会改变责任归属
                        // 或直接给载具下指令；签入只是把已经摆在面前的待办接过来（提出方那边
                        // 已经确认过一次了）。同一族的先例是卡片上的「申请切出」与「移交降落指挥」
                        // （都直接抛）、以及交接弹框里的「确认接管」。⚠️ 失败反馈仍然有——由
                        // `_checkinFromCard` 复用交接弹框给出，与弹框内的失败是同一套。
                        onCheckinRequested: function(handoverId, task) { opsView._checkinFromCard(handoverId, task) }
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
    // 飞行控制动作红绿确认弹框：起飞/降落/停泊 + 中段飞行的签出/取消/回航六种（用户 2026-09-23
    // 要求后三者也要确认）。交接的**受理**（签入/驳回）仍走 handoverDialog——那是另一回事。
    // 红=确认执行（危险动作警示）、绿=取消（安全退出）。未来专用控制台做大红/大绿实体按钮。
    //-------------------------------------------------------------------------
    Dialog {
        id: actionConfirmDialog
        parent: opsView
        width: 460
        modal: true
        // 标题与提示语都在 `_pendingConfirmTitle` / `_pendingConfirmHint` 里按 kind 分派（含"未识别"
        // 兜底）；此处保持绑定式调用，`_pendingAction` 一变两处一起重估。
        title: opsView._pendingConfirmTitle()

        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.fillWidth: true
                color: "#ffc107"; font.pixelSize: 13
                wrapMode: Text.Wrap
                text: opsView._pendingConfirmHint()
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
