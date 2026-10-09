import QtQuick
import QtTest

// ⚠️ 相对路径 import：`QGCQmlQuickTests` **没有 link QGC 的 QML 资源**（它的 CMakeLists 只链
//    Qt6::{QuickTest,Qml,Gui,Quick}），所以 `import QGroundControl...` 在这里必然失败。
//    而 `QUICK_TEST_SOURCE_DIR` 指向的是**源码目录**（不是构建目录），测试文件按文件系统 URL
//    加载 ⇒ 相对路径能穿回仓库根。深度：tests → QmlTesting → UnitTestFramework → test → 根。
import "../../../../src/OpsView/OpsCommon.js" as OpsCommon

/// 降落端统一框架（设计稿 §9.8）的两个纯函数与四个常量。
///
/// ‼️ 这一组用例钉的是**判据本身**，不是调用点：**进近方式**这个维度在 `OpsCommon.js` 里
///    由 `landKindTransitionToMc` 与 `landApproachPoint` 两个函数编码，QML 只许调它们；
///    另一个维度（**入口语义**：正常降落读库写库 / 救济不读不写）落在 `OpsView.qml` 的
///    两条入口上，不在本文件，故本文件不覆盖它。
///    判据写错的后果不是崩溃，
///    而是「三条路里有一条静默走了另一条的语义」—— 例如救济路径误写数据库。
///
/// ‼️ **2026-10-09 两处口径改动**（本文件随之重写，不是"顺手改绿"）：
///    ① F1 的进近点偏移距离**移进后端运营常数表**（`vtol_landing_pushout_distance`，初值
///       400 m）。⇒ 原来的 `LAND_FW_APPROACH_OFFSET_M` 常量**已删**，本文件不再有"常量值"
///       那一格；距离改由 `fwOrigin.pushoutM` **当实参传进来**，
///       故本文件的判据变成「**给定** pushoutM，偏移就是它」——
///       仍用**两个不同取值**去验，否则「函数把 400 写死」也能全绿。
///    ② F1 的原点与方位**同时**换了：改前是「**机位**沿**机位朝向**偏 300 m」，
///       改后是「**飞机**沿**飞机航向**偏 pushoutM」（用户 2026-10-09 裁定①）。
///       ⇒ 原来那几条"P 落在机位附近、朝向无效回 null"的断言，钉的是**旧几何**，
///         留着会变成"看着还绿、实际已无关"⇒ 一并重写为以**飞机**为原点的版本。
TestCase {
    id: testCase
    name: "OpsLandingCommonPureFunctions"

    /// 造一个 `fwOrigin` 实参（`landApproachPoint` 的第四参）。仅 F1 消费它。
    /// ⚠️ 不设默认值：这是一件**必须逐格写明**的输入 —— 默认值会让"某一格忘了传"
    ///    变成"传了默认值"，而 F1 的失败形状恰好是**静默算出错位置**。
    function makeOrigin(lat, lon, headingDeg, pushoutM) {
        return { lat: lat, lon: lon, headingDeg: headingDeg, pushoutM: pushoutM }
    }

    //-------------------------------------------------------------------------
    // 常量
    //-------------------------------------------------------------------------
    /// ‼️ 取值本身是契约的一部分：`"land"` 是**沿用**既有 `_pendingAction.kind`，
    ///    改字面量会让 `OpsView.qml` 里所有既有 case 静默落进 default 分支。
    function test_landKindLiterals() {
        compare(OpsCommon.LAND_KIND_KEEP_FW, "keepFwLand")
        compare(OpsCommon.LAND_KIND_TO_MC, "land")
        compare(OpsCommon.LAND_KIND_MC_RESCUE, "mcRescueLand")
    }

    /// 三个 kind 必须两两不同 —— 否则两个维度塌成一个，三种组合里至少两种无法区分。
    function test_landKindsAreDistinct() {
        verify(OpsCommon.LAND_KIND_KEEP_FW !== OpsCommon.LAND_KIND_TO_MC)
        verify(OpsCommon.LAND_KIND_KEEP_FW !== OpsCommon.LAND_KIND_MC_RESCUE)
        verify(OpsCommon.LAND_KIND_TO_MC !== OpsCommon.LAND_KIND_MC_RESCUE)
    }

    function test_mavCmdDoVtolTransitionValue() {
        compare(OpsCommon.MAV_CMD_DO_VTOL_TRANSITION, 3000)
    }

    /// ‼️ `LAND_FW_APPROACH_OFFSET_M` **已删**（见文件头 ①）。
    ///    这一格把"删掉了"钉成契约：哪天有人为了兜底把它加回来，
    ///    就会与后端运营常数**分叉成两个来源**，而分叉是静默的（两边都给得出一个数）。
    function test_fwApproachOffsetConstantIsGone() {
        compare(OpsCommon.LAND_FW_APPROACH_OFFSET_M, undefined)
    }

    //-------------------------------------------------------------------------
    // 维度一：进近方式
    //-------------------------------------------------------------------------
    function test_transitionToMcMatrix() {
        verify(!OpsCommon.landKindTransitionToMc(OpsCommon.LAND_KIND_KEEP_FW))
        verify(OpsCommon.landKindTransitionToMc(OpsCommon.LAND_KIND_TO_MC))
        verify(OpsCommon.landKindTransitionToMc(OpsCommon.LAND_KIND_MC_RESCUE))
    }

    /// 未知 kind 必须**不**被当成需要转换 —— 与「未知一律按最保守」相反，
    /// 这里保守的方向是「不要擅自转 MC」：转 MC 是不可逆的机体动作。
    function test_transitionToMcUnknownKind() {
        verify(!OpsCommon.landKindTransitionToMc(""))
        verify(!OpsCommon.landKindTransitionToMc(undefined))
        verify(!OpsCommon.landKindTransitionToMc("nonsense"))
    }

    //-------------------------------------------------------------------------
    // 维度二「入口语义」**刻意不在这里测**：它的落点是 `_execPendingAction` 的
    // **分支归属**（救济那一档不调 `_execLand`），不是一个可单测的纯函数。
    // 曾把它抽成 `landKindWritesDatabase(kind)` —— 那个写法看着更"整齐"，但函数体是
    // 「kind !== 救济」，任何调用点拿到的都是**编译期常量**（两条路恒真、一条路恒假），
    // 拿它当判据等于零判别力。对应检查改由 Task 5 Step 6 的**静态检查 3** 承担：
    // `case "mcRescueLand"` 的上下文里不出现 `_post(` / `_get(` / `_execLand`。
    //-------------------------------------------------------------------------
    // 第 ① 步：落点与进近点 —— F2/F3（先转 MC）
    //-------------------------------------------------------------------------
    /// 先转 MC ⇒ P **就是机位坐标**（§9.8.4 表第二行；三次实测全是 MC 态）。
    /// 第四参传 `null`：这两支**不读** `fwOrigin`（下一格专门钉这件事）。
    function test_toMcApproachPointEqualsSlot() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC,
                                            47.3979708, 8.5461635, null)
        verify(p !== null)
        compare(p.lat, 47.3979708)
        compare(p.lon, 8.5461635)
    }

    function test_mcRescueApproachPointEqualsSlot() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_MC_RESCUE,
                                            47.3979708, 8.5461635, null)
        verify(p !== null)
        compare(p.lat, 47.3979708)
        compare(p.lon, 8.5461635)
    }

    /// F2/F3 **不读** `fwOrigin`：`null` / 合法值 / 垃圾值三种输入结果必须**一模一样**。
    /// ‼️ 这一格是 2026-10-09 改动之后**新增**的：`fwOrigin` 是给 F1 用的，而
    ///    `_startLandFlow` 是**无条件**构造它再传进来的（不出货 `kind === ...` 判据）。
    ///    于是存在一种新的坏法 —— 有人在 F2/F3 那两支里顺手读了 `fwOrigin`，
    ///    于是"先转 MC"这条路会**看飞机的状态**，而它本该与飞机在哪、朝哪**无关**。
    function test_toMcIgnoresFwOrigin() {
        var a = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 47.0, 8.0, null)
        var b = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 47.0, 8.0,
                                            makeOrigin(47.0, 8.0, 123, 400))
        var c = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 47.0, 8.0,
                                            makeOrigin(0, 0, NaN, -1))
        verify(a !== null && b !== null && c !== null)
        compare(a.lat, b.lat); compare(a.lon, b.lon)
        compare(a.lat, c.lat); compare(a.lon, c.lon)
        // 阳性对照：结果确实**是机位坐标**，不是三个 null 碰巧一起过。
        compare(a.lat, 47.0)
        compare(a.lon, 8.0)
    }

    /// 机位坐标 `0/0` **不是** `landApproachPoint` 对 F2/F3 的判据 —— 这两支是**纯搬运**：
    /// 给什么传什么。这是本文件里最容易被「顺手加一道校验」改坏的一格，故用一条**必绿**
    /// 的用例把它钉成契约。
    ///
    /// ⚠️ **别把这条读成「三条路都不做坐标校验」**（2026-10-08 更正，2026-10-09 仍成立）。
    ///    原先这里写的是「F3 是救济，**零闸**：真在『尚未指派』窗口点了它，就飞向 (0,0)
    ///    ……那是用户明确接受的取舍」—— 那句已被推翻：`_startLandFlow` 里有一道对
    ///    三条路都成立的**落点**坐标闸。两件事各在各的地方：
    ///      · **本函数**（纯换算/搬运）不判**机位**坐标 —— 它没有业务上下文，也无权替
    ///        调用方决定「这个坐标值不值得发出去」；
    ///      · **调用点**判 —— `_execLand`（读库那条）与 `_retargetLandingSlot` 手里都有
    ///        `task`，知道自己拿到的坐标是不是"正常取回"的。
    ///    后端在「无可用接机机位」时下发的正是 `0/0/0`，所以本用例走的是**真实**取值。
    ///
    /// ‼️ 但 **F1 那一支是例外，且这个例外是 2026-10-09 才出现的**：F1 的原点是**飞机**
    ///    坐标，而 `0/0` 的飞机不是"未指派"、是"数据错" ⇒ F1 会回 `null`（见
    ///    `test_keepFwRejectsBadOriginCoords`）。两条判据的对象不同：**机位**不判、
    ///    **飞机原点**判。
    function test_toMcPassesThroughZeroSlotCoordinates() {
        var q = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 0, 0, null)
        verify(q !== null)
        compare(q.lat, 0)
        compare(q.lon, 0)
        var r = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_MC_RESCUE, 0, 0, null)
        verify(r !== null)
        compare(r.lat, 0)
        compare(r.lon, 0)
    }

    //-------------------------------------------------------------------------
    // 第 ① 步：落点与进近点 —— F1（保持 FW）
    //-------------------------------------------------------------------------
    /// 保持 FW ⇒ P = **飞机当前位置沿飞机当前航向**偏 `pushoutM` 米。
    /// 航向 90°（正东）：经度增大、纬度不变。
    /// ‼️ 这条用**不依赖公式的几何事实**验方向，不拿同一个方位约定去比同一个方位约定
    ///    （那样约定错则代码与用例一起错）。
    function test_keepFwApproachPointEast() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                            makeOrigin(47.0, 8.0, 90, 400))
        verify(p !== null)
        verify(p.lon > 8.0)
        verify(Math.abs(p.lat - 47.0) < 0.001)
    }

    /// 航向 0°（正北）：纬度增大、经度不变。
    ///
    /// ‼️ 这一格**同时**钉住了本函数唯一一处"看不出来"的地方：`VehicleFactGroup` 的
    ///    `heading` Fact 没有 `defaultValue` ⇒ 首帧 ATTITUDE 之前 `heading.value` 就是 `0`，
    ///    而 `0°` 是**合法正北**，两者数值上不可分辨。本函数**刻意**不假装能分辨
    ///    （`OpsCommon.js:2328` 明文禁止拿 `heading === 0` 当"没填"）
    ///    ⇒ 这里必须**放行**、算出朝正北的 P。哪天它变成回 `null`，说明有人加了
    ///    `heading === 0` 那道闸 —— 那会让**恰好朝正北**的飞机永远降落不了。
    function test_keepFwApproachPointNorth() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                            makeOrigin(47.0, 8.0, 0, 400))
        verify(p !== null)
        verify(p.lat > 47.0)
        verify(Math.abs(p.lon - 8.0) < 0.001)
    }

    /// 距离**就是传进来的 `pushoutM`**，不是写死的数。
    ///
    /// ‼️ 必须用**两个不同**的取值：只测一个（比如 400）的话，"函数里写死 400" 与
    ///    "函数真的用了实参" 给出**同一个**结果 ⇒ 本格零判别力。这正是 2026-10-09
    ///    把常量搬进运营常数表之后**新增**的风险：以前距离是本文件的常量，
    ///    现在是实参，而实参可以**被忽略**。
    /// 容 ±1 m（球面近似的舍入）。
    function test_keepFwPushoutMIsUsedAsGiven() {
        var a = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                            makeOrigin(47.0, 8.0, 90, 400))
        var b = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                            makeOrigin(47.0, 8.0, 90, 150))
        verify(a !== null && b !== null)
        var da = OpsCommon._greatCircleM(47.0, 8.0, a.lat, a.lon)
        var db = OpsCommon._greatCircleM(47.0, 8.0, b.lat, b.lon)
        verify(Math.abs(da - 400) < 1.0)
        verify(Math.abs(db - 150) < 1.0)
        // 阳性对照：两个结果**必须不同** —— 若相同，说明上面两条里有一条是碰巧过的。
        verify(Math.abs(da - db) > 100)
    }

    /// ‼️ **原点是飞机，不是机位**（2026-10-09 裁定①）。这是本次改动最容易被人"改回去"
    ///    的一格，故单独钉一条：同一个 `fwOrigin`、两个**天差地别**的机位 ⇒ P **完全相同**。
    ///    并同时验证 P 落在**飞机**附近、而不是机位附近 —— 只验"两者相同"的话，
    ///    一个"原点取机位、且完全忽略机位实参"的错误实现也能过。
    function test_keepFwOriginIsAircraftNotSlot() {
        var origin = makeOrigin(47.0, 8.0, 90, 400)
        var near = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.05, origin)
        var far = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 0, 0, origin)
        verify(near !== null && far !== null)
        compare(near.lat, far.lat)
        compare(near.lon, far.lon)
        // P 离**飞机**约 400 m……
        verify(Math.abs(OpsCommon._greatCircleM(47.0, 8.0, near.lat, near.lon) - 400) < 1.0)
        // ……而离那个近机位（47.0, 8.05 ≈ 3.8 km）远不止 400 m —— 若原点还是机位，
        // 这一条会红。
        verify(OpsCommon._greatCircleM(47.0, 8.05, near.lat, near.lon) > 3000)
    }

    /// `fwOrigin` 整个缺失（`null` / `undefined`）⇒ `null`。
    /// 调用方必须当**失败**处理：若在这里回落成机位坐标，就会组出一条"保持 FW"
    /// 却以机位为进近点的航线 —— 那一格**从未被端到端验证过**
    /// （§9.5.3 的实测表：只有"飞机前方偏移"那一格有全链路证据）。
    function test_keepFwRejectsMissingOrigin() {
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                           47.0, 8.0, null) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                           47.0, 8.0, undefined) === null)
    }

    /// 飞机坐标不可用 ⇒ `null`。闸是 `isValidWaypoint`（`isFinite && !== 0`），
    /// **不是** `coordinate.isValid`（那个对 (0,0) 为真，拦不住几内亚湾）。
    /// ⚠️ 这里的 `0/0` 判据与 `test_toMcPassesThroughZeroSlotCoordinates` 看似矛盾，
    ///    其实判的是**两个不同的对象**：本格判**飞机原点**（0/0 = 数据错 ⇒ 拒），
    ///    那一格判**机位**（0/0 = 后端在"无可用机位"时的真实下发 ⇒ 原样传出，由调用方判）。
    function test_keepFwRejectsBadOriginCoords() {
        // 0/0 —— `_finiteNumber` 放行、`isValidWaypoint` 拦下。这正是不用前者做闸的理由。
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(0, 0, 90, 400)) === null)
        // 只有一个为 0（半球边界上的真实坐标，但 `isValidWaypoint` 一并拦下）——
        // ⚠️ 这是本闸**已知的过拒**：赤道/本初子午线上的合法坐标会被拒。
        //    取舍：那两处的飞机在**本项目的作业区域内不存在**，而"0 当哨兵"是后端
        //    全仓的既有约定（`isValidWaypoint` 已被起飞端在用）。
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(0, 47.0, 90, 400)) === null)
        // 非数 / 缺列
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(NaN, 8.0, 90, 400)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(undefined, 8.0, 90, 400)) === null)
        // 阳性对照：**同一个** origin 只把坐标换成合法的，必须算得出 —— 否则上面几条
        // 可能是在"这一支恒回 null"的实现下过的。
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, 400)) !== null)
    }

    /// 航向不可用（`null` / NaN / 缺列 / 字符串）⇒ `null`。
    /// ‼️ 与 `test_keepFwApproachPointNorth` 成对：**`0` 是合法航向、不是"没有"**。
    function test_keepFwRejectsBadHeading() {
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, null, 400)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, NaN, 400)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, undefined, 400)) === null)
        // `_finiteNumber` 要求 `typeof === "number"` ⇒ 数字**字符串**也要拦住
        // （JSON 里来的值曾经是字符串，见 `OpsView.qml` 对运营常数的 `Number(...)`）。
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, "90", 400)) === null)
    }

    /// 推远距离不可用 ⇒ `null`。**`<= 0` 必须拒**，这是与几何函数 `takeoffTransitionPoint`
    /// 的**刻意分叉**：那个函数把 `distM === 0` 当**合法**（起飞端确实需要"偏移 0"这一档），
    /// 但降落端不是 —— `pushoutM === 0` 会让 P 落在飞机正上方 ⇒ 航线第一条腿零长度
    /// ⇒ 恰好退回本改动要消灭的那个形状（飞机在盘旋圈内），而且**全程静默**
    /// （PX4 照收、界面无痕）。所以这一格同时钉住"谁在拒"：
    /// ⚠️ 若哪天有人把这行闸删掉、指望几何函数兜底，`0` 会**通过**并算出 P == 飞机位置。
    function test_keepFwRejectsBadPushout() {
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, 0)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, -5)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, NaN)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, null)) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 47.0, 8.0,
                                           makeOrigin(47.0, 8.0, 90, "400")) === null)
        // ⚠️ 对照：`takeoffTransitionPoint` 本身**接受** 0 —— 上面第一条拒的**不是**它。
        verify(OpsCommon.takeoffTransitionPoint(47.0, 8.0, 90, 0) !== null)
    }

    //-------------------------------------------------------------------------
    // 未知 kind
    //-------------------------------------------------------------------------
    /// 未知 kind ⇒ `null`（不猜）。同 `test_transitionToMcUnknownKind` 的理由。
    /// `fwOrigin` 传一个**完全合法**的值：证明回 `null` 是**因为 kind**，
    /// 不是因为输入恰好缺了东西（否则这一格会被"F1 的闸"顺带弄绿，零判别力）。
    function test_unknownKindGivesNull() {
        var ok = makeOrigin(47.0, 8.0, 90, 400)
        verify(OpsCommon.landApproachPoint("nonsense", 47.0, 8.0, ok) === null)
        verify(OpsCommon.landApproachPoint("", 47.0, 8.0, ok) === null)
        verify(OpsCommon.landApproachPoint(undefined, 47.0, 8.0, ok) === null)
    }
}
