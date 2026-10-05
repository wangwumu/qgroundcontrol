import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// 「飞向接机机位」要构造 `QGeoCoordinate` 喂给 `Vehicle::guidedModeGotoLocation`。
// 与 `OpsRouteSync.qml` 同一用法（那边也是 `QtPositioning.coordinate(...)`）。
import QtPositioning

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
    // 确认框的锚点：**触发它的那张卡片的下缘**在窗口里的 y（用户 2026-09-28 要求确认框贴到卡片
    // 下方、与右边栏同宽）。由六个 `onXxxRequested` 在 `open()` 之前写入；`-1` 表示没有锚点，
    // 弹框兜底居中。每次点动作都会重写，所以关闭时不必清空。
    property real _confirmAnchorY: -1
    // 站点视图勾选：出站 / 进站 —— ‼️ 两个属性的**定义已上移到 `OpsShell`**（基类），不再是
    // 本文件的属性：地图上的飞机 marker 在骨架里，它上色时要读同一组值（理由见 `OpsShell`
    // 那两行上的注释）。这里继续直接读写即可（继承），但**别在这儿再定义一遍**——
    // 重复定义会把地图与列表分成两份各自漂移的值，且不报任何错。
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
    // 补扫入口②：任务列表到位后。`_tasks` 是骨架的属性（`OpsShell._tasks`），
    // 本文件是 `OpsShell` 的派生类，可以直接给它写信号处理器。
    // ⚠️ QML 对下划线开头属性的处理器命名是 `on_` + **保持首字符、第二个字母大写**
    //    （先例：`on_ActiveVehicleChanged` / `on_FlightModeChanged`）。
    // ⚠️ 这个处理器**多久**触发一次［2026-09-23 Task 3 评审订正：原文写"**不是** 2s 心跳"，
    //    在联机现场**不成立**］：
    //    `_tasks` 的赋值**带内容指纹守卫**（`OpsShell._fetchOverview` 里 `json !== _tasksJson` 才赋），
    //    但该指纹是 `JSON.stringify(data)`、**含每个任务的 `latest` 遥测**（`handlers/ops.go` 里
    //    `item.Latest = h.fetchLatestTelemetry(r.uavID)` 那一处 —— **按符号定位，别按行号**）；而 `OpsShell._fetchOverview` 里
    //    那段注释**自己就写着**「这一层**挡不住遥测**（`data` 带 `latest`，飞机一动就变）」。
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
    // 选中任务 → 找到停放其无人机的机位，点亮之；若是**到站**卡片，另把地图切到该飞机。
    // ⚠️ 本信号的**唯一**来源是列表点击（骨架 `selectTask` 发它）；点地图 marker 走的是
    //    `selectRoute`，**不发**这条信号——两条路各自管各自的视野，别以为这里是共用的。
    onTaskSelected: function(task) {
        _syncSlotForSelection(task)
        _focusMapOnInbound(task)
    }

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
    // `task` 整个传进来（而不是只传 `task_id`）：`_retargetLandingSlot` 要读 `task.status`
    // 才分得清"正常预占机位"与"降落流程中止后照提示来改派"（见那里的注释）。
    function _assignSlot(task, slotId, onDone) {
        var taskId = task.task_id
        // ‼️ `land` 段（飞机已进接机机位 10 m 圈、`AUTO.LAND` 已发出、正在原地下降）**拒绝改派**，
        //    而且必须在发 POST **之前**拒绝（2026-09-29 审查 C2）。
        //    原先是在 POST **之后**才由 `_retargetLandingSlot` 弹一句「本次改派未生效」——可那时
        //    库里的 `assign_slot_id` **已经改成新机位了**。后果不是"提示没说清楚"，而是：
        //    飞机降在**旧**机位，而落地时 `ops.Park` 写的是 `landing_slot_id = assign_slot_id`
        //    （即**新**机位，见 `handlers/ops.go` 的 `parkSlot := assignedSlotID`）
        //    ⇒ **旧机位没有任何占用登记** ⇒ 下一架执行降落时 `CheckLandingSlot` 判它
        //    `free: true`，被放行到**一架已经停在那儿的飞机**上。
        //    fail-closed 是刻意的：这个窗口只有几十秒，代价是**可逆的**（等落地完成再指定），
        //    而库里记错机位是不可逆的，且与「只能在机位上降落」同向。
        if (_landPhase === "land" && _landingTaskId === taskId) {
            QGroundControl.showMessageDialog(opsView, qsTr("降落已开始，本次改派未生效"),
                qsTr("无人机已进入原机位上空并开始下降，降落指令无法撤回，本次将降落在原机位。机位没有被改动，请在本次降落完成后再指定。"))
            if (onDone) onDone(false)
            return
        }
        _post("/api/tasks/" + taskId + "/assign-slot", { slot_id: slotId },
              function(status, data) {
                  if (status === 200) {
                      _poll()
                      // 「飞行中改派机位」：若这次改派针对的正是**正在执行降落流程**的那架飞机，
                      // 让飞机也跟上。此刻库里的 `assign_slot_id` 已经是新机位了（见
                      // `_retargetLandingSlot`：不改的话就是"库里指向新机位、飞机飞向旧机位"）。
                      _retargetLandingSlot(task.task_id, slotId)
                      if (onDone) onDone(true)
                  }
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
        case "land":           return qsTr("切换多旋翼降落确认")
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
        // ‼️ 这句必须与**实际落点**一致（2026-09-29 改）。原句是「随后返回起飞点、降落回原机位」
        //    ——那是旧实现（`guidedModeRTL` ⇒ PX4 RTL ⇒ home）的真实行为，而现在改成 Guided
        //    飞向**接机机位**。文案不改的话，操作员是照着一句**已经过时**的话去确认一个
        //    不可撤销的动作（点完确认，飞机就真飞了）。
        case "land":           h = qsTr("将发出降落指令：先切换为多旋翼并原地盘旋，随后飞向接机机位并在该机位降落（不可撤销）"); break
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
        //
        // ‼️ 起飞前先清掉**上一次飞行**的轨迹（用户 2026-09-29 要求）。
        //    ⚠️ 别把它当成"多余的一行"删掉：清空的**唯一**发生点是 `start()` 的**第一句**
        //    （`TrajectoryPoints.cc:45-49`），而 `start()` 由 `_updateArmed(true)` 调
        //    （`Vehicle.cc:1246`；`start()` 在 `:1253`、`stop()` 在 `:1259`）。`stop()` 本身
        //    **不清空**已采集的点（`TrajectoryPoints.cc:51-54`）。
        //    ⇒ **常规路径**（未解锁 → `startMission()` 解锁 → `start()` → `clear()`）旧点本来
        //      就会被清，本行在那一格是冗余的；
        //    ⇒ 但**按下起飞时飞机已处于解锁态**时，`_updateArmed` 的 arm 分支不会跑、
        //      `start()` 不被调用，旧点会在本次飞行里被继续追加 —— **那一格只有本行能清**。
        //    （2026-09-29 自纠：我原先写的根因「`stop()` 不清 ⇒ 本次必然接着上次画」是错的，
        //      症状另有原因，尚未定位。）
        //    顺序不能反：`startMission()` 会解锁，解锁才触发 `start()`，故必须**先清后启**。
        //    `clear()` 是 public slot（`TrajectoryPoints.h:24`），它发的 `pointsCleared`
        //    （`:29`）已由 `OpsShell.qml` 的轨迹线接管 ⇒ 地图立刻清空，本处不必再管绘制。
        v.trajectoryPoints.clear()
        v.startMission()
    }
    //---- 切换多旋翼降落（用户 2026-09-28；落点改为接机机位 2026-09-29）----
    // ⚠️ **本段整段没有机型判据**（2026-09-29 审查 C1）：`_execLand`、
    //    `_switchToMultirotorThenReturn`、以及列表里那个降落按钮
    //    （`TaskListPanel.qml` 的「切换多旋翼降落」）**都不看 `v.vtol`**。
    //    而 `Vehicle::_vtolState` 在非 VTOL 机体上恒为初值 0（见 `Vehicle.cc` 里
    //    `_handleExtendedSysState` 的 `if (vtol())` 那段注记）⇒ `OpsCommon.vtolTransitionDone(0)`
    //    恒为 false ⇒ 必然走满 30 秒超时，飞机已被 Hold 拽出航线悬停，而降落从未发出。
    //    用户 2026-09-29 裁定**暂只处理 VTOL** ⇒ 这里只标注、不加闸。将来要放行非 VTOL，
    //    判据须同时落在**按钮的 `visible`/`enabled`**（用户可见的第一道）与 `_execLand` 的入口上。
    //
    // 流程四步（2026-09-29 起）：`transition`（等转多旋翼）→ `goto`（飞向**接机机位**）
    // → `land`（发降落 + 等着陆确认）→ 空闲。四步的每一个失败分支都**弹可见对话框且不回落
    // 任何自动降落**——理由见 `_mcCheckTransitionComplete` 与 `_landFlowTick` 的段落注释。
    // 从按下按钮到确认落地之间的在途载具。用 `property` 而不是 JS 变量：`Connections.target`
    // 要绑它，而 QML 里给 JS 变量赋值不会发出变更信号。
    // ⚠️ 这是**单槽位**：多机并发切换的行为见 `_switchToMultirotorThenReturn` 里那道拒绝闸。
    property var _landingVehicle: null
    // 正在执行降落流程的**任务 id**（0 = 没有流程在跑）。「飞行中改派机位」要靠它判断
    // 这次【指定降落机位】针对的是不是这架飞机（见 `_retargetLandingSlot`）。
    //
    // ‼️ 为什么不能拿 `_landingVehicle` 去比对：`Vehicle.id` 是 **MAVLink system id**，
    //    而改派机位那条路拿到的是 `task.task_id` / `task.uav_id`（数据库主键）——两者是
    //    **不同的 id 空间**。比错的形状是"恒不相等"，表现为改派永远不生效且**不报错**，
    //    正是本次报障的同一类静默失败。
    property int _landingTaskId: 0
    // 降落流程的阶段位：`""`（空闲）/ `"transition"`（等转多旋翼）/ `"goto"`（已发指令、等飞到位）
    // / `"land"`（已发降落、等着陆确认）。
    //
    // ‼️ 不能省（2026-09-29）。`Connections` 在整个流程里一直挂在同一架飞机上，而 goto/land
    //    阶段每来一个心跳都会再触发 `_mcCheckTransitionComplete()`；此刻 `vtolState` 仍是
    //    `MAV_VTOL_STATE_MC`（`OpsCommon.vtolTransitionDone` 恒真）⇒ 没有阶段位就会**反复重发**
    //    `DO_REPOSITION`，而 PX4 每收到一次都重置到位判定 ⇒ 飞机永远到不了，
    //    必然走满 `_landGotoTimeoutMs` 然后不降落。
    property string _landPhase: ""
    // 接机机位坐标的快照。在 `_switchToMultirotorThenReturn` 里、**并发闸之后**取定
    //（为什么不在 `_execLand` 取，见那里的注释），飞行途中不再回读任务对象：
    // `_tasks` 每 2 秒被轮询整个换掉，回读会让目标点跟着换（且新数组里那一项可能已经不在）。
    // 「飞行中改派机位」是**显式**动作（`_assignSlot` 成功后重发落点），不靠这里隐式跟随。
    property real _landTargetLat: 0
    property real _landTargetLon: 0
    // 当前阶段的截止时刻（`Date.now()` 毫秒）。进入 `goto` / `land` 时各设一次。
    property real _landDeadlineMs: 0
    // 到达判定半径（米）。‼️ 调大是**危险方向**：站点 1 的机位测绘基本行距约 0.000225° ≈ 25 m，
    // 半径一旦超过半行距，就会把「停在邻位正上方」判成本位到达，于是飞机在**别人的机位**上降落。
    // 10 m 既小于半行距，又远大于悬停保持精度（GNSS 定位噪声的量级是米，不是十米）。
    readonly property real _landArriveRadiusM: 10.0
    // 等待转换完成的超时。机型脚本的 `VT_F_TRANS_DUR` 是 10 秒，这里留三倍余量。
    readonly property int _mcSwitchTimeoutMs: 30000
    // 飞向接机机位的总超时（含转弯、逆风、绕行）。
    readonly property int _landGotoTimeoutMs: 120000
    // 进入 `land` 段那一刻的高度（米，AMSL），以及"还在下降"的判定窗口与最小降幅。
    //
    // ‼️ 为什么**不**用「等固定秒数就判失败」：PX4 的下降速度是**分段**的
    //   （`MPC_Z_VEL_MAX_DN` / `MPC_LAND_ALT1` / `MPC_LAND_ALT2` / `MPC_LAND_SPEED`），
    //    从巡航高度落下来可能几十秒也可能几分钟，任何固定超时都会把「正在慢慢下降」
    //    误报成「没降落」——而误报的代价是操作员不再相信这条提示。
    //    改成看**高度有没有真的在掉**：60 秒掉不到 3 m（0.05 m/s，比 PX4 最慢的下降档还慢一个量级），
    //    才能断定降落模式没生效。
    property real _landStartAltM: 0
    readonly property int _landDescentCheckMs: 60000
    readonly property real _landMinDescentM: 3.0
    // 位置轮询周期。取 500 ms 的理由：判定圈半径 10 m，而多旋翼在 `MPC_XY_VEL_MAX`
    // 量级的速度下每周期位移在数米，不会一拍跨过整个圈；再密只是徒增刷新，不影响判定正确性
    //（判定是"当前位置在不在圈内"，不是"有没有穿过圈"）。
    readonly property int _landPollMs: 500

    Connections {
        target: opsView._landingVehicle
        // ‼️ 必须听 `vtolStateChanged`，**不能**听 `vehicleTypeChanged`：后者的全仓**唯一发射点**
        //    是 `Vehicle.cc:492` 的 `_offlineVehicleTypeSettingChanged`（离线机型设置，即 Plan 文件
        //    里带的机型），而 `_vehicleType` 全仓也只有 `:491` 那一个写入点 —— **心跳根本不碰它**
        //    （`_handleHeartbeat` 在 `:1308`，不写 `_vehicleType`）⇒ 飞行中它一次都不会发，
        //    无论飞机切得多成功，都必然走满 30 秒超时。
        //    （2026-09-29 审查 A4 修正：原注释写「只在心跳报的 `MAV_TYPE` 变化时才发」是错的。）
        function onVtolStateChanged() { opsView._mcCheckTransitionComplete() }
    }
    Timer {
        id: mcSwitchTimer
        interval: _mcSwitchTimeoutMs
        onTriggered: {
            if (!_landingVehicle) return
            _clearLandFlow()
            // 不能静默：此刻飞机既没飞向接机机位也没降落，还在原地盘旋，操作员必须知道指令没发出去。
            QGroundControl.showMessageDialog(opsView, qsTr("切换多旋翼未完成"),
                qsTr("已发出切换指令，但无人机在 %1 秒内未报告转换完成，降落指令未发出。无人机当前在原地盘旋。")
                    .arg(Math.round(_mcSwitchTimeoutMs / 1000)))
        }
    }
    // 飞向接机机位之后的两段等待共用一个 Timer，按 `_landPhase` 分派（见 `_landFlowTick`）。
    //
    // ‼️ 为什么用「轮询位置 + 自己判到达」而不是等 PX4 报到达：本流程走的是 **Guided**，
    //    `guidedModeGotoLocation` 发的是 `MAV_CMD_DO_REPOSITION`（一条 COMMAND_LONG），
    //    PX4 到位后**不回任何"已到达"事件**；唯一能拿到的 `MISSION_ITEM_REACHED`
    //    只有 mission 里的项才会发，而这里根本没有 mission。
    Timer {
        id: landFlowTimer
        interval: _landPollMs
        repeat: true
        onTriggered: opsView._landFlowTick()
    }
    /// 清空降落流程的全部在途状态。**所有**终止路径都必须走它。
    ///
    /// ‼️ 抽成函数不是为省行数：下面清掉的字段是**必须同生共死**的一组状态（它们描述的正是
    ///    "这架飞机走到哪一步了"）。终止路径散布在多个函数里，漏清任何一处，症状都是「下一次
    ///    点降落时行为诡异」——而那种缺陷 QML 既编译不出来、离屏也测不到。
    ///    ⇒ **新增终止分支时必须调它，不要手写那几行赋值；新增流程状态字段时必须在这里清掉它**
    ///    （本函数是这些状态的唯一清零点）。
    /// （刻意不列举"是哪几个函数、哪几个字段"：那种清单每加一次调用点就腐烂一次，而照着腐烂
    ///   的清单核对会给出一份虚假的安心。）
    function _clearLandFlow() {
        landFlowTimer.stop()
        mcSwitchTimer.stop()
        _landPhase = ""
        _landingVehicle = null
        _landingTaskId = 0
        _landTargetLat = 0
        _landTargetLon = 0
        _landDeadlineMs = 0
        _landStartAltM = 0
    }
    /// 转换完成（或本来就已是多旋翼）⇒ 飞向**接机机位**，而不是回家。
    ///
    /// ‼️ 落点为什么不是 home（2026-09-29 用户裁定「改为接机机位坐标」）：用户报障「切换 mc 降落前
    ///    换了机位、切回来又换一次，地图上接机降落点与起飞点一直重合，更换机位的动作没有起作用」。
    ///    根因是原实现走 `guidedModeRTL(false)` ⇒ PX4 RTL ⇒ 落点恒为 **home**，而 home 是**起飞点**；
    ///    `table_arrival_schedule.assign_slot_id`（ATC 指派的接机机位）**从未参与飞行**。
    ///    所以那不是"更换动作失效"，是**功能缺失**。
    ///    修法：转好多旋翼后 `guidedModeGotoLocation(接机机位坐标)` → 到达 → `guidedModeLand()`。
    ///
    /// ‼️ 为什么不改走航线里的降落点：上传的航线里**没有降落点**（`_endWaypointIndex` 恒回 -1，
    ///    因为 `/routes/:id/waypoints` 的响应不含 `end_waypoint_id`）⇒ `85 NAV_VTOL_LAND` 永不触发；
    ///    且 PX4 的 `MAV_CMD_NAV_VTOL_LAND(85)` 只在 `mavlink_mission.cpp` 里处理，
    ///    **只能当 mission item，不能单发 COMMAND_LONG**。
    ///
    /// ‼️ 为什么不用 `DO_SET_HOME` 把 home 改到机位：会**污染 home**——PX4 的 failsafe 回航点
    ///    也是它，改完一次之后所有失控保护都会飞向那个机位，而不只是这一次降落。
    ///
    /// `_poll()` 与 `_execReturn` 同一理由：库里的状态没变，但卡片要跟上。
    function _mcCheckTransitionComplete() {
        // ‼️ 阶段闸：本函数由 `vtolStateChanged` 驱动，goto/land 阶段的心跳会一遍遍进来
        //    （见 `_landPhase` 的注释）。没有它就会反复重发 goto。
        if (_landPhase !== "transition") return
        var v = _landingVehicle
        // 判据是「转换**已完成**」＝ `MAV_VTOL_STATE_MC`，**不是**「机型是多旋翼」：
        // `Vehicle::multiRotor()` 读心跳报的 `MAV_TYPE`，经 `QGCMAVLink::vehicleClass()`
        // 的纯 switch 把 `MAV_TYPE_VTOL_*` 全归到 `VehicleClassVTOL`，与多旋翼类不相交
        // ⇒ 对 VTOL 机体**恒为 false**，切成功了也判不出来（这正是 30 秒必超时的原因）。
        // 也不能用 `!vtolInFwdFlight`：那个 bool 在「转多旋翼中」(2) 就已经是 false ⇒ 会在
        // 转换途中就发指令，而 PX4 此刻仍视机体为固定翼，会重新落回卡死的 LOITER_DOWN。
        if (!v || !OpsCommon.vtolTransitionDone(v.vtolState)) return
        mcSwitchTimer.stop()
        // 纵深防御：`_execLand` 已在 `POST /land` **之前**验过坐标、`_switchToMultirotorThenReturn`
        // 又在并发闸之后取了快照（两处注释都有说明），所以经它们进来的调用**走不到**这一格。
        // 留着是防将来新增调用点直接进本段——那时若坐标是 0/0 就发 goto，飞机会**飞向几内亚湾**，
        // 而界面上"按钮可点、没有任何报错"。
        // ‼️ 判据按**坐标**、不按 `assign_slot_id`：机位被软删时后端下发 0/0/0 而 id 仍在
        //    （`handlers/ops.go` 里 `asl.deleted_at IS NULL` 那条 JOIN）——「有指派」≠「有可用落点」。
        if (!OpsCommon.isValidWaypoint(_landTargetLat, _landTargetLon)) {
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("没有可用的接机机位"),
                qsTr("未取得该任务的接机机位坐标（机位可能已被撤销），飞向机位与降落的指令均未发出。无人机当前在原地盘旋。"))
            return
        }
        // ‼️ 必须看返回值：`guidedModeGotoLocation` 在「飞机位置未知」（`altitudeAMSL` 为 NaN）时
        //    **一个字节都不发**并回 false。若当成功继续下去，下面的到达轮询会空转到超时，
        //    操作员只看到「超时」、看不到真正的原因。
        _landPhase = "goto"
        _landDeadlineMs = Date.now() + _landGotoTimeoutMs
        if (!v.guidedModeGotoLocation(QtPositioning.coordinate(_landTargetLat, _landTargetLon), 0)) {
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("飞向接机机位指令未发出"),
                qsTr("无人机当前位置未知，无法飞向接机机位，降落指令未发出。无人机当前在原地盘旋。"))
            return
        }
        landFlowTimer.restart()
        _poll()
    }
    /// `goto` 段：等飞到位；`land` 段：等着陆。
    ///
    /// ‼️ 两段的失败都**不回落任何自动降落**。用户 2026-09-28 定的红线是「除非要坠机了，
    ///    否则飞机只能在机位上降落」——回落 `guidedModeRTL(false)` 会落到 home＝**起飞点**，
    ///    而它未必是机位。悬停在原地是可控状态，比落到一个非机位的地方安全。
    function _landFlowTick() {
        var v = _landingVehicle
        // 本 Timer 只在 `goto`/`land` 两段里跑；其余阶段（含 `transition`，那段归 `mcSwitchTimer`）
        // 出现即异常，一并收干净，别让空转的 Timer 永远留在这儿。
        if (!v || (_landPhase !== "goto" && _landPhase !== "land")) { _clearLandFlow(); return }
        if (_landPhase === "goto") {
            var c = v.coordinate
            // 到达判据用 `OpsCommon.reachedSlot`（纯函数、已单测）：坐标无效 / 半径 ≤ 0 / NaN
            // 一律回 false ⇒ 位置报不上来时**不会**误判成"已到达"而就地降落。
            if (c && OpsCommon.reachedSlot(c.latitude, c.longitude, _landTargetLat, _landTargetLon, _landArriveRadiusM)) {
                _landPhase = "land"
                _landStartAltM = c.altitude
                _landDeadlineMs = Date.now() + _landDescentCheckMs
                // ‼️ 顺序：先换阶段位（本 Timer 不 stop，下一拍就用于等着陆），再发降落。
                //    `guidedModeLand()` 内部走 `FirmwarePlugin::_setFlightModeAndValidate`，
                //    那是个**阻塞**函数（3 轮 × 13 次 × 100 ms 的 `QThread::msleep`，中途
                //    `processEvents`）⇒ 期间本 Timer 仍会重入，而那时 `_landPhase` 已是 `land`，
                //    重入只会去读 `armed`，不会重复发指令。
                v.guidedModeLand()
                _poll()
                return
            }
            if (Date.now() >= _landDeadlineMs) {
                _clearLandFlow()
                QGroundControl.showMessageDialog(opsView, qsTr("未飞抵接机机位"),
                    qsTr("无人机在 %1 秒内未飞抵接机机位，降落指令未发出。无人机当前悬停中。")
                        .arg(Math.round(_landGotoTimeoutMs / 1000)))
            }
            return
        }
        if (_landPhase === "land") {
            // ‼️ 这一段为什么必须有：`Vehicle::guidedModeLand()` 返回 **void**，而它内部的
            //    `_setFlightModeAndValidate()` 的失败是**被丢掉的**（`PX4FirmwarePlugin::guidedModeLand`
            //    把返回值 `Q_UNUSED` 了）⇒ 从调用点**看不到**降落模式有没有生效。唯一可信的确认
            //    是**观测**。没有这一段，「发了降落但没生效」就退化成一架永远悬在机位上方的飞机
            //    + 一个不报错的界面 —— 正是本次报障的同一类缺陷。
            // 观测之一（成功）：落地后 PX4 按 `COM_DISARM_LAND`（默认 2 秒）自动上锁。
            if (!v.armed) {
                _clearLandFlow()
                _poll()
                return
            }
            // 观测之二（失败）：高度一直不掉 ⇒ 降落模式没生效。
            if (Date.now() >= _landDeadlineMs) {
                var alt = v.coordinate.altitude
                if (!isFinite(alt)) {
                    // 高度读不到就**不判**（宁可晚报，不可误报）：顺延一个窗口再试。
                    _landDeadlineMs = Date.now() + _landDescentCheckMs
                    return
                }
                if ((_landStartAltM - alt) >= _landMinDescentM) {
                    // 在下降，只是慢：把基准挪到当前高度再顺延一个窗口。
                    // ‼️ 必须**挪基准**：否则第一次掉够之后，后面每一拍都会因为"相对最初起点已掉够"
                    //    而永远顺延，飞机停在半空也不会报错。
                    _landStartAltM = alt
                    _landDeadlineMs = Date.now() + _landDescentCheckMs
                    return
                }
                _clearLandFlow()
                QGroundControl.showMessageDialog(opsView, qsTr("未确认降落"),
                    qsTr("已发出降落指令，但无人机在 %1 秒内既未着陆、高度也没有下降。降落指令可能未生效，请检查无人机状态。")
                        .arg(Math.round(_landDescentCheckMs / 1000)))
            }
        }
    }
    /// 「飞行中改派机位」：让**正在执行降落流程**的那架飞机改到新机位（用户 2026-09-29 裁定
    /// 「飞机改降到新机位」）。
    ///
    /// 调用点是 `_assignSlot` 的**成功回调**——所以库里的 `assign_slot_id` 此刻已经是新机位了。
    /// 本函数负责让**飞机**也跟上；不做的话就是"库里指向新机位、飞机飞向旧机位、界面上没有任何
    /// 提示"，与本次报障的静默不一致同类。
    ///
    /// ‼️ 坐标取自**机位列表** `_slots`（`slot.lat/lon`），不靠 `_poll()` 回来的任务对象：
    ///    `_poll()` 是异步的，它的响应到达时本函数早已执行完；而 `_slots` 里那个机位正是操作员
    ///    刚刚点中的那一个，坐标现成。第二个理由：`_tasks` 每 2 秒被整个换掉，回读任务对象会让
    ///    目标点跟着换（`_landTargetLat` 的声明注释有完整说明）。
    ///
    /// ‼️ 只对**同一架飞机**生效：不加 `_landingTaskId` 那一格的话，「A 机正在飞向机位、操作员
    ///    对 B 机点【指定降落机位】」会把 A 机改成飞向 B 的机位，全程没有任何报错。
    function _retargetLandingSlot(task, slotId) {
        var taskId = task.task_id
        // `_landPhase === ""` 与 `_landingTaskId === 0` 同生共死（都在 `_clearLandFlow` 里清），
        // 取其一即可；另一格留着是因为它才是"是不是这架飞机"的那一问。
        if (_landPhase === "" || _landingTaskId !== taskId) {
            // ‼️ 这一支**不能静默**（2026-09-29 审查 C1）。两种情形必须分开：
            //   (a) 任务不在 LANDING：这是最常见、也是最正常的「飞行中预占机位」——飞机还在飞，
            //       改派只改库、飞机不参与，此处什么都不做**正是对的**。
            //   (b) 任务已是 LANDING 却没有在途流程：说明此前那次降落**中止过**
            //       （转换超时 / 坐标不可用 / 未飞抵 / 未确认降落 / 并发被拒…）。而
            //       `POST /land` 在流程起头就把库里那个任务写成 LANDING 了，于是
            //       【切换多旋翼降落】的 `visible` 要求 `IN_FLIGHT` ⇒ 按钮不再出现；
            //       操作员照中止对话框的话来点【指定机位】，POST **真发出去了**、库里机位真改了，
            //       然后落到这里静默 return —— 弹窗关闭、飞机原地悬停、**零报错**。
            //       必须说出来，而且不能说"重新指定后重试"这类做不到的话。
            if (_landPhase === "" && task.status === "LANDING") {
                QGroundControl.showMessageDialog(opsView, qsTr("改派未生效：降落流程已停止"),
                    qsTr("新机位已记录，但该任务的降落流程此前已中止，无人机不会飞向新机位，也不会自动降落。当前界面没有重新发起降落的入口。"))
            }
            return
        }
        // ---- `land` 段：**刻意不重发** ----
        // `land` 意味着飞机已进入接机机位 10 m 圈、`AUTO.LAND` 已经发出，PX4 正在原地下降。
        // 此刻重发 `DO_REPOSITION` 会让飞机在机位上方**低空拉起再横飞**到邻位——站点 1 的机位
        // 基本行距只有约 25 m，那个高度上的横飞风险远大于"本次不改"。
        // ⚠️ 本支现在是**纵深防御**：`_assignSlot` 已在发 POST 之前就挡住了同一格（那里注释说明
        //    为什么必须在 POST 之前挡——挡晚了库里 `assign_slot_id` 会指向新机位，而落地时
        //    `ops.Park` 写的 `landing_slot_id` 取的就是它 ⇒ 旧机位失去占用登记）。
        //    所以这里的文案**不能**再写"新机位已记录"：走到这里时并没有改过库。
        if (_landPhase === "land") {
            QGroundControl.showMessageDialog(opsView, qsTr("降落已开始，本次改派未生效"),
                qsTr("无人机已进入原机位上空并开始下降，降落指令无法撤回，本次将降落在原机位。"))
            return
        }
        var s = _slotById(slotId)
        // 纵深防御 + 坐标有效性判据：能点到的机位必然在 `_slots` 里（弹窗的 `enabled` 读的就是
        // `_slotAssignable(s)`，同一个数组）——但 `_slots` 的 lat/lon 是非空列，脏数据仍可能是
        // 0/0，而 0/0 的后果是飞机飞向几内亚湾。
        if (!s || !OpsCommon.isValidWaypoint(s.lat, s.lon)) {
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("改派机位失败"),
                qsTr("未取得新机位的坐标，降落流程已停止，无人机当前在原地盘旋。"))
            return
        }
        _landTargetLat = s.lat
        _landTargetLon = s.lon
        // ---- `transition` 段：改快照就够了 ----
        // `goto` 还没发出去，转好多旋翼后 `_mcCheckTransitionComplete` 自然会用新坐标发指令。
        // ‼️ 这里**不能**顺手补发 goto：此刻机体可能还是固定翼，PX4 会把它当定高/定点指令、
        //    重新落回卡死的 `LOITER_DOWN`（见 `_mcCheckTransitionComplete` 里的同一段说明）。
        if (_landPhase === "transition") return
        // ---- `goto` 段：重发目标 ----
        // （`land` 与 `transition` 都已在上面的分支里 return，`_landPhase` 又只有这四个取值
        //   ⇒ 走到这里必然是 `goto`。将来若新增阶段，它也会静默落到本段——所以新增阶段时
        //   必须回来这里补判据，别只在 `_landPhase` 的声明注释里加一个值。）
        // 阶段位保持 `goto`（不换段），只把 deadline 推后：这是一次新的、完整的飞行。
        // `landFlowTimer` 一直在跑（`_mcCheckTransitionComplete` 里起的），不必重启。
        var v = _landingVehicle
        _landDeadlineMs = Date.now() + _landGotoTimeoutMs
        // ‼️ 必须看返回值：`guidedModeGotoLocation` 在「飞机位置未知」（`altitudeAMSL` 为 NaN）时
        //    一个字节都不发并回 false。理由与 `_mcCheckTransitionComplete` 里那一格相同。
        if (!v || !v.guidedModeGotoLocation(QtPositioning.coordinate(_landTargetLat, _landTargetLon), 0)) {
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("飞向新机位指令未发出"),
                qsTr("无人机当前位置未知，无法飞向新机位，降落流程已停止。无人机当前在原地盘旋。"))
            return
        }
    }
    /// 切换多旋翼降落：脱离回航 → 转为多旋翼 → 飞向接机机位 → 降落。
    ///
    /// ‼️ 为什么不只是「切多旋翼 + 重发回航」：`MAV_CMD_DO_VTOL_TRANSITION` 只做机体转换，
    /// **不换导航模式**。飞机已在回航中时，重发回航是**同一个**导航模式——PX4 的
    /// `NavigatorMode::run()` 只在"从非激活转激活"时调 `on_activation()`，同模式走 `on_active()`
    /// 分支，回航状态机原样不动，仍停在卡死的 `LOITER_DOWN` 格（固定翼进圈判定余量只剩 5 cm）。
    /// 先切 Hold 把导航模式挪开，后续的 Guided 指令才会重建状态机。
    ///（原实现此处重发的是 RTL，落点＝home＝**起飞点**；2026-09-29 改成 Guided 飞向接机机位，
    ///  理由见 `_mcCheckTransitionComplete` 的段落注释。）
    function _switchToMultirotorThenReturn(task) {
        var v = _vehicleForTask(task)
        if (!v) {
            QGroundControl.showMessageDialog(opsView, qsTr("降落指令未发出"),
                qsTr("未找到该任务无人机（deviceID %1）的连接，降落指令未下发，请检查现场链路。")
                    .arg(task && task.device_id ? task.device_id : "—"))
            return
        }
        // ‼️ 一次只等一架（2026-09-29 审查 C3）：`_landingVehicle` 是**单槽位**，第二架点降落会
        //    顶掉第一架的在途态 —— `Connections.target` 改指向第二架、`mcSwitchTimer.restart()`
        //    又把计时器重置 ⇒ 第一架转换完成后**没有任何处理器在听**、超时也不再触发
        //    ⇒ 那一架永远悬停在原地，且全程**没有任何可见错误**。
        //    修法是**拒绝并发并给出可见原因**，而不是把槽位换成按 deviceID 的 map：后者要在 QML 里
        //    用 `Instantiator` 动态建 `Connections`/`Timer`，是纯动态结构，而 `cmake --build` 对 QML
        //    语义零覆盖、离屏测试也够不到这段 —— 验证手段太弱。真正的多机并发切换留待后续单独做。
        if (_landingVehicle && _landingVehicle !== v) {
            QGroundControl.showMessageDialog(opsView, qsTr("已有一架无人机在降落中"),
                qsTr("另一架无人机的「切换多旋翼降落」仍在进行中，请等它完成或超时后再操作本架。"))
            return
        }
        // ‼️ 目标坐标的快照写在这里、**并发闸之后**：写早了会让被拒绝的那次调用污染正在飞的
        //    那一架的目标点（`_execLand` 的注释里有完整场景）。此后飞行途中不再回读 `task`
        //    —— `_tasks` 每 2 秒被整个换掉，回读会让目标点跟着换。
        //    取的是 `task.assign_slot_*`，与 `_execLand` 里那道校验读的是**同一个对象的同两个字段**
        //    ⇒ 不会出现"校验过的值"与"飞过去的值"不一致。
        _landTargetLat = task.assign_slot_lat
        _landTargetLon = task.assign_slot_lon
        // 阶段位与载具同生共死：`_landPhase` 描述的正是这架飞机走到哪一步了。
        _landingVehicle = v
        _landingTaskId = task.task_id
        _landPhase = "transition"
        // ‼️ 必须看返回值（2026-09-29 审查 C1'）：`hoverAndTransitionToMultirotor()` 在「本固件
        //    没有 Hold 模式」时**一个字节都不发**并回 false。若当成功继续下去，下面的 30 秒守卫
        //    会被"成功"分支停掉，而飞机仍在 RTL 里卡着 —— 操作员什么都看不到，症状与修之前一样。
        if (!v.hoverAndTransitionToMultirotor()) {
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("切换多旋翼指令未发出"),
                qsTr("本固件没有对应的悬停飞行模式，无法先脱离回航，切换指令未下发。无人机仍在回航中，请改用其它方式处置。"))
            return
        }
        // 本来就已是多旋翼时 `vtolStateChanged` 不会再发（状态没变），先自己查一遍；
        // 查完仍未完成，才等信号或超时。
        _mcCheckTransitionComplete()
        // ‼️ 判据是**阶段位**、不是 `_landingVehicle`：后者在 goto/land 阶段**仍然指着这架飞机**
        //    （轮询要靠它读位置与 `armed`）。若还用 `if (_landingVehicle)`，goto 期间就会把 30 秒的
        //    转换超时计时器一并重启 ⇒ 30 秒后它照样触发，把正在飞向机位的流程整个清掉并弹出
        //    「切换多旋翼未完成」。
        if (_landPhase === "transition") mcSwitchTimer.restart()
    }
    // 切换多旋翼降落（6.0-E 的按钮，LANDING 唯一写路径）：接机机位坐标校验 → 机位空闲校验 →
    // POST /tasks/:id/land（DB→LANDING）→ 脱离回航、转多旋翼、飞向接机机位、降落
    //（见 `_switchToMultirotorThenReturn`）。
    // ⚠️ 本函数**没有机型判据**（2026-09-29 审查 C1）：只看 `assign_slot_id` 与后端校验结果，
    //    非 VTOL 机体同样会走完全程。用户 2026-09-29 裁定**暂只处理 VTOL** ⇒ 只标注、不加闸。
    function _execLand(task) {
        if (!task) return
        // ‼️ 判据必须是 `assign_slot_id`（实际指派的降落机位），**不是** `landing_slot_id`
        //（那是落地后的快照、此刻恒空）。用后者等于**恒真地拦住每一次调用**，且失败形状是静默的：
        // 按钮看着能点，点下去什么都不发生，`console.warn` 用户在界面上看不见。
        //（2026-09-28 修；列表按钮的 `enabled` 是同一根因的另一处，两处必须同口径。）
        // 纵深防御：`enabled` 已挡住绝大多数情况，但本函数是 LANDING 的唯一写路径入口，
        // 留这道闸以防将来新增调用点绕过按钮——此时**必须给出可见原因**，不许静默返回。
        if (!task.assign_slot_id) {
            _landBlockReason = qsTr("该任务尚未指派降落机位，无法执行降落")
            landBlockDialog.open()
            return
        }
        // ‼️ 接机机位坐标必须在 `POST /land`（把任务改成 LANDING）**之前**校验（2026-09-29）。
        //    反过来做的话：库里已把任务写成 LANDING、飞机却因坐标不可用而原地盘旋 ——
        //    界面上任务卡显示"正在降落"，实际什么都没发生，正是本项目反复防的「谎报成功」。
        // ‼️ 判据按**坐标**、不按 `assign_slot_id`：机位被软删时后端下发 0/0/0 而 id 仍在
        //    （`handlers/ops.go` 里 `asl.deleted_at IS NULL` 那条 JOIN）——「有指派」≠「有可用落点」。
        // ‼️ 这里**只校验、不写任何状态**（2026-09-29）：本函数在并发闸**之前**执行，此处若写
        //    `_landTargetLat/Lon`，那么"A 机正在飞向机位、操作员又对 B 机点降落"时，B 的目标点会
        //    先落到全局状态上、再被并发闸拒绝 ⇒ **A 机改飞到 B 的机位**，且全程没有任何报错。
        //    快照写在 `_switchToMultirotorThenReturn` 里、并发闸**之后**（那里注释有说明）。
        if (!OpsCommon.isValidWaypoint(task.assign_slot_lat, task.assign_slot_lon)) {
            _landBlockReason = qsTr("该任务的接机机位坐标不可用（机位可能已被撤销），请重新指定接机机位")
            landBlockDialog.open()
            return
        }
        var tid = task.task_id
        _get("/api/tasks/" + tid + "/landing-slot-check", function(status, data) {
            if (status === 200 && data && data.free === true) {
                // ‼️ 未连接闸与并发闸必须在 `POST /land` **之前**（2026-09-29 审查 C3）。
                //    这两道闸原先只在 `_switchToMultirotorThenReturn` 里，而那个函数跑在 POST
                //    **之后** ⇒ 被闸拒绝时库里已经是 LANDING 了：「切换多旋翼降落」按钮
                //    （`visible` 要求 `IN_FLIGHT`）随之消失、飞机一条指令都没收到、任务卡却显示
                //    "正在降落" —— 又一处「谎报成功」，而且这一处连中止提示都没有。
                //    放在这里而不是更靠前，是因为 `/landing-slot-check` 是异步往返：这一格是
                //    POST 之前**最后**一个能判的时刻。
                //    `_switchToMultirotorThenReturn` 里那两道**保留**作纵深防御：那里的 `v` 是
                //    重新解析的（本往返期间链路可能已经掉），判据也不是同一份快照。
                var v = _vehicleForTask(task)
                if (!v) {
                    _landBlockReason = qsTr("未找到该任务无人机的连接，请检查现场链路")
                    landBlockDialog.open()
                    return
                }
                if (_landingVehicle && _landingVehicle !== v) {
                    _landBlockReason = qsTr("已有一架无人机在降落中，请等它完成或超时后再操作本架")
                    landBlockDialog.open()
                    return
                }
                _post("/api/tasks/" + tid + "/land", null, function(landStatus, data) {
                    if (landStatus === 200) {
                        _switchToMultirotorThenReturn(task)
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
    /// 选中**到站卡片**后把地图切到该飞机（用户 2026-10-02 裁定④）。用户原话
    /// 「到站任务卡片……除了选中外，不能对其做任何操作。当然，选中后，会把地图切到该飞机上」
    /// ——「选中后」承接的是同一段的「到站任务卡片」⇒ **只对进站任务**生效，
    /// 出站卡片的选中行为一字不动（那正是用户 2026-09-23 裁定的「地图中心=当前登陆站点」）。
    ///
    /// ‼️ 判据用 **`siteSection` + `sectionIsInbound`**，与卡片**配色**（`TaskListPanel` 的
    ///    `_inboundCard`）**逐字同一对函数、同一组实参**——用户看到的「青绿卡片」就是"选中会
    ///    拽地图"的充要条件。
    /// ⚠️ **不能图省事直接判 `OpsCommon.isInbound`**：那是**不看两个勾选框**的纯谓词
    ///    （勾选框由 `siteSection` 施加）。同站起降的航班（`isOutbound` 与 `isInbound` **同时为真**，
    ///    真库有这类场景，`route-same-station-check` 就是为它写的）**未接引**时会排在**段 2 出站**
    ///    、涂**出站蓝**，而裸 `isInbound` 仍为真 ⇒ 点它会拽地图，与用户看到的卡色矛盾。
    ///    更糟的是这种分叉**不报任何错**：只是某几张蓝卡片点了会动地图。
    /// ⚠️ 与配色判据一样，这里也**不重写**一份段序逻辑：判据每多一份拷贝，下次改口径就多一处
    ///    静默漏掉的地方（放宽 `isInbound` 时，那些漏掉的卡片点了没反应，而没有任何报错）。
    /// ⚠️ `TaskListPanel` 那边多一道 `panel.showSiteActions ? … : -1` 闸，这里**故意不照抄**：
    ///    那个面板被 `RomView` 以 `showSiteActions: false` 复用（同组件两种身份），少了闸就会给
    ///    监控员视图的卡片涂错色；而本函数只在站点视图点得到——`siteViewArea` 的
    ///    `visible: opsView._isSiteATC` 挡在前面 ⇒ 那道闸在这儿是**永不触发的死判据**。
    ///
    /// 落点复用「点地图上的飞机 marker」那条既有路径（`OpsShell.qml` 里 marker 的点击：
    /// `_mapFollowFirst = false` + `_mapManualCenter = <坐标>`，本函数是**逐字同款两行**）。
    /// ⚠️ 不说"`_mapManualCenter` 优先级最高"——骨架 `center` 绑定的**第一项**是
    ///    `routeLayersEnabled && _mapFollowFirst && _firstTaskCoord() !== null`，在监控员视图里
    ///    它**压在** `_mapManualCenter` 上面。本视图（`routeLayersEnabled === false`，站点视图的
    ///    默认值）那一项恒假 ⇒ `_mapManualCenter` 才是实际生效的那一支。
    ///    本函数**不调** `selectRoute`：marker 那条路调它，但 `selectTask` 在站点视图里
    ///    本来就跳过 `_selectedRouteId`（同 `routeLayersEnabled` 闸），这里跟它保持一致。
    ///
    /// 坐标**报文源优先**（与全系统口径一致：飞机位置吃报文不吃库）：
    ///   · 载具在线且已定位 ⇒ `vehicle.coordinate`；
    ///   · 否则回落 `task.latest` —— 后端 `ops.go` 的 `fetchLatestTelemetry`，按
    ///     `ORDER BY te.timestamp DESC, te.id DESC LIMIT 1` 取的**最后一帧遥测位置**，
    ///     **无相位过滤**（不是"落地位置"）。与骨架 `_firstTaskCoord()`（开局取景）同一口径。
    ///     ⚠️ `task.latest.lat` 同时当**真值判据**用（既有同款写法）：`lat` 恰为 0 时这一支
    ///     也不成立 ⇒ 赤道上的真位置同样取不到。这是继承来的口径，不在这里单独"修"。
    ///   · 两者都没有（载具掉了心跳、库里也没这一架）⇒ **不动地图**。
    ///
    /// 两道 `isValid` 是**防御**，不是"修一个已观测到的毛病"。2026-10-02 用探针
    /// （`/tmp/probe_center_invalid.qml`，offscreen）实测 `Map.center` 对无效坐标的反应：
    ///   · 标定格：`center: coordinate(31.2, 121.5)` ⇒ 读回 31.2/121.5（读回通路可用）；
    ///   · 赋 `coordinate(NaN, NaN)` ⇒ **center 纹丝不动**（仍是 31.2/121.5），QtLocation
    ///     **静默忽略**无效值，**不报错、不跳 (0,0)**；
    ///   · 正对照：紧接着赋 `coordinate(22.5, 114.0)` ⇒ 读回 22.5/114.0，证明上一格
    ///     "没变"是真的被拒，而不是这个属性被冻住了。
    ///   ⇒ 「无效坐标会让地图跳到几内亚湾」是**假的**（我原先就是这么写的，实测推翻）。
    /// ⚠️ **但 (0,0) 挡不住**：`QGeoCoordinate(0,0).isValid` 为 **true**（实测），是合法坐标。
    ///   能走到 `v.coordinate === (0,0)` 的路径只有 `Vehicle::_handleHighLatency2`
    ///   （`Vehicle.cc` 里那段 `_coordinate.setLatitude(highLatency2.latitude / 1E7)`
    ///   **没有 fix_type 闸**，而 `_handleGpsRawInt` 那条有 `>= GPS_FIX_TYPE_3D_FIX`）。
    ///   ‼️ 「路径存在」已 grep 确认，「**这些飞机会不会真发 HIGH_LATENCY2 且带 0**」**未实测**
    ///   ——不据此加判据；先按现状记在这里（`task.latest` 那支因真值判据已天然排除 lat=0）。
    function _focusMapOnInbound(task) {
        if (!task) return
        var sec = OpsCommon.siteSection(task, _outbound, _inbound, _mySiteId, _handoverById)
        if (!OpsCommon.sectionIsInbound(sec, task, _mySiteId, _handoverById)) return
        var c = null
        var vs = QGroundControl.multiVehicleManager.vehicles
        var v = (vs && vs.count > 0) ? OpsCommon.matchDeviceToVehicle(task, vs) : null
        if (v && v.coordinate && v.coordinate.isValid) {
            c = v.coordinate
        } else if (task.latest && task.latest.lat) {
            c = QtPositioning.coordinate(task.latest.lat, task.latest.lon)
        }
        if (c === null || !c.isValid) return
        _mapFollowFirst = false
        _mapManualCenter = c
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
        //    `t.deleted_at IS NULL AND COALESCE(t.uav_id,0) <> 0`（uavm 仓 `gcs_server/handlers/ops.go`
        //    的 `OpsHandler.Overview` 里那条**共享 WHERE** —— 按符号定位：
        //    `rg -n 'COALESCE(t.uav_id,0) <> 0'`，**别按行号**）—— **没有 status 过滤**；而 `device_id`
        //    来自同一条 SQL 的 `JOIN table_uav` ⇒ **历史任务也带着 device_id**。
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
            "get":     _get,
            // 起飞机位朝向的来源 —— `OpsRouteSync` 据此把起飞项（`cmd 84`）的坐标从 `home`
            // 偏到机位朝向上（见该文件 §④c）。这里**传整个 task** 而不是先取出朝向：
            // 朝向是 `createObject` 之后才算的，而 `createObject` 的初值只在建的这一刻求值一次
            // ⇒ 先把 task 交给它，由它自己按同一份数据算，避免"两处各算一遍"。
            "task":    task
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
        //    那个绑定是**起飞按钮的 `enabled`**（`TaskListPanel` 里那行
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
        //    （而它有内容指纹守卫，`OpsShell._fetchOverview`；飞机静止时可能很久不变）
        //    或 `multiVehicleManager.vehicles` 变化才偶然重估。
        //    ⇒ 用户看到的是"航线早就传完了，起飞按钮却一直不亮"—— 正是裁定 (a) 要消灭的现象。
        //
        //    先例同源：`OpsShell._fetchOverview` 的 `_tasks = data` 也是**整体替换**
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
    ///    （`Vehicle.h:222`，没有 `Changed` 后缀——QGC 的非标准命名）。
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
    // ‼️ 具体匹配已并入 `OpsCommon.matchDeviceToVehicle`（同一个 deviceID 查法，任务行与
    //    设备行共用）；这里只补 `vs` 的读取与 `count` 那一读。
    //    `vs.count` 是**依赖注册**不是短路优化：`vehicles` 是 `CONSTANT` 属性，而
    //    `.pragma library` 的函数体内读 `count` 不算进本绑定的依赖 ⇒ 不读它，载具上线后
    //    按钮状态永不重估（同 `OpsShell` 两处 marker 的注释）。
    function _vehicleForTask(task) {
        if (!task || !task.device_id) return null
        var vs = QGroundControl.multiVehicleManager.vehicles
        if (!vs || vs.count === 0) return null
        return OpsCommon.matchDeviceToVehicle(task, vs)
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
                        // ‼️ 只在**本 `Component` 内部**可见 —— 六个动作的锚点换算写在下面各自的
                        //    接收点里（它们同在这个 Component 内），根作用域的 `actionConfirmDialog`
                        //    够不到这个 id，故它只消费换算好的 `_confirmAnchorY`。
                        id: taskListPanel
                        // 交接弹框的位置锚点（`OpsShell._handoverAnchorFn`）：把"按 task_id 找卡片
                        // 下缘"的求值能力交给骨架。`taskListPanel` 的 id 只在本 `Component` 内可见
                        // （见上一条注释），根作用域够不到 ⇒ 只能在这里注入一个闭包。
                        // ‼️ `null` 与负数是**两回事**：`null` = 该任务不在本视图列表里（无锚点，
                        //    交给骨架退回居中）；负数是卡在列表里、只是滚出了可视区上方，照常换算，
                        //    由骨架按窗口高判有效性。混为一谈会让弹框贴到列表顶上（见
                        //    `TaskListPanel.cardBottomYForTask`）。
                        Component.onCompleted: opsView._handoverAnchorFn = function(taskId) {
                            var y = taskListPanel.cardBottomYForTask(taskId)
                            if (y === null) return -1
                            return taskListPanel.mapToItem(opsView, 0, y).y
                        }
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        tasks: OpsCommon.siteTasks(opsView._tasks, opsView._outbound, opsView._inbound,
                                                   opsView._mySiteId, opsView._handoverById)
                        handoverById: opsView._handoverById
                        nowMs: opsView._now
                        mySiteId: opsView._mySiteId
                        selectedTaskId: opsView._selectedTaskId
                        showSiteActions: opsView._isSiteATC
                        // 两个勾选框必须**与 `tasks` 用同一组值**：列表是 `siteTasks(..., _outbound,
                        // _inbound, ...)` 算出来的，而卡片配色要在面板里**重算一次**段号
                        // （拿不到段号，只拿得到过滤后的行）⇒ 传的不是同一组值就会"列表按 A 过滤、
                        // 颜色按 B 判"，看起来只是某几张卡颜色不对，没有任何报错。
                        outbound: opsView._outbound
                        inbound: opsView._inbound
                        isRouteMonitor: false
                        cardMargin: opsView._taskCardMargin
                        cardRightGap: opsView._taskCardRightGap
                        cardGap: opsView._taskCardGap
                        // 普通卡片边框＝浅蓝（用户 2026-10-06：「每个卡片加一个浅蓝色的边框」）。
                        // ‼️ `RomView.qml` 那个实例**同日也传了同一个色值**（用户随后点名了航线
                        //    列表与任务列表）—— 两个视图现在一致。色值在**两处各写一遍**，不共享
                        //    常量：改色要两处一起改，只改一处会让两个视图悄悄分叉。
                        // ⚠️ 三种语义边框色不受影响 —— 超时红 / 选中蓝 / 进站青绿在
                        //    `TaskListPanel.border.color` 的三元链里优先级更高，这里是最后一档。
                        cardBorderColor: "#6f9fd8"
                        canTakeoffFn: opsView._canTakeoff
                        takeoffBlockReasonFn: opsView._takeoffBlockReason
                        // 点整项：选中任务 + 同步点亮对应机位（骨架负责写 _selectedTaskId）
                        onTaskSelected: function(task) { opsView.selectTask(task) }
                        // ‼️ 六个动作都在 `open()` **之前**把触发卡片的下缘记进 `_confirmAnchorY`，
                        //    确认框的 `y` 绑定它 ⇒ 弹框长在那张卡片正下方。两个坐标系的换算在这里
                        //    做：信号给的是**卡片相对本组件**的下缘，弹框的 `y` 要的是**相对 opsView**，
                        //    故再过一次 `mapToItem`。（`card.y` 为什么不能用：见 TaskListPanel 处注释。）
                        onTakeoffRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"takeoff", task:task}
                            actionConfirmDialog.open()
                        }
                        onLandRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"land", task:task}
                            actionConfirmDialog.open()
                        }
                        onParkRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"park", task:task}
                            actionConfirmDialog.open()
                        }
                        onAssignSlotRequested: function(task) { opsView._assignSlotError = ""; opsView._assignSlotTask = task; slotDialog.open() }
                        onHandoverProposed: function(taskId, phase) { opsView._proposeHandover(taskId, phase) }
                        // 用户 2026-09-23：「执行"签出"、"取消"、"回航"都需要弹窗确认」。
                        // ‼️ 三者都是**先落库、再下指令**——写库那步在服务端事务里（见 `_execReturn`），
                        //    前端这里只负责"别让一次误触就直接发出去"。
                        onCheckoutRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"checkout", task:task}
                            actionConfirmDialog.open()
                        }
                        onReturnRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"return", task:task}
                            actionConfirmDialog.open()
                        }
                        // 【取消】(中段卡片) 与【撤回交接】(其余阶段) 是同一个动作的两个入口，
                        // 因此共用这一个信号、也共用同一次确认。`task` 可能缺失（老调用点只传 id）——
                        // 弹窗的提示语对 task 缺失是有兜底的，见 `_pendingConfirmHint`。
                        onHandoverCancelRequested: function(handoverId, task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
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
                // 深蓝 `#1565c0`，白底上 **5.75:1**（WCAG 及格线 4.5:1）。
                // 原为琥珀 `#ffc107`——那是**深色卡片**上的提示色（任务卡的通知条同族），
                // 搬到 `Dialog` 的浅色底上只剩 **1.63:1**，用户 2026-09-28 反馈"非常不明显"。
                color: "#1565c0"; font.pixelSize: 12
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
                            if (opsView._assignSlotTask) opsView._assignSlot(opsView._assignSlotTask, modelData.id, function(ok) {
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
        // 宽度与右边栏一致、右边缘贴窗口右缘（用户 2026-09-28）。原先没写 `x`/`y`，`Dialog` 缺省
        // 落在 (0,0) ⇒ 看起来在屏幕左上角。
        width: opsView.rightPanelWidth
        x: opsView.width - width
        // 上部与**触发它的那张任务卡片**的下缘对齐，留 6px。卡片靠下时向上收，别顶出屏幕底。
        y: opsView._confirmAnchorY < 0
           ? (opsView.height - height) / 2
           : Math.min(opsView._confirmAnchorY + 6, opsView.height - height - 12)
        modal: true
        // 标题与提示语都在 `_pendingConfirmTitle` / `_pendingConfirmHint` 里按 kind 分派（含"未识别"
        // 兜底）；此处保持绑定式调用，`_pendingAction` 一变两处一起重估。
        title: opsView._pendingConfirmTitle()

        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.fillWidth: true
                // 深蓝 `#1565c0`，白底上 **5.75:1**。原为琥珀 `#ffc107`（白底仅 **1.63:1**），
                // 用户 2026-09-28 反馈"非常不明显"。理由与上方 `landBlockDialog` 那条同源：
                // 琥珀是深色卡片上的提示色，不属于浅色的 `Dialog`。
                color: "#1565c0"; font.pixelSize: 13
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
