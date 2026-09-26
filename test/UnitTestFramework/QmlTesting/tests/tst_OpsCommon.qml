import QtQuick
import QtTest

// ⚠️ 相对路径 import：`QGCQmlQuickTests` **没有 link QGC 的 QML 资源**（它的 CMakeLists 只链
//    Qt6::{QuickTest,Qml,Gui,Quick}），所以 `import QGroundControl...` 在这里必然失败。
//    而 `QUICK_TEST_SOURCE_DIR` 指向的是**源码目录**（不是构建目录），测试文件按文件系统 URL
//    加载 ⇒ 相对路径能穿回仓库根。深度：tests → QmlTesting → UnitTestFramework → test → 根。
import "../../../../src/OpsView/OpsCommon.js" as OpsCommon

/// `OpsCommon.js` 纯函数的用例（机载告警行 + 航点→mission 两个纯函数组）。
/// 纯函数只吃 JS 实参，所以这里的 mock 是**故意的**：函数体对 `vehicles` 的用法是
/// 鸭子类型（`.count` + `.get(i)`），与真实的 `QmlObjectListModel` 同形。
TestCase {
    id: testCase
    name: "OpsCommonPureFunctions"

    //-------------------------------------------------------------------------
    // 夹具
    //-------------------------------------------------------------------------
    /// 造一个与 `QmlObjectListModel` **同形**的 vehicles：`.count` + `.get(i)`。
    /// ‼️ 不能直接用 JS 数组当 mock——`alertRows` 里写的是 `vehicles.count`，
    ///    数组上那是 `undefined` ⇒ 函数会静默返回空列表，而用例却以为"没告警"。
    ///    假夹具让真代码走对分支，是这类测试最容易失效的地方。
    function _vehicles(list) {
        return {
            count: list.length,
            get: function(i) { return list[i] }
        }
    }

    /// 造一架与 `Vehicle` **同形**的 mock。
    /// ⚠️ `deviceID` 是 `Q_INVOKABLE uint deviceID()`——**方法不是属性**（`OpsCommon.js`
    ///    的 `matchDeviceToVehicle` 注释记录了同一个坑）。这里照方法写，才测得出括号写漏。
    /// ⚠️ `id` 与 `statusTextMessages` 是 `Q_PROPERTY`——**属性**。与上面形式不同是既成事实。
    /// ‼️ 告警走 `statusTextMessages`（`Vehicle` 上的 QVariantList）而**不是**
    ///    `statusTextHandler.messages`：`Vehicle` 只前向声明了 `StatusTextHandler`
    ///    （`Vehicle.h:62`），把裸指针暴露给 QML 要过 MOC 对不完整类型的处理；转发
    ///    数据则 QML 根本不需要认识那个类型。mock 必须跟着真实形状走，否则测的是
    ///    一个不存在的接口。
    function _vehicle(id, deviceId, msgs) {
        return {
            id: id,
            deviceID: function() { return deviceId },
            statusTextMessages: msgs
        }
    }

    function _msg(iso, severity, text) {
        return { timestamp: iso, severity: severity, text: text }
    }

    /// 造一架与后端 `opsMonitorDevice` **同形**的 device（`gcs_server/handlers/ops.go`）。
    /// ⚠️ 只列被 `markerColor` 及其下游真正用到的键：`uav_status`（兜底色）、`event`（异常色）、
    ///    `task_id`（关联 key）。多写会让下一个人以为函数还读了别的字段。
    function _device(uavStatus, taskId, event) {
        return {
            device_id: 9103,
            uav_id: 9103,
            uav_no: "UAV-001",
            task_no: "QGC-001",
            uav_status: uavStatus,
            signed_in: true,
            task_id: taskId,
            route_id: 1,
            event: event || null,
            latest: null
        }
    }

    /// 造一条与 ③ `tasks[]` 同形的 task。
    function _task(taskId, status) {
        return { task_id: taskId, status: status, latest: null }
    }

    //-------------------------------------------------------------------------
    // 机制探针
    //-------------------------------------------------------------------------
    /// 先钉住"能 import 到库文件"这件事本身。若这条红了而其余全绿，说明是 import 路径
    /// 而不是被测逻辑出了问题——两者失败形状完全不同，混在一起会浪费一轮排查。
    function test_libraryIsReachable() {
        verify(typeof OpsCommon.alertRows === "function",
               "OpsCommon.alertRows 未导出（或 JS 库 import 失败）")
    }

    //-------------------------------------------------------------------------
    // severity 文案
    //-------------------------------------------------------------------------
    function test_severityLabel_data() {
        return [
            { tag: "emergency", value: 0, expect: "严重" },
            { tag: "alert",     value: 1, expect: "严重" },
            { tag: "critical",  value: 2, expect: "严重" },
            { tag: "error",     value: 3, expect: "严重" },
            { tag: "warning",   value: 4, expect: "警告" },
            { tag: "notice",    value: 5, expect: "提示" },
            { tag: "info",      value: 6, expect: "信息" },
            { tag: "debug",     value: 7, expect: "信息" },
        ]
    }

    /// `MAV_SEVERITY` 八档 → 中文四档（§6.3）。八档全测：只测 4/6 的话，把 0~3 写漏
    /// 也照样全绿，而"严重"恰恰是最该显示对的那一档。
    function test_severityLabel(data) {
        compare(OpsCommon.severityLabel(data.value), data.expect)
    }

    /// 未知值不能漏成空串或裸数字（界面不得出现裸枚举）。
    function test_severityLabel_unknownIsNotRaw() {
        var s = OpsCommon.severityLabel(99)
        verify(s !== "" && s !== "99", "未知 severity 回落成了空串或裸枚举：" + s)
    }

    //-------------------------------------------------------------------------
    // alertRows：聚合
    //-------------------------------------------------------------------------
    function test_emptyVehiclesYieldsNoRows() {
        compare(OpsCommon.alertRows(_vehicles([]), {}).length, 0)
    }

    /// 载具**没有** `statusTextMessages`（键缺失 / 为 null）时跳过它，而不是抛异常。
    /// ⚠️ 真实世界里这条路径存在：`Vehicle` 的 `statusTextMessages` 在
    ///    `_createStatusTextHandler()` 跑起来之前是空的，且 QML 侧一旦有人传进
    ///    别的 QObject（比如那个喂仪表的 `_mockVehicle`），也走这里。
    function test_vehicleWithoutMessages() {
        var vs = _vehicles([{ id: 7, deviceID: function() { return 9103 } }])
        compare(OpsCommon.alertRows(vs, {}).length, 0)
    }

    /// 基本聚合 + 用 deviceID 在索引里补 `uav_no`。
    function test_mapsDeviceToUavNo() {
        var vs = _vehicles([_vehicle(1, 9103, [_msg("2026-09-23T01:02:03.000Z", 4, "低电量")])])
        var idx = OpsCommon.deviceIndexByDeviceID([{ device_id: 9103, uav_no: "UAV-001" }])
        var rows = OpsCommon.alertRows(vs, idx)
        compare(rows.length, 1)
        compare(rows[0].who, "UAV-001")
        compare(rows[0].text, "低电量")
        compare(rows[0].severity, 4)
        compare(rows[0].time, "2026-09-23T01:02:03.000Z")
    }

    /// ‼️ §6.2 步骤 4：**找不到也要保留这一行**，用 `vehicle.id`（systemID）标识。
    /// 场景是"飞机在发告警但不在监控清单里"（落地后转 PARKED ⇒ 从 devices[] 消失，
    /// 但 QGC 的 Vehicle 不断开）——那正是最需要看见告警的时刻。
    /// 这条用例是**阴性对照的对照组**：把"保留"改成"跳过"必须让它变红。
    function test_unknownDeviceStillKeepsRow() {
        var vs = _vehicles([_vehicle(42, 9103, [_msg("2026-09-23T01:02:03.000Z", 3, "EKF 异常")])])
        var rows = OpsCommon.alertRows(vs, {})     // 空索引 ⇒ 找不到
        compare(rows.length, 1, "找不到 device 的那一行被丢掉了")
        verify(rows[0].who.indexOf("42") >= 0,
               "找不到 device 时应当用 systemID 标识，实际是：" + rows[0].who)
    }

    /// `device_id` 为 0（未学到映射）⇒ 索引里不该有 0 号键，也就找不到 ⇒ 走 systemID 分支。
    /// 与上一条同族，但走的是**另一条**代码路径（`deviceIndexByDeviceID` 的过滤）。
    function test_zeroDeviceIdIsNotIndexed() {
        var idx = OpsCommon.deviceIndexByDeviceID([{ device_id: 0, uav_no: "不该被认领" }])
        var vs = _vehicles([_vehicle(5, 0, [_msg("2026-09-23T01:02:03.000Z", 6, "x")])])
        var rows = OpsCommon.alertRows(vs, idx)
        compare(rows.length, 1)
        compare(rows[0].who, "#5")
    }

    /// 跨机按时间**倒序**合并（§6.2 步骤 5）。
    function test_mergesAcrossVehiclesNewestFirst() {
        var vs = _vehicles([
            _vehicle(1, 9103, [_msg("2026-09-23T01:00:00.000Z", 6, "旧")]),
            _vehicle(2, 9104, [_msg("2026-09-23T02:00:00.000Z", 6, "新")]),
        ])
        var rows = OpsCommon.alertRows(vs, {})
        compare(rows.length, 2)
        compare(rows[0].text, "新")
        compare(rows[1].text, "旧")
    }

    /// 每机只取**最近** N 条（§6.2 步骤 2）——是末尾 N 条不是前 N 条。
    /// `StatusTextHandler` 是 append，所以"最近"= 数组尾部。取反了的话界面上会显示
    /// 开机时那几条老告警，而最近的告警一条都看不见（且不报错）。
    function test_perVehicleLimitTakesNewest() {
        var many = []
        for (var i = 0; i < 30; i++) {
            many.push(_msg("2026-09-23T01:00:" + (i < 10 ? "0" : "") + i + ".000Z", 6, "m" + i))
        }
        var vs = _vehicles([_vehicle(1, 9103, many)])
        var rows = OpsCommon.alertRows(vs, {}, 5)
        compare(rows.length, 5)
        compare(rows[0].text, "m29")
        compare(rows[4].text, "m25")
    }

    /// 总行数上限截断的是**最旧的**那些（倒序之后从尾部切）。
    function test_totalLimitKeepsNewest() {
        var vs = _vehicles([
            _vehicle(1, 9103, [_msg("2026-09-23T01:00:00.000Z", 6, "旧")]),
            _vehicle(2, 9104, [_msg("2026-09-23T02:00:00.000Z", 6, "新")]),
        ])
        var rows = OpsCommon.alertRows(vs, {}, 20, 1)
        compare(rows.length, 1)
        compare(rows[0].text, "新")
    }

    /// `timestamp` 缺失或不可解析时不能把整张表排乱（NaN 参与减法会让顺序成为未定义）。
    function test_unparsableTimestampDoesNotBreakOrdering() {
        var vs = _vehicles([_vehicle(1, 9103, [
            _msg("", 6, "无时间戳"),
            _msg("2026-09-23T02:00:00.000Z", 6, "有时间戳"),
        ])])
        var rows = OpsCommon.alertRows(vs, {})
        compare(rows.length, 2)
        compare(rows[0].text, "有时间戳", "NaN 时间戳破坏了倒序")
    }

    /// 航班号与机号**一起**带出来（§6.2 步骤 3 要求每行含 `task_no`）。
    /// ⚠️ 两者必须来自**同一次**查表：分两次查的话，两次之间索引若换了对象，
    ///    同一行上的航班号与机号就会来自不同的快照。
    function test_mapsDeviceToTaskNo() {
        var vs = _vehicles([_vehicle(1, 9103, [_msg("2026-09-23T01:02:03.000Z", 4, "低电量")])])
        var idx = OpsCommon.deviceIndexByDeviceID([
            { device_id: 9103, uav_no: "UAV-001", task_no: "QGC-777" }])
        var rows = OpsCommon.alertRows(vs, idx)
        compare(rows[0].who, "UAV-001")
        compare(rows[0].taskNo, "QGC-777")
    }

    /// 找不到 device、或该 device 没有 `task_no` ⇒ **空串**，不是 `undefined`。
    /// ‼️ `undefined` 直接喂给 QML 的 `text` 会渲染出字面量 "undefined"（既有教训一族：
    ///    界面不该因为后端少一个字段就长出一个奇怪的词）。
    function test_taskNoEmptyWhenUnknown() {
        var vs = _vehicles([_vehicle(42, 9103, [_msg("2026-09-23T01:02:03.000Z", 3, "EKF 异常")])])
        compare(OpsCommon.alertRows(vs, {})[0].taskNo, "", "找不到 device 时 taskNo 应为空串")
        var idxNoTask = OpsCommon.deviceIndexByDeviceID([{ device_id: 9103, uav_no: "UAV-001" }])
        compare(OpsCommon.alertRows(vs, idxNoTask)[0].taskNo, "", "device 无 task_no 时应为空串")
    }

    //-------------------------------------------------------------------------
    // taskById / markerColor：地图 L3 飞机 marker 的关联与着色
    // （用户 2026-09-23 定的口径：地图上的航班与中段列表的状态点**同色**）
    //-------------------------------------------------------------------------

    function test_taskById_findsMatch() {
        var ts = [_task(7, "IN_FLIGHT"), _task(8, "LANDING")]
        compare(OpsCommon.taskById(ts, 8).status, "LANDING")
    }

    /// 找不到 ⇒ **`null`**（调用方据此走兜底），且输入为空/为 null 也不能抛。
    /// ⚠️ `task_id` 为 0（未指派）同样按找不到处理。
    function test_taskById_missingReturnsNull() {
        verify(OpsCommon.taskById([_task(7, "IN_FLIGHT")], 99) === null, "不存在的 task_id 应当回 null")
        verify(OpsCommon.taskById([], 7) === null, "空 tasks 应当回 null")
        verify(OpsCommon.taskById(null, 7) === null, "tasks 为 null 应当回 null")
        verify(OpsCommon.taskById([_task(7, "IN_FLIGHT")], 0) === null, "task_id=0（未指派）应当回 null")
    }

    /// 两侧类型可能不同（JSON 数字 vs 字符串）⇒ 必须按**数值**比较。
    function test_taskById_comparesNumerically() {
        compare(OpsCommon.taskById([_task("7", "LANDING")], 7).status, "LANDING")
    }

    /// 异常（备降/回航/迫降）优先于任何航班状态色——与中段列表的置顶徽标**恒等色**。
    /// ⚠️ 判据特意用 `DIVERT`（橙）而**不是** `FORCED_LANDING`：后者与 `statusColor` 的
    ///    超时红同为 `#ff3b3b`，撞色会让"异常优先"这条断言即使实现退化也照样绿。
    function test_markerColor_abnormalBeatsTaskStatus() {
        var d = _device("IN_FLIGHT", 7, { type: "DIVERT" })
        compare(OpsCommon.markerColor(d, _task(7, "IN_FLIGHT"), 0, {}), "#ff9800")
    }

    /// 无异常 ⇒ 吃**航班**状态色（这次改动的目的：地图与中段列表状态点同色）。
    function test_markerColor_usesTaskStatus() {
        var d = _device("IN_FLIGHT", 7, null)
        compare(OpsCommon.markerColor(d, _task(7, "IN_FLIGHT"), 0, {}), "#ffc107")
    }

    /// ‼️ 这条钉的是本次改动**唯一可见的行为差异**：交接超时红。
    /// 超时的判据来自 **task**，用**飞机**状态着色时这一支根本不可能出现。
    function test_markerColor_carriesHandoverTimeout() {
        var d = _device("IN_FLIGHT", 7, null)
        var h = { 7: { task_id: 7, phase_to: "ROUTE", deadline_at: "2026-09-23 00:00:00" } }
        compare(OpsCommon.markerColor(d, _task(7, "IN_FLIGHT"), Date.parse("2026-09-23T01:00:00Z"), h),
                "#ff3b3b")
    }

    /// ‼️ 关联不到 task 时兜底回 `deviceColor`，**不能**兜成 `statusColor(null)` 的蓝。
    /// 判据是 `RETURNING`：`deviceColor` 给黄，而 `statusColor(null)` 会给 `#3b9cff`
    /// —— 后者会让"关联失败"在界面上看起来像"一切正常"。
    function test_markerColor_fallsBackToDeviceColorWhenTaskMissing() {
        var d = _device("RETURNING", 7, null)
        compare(OpsCommon.markerColor(d, null, 0, {}), "#ffc107")
    }

    //-------------------------------------------------------------------------
    // minEnclosingCircle：本站机位范围的**最小包围圆**（地图圆圈图层用）
    // （用户 2026-09-23 定：「在当前登陆站点显示一个能够圈进所有机位范围的圆圈」）
    //-------------------------------------------------------------------------

    /// 造一个与 `/api/sites/:id/slots` **同形**的机位。
    /// ⚠️ 只列被 `minEnclosingCircle` 真正读到的键（`lat`/`lon`）。接口还下发
    ///    `id`/`slot_code`/`status` 等，但**几何不该依赖它们**——多写会让下一个人
    ///    以为算法还读了别的字段，从而不敢动那些字段。
    function _slot(lat, lon) {
        return { lat: lat, lon: lon }
    }

    /// **独立**的球面距离（米）。刻意**不**复用实现里的等距圆柱投影——两套公式
    /// 不同源，"覆盖性"断言才是交叉验证，而不是拿实现的口径验实现。
    /// 几百米量级下两者差 < 1 m，故各用例的容差按 1~2 m 给。
    function _distM(la1, lo1, la2, lo2) {
        var R = 6371000.0
        var p1 = la1 * Math.PI / 180, p2 = la2 * Math.PI / 180
        var dp = (la2 - la1) * Math.PI / 180
        var dl = (lo2 - lo1) * Math.PI / 180
        var h = Math.sin(dp / 2) * Math.sin(dp / 2) +
                Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2)
        return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)))
    }

    /// 最小包围圆的**两条定义性质**，每个构型都要成立：
    ///   ① 覆盖——所有点到圆心的距离 ≤ 半径；
    ///   ② 紧致——至少有一个点**落在圆上**（否则半径还能再缩，那就不是"最小"）。
    /// ⚠️ 只验①是不够的：一个"半径取 1000 公里"的实现永远满足①。
    /// `tag` 用来在批量调用时指出**是哪一个点集**失败（可选；单条用例不传）。
    function _verifyCovers(circle, slots, tag) {
        var t = tag ? ("[" + tag + "] ") : ""
        verify(circle !== null, t + "有效输入不该回 null")
        var maxD = 0
        for (var i = 0; i < slots.length; i++) {
            var d = _distM(slots[i].lat, slots[i].lon, circle.lat, circle.lon)
            if (d > maxD) maxD = d
        }
        verify(maxD <= circle.radiusM + 1.0,
               t + "有点落在圆外：最远 " + maxD.toFixed(2) + " m > 半径 " + circle.radiusM.toFixed(2) + " m")
        verify(maxD >= circle.radiusM - 1.0,
               t + "半径 " + circle.radiusM.toFixed(2) + " m 比最远点 " + maxD.toFixed(2) +
               " m 还大 —— 圆还能再缩，不是最小包围圆")
    }

    /// 确定性伪随机（MINSTD）。
    /// ‼️ **不用 `Math.random()`**：随机构型一旦失败必须能复现，否则红灯退化成"偶发"，
    ///    下一个人只会重跑一次然后当它没发生过。`48271 × 2³¹` 在 2⁵³ 以内，无精度丢失。
    function _lcg(seed) {
        var s = seed
        return function() {
            s = (s * 48271) % 2147483647
            return s / 2147483647
        }
    }

    function test_minEnclosingCircle_nullAndEmptyReturnNull() {
        verify(OpsCommon.minEnclosingCircle(null) === null, "null 输入应当回 null")
        verify(OpsCommon.minEnclosingCircle([]) === null, "空数组应当回 null")
    }

    /// 坐标无效（(0,0) / NaN / 缺字段）一律跳过；**全无效 ⇒ null**。
    /// ‼️ (0,0) 是"没有定位"的常见缺省值，与 `isValidWaypoint` 同一口径。放进去会让
    ///    圆心被拉到几内亚湾、半径变成几千公里——而界面上只是"圈变大了"，看不出是错的。
    function test_minEnclosingCircle_skipsInvalidAndNullsWhenNoneValid() {
        var bad = [_slot(0, 0), _slot(NaN, 117), _slot(40, NaN), _slot(undefined, undefined)]
        verify(OpsCommon.minEnclosingCircle(bad) === null, "全无效输入应当回 null")
    }

    /// 混入无效点**不改变**结果。阴性对照：把过滤删掉，这条必红。
    function test_minEnclosingCircle_invalidPointsDoNotPullCircle() {
        var good = [_slot(40.0, 117.0), _slot(40.0, 117.01), _slot(40.007, 117.005)]
        var mixed = good.concat([_slot(0, 0), _slot(NaN, NaN)])
        var c1 = OpsCommon.minEnclosingCircle(good)
        var c2 = OpsCommon.minEnclosingCircle(mixed)
        compare(c2.count, c1.count, "无效点被算进了点数")
        verify(Math.abs(c2.radiusM - c1.radiusM) < 0.01, "无效点改变了半径")
        verify(Math.abs(c2.lat - c1.lat) < 1e-9, "无效点改变了圆心纬度")
        verify(Math.abs(c2.lon - c1.lon) < 1e-9, "无效点改变了圆心经度")
    }

    /// 单点 ⇒ **半径 0**。给最小可见半径是**调用方**（地图图层）的事，算法不掺这个私货
    /// ——否则"只有一个机位的站点"画出来的圈会比真实范围大。
    function test_minEnclosingCircle_singlePointHasZeroRadius() {
        var c = OpsCommon.minEnclosingCircle([_slot(40.140578, 117.121397)])
        compare(c.count, 1)
        verify(Math.abs(c.lat - 40.140578) < 1e-9, "单点圆心纬度不是该点")
        verify(Math.abs(c.lon - 117.121397) < 1e-9, "单点圆心经度不是该点")
        verify(c.radiusM < 0.01, "单点半径应为 0，实际 " + c.radiusM)
    }

    /// 两点 ⇒ 圆心是中点、半径是半距（即以两点为直径的圆）。
    function test_minEnclosingCircle_twoPointsAreDiameter() {
        var a = _slot(40.0, 117.0), b = _slot(40.0, 117.01)
        var c = OpsCommon.minEnclosingCircle([a, b])
        var half = _distM(a.lat, a.lon, b.lat, b.lon) / 2
        verify(Math.abs(c.radiusM - half) < 1.0,
               "两点半径应为半距 " + half.toFixed(2) + " m，实际 " + c.radiusM.toFixed(2) + " m")
        verify(Math.abs(c.lat - 40.0) < 1e-6, "两点圆心纬度应是中点")
        verify(Math.abs(c.lon - 117.005) < 1e-6, "两点圆心经度应是中点")
        _verifyCovers(c, [a, b])
    }

    /// 正方形四顶点 ⇒ 圆心在几何中心、半径 = 对角线之半。四个点全部落在圆上。
    function test_minEnclosingCircle_square() {
        var s = [_slot(40.0, 117.0), _slot(40.0, 117.01),
                 _slot(40.01, 117.0), _slot(40.01, 117.01)]
        var c = OpsCommon.minEnclosingCircle(s)
        verify(Math.abs(c.lat - 40.005) < 1e-6, "正方形圆心纬度应为 40.005，实际 " + c.lat)
        verify(Math.abs(c.lon - 117.005) < 1e-6, "正方形圆心经度应为 117.005，实际 " + c.lon)
        var diag = _distM(40.0, 117.0, 40.01, 117.01)
        verify(Math.abs(c.radiusM - diag / 2) < 1.0,
               "正方形半径应为对角线之半 " + (diag / 2).toFixed(2) + " m，实际 " + c.radiusM.toFixed(2) + " m")
        _verifyCovers(c, s)
    }

    /// ‼️ **钝角三角形：最小包围圆是以最长边为直径的圆，不是外接圆。**
    /// 这是整个算法最容易写错的地方——"三点求外接圆"的实现在锐角构型上全绿，只在钝角
    /// 构型上偏大。本用例的构型刻意做得很扁（底约 853 m、高约 11 m）：
    /// 外接圆半径约 **8165 m**，正确答案只有约 **426 m**，差 19 倍 ⇒ 无法蒙混过关。
    function test_minEnclosingCircle_obtuseTriangleUsesLongestSideAsDiameter() {
        var a = _slot(40.0, 117.0), b = _slot(40.0, 117.01), apex = _slot(40.0001, 117.005)
        var c = OpsCommon.minEnclosingCircle([a, b, apex])
        var ab = _distM(40.0, 117.0, 40.0, 117.01)
        verify(Math.abs(c.radiusM - ab / 2) < 2.0,
               "钝角三角形应取最长边为直径（半径 " + (ab / 2).toFixed(2) + " m），实际 " +
               c.radiusM.toFixed(2) + " m —— 若接近 8165 m 则是误用了外接圆")
        verify(Math.abs(c.lat - 40.0) < 1e-6, "圆心应落在最长边的中点（纬度）")
        verify(Math.abs(c.lon - 117.005) < 1e-6, "圆心应落在最长边的中点（经度）")
        _verifyCovers(c, [a, b, apex])
    }

    /// 锐角三角形 ⇒ 最小包围圆**就是外接圆**，三点都落在圆上。
    /// 断言走"三点共圆"这个性质而**不是**写死半径：把外接圆解析式在测试里重算一遍，
    /// 等于把实现抄第二遍，抄错了照样绿。
    function test_minEnclosingCircle_acuteTriangleCircumscribesAllThree() {
        var s = [_slot(40.0, 117.0), _slot(40.0, 117.01), _slot(40.007, 117.005)]
        var c = OpsCommon.minEnclosingCircle(s)
        _verifyCovers(c, s)
        for (var i = 0; i < s.length; i++) {
            var d = _distM(s[i].lat, s[i].lon, c.lat, c.lon)
            verify(Math.abs(d - c.radiusM) < 1.0,
                   "锐角三角形的最小包围圆是外接圆，第 " + i + " 点应在圆上：距离 " +
                   d.toFixed(2) + " m vs 半径 " + c.radiusM.toFixed(2) + " m")
        }
    }

    /// 内部点**不改变**结果（最小包围圆由凸包顶点决定，内部点说了不算）。
    /// 阴性对照：一个"枚举点组合但不做覆盖检查"的实现会在这里把半径算小。
    function test_minEnclosingCircle_interiorPointIgnored() {
        var sq = [_slot(40.0, 117.0), _slot(40.0, 117.01),
                  _slot(40.01, 117.0), _slot(40.01, 117.01)]
        var withCenter = sq.concat([_slot(40.005, 117.005)])
        var c1 = OpsCommon.minEnclosingCircle(sq)
        var c2 = OpsCommon.minEnclosingCircle(withCenter)
        verify(Math.abs(c2.radiusM - c1.radiusM) < 0.5, "内部点改变了半径")
        _verifyCovers(c2, withCenter)
    }

    /// 站点 1 的**真实**机位（2026-09-23 从真库抄的 8 个未删机位）。
    /// 这条刻意**不**断言精确值——它的价值是用真实数据跑通一遍并钉住**量级**：
    /// 机位簇实测约 177 m × 75 m ⇒ 半径应在 50~150 m。
    /// ⚠️ 若实现漏了经度方向的 `cos(lat)` 比例，半径会明显偏大（约 1.3 倍）而**不报错**。
    function test_minEnclosingCircle_site1RealSlots() {
        var s = [_slot(40.140578, 117.121397), _slot(40.141027, 117.121397),
                 _slot(40.141027, 117.121918), _slot(40.140803, 117.122439),
                 _slot(40.140803, 117.122960), _slot(40.140353, 117.121918),
                 _slot(40.140578, 117.123481), _slot(40.140578, 117.122960)]
        var c = OpsCommon.minEnclosingCircle(s)
        compare(c.count, 8)
        _verifyCovers(c, s)
        verify(c.radiusM > 50 && c.radiusM < 150,
               "站点 1 机位簇的包围圆半径应在 50~150 m，实际 " + c.radiusM.toFixed(1) + " m")
        verify(c.lat > 40.1403 && c.lat < 40.1411, "圆心纬度越界：" + c.lat)
        verify(c.lon > 117.1213 && c.lon < 117.1235, "圆心经度越界：" + c.lon)
    }

    /// ‼️ **性质测试**：一大批构造出来的点集，逐个验「覆盖 + 紧致」两条定义性质。
    ///
    /// 为什么非要有这一条 —— 前面那些手写构型是**抽样**，抽到哪个构型是哪个。
    /// ⚠️ 但**别把它当万能**：变异实测，把 `_mecTwoPoints` 里 p→q 两侧候选圆的取舍改成
    ///    **恒取左侧**（一个会静默返回错圆的 bug），本条的 53 个构型 + 全部手写用例
    ///    **依然全绿** —— 那条分支**从公共 API 触达不到**（原因见
    ///    `test_mecTwoPoints_picksSmallerOfTwoSideCandidates`）。性质测试扩的是**整体
    ///    正确性**的样本量，不等于盖住了每一条内部路径。
    ///
    /// ⚠️ 只断言那两条性质，**不写死期望值** —— 写死半径等于把实现抄第二遍，抄错了照样绿。
    function test_minEnclosingCircle_manyConfigurationsSatisfyBothProperties() {
        var rnd = _lcg(20260923)

        // ① 簇状随机点。
        for (var t = 0; t < 40; t++) {
            var n = 3 + Math.floor(rnd() * 8)
            var pts = []
            for (var i = 0; i < n; i++) {
                pts.push(_slot(40 + (rnd() - 0.5) * 0.02, 117 + (rnd() - 0.5) * 0.02))
            }
            _verifyCovers(OpsCommon.minEnclosingCircle(pts), pts, "随机簇#" + t)
        }

        // ② 均匀落在同一个圆周上的点 —— 最小包围圆**就是那个圆**。
        //    这一族专打「p→q 两侧都有圆外点」：环上的点必然分布在任一直径的两侧。
        var kx = Math.cos(40 * Math.PI / 180)
        for (var m = 3; m <= 12; m++) {
            var ring = []
            for (var k = 0; k < m; k++) {
                var a = 2 * Math.PI * k / m
                ring.push(_slot(40 + 0.005 * Math.cos(a), 117 + 0.005 * Math.sin(a) / kx))
            }
            _verifyCovers(OpsCommon.minEnclosingCircle(ring), ring, "圆周#" + m)
        }

        // ③ 共线点：`_mecCircumcircle` 在这些构型上的 `d === 0` 退化分支。
        var lines = [
            [_slot(40, 117), _slot(40, 117.005), _slot(40, 117.01), _slot(40, 117.015)],
            [_slot(40, 117), _slot(40.005, 117), _slot(40.01, 117), _slot(40.015, 117)],
            [_slot(40, 117), _slot(40.005, 117.005), _slot(40.01, 117.01), _slot(40.015, 117.015)]
        ]
        for (var q = 0; q < lines.length; q++) {
            _verifyCovers(OpsCommon.minEnclosingCircle(lines[q]), lines[q], "共线#" + q)
        }
    }

    /// ‼️ **直接测内部函数**。理由：`_mecTwoPoints` 里「p→q 两侧候选圆取半径小的那个」
    /// 这条路径，从公共 API **触达不到**（变异实测：改坏它，上面 53 个构型 + 全部手写
    /// 用例仍全绿）。两层原因：① 候选来自 `pts[0..i-1]`（q 自己不贡献候选），要 `i ≥ 2`
    /// 才会有第二个候选点；② 即便当场选错，只要 `q` 不是该轮最后一个点，外层 Welzl 的
    /// 自纠正就会把圆修回来。要用公共 API 稳定抓住它，两个条件得同时成立，构型极罕见。
    /// 契约非平凡、公共 API 又测不到 ⇒ **直接测它**（`.pragma library` 下所有顶层函数
    /// 都是导出的，本文件的 import 能直接取到）。
    ///
    /// ⚠️ 它的契约是**弱**的：只保证 `p`、`q` 在圆上、且覆盖**某一侧**的点 —— **不**保证
    ///    覆盖 `pts` 全部（两侧都非空时取半径小的那个，而小的那个不覆盖另一侧）。整体
    ///    正确性由外层自纠正兜底。所以这里**不能**断言"覆盖 pts 全部"——那会写出一条
    ///    与实现契约不符的测试，绿灯骗人。
    function test_mecTwoPoints_picksSmallerOfTwoSideCandidates() {
        // p=(-10,0)、q=(10,0) 为直径（r=10）；上、下各一个圆外点，刻意**不对称**：
        // 左侧候选 r=12.5（经 (0,20)），右侧候选 r≈10.16667（经 (0,-12)）⇒ 必须取右侧。
        var p = { x: -10, y: 0 }, q = { x: 10, y: 0 }
        var pts = [{ x: 0, y: 20 }, { x: 0, y: -12 }]
        var c = OpsCommon._mecTwoPoints(pts, p, q)
        verify(c !== null, "两侧都有候选时不该回 null")
        verify(Math.abs(c.r - 10.16667) < 0.001,
               "应取两侧候选里**半径小的**那个（r≈10.1667），实际 r=" + c.r.toFixed(4) +
               "；若约 12.5 则是恒取了左侧 —— 那个圆不覆盖右侧的点")
        verify(Math.abs(c.y - (-1.83333)) < 0.001,
               "小候选的圆心 y 应约 -1.8333，实际 " + c.y.toFixed(4))
    }

    //=========================================================================
    // siteCenteredCircle —— 以**站点坐标**为中心圈住机位
    //（用户 2026-09-23 裁定，取代此前的「最小包围圆」；同日要求改为虚线渲染）
    //=========================================================================

    /// 站点坐标夹具。与 `_slot` **同形**（`{lat, lon}` vs `{latitude, longitude}`）但
    /// 刻意不同名 —— 生产里传进来的是 `QtPositioning.coordinate()`（有 `.latitude`/
    /// `.longitude`），而机位是后端 JSON（有 `.lat`/`.lon`）。两者混用会静默算出错圆，
    /// 夹具的名字把这条区别摆在明处。
    function _site(lat, lon) { return { latitude: lat, longitude: lon } }

    /// 以站点为中心的圆的判据。**不能复用 `_verifyCovers`** —— 那条断言的是
    /// 「覆盖 + 紧致」，两者共同刻画**最小包围圆**；而本函数的「紧致」含义完全不同：
    /// 圆心被钉死在站点上，机位簇偏心时半径**必然**大于最小包围圆半径，
    /// 用 `_verifyCovers` 会直接判它不合格。
    ///
    /// 本函数断言的是本实现真正的契约：① 圆心**恰好**是站点（不许任何偏移）
    /// ② 覆盖全部机位 ③ 半径**恰好**等于最远机位距离（不多给余量）。
    function _verifySiteCentered(circle, site, slots, tag) {
        var t = tag ? ("[" + tag + "] ") : ""
        verify(circle !== null, t + "有效输入不该回 null")
        // ① 圆心必须恰好是站点 —— 这是本次改动的**全部意义**，单独钉死
        verify(Math.abs(circle.lat - site.latitude) < 1e-12,
               t + "圆心纬度必须等于站点纬度 " + site.latitude + "，实际 " + circle.lat)
        verify(Math.abs(circle.lon - site.longitude) < 1e-12,
               t + "圆心经度必须等于站点经度 " + site.longitude + "，实际 " + circle.lon)
        // ② 覆盖 + 顺带量出最远距离
        var maxD = 0
        for (var i = 0; i < slots.length; i++) {
            var d = _distM(site.latitude, site.longitude, slots[i].lat, slots[i].lon)
            if (d > maxD) maxD = d
            verify(d <= circle.radiusM + 1.0,
                   t + "机位#" + i + " 距站点 " + d.toFixed(2) + " m 超出半径 " +
                   circle.radiusM.toFixed(2) + " m ⇒ 没圈住")
        }
        // ③ 紧致：半径 = 最远距离（算大了同样算错 —— 用户看到的是圆圈，白给的余量看得见）
        verify(Math.abs(circle.radiusM - maxD) < 1.0,
               t + "半径应 = 最远机位距离 " + maxD.toFixed(2) + " m，实际 " +
               circle.radiusM.toFixed(2) + " m")
    }

    function test_siteCenteredCircle_nullOrInvalidSiteReturnsNull() {
        var slots = [_slot(40.001, 117.001)]
        verify(OpsCommon.siteCenteredCircle(null, slots) === null, "站点为 null ⇒ null")
        verify(OpsCommon.siteCenteredCircle(undefined, slots) === null, "站点 undefined ⇒ null")
        verify(OpsCommon.siteCenteredCircle(_site(0, 0), slots) === null,
               "站点 (0,0) 是无效坐标 ⇒ null（与 isValidWaypoint 同口径）")
        verify(OpsCommon.siteCenteredCircle(_site(NaN, 117), slots) === null, "站点纬度 NaN ⇒ null")
        verify(OpsCommon.siteCenteredCircle(_site(40, NaN), slots) === null, "站点经度 NaN ⇒ null")
    }

    function test_siteCenteredCircle_noValidSlotsReturnsNull() {
        var site = _site(40, 117)
        verify(OpsCommon.siteCenteredCircle(site, []) === null, "空数组 ⇒ null")
        verify(OpsCommon.siteCenteredCircle(site, null) === null, "null 机位 ⇒ null")
        verify(OpsCommon.siteCenteredCircle(site, [null, _slot(0, 0), _slot(NaN, 117)]) === null,
               "全是无效机位 ⇒ null（而不是返回一个半径为 0 的圆）")
    }

    /// 核心用例：机位簇**明显偏心**时，圆心仍必须停在站点上。
    /// 同时断言本用例**有鉴别力** —— 若最小包围圆的圆心与站点几乎重合，
    /// 那么"圆心是不是站点"这个断言就抓不住任何实现差异（假绿）。
    function test_siteCenteredCircle_centerStaysOnSiteEvenWhenClusterIsEccentric() {
        var site = _site(40.0, 117.0)
        var slots = [_slot(39.999, 117.002), _slot(39.9995, 117.0025), _slot(39.999, 117.003)]
        var c = OpsCommon.siteCenteredCircle(site, slots)
        _verifySiteCentered(c, site, slots, "偏心簇")

        var mec = OpsCommon.minEnclosingCircle(slots)
        var gap = _distM(mec.lat, mec.lon, site.latitude, site.longitude)
        verify(gap > 100,
               "⚠️ 本用例的鉴别力依赖「簇心与站点相距足够远」：实测仅 " + gap.toFixed(1) +
               " m ⇒ 请换一个更偏心的构型，否则圆心断言抓不住偏移")
    }

    function test_siteCenteredCircle_radiusEqualsFarthestSlot() {
        var site = _site(40.0, 117.0)
        var slots = [_slot(40.001, 117.0), _slot(40.0, 117.002), _slot(39.998, 117.0)]
        var c = OpsCommon.siteCenteredCircle(site, slots)
        _verifySiteCentered(c, site, slots, "三点")
        // 最远的是 (39.998, 117.0)：纯纬度差 0.002° ⇒ 0.002 × 111194.9 ≈ 222.4 m
        verify(Math.abs(c.radiusM - 222.4) < 2.0,
               "半径应约 222.4 m（0.002° 纬度），实际 " + c.radiusM.toFixed(1) + " m")
        compare(c.count, 3)
    }

    function test_siteCenteredCircle_singleSlotOnSiteHasZeroRadius() {
        var site = _site(40.0, 117.0)
        var c = OpsCommon.siteCenteredCircle(site, [_slot(40.0, 117.0)])
        verify(c !== null, "机位恰好落在站点上时仍应返回圆（半径 0），而不是 null")
        verify(c.radiusM < 0.01, "半径应约 0，实际 " + c.radiusM)
        compare(c.count, 1)
    }

    /// 两个函数的差别**不是精度而是语义**：圆心被钉死在站点上，偏心时圆必然更大。
    /// 这条同时防止"把 siteCenteredCircle 实现成 minEnclosingCircle 的别名"。
    function test_siteCenteredCircle_differsFromMinEnclosingOnEccentricCluster() {
        var site = _site(40.0, 117.0)
        var slots = []
        for (var i = 0; i < 6; i++) slots.push(_slot(39.9985 + i * 0.0001, 117.002))
        var mec = OpsCommon.minEnclosingCircle(slots)
        var sc  = OpsCommon.siteCenteredCircle(site, slots)
        _verifySiteCentered(sc, site, slots, "偏心簇")
        verify(sc.radiusM > mec.radiusM * 1.5,
               "以站点为中心应明显大于最小包围圆，实测 " + sc.radiusM.toFixed(1) +
               " m vs " + mec.radiusM.toFixed(1) + " m ⇒ 若接近相等，说明圆心没有钉在站点上")
    }

    function test_siteCenteredCircle_skipsInvalidSlots() {
        var site = _site(40.0, 117.0)
        var good1 = _slot(40.001, 117.0), good2 = _slot(40.0, 117.0)
        var slots = [null, good1, _slot(0, 0), _slot(NaN, 117), good2, undefined]
        var c = OpsCommon.siteCenteredCircle(site, slots)
        compare(c.count, 2)
        _verifySiteCentered(c, site, [good1, good2], "含无效")
    }

    /// 性质测试：一批确定性伪随机构型，逐个验「圆心 = 站点 + 覆盖 + 紧致」。
    /// ⚠️ 与 `minEnclosingCircle` 的性质测试同理 —— 它扩的是样本量，
    ///    **不写死期望值**（写死半径等于把实现抄第二遍，抄错了照样绿）。
    function test_siteCenteredCircle_manyConfigurationsSatisfyContract() {
        var rnd = _lcg(20260923)
        for (var k = 0; k < 40; k++) {
            var site = _site(40 + (rnd() - 0.5) * 0.04, 117 + (rnd() - 0.5) * 0.04)
            var m = 1 + Math.floor(rnd() * 8)
            var slots = []
            for (var i = 0; i < m; i++) {
                slots.push(_slot(site.latitude + (rnd() - 0.5) * 0.02,
                                 site.longitude + (rnd() - 0.5) * 0.02))
            }
            _verifySiteCentered(OpsCommon.siteCenteredCircle(site, slots), site, slots, "构型#" + k)
        }
    }

    /// 真实站点 1 数据。机位第 0 个**恰好就是站点坐标**（平谷镇政府），
    /// 所以最远机位决定了半径 —— 用独立 haversine 复算，不写死数字。
    function test_siteCenteredCircle_site1RealSlots() {
        var site = _site(40.140578, 117.121397)
        var s = [_slot(40.140578, 117.121397), _slot(40.141027, 117.121397),
                 _slot(40.141027, 117.121918), _slot(40.140803, 117.122439),
                 _slot(40.140803, 117.122960), _slot(40.140353, 117.121918),
                 _slot(40.140578, 117.123481), _slot(40.140578, 117.122960)]
        var c = OpsCommon.siteCenteredCircle(site, s)
        compare(c.count, 8)
        _verifySiteCentered(c, site, s, "站点1真实数据")
        // 最远机位是 (40.140578, 117.123481)：纯经度差 0.002084°，
        // 在纬度 40.14 上约 0.002084 × 111194.9 × cos(40.14°) ≈ 177 m
        verify(c.radiusM > 150 && c.radiusM < 200,
               "站点 1 的站点中心圆半径应在 150~200 m，实际 " + c.radiusM.toFixed(1) + " m")
    }

    //-------------------------------------------------------------------------
    // 交接取数来源（2026-09-23：修缺口①②）
    //
    // 交接数据**有两个来源**，此前只有后者被消费：
    //   - 任务项自带的 `task.handover`：`Overview`/`RouteTasks` 对**每一项**都附带
    //     （`ops.go` 的 `pendingHandover`），**不按角色过滤**；
    //   - `/handovers/pending` 建的 `{task_id: handover}` 映射：**按角色过滤**
    //     （SITE_ATC 只拿本站 LANDING、ROUTE_MONITOR 只拿其航线 ROUTE）。
    //
    // 缺口正是这两者的差集：起飞机场 ATC 是 ROUTE 交接的**提出方**，他永远不在
    // 「待我确认」名单里 ⇒ `handoverById` 里没有该任务 ⇒ 前端判定"无交接"。
    // 后果是签出成功的**那一刻**卡片从他列表里消失（后端 SQL 特意保留了这一行，
    // 注释写明"签出重叠期出站方仍需见"——前后端判据相反），且"撤回交接"入口不可达。
    //-------------------------------------------------------------------------

    /// 与 `opsOverviewItem` 同形的任务项。只列被交接派生真正读到的键。
    function _hoTask(taskId, status, takeoffSiteId, handover) {
        return {
            task_id: taskId,
            status: status,
            takeoff_site_id: takeoffSiteId,
            latest: null,
            handover: handover || undefined
        }
    }

    /// 任务自带的交接摘要（后端 `opsHandoverInfo`，设计文档 §4.1：id 字段名为 `id`）。
    function _embeddedHo(id, phaseTo, proposedBy) {
        return { id: id, phase_to: phaseTo, status: "PENDING",
                 proposed_by: proposedBy, proposed_by_name: "站点操作员",
                 deadline_at: "" }
    }

    /// 任务自带交接优先于映射——映射里那份是**按角色过滤过的**，缺的正是提出方自己那条。
    function test_handoverFor_prefersEmbeddedHandover() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        var map = { 91103: _embeddedHo(99, "LANDING", 8) }
        compare(OpsCommon.handoverFor(task, map).id, 7,
                "应取任务自带的交接（后端已按任务维度附带），而不是按角色过滤过的映射")
    }

    /// 无自带交接时回落映射（兼容仍只发 pending 列表的调用点）。
    function test_handoverFor_fallsBackToPendingMap() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, undefined)
        var map = { 91103: { handover_id: 5, phase_to: "LANDING" } }
        compare(OpsCommon.handoverFor(task, map).handover_id, 5)
    }

    /// 两个来源都没有 ⇒ undefined（调用点靠它走三元式，见 `isMine` 上方注释）。
    function test_handoverFor_noneIsUndefined() {
        verify(OpsCommon.handoverFor(_hoTask(91103, "TAKEOFF", 1, undefined), {}) === undefined)
        verify(OpsCommon.handoverFor(null, {}) === undefined)
    }

    /// 核心回归：**签出重叠期内出站方必须仍看得见这张卡片**。
    /// `handoverById` 传空对象 = 纯 SITE_ATC 从 `/handovers/pending` 实际拿到的形状
    /// （该端点对 SITE_ATC 只回本站 LANDING 交接）。卡片消失是静默的——没有任何报错。
    function test_isOutbound_keepsCardDuringCheckoutOverlap() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        verify(OpsCommon.isOutbound(task, 1, {}),
               "签出已发起、待监控员确认期间，出站方仍须看得见该任务（出站重叠期）")
    }

    /// 缺口②：提出方（ATC）必须能拿到交接对象，否则「撤回交接」按钮的可见条件恒假。
    /// 按钮判据 = `card._handover ? isMine(card._handover, AuthController.userId) : false`。
    function test_proposerSeesWithdrawEntryWithoutPendingList() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        var h = OpsCommon.handoverFor(task, {})
        verify(h ? OpsCommon.isMine(h, 16) : false,
               "提出方（站点操作员 16）应拿得到自己提出的 ROUTE 交接，撤回入口才可达")
    }

    /// `pendingPhase` 同样走任务自带交接：显示文案（待接管/待降落）与按钮重键同源。
    function test_pendingPhase_readsEmbeddedHandover() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        verify(OpsCommon.pendingPhase(task, "ROUTE", {}), "应识别出待接管的 ROUTE 交接")
        verify(!OpsCommon.pendingPhase(task, "LANDING", {}), "phase 不匹配时不得误判")
    }

    /// 两个来源的 **id 字段名不同是文档约定**，不是笔误：任务上的 `handover` 用 `id`
    /// （设计文档 §4.1 响应样例），`/handovers/pending` 的项用 `handover_id`（§4 接口表）。
    /// 调用点一律走 `handoverId()`：直接写死一个名字，换源时就静默变 `undefined`，
    /// 表现为撤回按钮 POST 到 `/api/handovers/undefined/cancel`（400，且界面无提示）。
    function test_handoverId_readsBothFieldNames() {
        compare(OpsCommon.handoverId({ handover_id: 5 }), 5)
        compare(OpsCommon.handoverId({ id: 7 }), 7)
        verify(OpsCommon.handoverId(null) === undefined)
        verify(OpsCommon.handoverId(undefined) === undefined)
    }

    //-------------------------------------------------------------------------
    // 待**我**签入（2026-09-24 裁定 丙-1/丙-2）
    //   「任务卡醒目警示条」与「待签入航班置顶」**共用** `awaitingMyCheckin`。
    //   本组钉的是那条口径分界：**事实**（`task.handover`，不按角色过滤）
    //   ≠ **待办**（`handoverById`，按角色过滤且提出方不在名单里）。
    //-------------------------------------------------------------------------

    /// 与 `opsRouteTaskItem` 同形的任务项（比 `_hoTask` 多一个降落场地）。
    /// `landing_site_id` 是 `siteTasks` 判进站用的键，少了它进站分支恒假 ⇒ 用例会
    /// "什么都没测到"却全绿（阴性对照缺失的典型形状）。
    function _siteTask(taskId, status, takeoffSiteId, landingSiteId, handover) {
        return {
            task_id: taskId,
            status: status,
            takeoff_site_id: takeoffSiteId,
            landing_site_id: landingSiteId,
            latest: null,
            handover: handover || undefined
        }
    }

    /// 有异常事件的在航任务（`isAbnormal` 为真的最小形状）。
    function _abnormalTask(taskId) {
        return { task_id: taskId, status: "IN_FLIGHT", latest: null,
                 event: { type: "DIVERT", status: "OPEN" } }
    }

    /// ‼️ **本组最关键的一格**：判据必须只看**待办名单**，不看任务自带的事实。
    /// 场景：站点 ATC 自己提出了一条 ROUTE 交接 ⇒ `task.handover` 有值（事实），
    /// 但 `/handovers/pending` **不把他自己那条发给他**（待办名单里没有）。
    /// 若实现走 `handoverFor`（它优先 `task.handover`），这一格会返回 true ⇒ **红**。
    /// 后果不是"少一个提示"而是**假警示**：他既提不出也签入不了，警示条却让他去点。
    function test_awaitingMyCheckin_ignoresEmbeddedHandoverNotInPendingList() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        verify(!OpsCommon.awaitingMyCheckin(task, {}),
               "自己提出的交接不在待办名单里 ⇒ 不得标成「待我签入」（假警示）")
        verify(OpsCommon.awaitingMyCheckin(task, { 91103: _embeddedHo(7, "ROUTE", 16) }),
               "同一条任务进了待办名单 ⇒ 必须为 true（否则上一行是恒假，毫无区分度）")
    }

    /// 阴性对照：两处都没有交接 ⇒ false。返回 undefined 会让 QML 的 `visible` 退回 true。
    function test_awaitingMyCheckin_noHandoverAtAll() {
        verify(OpsCommon.awaitingMyCheckin(_hoTask(91103, "TAKEOFF", 1, undefined), {}) === false,
               "无交接 ⇒ 必须返回真 bool false（undefined 会让警示条恒亮）")
        verify(OpsCommon.awaitingMyCheckin(null, {}) === false)
        verify(OpsCommon.awaitingMyCheckin(_hoTask(1, "TAKEOFF", 1, undefined), null) === false,
               "名单尚未建好（null）时不得抛错，也不得亮警示")
    }

    /// 置顶：名单里那条排到最前，且**一条不丢、一条不重**。
    /// 阴性对照紧随其后——没有它，一个"把所有行都倒过来"的实现也能让上面那行绿。
    function test_siteTasks_putsAwaitingFirstOnlyWhenListed() {
        var t1 = _siteTask(1, "LANDING", 9, 1, undefined)
        var t2 = _siteTask(2, "LANDING", 9, 1, _embeddedHo(7, "LANDING", 16))
        var t3 = _siteTask(3, "LANDING", 9, 1, undefined)
        var all = [t1, t2, t3]

        var listed = OpsCommon.siteTasks(all, false, true, 1, { 2: _embeddedHo(7, "LANDING", 16) })
        compare(listed.length, 3, "置顶不得多收或少收行")
        compare(listed[0].task_id, 2, "待我签入的那条必须排在最前")
        compare(listed[1].task_id, 1, "其余保持原有先后")
        compare(listed[2].task_id, 3, "其余保持原有先后")

        // 阴性对照：名单为空 ⇒ 顺序与输入一致（证明上一行的 2 是"被置顶"而非"排序恰好如此"）
        var plain = OpsCommon.siteTasks(all, false, true, 1, {})
        compare(plain[0].task_id, 1, "名单为空时不得重排")
        compare(plain[2].task_id, 3, "名单为空时不得重排")
    }

    /// 回归：出站/进站两个勾选框从 `else if` 改成 `||` 之后，**一条任务仍只出现一次**。
    /// 造一条**同时**满足两个分支的任务：本站起飞 ∧ 本站降落 ∧ 有 PENDING(LANDING) 交接
    /// （此时 `isOutbound` 的 `checkoutState !== 'ACCEPTED'` 与 `!landingAccepted` 都成立）。
    /// 重复收会让同一条航班在列表里出现两次——看起来像"重复的数据"，不报错。
    function test_siteTasks_countsOverlappingTaskOnce() {
        var t = _siteTask(5, "IN_FLIGHT", 1, 1, _embeddedHo(7, "LANDING", 16))
        verify(OpsCommon.isOutbound(t, 1, {}), "夹具前提：这条应判为出站")
        verify(OpsCommon.isInbound(t, 1, {}), "夹具前提：这条应判为进站")
        compare(OpsCommon.siteTasks([t], true, true, 1, {}).length, 1,
                "两个勾选框同时命中时仍只收一次")
    }

    /// 监控员视图：待我签入同样进第 1 节（置顶节），且异常航班的位置不受影响。
    /// 阴性对照同上——名单为空时不得重排。
    function test_middleSectionTasks_putsAwaitingFirstOnlyWhenListed() {
        var a = _task(1, "IN_FLIGHT")
        var b = _task(2, "IN_FLIGHT")
        var c = _task(3, "IN_FLIGHT")
        var all = [a, b, c]

        var listed = OpsCommon.middleSectionTasks(all, null, { 3: _embeddedHo(7, "ROUTE", 16) })
        compare(listed.length, 3, "置顶不得多收或少收行")
        compare(listed[0].task_id, 3, "待我签入的那条必须排在最前")

        var plain = OpsCommon.middleSectionTasks(all, null, {})
        compare(plain.length, 3)
        compare(plain[0].task_id, 1, "名单为空时不得重排")

        // 选中一条航线时，第 1 节的「待签入」**不受航线过滤**（与异常航班同口径）
        var filtered = OpsCommon.middleSectionTasks(
                    [ _siteTask(4, "IN_FLIGHT", 1, 1, undefined),
                      _siteTask(5, "IN_FLIGHT", 1, 1, undefined) ],
                    99, { 4: _embeddedHo(7, "ROUTE", 16) })
        compare(filtered[0].task_id, 4,
                "第 1 节不受 selectedRouteId 过滤——它与异常航班同为常驻置顶")
    }

    /// ‼️ **回归靶子**：判据**不得**塞进 `isAbnormal`。
    /// `isAbnormal` 被 `abnormalKind`/`abnormalColor` 与**地图 marker 着色**共用
    /// （`markerColor` 的第一步就是它）——往里加一条"待签入也算异常"，地图上那架
    /// 飞机就会跟着变色。本格存在，是为了让那次误改**当场红**而不是上线后才被看见。
    function test_isAbnormal_unaffectedByAwaitingCheckin() {
        var task = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        verify(OpsCommon.awaitingMyCheckin(task, { 91103: _embeddedHo(7, "ROUTE", 16) }),
               "夹具前提：这条确实在待办名单里")
        verify(!OpsCommon.isAbnormal(task),
               "有 PENDING 交接 ≠ 异常：地图 marker 的着色判据不能被置顶判据污染")
    }

    //-------------------------------------------------------------------------
    // LANDING 交接**终态告知**（2026-09-24 裁定 乙）的时间链与文案
    //   后端下发 `landing_state` / `landing_changed_at`（`lastLandingHandover`），
    //   本组钉住 QGC 侧怎么把它变成那句提示。
    //-------------------------------------------------------------------------

    /// 与 `opsOverviewItem` 同形、带 LANDING 终态字段的任务项。
    function _landingTask(state, changedAt) {
        return { task_id: 91103, status: "IN_FLIGHT", latest: null,
                 landing_state: state, landing_changed_at: changedAt }
    }

    /// ‼️ 本组的地基：后端时间串是**无时区裸串**（`"2026-09-24 03:04:05"`），
    /// 用 `Date.parse` 直接吃会**按本地时区**解析 ⇒ 偏一个时区（东八区差 8 小时）。
    /// 断言写成 `Date.UTC(...)` 的毫秒值 ⇒ **与跑测试的机器时区无关**；写成
    /// `Qt.formatTime` 的本地时钟就变成了"在 CI 上必红"的用例。
    /// 追溯：`webui-naive-utc-timestamps`（同一个坑的另一端）。
    function test_utcNaiveMs_parsesNaiveStringAsUtc() {
        compare(OpsCommon.utcNaiveMs("2026-09-24 03:04:05"), Date.UTC(2026, 8, 24, 3, 4, 5),
                "无时区裸串必须按 UTC 解析")
        compare(OpsCommon.utcNaiveMs("2026-09-24T03:04:05Z"), Date.UTC(2026, 8, 24, 3, 4, 5),
                "已带 Z 的串不得被二次补 Z")
        compare(OpsCommon.utcNaiveMs("2026-09-24T03:04:05+08:00"), Date.UTC(2026, 8, 23, 19, 4, 5),
                "已带偏移量的串不得被当成本地时间")
    }

    /// 解析不出来时返回 **NaN**（不是 0）：0 是一个合法时刻（1970-01-01），
    /// 会被下游当成"真的有个时间"渲染出来。
    function test_utcNaiveMs_invalidIsNaN() {
        verify(isNaN(OpsCommon.utcNaiveMs("")), "空串 ⇒ NaN")
        verify(isNaN(OpsCommon.utcNaiveMs(undefined)), "undefined ⇒ NaN")
        verify(isNaN(OpsCommon.utcNaiveMs("不是时间")), "垃圾串 ⇒ NaN")
    }

    /// 回归：`deadlineMs` 与 `landing_changed_at` 走**同一个** `utcNaiveMs`。
    /// 改前两处各抄过一遍"补 Z"逻辑——将来只改一处，就会让其中一类时间**静默**偏 8 小时
    /// （倒计时看着正常，只是比真实期限早/晚 8 小时，没有任何报错）。
    function test_deadlineMs_sharesUtcBasis() {
        compare(OpsCommon.deadlineMs({ deadline_at: "2026-09-24 03:04:05" }),
                Date.UTC(2026, 8, 24, 3, 4, 5),
                "交接期限与作废时刻必须同源，否则两者会朝相反方向偏")
    }

    /// 非 TIMEOUT ⇒ **空串**（空串 = 不占位）。这一格是阴性对照：没有它，
    /// 一个"任何状态都吐一句话"的实现能让下面几格全绿，而界面上每条任务都挂着提示条。
    function test_landingNotice_emptyUnlessTimeout() {
        compare(OpsCommon.landingNotice(_landingTask("", ""), false), "", "无交接 ⇒ 空")
        compare(OpsCommon.landingNotice(_landingTask("ACCEPTED", ""), false), "", "已签入 ⇒ 空")
        compare(OpsCommon.landingNotice(_landingTask("PENDING", ""), false), "", "进行中 ⇒ 空")
        compare(OpsCommon.landingNotice(_landingTask("REJECTED", ""), false), "",
                "REJECTED 本轮不下发（后端能区分、但界面还没接），一并留空")
        compare(OpsCommon.landingNotice(null, false), "", "无任务 ⇒ 空")
        verify(OpsCommon.landingNotice(_landingTask("TIMEOUT", "2026-09-24 03:04:05"), false) !== "",
               "TIMEOUT ⇒ 必须非空（否则上面五格是恒真，毫无区分度）")
    }

    /// 用户 2026-09-24 裁定「**双方都告知**」：同一条作废，两个角色各得一句，
    /// 且**动作主语不同**——提出方（监控员）做得到「请重新发起」，接收方（降落机场）
    /// 只能「待其重新发起」。写反了就是让一个点不动按钮的角色去点按钮。
    function test_landingNotice_tellsBothSidesDifferently() {
        var t = _landingTask("TIMEOUT", "2026-09-24 03:04:05")
        var proposer = OpsCommon.landingNotice(t, false)
        var receiver = OpsCommon.landingNotice(t, true)
        verify(proposer !== receiver, "提出方与接收方不得是同一句（否则等于只告知了一方）")
        verify(proposer.indexOf("请重新发起") >= 0, "提出方那一句要他重新发起")
        verify(receiver.indexOf("待其重新发起") >= 0, "接收方那一句只能等对方重新发起")
    }

    /// 时刻缺失时必须**回落成不带时刻的文案**，而不是渲染出 `undefined` 或垃圾串。
    /// `changedAtClock` 对解析不出的时刻返回空串，就是为了让这里走另一句。
    function test_landingNotice_withoutTimestampDegradesGracefully() {
        var withAt = OpsCommon.landingNotice(_landingTask("TIMEOUT", "2026-09-24 03:04:05"), true)
        var withoutAt = OpsCommon.landingNotice(_landingTask("TIMEOUT", ""), true)

        // ‼️ 这两格**直接**钉住 `changedAtClock` 的契约，不靠文案间接推断。
        //    教训（实测）：本函数最初只写了下面那句 `indexOf("NaN") < 0`，结果
        //    「删掉 isNaN 守卫」的变异**照绿**——因为 `("0" + NaN).slice(-2)` 是 **"aN"**，
        //    不是 "NaN"。判据串选错 ⇒ 零区分度，且失败形状与"实现正确"长得一样。
        compare(OpsCommon.changedAtClock(_landingTask("TIMEOUT", "")), "",
                "解析不出时刻 ⇒ 必须返回空串，由调用点走另一句")
        verify(/^\d{2}:\d{2}$/.test(
                   OpsCommon.changedAtClock(_landingTask("TIMEOUT", "2026-09-24 03:04:05"))),
               "有时刻 ⇒ 必须是 HH:MM 形状（去掉 isNaN 守卫会退化成 'aN:aN'）")

        verify(withoutAt !== "", "缺时刻仍须告知作废（这恰恰是最该说清楚的那种情况）")
        verify(withoutAt.indexOf("undefined") < 0 && withoutAt.indexOf("aN") < 0,
               "缺时刻不得把 NaN/undefined 的残渣渲染进文案")
        verify(withoutAt !== withAt, "有/无时刻必须是两句不同的文案，否则时刻没真的进去")
    }

    //-------------------------------------------------------------------------
    // signedIn / checkinNotice：接收方签入（2026-09-24）
    //
    //   背景：`signed_in` 后端**早就在下发**（`handlers/ops.go` 的 `opsOverviewItem` 与
    //   `opsRouteTaskItem` 各一个，`ops_rom_test.go` 有用例钉着），而 **QGC 侧一个字都没读**
    //   （`src/` 下零命中）⇒ 设计文档 §0.2.2 要它承担的两件事一件都没发生：
    //     · 「操作按钮的可用性」——监控员在**航班还没交给自己**时就拿到了「移交降落指挥」，
    //       而后端那条路径**当时也没有闸**（责任链会断：飞机还没交给监控员，监控员却已经
    //       把降落指挥交给了降落机场）；
    //     · 「未签入提示」——判据缺失，界面上既没有按钮也没有解释。
    //-------------------------------------------------------------------------

    /// 与 `opsRouteTaskItem` / `opsOverviewItem` 同形的最小任务项。
    /// `signed_in` 是**布尔**（裁定 1A：`phase_to='ROUTE' AND status='ACCEPTED'` 有无记录），
    /// **不是枚举**——别照 `checkout_state` 那族的形状写这个夹具，那会诱导实现去比字符串。
    function _signedTask(status, signedIn, handover) {
        return { task_id: 91103, status: status, latest: null,
                 signed_in: signedIn, handover: handover || undefined }
    }

    /// ‼️ 本组地基：必须返回**真 bool**。`visible` / `enabled` 吃到 undefined 会退回默认值
    /// **true**（`qml-undefined-binding-falls-back-to-default-true`）——在这里的表现是
    /// "**未签入的航班反而能点移交**"，即本函数要防的那个缺陷本身。故 `!!` 不可省。
    function test_signedIn_alwaysReturnsRealBoolean() {
        verify(OpsCommon.signedIn(_signedTask("IN_FLIGHT", true)) === true, "已签入 ⇒ true")
        verify(OpsCommon.signedIn(_signedTask("IN_FLIGHT", false)) === false,
               "未签入 ⇒ 必须是真 bool false（undefined 会让「移交降落指挥」照常可点）")
        verify(OpsCommon.signedIn({ task_id: 1, status: "IN_FLIGHT" }) === false,
               "字段缺失（老缓存 / 老后端）⇒ false，fail-closed")
        verify(OpsCommon.signedIn(null) === false, "无任务 ⇒ false，且不得抛错")
    }

    /// 「尚未接管」提示条：**只在监控员侧、且飞机已在航线中**时才有意义。
    /// 站点侧不需要它——那边同一张卡上有【签出】按钮，"还没签出"本身就有一个出口。
    function test_checkinNotice_onlyForMonitorOnInFlightUnsigned() {
        var unsigned = _signedTask("IN_FLIGHT", false)
        verify(OpsCommon.checkinNotice(unsigned, true, {}) !== "",
               "监控员 + 在航 + 未签入 + 无人待我签入 ⇒ 必须给出提示（这正是「人员不知道」那一格）")
        compare(OpsCommon.checkinNotice(unsigned, false, {}), "",
                "站点侧不显示：那边有【签出】按钮，再挂一条是噪音")
        compare(OpsCommon.checkinNotice(_signedTask("IN_FLIGHT", true), true, {}), "",
                "已签入 ⇒ 无提示（否则签入按钮点完提示条还在，看起来像没生效）")
        compare(OpsCommon.checkinNotice(null, true, {}), "", "无任务 ⇒ 空")
    }

    /// 飞机尚未进入航线时**不说**。判据与「移交降落指挥」按钮的 `status === "IN_FLIGHT"`
    /// 对齐：那几档本来就没有操作，提示"暂不可操作"是在解释一件用户不会去尝试的事。
    function test_checkinNotice_silentBeforeInFlight() {
        var states = ["SCHEDULED", "READY", "READY_TO_TAKEOFF", "TAKEOFF", "LANDING", "COMPLETED"]
        for (var i = 0; i < states.length; i++) {
            compare(OpsCommon.checkinNotice(_signedTask(states[i], false), true, {}), "",
                    "非在航状态（" + states[i] + "）⇒ 不提示")
        }
    }

    /// ‼️ **本组最关键的一格**：已经有一条 PENDING 交接在等我签入时，**本提示条让位**。
    /// 两条说的是相反的事——警示条「有人在等你动手」vs 本提示「还没有人交给你」——
    /// 同时出现就是自相矛盾的画面。缺这一格的话，一个"只要未签入就吐提示"的实现
    /// 能让上面几格全绿，而界面上那两种情况会一起挂出来。
    function test_checkinNotice_yieldsToAwaitingCheckin() {
        var h = _embeddedHo(7, "ROUTE", 16)
        var task = _signedTask("IN_FLIGHT", false, h)
        var byId = { 91103: h }
        compare(OpsCommon.checkinNotice(task, true, byId), "",
                "有 PENDING 等我签入 ⇒ 交给警示条与【签入】按钮，本提示条让位")
        verify(OpsCommon.awaitingMyCheckin(task, byId),
               "同一条任务确实进了待办名单（否则上一行是恒真，毫无区分度）")
        verify(OpsCommon.checkinNotice(task, true, {}) !== "",
               "同一条任务**不在**待办名单里（签出被驳回 / 撤回 / 超时之后）⇒ 提示条必须回来")
    }

    //-------------------------------------------------------------------------
    // routeMissionItems / takeoffAltitude：航线 → 待下发的 mission
    //（2026-09-23 站点操作员起飞前置动作：握手完成后自动下发航线）
    //-------------------------------------------------------------------------

    /// 与 `GET /routes/:id/waypoints` 响应**同形**。只列被读到的键：
    /// `lat` / `lon` / `altitude` / `command`。接口还下发 `id`/`name`/`code`/
    /// `company_id` 等，但**下发逻辑不该依赖它们**——多写会让下一个人以为
    /// 函数还读了别的字段，从而不敢动那些字段。
    function _wp(lat, lon, alt, cmd) {
        return { lat: lat, lon: lon, altitude: alt, command: cmd }
    }

    /// route 20 的两个航点。值依据：**本计划 brief（2026-09-23）转述的真库观察**，
    /// 未经本任务独立复核（本任务无数据库访问权限）；下游落地前须在有库环境核验。
    function _route20() {
        return [_wp(39.748800, 116.143400, 50.0, 16),
                _wp(39.748823, 116.143486, 50.0, 21)]
    }

    function test_routeMissionItems_emptyReturnsEmpty() {
        compare(OpsCommon.routeMissionItems([]).length, 0, "空数组应回空")
        compare(OpsCommon.routeMissionItems(null).length, 0, "null 应回空")
        compare(OpsCommon.routeMissionItems(undefined).length, 0, "undefined 应回空")
    }

    /// ‼️ 本用例钉死整条链路的**量纲**：高度原样透传 + `frame = 0`（AMSL）。
    /// 量纲依据：**本计划 brief（2026-09-23）转述的真库观察** —— 该航线（route 4）的
    /// `.plan` 写 `home 413 + z 50`，而库里对应的 `table_waypoint.altitude` 是 **463.0**
    /// ⇒ 库值即 AMSL。**该观察未经本任务独立复核**（本任务无库访问），是 Task 2/3 的
    /// 设计前提：若库值其实是 AGL，`frame = 0` 会让每个航点都偏高一个 home 高程，
    /// 而任务卡上显示的高度看着完全正常 ⇒ 下游落地前须在有库环境核验。
    /// 阴性对照：把 `frame` 写成 `3`（QGC `MissionItem` 的**默认值**，相对 home）
    /// ⇒ 463 会被当成"离地 463 米"⇒ 本用例必红。
    function test_routeMissionItems_altitudeIsAmslWithGlobalFrame() {
        var items = OpsCommon.routeMissionItems([_wp(39.7488, 116.1434, 463.0, 16)])
        compare(items.length, 1)
        compare(items[0].alt, 463.0, "高度必须原样透传，不得做任何转换")
        compare(items[0].frame, 0,
                "frame 必须是 MAV_FRAME_GLOBAL(0)=AMSL；写成 3 会让 463 被当成离地高度")
        compare(items[0].command, 16)
    }

    /// ‼️ `command=21` 是**航线设计域**的"站点"标记，不是 `MAV_CMD_NAV_LAND`
    ///（后者也恰好是 21，纯属数值巧合）。本次裁定"降落稍后再议"⇒ 站点航点
    /// 按普通航点下发。这条防的是"看到 21 就发降落指令"这个误读 ——
    /// 一旦误读，飞机会在中途**直接降落**，而界面上看不出任何异常。
    function test_routeMissionItems_siteWaypointBecomesPlainWaypoint() {
        var items = OpsCommon.routeMissionItems([_wp(39.748823, 116.143486, 50.0, 21)])
        compare(items.length, 1)
        compare(items[0].command, 16, "站点航点(设计域 cmd=21)下发时必须映射成 NAV_WAYPOINT(16)")
    }

    /// 未知的设计域 `command` ⇒ **整条航线作废**（回空数组），不做"跳过这一点"。
    /// ‼️ 跳过会让飞机飞出一条用户没画过的路径，而界面上点的编号仍然连续、
    ///    看不出少了哪一个。这里是 fail-closed：宁可起飞按钮不亮。
    function test_routeMissionItems_unknownCommandVoidsWholeRoute() {
        var wps = [_wp(39.7488, 116.1434, 50.0, 16), _wp(39.7489, 116.1435, 50.0, 99)]
        compare(OpsCommon.routeMissionItems(wps).length, 0,
                "含未知 command 时应整体作废，而不是静默跳过那一点")
    }

    /// 坐标无效（`(0,0)` / 单轴为 0 / NaN / **真缺字段**）⇒ 同样整体作废，理由同上。
    /// ‼️ 判据是 `routeMissionItems` 内复用的单点定义 `isValidWaypoint`：**任一轴为 0 即无效**
    ///（不是"两轴同时为 0"）。(0,0) 是"没有定位"的常见缺省值。
    function test_routeMissionItems_invalidCoordinateVoidsWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        compare(OpsCommon.routeMissionItems([good, _wp(0, 0, 50.0, 16)]).length, 0, "(0,0) 应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(NaN, 116.1, 50.0, 16)]).length, 0, "NaN 纬度应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 116.1, NaN, 16)]).length, 0, "NaN 高度应作废")
        compare(OpsCommon.routeMissionItems([good, null]).length, 0, "null 元素应作废")
        // 单轴为 0：只挡"两轴同时为 0"的实现会在这里放行，把飞机送到赤道 / 本初子午线。
        compare(OpsCommon.routeMissionItems([good, _wp(0, 116.1, 50.0, 16)]).length, 0,
                "纬度单轴为 0 应作废（判据是「任一轴为 0」，不是「两轴同时为 0」）")
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 0, 50.0, 16)]).length, 0,
                "经度单轴为 0 应作废")
        // 真缺键（不是显式 NaN）——后端可空列 / 字段缺失的实际形态。
        compare(OpsCommon.routeMissionItems([good, { lat: 39.7, lon: 116.1, command: 16 }]).length, 0,
                "真缺 altitude 键应作废")
        compare(OpsCommon.routeMissionItems([good, { lat: 39.7, lon: 116.1, altitude: 50.0 }]).length, 0,
                "真缺 command 键应作废")
    }

    /// ‼️ `altitude` 为 `null` / 空串时**必须**作废 —— `Number(null) === 0`、`Number("") === 0`，
    /// 而 `isFinite(0)` 为真，若不拒绝就会产出一条 `alt: 0` 的航点，`takeoffAltitude`
    /// 随之回 **0 而不是 `NaN`** ⇒ **只判 `isNaN` 的起飞闸会失效** ⇒ 飞机被指令到 AMSL 0 米。
    /// （真实调用方用的是 `!(takeoffAlt > 0)`，不受此影响 —— 本用例测的是**纯函数的口径**。）
    /// ‼️ **坏点必须在索引 0**：`takeoffAltitude` 读的是**首点**，坏点若在索引 1，守卫一旦
    ///    失效回的是首点的 50 而**不是 0** ⇒ 那几条断言恒真、零鉴别力（本用例的第一版就是
    ///    这么废掉的）。这也是 F2 的**原始形态**：**首点**高度为空 ⇒ 起飞闸失效。
    /// ‼️ 起飞闸那几条**写在 `length` 断言之前**：QML QuickTest 在第一条失败断言处即终止本
    ///    函数，写在后面等于恒不可达 ⇒ 鉴别力必须**各自独立**，不能靠前一条代红。
    function test_routeMissionItems_nullAltitudeVoidsWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        var nullAlt = [_wp(39.7, 116.1, null, 16), good]
        var emptyAlt = [_wp(39.7, 116.1, "", 16), good]
        verify(isNaN(OpsCommon.takeoffAltitude(nullAlt)), "首点 altitude 为 null ⇒ 起飞高度必须是 NaN")
        verify(isNaN(OpsCommon.takeoffAltitude(emptyAlt)), "首点 altitude 为空串 ⇒ 起飞高度必须是 NaN")
        verify(OpsCommon.takeoffAltitude(nullAlt) !== 0, "强转成 0 就等于放行了一次 AMSL 0 米起飞")
        compare(OpsCommon.routeMissionItems(nullAlt).length, 0, "altitude 为 null 应作废")
        compare(OpsCommon.routeMissionItems(emptyAlt).length, 0, "altitude 为空串应作废")
    }

    /// ‼️ **类型闸**：`lat` / `lon` / `altitude` 三处**统一**只接受 JSON number。
    /// 下列形态的 `Number()` 结果都是 `0`（`"50"` 是 `50`），若不按类型拒绝，它们会从
    /// **同一道门**进来 ⇒ `takeoffAltitude` 回 0（或 50）而不是 `NaN`。
    /// 「枚举坏值」永远会漏 —— 本用例就是那些"漏"的集合。
    /// ⚠️ 坏点一律放**索引 0**（`takeoffAltitude` 读首点），否则断言无鉴别力。
    function test_routeMissionItems_nonNumberTypesVoidWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        var badAlt = function (v) { return [_wp(39.7, 116.1, v, 16), good] }
        compare(OpsCommon.routeMissionItems(badAlt(" ")).length, 0,
                "空白串：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("\t")).length, 0,
                "制表符串：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("0")).length, 0,
                "字符串 0：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("50")).length, 0,
                "数值字符串 50：能转成合法数，但类型不对 ⇒ 同样拒绝（不得靠能转成数放行）")
        compare(OpsCommon.routeMissionItems(badAlt(false)).length, 0,
                "布尔 false：Number(false) === 0 ⇒ 必须拒绝")
        compare(OpsCommon.routeMissionItems(badAlt([])).length, 0,
                "空数组：Number([]) === 0 ⇒ 必须拒绝")
        // lat / lon 同样按类型收 —— 三处口径必须一致。只改 altitude 就是再造一次
        // 「同一件事三处三种口径」（`isValidWaypoint` 上方那段注释记录的教训）。
        compare(OpsCommon.routeMissionItems([_wp("39.7", 116.1, 50.0, 16), good]).length, 0,
                "lat 为数值字符串 ⇒ 必须拒绝（不得靠 isValidWaypoint 侥幸兜住）")
        compare(OpsCommon.routeMissionItems([_wp(39.7, "116.1", 50.0, 16), good]).length, 0,
                "lon 为数值字符串 ⇒ 必须拒绝")
        // fail-closed 与位置无关：坏点在末位同样整体作废。
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 116.1, [], 16)]).length, 0,
                "坏点在末位也应整体作废")
    }

    /// ‼️ **数值 `0` 有意放行** —— 把这条**裁量**钉成**可执行判据**，而不是只写在注释里。
    /// `routeMissionItems` 只做**类型**检查：「高度恰好为 0」是**数据问题**（后端该不该存 0），
    /// 不是**类型问题**，业务判定留给调用方的起飞闸（那里能给出中文文案）。
    /// 本用例的意义：日后若有人把 `0` 也一并拒掉，必须**显式推翻**这个裁量 —— 会有人变红。
    function test_routeMissionItems_numericZeroAltitudeIsDeliberatelyAllowed() {
        var wps = [_wp(39.7, 116.1, 0, 16)]
        var items = OpsCommon.routeMissionItems(wps)
        compare(items.length, 1, "数值 0 是合法 number ⇒ 本函数**有意放行**（见 routeMissionItems 内注释）")
        compare(items[0].alt, 0, "高度原样透传，不做任何转换")
        compare(OpsCommon.takeoffAltitude(wps), 0,
                "起飞高度回 0（**不是** NaN）：类型闸不等于业务闸，拦起飞是调用方的事")
    }

    /// 顺序即输入顺序（调用方已按 `seq` 取好），且**不掺任何私货** ——
    /// 本函数不生成起飞项（起飞点的坐标是"飞机当前 home"，运行时才知道）。
    function test_routeMissionItems_preservesOrderAndAddsNoTakeoff() {
        var items = OpsCommon.routeMissionItems(_route20())
        compare(items.length, 2, "不该额外插入起飞项——起飞项由调用方在拿到 home 之后插")
        verify(Math.abs(items[0].lat - 39.748800) < 1e-9, "第 0 点顺序错了")
        verify(Math.abs(items[1].lat - 39.748823) < 1e-9, "第 1 点顺序错了")
    }

    /// 起飞高度 = **第一个航点的高度**（用户 2026-09-23 裁定 e）。
    /// route 20 两个点都是 50.0 ⇒ 期望 50.0。
    function test_takeoffAltitude_isFirstWaypointAltitude() {
        compare(OpsCommon.takeoffAltitude(_route20()), 50.0)
    }

    /// ‼️ 上面那一条**钉不住"第一个"这半句**：`_route20()` 两点同为 50.0 ⇒
    /// `items[0]` / `items[last]` / `Math.min` / `Math.max` 四种实现**全都绿**。
    /// 本条用一条**两点高度不同**的航线把「取首点」独立钉死（首点 50.0、末点 80.0）。
    /// ⚠️ 夹具是内联的，**不动** `_route20()` —— 它被多个用例共用。
    function test_takeoffAltitude_usesFirstWaypointNotLast() {
        // 两个方向都要：只试"首低末高"挡不住 `Math.min`，只试"首高末低"挡不住 `Math.max`。
        var firstLow = [_wp(39.748800, 116.143400, 50.0, 16),
                        _wp(39.748823, 116.143486, 80.0, 16)]
        var firstHigh = [_wp(39.748800, 116.143400, 80.0, 16),
                         _wp(39.748823, 116.143486, 50.0, 16)]
        compare(OpsCommon.takeoffAltitude(firstLow), 50.0,
                "起飞高度取**首点** 50.0；取末点或 `Math.max` 会得 80.0")
        compare(OpsCommon.takeoffAltitude(firstHigh), 80.0,
                "起飞高度取**首点** 80.0；取末点或 `Math.min` 会得 50.0")
    }

    /// 航线不可用 ⇒ `NaN`（**不是 0**）。调用方据此拦住起飞。
    /// ‼️ 回 0 会让飞机起飞到"AMSL 0 米"——一个在界面上看不出错的数字。
    function test_takeoffAltitude_isNaNWhenRouteUnusable() {
        verify(isNaN(OpsCommon.takeoffAltitude([])), "空航线应回 NaN 而不是 0")
        verify(isNaN(OpsCommon.takeoffAltitude(null)), "null 应回 NaN")
        verify(isNaN(OpsCommon.takeoffAltitude([_wp(0, 0, 50.0, 16)])), "坐标无效应回 NaN")
        verify(OpsCommon.takeoffAltitude([]) !== 0, "回 0 是危险的兜底值")
    }
}
