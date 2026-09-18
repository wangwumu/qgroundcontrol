import QtQuick
import QtQuick.Shapes

/// @brief 机位平面布局（仿 webui 停放页）：按经纬度投影 + **每轴一个比例系数**定尺。
///
/// 数据源：`GET /api/sites/:id/slots`（见 OpsView.qml `_fetchSlots`）。
///
/// ## 与 webui 停放页的一处**刻意不同**：间隔是固定值，不是一个比例
/// webui 里间隔 = 0.1461×卡宽 ⇒ 窄边栏里卡片与间隔**一起**被压到不可读。
/// 这里间隔钉死在 `fixedGap`（= 任务列表两张卡之间的间隔，单点定义在 `OpsView._taskCardGap`），
/// 比例系数只用来定**卡片宽**。
///
/// ## 两个比例系数（sx / sy），不是一个（用户 2026-09-18）
/// 「横向距离小了，但是纵向还是离得太远」——单一比例系数下中心距处处相等，于是
/// 横向相邻间隙 = `pitch − cw` = fixedGap，纵向相邻间隙 = `pitch − ch` = `0.44·cw + fixedGap`
/// （157px 的卡就是 **75px**，肉眼一眼看出不对劲）。
/// ⇒ 改成**每轴各一个**：`sx = (cw+G)/gx`、`sy = (ch+G)/gy`，`gx`/`gy` 是各轴上的最近间距
/// （各轴坐标排序取最小相邻差，见 `_axisMinGaps`）。两个轴的间隔于是都恰好等于 `fixedGap`。
/// 代价：**投影不再是等比的**（同一场地的相对方位仍然保真，绝对角度有拉伸）。
///
/// ## 卡片大小**由当前布局算出来**，不是常数
/// 「卡片的大小要根据宽度动态调整，不要做成固定的大小的，要根据当前的布局情况计算出来。
///  当然，每个界面上的机位卡片要一样大。」
/// ⇒ `_solveScale` 现算两个上界（可用宽 / 可用高）取最小，`sx`/`sy` 由最终的 `cw` 反推。
/// ‼️ 曾经有个 `_gapCap = 6.845×fixedGap` 的**常数**上界 —— 那正是"尺寸钉死、不随布局响应"
///    的元凶（3 机位的直角场地被它永久钉在 88px），已删。**别再把它加回来**。
/// ‼️ `minCardWidth` 只是**可读下限**（装不下时的兜底），它调不动常规场面的卡片大小。
///
/// ## 防重叠是**构造保证**的，不需要任何上界
/// `gx` 是全部 x 坐标排序后的最小相邻差 ⇒ **任一机位对的 `|dx|` 都不小于 `gx`**
/// （两点之差 = 中间那些相邻差之和，至少含一项，而每一项都 ≥ `gx`）。于是
/// `|dx|·sx ≥ gx·sx = cw + G` ⇒ **每一对**的横向净空都 ≥ G；纵向同理 ≥ G。
/// 而 `sx`/`sy` 是**由最终的 `cw` 反推**的 ⇒ 与 `cw` 取多大、是否被可读下限顶住都无关。
/// ⚠️ 只有某一轴上坐标**全同**（该轴 `g` 为 Infinity）时那一轴才退回等比，此时靠另一轴分离。
/// ⚠️ 旧写法（先解 s、再由 s 定 cw）有个致命的不动点：`cw` 一旦被上界夹住而 `s` 不缩，
/// 中心距就还是夹之前那个 ⇒ **间隔被撑到十几倍**（用户原话「离到邻村了」，实测 78.5px / 150px）。
/// **改尺寸就改 `cw`，`sx`/`sy` 永远跟着它走，别反过来。**
///
/// ## 机位状态这一维：**空心卡**（轮廓 + 底纹 + 占位圈 + 墨色），飞机按**无人机状态**着色
/// 本组件拿到的列表由**调用方选档**（`OpsView._slotsMapView` 走 `?include_unusable=1`），
/// 它含**已核准的全部机位**，故 `slot.status` 可能是 FREE / MAINTENANCE / FAULT 三者之一
/// （2026-09-18 之前平面图与使用面共用缺省档，`status` 恒为 FREE，这条通道一直是死的）。
///
/// ⚠️ **别把飞机图标的颜色改成按机位状态走**：那是 webui `SlotCard.vue` 的另一半口径，而这里的
/// 小飞机还要承担「停在哪台飞机」的指认 ⇒ 颜色必须与任务卡上的无人机状态一致（`uavColor`）。
/// 机位状态由三件套表达（单点定义在 `_slotStyles`）：**轮廓**（色 + 实/虚线）、**底纹**
/// （故障位的红网纹）、**占位圈的圈色**，外加第三行文字（`_statusText`，与几何层同源）。
/// 卡片是**空心卡**：空位透明底、停着飞机时才给深色底 —— 口径与 webui `SlotCard.vue` 逐条对齐。
///
/// ⚠️ **使用面仍只认 FREE 机位**：`OpsView._slots`（「指定机位」弹窗、`_slotById`/`_slotForTask`）
/// 走的还是缺省档，维护/故障机位不在其中——对操作员下发它们等于给一个永不成功的目标。
/// 两个集合**由后端分流**（`site.go ListSlots` 的三档），本组件只画、不判。
///
/// ⚠️ 为什么平面图非要看到维护/故障机位（用户 2026-09-18 报障）：「不显示处于维护和故障状态的
/// 机位，导致剩余各机位的**物理关系与实际有差别**」——本组件画的是场地的**物理布局**，
/// 少画两个机位，其余机位的投影相对方位就整体错位。**它不是使用面**。
Item {
    id: root

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    /// /api/sites/:id/slots 的数组（字段：id/slot_code/lat/lon/heading/status/review_status
    /// /current_uav_id/current_uav_no/current_uav_status）
    property var    slots: []
    /// "N" = 上为北（默认）；"E" = 上为东（逆时针 90° 转过来的视图）
    property string orient: "N"
    /// 求解比例系数用的**可用高上限**。
    /// ‼️ 必须来自**不依赖本组件尺寸**的量（如 rightPanel.height − 姿态仪表区），
    /// 否则「可用高 → s → 卡片高 → 自然高 → 可用高」会成环，QML 会给出抖动的结果。
    property real   maxAreaHeight: 0
    /// 当前选中的机位 id（-1 = 无）。点亮用。
    property int    selectedSlotId: -1
    /// 边栏宽的可取范围（**单点定义在 OpsView**，这里只用来算 desiredPanelWidth）
    property real   panelMinWidth: 340
    property real   panelMaxWidth: 510      // = panelMinWidth × 1.5

    /// 点选机位（参数为 slot.id）
    signal slotClicked(int slotId)

    //-------------------------------------------------------------------------
    // 可调参数
    //-------------------------------------------------------------------------
    /// 卡片 高/宽
    readonly property real cardAspect:   0.56
    /// 卡片**可读下限**：三行文字（机位号/无人机号/状态）压到这个宽度就到底了。
    /// ⚠️ 它不是"常规尺寸"——常规尺寸由 `_solveScale` 现算（见文件头）。
    /// 真库 site1 在 340px 边栏下算出 157px 宽，那是**下限的两倍多**，属正常。
    readonly property real minCardWidth: 70
    /// **固定**的机位间隔（见文件头「与 webui 的三处不同」）。
    /// 取值 = 任务列表两张卡之间的间隔（用户 2026-09-18：「间隔参照任务列表中两个卡片的间隔」），
    /// **单点定义在 `OpsView._taskCardGap`**，由调用方绑进来 —— 不在这里另抄一个字面量。
    property real   fixedGap:            6
    /// 机位区四周留白。由 OpsView 绑成 `_slotMargin`，与任务卡片左留白**同源**
    property real   edgeMargin:          10

    implicitWidth:  naturalWidth
    implicitHeight: naturalHeight
    clip:           false   // 溢出的卡片由外层 Flickable 的 clip 负责，这里不裁（滚动才看得见）

    //-------------------------------------------------------------------------
    // 常量
    //-------------------------------------------------------------------------
    /// 判定"两个机位坐标重合"的阈值（米）
    readonly property real _coincidentM:   0.001
    readonly property real _mPerDegLat:    111320

    //-------------------------------------------------------------------------
    // 卡片内文字的尺寸（飞机图标 + 三行文字）
    //-------------------------------------------------------------------------
    /// 卡片内左右内边距、图标与文字列的间距、图标占卡片宽的比例（下限 12px）。
    /// ‼️ 这三个量**同时**用于「算文字可用宽」与「真正摆位」（delegate 的 Row 直接读它们）
    /// —— 分成两份字面量必然漂移，而漂移的表现就是文字被 `ElideMiddle` 悄悄截掉。
    readonly property real _cardPadX:     5
    readonly property real _rowSpacing:   4
    readonly property real _planeRatio:   0.30
    readonly property real _planeMinSize: 12
    /// 机位号那一行比另两行大多少（沿用旧的 0.13 / 0.115）
    readonly property real _codeRatio:    1.13
    /// 字号的**可读下限**：缩到这个值就不再缩，剩下的宽度不足交给 `elide` 兜底。
    /// 「缩到 5px 的显示全」等于没显示 —— 下限比"永远不省略"优先。
    readonly property int  _minFontSize:  8
    /// 量宽用的基准字号（**只用于测量，不直接显示**）
    readonly property int  _refFontSize:  100

    /// 量文字宽用。
    /// ‼️ 必须是 **`FontMetrics` 的方法调用**（`advanceWidth(s)`），不能换成属性式的
    /// `TextMetrics`：后者一次只能量一个串，而"同一场地字号一致"要求先扫过**所有**机位
    /// 取最长那一串（逐个赋 `text` 再读 `advanceWidth` 会打断绑定，且顺序敏感）。
    FontMetrics { id: fmCode; font.bold: true;  font.pixelSize: root._refFontSize }
    FontMetrics { id: fmText; font.bold: false; font.pixelSize: root._refFontSize }

    //-------------------------------------------------------------------------
    // 几何（唯一入口：整块一次算完，避免多处各算一遍）
    //-------------------------------------------------------------------------
    readonly property var _geom: _layoutGeometry()

    /// 卡片宽（所有卡片同宽）
    readonly property real cardWidth:  _geom.cw
    /// 卡片高
    readonly property real cardHeight: _geom.ch
    /// 机位簇的自然宽（可能 > 本组件宽 ⇒ 横向滚动）
    readonly property real naturalWidth:  _geom.naturalW
    /// 机位簇的自然高
    readonly property real naturalHeight: _geom.naturalH

    /// 边栏要不要加宽：判据是「撑到可读下限这一步，装不装得下横向」。
    /// 竖直方向撑不下时加宽也救不了 ⇒ 返回最小宽（由纵向滚动兜底）。
    readonly property real desiredPanelWidth: _desiredPanelWidth()

    //-------------------------------------------------------------------------
    // 几何：投影与定尺
    //-------------------------------------------------------------------------
    /// 经纬度 → 米制等比平面。
    /// orient='E' 是**逆时针 90°**：(x,y)→(y,−x)，于是"上 = 东"。
    /// ⚠️ 写成顺时针 (−y,x) 会得到「上 = 西」，与"朝东"正好相反。
    function _project(list, o) {
        var pts = []
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            if (s && isFinite(Number(s.lat)) && isFinite(Number(s.lon))) pts.push(s)
        }
        if (pts.length === 0) return { points: [], we: 0, he: 0 }

        var latSum = 0, lon0 = Infinity, lat0 = Infinity
        for (i = 0; i < pts.length; i++) {
            var la = Number(pts[i].lat), lo = Number(pts[i].lon)
            latSum += la
            if (lo < lon0) lon0 = lo
            if (la < lat0) lat0 = la
        }
        var latBar = latSum / pts.length
        var kx = _mPerDegLat * Math.cos(latBar * Math.PI / 180)   // 经度方向的米/度
        var ky = _mPerDegLat                                     // 纬度方向的米/度

        var out = [], minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
        for (i = 0; i < pts.length; i++) {
            var mx = (Number(pts[i].lon) - lon0) * kx
            var my = -(Number(pts[i].lat) - lat0) * ky            // 屏幕 y 向下 ⇒ 取负
            var px = (o === "E") ? my : mx
            var py = (o === "E") ? -mx : my
            out.push({ slot: pts[i], x: px, y: py })
            if (px < minX) minX = px
            if (px > maxX) maxX = px
            if (py < minY) minY = py
            if (py > maxY) maxY = py
        }
        return { points: out, we: maxX - minX, he: maxY - minY, minX: minX, minY: minY }
    }

    /// 各轴的"最近间距"（米）：把该轴的坐标**排序后取最小相邻差**。
    /// 某一轴上坐标全同（差恒为 0）时返回 Infinity。
    ///
    /// ‼️ 这是"间隔恒定"能落到**两个轴**上的关键。旧的单一间距 `dMin` 只有一个比例系数
    /// ⇒ 中心距处处相等 ⇒ 横向相邻的间隙 = `pitch − cw = fixedGap`，纵向相邻的间隙
    /// = `pitch − ch = 0.44·cw + fixedGap`（157px 的卡就是 **75px**）。
    /// 用户 2026-09-18 报的「横向距离小了，但纵向还是离得太远」正是它。
    ///
    /// ‼️ **曾经的写法是"机位对按主轴分类（|dx| ≥ |dy| 的算 x 轴），各取最小"——错的。**
    /// 它把"某一对的主轴"当成了"这一对属于哪条网格线"，于是**同列相邻的两个机位**
    /// （dx = 0 < dy）被整个判给 y 轴，x 轴上就再也看不到它们 ⇒ `gx` 取到的是更远的另一对。
    /// 更致命的是**稀疏梅花桩**：站 1 的 7 台机位在 4 行 × 5 列里散放，一行只有一两台，
    /// **没有任何一对是"相邻行同列"** ⇒ 斜跨两行的那对（dx≈49.96, dy≈49.98）被 `dy` 大一点点
    /// 判给 y 轴 ⇒ `gy` 取到 **49.98 m（两倍行距）** ⇒ `sy` 少一半、行距从 45.2 掉到 22.55px
    /// （**比卡高 39 还小**，纵向压掉 16.45px）。
    /// 实测触发条件很脆：站 1 加一台"V07 正下方"的机位就凑出了同列对，行距**碰巧**恢复正常
    /// —— 删掉任意一台立刻复发。**判据不能靠场面凑巧。**
    ///
    /// ⇒ 改成**与配对无关**的写法：x 轴只关心 x 坐标的相邻差，y 轴只关心 y 坐标的相邻差。
    /// 顺带把防重叠的论证也变强了（见文件头：现在是**每一对**的两个轴净空都 ≥ G，
    /// 而不只是"配对的主轴"那一个）。
    function _axisMinGaps(pts) {
        var xs = [], ys = []
        for (var i = 0; i < pts.length; i++) { xs.push(pts[i].x); ys.push(pts[i].y) }
        return { gx: _minAdjacentDelta(xs), gy: _minAdjacentDelta(ys) }
    }

    /// 一列坐标里**最小的非零相邻差**（0 = 有两个机位在这条轴上完全对齐，不算间距：
    /// 它们靠另一轴分开，见文件头的不重叠论证）。少于两个可分辨值时返回 Infinity。
    function _minAdjacentDelta(vals) {
        var v = vals.slice().sort(function (a, b) { return a - b })
        var d = Infinity
        for (var i = 1; i < v.length; i++) {
            var dd = v[i] - v[i - 1]
            if (dd > _coincidentM && dd < d) d = dd
        }
        return d
    }

    /// 两个比例系数写成 **cw 的线性函数**：`sx = kx·cw + bx`、`sy = ky·cw + by`。
    /// 令 `sx = (cw+G)/gx`、`sy = (ch+G)/gy`（ch = aspect·cw）即得。
    /// 某一轴上坐标**全同**时那一轴退回**等比**（借用另一轴的系数）—— 此时该轴上的机位对
    /// 全都由另一轴的净空保证不重叠（见 `_solveScale` 的不重叠论证）。
    /// 返回 null = 两轴坐标都全同（所有机位重合）⇒ 交给 `_gridFallback`。
    ///
    /// ‼️ 返回值里**带着 `gx`/`gy` 与两个 ok 标志**：`_solveScale` 要用**取整后**的 `ch`
    ///    重算 `sy`（见那里的注释），没有 `gy` 就重算不了。别把它们当调试字段删掉。
    function _axisScaleCoeffs(pts) {
        var g = _axisMinGaps(pts)
        var okX = isFinite(g.gx), okY = isFinite(g.gy)
        var a = cardAspect, G = fixedGap
        if (okX && okY) return { kx: 1 / g.gx, bx: G / g.gx, ky: a / g.gy, by: G / g.gy,
                                 gx: g.gx, gy: g.gy, okX: true, okY: true }
        if (okX)        return { kx: 1 / g.gx, bx: G / g.gx, ky: 1 / g.gx, by: G / g.gx,
                                 gx: g.gx, gy: g.gy, okX: true, okY: false }
        if (okY)        return { kx: a / g.gy, bx: G / g.gy, ky: a / g.gy, by: G / g.gy,
                                 gx: g.gx, gy: g.gy, okX: false, okY: true }
        return null
    }

    /// 定尺：**直接解 cw**，两个比例系数由 cw 反推（`sx = kx·cw + bx` 等）。
    /// "装得下"是 cw 的两个一次不等式，闭式解：
    ///   we·sx + cw ≤ availW      he·sy + aspect·cw ≤ availH
    ///
    /// ‼️ **不设常数上界**（用户 2026-09-18：「不要做成固定的大小」）——两个上界全部现算。
    /// ‼️ 改 cw 就自动改 sx/sy ⇒ **间隔恒为 fixedGap 是构造保证**，与 cw 取多少无关，
    /// 也与 cw 被可读下限顶上去无关。于是不重叠**无条件成立**：
    /// 任一机位对都有 `|dx| ≥ gx` ⇒ `|dx|·sx ≥ gx·sx = cw + G` ⇒ 横向净空 ≥ G（纵向同理）。
    /// （两轴坐标都全同时走网格兜底。）
    /// ⇒ 旧版那个"逐对精确防重叠上界"（`_pairSafeCardWidth`）连同它带来的浅叠取舍，
    ///    整个不需要了。
    function _solveScale(availW, availH, we, he, coef) {
        var cwW = (availW - we * coef.bx) / (we * coef.kx + 1)
        var cwH = (availH - he * coef.by) / (he * coef.ky + cardAspect)
        // ⚠️ floor 不是 round：向上取整会把间隔吃掉一点，固定值就不再是固定值
        var cw = Math.max(Math.floor(Math.min(cwW, cwH)), minCardWidth)
        var ch = Math.round(cw * cardAspect)
        var sx = coef.kx * cw + coef.bx
        // ‼️ `sy` 由**取整后**的 `ch` 反推，**不能**沿用 `coef.ky * cw + coef.by`。
        //    后者用的是 `cardAspect * cw`（未取整），而画出来的是 `round(cardAspect * cw)`
        //    —— 两者差多少，纵向净空就少多少（站 1 实测：净空 6.00 变 **5.88**，
        //    `ch` 从 152.88 舍入到 153 吃掉了 0.12px）。横向没有这个问题：
        //    `cw` 本身就是 floor 出来的整数，`sx` 用未取整的 `cw` 也是同一个值。
        //    webui 侧 `useParking.solveScale` 已改成同一写法，**两处必须同源**。
        var sy = coef.okY ? (ch + fixedGap) / coef.gy
               : coef.okX ? sx                            // 纵向坐标全同 ⇒ 退回等比
               : coef.ky * cw + coef.by                   // 理论上到不了（coef 为 null 已提前返回）
        return { cw: cw, ch: ch, sx: sx, sy: sy }
    }

    /// 三行文字的字号。**全场地一个值**——扫过所有机位取"最长那一串"的需求，
    /// 于是同一场地的卡片字号一致（与「每个界面上的机位卡片要一样大」同一条精神）。
    ///
    /// "放得下"是**构造保证**：三个上界都反解自"该行文字在基准字号下的**实测**宽"：
    /// `u ≤ ref·textW / adv(s)`，机位号那行再除以 `_codeRatio`（它的字号是 `u·_codeRatio`）。
    ///
    /// ‼️ 旧写法按**卡片宽**定比例（`cw × 0.13`）是**错的**：它没算飞机图标与内边距吃掉的
    /// 那部分——157px 的卡里只有 `157 − 10 − 47 − 4 = 96px` 真的留给文字，而 20px 的
    /// `"SLOT_V02"` 需要 110px ⇒ 三行全被 `ElideMiddle` 截成 `SL…02`（用户 2026-09-18
    /// 报障「机位卡片上的文字都显示不全了，适当缩小字号，显示全」）。
    /// 卡片第三行的文字：**占用 → 无人机状态；空位 → 机位状态**（空闲 / 维护 / 故障）。
    ///
    /// ‼️ 本函数是**测量与摆位的唯一同源点**（规则⑦的配套约束）：`_fitFontSizes` 按它量宽、
    /// delegate 按它显示。两处各写一份表达式，就会出现"量的是 A、显示的是 B"⇒ 文字被
    /// `ElideMiddle` 悄悄截掉而探针全绿。
    ///
    /// ⚠️ 两个 `*_label` 都是**调用方补好的**中文文案，唯一来源是 OpsView 的 `_uavStatusLabel`
    /// 与 `_slotStatusLabel` —— 本组件**不另抄一份枚举→中文**（「界面不出现裸枚举」+「文案单点定义」）。
    /// 末端的 `|| slot.status` 是**故意保留的 fail-visible 兜底**：后端加了第 4 个状态值而前端没跟上时，
    /// 卡片上会显示那个原始枚举（一眼可见），而**不是**静默显示成「空闲」——那是在撒谎，
    /// 一个维护中的机位看着和可用机位一模一样。
    function _statusText(slot) {
        if (!slot) return ""
        return slot.current_uav_id
               ? (slot.uav_status_label || slot.uav_status || "")
               : (slot.slot_status_label || slot.status || "")
    }

    function _fitFontSizes(cw, ch) {
        var planeW = Math.max(_planeMinSize, cw * _planeRatio)
        var textW  = Math.max(1, cw - _cardPadX * 2 - planeW - _rowSpacing)
        var lineH  = Math.max(1, Math.round((ch - 6) / 3))
        var ref    = _refFontSize
        // 竖向：三行合计不得超出卡内高。0.85 / 0.80 里已含 Text 的行高系数（≈1.17）。
        var u = Math.min(Math.round(lineH * 0.85), Math.floor(lineH * 0.80 / _codeRatio))
        for (var i = 0; i < slots.length; i++) {
            var s = slots[i]
            if (!s) continue
            var uavNo = s.current_uav_id ? (s.current_uav_no || "") : ""
            var label = _statusText(s)     // ← 与 delegate **同源**，别在这里另写一份表达式
            u = Math.min(u, Math.floor(ref * textW
                                       / Math.max(1, fmCode.advanceWidth(s.slot_code || "") * _codeRatio)))
            if (uavNo) u = Math.min(u, Math.floor(ref * textW / Math.max(1, fmText.advanceWidth(uavNo))))
            if (label) u = Math.min(u, Math.floor(ref * textW / Math.max(1, fmText.advanceWidth(label))))
        }
        u = Math.max(_minFontSize, u)
        return { uavSize: u, codeSize: Math.max(1, Math.floor(u * _codeRatio)), lineH: lineH }
    }

    /// 把字号挂到几何结果上（**唯一出口**：四个 return 分支都过这里，漏一个分支就有一类
    /// 场面的卡片没有字号 ⇒ `undefined` ⇒ 又回到 1px 那个坑）。
    function _finalize(res) {
        var fs = _fitFontSizes(res.cw, res.ch)
        res.codeSize = fs.codeSize
        res.uavSize  = fs.uavSize
        res.lineH    = fs.lineH
        return res
    }

    /// 全部落位一次算完。返回的 items 每项自带 cw/ch（两种排布模式共用同一套渲染）。
    function _layoutGeometry() {
        var availW = Math.max(0, width - edgeMargin * 2)
        var availH = Math.max(0, maxAreaHeight - edgeMargin)
        var proj = _project(slots, orient)
        var pts = proj.points

        if (pts.length === 0)
            return _finalize({ items: [], cw: minCardWidth, ch: Math.round(minCardWidth * cardAspect),
                               naturalW: 0, naturalH: 0, mode: "none" })

        // 只有 1 个 ⇒ 没有"间距"可参照，比例系数无从谈起，直接给一张默认尺寸的卡
        //（**刻意不随宽度放大**：单机位撑成一张占满整块场地的大空卡，比小卡更难用）
        if (pts.length === 1) {
            var cw1 = minCardWidth, ch1 = Math.round(cw1 * cardAspect)
            return _finalize({ items: [{ slot: pts[0].slot, x: edgeMargin + (availW - cw1) / 2, y: 0,
                                         cw: cw1, ch: ch1 }],
                               cw: cw1, ch: ch1, naturalW: cw1, naturalH: ch1, mode: "solo" })
        }

        // ‼️ 退化数据：投影完全不带位置信息（真库里 site 2 的两个机位坐标一模一样）。
        // 此时投影布局会把所有卡片画在同一个点上（看起来只剩一张），**strictly 比现状差**
        // ⇒ 退回原来的两列网格。判据是"整簇在 x 和 y 上都没有展开"，不是"某一对重合"
        //（只重合一对时，其余机位的相对关系仍然有效，照常投影）。
        if (proj.we + proj.he < 0.5) return _gridFallback(pts, availW)

        var coef = _axisScaleCoeffs(pts)
        if (!coef) return _gridFallback(pts, availW)     // 两轴坐标都全同 ⇒ 所有机位重合
        var sol = _solveScale(availW, availH, proj.we, proj.he, coef)
        var naturalW = proj.we * sol.sx + sol.cw
        var naturalH = proj.he * sol.sy + sol.ch
        // 横向：**先让出 edgeMargin**，富余再平分两侧 ⇒ 机位卡片与任务卡片同一条左基线
        //（用户 2026-09-18：「机位卡片左侧不能靠边，需要留点空间（见任务卡片的左侧空间）」）。
        // ⚠️ 纵向不加这个偏移：贴底是由 OpsView 的底锚 + `_slotMargin` 给的，这里再加会重复。
        var padX = Math.max(0, (availW - naturalW) / 2)
        var ox = edgeMargin + padX + sol.cw / 2, oy = sol.ch / 2
        var items = []
        for (var i = 0; i < pts.length; i++) {
            items.push({ slot: pts[i].slot,
                         x: ox + (pts[i].x - proj.minX) * sol.sx - sol.cw / 2,
                         y: oy + (pts[i].y - proj.minY) * sol.sy - sol.ch / 2,
                         cw: sol.cw, ch: sol.ch })
        }
        return _finalize({ items: items, cw: sol.cw, ch: sol.ch,
                           naturalW: naturalW, naturalH: naturalH,
                           mode: "projected", sx: sol.sx, sy: sol.sy, gap: fixedGap })
    }

    /// 退化数据的兜底：老的两列网格（2 列），保证「坐标全为 0」时不比改造前更差。
    function _gridFallback(pts, availW) {
        var cols = 2
        var bw = Math.max(minCardWidth, (availW - fixedGap) / cols)
        var bh = Math.round(bw * 0.5)
        var rows = Math.ceil(pts.length / cols)
        var items = []
        for (var i = 0; i < pts.length; i++) {
            var r = Math.floor(i / cols), c = i % cols
            items.push({ slot: pts[i].slot, x: edgeMargin + c * (bw + fixedGap),
                         y: r * (bh + fixedGap), cw: bw, ch: bh })
        }
        return _finalize({ items: items, cw: bw, ch: bh,
                           naturalW: cols * bw + (cols - 1) * fixedGap,
                           naturalH: rows * bh + (rows - 1) * fixedGap, mode: "grid" })
    }

    /// 边栏要不要加宽。**判据只有一条**：当前宽度装不装得下**可读的**卡片。
    /// 装得下 ⇒ 不加宽（加宽只是白占地图）；装不下 ⇒ 扩到"**刚好**装下可读卡片"为止，不多扩。
    ///
    /// ‼️ 两个反例，都实测过：
    /// ① "扩到卡片最大"（拿 `cwH` 当 `want`）：真库 site1（3 机位）在 340 下卡片已是 157×88、
    ///    远比可读下限宽，却仍把边栏顶到 510 —— 白占地图。
    /// ② "不把宽度上界算进 `want`"：8 机位挤成一片时会得出 `need=4262` ⇒ 同样撑满 510，
    ///    而 340 与 510 下卡片**都是 70**（宽度上界压根没松绑）。
    function _desiredPanelWidth() {
        var proj = _project(slots, orient)
        var n = proj.points.length
        if (n < 2) return panelMinWidth
        if (proj.we + proj.he < 0.5) return panelMinWidth          // 走网格兜底，无需加宽
        var coef = _axisScaleCoeffs(proj.points)
        if (!coef) return panelMinWidth
        var availH = Math.max(0, maxAreaHeight - edgeMargin)
        // 高度已经把卡片卡到可读下限以下 ⇒ 加宽换不来更大的卡片（纵向滚动兜底）
        if ((availH - proj.he * coef.by) / (proj.he * coef.ky + cardAspect) < minCardWidth)
            return panelMinWidth
        // "cwW ≥ minCardWidth" 反解出所需可用宽 ⇒ 刚好可读的边栏宽
        var need = Math.ceil(minCardWidth * (proj.we * coef.kx + 1) + proj.we * coef.bx)
                   + edgeMargin * 2
        if (need <= panelMinWidth) return panelMinWidth
        return Math.min(panelMaxWidth, need)
    }

    //-------------------------------------------------------------------------
    // 呈现
    //-------------------------------------------------------------------------
    // 小飞机：机头原生朝**右**（东，+x）。按罗盘 heading 旋转必须 −90°；
    // 朝东视图还要再叠 mapRot（−90°）。写成 rotate(heading) 会系统性偏 90°。
    readonly property string _airplanePath: "M8.4 12H2.8L1 15H0V5h1l1.8 3h5.6L6 0h2l4.8 8H18a2 2 0 1 1 0 4h-5.2L8 20H6z"

    // ---- 路径生成（全都返回 SVG 串喂给 `PathSvg`） ---------------------------------
    // 用 `PathSvg` 而不是 `PathLine`/`PathAngleArc` 元素列表，是因为这三条路径的**点数随
    // 卡片尺寸变**（网纹尤其：线数由宽高决定），元素列表没法参数化。
    // 好处顺带一条：探针读到的 `PathSvg.path` 是**字符串**，能直接断言"这是个圆"、
    // "这里有 N 条斜线"，而 `Shape` 画出来的像素是读不到的。

    /// 圆角矩形轮廓。`inset` 是描边内缩量：描边以路径为中心向两侧各画 `strokeWidth/2`，
    /// 不内缩的话外侧那一半落在卡片边界外（本卡片的邻居和面板边界会啃掉它）。
    function _roundRectPath(w, h, r, inset) {
        var x0 = inset, y0 = inset
        var x1 = w - inset, y1 = h - inset
        if (x1 <= x0 || y1 <= y0) return ""
        r = Math.max(0, Math.min(r, (x1 - x0) / 2, (y1 - y0) / 2))
        return "M" + (x0 + r) + "," + y0
             + " H" + (x1 - r) + " A" + r + "," + r + " 0 0 1 " + x1 + "," + (y0 + r)
             + " V" + (y1 - r) + " A" + r + "," + r + " 0 0 1 " + (x1 - r) + "," + y1
             + " H" + (x0 + r) + " A" + r + "," + r + " 0 0 1 " + x0 + "," + (y1 - r)
             + " V" + (y0 + r) + " A" + r + "," + r + " 0 0 1 " + (x0 + r) + "," + y0 + " Z"
    }

    /// 整圆（两段半圆）。`d` = 外径。空位的**虚线占位圈**用它。
    function _circlePath(d) {
        var r = d / 2
        if (r <= 0) return ""
        return "M0," + r + " A" + r + "," + r + " 0 1 1 " + d + "," + r
             + " A" + r + "," + r + " 0 1 1 0," + r + " Z"
    }

    /// 两向 45° 交叉网纹。参数**照抄 webui 的 `repeating-linear-gradient`**：
    /// 线色 `#b91c1c`、线宽 1.5px、周期 6px。
    /// ‼️ 别按卡片大小等比缩放周期：CSS 那边是**绝对像素**，小卡上更密是同一个观感；
    /// 等比放大到 100px 宽的卡上就只剩两条线，"网纹"也就没了。
    /// 每条线都画满整高并向两端越界 —— 45° 线不越界就盖不住矩形的角（webui 靠
    /// `background-repeat` 铺满同一回事）。越界部分由外层 `clip: true` 裁掉。
    function _hatchPath(w, h, gap) {
        if (w <= 0 || h <= 0) return ""
        var d = Math.max(2, gap), p = "", x
        for (x = -h; x <= w + h; x += d) p += "M" + x + ",0 L" + (x + h) + "," + h + " "
        for (x = 0;  x <= w + 2 * h; x += d) p += "M" + x + ",0 L" + (x - h) + "," + h + " "
        return p
    }

    /// 无人机状态 → 颜色。**键与 OpsView.qml `_uavStatusLabel` 是同一组**
    /// （table_uav.status 的 11 个枚举），改枚举时两处一起改。
    function uavColor(status) {
        switch (status) {
        case "PARKED":            return "#67e8f9"   // 已停放
        case "PARKED_YARD":       return "#d8b4fe"   // 停放场
        case "PREFLIGHT":         return "#fde68a"   // 准备中
        case "READY_TO_TAKEOFF":  return "#a3e635"   // 待飞
        case "TAKEOFF":           return "#4ade80"   // 起飞中
        case "IN_FLIGHT":         return "#34d399"   // 飞行中
        case "RETURNING":         return "#38bdf8"   // 返航中
        case "LANDING":           return "#38bdf8"   // 降落中
        case "LANDED":            return "#94a3b8"   // 已落地
        case "DIVERTED":          return "#fbbf24"   // 备降
        case "EMERGENCY_LANDING": return "#f87171"   // 迫降
        default:                  return "#94a3b8"
        }
    }

    /// 机位状态 → **空心卡**视觉（三档一张表）。**这条通道现在是活的**：2026-09-18 起平面图走
    /// `?include_unusable=1`（见文件头），拿得到维护/故障机位 ⇒ 三个分支都会真的命中。
    ///
    /// 口径与 webui `SlotCard.vue` 的 `.sm-free` / `.sm-maint` / `.sm-fault` 同源（用户 2026-09-18 定）：
    ///   空闲 FREE  **白色实线**轮廓 + 透明底 + 白色虚线圈 + 白"空闲"
    ///   维护 MAINT **白色虚线**轮廓 + 透明底 + 白色虚线圈 + 白字
    ///   故障 FAULT 红色实线轮廓 + **红色交叉网纹底** + 白色虚线圈 + 白字
    ///
    /// ‼️ FREE 与 MAINTENANCE **同为白色轮廓，唯一的差别就是实线/虚线** —— 这是可以的（线型是
    /// 独立通道），但**别"顺手统一"**其中任一条：把 FREE 改成虚线或把维护改成实线，这两档就
    /// 再也分不出来了。（`#4a5f85` 那种暗蓝作 FREE 是 2026-09-18 首版，用户真机一看就说
    /// 「空闲卡片显示非常不明显」，当日改白。）
    ///
    /// ‼️ 故障位的字是**全白**，刻意**不**取描边色 —— 这条是 webui 量出来的硬约束，别"顺手统一成
    /// 二字与边框同色"：网纹要看得见线色就得够亮（`#b91c1c`），浅红字压在这些线上最坏只有 **2.37:1**。
    /// 红字压红底怎么调都是"调一个另一个就崩"，故让**两个红通道**（轮廓 + 网纹）去表达故障。
    /// ⚠️ 别拿这里的颜色去推**使用面**的行为：维护/故障机位在「指定机位」弹窗里根本不存在。
    readonly property var _slotStyles: ({
        "FREE":        { outline: "#ffffff", dashed: false, hatch: false, mark: "#ffffff" },
        "MAINTENANCE": { outline: "#ffffff", dashed: true,  hatch: false, mark: "#ffffff" },
        "FAULT":       { outline: "#f87171", dashed: false, hatch: true,  mark: "#ffffff" }
    })
    /// 未知/缺失状态退回 FREE —— 与 webui 的 `default: return 'sm-free'` 同口径。
    /// ⚠️ 别在这里加"fail-visible 显示原始枚举"式的兜底：`mark` 是**颜色**，不是文案；
    /// 状态二字本身仍走 `_statusText`，那条有 `|| slot.status` 兜底（后端加第 4 个状态值时
    /// 会**显示原始枚举**而不是谎报"空闲"）。
    function slotStyle(slot) {
        var st = slot ? slot.status : ""
        return _slotStyles[st] || _slotStyles.FREE
    }

    Repeater {
        model: root._geom.items

        delegate: Rectangle {
            id: cardRoot
            objectName: "slotCard"      // 供离屏探针（/tmp/slprobe）按名字取回卡片量坐标
            x:      modelData.x
            y:      modelData.y
            width:  modelData.cw
            height: modelData.ch
            radius: 6
            // **空心卡**：空位**透明底**（飞机图标与文字直接压在地图上，见文件头），
            // 停着飞机时才给深色底 —— 与 webui `.slot.occupied { background: var(--bg) }` 同口径：
            // 飞机图标和状态文字要压在干净的底上。选中态仍占底色通道。
            readonly property bool _selected: root.selectedSlotId === modelData.slot.id
            readonly property bool _occupied: !!modelData.slot.current_uav_id
            /// 本档的视觉参数（轮廓色 / 是否虚线 / 是否有网纹 / 墨色），单点定义在 `_slotStyles`
            readonly property var  _style:    root.slotStyle(modelData.slot)
            color:  _selected ? "#2f6bd8" : (_occupied ? "#1c2942" : "transparent")
            // ‼️ 边框一律交给下面的 `slotOutline` 画，这里**必须**是 0。
            // 两处都画的话，维护档会同时出现"白虚线"和"白实线"两条框。
            border.width: 0

            readonly property real _planeSize: Math.max(root._planeMinSize, cardRoot.width * root._planeRatio)
            /// 轮廓线宽（选中时加粗）。**算一次**给描边色、宽度、路径内缩三处共用 ——
            /// 内缩量必须等于线宽的一半，三处各写一份必然漂移（表现是描边粗细不一或半个像素被啃掉）。
            readonly property real _outlineW: _selected ? 2 : 1.4
            // 字号**由几何层算好**（`_fitFontSizes`：按每张卡实测的文字宽反解，全场地取同一个值）。
            // 这里只读结果——**不要在委托里另算字号**：那会按卡片各算各的，
            // 同一场地里"无人机号长一点的那张卡"连机位号都跟着变小。
            //
            // ‼️ 曾经在这里按**卡片宽**定比例（`cardRoot.width * 0.13` / `* 0.115`）：飞机图标与
            // 内边距吃掉 47% 的卡宽，算式却按整卡宽算 ⇒ 20px 的 "SLOT_V02" 需要 110px 而只有 96px
            // ⇒ 三行全被 `ElideMiddle` 截成 "SL…02"（用户 2026-09-18：「文字都显示不全了」）。
            // ‼️ 还有一次这里写的是 `cardRoot.ch` —— 卡片上**根本没有** `ch` 这个属性 ⇒
            // `(undefined−6)/3 = NaN` ⇒ 赋给 int 属性变 **1** ⇒ 三行以 1px 渲染，肉眼
            // 就是"卡片上除了飞机图标啥也没有"。QML 读不存在的属性**不报错**，只给 undefined。
            readonly property int _lineH:    root._geom.lineH
            readonly property int _codeSize: root._geom.codeSize
            readonly property int _uavSize:  root._geom.uavSize

            // ---- 机位状态这一维的三件套（底纹 / 轮廓 / 占位圈），顺序即叠放顺序 --------------

            /// ① 红色交叉网纹底（仅故障位）。
            /// ⚠️ **空位才画**：停着飞机时上面的深色底会盖住它 —— 与 webui `.slot.occupied`
            /// 用 `background` 简写一并清掉网纹同口径（"保住可读性优先"，那是刻意的不是 bug）。
            Item {
                objectName: "slotHatch"
                anchors.fill: parent
                clip: true          // 45° 线是越界画的，越界部分在这里裁掉
                visible: cardRoot._style.hatch && !cardRoot._occupied
                Shape {
                    objectName: "slotHatchShape"    // 供离屏探针断言"故障位确实有网纹"
                    anchors.fill: parent
                    ShapePath {
                        strokeColor: "#b91c1c"
                        strokeWidth: 1.5
                        fillColor:   "transparent"
                        // ‼️ 尺寸必须写 `cardRoot.width/height`，**别写 `parent.width`**：
                        // `PathSvg` 不是 Item、没有自己的 `parent`，绑定里的 `parent` 会落到
                        // **外层组件**（`SlotLayout`）上 —— 实测按 340×181.92 生成，比卡片
                        // 大出三四倍。密度侥幸没错（线是等距的、卡外的被 `clip` 裁掉），
                        // 但每张故障卡白生成近 10KB 路径，且数值随边栏宽度无谓地变。
                        PathSvg { path: root._hatchPath(cardRoot.width, cardRoot.height, 6) }
                    }
                }
            }

            /// ② 卡片轮廓。**唯一的边框来源**：实线与虚线都走这里。
            /// 拆成"实线看 `Rectangle.border`、虚线看 Shape"两处必然漂移，而漂移的表现是
            /// 某一档的框莫名其妙比别档粗细不一。虚线只能这么画 —— QML 的 `Rectangle`
            /// **没有** `borderStyle`（那是 QtWidgets 的 API）。
            Shape {
                objectName: "slotOutline"
                anchors.fill: parent
                ShapePath {
                    fillColor:   "transparent"
                    strokeColor: cardRoot._selected ? "#7fb3ff" : cardRoot._style.outline
                    strokeWidth: cardRoot._outlineW
                    strokeStyle: cardRoot._style.dashed ? ShapePath.DashLine : ShapePath.SolidLine
                    dashPattern: cardRoot._style.dashed ? [5, 4] : []
                    PathSvg {
                        path: root._roundRectPath(cardRoot.width, cardRoot.height, cardRoot.radius,
                                                  cardRoot._outlineW / 2)
                    }
                }
            }

            // ⚠️ 竖直居中做在 Row 上，**不要**让 Row 的子项各自 anchors.verticalCenter：
            // Row 是 Positioner，会另行决定子项的 y，与锚定打架（Qt 文档明确不建议）。
            Row {
                id: cardRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.left:   parent.left
                anchors.right:  parent.right
                // ‼️ 这三个量**必须**读 root 上的常量：`_fitFontSizes` 就是按它们反解文字可用宽的，
                // 这里另写字面量 ⇒ 测量与摆位各说各话，表现就是文字被悄悄截掉。
                anchors.leftMargin:  root._cardPadX
                anchors.rightMargin: root._cardPadX
                spacing: root._rowSpacing

                Item {
                    id: planeBox
                    width:  cardRoot._planeSize
                    height: cardRoot._planeSize

                    // 图标**二选一**（与 webui 的 `v-if="slot.uav_id"` 同口径）：
                    // 有飞机 → 飞机轮廓；空位 → **虚线占位圈**（webui 的 `.ph`）。
                    // ‼️ 空位以前画的也是飞机轮廓（空心灰飞机），2026-09-18 按用户规格改成虚线圈。

                    // 有飞机：20×20 的路径按 _planeSize 缩放；Shape 中心与旋转原点重合，
                    // 于是"先缩放后旋转"与"先旋转后缩放"结果一致（都是绕中心）。
                    // 颜色按**无人机状态**（见文件头：它还要承担"停的是哪台飞机"的指认）。
                    Shape {
                        visible: cardRoot._occupied
                        width: 20
                        height: 20
                        anchors.centerIn: parent
                        scale: planeBox.width / 20
                        transformOrigin: Item.Center
                        transform: Rotation {
                            origin.x: 10; origin.y: 10
                            angle: (Number(modelData.slot.heading) || 0) - 90
                                   + (root.orient === "E" ? -90 : 0)
                        }
                        ShapePath {
                            fillColor:   root.uavColor(modelData.slot.uav_status)
                            strokeColor: "transparent"
                            strokeWidth: 0
                            PathSvg { path: root._airplanePath }
                        }
                    }

                    // 空位：**虚线占位圈**。圈色跟本档的墨色走（空闲蓝 / 维护白 / 故障白）——
                    // webui 那条"`.ph` 取本卡墨色"的规则；故障位取白是特例（见 `_slotStyles`）。
                    Shape {
                        objectName: "slotPlaceholder"
                        visible: !cardRoot._occupied
                        anchors.fill: parent
                        ShapePath {
                            fillColor:   "transparent"
                            strokeColor: cardRoot._style.mark
                            strokeWidth: 1.6
                            strokeStyle: ShapePath.DashLine
                            dashPattern: [3, 3]
                            PathSvg { path: root._circlePath(planeBox.width - 1.6) }
                        }
                    }
                }

                Column {
                    id: metaCol
                    width: cardRow.width - planeBox.width - cardRow.spacing
                    spacing: 0

                    // ① 机位编号。三档一律纯白（webui `.sm-free .code, .sm-maint .code,
                    // .sm-fault .code { color: #fff }`）—— 空心卡上没有"底"可以衬字，
                    // 色值再分档就只剩对比度问题。
                    Text {
                        width: parent.width
                        color: "#ffffff"
                        font.pixelSize: cardRoot._codeSize
                        font.bold: true
                        elide: Text.ElideMiddle
                        text: modelData.slot.slot_code
                    }
                    // ② 无人机编号（空位时整行不占位，卡片退回两行）
                    Text {
                        width: parent.width
                        visible: cardRoot._occupied
                        color: "#9fb3d4"
                        font.pixelSize: cardRoot._uavSize
                        elide: Text.ElideMiddle
                        text: modelData.slot.current_uav_no || ""
                    }
                    // ③ 状态。占用=无人机状态（与飞机图标同色）；空位=机位状态（空闲/维护/故障）。
                    // 取值一律走 `root._statusText` —— 它与 `_fitFontSizes` 同源（见该函数注释）。
                    // 空位时取**本档的墨色**（空闲蓝 / 维护白 / 故障白），与轮廓、占位圈同色
                    // —— 这正是 webui 那条"状态二字取描边色"的规则，故障位是它唯一的例外（见 `_slotStyles`）。
                    Text {
                        width: parent.width
                        color: cardRoot._occupied
                               ? root.uavColor(modelData.slot.uav_status) : cardRoot._style.mark
                        font.pixelSize: cardRoot._uavSize
                        elide: Text.ElideMiddle
                        text: root._statusText(modelData.slot)
                    }
                }
            }

            // 点机位 → 选中该机位，并反向点亮停放其无人机的任务（沿用原有交互）
            MouseArea {
                anchors.fill: parent
                onClicked: root.slotClicked(modelData.slot.id)
            }
        }
    }
}
