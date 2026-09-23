import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// L3 航班 marker 的箭头是 `Shape` + `PathSvg` 自绘的（见该段注释）。
// ⚠️ `Shape` 属于 `QtQuick.Shapes`，**不属于** `QtQuick`——少了这一行，
//    构建、单测、qmllint **三者都不会报错**，只有真的加载这个组件时才炸：
//        OpsShell.qml:1205:29: Shape is not a type   ← 报错**原文**，1205 是当时的行号
//    然后 `OpsView unavailable` → `MainWindow` 起不来（窗口是 null）。
//    同目录 `SlotLayout.qml:2` 是既有先例，用的是同一个 import。
import QtQuick.Shapes
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
    // 是否启用**航线图层**（① my-routes 缓存 + ③ route-tasks）。
    // ‼️ 与 `overviewView` 一样是**数据源参数，不是显示开关**：监控员视图（RomView）置 true，
    //    站点视图（OpsView）保持 false——站点操作员没有被指派"负责航线"，拉它没有意义，
    //    更不该让站点视图的地图长出第二个会与 `_tasks` 竞争的数据源。
    //    置 true 后：地图的 L1 航线/ L3 飞机 marker 改吃航线缓存与 ③ 的 `devices`，
    //    骨架才会去跑 §7.2 的首拉序列与 ③ 的轮询。
    property bool   routeLayersEnabled: false

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    // 每次轮询后发。**视图专属**的请求挂在它上面（OpsView 连机位、RomView 连接引清单）——
    // 让骨架的 `_poll()` 保持"只拉两视图共用的两份数据"，不必认识机位。
    signal polled()
    // 选中任务（地图 marker 或列表点击都走它）。视图侧据此同步自己的机位高亮等。
    signal taskSelected(var task)
    // 选中航线（§4.3）。`null` = 取消选中。视图侧据此点亮地图上的 L2。
    signal routeSelected(var routeId)
    // ③ **每次成功**后发。监控员视图据此把 `devices` 的 device_id 清单推给 C++（§3.5.3）。
    // ‼️ **不能挂在 `polled()` 上**：`_poll()` 发出信号时 ③ 的异步响应还没回来，
    //    那时读到的是**上一轮**的 `_routeDevices`——清单会差一拍，而且首拉时是空的。
    signal routeTasksUpdated()

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
    property string _tasksJson:    ""      // 上一轮 `_tasks` 载荷的内容指纹（作用见 `_fetchOverview`）
    // 地图 L1 航线的**几何数据源**：只含任务身份 + 航点，**不含 `latest` 遥测**。
    /// ‼️ 为什么要跟 `_tasks` 分开：`_tasks` 带 `latest`，飞机每动一次内容就变 ⇒ 换身份
    ///    ⇒ 航线**陪着一起销毁重建**（离屏探针实测：只改一条 `latest`，4 条线全量 +4/−4）。
    ///    而航线画的是航点，与遥测无关 —— 飞机在飞时这个空转每 2s 发生一次。
    ///    这里再用**内容指纹**兜一层：几何没变就保持原数组身份。
    /// ⚠️ `_taskGeom` 的元素是**新建的 JS 对象**，但 `waypoints` 仍指向原数组（不复制）。
    /// ⚠️ 本属性**必须由 `_rebuildTaskGeom()` 显式维护**，不要改成读 `_tasks` 的绑定。
    property var    _taskGeom:     []
    property string _taskGeomKey:  ""
    property var  _pending:        []      // /handovers/pending 待确认交接数组
    property var  _handoverById:   ({})    // task_id -> pending handover
    property var  _seenHandovers:  []      // 已提示过的 handover id（防重复弹框）
    property var  _selectedTaskId: -1
    property var  _confirmHandover: null   // 交接弹框当前对象
    property int   _now:           Date.now()
    property string _handoverActionError: ""  // 交接确认/拒绝/撤回失败提示（handoverDialog 保留可重试）
    // 本站站点 id 来自登录响应 role_sites 单值（AuthController.siteId，仅内存），不再从任务反推。
    property var   _mySiteId:       AuthController.siteId
    // 本站站点**坐标**（`GET /api/sites/:id` 的 `lat`/`lon`）。站点视图套视野的**中心锚点**。
    /// ‼️ 为什么 id 与坐标分两个属性：id 是登录响应直接给的（内存里就有），坐标要走一次接口。
    /// ‼️ 站点表**本身不存坐标**——`table_site` 只有 `waypoint_id`，坐标在关联的 `table_waypoint`。
    ///    后端 `siteJoinSelect` 已 `LEFT JOIN table_waypoint` 把 `w.lat`/`w.lon` 并进响应，
    ///    所以这里拿到的是**权威值**，前端不需要（也无法）自己拼。
    /// ⚠️ `null` = 还没拿到 / 本站没挂航点（后端 `COALESCE(w.lat,0)` 会给出 0，被有效性检查挡掉）
    ///    ⇒ 套视野退化为"居包围盒中心"，与监控员视图逐字一致；`center` 兜底链另有落点。**不崩**。
    property var   _mySiteCoord:    null

    // 机位范围圈的**最小可见直径**（屏幕像素）。用户 2026-09-23 裁定：「为站点设置一个最小
    // 像素尺寸，当在某个比例尺下，站点圆圈小于最小像素尺寸，则按照最小像素尺寸显示」。
    /// ‼️ 为什么非要有它：本站机位簇实测跨度约 177 m × 75 m，而「完整显示所有航线」套出来的
    ///    比例尺约 **357 m/px** ⇒ 真实圆圈直径**不到 1 像素**。没有下限就是"画了但看不见"。
    /// ⚠️ 取 120 是"够醒目、又不至于盖住半个屏幕"的**起点值**，没有理论依据——它最终是给
    ///    人眼看的，要按真机目视结果调。别把它当成推导出来的数。
    readonly property real _minSlotCircleDiameterPx: 120

    /// 机位范围圈的**最大显示直径**（屏幕像素）—— 超过就**不画**（判据在地图图层处）。
    /// ‼️ 这是**信息量**判据不是美观判据：圆一旦大到直径是满屏的好几倍，它在屏幕上剩下的
    ///    那段"弧"已经近乎一条直线——用户看不出那是个圈，画出来只是干扰。与
    ///    `_minSlotCircleDiameterPx` 对称：小到看不见就抬到最小可见，大到没信息量就不画。
    /// ⚠️ 它同时是**防御**：`MapQuickItem` 的 `sourceItem` 是**屏幕像素**尺寸（半径要自己除
    ///    米/像素），zoom 21 + 一个几公里跨度的站点能算出几十万像素的 Shape，那是真实的卡顿
    ///    风险。取 20000（≈ 5 倍 4K 屏宽）远超任何真实屏幕，**正常使用永远不触发**——本站机位
    ///    簇直径约 200 m，zoom 21 时也只有约 4400 px。
    readonly property real _maxSlotCircleDiameterPx: 20000

    // 本站机位数组（**已核准**，含维护/故障），**由视图注入** —— 范围圈的原料。
    /// ‼️ 为什么注入的是**原始机位数组**而不是算好的圆：圆的圆心是**站点坐标**，而
    ///    `_mySiteCoord` 是**异步**到手的（`_fetchMySite` 的回调，见 `_fetchMySite` 处）。
    ///    若在视图侧命令式算圆，站点坐标**后到**时没有任何东西会触发重算 —— 圆永远画不出来。
    ///    搬进基类做成**绑定**后，`_mySiteCoord` 与 `_slotList` 两个依赖源任一变化都自动重估。
    /// ‼️ 仍然**必须由视图注入**（不能在基类自己拉）：机位数据挂在派生类型上，而**基类读不到
    ///    派生类成员**。同 `rightPanelWidth` 的模式。
    /// ‼️ 数据源是**已核准机位**（`_slotsAll`，`?include_unusable=1`）而不是"可用机位"：
    ///    范围圈描述的是本站机位的**物理占地**，维护中/故障的机位照样占着那块地。
    /// ⚠️ 视图侧按**几何指纹**维护身份，不是每次轮询都换数组
    ///    （理由见 `OpsView._updateSlotList`）。
    property var   _slotList: []

    // 本站机位范围圈 = `{lat, lon, radiusM, count}`（`OpsCommon.siteCenteredCircle` 的返回值）；
    // `null` = 站点坐标还没到 / 一个有效机位都没有。
    /// ‼️ 圆心 = **站点坐标**，半径 = 站点到各机位的**最大**距离（用户 2026-09-23 裁定
    ///    「改为以站点坐标为中心，圈住各个机位」）。**不是**最小包围圆——两者的差别不是精度
    ///    是语义：机位簇偏心时本式的圆明显更大，那是刻意的。`OpsCommon` 里两个函数并存。
    /// ⚠️ 这里**不许**预先取 `max(…, 最小可见直径)`：那是**渲染时**的事（见地图图层处），
    ///    存进来会让"只有一个机位的站点"永久失去真值。
    readonly property var _slotRangeCircle: OpsCommon.siteCenteredCircle(_mySiteCoord, _slotList)

    // 范围圈在**屏幕上的直径**（像素）= 真实直径 ÷ 米每像素。渲染用。
    /// ‼️ 这一条绑定同时吃三个依赖源（圆数据、地图缩放/就绪/尺寸），缺任一都会让圆不随缩放
    ///    更新，**且不报任何错**。后三个靠**实参位置**读 `opsMap.*` 注册依赖——方法调用本身
    ///    不注册（见 `_metersPerPixelAt` 的注释）。
    /// ⚠️ 返回 0 = 没有可画的圆（没数据 / 地图未就绪 / mpp 无效），调用处据此隐藏。
    /// ⚠️ 上界**不在这里**钳：这条绑定的语义就是"真实直径的像素值"，钳了就等于画错。
    ///    见地图图层处 `_maxSlotCircleDiameterPx` 的判据。
    readonly property real _slotRangeDiaPx: {
        var c = _slotRangeCircle
        if (!c) return 0
        var mpp = _metersPerPixelAt(QtPositioning.coordinate(c.lat, c.lon),
                                    opsMap.zoomLevel, opsMap.mapReady,
                                    opsMap.width, opsMap.height)
        if (!isFinite(mpp) || !(mpp > 0)) return 0
        return Math.max(2 * (Number(c.radiusM) || 0) / mpp, _minSlotCircleDiameterPx)
    }

    //-------------------------------------------------------------------------
    // 航线缓存（设计文档 §2.1；仅 `routeLayersEnabled` 的视图使用）
    //-------------------------------------------------------------------------
    // ‼️ **每次整体重建对象**，不原地改属性：QML 绑定不认识"JS 对象的某个键变了"，
    //    原地 `_routeCache[id].waypoints = xs` **不会**触发任何重估（界面静默停在旧值）。
    property var  _routeCache:      ({})   // { "12": {route_id, route_code, route_name, route_type, waypoints} }
    property var  _routeOrder:      []     // 航线 id 的有序数组（保持服务端返回次序）
    property var  _routeTasks:      []     // ③ 的 tasks[]（**一个任务一行**）
    property var  _routeDevices:    []     // ③ 的 devices[]（**一架飞机一行**，飞机字段的唯一载体）
    property bool _routeCacheReady: false  // 区分「还没拉到」与「拉到了但确实是空的」（§2.1）
    property var  _routeUpdatedAt:  null   // ③ 上次**成功**的时刻（陈旧指示用，§2.4）
    property bool _routeTasksStale: false  // ③ 上次请求失败（保留旧数据 + 显示提示条，§2.4）
    property var  _selectedRouteId: null   // §4.3 选中航线；null = 未选中
    property bool _bootstrapping:   false  // §7.2 首拉防重入
    property int  _routeRetryLeft:  0      // ① 的自动重试剩余次数（§7.2）
    property string _routeLoadError: ""    // ①② 的失败提示（空串 = 正常）
    // ③ 下发的帧超时阈值（毫秒）。**由后端给**，不在这里写死——它是接引链路的参数（㉑）。
    property int  _routeFrameTimeoutMs: 3000

    // 右栏上段航线列表的**唯一数据源**（每行 = 一条负责航线）。
    // ⚠️ 地图的 L1/L2 **不吃它**：那两条 `MapItemView` 的 model 是 `routeRowsDimmed()` /
    //    `routeRowsLit()`，读的是 `_routeGeom`（只含几何，不吃 ③）。理由见 `_routeGeom`
    //    声明处——让地图吃 `_routeRows` 会让任务状态一变就重建全部 `MapPolyline`（画面抖动）。
    // ‼️ 做成**派生属性**而不是在委托里调 `_countFor(route_id)`，理由是**重建次数**：
    //    这里的表达式读 `_routeCache`/`_routeOrder`/`_routeTasks` 三个属性，任一变 ⇒
    //    数组**整体重建一次**；写在委托里则每行各建一次、且与行的存活期纠缠。
    // ⚠️ 但**不要**把这条推广成"`function` 调用不注册绑定依赖"——那句是错的，已证伪：
    //    QML 对 **JS 函数**调用是记录依赖的。反证就在本文件——`center` 的绑定调
    //    `_firstTaskCoord()`、函数体内读 `_tasks`，而 `_poll()` 每 2s 重赋 `_tasks`，
    //    它就跟着重估一次；`_routeFitCenter`/`_routeFitZoom` 那套"回读存值"机制**正是
    //    为对抗这个**而存在的。不记录依赖的是 **C++ 的 `Q_INVOKABLE`**，不是 QML/JS 函数。
    //    （本条同时解释了 `routeRowsDimmed()/routeRowsLit()` 写在 `model:` 里为什么有效。）
    readonly property var _routeRows: {
        // ‼️ 分组与计数**住 `OpsCommon` 纯函数**，本文件不再内联实现一遍。
        //    理由有二：纯函数才是 QML 测试基础设施够得着的（写在骨架里只能靠肉眼比对）；
        //    且这两段判据原先在本文件与 `OpsCommon` 里**各有一份定义**，会各演化各的。
        // ‼️ `groupTasksByRoute` 按 `_routeOrder` 建键 ⇒ 无航班的航线拿到的是**空数组
        //    而不是缺键**（缺键会让"这条航线没有航班"与"这条航线的数据还没回来"
        //    在界面上长得一样）。③ 里出现不在名册里的航线时两边都跳过、不新增行。
        var grouped = OpsCommon.groupTasksByRoute(_routeTasks, _routeOrder)
        var out = []
        for (var k = 0; k < _routeOrder.length; k++) {
            var id = _routeOrder[k]
            var r = _routeCache[String(id)]
            if (!r) continue
            var g = grouped[String(id)]
            out.push({
                route_id:     r.route_id,
                route_code:   r.route_code,
                route_name:   r.route_name,
                route_type:   r.route_type,
                waypoints:    Array.isArray(r.waypoints) ? r.waypoints : [],
                active_count: OpsCommon.activeUavCount(g),
                has_abnormal: g.some(OpsCommon.isAbnormal),
                tasks:        g
            })
        }
        return out
    }

    /// ‼️ **供 L1/L2 的 `model` 用：把航线按「是否选中」拆成两个互斥列表。**
    ///    两态（淡/亮）用两个 model 表达而不是在委托里写 `line.color: _lit ? A : B`：
    ///    选中变化时两个数组都重建 ⇒ `MapItemView` 重建委托 ⇒ 每个委托**整个**带着自己的
    ///    宽度+颜色出生，不存在"改了宽度没改颜色"这类半更新。
    ///
    /// ⚠️ 这里原先写的理由（「`MapPolyline.line` 是 group property，其子属性上的真绑定会被
    ///    **静默丢弃**」）**是错的，已证伪**：实测在 GL 后端下 `line.color` 的绑定/表达式
    ///    **完全正常**。当初得出那个结论，是因为取证用的是 `QT_QPA_PLATFORM=vnc`
    ///    （软件渲染后端会**把 R 与 B 通道互换**），而用于证伪的洋红 `#ff00ff` 恰好 R=B
    ///    ⇒ 在互换下不变 ⇒ **假绿**。详见地图处 L1 的长注释。
    ///    ⚠️ 两个函数必须**互斥且完备**：任一航线恰好出现在一边——否则要么同位置叠两条线，
    ///    要么被选中的那条从地图上消失。
    /// ‼️ 读的是 `_routeGeom`（**只含几何，不吃 ③**），不是 `_routeRows`——理由见 `_routeGeom`
    ///    声明处。改成 `_routeRows` 会让任务状态一变就重建全部 `MapPolyline`（画面抖动）。
    function routeRowsDimmed() {
        if (_selectedRouteId === null) return _routeGeom
        return _routeGeom.filter(function(r) {
            return Number(r.route_id) !== Number(_selectedRouteId)
        })
    }
    function routeRowsLit() {
        if (_selectedRouteId === null) return []
        return _routeGeom.filter(function(r) {
            return Number(r.route_id) === Number(_selectedRouteId)
        })
    }

    /// 航点 → `MapPolyline.path`。
    /// ‼️ 逐点过滤无效坐标：`QtPositioning.coordinate(undefined, undefined)` 产出的是一个
    ///    **无效坐标**，而无效坐标进 `path` 的后果是**整条线不画**（不是跳过那个点）。
    /// ‼️ 守卫**不能**写 `Array.isArray(wps)`：`modelData` 里的嵌套数组由 QML 交给委托时被包成
    ///    **序列对象**——`typeof` 是 `"object"`、`Array.isArray()` 恒 **false**，却有 `length`
    ///    且能下标访问（实测同一个值：`isArr=false type=object len=4`）。用 `Array.isArray`
    ///    守卫会直接返回空数组 ⇒ **一条线都不画、零报错**。判据改成"有没有数字型 length"。
    function routePathOf(wps) {
        if (!wps || typeof wps.length !== "number") return []
        var out = []
        for (var i = 0; i < wps.length; i++) {
            var la = Number(wps[i].lat), lo = Number(wps[i].lon)
            // ‼️ 与 `OpsCommon.routeBounds` / `MapFitFunctions` **同一口径**（判据单点定义在
            //    `OpsCommon.isValidWaypoint`）。原先这里只判 `isFinite`、不滤 0 ⇒ 一个缺省航点
            //    (0,0) 会被**画成一条甩到几内亚湾的长线**，而视野拟合又把那个点忽略了
            //    ——画出来的与套出来的不是同一条航线。口径统一后两者必然一致。
            if (!OpsCommon.isValidWaypoint(la, lo)) continue
            out.push(QtPositioning.coordinate(la, lo))
        }
        return out
    }

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
    // ‼️ 「跟随首个任务」现在**只对监控员视图生效**（`center` 绑定里那项带 `routeLayersEnabled &&`
    //    前缀）：站点视图的中心归 §7.4 管，锚点是**本站坐标**（用户诉求「地图中心设置为当前
    //    登陆站点」），不是飞机实时位置。站点视图里 `_mapFollowFirst` 因此成了惰性属性，但
    //    `onMapPanStart` 仍在写它——留着无害，删掉反而让两个视图的平移路径分叉。
    property bool  _mapFollowFirst:  true
    property var   _mapManualCenter: null

    // §7.4 套完视野后**回读**存下来的中心/缩放（仅 `routeLayersEnabled` 的视图会写）。
    // ‼️ 为什么要存：`setVisibleRegion()` 是**从 C++ 侧**写 `center`/`zoomLevel` 的，而这两个
    //    属性在 QML 里挂着绑定。**实测结论（Qt 6.11.1 + `itemsoverlay` 离屏探针）：绑定照旧
    //    活着、不会被解开** ⇒ 2s 轮询必然重估它们（`_fetchOverview` 无条件 `_tasks = data`，
    //    空数组也是新对象 ⇒ `var` 属性必然发变更信号），把地图拽回
    //    `QGroundControl.flightMapPosition`（本机 ini 里是**出厂默认的苏黎世**），航线在 2 秒内
    //    重新消失。存下来并让 `center`/`zoomLevel` 的绑定**优先**取这里的值，问题就消掉了。
    // ⚠️ 写法上仍按"两种语义下都对"来写：绑定活着 ⇒ 重算出同一个值（稳定）；万一哪天 Qt 改了
    //    行为、绑定真断了 ⇒ 这两个属性变成惰性值，也不影响任何东西。**不要**因为"实测说绑定
    //    活着"就把回读那一步删掉——那一步正是这条健壮性的载体。
    property var   _routeFitCenter: null
    property real  _routeFitZoom:   0
    // ③ 上一轮载荷的**内容指纹**。作用不是缓存，是"内容没变就别换对象"——见 `_fetchRouteTasks`。
    property string _routeTasksJson:   ""
    property string _routeDevicesJson: ""

    // 地图 L1/L2 与两个套视野函数的**几何数据源**：只含航线身份 + 航点。
    /// ‼️ 为什么要跟 `_routeRows` 分开：`_routeRows` 额外带了 `active_count`/`has_abnormal`/`tasks`
    ///    （右栏列表要），**那几个字段吃 ③ 的任务轮询** ⇒ 任务状态一变，`_routeRows` 整体重建
    ///    ⇒ 地图上所有航线**销毁重建**（用户报「航线过几秒就抖一下」）。
    ///    地图要的只是几何，与 ③ 无关。这里再用**内容指纹**兜一层：几何没变就**保持原数组身份**
    ///    （`property var` 换身份会让 `MapItemView` 重建全部委托）。
    /// ⚠️ 所以本属性**必须由 `_rebuildRouteGeom()` 显式维护**，不要改成读 `_routeRows` 的绑定。
    property var    _routeGeom:    []
    property string _routeGeomKey: ""
    function _rebuildRouteGeom() {
        var g = []
        for (var i = 0; i < _routeOrder.length; i++) {
            var r = _routeCache[String(_routeOrder[i])]
            if (!r) continue
            g.push({
                route_id:   r.route_id,
                route_code: r.route_code,
                route_name: r.route_name,
                route_type: r.route_type,
                waypoints:  Array.isArray(r.waypoints) ? r.waypoints : []
            })
        }
        // ⚠️ 指纹**不能**用 `JSON.stringify(g, ["route_id","waypoints"])` 那种 replacer 数组：
        //    它会把**嵌套**对象的键也一并过滤掉 ⇒ 航点内容被排除在指纹外 ⇒ 航点变了却不重绘。
        var key = JSON.stringify(g)
        if (key === _routeGeomKey) return
        _routeGeomKey = key
        _routeGeom    = g
    }
    // 套视野时包围盒占**可见区**的比例（余下的是边距）。⚠️ 不能取 1.0：`setVisibleRegion`
    // 的实际落点与按公式算的不完全一致（见 `_applyBounds` 的迭代说明），贴边算出来的结果
    // 会有一两成概率**越界几个像素**，而用户看到的正是「航线超过当前视口」。
    readonly property real _fitPad: 0.94

    // 「待套视野」标志。**不要**在数据回来时直接套——那是在跟布局抢时间。
    // ‼️ 真正读 `opsMap.width`/`height` 的是 `_applyBounds`（**不是** `_fitRoutesToViewport`——
    //    它只做 `routeBounds` + 转调）。可用区＝整图**减去**右侧面板宽与上下两条横条，是**减法**
    //    （`w - panelW`），**不是**任何比例系数（这里原先写作"右栏内缩系数 `w/(w−340)`"，
    //    代码里没有这个式子）。数据（本地回环 HTTP，常在个位数毫秒）**几乎必然早于**布局
    //    （下一个渲染帧，~16ms）到达。
    //    此时 `width == 0` ⇒ 可用区退化成空/负，且 `setVisibleRegion` 会算出一个**无意义的 zoom**
    //    被回读进 `_routeFitZoom`——而 `zoomLevel` 绑定一旦看到 `_routeFitZoom > 0` 就**永久接管**，
    //    **没有任何重试路径**，地图就此停在错的比例尺上（用户报障「没有自动缩放显示所有航线」）。
    //    ⇒ 数据回来只**置标志**，真正套视野等 `opsMap.width > 0` 时由 `onWidthChanged` 执行。
    property bool  _routeFitPending: false
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
        id: pollTimer
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
    // ① 失败后的重试（§7.2：自动重试 3 次、间隔 2s）。一次性，由 `_fetchMyRoutes` 重启。
    Timer {
        id: routeRetryTimer
        interval: 2000; repeat: false
        onTriggered: _fetchMyRoutes(function(ok) {
            // ‼️ 收尾必须走 `_onRoutesReady()`。这条路原先自己写了一遍收尾序列，且**漏了
            //    `_requestRoutesFit()`** ⇒「登录时 ① 抖了一次、重试成功」的结果是：右栏有数据、
            //    地图却停在 `flightMapInitialZoom`(17) 俯视**出厂默认的苏黎世**，一条航线都看不到。
            //    而"① 失败一次"正是这个重试机制**唯一**的存在理由，所以这不是边角情形。
            if (ok) _fetchMyRouteWaypoints(function() { _onRoutesReady() })
        })
    }

    // §7.2 首拉：`visible` 变 true 时**立即**跑一次，不等 Timer 满 2s。
    onVisibleChanged: if (visible && AuthController.loggedIn) _bootstrap()
    // 退出登录清空航线缓存（§2.2）。**不在这里重拉**——重新登录会让本项重新可见，走 `onVisibleChanged`。
    Connections {
        target: AuthController
        function onLoggedInChanged() {
            if (!AuthController.loggedIn) {
                opsShell._routeCache = ({}); opsShell._routeOrder = []
                opsShell._routeTasks = [];   opsShell._routeDevices = []
                opsShell._routeCacheReady = false; opsShell._selectedRouteId = null
                opsShell._routeLoadError = "";     opsShell._routeTasksStale = false
                // 几何与两个内容指纹一并清空：留着旧指纹会让下次登录的**第一发** ③ 被
                // "内容没变"误判成空转（`_routeTasks` 还停在登出时置的 `[]`，界面空白到第二发）。
                opsShell._routeGeom = [];          opsShell._routeGeomKey = ""
                opsShell._routeTasksJson = "";     opsShell._routeDevicesJson = ""
                // 视野状态一并清空。‼️ `_mapManualCenter` 必须清——它**优先级高于** `_routeFitCenter`
                // （见 `center` 绑定），一旦在上一个会话里被平移/点选置上而这里不清，下次登录
                // `_fitRoutesToViewport()` 把 **zoom 套对了、中心却被旧的手动位置压住** ⇒ 航线在
                // 视野外 ⇒ 屏幕上什么都没有，且不报错、日志无声。
                opsShell._mapManualCenter = null;  opsShell._mapFollowFirst = true
                opsShell._routeFitCenter = null;   opsShell._routeFitZoom = 0
                opsShell._routeFitPending = false
                // 本站坐标一并清：它是套视野的中心锚点，且在 `center` 的兜底链里**排在
                // `_routeFitCenter` 之后**（见 `center` 绑定）。留着上一个站点的坐标，会让下一个
                // 账号登录的瞬间把地图摆在**别人的站点**上，直到自己的坐标回来才纠正——
                // 画面跳一下，且跳的方向是错的。
                // ⚠️ `_mySiteId` 不用清：它是 `AuthController.siteId` 的**绑定**，登出自动失效。
                opsShell._mySiteCoord = null
                // ‼️ `_bootstrapping` 也必须清。它的复位只写在 `_bootstrap()` 自己的回调里，
                //    而首拉的 ① 是**可以整个回调都到不了**的（② 的重试余额用尽时提前 return、
                //    `_send` 在地址未配置时静默 return、登出发生在请求在途时）。
                //    一旦卡在 true，`_bootstrap()` 从此被 `if (_bootstrapping) return` 挡死，
                //    登出再登录也不恢复 ⇒ 右栏上段永久「航线加载中…」。
                opsShell._bootstrapping = false
            }
        }
    }

    //-------------------------------------------------------------------------
    // 网络层：XHR + Bearer（仿 PlanUploader 的 Bearer 鉴权方式）
    //-------------------------------------------------------------------------
    function _send(method, path, body, onDone) {
        if (_apiBase === "") {
            console.warn("OpsView: gcs_server 地址未配置")
            // ‼️ **必须**回调 `onDone`（状态码 0 = 根本没发出去）。静默 `return` 会让调用方的
            //    "失败"分支永不执行：`_fetchMyRoutes` 的重试计数不递减、错误条不置，
            //    而 `_bootstrap` 的 `_bootstrapping` 只在自己的回调里复位
            //    ⇒ 右栏上段**永久**停在「航线加载中…」，零提示、零日志，只能重启。
            if (onDone) onDone(0, null)
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

    /// 从 `_tasks` 抽出地图航线要用的**纯几何**（任务身份 + 航点）。遥测不进指纹。
    /// ‼️ 这是 `_tasks` 之上的**第二层**守卫，两层管的不是一回事：
    ///    · `_tasksJson`（`_fetchOverview` 里）吃掉"整条载荷都没变"的空转，护的是 marker + 列表；
    ///    · 本函数吃掉"航点没变、只是飞机动了"，护的是**航线**——否则飞机在飞时每 2s 白重建一次。
    /// ⚠️ 指纹**不能**用 `JSON.stringify(g, ["task_id","waypoints"])` 那种 replacer 数组：
    ///    它会把**嵌套**对象的键也一并过滤掉 ⇒ 航点内容被排除在指纹外 ⇒ **航点变了却不重绘**。
    ///    （同 `_rebuildRouteGeom` 的既有教训，那边踩过一次。）
    /// 返回**几何是否真的变了**（`true` = 换了数组身份）。调用方据它决定要不要重套视野：
    /// 飞机在动只改 `_tasks[i].latest`、不动 `waypoints` ⇒ 指纹不变 ⇒ **不抢用户视野**。
    function _rebuildTaskGeom() {
        var g = []
        for (var i = 0; i < _tasks.length; i++) {
            var t = _tasks[i]
            g.push({
                task_id:   t.task_id,
                route_id:  t.route_id,
                waypoints: Array.isArray(t.waypoints) ? t.waypoints : []
            })
        }
        var key = JSON.stringify(g)
        if (key === _taskGeomKey) return false
        _taskGeomKey = key
        _taskGeom    = g
        return true
    }

    //---- 接口封装 ----
    function _fetchOverview() {
        _get("/api/ops/overview?view=" + opsShell.overviewView, function(status, data) {
            if (status !== 200 || !Array.isArray(data)) { console.warn("OpsView overview", status); return }
            // ‼️ **内容没变就不要重新赋值**（理由同 `_fetchRouteTasks`）。`property var` 一旦换身份，
            //    吃 `_tasks` 的 `MapItemView`（飞机 marker）与右栏列表都会销毁重建全部委托。
            //    实测（改动前）：载荷**逐字节相同**时，4 条航线仍每轮新建 4 个，累计 4→8→12→… 无休止。
            //    判据取 delegate 自身的 `Component.onCompleted/onDestruction` 计数，**不是对象指针**
            //    ——销毁后新建可能拿到同一块地址，指针相同会假绿。
            //    ⚠️ 这一层**挡不住遥测**（`data` 带 `latest`，飞机一动就变），航线的空转由
            //       `_rebuildTaskGeom()` 那一层挡。两层都要，少一层都不完整。
            var json = JSON.stringify(data)
            if (json !== _tasksJson) {
                _tasksJson = json
                _tasks     = data
                // ‼️ 几何**真的变了**才重套视野（返回 false = 只是遥测在动，飞机位置变了而航点没变）。
                //    站点视图每 2s 轮询一次，若无条件重套，`_applyBounds` 里的 `_mapManualCenter = null`
                //    会**每 2 秒抢走用户的地图视野**——用户永远没法把地图拖到别处看。
                //    这与 `refreshRoutes` 的既有语义一致：「只在航线集合真的变了时重置视野」。
                if (_rebuildTaskGeom() && !routeLayersEnabled) _requestRoutesFit()
            }
            _updateMockVehicle()
            // 本站站点 id 由 AuthController.siteId（登录 role_sites 单值）提供，不再从任务 data[i].site_id 反推。
        })
    }

    /// 本站站点坐标（`GET /api/sites/:id`）。**站点视图套视野的中心锚点**，只取一次。
    /// ‼️ 站点表本身不存坐标（见 `_mySiteCoord` 声明处），坐标由后端 JOIN 航点后下发。
    /// ⚠️ 拿不到时**保持 `null` 并照常套视野**——退化路径是"居包围盒中心"（`_applyBounds` 的
    ///    `centerOn` 缺省行为），与监控员视图逐字一致。**不要**在这里 `return` 掉整个套视野：
    ///    那会让"本站没挂航点"变成一个空白地图，而它本该只是一个不那么理想的视野。
    function _fetchMySite() {
        var sid = Number(_mySiteId)
        // 无站点身份（平台级账号 / role_sites 为空）⇒ 不请求。`/api/sites/0` 会 404，
        // 而在控制台里打一行无意义的 warning 只会让真正的故障更难看见。
        if (!(sid > 0)) return false
        _get("/api/sites/" + sid, function(status, data) {
            if (status !== 200 || !data) { console.warn("OpsView 本站站点", status); return }
            var la = Number(data.lat), lo = Number(data.lon)
            // 口径与 `OpsCommon.isValidWaypoint` **逐字一致**：两轴有限，且**任一轴为 0 即无效**。
            // 后端对没挂航点的站点给的是 `COALESCE(w.lat, 0)` ⇒ 正好是 0，被这里挡住 ✓。
            if (!OpsCommon.isValidWaypoint(la, lo)) return
            _mySiteCoord = QtPositioning.coordinate(la, lo)
            // 坐标是套视野的**输入**（`centerOn`），可能比首帧晚到 ⇒ 到了要重套一次。
            // ‼️ 只在**站点视图**重套：监控员视图的视野与本站坐标无关，重套会平白抢走用户
            //    正在看的局部（`_applyBounds` 会清 `_mapManualCenter`）。
            // ‼️ 一条航线都没有时不套：`routeBounds` 会返回 null、套不出东西，此时地图中心
            //    由 `center` 绑定链里的 `_mySiteCoord` 兜底给出（那条路不需要套视野）。
            if (!routeLayersEnabled && _taskGeom.length > 0) _requestRoutesFit()
        })
        return true
    }

    /// 圆心处**每像素多少米**（返回 `NaN` = 地图未就绪 / 该坐标投影不出来）。
    /// 给机位范围圈的「最小可见尺寸」把像素下限换算成米用。
    ///
    /// ‼️ `zoom`/`ready`/`w`/`h` 四个参数**存在的唯一理由是让调用点的绑定注册依赖**：
    ///    QML 里**方法调用不注册绑定依赖**，函数体内读属性一律不算数（本文件头与
    ///    `OpsCommon.js` 头部（`.pragma library` 那段）都有记录，`rightPanelWidth` 那条链
    ///    就是靠实参传递绕开的）。
    ///    所以依赖必须由调用方在**实参位置**读完再传进来——把 `opsMap.zoomLevel` 从
    ///    实参里删掉，圆圈就再也不会随缩放更新，而且**不会报任何错**。
    ///
    /// ⚠️ 用「圆心右移 1 像素再量距离」而不是自己按 zoom 推公式：实际投影由地图插件决定
    ///    （`FlightMap` 的插件是可换的），推公式会和真实渲染对不上。
    function _metersPerPixelAt(coord, zoom, ready, w, h) {
        if (!coord || !ready || !(w > 0) || !(h > 0)) return NaN
        // `zoom` 不参与换算，只用来注册依赖（见上）。恒假判断会让人以为漏传了参数，
        // 这里用一个**语义上也成立**的检查：zoom 不是有限数说明地图状态本身就不正常。
        if (!isFinite(Number(zoom))) return NaN
        var p = opsMap.fromCoordinate(coord, false)
        if (!p || !isFinite(p.x) || !isFinite(p.y)) return NaN
        var right = opsMap.toCoordinate(Qt.point(p.x + 1, p.y), false)
        if (!right || !right.isValid) return NaN
        return coord.distanceTo(right)
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
    //---- 航线缓存（设计文档 §1.2/§1.3/§1.4；仅 `routeLayersEnabled` 时调用）----
    /// ① 全部负责航线。**失败不清空已成功的缓存**（§2.2：刷新时保留旧值直到新值到手）。
    /// 自动重试 3 次、间隔 2s（§7.2）；三次都失败才置错误条。
    function _fetchMyRoutes(onDone) {
        _get("/api/ops/my-routes", function(status, data) {
            if (status !== 200 || !Array.isArray(data)) {
                console.warn("OpsShell my-routes", status)
                if (_routeRetryLeft > 0) {
                    _routeRetryLeft--
                    routeRetryTimer.restart()
                    // ‼️ 这次尝试是"交给重试"、不是"最终失败"，但**仍然要回调**：
                    //    调用方（`_bootstrap`）的收尾只写在回调里，不回调就永远不复位
                    //    `_bootstrapping`（此后 `_bootstrap()` 全被挡死）。重试本身由
                    //    `routeRetryTimer` 继续，与本回调无关。
                    if (onDone) onDone(false)
                    return
                }
                // §7.3 的菜单项已补上（`toolbar_refreshRoutes`）⇒ 文案改为指向它。
                // ‼️ 当初绕开它的理由——"提示指向一个找不到的入口，比不给提示更糟：用户会先
                //    去找、再怀疑自己找错了"——随菜单项落地而消失。而不改回来则是相反的错误：
                //    入口**存在**却没有任何地方告诉用户，等于白做。
                _routeLoadError = qsTr("负责航线加载失败，点菜单「刷新航线与航点」重试")
                if (onDone) onDone(false)
                return
            }
            _routeLoadError = ""
            // ‼️ 整体**重建**两个对象（不是原地改），否则绑定不重估（见 `_routeRows` 上方注释）。
            // ‼️ 键一律 `String(route_id)`：JSON 对象的键恒为字符串，`_routeCache[12]` 与
            //    `_routeCache["12"]` 是同一个键，但**读的地方**必须一致地写 `String(...)`，
            //    否则 `_routeCache[id]`（id 来自响应，可能是数字）看着对、实际也对，
            //    却会让人以为可以混用——真混进一处 `Object.keys` 比较就会静默不匹配。
            var cache = {}, order = []
            for (var i = 0; i < data.length; i++) {
                var r = data[i]
                // ‼️ 航点**继承旧值**，**不要**写成 `waypoints: []`。① 回来时 ② 还没发，
                //    置空的话 —— ② 一旦失败（`_fetchMyRouteWaypoints` 的失败分支**不动缓存**，
                //    因为它没有旧航点可保留）—— `_routeCache` 就永久停在"有航线、无航点"：
                //    右栏照常列出航线与活跃数，**地图上折线全部消失**，而 ② 没有周期性重取，
                //    不会自愈。这正是 §2.2 那句「刷新时保留旧值直到新值到手」要挡的情形。
                var prev = _routeCache[String(r.route_id)]
                cache[String(r.route_id)] = {
                    route_id: r.route_id, route_code: r.route_code, route_name: r.route_name,
                    route_type: r.route_type,
                    waypoints: (prev && Array.isArray(prev.waypoints)) ? prev.waypoints : []
                }
                order.push(r.route_id)
            }
            _routeCache = cache
            _routeOrder = order
            _rebuildRouteGeom()
            if (onDone) onDone(true)
        })
    }

    /// ② 全部负责航线的航点，**一次拿回**（返回以**字符串** route_id 为键的对象）。
    /// 单条航线没航点时后端给 `[]` ⇒ 这里再兜一层 `Array.isArray`，让 `waypoints` 恒为数组。
    function _fetchMyRouteWaypoints(onDone) {
        _get("/api/ops/my-routes/waypoints", function(status, data) {
            if (status !== 200 || !data || typeof data !== "object" || Array.isArray(data)) {
                console.warn("OpsShell my-routes/waypoints", status)
                // 同 `_fetchMyRoutes`：指向 §7.3 的菜单项（§7.2 的原文即要求这句文案）。
                _routeLoadError = qsTr("航点加载失败，点菜单「刷新航线与航点」重试")
                if (onDone) onDone(false)
                return
            }
            var cache = {}
            for (var i = 0; i < _routeOrder.length; i++) {
                var k = String(_routeOrder[i])
                var r = _routeCache[k]
                if (!r) continue
                var wps = data[k]
                cache[k] = {
                    route_id: r.route_id, route_code: r.route_code, route_name: r.route_name,
                    route_type: r.route_type, waypoints: Array.isArray(wps) ? wps : []
                }
            }
            _routeCache = cache
            _rebuildRouteGeom()
            if (onDone) onDone(true)
        })
    }

    /// ③ 2s 轮询。**失败不动缓存**（§2.2：地图上飞机消失会被误读成"飞机没了"，陈旧好过空白），
    /// 只把 `_routeTasksStale` 置起来给故障提示条用（§2.4）。
    function _fetchRouteTasks() {
        _get("/api/ops/route-tasks", function(status, data) {
            if (status !== 200 || !data || !Array.isArray(data.devices) || !Array.isArray(data.tasks)) {
                console.warn("OpsShell route-tasks", status)
                _routeTasksStale = true
                return
            }
            // ‼️ **内容没变就不要重新赋值**（两个都一样）。`property var` 一旦换身份：
            //    `_routeRows` 整体重建 ⇒ 右栏列表重建委托（`ListView` 可能连带重置滚动位置），
            //    地图 L3 的飞机 marker 也会销毁重建。**每 2s 无条件重建是画面抖动的根源。**
            //    实测（改动前）：载荷 1137 字节**逐字节相同**时，L1 委托仍每轮新建 4 个
            //    （= 航线条数）、累计 4→8→12→… 无休止。
            //    地图 L1/L2 另有 `_routeGeom` 兜底（不吃任务状态），这里管的是任务/飞机状态本身。
            var tJson = JSON.stringify(data.tasks)
            var tChanged = tJson !== _routeTasksJson
            if (tChanged) {
                _routeTasksJson = tJson
                _routeTasks     = data.tasks
            }
            // ⚠️ 飞机**要**随遥测动：位置一变指纹就变，照常赋值。守卫只吃掉"什么都没变"的空转。
            var dJson = JSON.stringify(data.devices)
            var dChanged = dJson !== _routeDevicesJson
            if (dChanged) {
                _routeDevicesJson = dJson
                _routeDevices     = data.devices
            }
            _routeFrameTimeoutMs = (typeof data.frame_timeout_ms === "number" && data.frame_timeout_ms > 0)
                                   ? data.frame_timeout_ms : 3000
            _routeUpdatedAt = new Date()
            _routeTasksStale = false
            opsShell.routeTasksUpdated()
        })
    }

    /// §7.2 首拉序列：① → ② → `_routeCacheReady` → ③ 的第一发。**不等 Timer 满 2s**
    /// （`running` 变 true 只是启动计时器，首次触发仍要等满一个周期 ⇒ 登录后最多 2s 空白）。
    /// ‼️ `_poll()` 必须在 `_routeCacheReady = true` **之后**：右栏上段要有内容。
    /// ⚠️ 站点视图也走这里（原先是 `!routeLayersEnabled` 直接返回），但只跑 `_fetchMySite()`
    ///    那一步：①② 是监控员视图的**航线缓存**，站点视图的几何来自 `overview?view=site`
    ///    （`_taskGeom`）——两套数据源不相干，站点视图不需要也不该付 ①② 的代价。
    function _bootstrap() {
        if (_bootstrapping) return
        _bootstrapping = true
        // 站点视图：唯一的输入是本站坐标；套视野由 `_fetchMySite` 的回调触发。
        // ‼️ 两条分支都必须复位 `_bootstrapping`——卡在 true 会让 `_bootstrap` 从此被挡死，
        //    登出再登录也不恢复（详见登出处那条长注释）。
        if (!routeLayersEnabled) {
            _fetchMySite()
            _bootstrapping = false
            return
        }
        _routeRetryLeft = 3
        _fetchMyRoutes(function(ok) {
            // ⚠️ 失败时**不** `pollTimer.restart()`：`running` 是绑定
            //    （`opsShell.visible && AuthController.loggedIn`），而 `restart()` 会写 `running`
            //    ⇒ **打断绑定**，此后登出/切视图都停不下这个 2s 轮询（且不报错）。
            //    这里本来也不需要它——间隔已经由定时器自己走，下一次触发在 2s 后。
            if (!ok) { _bootstrapping = false; return }
            _fetchMyRouteWaypoints(function() {
                _onRoutesReady()
                _bootstrapping = false
            })
        })
    }

    /// ② 成功之后的收尾 —— **两条到达路径共用**（首拉 `_bootstrap` 与 ① 的自动重试）。
    /// 抽出来的理由不是 DRY 洁癖：重试那条路原先自己抄了一遍收尾序列，**漏了
    /// `_requestRoutesFit()`**，于是"登录时 ① 抖一次、重试成功"的结果是右栏有数据、
    /// 地图却停在出厂默认视野上（详见 `routeRetryTimer` 处）。
    function _onRoutesReady() {
        _routeCacheReady = true
        // 首拉**立刻**发一次，不等 Timer 满 2s（`running` 变 true 只是启动计时器，
        // 首次触发仍要等满一个周期 ⇒ 登录后最多 2s 空白）。
        _poll()
        // §7.4：拿到航点后把视野套到全部航线上。
        // ‼️ 这一步不是"锦上添花"，是**没有它地图上就看不到航线**：监控员视图的
        //    `_tasks`（`overview?view=route`）实测恒 0 行 ⇒ `_firstTaskCoord()` 恒 null、
        //    `zoomLevel` 落到 `flightMapInitialZoom`（=17.0，硬编码）⇒ 地图停在
        //    `QGroundControl.flightMapPosition`（本机 ini 里是**出厂默认的苏黎世**）
        //    以 17 级（视口约 1km）俯视，而航线在北京/上海。
        // ⚠️ 走 `_requestRoutesFit()` 而**不是**直接 `_fitRoutesToViewport()`：后者要读
        //    `opsMap.width`，而数据（本地回环，毫秒级）几乎必然早于布局（下一帧）到达。
        _requestRoutesFit()
    }

    /// 「刷新航线与航点」（§7.3）：重拉 ①②，**保留旧缓存直到成功**。返回是否真的变了。
    function refreshRoutes(onDone) {
        _routeRetryLeft = 3
        var before = _routeOrder.join(",")
        _fetchMyRoutes(function(ok) {
            if (!ok) { if (onDone) onDone(false); return }
            _fetchMyRouteWaypoints(function() {
                _routeCacheReady = true
                var changed = before !== _routeOrder.join(",")
                // §7.3：**只在航线集合真的变了**时重置视野——用户此刻可能正在看某个局部，
                // 每次刷新都强制复位是**抢走控制权**。
                if (changed) _requestRoutesFit()
                if (onDone) onDone(changed)
            })
        })
    }

    /// 请求「把视野套到全部航线」。**数据回来时调它，不要直接调 `_fitRoutesToViewport()`。**
    /// 布局已给出尺寸就立刻套；否则置 `_routeFitPending`，等 `opsMap` 的 `onWidthChanged` 补套。
    function _requestRoutesFit() {
        if (opsMap.width > 0 && opsMap.height > 0) {
            _routeFitPending = false
            _fitRoutesToViewport(_fitRows(), _fitCenterOn())
        } else {
            _routeFitPending = true
        }
    }

    /// 套视野的**几何数据源**。两个视图各吃各的，形状相同（`{waypoints:[{lat,lon}]}`）
    /// ⇒ `OpsCommon.routeBounds` 两边共用，不必分家。
    /// ‼️ **必须分开、不能合并成一个数组**：站点视图的 `_routeGeom` 恒为空（它不跑 ①②），
    ///    监控员视图的 `_taskGeom` 也恒为空（`overview?view=route` 实测 0 行）⇒ 取错一个
    ///    的结果是「什么都套不出来」，而 `routeBounds` 返回 null 是**合法的静默路径**
    ///    （§7.4 退化情形 2），屏幕上不会有任何提示。
    function _fitRows() {
        return routeLayersEnabled ? opsShell._routeGeom : opsShell._taskGeom
    }

    /// 套视野的**中心锚点**：站点视图钉在本站（用户诉求「地图中心设置为当前登陆站点」），
    /// 监控员视图给 `null`（= 居包围盒中心，既有行为，一字不改）。
    /// ⚠️ 站点坐标还没到（或本站没挂航点）时 `_mySiteCoord` 是 `null` ⇒ 自动退化成居中，
    ///    与监控员视图同一条路径，**不会**套出空视野。
    function _fitCenterOn() {
        return routeLayersEnabled ? null : _mySiteCoord
    }

    /// §7.4 视野：把可见区域套到**全部负责航线**上（用户诉求「比例尺要能够显示所有要显示的航线」）。
    /// 返回是否真的调了 `setVisibleRegion`。
    /// `rows` 缺省 = 监控员视图的全部负责航线；**两个视图都走这里**，各自的几何由 `_fitRows()` 给。
    /// `centerOn` = 中心锚点（站点视图给本站坐标，监控员视图给 `null`）——见 `_fitCenterOn`。
    ///
    /// 📌 **本条原是"只能由 `routeLayersEnabled` 的视图调用"，2026-09-23 撤销。** 原文那两条理由
    ///    都随需求变更失效了。留档的理由：下一个人会**再次**生出"站点视图不该套视野"的直觉，
    ///    而当时的直觉是有依据的——要知道依据是怎么没的，才不会把它当噪音删掉又重建一遍：
    ///    ① 「它会写 `_routeFitCenter`/`_routeFitZoom`，在 `center`/`zoomLevel` 的优先级链里插进
    ///       站点视图不该有的语义」——用户现在**要**的正是这套语义。`center` 原先跟随首个任务
    ///       （飞机实时位置），需求「地图中心设置为当前登陆站点」把那条语义取代掉了；
    ///       而 `_routeFitZoom` 接管 `zoomLevel` 恰恰就是"按航线范围定比例尺"想要的效果。
    ///    ② 「站点视图的 `center` 靠 `_firstTaskCoord()` 跟随首个任务，套视野与那套语义互相干扰」
    ///       ——同上，两条语义不能共存，留下的是用户点名的那条（站点）。`center` 绑定里那个
    ///       分支现在**带 `routeLayersEnabled &&` 前缀**，站点视图根本走不到它。
    ///    ⚠️ 至于更早那句"`setVisibleRegion()` 会打断 `center`/`zoomLevel` 的绑定"——**它从来就是错的**
    ///       （那是 C++ 侧写 `_map.visibleRegion`，QML 绑定照旧活着；实测见 `_routeFitCenter` 声明处）。
    ///       本条曾同时存在三种互相矛盾的说法，现已统一到"不打断"这一条。
    ///
    /// ⚠️ 调用点必须在几何数据到位之后：航点没回来时每条航线的 `waypoints` 都是空数组 ⇒
    ///    `routeBounds` 返回 null ⇒ 这里直接返回、什么都不做（这正是 §7.4 退化情形 2 的要求）。
    /// ‼️ 站点视图的**触发闸在上游**（`_fetchOverview` 按几何指纹、`_fetchMySite` 按坐标到达），
    ///    本函数自己**不做**节流：每被调一次就真的重套视野、并清掉 `_mapManualCenter`。
    function _fitRoutesToViewport(rows, centerOn) {
        var b = OpsCommon.routeBounds(rows !== undefined ? rows : opsShell._routeGeom)
        // §7.4 退化情形 2：一条航线都没有（没被指派，或数据还没回来）⇒ **不要**调
        // `setVisibleRegion`——传空矩形进去的缩放结果不可预测。保持当前视野。
        if (b === null) return false
        return _applyBounds(b, centerOn)
    }

    /// 选中某条航线 ⇒ 套到**该条航线**的包围盒（用户诉求：「点击某航线，地图应该自动缩放以
    /// 最佳视图显示该航线」）。找不到该行（已从缓存消失）时**保持当前视野**，不套空矩形。
    function _fitRouteToViewport(routeId) {
        if (!routeLayersEnabled) return false
        if (routeId === null || routeId === undefined) return false
        var one = opsShell._routeGeom.filter(function(r) {
            return Number(r.route_id) === Number(routeId)
        })
        if (one.length === 0) return false
        var b = OpsCommon.routeBounds(one)
        if (b === null) return false
        return _applyBounds(b)
    }

    /// 包围盒 → 视口。**全部航线与单条航线共用这一条路径**（退化保护 + 遮挡内缩 + 落位），
    /// 所以「点航线」与「登录自动套」的几何行为必然一致，不会两处漂移。
    ///
    /// ‼️ `opsMap` 是 `anchors.fill` **满铺**的，而三块兄弟项**盖在它上面**：
    ///      · 顶部命令条 `commandBarWrap`        → 盖住上边 `toolbarHeight`
    ///      · 底部状态栏 `instrumentPanel`        → 盖住下边（左区宽，height 48）
    ///      · 右栏 `rightPanel`（从命令条下沿到底）→ 盖住右边 `rightPanelWidth`
    ///    ⇒ **可见区** = `[0, w−右栏宽] × [命令条高, h−状态栏高]`。既不是整张地图，
    ///    也不是只挖掉右边一块。历史教训（用户报「航线超过当前视口」）：只按右栏缩经度、
    ///    而且是**对称**放大＝把包围盒摆在**视口正中**，于是右边缘正好落在右栏下 `右栏宽/2`
    ///    处；纵向更是一点没让 ⇒ 航线北端压在命令条下、南端压在状态栏下。
    ///
    /// 做法：**用地图自己当量具 + 迭代收敛**，全程不做墨卡托换算（纬度方向像素↔度不是线性的，
    /// 按度数换算会在跨度大、纬度高的场景下差出可观的量）：
    ///   ① 先把包围盒原样套进去 —— 这一步只为**造出一个已知状态**当量具；
    ///   ② 用 `fromCoordinate` 量出包围盒此刻在屏幕上占多少像素、中心在哪；
    ///   ③ 反解出"包围盒要占可见区的 `_fitPad`"所需的**目标比例尺** σ（相对当前），把目标视口
    ///      换算成当前比例尺下的像素矩形（边长 `w/σ × h/σ`，中心由"包围盒中心要落在**可见区**
    ///      中心"反推），取两角 `toCoordinate` 成地理矩形后 `setVisibleRegion` 套上去；
    ///   ④ **回到 ② 再量一次**。`setVisibleRegion` 的实际落点与按公式算的并不完全相等（Qt 在
    ///      `fitViewportToGeoShape` 里对墨卡托包围盒另有取整/留白处理，实测偏差约 2%），一次
    ///      到位会在贴边处越界几像素。迭代把这点误差当**残差**消掉——实测（1741×971）跑满
    ///      3 轮后落在「高 789px / 可用 857px」，两轴都在界内且各留 30px 上下边距。
    /// ‼️ 全程**不直接赋** `center`/`zoomLevel`：那是 QML 赋值，会**打断**这两个绑定（两个视图都
    ///    靠绑定取回 `_routeFitCenter`/`_routeFitZoom`）。`setVisibleRegion` 是 C++ 侧写入，绑定照旧活着。
    ///
    /// 中心锚点 `centerOn`（可省）：站点视图传**本站坐标**，把本站钉在可见区中心；监控员视图
    ///    不传 ⇒ 居包围盒中心，与改动前**逐字等价**。比例尺随之改由"锚点到盒子的**最远**距离"
    ///    反解——锚点居中时它退化成原来的"半个盒宽"，两条路径共用同一式，不会各自漂移。
    function _applyBounds(b, centerOn) {
        var minLat = b.minLat, maxLat = b.maxLat, minLon = b.minLon, maxLon = b.maxLon

        // 中心锚点解析。⚠️ 锚点钉的是**可见区**中心，不是视口几何中心——右栏与上下两条横条
        //    盖住的那部分用户根本看不见，他说的"地图中心"就是他看得见的那块区域的中心。
        //    下面 `cx`/`cy` 那两处偏移正是为此而设。‼️ 因此 `_routeFitCenter` 回读出来的
        //    **视口**中心与本站坐标**不是同一个点**——那是**对的**，不要"顺手修正"成锚点坐标，
        //    那会让视口整体offset、航线被面板盖掉一截。
        var anchored = false, cA = null
        if (centerOn && isFinite(Number(centerOn.latitude)) && isFinite(Number(centerOn.longitude))) {
            cA = QtPositioning.coordinate(Number(centerOn.latitude), Number(centerOn.longitude))
            anchored = true
        }

        // §7.4 退化情形 1：包围盒零面积（全部航线退化成一个点）⇒ `setVisibleRegion` 会缩放到
        // **最大级别**（贴到地面），用户看到的是"点一下刷新地图突然掉下去了"。补最小跨度
        // 0.005° ≈ 500m，**对称**扩，中心不动。
        var minSpan = 0.005
        if (maxLat - minLat < minSpan) {
            var dLat = (minSpan - (maxLat - minLat)) / 2
            minLat -= dLat; maxLat += dLat
        }
        if (maxLon - minLon < minSpan) {
            var dLon = (minSpan - (maxLon - minLon)) / 2
            minLon -= dLon; maxLon += dLon
        }

        // 可见区尺寸。⚠️ 必须在**布局完成之后**算：`opsMap.width` 还是 0 时下面会算出 0 或
        // 负数，把跨度压成 0 ⇒ 又回到退化情形 1（`_requestRoutesFit()` 已经保证了这一点，
        // 这里只是兜底——它同时也是"尺寸没起来就别动地图"的最后一道闸）。
        var w = opsMap.width, h = opsMap.height
        var panelW = opsShell.rightPanelWidth
        var topH   = commandBarWrap.height
        var botH   = instrumentPanel.height
        var uw = w - panelW
        var uh = h - topH - botH
        if (!(w > 0 && h > 0 && uw > 1 && uh > 1)) return false

        // 角点顺序：`rectangle(topLeft, bottomRight)` ⇒ 左上 = (最大纬度, 最小经度)。
        // `opsMap` 是 `FlightMap`（它自己就是 `Map`），**必须**走它自己的 `setVisibleRegion`
        // 而不是直接写 `visibleRegion` 属性——那里面有一句"先设成退化矩形再设真值"的
        // Qt bug 绕行（`FlightMap.qml:32-41`，连设两次同一个 region 第二次不生效），
        // 还有 zoomLevel 上限 20 的钳位。
        var cTL = QtPositioning.coordinate(maxLat, minLon)
        var cBR = QtPositioning.coordinate(minLat, maxLon)

        // 套视野 ＝ 用户**明确要求重控视野**（登录 / 刷新 / 点选航线）⇒ 必须清掉手动中心。
        // ‼️ 不清的后果：`center` 绑定里 `_mapManualCenter` **排在 `_routeFitCenter` 前面**，
        //    而它一旦被 `onMapPanStart`（拖动地图）或点选 marker 置上就**再没人清**（登出原先
        //    也不清）⇒ 此后每次套视野都是 **zoom 套对了、中心被旧的手动位置压住** ⇒ 航线落在
        //    视野外 ⇒ 屏幕上什么都没有，**不报错、日志无声**。
        _mapManualCenter = null

        // ① 原样套一次，纯为**造出量具的起始状态**（下面的迭代会把它改掉）。
        opsMap.setVisibleRegion(QtPositioning.rectangle(cTL, cBR))

        // ②③④ 迭代（见函数头说明）。
        var applied = false
        for (var i = 0; i < 3; i++) {
            var p1 = opsMap.fromCoordinate(cTL, false)
            var p2 = opsMap.fromCoordinate(cBR, false)
            if (!p1 || !p2) break
            var bx0 = Math.min(p1.x, p2.x), bx1 = Math.max(p1.x, p2.x)
            var by0 = Math.min(p1.y, p2.y), by1 = Math.max(p1.y, p2.y)
            var bw = bx1 - bx0, bh = by1 - by0
            if (!isFinite(bw) || !isFinite(bh) || bw <= 0 || bh <= 0) break
            // 地图还没 `mapReady` 时 `fromCoordinate` 会给出与"装得下"无关的数字。① 刚把包围盒
            // 套满整张地图 ⇒ 此刻它两轴都不可能超过视口，明显超了就是量具坏了，宁可什么都不做。
            if (i === 0 && (bw > w * 1.01 || bh > h * 1.01)) return false

            // 视口该以哪个**像素点**为中心：有锚点用锚点，没有就用包围盒中心。
            // ⚠️ 锚点与盒子是在**同一个比例尺**下量出来的（都在 ① 造出的那个状态里）⇒ 可直接比。
            var cxp, cyp, halfW, halfH
            var pa = anchored ? opsMap.fromCoordinate(cA, false) : null
            if (pa && isFinite(pa.x) && isFinite(pa.y)) {
                cxp = pa.x; cyp = pa.y
                halfW = Math.max(pa.x - bx0, bx1 - pa.x)
                halfH = Math.max(pa.y - by0, by1 - pa.y)
            } else {
                // 锚点缺失、或 `fromCoordinate` 量不出 ⇒ 退回居包围盒中心，与改动前一致。
                cxp = (bx0 + bx1) / 2; cyp = (by0 + by1) / 2
                halfW = bw / 2;        halfH = bh / 2
            }
            if (!(halfW > 0) || !(halfH > 0)) break

            // 目标比例尺（相对**当前**）：两轴取更紧的那个，缩完恰好有一轴贴在 `_fitPad` 上。
            // ‼️ 分母是"中心点到盒子的**最远**横向（纵向）距离"，**不是**半个盒宽——锚点偏心时
            //    （本站挂在航线一端，很常见）按半盒宽算会让**远端那一侧出界**，正是用户报过的
            //    「航线超过当前视口」。锚点居中时 `halfW === bw/2` ⇒ 本式退化成原来那一式。
            var sig = Math.min(uw * _fitPad / (2 * halfW), uh * _fitPad / (2 * halfH))
            // 已达标（还需要放大/缩小的幅度可忽略）⇒ 不动地图，避免无谓的瓦片重取。
            if (Math.abs(sig - 1) < 0.02) break

            // 目标视口在当前比例尺下看，就是一块 `w/σ × h/σ` 的像素矩形；它的中心由"中心点
            // 要落在**可见区**中心"反推：屏幕坐标下 `screen(q) = (q − C)·σ + (w/2, h/2)`，
            // 令 `screen(中心点) = (uw/2, topH + uh/2)` 解出 C。无锚点时中心点就是包围盒中心，
            // 此时 `cxp = (bx0+bx1)/2`，与改动前的式子**逐字相同**。
            var vw = w / sig, vh = h / sig
            var cx = cxp + (panelW / 2) / sig
            var cy = cyp + ((botH - topH) / 2) / sig
            var tl = opsMap.toCoordinate(Qt.point(cx - vw / 2, cy - vh / 2), false)
            var br = opsMap.toCoordinate(Qt.point(cx + vw / 2, cy + vh / 2), false)
            if (!tl || !tl.isValid || !br || !br.isValid) break

            opsMap.setVisibleRegion(QtPositioning.rectangle(
                QtPositioning.coordinate(tl.latitude, tl.longitude),
                QtPositioning.coordinate(br.latitude, br.longitude)))
            applied = true
        }

        // 回读给 `center`/`zoomLevel` 的绑定优先取用（见声明处的长注释）：依赖一变绑定就重估，
        // 没有这两个值就会被拽回模板缺省比例尺。
        _routeFitCenter = opsMap.center
        _routeFitZoom   = opsMap.zoomLevel
        return applied
    }

    /// 选中航线（§4.3）。**再点已选中的那一行 = 取消选中**（toggle）。
    /// ⚠️ 用户没明说 toggle——但"再点一次还是选中"会让用户除了点别处找不到取消的办法。
    /// **这是设计决定，不是用户裁定**，若用户不同意改这一个函数即可。
    function selectRoute(routeId) {
        if (_selectedRouteId !== null && Number(_selectedRouteId) === Number(routeId)) {
            // 取消选中 ⇒ 回到**全部航线**视图（没有别的合理视图：此刻屏幕上只剩淡线）。
            // ⚠️ 回套**不在这里**做：三条取消路径（列表再点一次 / 点地图空白 / 点右栏空白）
            //    全部落在 `clearRouteSelection()` 里，那里是唯一落点。此前这里另调过一次
            //    `_requestRoutesFit()`，是"只有这条路回套"的历史遗留，已收拢。
            clearRouteSelection()
        } else {
            _selectedRouteId = routeId
            opsShell.routeSelected(_selectedRouteId)
            // 「点击某航线，地图自动缩放以最佳视图显示该航线」。航点未到/该行已消失时
            // `_fitRouteToViewport` 返回 false 并保持当前视野，不会把地图套成空矩形。
            _fitRouteToViewport(routeId)
        }
    }
    /// 「点击界面其他部分则取消航线选择」（裁定 ⑥）。落点是**已有的**、本来就要接收点击的
    /// 容器（地图 / 右栏背景），**不新增覆盖层**——铺满全屏的 MouseArea 会吃掉下层所有控件的
    /// 点击且**不报错**（`toast-eats-clicks-under-it` 那个坑的形状）。
    ///
    /// ‼️ 取消选中后**把视野套回全部负责航线**（用户 2026-09-23 裁定）：「取消以后……此时应该
    ///    让地图缩放到显示所有监控航线（如登录后进入的状态）」。三条取消路径共用本函数，
    ///    所以"列表里再点一次"与"点卡片外的屏幕"视野行为**必然一致**，不会两处漂移。
    /// ⚠️ 这一条**推翻**了本函数原先的一句判断：「地图空白处的点击……**不**回套——用户此刻
    ///    是在看地图，把视野拽走是抢控制权」。那句是**我加的**、不是用户裁定；用户看过实际
    ///    表现后明确要求回套，以本节为准。
    /// ⚠️ `_selectedRouteId === null` 时**直接返回、不回套**：那不是"取消"，是"本来就没选中"。
    ///    此时若也回套，用户每点一下地图（含拖完松手那次）都会被拽回全景，那才是真的抢控制权。
    function clearRouteSelection() {
        if (_selectedRouteId === null) return
        _selectedRouteId = null
        opsShell.routeSelected(null)
        // 与登录首拉（§7.4）走**同一条**路径 ⇒「取消后」与「刚进来」的几何结果必然相同。
        // 用 `_requestRoutesFit()` 而不是 `_fitRoutesToViewport()`：前者带"布局未就绪时补套"
        // （`_routeFitPending`），后者要直接读 `opsMap.width`。
        _requestRoutesFit()
    }

    // 只拉**两个视图共用**的两份数据；视图专属的请求（如机位）由视图自己连 `polled()`。
    // 顺序与拆分前一致：overview → pending → （视图的）机位。
    function _poll() {
        if (_apiBase === "") return
        _fetchOverview()
        _fetchPending()
        if (routeLayersEnabled) _fetchRouteTasks()
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
            var hid = OpsCommon.handoverId(h)
            if (_seenHandovers.indexOf(hid) >= 0) continue
            _seenHandovers.push(hid)
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
            // 优先级：用户手动平移 > §7.4 套出全部航线 > 本站坐标（站点视图）> 模板缺省。
            // 监控员视图的 `_tasks` 恒 0 行（`overview?view=route`），没有 §7.4 那一段它就会
            // 停在模板缺省（本机 = 出厂默认苏黎世）。见 `_routeFitCenter` 的声明处。
            // ⚠️ `zoomLevel` 去掉了 `routeLayersEnabled &&` 前缀：站点视图现在也用 §7.4 定比例尺
            //    （用户诉求「完整显示当前所有航线」）。没有它，站点视图会停在
            //    `_tasks.length ? 14 : 17` 这个**与航线范围无关**的固定值上。
            zoomLevel:                  _routeFitZoom > 0
                                        ? _routeFitZoom
                                        : (_tasks.length ? 14 : QGroundControl.flightMapInitialZoom)
            // ‼️ 首项「跟随首个任务」**加了** `routeLayersEnabled &&` 前缀，不是顺手加的：站点视图的
            //    center 现在由 §7.4 钉在本站（用户诉求「地图中心设置为当前登陆站点」），而
            //    `_firstTaskCoord()` 给的是**飞机实时位置**——两条语义不能共存，留下的是用户点名
            //    的那条。加前缀而不是删掉整个分支，是为了让监控员视图**逐字不变**：它 `_tasks`
            //    恒 0 行、这分支从未生效过，但"从未生效"是**实测结论不是结构保证**，不能拿它当
            //    删除的理由（哪天 `view=route` 有数据了，行为就变了）。
            center:                     routeLayersEnabled && _mapFollowFirst && _firstTaskCoord() !== null
                                        ? _firstTaskCoord()
                                        : (_mapManualCenter !== null
                                           ? _mapManualCenter
                                           : (_routeFitCenter !== null
                                              ? _routeFitCenter
                                              // 站点视图在**一条航线都没有**（套不出视野）时的落点：
                                              // 中心仍是本站，只是比例尺走上面那条与范围无关的固定值。
                                              : (_mySiteCoord !== null
                                                 ? _mySiteCoord
                                                 : (QGroundControl.flightMapPosition.isValid
                                                    ? QGroundControl.flightMapPosition
                                                    : QtPositioning.coordinate(31.2, 121.5)))))
            // 用户平移地图：先冻结当前中心（此时仍=跟随值，无跳变）再退出跟随，
            // 顺序不可颠倒（先退跟随会回落到 GCS 位置兜底，画面跳变）。
            onMapPanStart: { _mapManualCenter = opsMap.center; _mapFollowFirst = false }
            onMapPanStop:  { _mapManualCenter = opsMap.center }
            // 数据早于布局到达时的补套（见 `_routeFitPending` 的长注释）。两个方向都挂：
            // 布局可能先给宽后给高，只挂一个会漏。
            onWidthChanged:  if (_routeFitPending) _requestRoutesFit()
            onHeightChanged: if (_routeFitPending) _requestRoutesFit()

            // 本站机位范围圈 —— **站点视图**用。
            // 用户 2026-09-23：「在当前登陆站点显示一个能够圈进所有机位范围的圆圈」，
            // 同日改口径：「改为以站点坐标为中心，圈住各个机位，圆圈用虚线」。
            // ‼️ 声明在**航线之前**：QML 里先声明的 item 在地图**下层**。它是背景性的范围
            //    提示，压住航线或飞机 marker 就成了干扰。
            // ‼️ 为什么不是 `MapCircle`（QGC 有 4 处裸先例，属性写法也对得上）：QtLocation 的
            //    `MapCircle` 边框**只有** width/color，**没有任何虚线能力**
            //    （`grep -i dash .../QtLocation/plugins.qmltypes` 返回空）⇒ 做不出要的虚线。
            //    唯一可行路径是 `MapQuickItem` + `Shape`：虚线 = `ShapePath.DashLine` +
            //    `dashPattern`（先例：同目录 `SlotLayout.qml` 的机位卡空心虚线，但在**地图里**
            //    没有先例，故另开探针实测过类型与属性名）。
            // ‼️ 代价：`sourceItem` 是**屏幕像素**空间，半径得自己除以米/像素 —— 这恰好与
            //    「最小像素尺寸」是同一件事，两者合并进 `_slotRangeDiaPx` 一次算完。
            //    ⇒ 圆随缩放**重估**靠的是那条绑定的依赖注册，不再是 MapCircle 的 `radius`。
            // ⚠️ 它不是 `MapItemView`：单个 item（不是 model 驱动），没有"委托整体重建"那类
            //    抖动；但 `coordinate` / 尺寸仍是绑定，同样靠 `_slotRangeCircle` 的**身份稳定**
            //    （视图侧按几何指纹维护）来避免每 2s 重算。
            MapQuickItem {
                objectName: "slotRangeCircle"
                // ‼️ 三个条件缺一不可：`routeLayersEnabled` 是视图闸（监控员视图不显示范围圈）；
                //    `> 0` = 没有可画的圆（无数据 / 地图未就绪 / mpp 无效，见 `_slotRangeDiaPx`）；
                //    `<= 上界` = 大到没有信息量，**不画**（判读见 `_maxSlotCircleDiameterPx`）。
                //    上界那个条件同时还挡住了"几十万像素的 Shape"这条卡顿路径——`visible:false`
                //    的 item 不渲染，`sourceItem` 也就不会生成几何。
                visible: !opsShell.routeLayersEnabled
                         && opsShell._slotRangeDiaPx > 0
                         && opsShell._slotRangeDiaPx <= opsShell._maxSlotCircleDiameterPx
                coordinate: {
                    var c = opsShell._slotRangeCircle
                    return c ? QtPositioning.coordinate(c.lat, c.lon)
                             : QtPositioning.coordinate(0, 0)
                }
                // 圆心 = 站点 ⇒ 锚点取 `sourceItem` 的**正中心**。直径变了锚点必须跟着变，
                // 否则圆会偏心（此处是绑定，自动跟随）。
                anchorPoint: Qt.point(opsShell._slotRangeDiaPx / 2, opsShell._slotRangeDiaPx / 2)
                sourceItem: Shape {
                    width:  opsShell._slotRangeDiaPx
                    height: opsShell._slotRangeDiaPx
                    ShapePath {
                        // 用户 2026-09-23：「圆圈用虚线」。`DashLine` 是**唯一**能出虚线的枚举
                        //（`ShapePath` 只有 SolidLine / DashLine / 无描边三种）。
                        strokeStyle: ShapePath.DashLine
                        // ⚠️ 单位是**线宽倍数**不是像素（Qt 文档：pattern is specified in units
                        //    of the pen width）⇒ 配合下面的 strokeWidth: 2，实得 10 px 实 / 8 px 空。
                        //    改 strokeWidth 会连带改虚线密度，别把它当成两个独立的旋钮。
                        dashPattern: [5, 4]
                        strokeColor: "#ffd400"
                        strokeWidth: 2
                        // 空心圈：实心填充会盖住底图上的地形与航线。**别改成半透明填充**——
                        // 那在深色卫星底图上只会让圈与底图的对比度下降。
                        fillColor: "transparent"
                        PathAngleArc {
                            centerX: opsShell._slotRangeDiaPx / 2
                            centerY: opsShell._slotRangeDiaPx / 2
                            // `- 1` 给 2 px 线宽留半个线身，让描边整个落在 `sourceItem` 内
                            //（超出去的会被 item 边界裁掉）。`max(0, …)` 防直径极小时的负数。
                            radiusX: Math.max(0, opsShell._slotRangeDiaPx / 2 - 1)
                            radiusY: Math.max(0, opsShell._slotRangeDiaPx / 2 - 1)
                            startAngle: 0
                            sweepAngle: 360
                        }
                    }
                }
            }

            //-----------------------------------------------------------------
            // 轨迹线 —— 全部**已建链**载具各一条（**两个视图共用**，不加 `routeLayersEnabled` 闸）
            // ‼️ 数据源是 `QGroundControl.multiVehicleManager.vehicles`（**真实** MAVLink 载具），
            //    不是 `_tasks` / `_routeDevices`——那两个是后端 REST 的投影、按 2 s 轮询跳变；
            //    轨迹是**逐帧**的东西，只有载具侧的 `TrajectoryPoints` 有它。
            //    ⇒ 这也正是「OpsView 里飞机轨迹不出现」的根因：本文件此前**从未引用过**
            //      `trajectoryPoints`（全文件零引用）。
            // ‼️ `TrajectoryPoints` 是**纯内存、不落库**的（`Vehicle.h:155`，`CONSTANT` 属性），
            //    且**只在解锁(armed)期间记录**：`Vehicle::_updateArmed`（`Vehicle.cc:1230`）
            //    在转 armed 时 `start()`、转 disarmed 时 `stop()` ⇒ 未起飞的载具这条线天然是空的，
            //    **不要**在这里再加一道"是否在飞"的判据。抽稀也由它自己做
            //    （2 m / 1.5°，`TrajectoryPoints.h:40-41`）。
            // ‼️ 参照实现 = `src/FlyView/FlyViewMap.qml:239-260`（用户点名的那份，已在 FlyView
            //    实测通过）。与它的**唯一差别**：FlyView 只画**当前选中**载具一条
            //    （靠 `onActiveVehicleChanged` 换 `Connections.target`），这里按 model **展开成
            //    每条一架** ⇒ "换车时全量重取"那件事改由 `Component.onCompleted` /
            //    `on_TpsChanged` 承担（FlyView 那份由 `Connection` 的 target 变化承担）。
            //-----------------------------------------------------------------
            // ‼️ `MapItemView` 而非裸 `Repeater`——理由见 L1 上方的长注释：**晚于地图创建**的
            //    `MapPolyline` 不会被注册进地图（`path` 有值、`pathLength()` 正确、QML 零报错，
            //    就是一条线都不画）。
            MapItemView {
                model: QGroundControl.multiVehicleManager.vehicles
                delegate: MapPolyline {
                    id: trajLine
                    line.width: 3
                    line.color: OpsCommon.trajectoryColor(index)
                    z: QGroundControl.zOrderTrajectoryLines
                    // ‼️ `path` **故意不给绑定**（对照本文件里其它几个 `MapPolyline` 都是
                    //    `path: …` 绑定）：轨迹靠 `onPointAdded` **增量** `addCoordinate()` 追加，
                    //    而绑定会在下一次重估时把已追加的点**整体覆盖掉**。
                    //    FlyView 那份同样是命令式赋值（`FlyViewMap.qml:250`），也没有绑定。
                    path: []
                    // ‼️ 角色名是 **`object`** 不是 `modelData`：`vehicles` 是 `QmlObjectListModel`，
                    //    它有两个角色 ⇒ `modelData` 会是 `QVariantMap` 而非 `Vehicle`。
                    //    逐条理由见 `OpsView.qml:662-677`，以及下面 L3 marker 的同款注释。
                    readonly property var _tps: object ? object.trajectoryPoints : null
                    // 全量重取（`list()`：`TrajectoryPoints.h:18`）。`path` 无绑定 ⇒ 幂等，
                    // 重复调用无害，所以下面两条触发路径可以重叠。
                    function _reset() { path = _tps ? _tps.list() : [] }
                    // ‼️ 两条触发路径**都要**，缺一条就是个静默错误：
                    //    · `Component.onCompleted` 覆盖"**委托出生时**车上已有历史轨迹"
                    //      （委托随 `vehicles` 增删重建）；
                    //    · `on_TpsChanged` 覆盖"`object` **晚到**或被复用"——`QQmlDelegateModel`
                    //      会把销毁的委托回收再派给别的行，只写前者的话，被复用的那条线会
                    //      **停在上一架飞机的轨迹上**（而界面看起来完全正常）。
                    //    ⚠️ 处理器名是 `on_TpsChanged` 不是 `on_tpsChanged`（下划线后首字母大写）。
                    //       这不是照文档推的：同仓 `FlyViewMap.qml:33` 声明
                    //       `property var _activeVehicleCoordinate`、`:184` 用
                    //       `on_ActiveVehicleCoordinateChanged`，声明与处理器在同一文件里共存。
                    Component.onCompleted: _reset()
                    on_TpsChanged: _reset()
                    Connections {
                        target: trajLine._tps
                        // 三个信号与 `TrajectoryPoints.h:26-29` 一一对应。
                        function onPointAdded(coordinate) {
                            trajLine.addCoordinate(coordinate)
                        }
                        // `updateLastPoint` 改的是**最后一个点**（原地更新，抑制静止时的抖动）。
                        // ⚠️ 这里加了长度守卫，**不是**照抄 `FlyViewMap.qml:257` 的裸减法：
                        //    空数组时 `pathLength()-1` 是 -1，会不会崩只取决于 Qt 对越界的容忍度
                        //    ——不该把"Qt 恰好不崩"当成保证。
                        function onUpdateLastPoint(coordinate) {
                            if (trajLine.pathLength() > 0) {
                                trajLine.replaceCoordinate(trajLine.pathLength() - 1, coordinate)
                            }
                        }
                        function onPointsCleared() { trajLine.path = [] }
                    }
                }
            }

            // 航路（全部任务 waypoints 连线）——**站点视图**用。
            // 监控员视图改吃航线缓存（下面的 L1），此处置空数组即可：Repeater 的 model 为
            // 空时**不创建任何项**，没有"隐藏但仍在"的残留（`visible: false` 才会留下不可见项）。
            // ‼️ `MapItemView` 而非裸 `Repeater`——理由见 L1 上方的长注释。
            // ‼️ 吃 **`_taskGeom`** 而不是 `_tasks`：航线画的是航点，与 `latest` 遥测无关，
            //    而吃 `_tasks` 会让飞机每动一次就整条线销毁重建（每 2s）。`_taskGeom` 由
            //    `_rebuildTaskGeom()` 按**几何指纹**维护，航点不变就保持数组身份。
            //    ⚠️ 元素只有 `task_id`/`route_id`/`waypoints`——**没有 `latest`**，
            //       所以这里（以及今后往 delegate 里加的东西）不能引用任务的位置/状态；
            //       要位置/状态就用下面吃 `_tasks` 的那个 marker `MapItemView`。
            MapItemView {
                model: opsShell.routeLayersEnabled ? [] : _taskGeom
                delegate: MapPolyline {
                    line.width: 2
                    line.color: "#00bfff"
                    path: modelData.waypoints ? modelData.waypoints.map(
                              function(wp) { return QtPositioning.coordinate(wp.lat, wp.lon) }) : []
                }
            }

            // 无人机 marker —— **站点视图**用（吃 `overview` 的 task）
            // ‼️ `MapItemView` 而非裸 `Repeater`——理由见 L1 上方的长注释。
            MapItemView {
                model: opsShell.routeLayersEnabled ? [] : _tasks
                delegate: MapQuickItem {
                    // ‼️ 位置主源是**报文**，不是 `modelData.latest`（用户 2026-09-24 报障：
                    //    「飞机图标不会在 OpsView 中出现」）。`latest` 来自后端轮询的
                    //    `table_telemetry`（最多陈旧 2 s，且 `data_writer` 一旦停写就恒为旧值
                    //    甚至为 null）；载具坐标则是**逐帧**的 MAVLink 位置。
                    //    `OpsCommon.resolvePosition` 的次序就是"报文优先、REST 兜底"（§5.2）。
                    // ‼️ 下面两段与 L3（监控员视图）marker **逐条同构**，是同一处坑：
                    //    · `vehicles` 必须在**绑定表达式里**读一次当实参传进去（`.pragma library`
                    //      里函数体读属性**不注册绑定依赖**，见 `OpsCommon.js` 头部）；
                    //    · `vs.count` 那一读是**依赖注册**不是短路优化：`vehicles` 在
                    //      `MultiVehicleManager.h:22` 上是 `CONSTANT`，只读它这个绑定**永不重估**
                    //      ⇒ 载具建链后 marker 永远找不到 Vehicle，而界面看起来完全正常；
                    //    · `_veh.coordinate` 同理必须在**实参位置**读，否则 MAVLink 位置一变
                    //      这个绑定不重估，marker **永远停在第一帧**。
                    readonly property var _veh: {
                        var vs = QGroundControl.multiVehicleManager.vehicles
                        if (!vs || vs.count === 0) return null
                        return OpsCommon.matchDeviceToVehicle(modelData, vs)
                    }
                    readonly property var _pos: OpsCommon.resolvePosition(
                                                     modelData, _veh, _veh ? _veh.coordinate : null)
                    // 两处都没有位置 ⇒ **不画**（与 L3 同一判据：该机尚无遥测）
                    visible: _pos !== null
                    coordinate: _pos !== null
                                ? QtPositioning.coordinate(_pos.lat, _pos.lon)
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
                                // ‼️ 用 `_pos` 而不是 `modelData.latest`：上面那个判据下
                                //    **可能报文有位置而 REST 没有**（`latest` 为 null），
                                //    直接取 `.lat` 会抛 TypeError ⇒ 点击**静默失效**。
                                //    与 `visible` 同源，也保证"点得到的一定画得出来"。
                                if (_pos !== null) {
                                    _mapManualCenter = QtPositioning.coordinate(_pos.lat, _pos.lon)
                                }
                            }
                        }
                    }
                }
            }

            //-----------------------------------------------------------------
            // L1 航线（常驻，淡色） + L2 选中航线点亮 —— **监控员视图**用（设计文档 §5.1）
            // ‼️ 「常驻」= **不看该航线有没有航班**：集合来自 ① 的缓存，与 ③ 的轮询结果无关。
            //    一架飞机都没有的航线，这条淡线**照样画**（只是上段数字是 0）。
            //    **不要**用"有没有活跃飞机"去过滤它。
            // ‼️ L1/L2 是**同一层**的两态（线宽与颜色一起变）：两条 `MapItemView` 的 model
            //    **互斥**（`routeRowsDimmed()` / `routeRowsLit()`），任一时刻同一条航线只被
            //    画一次——所以不会在曲线段上露出旧线的边（那是"同一条画两遍"才会有的问题）。
            //-----------------------------------------------------------------
            // ‼️ **必须是 `MapItemView`，不能是裸 `Repeater`。**
            //    `Repeater` 的委托是在**地图创建之后**才由 model 填充的（`_routeGeom` 登录前恒空），
            //    这种"晚到"的 MapPolyline **不会被注册进地图**——`path` 有值、`path.length` 正确、
            //    **QML 零报错**，就是一条线都不画（实测 Qt 6.11.1 + QGC 地图插件：同一份 model，
            //    裸 Repeater 出 0 像素、`MapItemView` 出 7279 像素）。`MapItemView` 正是
            //    QtLocation 为此提供的组件，QGC 自己的 `MissionLineView.qml` 用的也是它。
            //    ⚠️ 这个坑**只在真实地图插件上显形**：用 `itemsoverlay` 插件写的离屏探针会**假绿**。
            // 【两态靠换 model，不靠改 `line.*` 绑定】
            //    `line` 是 `MapPolyline` 的 group property（CONSTANT），`line.width/color` 是它的
            //    子属性。两态（淡/亮）用两个**互斥的 model** 表达，选中变化时两个数组都重建 ⇒
            //    `MapItemView` 重建委托 ⇒ 新委托带着自己的颜色出生。这样两态不共享同一个委托实例，
            //    避免"改了宽度没改颜色"这类半更新。
            //
            // ‼️ **颜色必须选得够亮——这是本功能唯一真正踩过的坑。**
            //    深色卫星底图上，初版淡色 `#4a6fa5` 与底图的蓝灰色调几乎融在一起：实测线心与
            //    邻域底图的相对亮度比只有 **2.21**，肉眼判定为"地图上根本没画航线"（用户三次报障）。
            //    换 `#9fc4e8` 后比值 3.15（苏黎世底图）/ 4.70（华北深色底图）。**淡 ≠ 看不见**：
            //    调这个颜色时必须在真实底图上量对比度（线心亮度 vs 线旁底图亮度），别凭 RGB 直觉。
            //
            // ⚠️ **取证时的陷阱**：在 `QT_QPA_PLATFORM=vnc`（该插件不支持 OpenGL，Qt Quick 退回
            //    软件渲染）下，`MapPolyline.line.color` 的 **R 与 B 通道会被互换**——写 `#ff0000`
            //    渲染成纯蓝、写 `#4a6fa5` 渲染成暗橙褐。**同一份代码在 WSLg 的 GL 后端下颜色完全
            //    正确**（三条原色探针各 3830 px、零偏差）。所以在 VNC 下截图判色会得出"绑定被丢弃"
            //    这类**完全错误**的结论（本功能为此绕了一大圈）。
            //    ⇒ 判颜色一律在 GL 后端（用户实跑的环境）；VNC 只用于判布局/交互。
            MapItemView {
                model: opsShell.routeLayersEnabled ? opsShell.routeRowsDimmed() : []
                delegate: MapPolyline {
                    line.width: 3
                    line.color: "#9fc4e8"
                    path: opsShell.routePathOf(modelData.waypoints)
                }
            }
            MapItemView {
                model: opsShell.routeLayersEnabled ? opsShell.routeRowsLit() : []
                delegate: MapPolyline {
                    line.width: 5
                    line.color: "#00e5ff"
                    path: opsShell.routePathOf(modelData.waypoints)
                }
            }

            //-----------------------------------------------------------------
            // L3 航班 marker —— **监控员视图**用（设计文档 §5.1/§5.2/§5.3）
            // ‼️ 吃 ③ 的 **`devices[]`**（不是 `tasks[]`）：`latest`（位置与**航向**）、
            //    `event`（异常着色）、`task_id`（关联出航班）、`route_id`（选中淡化）
            //    **全都只在这个数组里**。
            //    ⚠️ 不要为了"看起来对称"而改吃 `tasks`——两者的字段集不相交，互换只会缺字段。
            //    ⚠️ **着色是唯一的例外**：它按 `task_id` 关联回 `tasks[]` 取**航班**状态色
            //       （`OpsCommon.markerColor`，用户 2026-09-23 定的口径，理由见该函数注释）。
            //       关联只取颜色，位置与航向仍然只从 `devices[]` 拿（单一位置源约定）。
            // ‼️ **恒画全部**，不随选中增减（用户 ⑥ 修正的原始冲突）：选中只改**样式**，
            //    不改**集合**——所以这里的 model 永不经过任何按选中过滤的函数。
            // ✅ 每个 device 都经任务→航线关联而来，`route_id` **必非 null**，没有"无航线飞机"这一支。
            //-----------------------------------------------------------------
            // ‼️ `MapItemView` 而非裸 `Repeater`——理由见 L1 上方的长注释。
            MapItemView {
                model: opsShell.routeLayersEnabled ? opsShell._routeDevices : []
                delegate: MapQuickItem {
                    id: devMarker
                    // ‼️ `QGroundControl.multiVehicleManager.vehicles` 必须在这个**绑定表达式里**
                    //    读一次，作为实参传进去：`OpsCommon` 的函数体里读属性**不注册绑定依赖**
                    //    （`.pragma library` 的硬约束，见该文件头部）。写成函数内部读取的话，
                    //    载具建链/断开都不会让这里重估 ⇒ 永远找不到 Vehicle。
                    readonly property var _veh: {
                        var vs = QGroundControl.multiVehicleManager.vehicles
                        // ‼️ `vs.count` 这一读是**依赖注册**，不是短路优化：`vehicles` 在
                        //    `MultiVehicleManager.h:22` 上是 **CONSTANT** 属性，只读它的话这个绑定
                        //    **永不重估**（`.pragma library` 里读 count 不算进调用方的依赖，
                        //    见 OpsCommon.js 头部）⇒ 载具建链后 marker 永远找不到 Vehicle，
                        //    而界面看起来完全正常。`count` 有 NOTIFY countChanged。
                        if (!vs || vs.count === 0) return null
                        return OpsCommon.matchDeviceToVehicle(modelData, vs)
                    }
                    // 同理：`_veh.coordinate` 也必须在**实参位置**读一次，否则 MAVLink 位置一变
                    // 这个绑定不重估，marker **永远停在第一帧**——而界面看起来完全正常。
                    readonly property var _pos: OpsCommon.resolvePosition(
                                                     modelData, _veh, _veh ? _veh.coordinate : null)
                    readonly property string _vis: OpsCommon.visibleForSelection(modelData, opsShell._selectedRouteId)
                    // 本机所属的航班。`_routeTasks` 与 `_routeDevices` 是后端**同一条 WHERE
                    // 的两个投影**，所以这里查得到是常态、查不到才是异常（`markerColor` 对此有兜底）。
                    readonly property var _task: OpsCommon.taskById(opsShell._routeTasks, modelData.task_id)
                    // ‼️ `opsShell._now` 必须**作为实参**读进来：`.pragma library` 里函数体内读属性
                    //    **不注册绑定依赖**（见 `OpsCommon.js` 头部）⇒ 写在 `markerColor` 内部读的话
                    //    这个绑定永不重估，**交接超时红就永远不会出现**（而界面看起来完全正常）。
                    readonly property color _markerColor: OpsCommon.markerColor(
                                                             modelData, _task, opsShell._now, opsShell._handoverById)

                    // 两处都没有位置 ⇒ **不画**（`device.latest` 为 null 是常态：该机尚无遥测）
                    visible: _pos !== null
                    coordinate: _pos !== null
                                ? QtPositioning.coordinate(_pos.lat, _pos.lon)
                                : QtPositioning.coordinate(0, 0)
                    // 异常飞机恒 1.0（`visibleForSelection` 已保证），此处只需区分 dimmed
                    opacity: _vis === "dimmed" ? OpsCommon.dimmedOpacity : 1.0
                    anchorPoint: Qt.point(12, 12)

                    sourceItem: Item {
                        // ‼️ 本项宽度是**「图标 + 航班号标」整块**，不是图标的 24：命中区要盖住两者
                        //    （理由见下面 MouseArea）。`anchorPoint` 是 (12,12) 而图标仍从 (0,0)
                        //    起画 ⇒ 只把本项撑宽**不会移动**图标，标注落点不受影响。
                        width: 24 + 3 + markerLabelBox.width
                        height: 24
                        // 图标 = **QGC 缺省的地图飞机图标**的形状。来源是
                        // `src/FlightMap/Images/vehicleArrowOpaque.svg`（`FirmwarePlugin.h:327`
                        // 的 `vehicleImageOpaque()`，FlyView 地图用的就是它，PX4 插件未覆盖）。
                        // ‼️ 用 `Shape` 自绘而**不是** `Image` + `MultiEffect` 染色：后者要过 shader，
                        //    而"多色 SVG 到底有没有被压成单色"会变成一个只能靠肉眼验的隐含前提
                        //    （原图是**硬编码三色红**，QGC 自己也没给它染过色——`VehicleMapItem`
                        //    里那个 `MultiEffect` 只用来打阴影）。这里只取原图的**两个填充三角**
                        //    （原图另有两条深红描边，是多色硬编码的，去掉才能按状态染色），
                        //    path 坐标与上游 SVG **逐字相同**，便于日后与上游比对。
                        // ‼️ 顶点在 (35.5, 2.118) ⇒ **机头朝正北**，故 `rotation` 就是航向本身。
                        //    ⚠️ **不要**叠 −90°：站点机位图那个 `_airplanePath` 机头朝**右**、
                        //    需要 −90°，两者朝向约定相反，别把那边的手法照搬过来。
                        Item {
                            width: 24; height: 24
                            // ‼️ 航向旋转放在**这一层**，不放 `Shape` 上：`Shape` 内部那层
                            //    `Scale`（72→24）与 `rotation` 谁先作用取决于 Qt 的变换合并顺序，
                            //    "绕原点还是绕中心"会因此不同。在外层转，只绕 24×24 的中心，没有歧义。
                            // ⚠️ `heading` 缺失时回 0（正北）——不能让它变成 NaN 传下去。
                            rotation: Number(modelData.latest ? modelData.latest.heading : 0) || 0

                            Shape {
                                width: 72; height: 72
                                // 原图 viewBox 是 72×72，缩到 24。用 `Scale` 而不是把 path 里的
                                // 数字改小——改了数字就再也看不出它来自哪个图标了。
                                transform: Scale { origin.x: 0; origin.y: 0; xScale: 1 / 3; yScale: 1 / 3 }

                                ShapePath {
                                    fillColor: devMarker._markerColor
                                    strokeColor: "#ffffff"
                                    // ‼️ 宽度是**量出来的**，不是照搬原来那个圆点的 `border.width`
                                    //    —— 同样的 3px 在两种形状上完全不是一回事：圆点的 3px 边框
                                    //    只占 24px 周长的 12.5%，而这条**尖三角形**最窄处趋近于零，
                                    //    3px 描边会把填充色糊掉。离屏探针实测「状态色只剩 19%、
                                    //    其余全被白边盖住」，图标看上去是**白的**——正好毁掉
                                    //    "按状态显示不同颜色"这个诉求。
                                    //    实测各档（橙色像素 / 描边+填充总像素）：
                                    //      1.5px = 48%   1px = 64%   无描边 = 100%
                                    //      0.67px ≈ 98%，但它被抗锯齿吃成 2 个像素 ⇒ 等于没画，
                                    //      所以**没有**"细到刚好"这一档可选。
                                    //    ⇒ 常态**不描边**（状态色完整可见），点亮时用 1px 白边；
                                    //      两档的差别落在"有没有边"上，而不是边的粗细。
                                    // ⚠️ `strokeWidth` 的单位是 **path 的坐标（未缩放的 72 制）**，
                                    //    缩放 1/3 之后视觉宽度才等于它的三分之一 ⇒ 要 1px 视觉就写 3。
                                    strokeWidth: devMarker._vis === "lit" ? 3 : 0
                                    PathSvg { path: "M35.5 2.118v51.573L1.118 70.882zM36.5 53.691V2.118l34.382 68.764z" }
                                }
                            }
                        }
                        // 航班号标在图标右侧（自绘，**不用 ToolTip**：地图项是画在场景里的，
                        // ToolTip 的 parent 会落到地图根而非被悬停项上，位置会漂移）
                        // ‼️ 标的是**航班号**（`task_no`）而不是机号——地图上画的就是"航班"
                        //    （用户 2026-09-23 定）。三级回退：航班号 → 机号 → 设备号。
                        //    中间那级不是多余的：`task_no` 与 `uav_no` 都可能为空（后者在
                        //    `devices[]` 里由后端关联出来），而 `device_id` 一定在。
                        Rectangle {
                            id: markerLabelBox
                            x: 27                        // = 图标宽 24 + 间距 3（与上面的 width 同源，别只改一处）
                            anchors.verticalCenter: parent.verticalCenter
                            width: markerLabel.width + 8; height: markerLabel.height + 4
                            radius: 3
                            color: "#cc0d1526"
                            border.color: "#3a4a66"; border.width: 1
                            Text {
                                id: markerLabel
                                anchors.centerIn: parent
                                color: "#e6edf7"; font.pixelSize: 10; font.bold: true
                                text: modelData.task_no ? modelData.task_no
                                      : (modelData.uav_no ? modelData.uav_no : ("#" + modelData.device_id))
                            }
                        }
                        // ‼️ 命中区靠**撑宽 parent** 来涵盖航班号标，而不是在这里写
                        //    `width: parent.width + 3 + markerLabelBox.width`：
                        //    原先只 `anchors.fill: parent` 填图标的 24×24，而标画在图标**之外**
                        //    （x=27 起）⇒ **点标毫无反应**。而用户眼里那是「飞机 + 航班号」一个
                        //    整体，点在哪一半都该算点中了这架飞机。
                        // ⚠️ 本项是最后一个子项（后声明者在上）。日后若往 sourceItem 里再加
                        //    Button/MouseArea，必须排在**本项之前**，否则会把命中区切掉一块。
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                // 点 marker = 选中该机**所属的航线**（§4.3 的选中是航线级；
                                // 任务级选中仍由中段列表发 taskSelected 驱动）
                                opsShell.selectRoute(modelData.route_id)
                                _mapFollowFirst = false
                                _mapManualCenter = QtPositioning.coordinate(devMarker._pos.lat, devMarker._pos.lon)
                            }
                        }
                    }
                }
            }

            // 「点击界面其他部分则取消航线选择」（裁定 ⑥）。**直接接 `mapClicked`**，
            // 不另铺覆盖层——铺满的 MouseArea 会吃掉下层所有控件的点击且不报错。
            //
            // ‼️ 这里**曾经挂的是 `TapHandler`，它是个永远不触发的死 handler**：
            //    `FlightMap` 内部有一层 `anchors.fill` 的 `MultiPointTouchArea`
            //    （`mouseEnabled: true`），它**先消费**点击并发出 `mapClicked`；挂在
            //    `FlightMap` **自身**上的 handler 属于父项 handler，子项一旦接受事件就再也
            //    收不到。2026-09-23 实测（选中 RT-004 后点地图空白）：选中区像素 diff = 0，
            //    界面毫无反应——而**同一时刻点右栏空白是生效的**（那条路没被覆盖层挡）。
            //    所以改成接它本来就在发的那条信号，零新增控件。
            // ⚠️ 不要改回 TapHandler「顺手统一两个视图」的写法。右栏那条能不能收到，取决于
            //    **子项有没有把这次按下消费掉**，而不是"点了哪块区域"：
            //      · 两段列表的 `ListView` 在**内容溢出视口**时会消费按下（`Flickable` 要支持
            //        拖动）⇒ 落在列表上的点击收不到；
            //      · 命令条那 66px（`commandBarWrap` 在本文件内 `z:100`，高 `toolbarHeight`
            //        =**66**，不是 48）压根不属于右栏。
            //    ⇒ 一句话：**右栏上「列表溢出」处点不动，「不溢出的空白」点得动。**
            //
            //    ‼️ 本条**原先的结论是错的，已被探针证伪**。原文说「列表占的区域都被它吃掉，
            //       包括列表末尾下方的空白」，读起来像"右栏有一大片点不动的空白"。把两个条件
            //       摆在一起看，它们是**互斥**的：
            //         · 列表**装得下** ⇒ `Flickable` 不可拖 ⇒ **不消费**按下 ⇒ 事件冒泡到父项，
            //           这个 handler **照常生效**——"列表末尾下方的空白"正在此列；
            //         · 列表**溢出**   ⇒ 消费按下 ⇒ handler 收不到 ⇒ 但此时视口已被卡片**铺满**
            //           （只剩卡与卡之间 `cardGap`=**6px** 的缝）⇒ **没有可点的空白**。
            //       ⇒ 真正会失效的只有那 **6px 卡缝**，"大片空白点不动"这个说法不成立。
            //       2026-09-23 竖扫报出的 y=290/320/700 三点与"卡缝"相符（该步长下缝约占 1/5），
            //       但那一轮没留原始坐标与截图，**无法回查确认**——此处存疑，别当成已证。
            //
            //    ⚠️ **试过、不行的修法**（`qmltestrunner` + offscreen 实测，别重试）：
            //      · 把 `TapHandler` 从 `rightPanel` 挪到 `ListView` **自身**上 —— 列表溢出时
            //        **同样**收不到（实测 0 次）。推测是 handler 的抓取被 `Flickable` 的按下
            //        夺走，**机制未查证**。
            //      · 覆写 `ListView.contentItem` 往里挂 handler —— Qt 6.11 起 `contentItem`
            //        是**只读**属性，这么写直接编译不过。
            //    地图那条没有这个问题：`mapClicked` 覆盖整张地图，且拖动时不发。
            onMapClicked: opsShell.clearRouteSelection()
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

            // 点右栏**空白处**也取消航线选择（裁定 ⑥「点击界面其他部分」）。
            // ⚠️ 声明在父项上不会抢子项的点击：指针事件先给子项，子项不接受才冒泡上来
            //    ⇒ 航线行/任务卡自己的 MouseArea 先消费，**不会**出现"点一行选上又立刻被清掉"。
            //    （这也正是不能换成"铺满全屏的 MouseArea"的原因：那会**无条件**吃掉下层点击。）
            TapHandler {
                enabled: opsShell.routeLayersEnabled
                onTapped: opsShell.clearRouteSelection()
            }

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
                    onClicked: _rejectHandover(OpsCommon.handoverId(_confirmHandover), function(ok) {
                        if (ok) handoverDialog.close()
                        else _handoverActionError = qsTr("操作未送达服务端，请重试；仍失败请通知提出方撤回重提")
                    })
                }
                Button {
                    text: _confirmHandover && OpsCommon.isMine(_confirmHandover, AuthController.userId) ? qsTr("撤回") : qsTr("确认接管")
                    onClicked: {
                        var mine = _confirmHandover && OpsCommon.isMine(_confirmHandover, AuthController.userId)
                        var act = mine ? _cancelHandover : _acceptHandover
                        act(OpsCommon.handoverId(_confirmHandover), function(ok) {
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
