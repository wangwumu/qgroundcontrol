import QtQuick
import QtTest

// ⚠️ 相对路径 import：`QGCQmlQuickTests` **没有 link QGC 的 QML 资源**（它的 CMakeLists 只链
//    Qt6::{QuickTest,Qml,Gui,Quick}），所以 `import QGroundControl...` 在这里必然失败。
//    而 `QUICK_TEST_SOURCE_DIR` 指向的是**源码目录**（不是构建目录），测试文件按文件系统 URL
//    加载 ⇒ 相对路径能穿回仓库根。深度：tests → QmlTesting → UnitTestFramework → test → 根。
import "../../../../src/OpsView/OpsCommon.js" as OpsCommon

/// 降落端统一框架（设计稿 §9.8）的两个纯函数与五个常量。
///
/// ‼️ 这一组用例钉的是**判据本身**，不是调用点：**进近方式**这个维度在 `OpsCommon.js` 里
///    由 `landKindTransitionToMc` 与 `landApproachPoint` 两个函数编码，QML 只许调它们；
///    另一个维度（**入口语义**：正常降落读库写库 / 救济不读不写）落在 `OpsView.qml` 的
///    两条入口上，不在本文件，故本文件不覆盖它。
///    判据写错的后果不是崩溃，
///    而是「三条路里有一条静默走了另一条的语义」—— 例如救济路径误写数据库。
TestCase {
    id: testCase
    name: "OpsLandingCommonPureFunctions"

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

    function test_fwApproachOffsetValue() {
        compare(OpsCommon.LAND_FW_APPROACH_OFFSET_M, 300)
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
    // 第 ① 步：落点与进近点
    //-------------------------------------------------------------------------
    /// 保持 FW ⇒ P = 机位沿机位朝向偏 300 m。朝向 90°（正东）：经度增大、纬度不变。
    /// ‼️ 这条用**不依赖公式的几何事实**验方向，不拿同一个方位约定去比同一个方位约定
    ///    （那样约定错则代码与用例一起错）。
    function test_keepFwApproachPointEast() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                            47.0, 8.0, 90)
        verify(p !== null)
        verify(p.lon > 8.0)
        verify(Math.abs(p.lat - 47.0) < 0.001)
    }

    /// 朝向 0°（正北）：纬度增大、经度不变。
    function test_keepFwApproachPointNorth() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                            47.0, 8.0, 0)
        verify(p !== null)
        verify(p.lat > 47.0)
        verify(Math.abs(p.lon - 8.0) < 0.001)
    }

    /// 距离确实是 300 m（±1 m，容球面近似的舍入）。
    function test_keepFwApproachPointDistance() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                            47.0, 8.0, 90)
        verify(p !== null)
        var d = OpsCommon._greatCircleM(47.0, 8.0, p.lat, p.lon)
        verify(Math.abs(d - 300) < 1.0)
    }

    /// 先转 MC ⇒ P **就是机位坐标**（§9.8.4 表第二行；三次实测全是 MC 态）。
    /// ‼️ 与上一条形成对照：同一个机位、同一个朝向，两个 kind 必须给出**不同**的 P。
    function test_toMcApproachPointEqualsSlot() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC,
                                            47.3979708, 8.5461635, 90)
        verify(p !== null)
        compare(p.lat, 47.3979708)
        compare(p.lon, 8.5461635)
    }

    function test_mcRescueApproachPointEqualsSlot() {
        var p = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_MC_RESCUE,
                                            47.3979708, 8.5461635, 90)
        verify(p !== null)
        compare(p.lat, 47.3979708)
        compare(p.lon, 8.5461635)
    }

    /// 朝向无效（`null` / NaN / 非数字）时，保持 FW 这一支算不出 P ⇒ 必须回 `null`。
    /// ‼️ 回 `null` 是契约：调用方必须当**失败**处理。若在这里回落成机位坐标，
    ///    就会组出一条 P == 机位的「保持 FW」航线，而那一格**从未被端到端验证过**
    ///    （§9.5.3 的实测表：只有 300 m 那一格有全链路证据）。
    function test_keepFwApproachPointBadHeading() {
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                           47.0, 8.0, null) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                           47.0, 8.0, NaN) === null)
        verify(OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW,
                                           47.0, 8.0, undefined) === null)
    }

    /// ‼️ 坐标 `0/0` **不是** `landApproachPoint` 的判据 —— 这是本文件里最容易被
    ///    「顺手加一道校验」改坏的一格，故用一条**必绿**的用例把它钉成契约。
    ///    本函数是**纯几何换算**：给它机位坐标，它算进近点，`0/0` 是合法经纬度、照算不误。
    ///
    /// ⚠️ **别把这条读成「三条路都不做坐标校验」**（2026-10-08 更正）。原先这里写的是
    ///    「F3 是救济，**零闸**：真在『尚未指派』窗口点了它，就飞向 (0,0) ……那是用户明确
    ///    接受的取舍」—— 那句已被推翻：`_startLandFlow` 里有一道对三条路都成立的落点坐标闸。
    ///    两件事各在各的地方：
    ///      · **本函数**（纯换算）不判 `0/0` —— 它没有业务上下文，也无权替调用方决定
    ///        「这个坐标值不值得发出去」；
    ///      · **调用点**（`OpsView.qml` 的 `_startLandFlow`）判 —— 它手里有 `task`，
    ///        知道这个坐标是不是「正常取回」的。
    ///    所以本用例仍**必绿**，而坐标闸在 QML 那一侧。
    ///
    /// 依据（用户 2026-10-08 裁定逐字）：「这里的**不判，前提是 qgc 取出机位坐标是正常的、
    /// 无错误的取回**」—— 「不判」的辖区是**业务状态机**与**QGC 指令执行进度**，
    /// 「坐标有没有正常取回」是「不判」赖以成立的**前提**，不在辖区内。
    ///
    /// 后端在「无可用接机机位」时下发的正是 `0/0/0`，所以本用例走的是**真实**取值。
    function test_zeroCoordinatesAreNotThisFunctionsConcern() {
        // 先转 MC 的两支：原样传出，与救济/正常无关。
        var r = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_MC_RESCUE, 0, 0, 90)
        verify(r !== null)
        compare(r.lat, 0)
        compare(r.lon, 0)
        var q = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 0, 0, 90)
        verify(q !== null)
        compare(q.lat, 0)
        compare(q.lon, 0)
        // 保持 FW 那一支：0/0 是合法经纬度（几内亚湾），照常算出偏 300 m 的 P。
        // ⚠️ 哪天它回了 null，说明有人把坐标闸挪进了本函数 —— 那会让**调用方**失去
        //    「坐标是不是正常取回」的判定权（本函数看不见 `task`，判不了这件事）。
        var k = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_KEEP_FW, 0, 0, 90)
        verify(k !== null)
        verify(Math.abs(OpsCommon._greatCircleM(0, 0, k.lat, k.lon) - 300) < 1.0)
    }

    /// 先转 MC 那一支**不读朝向**（§9.5.9 第 1、2 条：降落端不管朝向）。
    /// ⇒ 朝向缺失也必须能算出 P。这条与 `test_keepFwApproachPointBadHeading` 成对。
    function test_toMcIgnoresHeading() {
        var a = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 47.0, 8.0, null)
        var b = OpsCommon.landApproachPoint(OpsCommon.LAND_KIND_TO_MC, 47.0, 8.0, 123)
        verify(a !== null && b !== null)
        compare(a.lat, b.lat)
        compare(a.lon, b.lon)
    }

    /// 未知 kind ⇒ `null`（不猜）。同 `test_transitionToMcUnknownKind` 的理由。
    function test_unknownKindGivesNull() {
        verify(OpsCommon.landApproachPoint("nonsense", 47.0, 8.0, 90) === null)
        verify(OpsCommon.landApproachPoint("", 47.0, 8.0, 90) === null)
    }
}
