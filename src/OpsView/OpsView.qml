import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// `QtPositioning.coordinate(...)` 用来构造 `QGeoCoordinate`（地图聚焦用，见 `_focusMapOnInbound`）。
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
    // 机位选择弹框的**两种用途**（同一个 `Dialog` 复用，别新开一个）：
    //   "assign" = 【指定机位】：选中即 `POST /assign-slot` 落库（原行为，未动）。
    //   "land"   = 【降落】/【切换多旋翼降落】的**第一步**：**只选、不写库**。
    //             用户 2026-10-08 裁定「**确认执行时才写**」⇒ 落库推迟到红绿确认框的
    //             「确认执行」那一下（`_commitLand`）。
    // ‼️ 两种用途**必须分开**，不能在 "land" 档里提前 POST：那样"选完机位又点【取消】"
    //    也会在库里留下一次机位变更（库里已改、飞机没动、界面上不留任何痕）。
    property string _slotDialogMode: "assign"
    // mode === "land" 时走哪条降落路（`OpsCommon.LAND_KIND_KEEP_FW` / `LAND_KIND_TO_MC`）。
    // 由 `_beginLandFlow` 写、由 `slotDialog` 的 delegate 读、塞进 `_pendingAction.kind`。
    property string _slotDialogLandKind: ""
    // 红绿确认动作。八个 kind 的载荷**不统一**，别照一个形状去读：
    //   takeoff / keepFwLand / land / mcRescueLand / park / checkout / return → {kind, task}
    //   cancelHandover                                                       → {kind, handoverId, task}（task 可能为 undefined）
    // 标题与提示语按 kind 分派，见 `_pendingConfirmTitle` / `_pendingConfirmHint`。
    property var  _pendingAction:  null
    // 确认框的锚点：**触发它的那张卡片的下缘**在窗口里的 y（用户 2026-09-28 要求确认框贴到卡片
    // 下方、与右边栏同宽）。由八个 `onXxxRequested` 在 `open()` 之前写入；`-1` 表示没有锚点，
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
    // 才分得清"正常**指派**机位"与"降落流程中止后照提示来改派"（见那里的注释）。
    function _assignSlot(task, slotId, onDone) {
        var taskId = task.task_id
        // ‼️ **正在下降时拒绝改派** —— 判据取遥测 `landing`，而且必须在发 POST **之前**拒绝
        //    （2026-09-29 审查 C2）。
        //    ⚠️ 本行上方原写「`land` 段（飞机已进接机机位 10 m 圈、`AUTO.LAND` 已发出、
        //       正在原地下降）」—— 那是统一链**之前**的机制，且 `_landPhase` 现在根本没有
        //       `"land"` 这个取值（只有 `""` / `"transition"` / `"autonomous"`）。判据早已
        //       换成 `landing` 属性，语义见 `_landFlowTick` 里关于 `Vehicle::_setLanding` 那段。
        //    原先是在 POST **之后**才由 `_retargetLandingSlot` 弹一句「本次改派未生效」——可那时
        //    库里的 `assign_slot_id` **已经改成新机位了**。后果不是"提示没说清楚"，而是：
        //    飞机降在**旧**机位，而库里的机位登记已经跟着改派走了 —— 两半都错，且**旧机位的
        //    登记丢失比原先更早**（2026-10-08 方案 (a) 之后）：
        //      ① `handlers/ops.go` 的 `AssignSlot` 在 `LANDING` 段**同事务**把
        //         `uav.current_slot_id` 从旧机位迁到新机位 ⇒ **改派事务提交的那一刻**旧机位
        //         就没有任何占用登记了（方案 (a) 之前这一步不存在，登记要到 ② 才丢）；
        //      ② 落地时 `ops.Park` 写的是 `landing_slot_id = assign_slot_id`
        //         （即**新**机位，见 `handlers/ops.go` 的 `parkSlot := assignedSlotID`）
        //         —— 连快照也记成新机位。
        //    ⇒ **旧机位没有任何占用登记** ⇒ 下一架执行降落时 `CheckLandingSlot` 判它
        //    `free: true`，被放行到**一架已经停在那儿的飞机**上。
        //    fail-closed 是刻意的：这个窗口只有几十秒，代价是**可逆的**（等落地完成再指定），
        //    而库里记错机位是不可逆的，且与「只能在机位上降落」同向。
        if (_landingVehicle && _landingVehicle.landing && _landingTaskId === taskId) {
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
                      // ‼️ **传 `task` 整个对象，不是 `task.task_id`**（2026-10-08 终局审查 F1 修）。
                      //    该函数的两个形参判据都读对象字段（`task.task_id` / `task.status`），
                      //    传数字会让两者都成 `undefined` ⇒ `_landingTaskId !== undefined` 恒真
                      //    ⇒ 函数体**整段永不执行**，且第一支的弹窗也因 `task.status` 为
                      //    `undefined` 而不弹 ⇒ **改派全程静默失效**（库里改了、飞机不跟）。
                      //    `_assignSlot` 的形参名也是 `task`，上面 `taskId` 取自同一对象，
                      //    改这里时容易被"看起来同形"骗过去。
                      _retargetLandingSlot(task, slotId)
                      if (onDone) onDone(true)
                  }
                  else {
                      _assignSlotError = (data && (data.error || data.reason)) || ("HTTP " + status)
                      console.warn("OpsView assign-slot", status, JSON.stringify(data))
                      if (onDone) onDone(false)
                  }
              })
    }
    //-------------------------------------------------------------------------
    // 【降落】/【切换多旋翼降落】的**两步入口**（用户 2026-10-08 裁定）
    //-------------------------------------------------------------------------
    // 用户原话：「选择"降落"按钮后，应该弹出一个界面选择机位，而不是这个确认提示。在选择完
    // 机位后，才可以弹出在合格确认对话框。」「这个对话框框中的解释性文字不需要，把对话框改成
    // 一个类似任务卡片的风格，提示的内容有三行： 任务：,无人机：,机位。」
    // 以及 AskUserQuestion 的第三条裁定：「**确认执行时才写**」。
    // ⇒ 四步：点【降落】→ 选机位（**只选，一个字节都不写库**）→ 红绿确认框（卡片式三行）→
    //    「确认执行」时**才** `POST /assign-slot`，成功后再走 `_execLand`（机位校验 →
    //    `POST /land` → 统一降落链）。
    //
    // ‼️ 为什么"点【降落】时必须先选机位"，而不是直接拿列表里已有的 `assign_slot_id`：
    //    改前弹的直接是确认框，正文只有一句「将发出降落指令…」+ 任务号/无人机号，
    //    **一个字都没提落点是哪个机位** —— 操作员是在确认一个他没看见的落点。
    //    先选机位，落点就是他自己刚点的那一个。
    // ⚠️ 列表项上的 `assign_slot_id` **不是**【降落】/【切换多旋翼降落】的 `enabled` 判据 ——
    //    理由在**降落链的顺序**：点按钮 → 弹出选择机位框（`_beginLandFlow` 的
    //    `slotDialog.open()`）→ 选完**并确认后**才写库。"选机位"发生在点击**之后**，所以"库里
    //    有没有已指派机位"**不可能**是点击的**前置**；拿它当判据就是把顺序搞反了。
    //    历史留档：这两颗按钮确实拿 `assign_slot_id` 当过判据（2026-09-29 引入、2026-10-08 删）。
    //    那道前置**单独**只是把按钮误灰；会在整条链上合成**死锁**的是它与【指定机位】入口
    //    **同时**收紧 —— 从未指派过机位的任务两颗降落按钮灰着，而指派它的入口也不可点。
    //    ‼️ 但这只是**条件**，2026-10-08 那一轮**没有**发生：同轮只把【指定机位】的 `visible`
    //    从 `_inboundActionable`（**含 IN_FLIGHT**）**收窄**为
    //    `card._inboundActionable && modelData.status !== "IN_FLIGHT"`、**并未删除**那颗按钮
    //    —— IN_FLIGHT 段照旧可点 ⇒ 死锁当时不成立。要把 `visible` 再收到连 IN_FLIGHT 也拦掉、
    //    且本判据又被改回来，死锁才成立（判据变迁的完整留档见 `TaskListPanel.qml` 两颗按钮处）。
    //    本列表项上的它现在只用于**回显当前落点**，不门控。
    // ⚠️ 口径：`assign_slot_id` 是「**指派**」（计划落点，**非占用**）；占用判据是 `current_uav_no`。
    //
    // `cardBottomY` 是**已经过 `mapToItem` 换算到 opsView 坐标系**的下缘（与另外七个
    // `onXxxRequested` 逐字同款），确认框的 `y` 绑的就是它：先选机位、后弹确认框，中间隔着
    // 一次用户操作，所以这个锚点要由本函数**先存下来**再等（`_confirmAnchorY` 的声明注释写的
    // "每次点动作都会重写，所以关闭时不必清空"在这里仍然成立）。
    function _beginLandFlow(task, kind, cardBottomY) {
        if (!task) return
        _confirmAnchorY = cardBottomY
        _assignSlotError = ""
        _assignSlotTask = task
        _slotDialogLandKind = kind
        _slotDialogMode = "land"
        slotDialog.open()
    }
    /// 确认框正文用**卡片式三行**（而不是解释性长句）的那两档：F1 保持固定翼 / F2 切换多旋翼。
    /// ‼️ **不含 F3**（`mcRescueLand`）：救济档的正文是**另一套版式**（见 `_isRescueKind`）——
    ///    它以「重要提示：」起头、整段是醒目警示（用户 2026-10-06 第 7 条「位置、姿态、高度
    ///    不可预测」那条路的验收内容），下面才是条目行；而且救济**不选机位**（用原任务已指定的
    ///    机位），压根凑不出「机位：」这一行。
    function _isLandSummaryKind(a) {
        return !!a && (a.kind === "keepFwLand" || a.kind === "land")
    }
    /// 救济档（F3，界面上叫**「直接降落」**）的正文版式（用户 2026-10-08 第五轮）：
    ///   「重要提示：」+ **悬挂缩进**的长警示语，下接「任务：」「无人机：」两行条目。
    /// ‼️ 与 `_isLandSummaryKind` **并列而不是包含**：两套版式的行数、行名、配色都不同
    ///    （救济没有「机位：」行 —— 它用原任务已指定的机位，操作员不选）。
    function _isRescueKind(a) {
        return !!a && a.kind === "mcRescueLand"
    }
    /// 「任务：」那一行的取值。
    /// ‼️ **刻意不用 `OpsCommon.taskNo()`**：那个函数**优先取 `uav_no`**
    ///    （`task.uav_no ? task.uav_no : task.task_no`，"航班号"语义），而本行要的是**任务号**。
    ///    照搬它会让弹框里「任务：」与「无人机：」两行**显示同一个值**（云端库实测两者确实不同：
    ///    task 91106 = `task_no: TASK_DXK_001` / `uav_no: UAV-10001048`），
    ///    而用户要的就是三行各说一件事。
    function _landConfirmTaskNo(a) {
        return (a && a.task && a.task.task_no) ? a.task.task_no : "—"
    }
    /// 「无人机：」那一行的取值（取 `uav_no`，与任务卡上「航班：」那一行同源）。
    function _landConfirmUAVNo(a) {
        return (a && a.task && a.task.uav_no) ? a.task.uav_no : "—"
    }
    /// 「机位：」那一行的取值 —— 就是操作员**上一步刚选中的那个机位**。
    /// ⚠️ 取 `a.slot`（用户选的那个）而**不是** `a.task.assign_slot_id`：此刻库还没写
    ///    （用户裁定「确认执行时才写」），列表项上那个 id 是**旧的**，拿它显示等于在确认框里
    ///    报一个不是本次落点的机位。
    function _landConfirmSlotCode(a) {
        return (a && a.slot && a.slot.slot_code) ? a.slot.slot_code : "—"
    }
    /// 把**本次选中的机位**盖到任务对象的一个**副本**上，再交给 `_execLand` / `_startLandFlow`。
    ///
    /// ‼️ 为什么要副本：那两个函数读的是 `task.assign_slot_*`（`_execLand` 的坐标闸、
    ///    `_startLandFlow` 的落点/进近点、`_landingTaskId`），而列表项是 `_poll()` 每 2s 换一次
    ///    的只读快照，**不能就地改**（改了也只会被下一次轮询冲掉，还会污染列表渲染）。
    /// ‼️ **全量拷贝再覆写三个字段，不写白名单**：那两条链还要读 `task_id` / `status` /
    ///    `device_id`（`_vehicleForTask`）/ `uav_id` / `uav_no`…，白名单漏一个字段就是一处
    ///    **静默**失效 —— `_assignSlot` 里那次"传数字而不是传对象"的教训（`_retargetLandingSlot`
    ///    整段永不执行、零报错）就是这么来的。
    /// ⚠️ `heading` 必须一起盖：F1（保持固定翼）要用机位**朝向**算进近点，用旧机位的朝向会算出
    ///    一个与新机位无关的进近点，而 `_startLandFlow` 一旦算出 `p` 就会照发。
    function _taskWithSlot(task, slot) {
        var t = {}
        for (var k in task) t[k] = task[k]
        t.assign_slot_id = slot.id
        t.assign_slot_lat = slot.lat
        t.assign_slot_lon = slot.lon
        t.assign_slot_heading = slot.heading
        return t
    }
    /// 「确认执行」那一下：**先写库、再下指令**（本项目的工程口径，与 `_execReturn` 同向）。
    ///
    /// ‼️ 写库放在这里而不是选机位那一步，是用户 2026-10-08 的逐字裁定（「确认执行时才写」）；
    ///    代价是"选了机位又点取消"不留痕 —— 正是这条裁定要的效果。
    /// ‼️ 写库**失败不许静默**：`_assignSlot` 的失败分支只把原因写进 `_assignSlotError`，
    ///    而此刻选机位框和确认框**都已经关了** ⇒ 不重开的话，操作员看到的就是"点了确认执行、
    ///    什么都没发生"（那正是本项目反复防的静默失败形状）。重开选机位框有两个作用：
    ///    把那句红字显示出来，并让他就地改选一个机位。
    function _commitLand(a) {
        var task = a ? a.task : null
        var slot = a ? a.slot : null
        if (!task || !slot) return
        var kind = a.kind
        _assignSlotError = ""
        _assignSlotTask = task
        _assignSlot(task, slot.id, function(ok) {
            if (!ok) {
                // ⚠️ 落库**没成功**，所以这条降落路到此为止：绝不能继续 `_execLand`
                //    （`POST /land` 会把任务写成 LANDING，而落点仍是库里的旧机位 ⇒
                //    又一次"库里记 A、飞机降 B"）。
                _slotDialogMode = "land"
                _slotDialogLandKind = kind
                slotDialog.open()
                return
            }
            _assignSlotTask = null
            _execLand(_taskWithSlot(task, slot), kind)
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
        case "keepFwLand":     return qsTr("降落确认")
        case "land":           return qsTr("切换多旋翼降落确认")
        case "mcRescueLand":   return qsTr("MC方式降落（救济功能）")
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
        // ‼️ 降落两档（F1 保持固定翼 / F2 切换多旋翼）**不走本函数**：它们的正文已按用户
        //    2026-10-08 的要求换成**卡片式三行摘要**（`_isLandSummaryKind` + `actionConfirmDialog`
        //    里那个深色 `Rectangle`），解释性长句删掉。
        //    这里返回空串，而不是把旧文案留在 `case` 里：留着的话，一旦那个 `visible` 判据哪天
        //    被写坏（QML 里 `undefined && x` 这类**静默**失效），界面会重新冒出一句既不该出现、
        //    又与本轮实际落点无关的长句，而没有任何东西会报错。
        // ⚠️ 被删掉的那两句留档（别以为是手滑）：
        //    keepFwLand: 「将发出降落指令：无人机保持固定翼飞向接机机位，在该机位上空转换并降落在该机位（不可撤销）」
        //    land:       「将发出降落指令：先切换为多旋翼，随后飞向接机机位并在该机位降落（不可撤销）」
        //    它们两条的历史教训**仍然成立**，将来任何新文案都要守：① 文案必须与**实际落点**一致
        //    （2026-09-29 的错句是「随后返回起飞点、降落回原机位」，那是旧实现 PX4 RTL ⇒ home 的
        //    行为，改接机机位后没跟着改 ⇒ 操作员照着一句过时的话去确认一个不可撤销的动作）；
        //    ② 不许写做不到的承诺（2026-10-07 删掉"并原地盘旋"——统一链第 ② 步不再切 Hold，
        //    转换在飞行中做，飞机本来就不盘旋）。
        if (_isLandSummaryKind(a)) return ""
        // ‼️ 救济档（F3）2026-10-08 第五轮**也搬走了**，理由与 F1/F2 同理（正文已结构化）。
        //    ⚠️ 必须是**提前 return**，不能只删掉 `switch` 里那个 `case`：删了 case 它会落到
        //    `default` ⇒ 弹框正文明晃晃写着「无法识别的操作类型」。这是 QML 里那种**不报错**
        //    的失效（`switch` 有 default 兜底，永远不抛）。
        if (_isRescueKind(a)) return ""
        var h = ""
        switch (a.kind) {
        case "takeoff":        h = qsTr("将发出起飞指令：无人机升空后沿该航线飞行"); break
        // ‼️ 救济档的 `case` 在 2026-10-08 第五轮**删掉了** —— 它已由上面的 `_isRescueKind`
        //    提前 return 走掉。⚠️ 被删掉的那句**留档**（别以为是手滑）：
        //      「【救济功能】跳过全部降落校验、不写数据库、不占用接机机位；请先在主界面确认
        //        无人机位置与姿态（不可撤销）\n将发出降落指令：先切换为多旋翼，随后飞向接机
        //        机位并在该机位降落」
        //    它承载的用户要求（2026-10-06 第 7 条「救济时位置、姿态、高度不可预测」要醒目）
        //    **没有废**：新文案首句「本功能为救济功能，当飞机不可控时才能使用」说的是同一件事，
        //    而且更狠 —— 旧句在讲"这条路做了什么"，新句在讲"什么时候才准用"。
        //    提示仍然落在**文案**里、不落在按钮配色里：按钮配色只能表达"这个动作危险"，
        //    表达不了"你正在用一条不校验、不写库的路"，而后者才是操作员此刻必须知道的事。
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
        // ‼️ `OpsCommon.taskNo(t)` **不能**用在这里：它**优先返回 `uav_no`**
        //    （`task.uav_no ? task.uav_no : task.task_no`），照搬会让这一行显示成
        //    「任务「UAV-10001048」 · 无人机 UAV-10001048」—— 同一个值说两遍。
        //    `_landConfirmTaskNo` 的注释里记过同一条教训（云端库实测两者确实不同）。
        return qsTr("%1\n任务「%2」 · 无人机 %3")
            .arg(h).arg(t.task_no ? t.task_no : "—").arg(t.uav_no ? t.uav_no : "—")
    }

    /// 确认弹窗正文那一行的颜色。**现在只剩五档**走它（起飞/停泊/签出/取消/回航）——
    /// 降落两档（F1/F2）与救济档（F3）的正文都已换成结构化块，各有自己的字色。
    ///
    /// ‼️ 这里原来有一条「救济档用亮红 `#ff6b6b`」的分支，2026-10-08 第五轮救济档搬走后
    ///    **它永远不生效了**（`_pendingConfirmHint()` 对救济档恒返回空串）⇒ 按"不留死分支"
    ///    删掉。救济的醒目色改落在 `actionConfirmDialog` 那个「重要提示：」块上（同为 `#ff6b6b`）。
    ///    ⚠️ 保留它的"防御价值"是假的：那一行对救济档**根本不显示**，写坏 `_isRescueKind`
    ///    也只会让**另一个块**不显示，与这个色值无关。
    ///
    /// ‼️ 色值是**实算**的（WCAG 相对亮度公式，本机 python 一行可复现），
    ///    基准是**本框当前的底色**深绿 `#0f2f2c`（`OpsDialog.qml`）：`#9fb3d4` **6.75:1**，过 AA 4.5:1。
    /// ⚠️ 白底时代那对值**已经不能用了**（2026-10-08 第四轮本框并入深色底）：
    ///      `#1565c0` 深蓝在深绿底上只剩 **2.50:1**、`#c62828` 深红只剩 **2.55:1**
    ///      （它们在白底上分别是 5.75 / 5.62）—— 直接搬过来等于看不清。
    /// ⚠️ 琥珀系 `#ffc107` 在浅底上是 1.63:1（用户 2026-09-28 反馈"非常不明显"），
    ///    但在**深底**上是 **8.80:1**；本行仍不用它，是为了与卡片里的警示条区分开。
    function _pendingConfirmHintColor() {
        return "#9fb3d4"
    }

    // 红绿确认动作执行（kind: takeoff→DB 落库 + 起飞指令；
    //                          keepFwLand→机位校验 + DB 落库 + 保持固定翼降落指令；
    //                          land→机位校验 + DB 落库 + 先转多旋翼再降落；
    //                          mcRescueLand→救济：零校验、零读写库，直接走降落链；
    //                          park→DB 停泊收尾 + 离线下电；
    //                          checkout→建 ROUTE 交接；cancelHandover→撤回自己提的交接；
    //                          return→回航落库 + RTL）
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
            // ‼️ 必须带失败反馈（2026-10-06 审查 §1③）：上面那个确认框是**先 close 再派发**的，
            //    所以失败时框已经没了——不报的话操作员看到的与"撤回成功"逐字相同。
            if (a.handoverId) _cancelHandoverWithFeedback(a.handoverId)
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
        } else if (a.kind === "land" || a.kind === "keepFwLand") {
            // F1 / F2：**先写库、再走降落链**，写库这一步由 `_commitLand` 里的
            // `POST /assign-slot` 完成（用户 2026-10-08「确认执行时才写」）。
            // ‼️ 不能像改前那样直接 `_execLand(task, kind)`：那时的 `task` 是**列表项快照**，
            //    它的 `assign_slot_*` 是**旧的**（本轮选中的机位在 `a.slot` 里，还没落库）
            //    ⇒ 会拿旧落点去校验、去飞。
            // ⚠️ `_commitLand` 是**异步**的（先发 POST），本函数末尾那句 `_pendingAction = null`
            //    不影响它：`a` 是形参、按值传进闭包，与 `_pendingAction` 是不是空无关。
            _commitLand(a)
        } else if (a.kind === "mcRescueLand") {
            _startLandFlow(OpsCommon.LAND_KIND_MC_RESCUE, task)
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
    //---- 降落统一链（用户 2026-10-06；设计稿 §9.8）----
    // 三条路（F1 保持固定翼降落 / F2 切换多旋翼降落 / F3 MC方式降落＝救济）共用**同一条**
    // 执行链：① 定落点 → ② [条件] 转多旋翼 → ③ 上传两航点 → ④ 切自动任务模式 → ⑤ PX4 自主。
    // ①②③④ 由 QGC 发；⑤ 此后 QGC **一个字节都不发**。
    //
    // ⚠️ **本段仍整段没有机型判据**（2026-09-29 审查 C1 的结论保留）：`_startLandFlow`、
    //    `_execLand` 与三颗按钮都不看 `v.vtol`。而 `Vehicle::_vtolState` 在非 VTOL 机体上
    //    恒为初值 0 ⇒ `OpsCommon.vtolTransitionDone(0)` 恒为 false ⇒ **F2 / F3**（＝
    //    `OpsCommon.landKindTransitionToMc` 为真的那两条）会先发一条转换命令、然后走满
    //    30 秒转换超时。**F1 不进这一支** —— `keepFwLand` 让 `landKindTransitionToMc` 恒假，
    //    它直接进 ③④，等的是上传档而不是转换档。
    //    用户 2026-09-29 裁定**暂只处理 VTOL** ⇒ 这里只标注、不加闸。将来要放行非 VTOL，
    //    判据须同时落在**按钮的 `visible`/`enabled`**（用户可见的第一道）与 `_startLandFlow` 入口上。
    //
    // 从按下按钮到确认落地之间的在途载具。用 `property` 而不是 JS 变量：`Connections.target`
    // 要绑它，而 QML 里给 JS 变量赋值不会发出变更信号。
    // ⚠️ 这是**单槽位**：多机并发的拒绝闸在 `_startLandFlow` 里。
    property var _landingVehicle: null
    // 正在执行降落流程的**任务 id**（0 = 没有流程在跑）。「飞行中改派机位」要靠它判断
    // 这次【指定降落机位】针对的是不是这架飞机（见 `_retargetLandingSlot`）。
    //
    // ‼️ 为什么不能拿 `_landingVehicle` 去比对：`Vehicle.id` 是 **MAVLink system id**，
    //    而改派机位那条路拿到的是 `task.task_id` / `task.uav_id`（数据库主键）——两者是
    //    **不同的 id 空间**。比错的形状是"恒不相等"，表现为改派永远不生效且**不报错**。
    property int _landingTaskId: 0
    // 本流程属于三条路里的哪一条（`OpsCommon.LAND_KIND_*`）。**进近方式**维度的唯一载体：
    // `_retargetLandingSlot` 重算进近点时要按它选公式，事后从坐标反推不出来。
    property string _landKind: ""
    // 降落流程的阶段位，**三值**：`""`（空闲）/ `"transition"`（等转多旋翼）/
    // `"autonomous"`（③④ 已发出，此后由 PX4 自主飞回并降落）。
    //
    // ‼️ 不能省。`Connections` 在整个流程里一直挂在同一架飞机上，心跳会一遍遍触发
    //    `_mcCheckTransitionComplete()`；没有阶段闸就会**反复重发**转换命令。
    property string _landPhase: ""
    // 落点＝接机机位坐标的快照。在 `_startLandFlow` 里、**并发闸之后**取定，飞行途中不再
    // 回读任务对象：`_tasks` 每 2 秒被轮询整个换掉，回读会让目标点跟着换。
    // 「飞行中改派机位」是**显式**动作（`_assignSlot` 成功后重传航线），不靠这里隐式跟随。
    property real _landTargetLat: 0
    property real _landTargetLon: 0
    // 进近点 P 的快照。取值随 `_landKind` 变（两种取值的依据见 `OpsCommon.landApproachPoint`）。
    // 与落点分开存：F1 时两者**不同**（P 是机位沿朝向偏 300 m 那一点），事后算不回来。
    property real _landApproachLat: 0
    property real _landApproachLon: 0
    // 当前阶段的截止时刻（`Date.now()` 毫秒）。上传段与自主段**共用**这一个字段，
    // 由 `_uploadLandingMission` 设为上传超时，收到上传完成确认后顺延为自主段超时。
    property real _landDeadlineMs: 0
    // 上传完成确认**收到过没有**。它是 `_onLandingMissionFinished` 分辨「首传失败（清场）」与
    // 「改派重传失败（保流程）」的唯一依据。
    property bool _landUploaded: false
    // **当前这段等待，截止时刻是按哪一档设的**：true ⇒ 上传档（60 s），false ⇒ 自主段档（600 s）。
    // ‼️ 不能拿 `_landUploaded` 兼任这一问（2026-10-08 评审 I-1）：`_retargetLandingSlot` 的改派重传
    //    **刻意不重置** `_landUploaded`（那会让改派失败被误判成首传失败、把在跑的流程清掉），
    //    但它把截止时刻改成了上传档 ⇒ 用 `_landUploaded` 分叉，会把「实际只等了 60 秒」
    //    报成「等了 600 秒」。两问各自独立，就得分两个字段。
    // ‼️ 与 `_landUploaded` 一样：超时分支里的读取必须发生在 `_clearLandFlow()` **之前**
    //    （那是这些字段的唯一清零点），顺序颠倒后两种超时永远报同一条文案。
    property bool _landWaitingForUpload: false
    // ‼️ **本流程里见过飞机在空中没有**（2026-10-08 终局审查 F3 修）。
    //    `_landFlowTick` 的完成判据是 `!flying && !armed`（＝"已落地且已上锁"），
    //    可它对一架**本来就在地面**的飞机**首拍即真** ⇒ 会在第一个 500 ms 轮询就
    //    `_clearLandFlow()` 静默收场 —— 而 ③④ 已经发出、机上航线已被覆盖、界面**零提示**
    //    （两个 C++ 出口的消息又被 `_landPhase !== "autonomous"` 丢掉）。
    //    这与本按钮自己的承诺相反：「凡『点了也白点』的情形，由 `_startLandFlow` 弹
    //    **可见的失败**」（`TaskListPanel.qml` 的 F3 注释）。
    //    ⇒ 只有**先见过它在空中**，才认那条完成判据；否则一路走到超时，弹可见的
    //      「未确认降落」。语义上这也更准：「完成」应该是"飞出去又回来了"，而不是"从没飞过"。
    property bool _landSawAirborne: false
    // 等待转换完成的超时。机型脚本的 `VT_F_TRANS_DUR` 是 10 秒，这里留三倍余量。
    readonly property int _mcSwitchTimeoutMs: 30000
    // 从发出上传到收到完成确认的超时。
    // ⚠️ **60 秒是余量估计，不是实测结论**：§9.7 三次 SITL 记的是**整段**耗时
    //    （93 / 95 / 89 s，含飞回与自主降落），**没有单独量过「上传 + 切模式」这一小段**。
    //    取 60 秒的理由只是它比下面自主段的 600 s 短一个量级、又远大于一条链路往返。
    //    超时意味着链路有问题，而不是飞机慢。
    readonly property int _landUploadTimeoutMs: 60000
    // 自主段总超时：从"上传完成确认"到"落地并上锁"的最大等待。
    // ‼️ 取 10 分钟（原实现的两段超时加起来是 3 分钟）不是放宽，是**换了等待对象**：
    //    原来等的是"QGC 发的指令生效"，那是秒级的；现在等的是"PX4 把飞机飞回机位并降落"，
    //    实测单程 89 s，加上进近段与逆风绕行，3 分钟是紧的。
    readonly property int _landAutonomousTimeoutMs: 600000
    // 位置轮询周期。自主段只用它判"落地了没有"，500 ms 足够。
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
        // C++ 出口 `Vehicle::startVtolLandingMission` 的结果经此回来（Task 2）。
        function onVtolLandingMissionFinished(ok, message) {
            opsView._onLandingMissionFinished(ok, message)
        }
    }
    Timer {
        id: mcSwitchTimer
        interval: _mcSwitchTimeoutMs
        onTriggered: {
            // ‼️ **载具没了也不能静默**（2026-10-08 评审 C-2）。`_landingVehicle` 为 null 的典型成因是
            //    链路断开 / `Vehicle` 对象被销毁 —— 恰恰是最需要告知操作员的那一刻。原实现
            //    `if (!_landingVehicle) return` 把最该响的那一格变成了哑的，与本 Timer 下方
            //    「不能静默」那句直接相反。
            //    只有 `_landPhase === ""`（流程早已收场、本 Timer 是野的）才可以静默。
            if (_landPhase === "") return
            var vehLost = !_landingVehicle
            _clearLandFlow()
            if (vehLost) {
                QGroundControl.showMessageDialog(opsView, qsTr("切换多旋翼未完成"),
                    qsTr("等待转换完成期间与无人机失去联系，无法确认转换是否完成，降落航线未发出。请确认无人机状态后再操作。"))
                return
            }
            // 不能静默：此刻飞机既没飞向接机机位也没降落，还在原地盘旋，操作员必须知道指令没发出去。
            QGroundControl.showMessageDialog(opsView, qsTr("切换多旋翼未完成"),
                qsTr("已发出切换指令，但无人机在 %1 秒内未报告转换完成，降落航线未发出。无人机当前在原地盘旋。")
                    .arg(Math.round(_mcSwitchTimeoutMs / 1000)))
        }
    }
    // 自主段的落地轮询（见 `_landFlowTick`）：每 `_landPollMs` 读一次遥测 `flying` / `armed`，
    // 判"已落地且已上锁"。统一链里 QGC 发完 ④ 就不再发任何指令，完成与否只能从遥测看。
    Timer {
        id: landFlowTimer
        interval: _landPollMs
        repeat: true
        onTriggered: opsView._landFlowTick()
    }
    /// 降落统一链的入口（设计稿 §9.8.4 的 ①②）。三个按钮在确认之后都汇到这里。
    ///
    /// ‼️ **本函数不读写数据库**。正常降落（F1/F2）的业务闸与 `POST /land` 在 `_execLand` 里，
    ///    本函数在它**之后**被调用；救济（F3）直接调本函数、不读写任何库状态。
    ///    这个分工就是设计稿 §9.8.2「入口语义」那个维度的代码形态：
    ///    **按钮身份决定走不走 `_execLand`**，而不是在本函数内部再判一次。
    ///    ⚠️ 但「救济不判」**不是**「本函数内一道闸都没有」（用户 2026-10-08 裁定）：「不判」的
    ///       辖区是**业务状态机**与**QGC 指令执行进度**，本函数一概不看这两样；函数里剩下的
    ///       全是**前提类**的闸 —— 载具可达、单槽位未占、落点坐标可用、进近点可算。
    ///       前提不在「不判」的辖区内，见下面坐标闸那段。
    ///
    /// `kind` 取 `OpsCommon.LAND_KIND_*` 之一。
    function _startLandFlow(kind, task) {
        var v = _vehicleForTask(task)
        if (!v) {
            QGroundControl.showMessageDialog(opsView, qsTr("降落指令未发出"),
                qsTr("未找到该任务（%1）对应无人机的连接，降落指令未下发，请检查现场链路。")
                    .arg(task && task.uav_no ? task.uav_no : "—"))
            return
        }
        // ‼️ 一次只等一架。多个降落流程共用 `_landingVehicle` / `_landTargetLat` 等**单槽位**
        //    状态，放进来就会互相覆盖坐标与阶段位。
        //
        // ‼️ **同一架默认也要挡**（2026-10-08 评审 C-3）。原闸是 `_landingVehicle !== v`，只挡"别的
        //    飞机"，于是对**同一架**重复点（再点一次、或换另一颗降落按钮）会这样收场：
        //      ① `_uploadLandingMission` 把 `_landUploaded` 重置为 false；
        //      ② C++ `Vehicle::startVtolLandingMission` 撞 `_missionManager->inProgress()`，
        //         **同步** emit `vtolLandingMissionFinished(false, …)`；
        //      ③ `_onLandingMissionFinished` 读到 `_landUploaded === false` ⇒ 判成"首传失败"
        //         ⇒ `_clearLandFlow()` 弹「降落航线未发出」；
        //      ④ 而**首传那次仍在 C++ 里飞**。它成功回来时 `_landPhase` 已被清空，
        //         被 `_onLandingMissionFinished` 的首行闸丢掉。
        //    ⇒ 终点是「机上航线是好的，界面却报『未发出』，流程状态被拆光」。
        //    单槽位状态本来就容不下第二个流程 —— 拒绝并**说出来**，操作员才有下一步。
        //
        // ‼️ **救济档（F3「直接降落」）例外：可接管**（用户 2026-10-08 第六轮裁定）。
        //    为什么必须开这个口：那颗按钮的 `visible` 判据是 `status === "LANDING"`
        //    （`TaskListPanel.qml`），而把任务写成 LANDING 的**唯一**写点就是 QGC 发正常降落
        //    那一步（`_execLand` 里的 `POST /land`）⇒ **按钮可见的那一刻，正是一个降落流程
        //    在跑的那一刻**。改前对同一架一律拒绝，等于：救济在它**唯一出现**的场景里点不动，
        //    而"正常降落下不去"恰恰是救济要救的那种不可控。
        //    ⚠️ 这也与用户 C1 裁定对齐：「F3 不判状态机、也不判 qgc 当前指令执行到哪一步」
        //       —— `_landingVehicle` 就是 QGC 侧的流程槽位，判它判的正是"执行到哪一步"。
        //
        //    接管 ＝ **先清场，再从 ① 重走**（控制流继续往下，与首次进入同一条路）：
        //      · `_clearLandFlow()` 是本流程状态的唯一清零点，顺带停掉 `mcSwitchTimer` /
        //        `landFlowTimer`。不清场就直接覆盖，两个旧 Timer 会与新流程抢同一组字段。
        //      · **落点不变**：F2 与 F3 的 `landApproachPoint` 是同一支（`OpsCommon.js`），
        //        两者落点都是 `assign_slot_id` 那个机位 ⇒ 接管只重发航线，不改落点。
        //      · **不写库**：救济本来就不走 `_execLand`（零读写库，见 C1），库里任务已是 LANDING。
        //    ⚠️ C-3 那条链在接管时**仍可能踩到**，但形状已经变了：若旧流程的**上传事务**在
        //       C++ `_missionManager` 里还没结束，新的 `startVtolLandingMission` 会撞
        //       `inProgress()` 闸、同步 emit 失败 ⇒ 新流程**自己**走 ③ 清场并弹
        //       「上一次航线写入尚未完成，请稍后重试」—— 失败仍**可见**，那句提示语正是操作员
        //       该做的下一步（再点一次），而不是改前那种"点了什么都不发生"。
        //       （接管先清场，所以不会再出现 ④ 那种"旧流程仍在飞、界面已被拆光"。）
        if (_landingVehicle) {
            var sameVehicle = (_landingVehicle === v)
            if (!sameVehicle) {
                QGroundControl.showMessageDialog(opsView, qsTr("已有一架无人机在降落中"),
                    qsTr("另一架无人机的降落流程仍在进行中。请等它完成或超时后再操作本架。"))
                return
            }
            if (kind !== OpsCommon.LAND_KIND_MC_RESCUE) {
                QGroundControl.showMessageDialog(opsView, qsTr("该无人机已在降落流程中"),
                    qsTr("本架无人机的降落流程尚未结束，本次操作未生效。请等它完成或超时后再操作。"))
                return
            }
            // 同一架 + 救济 ⇒ 接管：清掉旧流程的在途状态，然后继续往下走。
            _clearLandFlow()
        }

        // ---- ① 定落点与进近点 ----
        // 落点恒为**接机机位**（§9.7 定义第 1 条：无条件，但不是"随便落"）。
        var slotLat = task.assign_slot_lat
        var slotLon = task.assign_slot_lon
        // ‼️ **落点坐标必须可用 —— 这道闸对三条路都成立，包括 F3（救济）**（2026-10-08 终局审查 F2 加）。
        //    为什么下一道 `if (!p)` 拦不住：MC 两支的 `landApproachPoint` **恒**返回机位坐标本身、
        //    **永不为 null**（连 0/0 也原样传出）⇒ 机位未指派或已被软删时后端下发的
        //    `assign_slot_lat/lon = 0/0` 会被原样发成 `[WAYPOINT@(0,0), VTOL_LAND@(0,0)]`。
        //    F1/F2 的坐标闸在 `_execLand`（那条路必经），F3 绕过 `_execLand` 直达本函数
        //    ⇒ 没有本道，F3 就是**唯一**没有坐标校验的入口。
        //
        //    ⚠️ **这不违反 R9 的「F3 不判」**（用户 2026-10-08 裁定）。「不判」有两个**具名辖区**：
        //       ① 业务状态机（机位是否空闲、任务是否已 LANDING、无人机状态是否正常）、
        //       ② QGC 指令执行进度。
        //       落点坐标**不在**这两个辖区里 —— 它是「不判」赖以成立的**前提**。用户原话：
        //       「这里的**不判，前提是 qgc 取出机位坐标是正常的、无错误的取回**」；
        //       且落点是原任务指定的机位坐标、**源头是数据库表**，不是随机数。
        //    ⇒ 本闸守的是**前提**（坐标有没有正常取回），不是**业务该不该拦**。前提成立时它
        //      永不触发；前提破裂时它把「飞向 (0,0)」换成一句可见的失败 —— 正合用户另一条口径
        //      「只要不是静默型失败，每个失败都有提示，应对策略就不用太过在意」。
        //    本闸只读内存里的 `task` 字段，**不调任何接口、不写库**。
        if (!OpsCommon.isValidWaypoint(slotLat, slotLon)) {
            QGroundControl.showMessageDialog(opsView, qsTr("降落航线未发出"),
                qsTr("该任务没有可用的接机机位坐标（机位可能尚未指定或已被撤销），降落未发出。请先指定接机机位。"))
            console.warn("OpsView 降落落点坐标不可用 kind=", kind,
                         "slot=", slotLat, slotLon)
            return
        }
        var p = OpsCommon.landApproachPoint(kind, slotLat, slotLon, task.assign_slot_heading)
        if (!p) {
            // ⚠️ 坐标判据**不在这里**（见 `OpsCommon.landApproachPoint`：0/0 是它的合法输入），
            //    能落进本支的**只剩一种**：F1（保持固定翼），
            //    且该机位**朝向**不可用。F2/F3 恒返回机位坐标本身，**永不为 null**。
            //    F1 在这一格算不出 P，而 **P ≠ 机位**的保持固定翼航线从未被端到端验证过
            //    （§9.5.3 实测表只覆盖了偏移 300 m 那一档）⇒ 不许回落成 P = 机位，直接报失败。
            QGroundControl.showMessageDialog(opsView, qsTr("降落航线未发出"),
                qsTr("无法由接机机位算出进近点（「保持固定翼」需要机位朝向，该朝向不可用），降落未发出。"))
            console.warn("OpsView 降落进近点计算失败 kind=", kind,
                         "slot=", slotLat, slotLon, "heading=", task.assign_slot_heading)
            return
        }
        // ‼️ 快照写在**并发闸之后**。此后一律读快照、不回读 `task`。
        _landingVehicle = v
        _landingTaskId = task.task_id
        _landKind = kind
        _landTargetLat = slotLat
        _landTargetLon = slotLon
        _landApproachLat = p.lat
        _landApproachLon = p.lon

        // ---- ② [条件] 转多旋翼 ----
        // 条件＝「本路要求转」**且**「当前还不是多旋翼」。后一半落实用户 2026-10-06 第 11 条
        // 逐字「也许已经是 mc 了」：已经是 MC 就不发那条命令、不等，直接进 ③④。
        if (OpsCommon.landKindTransitionToMc(kind)
                && !OpsCommon.vtolTransitionDone(v.vtolState)) {
            _landPhase = "transition"
            // ⚠️ 停掉可能还活着的 `landFlowTimer`。本 Timer 只在自主段里有意义
            //    （`_landFlowTick` 判落地、判超时），`"transition"` 段由 `mcSwitchTimer` 计时。
            //    这是**第一道**；**第二道**在 `_landFlowTick` 里按阶段位分流。
            //    两道都要：只靠第二道时，野 Timer 仍会每 500 ms 空转一次。
            landFlowTimer.stop()
            mcSwitchTimer.restart()
            // ‼️ 只发转换命令、**不切 Hold**（设计稿 §9.8.5）。统一链里 ② 后面跟的是 ④ 的
            //    AUTO_MISSION **真转换**（inactive→active），导航状态机会照样重建 ⇒ 原实现里
            //    那个 Hold 的用途（把导航模式挪开，让后续的 Guided 指令能重建状态机）不再需要。
            //    既有对照：`Vehicle::hoverAndTransitionToMultirotor()` 发的是**同一条命令**，
            //    差别只在它前面多切一次 Hold。
            //    `showError = true`：命令被拒时由 QGC 内建的错误通道弹提示 —— `sendCommand`
            //    返回 void，QML 侧判不了返回值，"让失败可见"这件事只能压在 `showError` 上。
            v.sendCommand(1, OpsCommon.MAV_CMD_DO_VTOL_TRANSITION, true,
                          OpsCommon.MAV_VTOL_STATE_MC, 0, 0, 0, 0, 0, 0)
            // 发完自查一次：`vtolStateChanged` 只在状态**变化**时发，而"本来就是 MC"上面已排除
            // ⇒ 这里不会重复触发。若命令生效极快、回调已跑过，本次自查会被
            // `_mcCheckTransitionComplete` 的阶段闸挡掉。
            _mcCheckTransitionComplete()
            return
        }

        // ---- 不需要转 ⇒ 直接进 ③④ ----
        _landPhase = "autonomous"
        _uploadLandingMission()
    }
    /// ③④：上传两航点 + 切自动任务模式。两者都在 C++ 出口里（Task 2），本函数只发起与计时。
    ///
    /// ‼️ 为什么整段放进 C++：`writeMissionItems` 有个必踩的调用约定 —— PX4 上
    ///    `PX4FirmwarePlugin::sendHomePositionToVehicle()` 返回 **false** ⇒ 上传时
    ///    `PlanManager` 会**删掉航线的第 0 项**。所以传入的列表必须自己垫一个占位首项，
    ///    否则两个航点被删成一个 `VTOL_LAND`，PX4 以 `navigator_mis_starts_w_landing2` **拒收**，
    ///    而上传期照回 ACCEPTED、界面无痕、飞机不动。这类"看起来成功"的失败放在 C++ 里有
    ///    类型与单测兜着，放在 QML 里没有编译期保护。
    function _uploadLandingMission() {
        var v = _landingVehicle
        if (!v) { _clearLandFlow(); return }
        _landUploaded = false
        _landWaitingForUpload = true
        _landDeadlineMs = Date.now() + _landUploadTimeoutMs
        landFlowTimer.restart()
        // ⚠️ **不看返回值**：`startVtolLandingMission` 的失败一律经
        //    `vtolLandingMissionFinished(false, …)` 回来（同步失败也是 emit 之后才 return false）。
        //    这里再判一次返回值，同一次失败会弹两个框。
        v.startVtolLandingMission(_landApproachLat, _landApproachLon, _landTargetLat, _landTargetLon)
    }
    /// C++ 出口 `vtolLandingMissionFinished` 的接收点（经 `Connections` 转一手）。
    ///
    /// ⚠️ **已知限制（登记在 Review Focus，不在本任务修）**：闸只能挡「流程已清场」的迟到信号，
    ///    挡不住「旧流程超时清场后、操作员立刻对同一架飞机重开一次流程」这一格 —— 那时旧流程的
    ///    信号到达，会被当成新流程的结果（表现为弹一个错的框、或把新流程的截止时刻顺延）。
    ///    窗口＝「超时清场」到「新的一次上传完成」之间；真正的解法是让 C++ 出口带回调用者
    ///    提供的 token（要改签名），成本大于收益，且它不影响飞行安全 ——
    ///    PX4 执行的是**后到的那条**航线。
    function _onLandingMissionFinished(ok, message) {
        if (_landPhase !== "autonomous") return
        if (!ok) {
            // ‼️ 两格的分叉依据是 `_landUploaded`：它只由本函数置真，而**改派重传时不重置**
            //    ⇒ 读到 true 就说明"首传成功过，这一次是改派的第二次上传"。
            if (_landUploaded) {
                // 改派重传失败：PX4 上仍是**旧**航线（旧落点），流程照常有效 ⇒
                // **保持流程继续**，只把截止时刻从"上传超时"顺延回自主段超时。
                // （Review Focus 第 5 条：期望是"弹窗且保持原流程继续"，不是把流程清掉。）
                // ⚠️ 不顺延的话，下一拍 `_landFlowTick` 会按 60 秒的上传超时**立即误报**超时。
                QGroundControl.showMessageDialog(opsView, qsTr("改派未生效"),
                    message && message.length > 0 ? message
                                                  : qsTr("新航线的上传未成功，本次改派未生效；无人机仍飞向原机位。"))
                _landWaitingForUpload = false
                _landDeadlineMs = Date.now() + _landAutonomousTimeoutMs
                return
            }
            _clearLandFlow()
            QGroundControl.showMessageDialog(opsView, qsTr("降落航线未发出"),
                message && message.length > 0 ? message
                                              : qsTr("航线未能发出或未能生效，降落流程已停止。"))
            return
        }
        // ③④ 都成了：此后 QGC 不再发任何字节（第 ⑤ 步由 PX4 自主）。
        // 把截止时刻从"上传超时"顺延到"自主段超时"。
        _landUploaded = true
        _landWaitingForUpload = false
        _landDeadlineMs = Date.now() + _landAutonomousTimeoutMs
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
        _landKind = ""
        _landTargetLat = 0
        _landTargetLon = 0
        _landApproachLat = 0
        _landApproachLon = 0
        _landDeadlineMs = 0
        _landUploaded = false
        _landWaitingForUpload = false
        _landSawAirborne = false
    }
    /// 转换完成（或本来就已是多旋翼）⇒ 飞向**接机机位**，而不是回家。
    ///
    /// ‼️ 落点为什么不是 home（2026-09-29 用户裁定「改为接机机位坐标」）：用户报障「切换 mc 降落前
    ///    换了机位、切回来又换一次，地图上接机降落点与起飞点一直重合，更换机位的动作没有起作用」。
    ///    根因是原实现走 `guidedModeRTL(false)` ⇒ PX4 RTL ⇒ 落点恒为 **home**，而 home 是**起飞点**；
    ///    `table_arrival_schedule.assign_slot_id`（ATC 指派的接机机位）**从未参与飞行**。
    ///    所以那不是"更换动作失效"，是**功能缺失**。
    ///
    /// ‼️ 为什么不用 `DO_SET_HOME` 把 home 改到机位：会**污染 home**——PX4 的 failsafe 回航点
    ///    也是它，改完一次之后所有失控保护都会飞向那个机位，而不只是这一次降落。
    ///
    /// `_poll()` 与 `_execReturn` 同一理由：库里的状态没变，但卡片要跟上。
    ///
    /// 本函数现在的分工：**等 ② 转换完成 ⇒ 触发 ③④（上传两航点 + 切 AUTO_MISSION）**，
    /// **不再自己发任何 Guided 指令** —— 统一链里也没有"转完飞向机位"这一段了，
    /// 飞回机位由 PX4 的 mission 状态机做（设计稿 §9.8.4 第 ⑤ 步）。
    function _mcCheckTransitionComplete() {
        // ‼️ 阶段闸：本函数由 `vtolStateChanged` 驱动，自主段的心跳会一遍遍进来
        //    （见 `_landPhase` 的注释）。没有它就会反复重发转换命令。
        if (_landPhase !== "transition") return
        var v = _landingVehicle
        // 判据是「转换**已完成**」＝ `MAV_VTOL_STATE_MC`，**不是**「机型是多旋翼」：
        // `Vehicle::multiRotor()` 读心跳报的 `MAV_TYPE`，经 `QGCMAVLink::vehicleClass()`
        // 的纯 switch 把 `MAV_TYPE_VTOL_*` 全归到 `VehicleClassVTOL`，与多旋翼类不相交
        // ⇒ 对 VTOL 机体**恒为 false**，切成功了也判不出来。
        // 也不能用 `!vtolInFwdFlight`：那个 bool 在「转多旋翼中」(2) 就已经是 false ⇒ 会在
        // 转换途中就往下走，而 PX4 此刻仍视机体为固定翼。
        if (!v || !OpsCommon.vtolTransitionDone(v.vtolState)) return
        mcSwitchTimer.stop()
        // 坐标的纵深防御**已不在这里**：统一链里坐标由 `_startLandFlow` 一次取定并验过
        //（`landApproachPoint` 回 null 即报错），本函数不再碰坐标。
        _landPhase = "autonomous"
        _uploadLandingMission()
    }
    /// ‼️ 本段的失败**不回落任何自动降落**。用户 2026-09-28 定的红线是「除非要坠机了，
    ///    否则飞机只能在机位上降落」——回落 `guidedModeRTL(false)` 会落到 home＝**起飞点**，
    ///    而它未必是机位。悬停在原地是可控状态，比落到一个非机位的地方安全。
    ///
    /// 自主段：等落地。
    ///
    /// ‼️ 完成判据＝**遥测**（设计稿 §9.8.7「必须重做」第 ② 条）。原实现等的是「QGC 自己发的
    ///    降落指令有没有生效」（`!v.armed` + 高度有没有在掉）—— 统一链里 QGC 发完 ④ 就不再发
    ///    任何东西、飞机由 PX4 的 mission 状态机自主飞，所以只能看**飞机自己的状态**。
    ///    `flying` 与 `armed` 两个都取（理由见下），合起来就是 PX4 `landed_state` 在 QGC 侧的翻译。
    function _landFlowTick() {
        var v = _landingVehicle
        // ⚠️ **两个非自主阶段要分开处理**：
        //    `""`（无流程）⇒ 本 Timer 是野的，收干净，别让它空转。
        //    `"transition"`（等转多旋翼，③ 还没发出）⇒ **只 return，不清场**。清场会把一次
        //      正在进行的转多旋翼等待**整段销毁**（`_clearLandFlow()` 清 `_landingVehicle` /
        //      `_landKind` / 两个坐标快照），而 `mcSwitchTimer` 还在跑、`vtolStateChanged`
        //      回来时已经找不到流程 ⇒ 表现为「点了降落、飞机转完多旋翼、然后什么都不发生」。
        if (!v || _landPhase === "") { _clearLandFlow(); return }
        if (_landPhase !== "autonomous") return
        // ‼️ 为什么两个条件都要：
        //    只看 `armed` —— "飞行中但某些时刻 armed 短暂为假"会被判成已落地；
        //    只看 `flying` —— 落地后 PX4 按 `COM_DISARM_LAND`（默认 2 秒）才自动上锁，
        //                    那两秒里 `flying` 已是 false ⇒ 会提前判成功。
        //    两个都取 ⇒ 只有"落地**且**已上锁"才算完成。
        //
        // ‼️ 这条判据是设计稿 §9.8.7 那句「读遥测 `landed_state == 1`」在 QGC 侧的**实现**。
        //    QGC 没有把 `landed_state` 暴露成属性，只暴露了它的两个派生 bool；
        //    `Vehicle::_handleExtendedSysState`（`Vehicle.cc:1058-1083`，函数头到 switch 收尾）的映射是**全函数**：
        //      ON_GROUND(1) ⇒ flying=false, landing=false
        //      TAKEOFF(2)   ⇒ flying=true,  landing=false
        //      IN_AIR(3)    ⇒ flying=true,  landing=false
        //      LANDING(4)   ⇒ flying=true,  landing=true
        //    **PX4 路径上**写 `_flying=false` 的来源是 `ON_GROUND(1)`（别在别的机型上引这句：
        //    `APMFirmwarePlugin.cc` 也写 `_setFlying`）⇒ `!v.flying` 与
        //    「`landed_state == 1`」等价。
        //
        // ⚠️ 但**不是逐字等价**，成立范围有两条边界，写在这里免得被当成本判据的漏洞：
        //    ① `default: break;`（`:1081-1082`）⇒ `UNDEFINED(0)` **不写回**，两个 bool
        //       保持上一次的值（`_flying` 初值见 `Vehicle.h`）。PX4 正常飞行不发 `UNDEFINED`。
        //    ② 本判据只对**收到过** `EXTENDED_SYS_STATE` 的飞机成立。首帧到达之前 `_flying`
        //       还是初值 `false` —— 但那一刻 `armed` 也还没置真，本行的合取
        //       `!v.flying && !v.armed` 因此仍为假 ⇒ **不会被误判成「已落地」**。
        //       这就是 `!v.armed` 那个合取项**不能删**的原因之一。
        //
        // ‼️ **前置 `_landSawAirborne`（2026-10-08 终局审查 F3 修）**：上面 ①② 两条合起来
        //    只挡住了"遥测还没到"的**几十毫秒**，挡不住**飞机本来就在地面**这一整类情形 ——
        //    那时 `_flying` 与 `armed` 已经都是货真价实的 `false`，合取**首拍即真** ⇒ 流程在
        //    第一个 500 ms 轮询就被 `_clearLandFlow()` 静默销毁，而 ③④ 已发出、机上航线已被
        //    覆盖、界面**一点提示都没有**（本函数两条 C++ 出口的消息都被 `_landPhase !==
        //    "autonomous"` 丢掉，而 `_landPhase` 刚被清成 ""）。这与本按钮自己的承诺相反：
        //    「凡『点了也白点』的情形，由 `_startLandFlow` 弹**可见的失败**」。
        //    ⇒ 必须**先见过它在空中**（`v.flying` 为真过至少一拍），才认这条完成判据；
        //      否则一路走到下面 `Date.now() >= _landDeadlineMs` 的超时分支，弹可见的失败。
        //      语义上这也更准：降落"完成"是"飞出去又回来了"，不是"从没飞过"。
        if (v.flying) _landSawAirborne = true
        //
        // ⚠️ 改派段用的是 `v.landing`（见 `_retargetLandingSlot`），**它不等于 `LANDING(4)`**：
        //    `Vehicle::_setLanding`（`Vehicle.cc:1868-1873`）带 `if (armed() && …)` 闸 ⇒
        //      ① 未上锁时 `landing` **永远是 false**（`LANDING` 态本来就在锁着飞，实际不受影响）；
        //      ② 一旦 `armed` 变假，`_setLanding(false)` 也**不再写入** ⇒ 若 `ON_GROUND` 帧
        //         恰好在自动上锁**之后**才到，`landing` 会**卡在 true**，直到飞机下次解锁并
        //         收到一张 TAKEOFF / IN_AIR / ON_GROUND 帧。
        //    ⇒ 它的语义是「**最后一次已知处于 LANDING 态、且当时锁着**」。对改派段那道闸够用
        //      （闸只要求「正在降落时别改库」，卡在 true 的方向恰好是保守的）；**不要**把它
        //      抄到任何需要精确判定 `landed_state` 的地方。
        if (_landSawAirborne && !v.flying && !v.armed) {
            _clearLandFlow()
            _poll()
            return
        }
        if (Date.now() >= _landDeadlineMs) {
            // ‼️ **先读后清**：`_clearLandFlow()` 是这些字段的唯一清零点，顺序颠倒会让两种
            //    超时永远报同一条文案（`_landWaitingForUpload` 会被清成 false，于是上传档的
            //    超时也报自主段那一条）。
            var awaitingUpload = _landWaitingForUpload
            _clearLandFlow()
            if (awaitingUpload) {
                QGroundControl.showMessageDialog(opsView, qsTr("降落航线未发出"),
                    qsTr("在 %1 秒内未收到航线上传完成的确认，飞机未收到降落航线。请检查链路后重试。")
                        .arg(Math.round(_landUploadTimeoutMs / 1000)))
            } else {
                QGroundControl.showMessageDialog(opsView, qsTr("未确认降落"),
                    qsTr("降落航线已发出，但无人机在 %1 秒内未报告完成着陆。请在主界面确认无人机状态。")
                        .arg(Math.round(_landAutonomousTimeoutMs / 1000)))
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
            //   (a) 任务不在 LANDING：这是最常见、也是最正常的「飞行中**指派**机位」（**非占用**）——飞机还在飞，
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
        // ---- `transition` 段（② 已发出、③ 尚未上传）：只换快照，**不重传** ----
        // ‼️ **两个快照都要换**。③ 上传时读的是 `_landApproach*`（`_uploadLandingMission`），
        //    而且它**从不重算** —— 只换 `_landTarget*` 会让飞机朝一个与新机位无关的方向做
        //    进近段（F1 的 P 本就落在**旧机位**朝向的 300 m 射线上）。
        if (_landPhase === "transition") {
            var ta = OpsCommon.landApproachPoint(_landKind, s.lat, s.lon, s.heading)
            _landTargetLat = s.lat
            _landTargetLon = s.lon
            if (!ta) {
                // ⚠️ **不回滚落点**。`_assignSlot` 的 POST 已经成功，库里的 `assign_slot_id`
                //    就是新机位；把 `_landTarget*` 退回旧机位会让局面变成「库里记新机位、
                //    飞机降旧机位」—— 那正是 `_assignSlot` 那道闸要防的错。此处保留旧进近点、
                //    把事实说出来，改派本身**不算失败**（落点已经改了）。
                QGroundControl.showMessageDialog(opsView, qsTr("改派不完整"),
                    qsTr("新机位的朝向不可用，算不出新的进近点。落点已改为新机位，进近段仍按原方向飞。"))
                return
            }
            _landApproachLat = ta.lat
            _landApproachLon = ta.lon
            return
        }

        // ⚠️ **首传尚未确认时拒绝改派**。`_landUploaded` 为假 ⇒ `writeMissionItems` 已发出、
        //    `sendComplete` 还没回来。此刻 PX4 上**还没有**这条航线，而重传会与首传争同一个
        //    `PlanManager` 的写入事务，且首传完成时用的仍是**旧**快照 ⇒ 最终机上留下的是哪一条
        //    不可知。本闸给出的承诺是：**改派只发生在「航线已经在机上」时**。
        //    （`transition` 段已在上方 return，走不到这里 ⇒ 本闸只作用于自主段。）
        if (!_landUploaded) {
            QGroundControl.showMessageDialog(opsView, qsTr("改派未生效"),
                qsTr("首条降落航线尚未确认上传完成，本次改派未生效。请稍后重试。"))
            return
        }

        // ---- 自主段（`"autonomous"`）：**重传整条航线** ----
        // 依据 §9.8.7「必须重做」第 ① 条。原实现重发的是 Guided 的 `DO_REPOSITION`，
        // 而统一链里飞机已交给 PX4 的 mission 状态机，Guided 与它是两套东西。
        // 上传即载入（§9.7 实验 #4 实测：执行中上传，89 s 落成、`sub` 恒为 4，从未切走）。
        //
        // ‼️ 「已经在降落」时**不**重传：判据取遥测 `v.landing`，不取我们自己的阶段位 ——
        //    阶段位只说"③④ 已发出"，分不出"正在飞回"与"正在降落"，而后者重传航线的行为
        //    **未实测**（实验 #4 的上传点在 `seq=0`，即飞行段）。沿用原实现这一格的文案。
        var lv = _landingVehicle
        if (!lv || lv.landing) {
            QGroundControl.showMessageDialog(opsView, qsTr("改派未生效"),
                qsTr("降落已开始，本次改派未生效。"))
            return
        }
        // 新机位的进近点要按**本流程的进近方式**重算：F1 的 P 随朝向偏移 300 m，
        // 不重算会让飞机朝一个与新机位无关的方向做进近段。
        // ⚠️ 用 `s.lat/s.lon`（**新**机位）算，四个快照在算成功之后**一次性**改写：算不出进近点
        //    就一个快照都不动 —— 那样飞机仍按机上那条旧航线飞向原机位，下面那句「本次改派
        //    未生效，无人机仍飞向原机位」才是字面为真的。
        // ‼️ 重传时传的落点必须是**新**机位：`_landTarget*` 若不跟着改，航线的落点还是旧机位，
        //    而库里 `assign_slot_id` 已经是新机位 —— 正是 `_assignSlot` 那道闸要防的
        //    「库里记新机位、飞机降旧机位」。
        var na = OpsCommon.landApproachPoint(_landKind, s.lat, s.lon, s.heading)
        if (!na) {
            QGroundControl.showMessageDialog(opsView, qsTr("改派未生效"),
                qsTr("新机位的朝向或坐标不可用，算不出进近点。本次改派未生效，无人机仍飞向原机位。"))
            return
        }
        _landTargetLat = s.lat
        _landTargetLon = s.lon
        _landApproachLat = na.lat
        _landApproachLon = na.lon
        // ⚠️ **不要重置 `_landUploaded`**：它是 `_onLandingMissionFinished` 分辨
        //    「首传失败（清场）」与「改派重传失败（保流程）」的唯一依据。重置了，
        //    改派失败会被当成首传失败，把一条仍在正常执行的流程清掉。
        // ⚠️ 但**截止档位要跟着改回上传档**（`_landWaitingForUpload`）：重传就是一次新的上传，
        //    等的仍是 `sendComplete`。它和 `_landUploaded` 是两问，别合并（评审 I-1）。
        _landWaitingForUpload = true
        _landDeadlineMs = Date.now() + _landUploadTimeoutMs
        landFlowTimer.restart()
        // ⚠️ 不看返回值（同 `_uploadLandingMission`）：失败经信号回来，这里再判会弹两次。
        lv.startVtolLandingMission(_landApproachLat, _landApproachLon,
                                   _landTargetLat, _landTargetLon)
    }
    // 正常降落的唯一写路径（F1「降落」与 F2「切换多旋翼降落」共用，`kind` 区分进近方式）：
    // 接机机位坐标校验 → 机位空闲校验 → POST /tasks/:id/land（DB→LANDING）→ `_startLandFlow`。
    // ⚠️ 本函数**没有机型判据**（2026-09-29 审查 C1）：只看 `assign_slot_id` 与后端校验结果，
    //    非 VTOL 机体同样会走完全程。用户 2026-09-29 裁定**暂只处理 VTOL** ⇒ 只标注、不加闸。
    function _execLand(task, kind) {
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
        //    快照写在 `_startLandFlow` 里、并发闸**之后**（那里注释有说明）。
        if (!OpsCommon.isValidWaypoint(task.assign_slot_lat, task.assign_slot_lon)) {
            _landBlockReason = qsTr("该任务的接机机位坐标不可用（机位可能已被撤销），请重新指定接机机位")
            landBlockDialog.open()
            return
        }
        var tid = task.task_id
        _get("/api/tasks/" + tid + "/landing-slot-check", function(status, data) {
            if (status === 200 && data && data.free === true) {
                // ‼️ 未连接闸与并发闸必须在 `POST /land` **之前**（2026-09-29 审查 C3）。
                //    `_startLandFlow` 里也有这两道，但它跑在 POST **之后** ⇒ 只靠那里的话，
                //    被闸拒绝时库里已经是 LANDING 了：「切换多旋翼降落」按钮（`visible` 要求
                //    `IN_FLIGHT`）随之消失、飞机一条指令都没收到、任务卡却显示"正在降落"
                //    —— 又一处「谎报成功」，而且这一处连中止提示都没有。
                //    放在这里而不是更靠前，是因为 `/landing-slot-check` 是异步往返：这一格是
                //    POST 之前**最后**一个能判的时刻。
                //    `_startLandFlow` 里那两道**保留**作纵深防御：那里的 `v` 是**重新解析**的
                //    （本往返期间链路可能已经掉），判据也不是同一份快照。
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
                        _startLandFlow(kind, task)
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

    //── VTOL 起飞转换距离（运营常数，2026-10-06 设计稿 §5/§7）────────────────
    //
    // 这个距离**是运营常数**，与那四个高度常数同一张表（`table_operational_constant`），
    // 由后端 `GET /api/operational-constants` 下发。QGC 侧**不再**读
    // `PlanViewSettings.vtolTransitionDistance` —— 那个设置项**留着不动**，
    // 改它对本项目的起飞转换点**已无效**，界面上没有这个提示，是设计稿 §10.1 登记过的已知代价。
    //
    // 「留着不动」不是随口说的：2026-10-06 全仓 `rg` 实测，该设置项**还有两个 src 侧读者**
    // （都在上游 QGC 的 Plan 视图路径上，与 `OpsView` 无关）：
    //   · `MissionManager/TakeoffMissionItem.cc:166` —— **起飞点**的默认距离。
    //     ⚠️ 它只在 `!coordinate().isValid()` 时进入，且沿**方位角 0（正北）**偏
    //     （`:179 atDistanceAndAzimuth(distance, 0)`）—— 设计稿里「失效时朝正北飞」
    //     那个现象就是这一行。本项目走不到它：`OpsRouteSync.qml:659` 的
    //     `takeoff.coordinate = takeoffPoint` 是**最后一次**写
    //     （`TakeoffMissionItem::setCoordinate`（`:97-105`）无条件转调
    //     `SimpleMissionItem::setCoordinate`）⇒ **我们算的点赢**。
    //   · `MissionManager/VTOLLandingComplexItem.cc:38-42` —— 垂起着陆航线的
    //     `landingDistance` 默认值种子（降落侧，与本参数无关）。
    // 另：`AppSettings/pages/PlanView.SettingsUI.json:13` 仍把它摆在设置页上（所以用户看得见、改得动、但改了没用）。
    //
    // ‼️ **触发频率 = 每个 Vehicle 对象一次**（设计稿 §7.2），**不是**「每次建链」：
    //   · 触发点是 `_onVehicleConnected()`，但该函数**约每 2s** 还会被
    //     `on_TasksChanged → _syncRoutesForAlreadyConnected()` 再调一次（遥测链活着时）
    //     ⇒ **必须有闩**，否则变成每 2s 一个 XHR。
    //   · 闩按 **Vehicle 对象身份**，**不能按值**：兜底的 300 与库里取到的 300
    //     在值上完全同形，用值当判据分不出「问过没有」。
    //   · 「重连飞机」在本项目里**通常不会**重建 Vehicle 对象（那是 PX4 重启，QGC 到
    //     mavp2p 的 link 没断）⇒ 改库后要**重启 QGC** 才会重新取。
    //
    // `-1` = **第一个**请求还没回来（§7.5）。‼️ 只有初始值才是 `-1`：后续取值
    // **不再重置**——该常数全局同值、与是哪架飞机无关，重置只会给所有飞机多开一个
    // 「不建 sync」的窗口，带不来任何正确性。
    property real _vtolTransitionDistance: -1
    // 闩：已经为**这个 Vehicle 对象**取过（含在途）。`null` = 还没为任何飞机取过。
    property var  _vtolDistanceAskedFor: null
    // 请求序号：每发一次取值请求 +1；回调带着**自己那次的序号**回来。
    // 用途＝去重。一次请求有三个可能先到的落定点（`readystatechange(DONE)`、`onerror`、
    // 超时 `Timer`），谁先到谁算数、后到的丢弃。**不能**改用 `_vtolTransitionDistance`
    // 是否已是 `>= 100` 当这个判据：那样第二架飞机的那次请求（结果本应照样刷新缓存）
    // 会被静默丢弃 —— §7.3 的粒度是「每个 Vehicle 对象取一次」，不是「全局只取一次」。
    property int  _vtolReqSeq: 0
    property int  _vtolSettledSeq: -1

    /// 取值请求的**超时计时器** —— 「预设一个时间，时间一到不等返回」（用户原话）。
    ///
    /// ‼️ **为什么不用 `xhr.timeout`：Qt 6.11 的 QML `XMLHttpRequest` 没实现它。**
    ///    2026-10-06 实测（黑洞服务端：accept 后永不回包）——
    ///    `xhr.timeout = 1200` 赋值**能读回 1200**（那只是个 JS 属性、骗过读回），
    ///    但 **5 s 内零回调**：无 `ontimeout`、无 `readyState === DONE`、无 `onerror`
    ///    ⇒ 请求**永远挂着**，回调永远不来。⚠️ 别用「读回等于所设」当它生效的判据。
    ///    对照臂（同一份脚本里对正常应答的服务端）：2 ms 拿到 `status 200`，机制本身没问题。
    ///    ⇒ 超时只能由 QML 侧自己的 `Timer` 兜。见 `_onVtolDistanceArrived()`（它会停表）。
    Timer {
        id: _vtolTimeoutTimer
        interval: 5000
        repeat: false
        // 迟到的应答由 `_onVtolDistanceArrived` 里的 `seq` 判据丢弃，所以这里
        // 直接报「当前在途的那一次的序号」即可。
        onTriggered: opsView._onVtolDistanceArrived(opsView._vtolReqSeq, false, NaN)
    }

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
        // ‼️ **转换距离还在路上时不要建 sync**（设计稿 §7.3.1）。
        //    `OpsRouteSync.vtolTransitionDistance` 是下面的 `createObject` 初值，
        //    而初值**只在建的这一刻求值一次** ⇒ 在途时建会把「还没有值」烘进航线；
        //    更糟的是事后补调会命中上面那个 `ex` 早返回（`ex.vehicle === vehicle`，
        //    不会重发）⇒ `start()` 一次都不会被调，**航线永远发不出去且全程无报错**。
        //    ⇒ 未就绪就**别建**：`_routeSyncs` 里不留半成品，补调走的是「新建」分支。
        // 位置＝`ex` 早返回**之后**：放函数最前面的话，为 B 机取值的那几十毫秒里会把
        //    A 机已建好的 sync 也一并挡掉（本函数只有一个调用点、返回值无人使用，
        //    两种放法行为无差，放这里要解释的东西更少）。
        if (_vtolTransitionDistance === -1) return null
        var sync = _routeSyncComponent.createObject(opsView, {
            "vehicle": vehicle,
            "routeId": task.route_id,
            "get":     _get,
            // 起飞机位朝向的来源 —— `OpsRouteSync` 据此把起飞项（`cmd 84`）的坐标从 `home`
            // 偏到机位朝向上（见该文件 §④c）。这里**传整个 task** 而不是先取出朝向：
            // 朝向是 `createObject` 之后才算的，而 `createObject` 的初值只在建的这一刻求值一次
            // ⇒ 先把 task 交给它，由它自己按同一份数据算，避免"两处各算一遍"。
            "task":    task,
            // 转换距离**按值注入**（不是绑定）：初值只在建的这一刻求值一次，而上面那道闸
            // 已保证此刻它必然 **>= 100**（`-1` 到不了这里，§7.4 的归一化保证没有其它形态）。
            "vtolTransitionDistance": _vtolTransitionDistance
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
        // ‼️ **闩只包住「发请求」这一句，任务循环每次照跑**（设计稿 §7.3.1 末）。
        //    反过来写 —— 把闩提到本函数第一句
        //        `if (_vtolDistanceAskedFor === vehicle) return`
        //    —— 会让航线**永远建不出来**，因为补调走的正是这条路：
        //        XHR 回来 → _syncRoutesForAlreadyConnected() → _onVehicleConnected(同一架)
        //        → 闩命中 → return ⇒ 任务循环根本没跑到。
        //    （`_fetchVtolTransitionDistance` 内部自己判闩，所以这句是幂等的。）
        _fetchVtolTransitionDistance(vehicle)
        var ts = _tasks
        if (!ts) return
        for (var i = 0; i < ts.length; i++) {
            var t = ts[i]
            if (!t || !t.device_id || t.device_id !== vehicle.deviceID()) continue
            if (!t.route_id) continue
            _syncRouteForTask(t, vehicle)
        }
    }

    /// 取一次 VTOL 起飞转换距离（设计稿 §7.3）。
    ///
    /// **内部自己判闩**：每个 Vehicle 对象只发 1 次（含在途）。调用方每次都调它，
    /// 由它决定这次要不要真的发 —— 这样 `_onVehicleConnected()` 的任务循环
    /// 不会被闩挡住（见该函数里那段）。
    ///
    /// ‼️ **请求必须带超时**：服务端不响应时回调**永远不来** ⇒ 参数永远停在 `-1`、
    ///    航线永远建不出来（`_syncRouteForTask()` 那道闸会一直挡住）。
    ///    这不是本参数特有的要求，是「取一次后台数据」这件事的通用做法：
    ///    **预设一个时间，时间一到不等返回**（用户原话）。
    ///    ⚠️ 超时**不能用 `xhr.timeout`**（Qt 6.11 的 QML XHR 没实现它，见
    ///    `_vtolTimeoutTimer` 的注释与那里的实测）⇒ 由那个 Timer 兜。
    ///    也因此这里不走 `OpsShell._get`（它没带超时能力）。
    function _fetchVtolTransitionDistance(vehicle) {
        if (_vtolDistanceAskedFor === vehicle) return
        _vtolDistanceAskedFor = vehicle
        _vtolReqSeq += 1
        var seq = _vtolReqSeq
        if (_apiBase === "") {
            // gcs_server 地址没配 ⇒ 不必干等超时，直接走同一个落定出口。
            _onVtolDistanceArrived(seq, false, NaN)
            return
        }
        var xhr = new XMLHttpRequest()
        xhr.open("GET", _apiBase + "/api/operational-constants")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthController.authToken())
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var ok = (xhr.status >= 200 && xhr.status < 300)
            var v = NaN
            if (ok && xhr.responseText && xhr.responseText.length) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    var items = data ? data.items : null
                    for (var i = 0; items && i < items.length; i++) {
                        if (items[i] && items[i].key === "vtol_takeoff_transition_distance") {
                            v = Number(items[i].value)
                            break
                        }
                    }
                } catch (e) {
                    console.warn("OpsView: 运营常数响应非 JSON，起飞转换距离退回内置 300")
                }
            }
            _onVtolDistanceArrived(seq, ok, v)
        }
        // 网络错（连接被拒、DNS 失败…）走这里；**「服务端不响应」不走这里**，
        // 那条路由 `_vtolTimeoutTimer` 兜（`xhr.timeout` 在 Qt 6.11 无效）。
        xhr.onerror = function() { _onVtolDistanceArrived(seq, false, NaN) }
        _vtolTimeoutTimer.restart()
        xhr.send(null)
    }

    /// 取值**落定**（成功、超时、网络错、地址未配，四条路都走这里）：
    /// 按 `seq` 去重 ⇒ §7.4 归一化 ⇒ 补调被挡下的建 sync。
    function _onVtolDistanceArrived(seq, ok, v) {
        // 一次请求有三个落定点，谁先到谁算数、后到的丢弃（`seq` 只增 ⇒ `<=` 即已落定）。
        if (seq <= _vtolSettledSeq) return
        _vtolSettledSeq = seq
        _vtolTimeoutTimer.stop()
        // ‼️ 「内置 300」这个兜底字面量全链**共四处**，改值时四处都要人工同改
        //    （设计稿 §7.4；跨语言/跨文件的相等关系**没有判据**）：
        //      ① 迁移里的种子值（`db/migrate.go` 写入 `table_operational_constant` 的 300）
        //      ② Go 的 `defaultVtolTakeoffTransitionDistance`（`handlers/operational_constant.go`）
        //      ③ 这一处（`_vtolTransitionDistance` 取不到时的归一化）
        //      ④ `OpsRouteSync.qml` 里 `transitionM` 取不到时的归一化（同仓，同一个 300）
        //    ⚠️ 2026-10-08 订正：原注释写「QGC 侧只有这一处」「三处要人工同改」——**两处都错**，
        //    漏掉了同仓的 ④（`src/OpsView/OpsRouteSync.qml` 的 `transitionM = 300`）。
        //    ⚠️ **边界：链外还有第 5 个同量纲字面量，改上面四处时不必动它** ——
        //    `src/Settings/PlanView.SettingsGroup.json` 的 `vtolTransitionDistance` 默认值也是 300.0。
        //    它自 2026-10-06 起对本项目的起飞转换点**已不生效**（改它无效，界面无提示，
        //    设计稿 §10.1 登记过的已知代价），但**不能删**：上游 Plan 视图仍有两个读者
        //    （`MissionManager/TakeoffMissionItem.cc` 的起飞点默认距离、
        //    `MissionManager/VTOLLandingComplexItem.cc` 的降落地距离默认值）。
        //    在这里点明它，是为了让上面「共四处」这个断言有**明确的排除范围**——
        //    否则第 5 个字面量会让「共四处」读起来像是漏数了。详见本文件「VTOL 起飞转换距离
        //    （运营常数）」那段（`_vtolTransitionDistance` 属性定义处）的完整边界论证。
        _vtolTransitionDistance = (ok && isFinite(v) && v >= 100) ? v : 300
        // 在途期间被 `_syncRouteForTask()` 挡下的那些任务，现在补建。
        // （该函数已存在，`Component.onCompleted` 与 `on_TasksChanged` 都在调它。）
        _syncRoutesForAlreadyConnected()
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
                        // ‼️ 只在**本 `Component` 内部**可见 —— 八个动作的锚点换算写在下面各自的
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
                        // ‼️ 八个动作都在 `open()` **之前**把触发卡片的下缘记进 `_confirmAnchorY`，
                        //    确认框的 `y` 绑定它 ⇒ 弹框长在那张卡片正下方。两个坐标系的换算在这里
                        //    做：信号给的是**卡片相对本组件**的下缘，弹框的 `y` 要的是**相对 opsView**，
                        //    故再过一次 `mapToItem`。（`card.y` 为什么不能用：见 TaskListPanel 处注释。）
                        onTakeoffRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"takeoff", task:task}
                            actionConfirmDialog.open()
                        }
                        // ‼️ 这两档与另外六个不同：**先弹机位选择框，再弹确认框**（用户 2026-10-08）。
                        //    所以这里不进 `_pendingAction` / 不开 `actionConfirmDialog` —— 那两步
                        //    都推迟到操作员选完机位**并确认后**（`slotDialog` 的 delegate → `_commitLand`）。
                        // ⚠️ 锚点仍在这一刻算好传进去：等选完机位再算，`cardBottomY` 早就没有意义了
                        //    （卡片可能已被 `_poll()` 换掉）。
                        onLandRequested: function(task, cardBottomY) {
                            opsView._beginLandFlow(task, OpsCommon.LAND_KIND_TO_MC,
                                                   taskListPanel.mapToItem(opsView, 0, cardBottomY).y)
                        }
                        onKeepFwLandRequested: function(task, cardBottomY) {
                            opsView._beginLandFlow(task, OpsCommon.LAND_KIND_KEEP_FW,
                                                   taskListPanel.mapToItem(opsView, 0, cardBottomY).y)
                        }
                        onMcRescueLandRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"mcRescueLand", task:task}
                            actionConfirmDialog.open()
                        }
                        onParkRequested: function(task, cardBottomY) {
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            opsView._pendingAction = {kind:"park", task:task}
                            actionConfirmDialog.open()
                        }
                        // 【指定机位】= 机位选择框的**另一种用途**：选中即写库（原行为）。
                        // ‼️ `_slotDialogMode` 必须在这里复位成 "assign"：不复位的话，走过一次
                        //    【降落】之后它一直停在 "land" ⇒ 点【指定机位】选中的机位**不会落库**、
                        //    而是弹出一个降落确认框。那是一条**不出错、只做错事**的路径。
                        onAssignSlotRequested: function(task, cardBottomY) {
                            opsView._slotDialogMode = "assign"
                            opsView._slotDialogLandKind = ""
                            opsView._assignSlotError = ""
                            opsView._assignSlotTask = task
                            // ‼️ 锚点与另外八个动作**同款**（用户 2026-10-08 第三轮：
                            //    「位置，我们的惯例是显示在对应任务卡片的下方」）。
                            //    改前这里**不设**锚点 ⇒ `_confirmAnchorY` 会停在上一次动作留下的
                            //    值上（或初值 -1）⇒ 机位框要么贴着一张不相干的卡片、要么落到屏幕正中。
                            //    ⚠️ 与 `onLandRequested`/`onKeepFwLandRequested` 那条的区别只是
                            //    时机：那两条设完锚点还要等一次"选机位"才弹确认框，本条的框**就是**
                            //    这一步，所以设完立刻 `open()`。
                            opsView._confirmAnchorY = taskListPanel.mapToItem(opsView, 0, cardBottomY).y
                            slotDialog.open()
                        }
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
    OpsDialog {
        id: landBlockDialog
        parent: opsView
        // ‼️ 2026-10-08 第四轮：并入共用皮肤（`OpsDialog`），宽度与右栏一致、贴窗口右缘。
        //    改前 `width: 400` 是**硬编码**，而且 `x`/`y` **都没写** ⇒ `Dialog` 缺省落 (0,0)，
        //    表现在界面上就是**屏幕左上角**（同一个坑 `actionConfirmDialog` 于 2026-09-28
        //    已经踩过一次，当时只修了那一个框，本框一直漏着）。
        //    ⚠️ `y` **不读 `_confirmAnchorY`**：本框由"降落校验未通过/指令下发失败"弹出，
        //       触发它的**不是某张卡片上的按钮** ⇒ 没有锚点来源，读了只会用到上一次动作
        //       留下的残值、贴着一张不相干的卡片。故直接垂直居中。
        width: opsView.rightPanelWidth
        x: opsView.width - width
        y: (opsView.height - height) / 2
        modal: true
        title: qsTr("降落被阻止")

        ColumnLayout {
            width: parent.width
            spacing: 8
            Text {
                Layout.fillWidth: true
                // 亮红 `#ff6b6b` —— 深绿底 `#0f2f2c` 上 **5.17:1**，过 AA 4.5:1，
                // 与卡片里的错误红同值（本框换深色底后本行**不用改**，原本就是深底家族的色）。
                color: "#ff6b6b"; font.pixelSize: 13
                wrapMode: Text.Wrap
                text: qsTr("降落操作已被阻止，请人工确认机位/状态后重试。")
            }
            Text {
                Layout.fillWidth: true
                // ‼️ 本行取值的**三度翻转**（2026-10-08），别再翻回去：
                //    ① 原为琥珀 `#ffc107` —— 落在浅底 `Dialog` 上只剩 1.63:1，用户 2026-09-28
                //       反馈"非常不明显"；
                //    ② 改成深蓝 `#1565c0`（白底 5.75:1，那时是对的）；
                //    ③ 本轮本框并入深色底（`OpsDialog`）⇒ 深蓝只剩 **2.50:1**，改回深底家族的
                //       次要色 `#9fb3d4`（**6.75:1**）。
                //    结论同 `slotDialog`：**字色跟着底走**，没有哪个色值"天生正确"。
                color: "#9fb3d4"; font.pixelSize: 12
                wrapMode: Text.Wrap
                text: opsView._landBlockReason
            }
        }
    }

    //-------------------------------------------------------------------------
    // 机位选择弹框（SITE_ATC）——**两种用途共用**：见 `_slotDialogMode` 的声明注释。
    //   "assign"：【指定机位】，选中即写库（原行为）。
    //   "land"  ：【降落】/【切换多旋翼降落】的第一步，**只选、不写库**。
    //-------------------------------------------------------------------------
    OpsDialog {
        id: slotDialog
        parent: opsView
        // ‼️ 宽度与右边栏一致（用户 2026-10-08 第四轮：「宽度有与右边栏宽度等宽」）。
        //    原为**硬编码 360**。而右边栏是**可变宽**的 —— `rightPanelWidth` = 站点视图下
        //    `min(510, max(340, 机位图所需宽))`（见本文件顶部 `rightPanelWidth` 的声明）
        //    ⇒ 机位图宽时弹框比栏窄、机位图窄时又比栏宽，两边永远对不齐。
        //    与 `actionConfirmDialog` / `handoverDialog` 逐字同款。
        // ⚠️ 宽度变成可变值后，下面机位格 `Flow` 的**列数会随栏宽变**（原注释按 360 算的
        //    固定 3 列已失效）—— 这是 `Flow` 的正常行为，不需要按宽度补分支。
        width: opsView.rightPanelWidth
        modal: true
        // ‼️ 位置与 `actionConfirmDialog` **逐字同款**：贴右边栏、上部对齐**触发它的那张任务卡片**
        //    的下缘（留 6px，卡片靠下时向上收，别顶出屏幕底）。用户 2026-10-08 第三轮：
        //    「位置，我们的惯例是显示在对应任务卡片的下方」。
        //    改前本框 `x`/`y` **都没写** ⇒ `Dialog` 缺省落在 (0,0)，看起来在**屏幕左上角**
        //    （同一个坑 `actionConfirmDialog` 在 2026-09-28 已经踩过一次）。
        //    锚点由 `_beginLandFlow` / `onAssignSlotRequested` 在 `open()` 之前写入
        //    —— 两个入口都写，缺一个就会用到上一次动作的残留值。
        x: opsView.width - width
        y: opsView._confirmAnchorY < 0
           ? (opsView.height - height) / 2
           : Math.min(opsView._confirmAnchorY + 6, opsView.height - height - 12)
        title: opsView._slotDialogMode === "land" ? qsTr("选择降落机位") : qsTr("指定降落机位")
        // ‼️ 深色卡片皮肤（底 `#0f2f2c` / 描边 `#26a69a` / **覆写 `header`**）已**上移**到
        //    `OpsDialog.qml` —— 本框 2026-10-08 第三轮时只在这里写了一份；第四轮四个框
        //    （选择机位 / 确认 / 交接 / 降落被阻止）统一走那个组件，改配色只改那一处。
        // ⚠️ 第三轮写在这里的那句警告「**只改本框**；`actionConfirmDialog` 保持平台默认浅底，
        //    它另外六档跟着翻会一起失效」**已被第四轮推翻**：现在**四个框全是深底**。
        //    它连同它的理由一并作废，别照它去回退。正确做法不是「别翻」，而是翻的时候
        //    **把框内字色一起翻**（浅底那套色搬到深绿底上的实算对比度见 `OpsDialog.qml`）。

        ColumnLayout {
            width: parent.width
            spacing: 6
            Text {
                Layout.fillWidth: true
                // 正文两行**条目化**（用户 2026-10-08 第四轮：「提示内容要条目化，具体的显示
                // 两行，第一行：飞行任务：，第二行：无人机：」）。两种用途（land / assign）
                // **同版式** —— 它们在界面上本来是同一个框，不该因为入口不同换一套排版。
                // ⚠️ 动作说明（「选择降落机位」/「指定降落机位」）**不写在这里**：它已经在
                //    `title` 上，正文再写一遍就是同一块地方说两遍。
                // ‼️ 第一行必须取 `t.task_no`，**不能**用 `OpsCommon.taskNo(t)`：那个函数
                //    **优先返回 `uav_no`**（`task.uav_no ? task.uav_no : task.task_no`，
                //    「航班号」语义）⇒ 两行会显示**同一个值**。同一条教训见 `_landConfirmTaskNo`。
                //    （本轮之前 `assign` 分支正是 `OpsCommon.taskNo(t)`，两行同值。）
                // ⚠️ 条目名与 `actionConfirmDialog` 的三行摘要**用词一致**（「飞行任务：」/
                //    「无人机：」）—— 两个框一前一后出现，读起来要是同一套。
                color: "#e6edf7"; font.pixelSize: 12
                wrapMode: Text.Wrap
                text: {
                    var t = opsView._assignSlotTask
                    if (!t) return ""
                    return qsTr("飞行任务：%1\n无人机：%2")
                        .arg(t.task_no ? t.task_no : "—")
                        .arg(t.uav_no ? t.uav_no : "—")
                }
            }
            // 空态：本站一个可用机位都没有（全被占用 / 全未核准 / 机场压根没建机位）。
            // ‼️ 必须有：本轮把两颗降落按钮改成**恒可点**（因为点下去第一步就是选机位）⇒
            //    "点开发现是空的"从不可达变成**可达**。没有这行，用户看到的是一个空框，
            //    分不清是"本站没机位"还是"界面卡住了"。
            Text {
                Layout.fillWidth: true
                visible: opsView._slots.length === 0
                // 琥珀 `#ffc107` —— 深色底上的警示色（与卡片里那两条警示同值）。
                color: "#ffc107"; font.pixelSize: 12
                wrapMode: Text.Wrap
                text: qsTr("本站暂无可选机位（机位须已核准且空闲）。")
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
                // 3 列 × 104 + 2 × 8 = 328 ≤ 内容宽（360 − Dialog 两侧 padding 24）⇒ 恰好三列。
                spacing: 8
                Repeater {
                    model: opsView._slots
                    // ‼️ 机位格改成**卡片式**（用户 2026-10-08 第三轮「机位列表也要优化」）。
                    //    原为平台默认按钮（浅色圆角 + 深字 + `slot_code（占用）` 一行平铺），
                    //    落在本轮新换的深色框里既刺眼又和任务卡片是两个世界。
                    //    现改为与任务卡片同族的小卡：深底 / 描边 / 浅字，**三态可辨**：
                    //      不可用（暗底暗字 + 原因） / 当前已指派（蓝描边 + 「当前机位」） /
                    //      可选（常态，悬停转青绿）。
                    delegate: Button {
                        id: slotBtn
                        width: 104; height: 44
                        enabled: opsView._slotAssignable(modelData)
                        // 「当前已指派」= 这条任务**库里**那个 `assign_slot_id`（旧值）。
                        // ⚠️ 本框**不预选**它、也不把它当作默认提交值（用户裁定「确认执行时才写」，
                        //    选中谁就是谁）—— 只做**标记**，让操作员一眼看出"不改的话飞机落在哪"。
                        readonly property bool _isCurrent:
                            !!opsView._assignSlotTask
                            && modelData.id === opsView._assignSlotTask.assign_slot_id
                        background: Rectangle {
                            radius: 4
                            border.width: 1
                            // 底色三态：不可用（比卡底更暗，视觉下沉） > 悬停（青绿压暗） > 常态卡底。
                            color: !slotBtn.enabled ? "#131c2e"
                                   : (slotBtn.hovered ? "#16403a" : "#16233c")
                            // 描边优先级：不可用（最暗的蓝灰） < 常态 < 悬停青绿 < **当前机位蓝**
                            // ——「当前」是这块格子里信息量最大的一格，不能被悬停盖掉。
                            // 蓝色取 `#2f6bd8`，与任务卡片"已选中"的边框同值。
                            border.color: !slotBtn.enabled ? "#243349"
                                          : (slotBtn._isCurrent ? "#2f6bd8"
                                             : (slotBtn.hovered ? "#26a69a" : "#2a4a6b"))
                        }
                        contentItem: Column {
                            spacing: 2
                            anchors.centerIn: parent
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData.slot_code
                                color: slotBtn.enabled ? "#e6edf7" : "#5c6b85"
                                font.pixelSize: 13
                                font.bold: slotBtn._isCurrent
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                // 第二行：**不可用原因优先**（占用/未核准/维护/故障），
                                // 没有原因时才是「当前机位」，两者都没有就不占位。
                                // ⚠️ 顺序不能反：一个"当前但已被占用"的机位若显示「当前机位」，
                                //    操作员会以为它可用。
                                text: {
                                    var h = opsView._slotAssignHint(modelData)
                                    if (h !== "") return h
                                    return slotBtn._isCurrent ? qsTr("当前机位") : ""
                                }
                                visible: text !== ""
                                color: slotBtn.enabled ? "#9fb3d4" : "#5c6b85"
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                        onClicked: {
                            if (!opsView._assignSlotTask) return
                            if (opsView._slotDialogMode === "land") {
                                // 【降落】第一步：**只选、一个字节都不发**。
                                // ‼️ 落库在 `_commitLand` 里、由红绿确认框的「确认执行」触发
                                //    （用户 2026-10-08 逐字裁定「确认执行时才写」）。提前发的话，
                                //    "选完机位又点【取消】"也会在库里留下一次机位变更。
                                var kind = opsView._slotDialogLandKind
                                // 防御：`mode === "land"` 而 `kind` 为空说明有人漏设了配对的那一格
                                // （两者只在 `_beginLandFlow` / `_commitLand` / `onAssignSlotRequested`
                                // 三处同写）。此时**什么都不做**，不要带着空 kind 去开确认框 ——
                                // `_execPendingAction` 会把空 kind 落进"一个分支都不匹配"，表现为
                                // 「点了确认执行、什么都没发生、零报错」。
                                if (!kind) {
                                    console.warn("OpsView 降落：_slotDialogLandKind 为空，本次未发起")
                                    return
                                }
                                var t = opsView._assignSlotTask
                                slotDialog.close()
                                opsView._assignSlotTask = null
                                // 机位取 `slot`（本次**选中**的这个，供确认框第三行显示）；
                                // 此刻库里那个 `assign_slot_id` 还是旧的，故意不看它。
                                opsView._pendingAction = { kind: kind, task: t, slot: modelData }
                                actionConfirmDialog.open()
                                return
                            }
                            opsView._assignSlot(opsView._assignSlotTask, modelData.id, function(ok) {
                                if (ok) { slotDialog.close(); opsView._assignSlotTask = null }
                            })
                        }
                    }
                }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 飞行控制动作红绿确认弹框，共**八种**：起飞、保持固定翼降落、切换多旋翼降落、MC方式降落（救济）、
    // 停泊（前五种在站点视图的卡片上），以及中段飞行的签出/取消/回航（用户 2026-09-23 要求后三者
    // 也要确认）。交接的**受理**（签入/驳回）仍走 handoverDialog——那是另一回事。
    // 红=确认执行（危险动作警示）、绿=取消（安全退出）。未来专用控制台做大红/大绿实体按钮。
    //-------------------------------------------------------------------------
    OpsDialog {
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
                // ‼️ 本行取值的**三度翻转**（2026-10-08），别再翻回去：
                //    ① 原为琥珀 `#ffc107` —— 落在浅底 `Dialog` 上只剩 1.63:1，用户 2026-09-28
                //       反馈「非常不明显」；
                //    ② 改成深蓝 `#1565c0`（白底 5.75:1；救济档深红 `#c62828` 5.62:1）—— 那时是对的；
                //    ③ 本轮本框并入**深色底**（`OpsDialog`）⇒ 深蓝只剩 **2.50:1**、深红只剩 **2.55:1**，
                //       两个都不及格 ⇒ 换成深底家族，现值与实算值见 `_pendingConfirmHintColor`。
                //    结论与 `slotDialog` / `landBlockDialog` **同一条**：**字色跟着底走**，
                //    没有哪个色值天生正确，错的是把某个底上量过的色搬到另一个底上。
                color: opsView._pendingConfirmHintColor(); font.pixelSize: 13
                wrapMode: Text.Wrap
                text: opsView._pendingConfirmHint()
                // ‼️ 降落两档（F1/F2）与救济档（F3）**都不显示这行**：它们的正文换成了下面
                //    各自的结构化块（第四轮「解释性文字不需要」／第五轮救济档重写）。
                //    `_pendingConfirmHint()` 对这三档恒返回空串，此处再叠一道 `visible` ——
                //    空串也占 `ColumnLayout` 的一行高度。
                // ⚠️ 剩下**五档**（起飞/停泊/签出/取消/回航）继续走这里。
                visible: !opsView._isLandSummaryKind(opsView._pendingAction)
                         && !opsView._isRescueKind(opsView._pendingAction)
            }
            // ── 降落两档（F1 保持固定翼 / F2 切换多旋翼）的正文：**三行条目**（用户 2026-10-08）──
            // 第二轮原话：「把对话框改成一个类似任务卡片的风格，提示的内容有三行： 任务：,无人机：,机位。」
            // 第四轮又要求：「选择完机位后，进入确认界面的**风格也要与此相同**」（同 `slotDialog`）。
            // ‼️ 于是这里**去掉了原来那个内嵌的 `#16233c` 矩形块**：
            //    · 第二轮那时整个 `Dialog` 还是平台默认的**浅底**，正文里套一块深色卡是"像任务卡"
            //      的唯一做法；
            //    · 第四轮整个框本身就是深色卡片了（`OpsDialog`），再套一层同族深色块
            //      **看不出边界**（`#16233c` 与框底 `#0f2f2c` 几乎同亮度），
            //      而且和 `slotDialog` 的两行纯文字对不上 —— 那才叫"风格不同"。
            // ⚠️ 条目名与 `slotDialog` **用词一致**：「飞行任务：」/「无人机：」。第二轮用户写的是
            //    「任务：」，第四轮写的是「飞行任务：」—— 本轮统一取**后者**，因为这两个框在界面
            //    上是一前一后出现的、同一个字段不该有两个名字。
            // ⚠️ 第三行取的是操作员**上一步刚选中的**机位（`_landConfirmSlotCode`），不是库里的
            //    `assign_slot_id` —— 此刻库还没写（用户裁定「确认执行时才写」）。
            Column {
                Layout.fillWidth: true
                visible: opsView._isLandSummaryKind(opsView._pendingAction)
                spacing: 5
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: qsTr("飞行任务：") + opsView._landConfirmTaskNo(opsView._pendingAction)
                }
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: qsTr("无人机：") + opsView._landConfirmUAVNo(opsView._pendingAction)
                }
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: qsTr("机位：") + opsView._landConfirmSlotCode(opsView._pendingAction)
                }
            }
            // ── 救济档（F3「直接降落」）的正文（用户 2026-10-08 第五轮；文案订正于第六轮）──
            // 用户 2026-10-08 第六轮订正后的文案，逐字：
            //   「本功能为救济功能，当飞机不可控时才能使用，它将跳过一切状态检查和限制，
            //     直接控制无人机在机位上降落。使用此功能，可能导致前后台数据不一致，
            //     需要通知相关人员处理。」
            // ⚠️ 第五轮原文与订正版有**两处**不同，均以订正版落码，留痕如下：
            //     ①「一切状态**和检查和状态**」→ 订正为「一切**状态检查和限制**」；
            //     ②「可能导致**货台**数据不一致」→ 订正为「可能导致**前后台**数据不一致」。
            //    第五轮我把 ① 标为"疑似重复"、照录未改并单列一条问过用户 —— 用户的答复是
            //    **两处都是错别字**、整段以本轮文字为准。⇒ 遇到读起来别扭的中文需求原文，
            //    正确做法仍是「照录 + 单列一条问」，**不要自行改通顺**：① 我猜错了方向
            //    （猜"重复"、实为"检查和限制"），自作主张改写只会离原意更远。
            //
            // ‼️ 悬挂缩进（hanging indent）用 `RowLayout` + 两个 `Text` 实现，**不是**在长文案里
            //    手打空格：`Text` 没有 CSS 的 `text-indent` / `padding-left` 那套，插空格既数不准，
            //    也会随字体/缩放漂移。`spacing: 0` ⇒ 第二个 `Text` 的左边缘**正好**落在
            //    「重要提示：」的右边缘 ⇒ 换行后的**每一行都从那里起**，正是用户要的
            //    "与上一行是一组"。
            // ‼️ `Layout.alignment: Qt.AlignTop` 两边都要写：不写时右列多行会把左列按竖直居中
            //    摆，「重要提示：」会飘到文案中段，看起来就不像一句话的开头了。
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                visible: opsView._isRescueKind(opsView._pendingAction)
                Text {
                    Layout.alignment: Qt.AlignTop
                    text: qsTr("重要提示：")
                    // 深绿底 `#0f2f2c` 上实算 5.17:1，过 AA 4.5:1（与 `_pendingConfirmHintColor`
                    // 注释里那份表同源）。加粗让"这是警示"在第一眼就成立。
                    color: "#ff6b6b"; font.pixelSize: 13; font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    color: "#ff6b6b"; font.pixelSize: 13
                    wrapMode: Text.Wrap
                    // ⚠️ 整段与「重要提示：」**同色**：用户说的是"一组内容"，缩进已经在版式上
                    //    分组了，颜色再拆开反而把这个组拆散。救济的醒目色就是这么来的。
                    text: qsTr("本功能为救济功能，当飞机不可控时才能使用，它将跳过一切状态检查和限制，直接控制无人机在机位上降落。使用此功能，可能导致前后台数据不一致，需要通知相关人员处理。")
                }
            }
            // 条目的**两行**：与 `slotDialog`、降落两档同款（纯文字、深底浅字、可省略中间）。
            // 取值复用 `_landConfirmTaskNo` / `_landConfirmUAVNo` —— 救济档的 `_pendingAction`
            // 同样带着 `task`（`OpsView.qml` 里那处 `{kind:"mcRescueLand", task:task}`）。
            Column {
                Layout.fillWidth: true
                visible: opsView._isRescueKind(opsView._pendingAction)
                spacing: 5
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: qsTr("任务：") + opsView._landConfirmTaskNo(opsView._pendingAction)
                }
                Text {
                    width: parent.width
                    color: "#e6edf7"; font.pixelSize: 12
                    elide: Text.ElideMiddle
                    text: qsTr("无人机：") + opsView._landConfirmUAVNo(opsView._pendingAction)
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

