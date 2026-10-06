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

    /// 带 `route_id` 的普通在航任务。‼️ `_task`/`_abnormalTask`/`_siteTask`/`_hoTask`
    /// **都不带 `route_id`**，而 `middleSectionSplit/Tasks` 的第 2 节判据正是
    /// `Number(u.route_id) !== Number(selectedRouteId)` —— 拿它们当夹具的话
    /// `Number(undefined)` 是 `NaN`，`NaN !== 7` 恒真 ⇒ 第 2 节**恒空**，
    /// 「选中航线只留该航线的」那格会对着空数组**假绿**。
    function _routeTask(taskId, routeId) {
        return { task_id: taskId, status: "IN_FLIGHT", route_id: routeId, latest: null }
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

    /// 终态黑名单**逐档**（与后端 `handlers/task.go` 的 `finishedTaskStatuses` 逐字对应）。
    /// ⚠️ 两个拼写都要钉：真库 2026-10-02 实测**同时**在用——`table_flight_task` 里那条是
    ///    `CANCELED`，而同库 `table_task_handover` 里 16 条全是 `CANCELLED`。
    ///    只钉一个的话，另一个字面量的任务会被当成"非终态"放进 `isInbound`，**且没有任何报错**。
    /// ⚠️ 第二半同样必要：若全是终态，一个恒真的实现也能让第一半全绿。
    function test_isFinishedTaskStatus_blacklistIsExact() {
        var fin = ["COMPLETED", "ABORTED", "CANCELED", "CANCELLED"]
        for (var i = 0; i < fin.length; i++)
            verify(OpsCommon.isFinishedTaskStatus(fin[i]) === true,
                   fin[i] + " 是终态 ⇒ 必须为**真 bool** true")

        var live = ["SCHEDULED", "READY", "TAKEOFF", "IN_FLIGHT", "LANDING", ""]
        for (var j = 0; j < live.length; j++)
            verify(OpsCommon.isFinishedTaskStatus(live[j]) === false,
                   live[j] + " 不是终态 ⇒ 必须为**真 bool** false"
                   + "（undefined 会让 isInbound 那句 return false 短路成 undefined）")

        // ‼️ 这一格钉的是**两侧一致**，不是"这个判据对"：`ABORT`/`FAILED` 在 `statusLabel`
        //    里被译成「中止」「异常」，却**不在**后端的 `finishedTaskStatuses` 里
        //    ⇒ 两侧都把它们当**非终态**。前端单方面加进去就会与后端漂移（后端下发、前端滤掉
        //    或反之），而漂移的症状正是本 bug 的形状："任务卡片时有时无"。
        //    ⚠️ **未实测**：后端是否真会把这俩字面量写进 `table_flight_task.status`
        //    （真库现有取值只有 `READY`/`CANCELED`）。若将来真出现，这是一处**静默放行**的缝。
        verify(OpsCommon.isFinishedTaskStatus("ABORT") === false
               && OpsCommon.isFinishedTaskStatus("FAILED") === false,
               "与后端 finishedTaskStatuses 保持一致：ABORT/FAILED 不在黑名单里")
    }

    //-------------------------------------------------------------------------
    // 「到站本站」的航班（2026-10-02 用户需求，逐字）
    //   「在检索任务列表时，除了从当前站点起飞的，还要检索到站本站的飞行任务（要求该飞行
    //     任务对应的飞机至少已经 READY_TO_TAKEOFF），到站任务卡片显示在出站任务卡片的
    //     后面…当该飞行任务被成功接引后，该任务卡片将被置顶，如果当前站点有多个已经接引、
    //     但是未降落的任务，那么置顶项按照接引的顺序显示」
    //   后端（`gcs_server/handlers/ops.go` 的 `case "site":`）与前端**逐项同口径**，
    //   本组钉的是前端这一半。两侧漂移的表现正是本 bug：**后端给了、前端滤掉了**，
    //   而飞机遥测走另一条路照常显示 ⇒「轨迹和数据都在、任务卡片不在」。
    //-------------------------------------------------------------------------

    /// 与 `opsOverviewItem` 同形的任务项（比 `_siteTask` 多飞机状态与接引时刻）。
    /// ‼️ `uav_status` 是本组判据的自变量：少了它 `isAirborneReady` 恒假 ⇒ 用例会
    ///    "什么都没测到"却全绿（同 `_siteTask` 上方对 `landing_site_id` 的警告）。
    /// `landingAcceptedAt` 给了才置 `landing_accepted`——两个字段同源（后端同一个子查询族）。
    function _inboundTask(taskId, status, takeoffSiteId, landingSiteId, uavStatus, landingAcceptedAt) {
        var t = _siteTask(taskId, status, takeoffSiteId, landingSiteId, undefined)
        t.uav_status = uavStatus
        if (landingAcceptedAt !== undefined) {
            t.landing_accepted = true
            t.landing_accepted_at = landingAcceptedAt
        }
        return t
    }

    /// 白名单**逐档**（与后端 `ops.go` 里那份逐字对应，用户 2026-09-22 裁定 2B）。
    /// ⚠️ 两半都要：六档各自为真，**阈值之下**的档（PREFLIGHT）与未知值必须为假——
    ///    少了后一半，一个恒真的实现也能让六档全绿。
    /// ‼️ 取**白名单**而非"排除法"：`table_uav.status` 无 CHECK 约束，将来多一个状态时
    ///    排除法会把新状态**静默**放行；白名单则 fail-closed（那正是这里要的）。
    function test_isAirborneReady_whitelistIsExact() {
        var ok = ["READY_TO_TAKEOFF", "TAKEOFF", "IN_FLIGHT", "LANDING", "RETURNING", "EMERGENCY_LANDING"]
        for (var i = 0; i < ok.length; i++)
            verify(OpsCommon.isAirborneReady(ok[i]), ok[i] + " 在白名单内 ⇒ 必须为 true")

        var notOk = ["PREFLIGHT", "PARKED", "", "IDLE", undefined, null]
        for (var j = 0; j < notOk.length; j++)
            verify(OpsCommon.isAirborneReady(notOk[j]) === false,
                   String(notOk[j]) + " 不在白名单内 ⇒ 必须是**真 bool** false"
                   + "（undefined 会让调用点的可见性判定退回默认值 true）")
    }

    /// 本次 bug 的**正面判据**：飞机已飞到本站、监控员**还没发起移交**（零交接）。
    /// 改前 `isInbound` 要求 `LANDING || pendingPhase(LANDING) || landingAccepted`，三项全假
    /// ⇒ 卡片不出现，而飞机数据照常显示——用户看到的就是那个"诡异"。
    /// ⚠️ `takeoff_site_id = 3`（他站）是**刻意**的：写成本站的话 `isOutbound` 也会命中，
    ///    将来若有人把两个判据合成一条，"进站那半句放行了"就与"出站那半句放行了"不可区分。
    function test_isInbound_airborneTaskAtMyLandingSite() {
        var t = _inboundTask(91103, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        verify(OpsCommon.isInbound(t, 1, {}),
               "飞机 IN_FLIGHT、降落在本站、零交接 ⇒ 必须判为进站（改前为 false，正是本 bug）")
    }

    /// 收窄判据：「到站**本站**」这四个字本身要有判据。
    /// 上面那条在**任何**一条他站起飞的航班上都成立，真正收到本站的只有 `landing_site_id`。
    /// 少了这一格，把判据写成「凡白名单内的在飞航班一律进站」也能全绿——后果是**每个**站点的
    /// 列表里塞满别人家的航班。
    function test_isInbound_stillRequiresMyLandingSite() {
        verify(!OpsCommon.isInbound(_inboundTask(91104, "IN_FLIGHT", 3, 99, "IN_FLIGHT"), 1, {}),
               "降落在 99 站 ⇒ 对本站点而言只是路过，不得进站")
        verify(!OpsCommon.isInbound(_inboundTask(91105, "IN_FLIGHT", 3, undefined, "IN_FLIGHT"), 1, {}),
               "缺 landing_site_id ⇒ 不得进站")
    }

    /// ‼️ 新增的白名单分支是 **OR 并上**，不是替换——与后端同日实测的**同一形状的锁**。
    /// 三格各钉既有分支的一项，且**飞机状态都在白名单外**（PARKED）：
    /// 不这么做的话白名单分支会把它们一并放行，这一格就退化成"什么都没测"。
    ///
    /// ⚠️ 第三格是用户裁定⑤（接引后置顶）的**入口条件**：飞机接引后往往很快落地停稳
    /// （`PARKED`，白名单外），此刻若进站判据只剩白名单一项，那张刚被置顶的卡片
    /// 会在停稳的瞬间**整条消失**——置顶功能看起来"时好时坏"。
    function test_isInbound_keepsExistingBranches() {
        verify(OpsCommon.isInbound(_inboundTask(1, "LANDING", 3, 1, "PARKED"), 1, {}),
               "任务已 LANDING ⇒ 进站（既有第一项：与飞机状态无关）")

        var pending = _inboundTask(2, "IN_FLIGHT", 3, 1, "PARKED")
        pending.handover = _embeddedHo(7, "LANDING", 8)
        verify(OpsCommon.isInbound(pending, 1, {}),
               "有 PENDING(LANDING) 交接 ⇒ 进站（既有第二项：监控员已发起移交、等本站签入）")

        verify(OpsCommon.isInbound(_inboundTask(3, "IN_FLIGHT", 3, 1, "PARKED", "2026-10-02 09:00:00"), 1, {}),
               "已接引 ⇒ 进站（既有第三项，也是「接引后置顶」那一段的入口）")
    }

    /// ‼️ **用户 2026-10-02 报的那条**，逐字复刻真库：
    ///   「使用 site_atc 登录 qgc1，显示飞行任务（关联 10000385）从平谷飞北七家，
    ///     飞机状态是 READY_TO_TAKEOFF；使用 nd_test 登录 qgc3，屏幕上没有任务列表」
    /// 真库实测值：task **91103** / `E2E-迫降-001` / `status='READY'` / `site_id=1`（平谷）/
    /// `landing_site_id=2`（北七家）/ uav id=6 `status='READY_TO_TAKEOFF'`，**零交接行**。
    /// 改前外层白名单 `IN_FLIGHT`/`LANDING` 把 `'READY'` 挡在门外 ⇒ 北七家的列表**整个是空的**，
    /// 而飞机遥测走另一条路照常显示。这正是"轨迹和数据都在、任务卡片不在"。
    /// ⚠️ `takeoff_site_id=1 ≠ mySiteId=2` 是**刻意**的：写成本站的话出站半句也会命中，
    ///    将来若有人把两个判据合成一条，"进站半句放行了"就与"出站半句放行了"不可区分。
    function test_isInbound_taskNotYetAirborneAtMyLandingSite() {
        var t = _inboundTask(91103, "READY", 1, 2, "READY_TO_TAKEOFF")
        verify(OpsCommon.isOutbound(t, 2, {}) === false, "夹具前提：对北七家而言不是出站卡")
        verify(OpsCommon.isInbound(t, 2, {}),
               "任务 READY、飞机 READY_TO_TAKEOFF、降落本站、零交接 ⇒ 必须进站（改前 false，正是本 bug）")

        // 阴性对照：同形状但飞机还没上电（白名单外）且零交接 ⇒ 不得进站。
        // 少了这一格，"凡非终态的任务一律进站"也能让上一行绿 —— 那会把**每个**站点的列表
        // 塞满停在地上、与本站无关的航班。本次放宽的是**外层状态闸**，不是四项判据。
        verify(OpsCommon.isInbound(_inboundTask(91106, "READY", 1, 2, "PARKED"), 2, {}) === false,
               "降落本站但飞机 PARKED、零交接 ⇒ 不得进站")
    }

    /// ‼️ **外层闸（终态黑名单）自己**的判据。夹具**只**让这一层挡得住：其余四项全真。
    /// 少了这一格，把外层闸整个删掉也能全绿 —— `test_isInbound_keepsExistingBranches`
    /// 里三条的 `status` 都是非终态，一个都钉不到它（同 `isAirborneReady` 上方说的
    /// "少了后一半，一个恒真的实现也能让六档全绿"）。
    /// ⚠️ 交接那一路尤其重要：`table_task_handover` 是**历史表**，任务飞完之后交接行**不会消失**
    ///    ⇒ 没有这一层，一条已完成的历史任务会靠分支②或③**永久回流**到降落场的列表里。
    function test_isInbound_dropsFinishedTask() {
        var fin = ["COMPLETED", "ABORTED", "CANCELED", "CANCELLED"]
        for (var i = 0; i < fin.length; i++) {
            // 一路：飞机在白名单内（分支④为真）⇒ 只有外层闸挡得住。
            verify(OpsCommon.isInbound(_inboundTask(92000 + i, fin[i], 1, 2, "IN_FLIGHT"), 2, {}) === false,
                   fin[i] + " + 飞机在飞 + 降落本站 ⇒ 终态不得进站（此处只有外层闸拦得住）")

            // 另一路：挂着一笔 LANDING 交接（分支②为真）⇒ 同样只有外层闸挡得住。
            var byHo = _inboundTask(92100 + i, fin[i], 1, 2, "PARKED")
            byHo.handover = _embeddedHo(7, "LANDING", 8)
            verify(OpsCommon.isInbound(byHo, 2, {}) === false,
                   fin[i] + " + 挂着 LANDING 交接 ⇒ 终态不得靠分支②回流")
        }
    }

    /// 四段顺序（用户 2026-10-02 裁定，两处原话见本组标题）：
    /// ① 待我签入 → ② 已接引（按**接引时刻升序**）→ ③ 出站 → ④ 未接引进站。
    /// ⚠️ 输入顺序**刻意打乱**：照顺序喂进去的话，「按段重排」与「原样返回」不可区分。
    function test_siteTasks_fourSegments() {
        var awaiting = _siteTask(1, "IN_FLIGHT", 3, 1, _embeddedHo(7, "LANDING", 8))
        var acc2 = _inboundTask(2, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:00")
        var acc3 = _inboundTask(3, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:05")
        var out4 = _siteTask(4, "TAKEOFF", 1, 3, undefined)
        var in5 = _inboundTask(5, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        var all = [out4, in5, acc3, acc2, awaiting]
        var map = { 1: _embeddedHo(7, "LANDING", 8) }

        var got = OpsCommon.siteTasks(all, true, true, 1, map)
        compare(got.length, 5, "一条不丢、一条不重")
        compare(got[0].task_id, 1, "① 待我签入最前（2026-09-24 裁定 丙-2 不动）")
        compare(got[1].task_id, 2, "② 已接引：先接引的在前")
        compare(got[2].task_id, 3, "② 后接引的在后（按接引时刻升序，不是按输入顺序）")
        compare(got[3].task_id, 4, "③ 出站：排在**已接引之后**（接引即置顶）、未接引进站之前")
        compare(got[4].task_id, 5, "④ 未接引进站：垫底（「到站任务卡片显示在出站任务卡片的后面」）")
    }

    /// 已接引却**没有时刻**（后端记录的那个不可达形状）⇒ 排在有时刻的**之后**。
    /// ‼️ 直接拿 `landing_accepted_at` 当排序键、缺值当 `""`（或 `undefined`）会让它排到
    ///    **最前**（空串/NaN 比较最小）⇒ 顺序错乱，而界面上没有任何报错，只是顺序不对。
    function test_siteTasks_acceptedWithoutTimestampSortsLast() {
        var noTs = _inboundTask(1, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:00")
        delete noTs.landing_accepted_at           // 保留 landing_accepted = true
        var withTs = _inboundTask(2, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:09")

        var got = OpsCommon.siteTasks([noTs, withTs], true, true, 1, {})
        compare(got[0].task_id, 2, "有时刻的在前；无时刻的不得因「空串最小」顶到前面")
        compare(got[1].task_id, 1, "无时刻的排在后面（保守：缺信息的不能顶掉有信息的）")
    }

    //-------------------------------------------------------------------------
    // 站点视图的四段：**排序与配色同源**（用户 2026-10-02 裁定②⑤⑥）
    //   段号是契约：`siteTasks` 按 0→1→2→3 拼接，卡片配色也按段号判
    //   ⇒ 两处共用 `siteSection`，不可能出现"排在进站段却涂出站色"。
    //-------------------------------------------------------------------------

    /// 四段的段号本身。数值写成**字面量**：改常量值会让这组一起红，那是提醒
    /// "段号被排序与配色同时依赖"，改之前得两处一起看。
    function test_siteSection_fourSegments() {
        var landing = _embeddedHo(7, "LANDING", 8)

        compare(OpsCommon.siteSection(_siteTask(1, "IN_FLIGHT", 3, 1, landing), true, true, 1, { 1: landing }),
                0, "待我签入 ⇒ 段 0（最前，2026-09-24 裁定 丙-2）")

        compare(OpsCommon.siteSection(_inboundTask(2, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:00"),
                                      true, true, 1, {}),
                1, "已接引 ⇒ 段 1（置顶）")

        compare(OpsCommon.siteSection(_siteTask(3, "TAKEOFF", 1, 3, undefined), true, true, 1, {}),
                2, "出站 ⇒ 段 2")

        compare(OpsCommon.siteSection(_inboundTask(4, "IN_FLIGHT", 3, 1, "IN_FLIGHT"), true, true, 1, {}),
                3, "未接引进站 ⇒ 段 3（垫底，裁定②「显示在出站任务卡片的后面」）")
    }

    /// 勾选框的收窄要有判据：两个勾选框各自关掉时，对应那一侧不得入列。
    /// 少了这一格，把 `siteSection` 写成"凡进站一律收"也能全绿——后果是
    /// 用户取消勾选"进站"之后到站卡片还在列表里。
    function test_siteSection_noneWhenThatBoxIsUnchecked() {
        compare(OpsCommon.siteSection(_siteTask(1, "TAKEOFF", 1, 3, undefined), false, true, 1, {}), -1,
                "出站卡片：只勾「进站」时不得入列")
        compare(OpsCommon.siteSection(_inboundTask(2, "IN_FLIGHT", 3, 1, "IN_FLIGHT"), true, false, 1, {}), -1,
                "进站卡片：只勾「出站」时不得入列")
    }

    /// ‼️ 配色判据必须与**排序位置**一致。三格分别是段 1 / 段 3 / 段 2，第三格是关键：
    /// 同站起降的卡片 `isInbound` 与 `isOutbound` **同时为真**，按既有口径（出站优先）
    /// 落段 2 ⇒ 必须取**出站色**。若配色改判 `isInbound` 就会涂成进站色，
    /// 而它排在出站那一段——"位置说一套、颜色说另一套"。
    function test_sectionIsInbound_matchesSortPosition() {
        var acc = _inboundTask(1, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:00")
        compare(OpsCommon.siteSection(acc, true, true, 1, {}), 1, "夹具前提：落段 1")
        verify(OpsCommon.sectionIsInbound(1, acc, 1, {}), "段 1 ⇒ 进站色")

        var uncon = _inboundTask(2, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        compare(OpsCommon.siteSection(uncon, true, true, 1, {}), 3, "夹具前提：落段 3")
        verify(OpsCommon.sectionIsInbound(3, uncon, 1, {}), "段 3 ⇒ 进站色")

        var sameSite = _inboundTask(3, "IN_FLIGHT", 1, 1, "IN_FLIGHT")
        verify(OpsCommon.isInbound(sameSite, 1, {}), "夹具前提：同站起降**同时**满足进站判据")
        compare(OpsCommon.siteSection(sameSite, true, true, 1, {}), 2, "同站起降未接引 ⇒ 落段 2（出站优先）")
        verify(!OpsCommon.sectionIsInbound(2, sameSite, 1, {}),
               "落段 2 ⇒ 取**出站色**（即使 isInbound 为真）：配色与排序位置必须一致")

        verify(!OpsCommon.sectionIsInbound(-1, uncon, 1, {}), "未入列（-1）⇒ 不得判成进站色")
    }

    /// 段 0（待我签入）**两种相位都可能**：站点视图收到的是 LANDING 待办（进站卡），
    /// 监控员视图是 ROUTE 待办（出站卡）。判据同一条、相位不同 ⇒ 配色不由段号决定，
    /// 追问一次 `isInbound`。
    /// ⚠️ 少了第二格，"段 0 恒为进站色"也能全绿——那会让监控员视图里每一张待签入卡
    /// 都涂成青绿（把 `/handovers/pending` 的角色过滤当成永不变的事实）。
    function test_sectionIsInbound_awaitingFollowsPhase() {
        var lh = _embeddedHo(7, "LANDING", 8)
        var incoming = _siteTask(1, "IN_FLIGHT", 3, 1, lh)
        compare(OpsCommon.siteSection(incoming, true, true, 1, { 1: lh }), 0, "夹具前提：落段 0")
        verify(OpsCommon.sectionIsInbound(0, incoming, 1, { 1: lh }),
               "LANDING 待办 ⇒ 进站卡 ⇒ 进站色")

        var rh = _embeddedHo(9, "ROUTE", 16)
        var outgoing = _siteTask(2, "IN_FLIGHT", 1, 3, rh)
        compare(OpsCommon.siteSection(outgoing, true, true, 1, { 2: rh }), 0, "夹具前提：也落段 0")
        verify(!OpsCommon.sectionIsInbound(0, outgoing, 1, { 2: rh }),
               "ROUTE 待办 ⇒ 出站卡 ⇒ 出站色（段号相同、相位不同）")
    }

    //-------------------------------------------------------------------------
    // 站点视图**地图 marker** 的配色（用户 2026-10-02 裁定：「出站用黄色（用最醒目换色），
    // 入站用绿色（最醒目的绿色）」＋「告警优先，其余黄/绿」＋「SEC_NONE 沿用按状态着色」）
    //-------------------------------------------------------------------------

    /// 两色的**正面断言**：出站取黄、进站取绿。数值写成字面量而不是读
    /// `OpsCommon.OUTBOUND_MARKER_COLOR`——读常量的话，把常量改成任意颜色都照样全绿，
    /// 等于这格只验了"函数返回了它自己那个常量"。
    function test_siteMarkerColor_outboundYellowInboundGreen() {
        var out = _siteTask(3, "TAKEOFF", 1, 3, undefined)
        compare(OpsCommon.siteSection(out, true, true, 1, {}), 2, "夹具前提：出站 ⇒ 落段 2")
        compare(OpsCommon.siteMarkerColor(out, true, true, 1, {}, 0, false), "#ffd400",
                "出站 ⇒ 醒目的黄")

        var inb = _inboundTask(4, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        compare(OpsCommon.siteSection(inb, true, true, 1, {}), 3, "夹具前提：未接引进站 ⇒ 落段 3")
        compare(OpsCommon.siteMarkerColor(inb, true, true, 1, {}, 0, false), "#00e676",
                "进站 ⇒ 醒目的绿")
    }

    /// ‼️ 「两个绿**刻意不同色**」是本组唯一的判据：`statusColor` 的"已停稳绿" `#2ecc71`
    /// 说的是**状态**，本案的 `#00e676` 说的是**归属**。这一格用一条**同时**满足两边的任务
    /// （`LANDING` ＋ 降落本站 ＋ 已落地）把两个分支摆在一起：若有人为了"统一色板"把进站绿
    /// 改成 `#2ecc71`，本格立刻红——而界面上"停稳了"与"归本站"从此再也分不开。
    /// ⚠️ 同一夹具在**未**落地时必须是进站绿：否则"已落地优先"那半句没有判据。
    function test_siteMarkerColor_landedGreenIsNotTheInboundGreen() {
        var landed = _inboundTask(5, "LANDING", 3, 1, "LANDING")
        compare(OpsCommon.siteSection(landed, true, true, 1, {}), 3, "夹具前提：进站卡（落段 3）")

        compare(OpsCommon.siteMarkerColor(landed, true, true, 1, {}, 0, true), "#2ecc71",
                "已落地 ⇒ 取「已停稳」绿")
        compare(OpsCommon.siteMarkerColor(landed, true, true, 1, {}, 0, false), "#00e676",
                "同一条任务尚未落地 ⇒ 取「归本站」绿")
        verify(OpsCommon.siteMarkerColor(landed, true, true, 1, {}, 0, true)
               !== OpsCommon.siteMarkerColor(landed, true, true, 1, {}, 0, false),
               "两个绿必须**不同色**：同色会把「停稳了」读成「归本站」")
        verify("#00e676" !== "#2ecc71" && "#ffd400" !== "#2ecc71",
               "常量前提：本组三色互不相同（上面两格才可能失败）")
    }

    /// ‼️ **告警优先**（用户裁定）不是修饰语：这一格拿一条"否则会涂成出站黄"的任务
    /// （本站起飞、非终态）＋一个**已过期**的交接 ⇒ 必须是超时红。
    /// 少了这一格，"黄绿盖掉超时红"也能全绿——那等于把"接手窗口正在关闭"从地图上删掉。
    /// ⚠️ 夹具必须**同时**满足黄的那一支，否则本格是靠"反正它也进不了黄绿分支"过关的。
    function test_siteMarkerColor_timeoutRedBeatsOutboundYellow() {
        var t = _siteTask(7, "TAKEOFF", 1, 3, undefined)
        compare(OpsCommon.siteMarkerColor(t, true, true, 1, {}, 0, false), "#ffd400",
                "夹具前提：无交接时它就是出站黄")
        var h = { 7: { task_id: 7, phase_to: "ROUTE", deadline_at: "2026-09-23 00:00:00" } }
        compare(OpsCommon.siteMarkerColor(t, true, true, 1, h, Date.parse("2026-09-23T01:00:00Z"), false),
                "#ff3b3b", "交接已超时 ⇒ 红，**优先于**出站黄")
    }

    /// 第二档告警：任务中止 / 异常。夹具是"否则会涂进站绿"的那种 ⇒ 这一格钉的是**优先关系**。
    ///
    /// ‼️ `ABORT` 与 `FAILED` 是**载重**的那两档，`ABORTED` 不是——三者**不是一回事**：
    ///    · `ABORTED` ∈ `FINISHED_TASK_STATUSES` ⇒ 既非出站也非进站 ⇒ 落 `SEC_NONE` ⇒
    ///      兜底的 `statusColor` 本来就给红。**删掉中止那一档，它照样红。**
    ///    · `ABORT` / `FAILED` **不在**那个终态集合里 ⇒ 这条"降落本站 + 飞机 `IN_FLIGHT`"
    ///      的任务会被判成**进站** ⇒ 删掉中止那一档它立刻变**进站绿**。
    ///    本格第一行就是钉这个前提（落段 3）：夹具若用 `ABORTED`，"中止优先"这条断言
    ///    会因为夹具压根进不了黄绿分支而**假绿**——这正是它第一版写成 `ABORTED` 时的实况。
    ///    （同族坑：`ABORT` / `ABORTED` 是**两个字面量**。）
    function test_siteMarkerColor_abortRedBeatsInboundGreen() {
        var stat = ["ABORT", "FAILED"]
        for (var i = 0; i < stat.length; i++) {
            var t = _inboundTask(6, stat[i], 3, 1, "IN_FLIGHT")
            compare(OpsCommon.siteSection(t, true, true, 1, {}), 3,
                    "夹具前提（" + stat[i] + "）：落段 3，否则它压根不会涂进站绿、本格假绿")
            verify(OpsCommon.sectionIsInbound(3, t, 1, {}), "夹具前提（" + stat[i] + "）：进站那一支为真")
            compare(OpsCommon.siteMarkerColor(t, true, true, 1, {}, 0, false), "#ff3b3b",
                    stat[i] + " ⇒ 红，**优先于**进站绿")
        }

        // 阴性对照：`ABORTED` 走的是**兜底**那条路，不是中止那一档。两处都得是红——
        // 少了这一格，"中止档只收 `ABORT`/`FAILED`"与"收全三个"不可区分。
        var aborted = _inboundTask(7, "ABORTED", 3, 1, "IN_FLIGHT")
        compare(OpsCommon.siteSection(aborted, true, true, 1, {}), -1,
                "夹具前提：`ABORTED` 是终态 ⇒ 未入列（它变红靠兜底，不靠中止那一档）")
        compare(OpsCommon.siteMarkerColor(aborted, true, true, 1, {}, 0, false), "#ff3b3b",
                "`ABORTED` ⇒ 同样红（经 `SEC_NONE` 兜底）")
    }

    /// ‼️ 第三类 `SEC_NONE`（两个勾选框都没勾到它）**沿用现状的状态色**（用户裁定）。
    /// 判据直接与 `statusColor` 对拍——这正是"沿用"二字的字面含义；改成涂灰/涂透明
    /// 都会红。夹具取 `IN_FLIGHT`（状态色 `#ffc107`，与出站黄 `#ffd400` **不同字面**），
    /// 否则"回落成出站黄"也能蒙混过关。
    /// ⚠️ 两格都要：只勾一侧时另一侧的任务同样落 `SEC_NONE`。
    function test_siteMarkerColor_noneFallsBackToStatusColor() {
        var out = _siteTask(8, "IN_FLIGHT", 1, 3, undefined)
        var inb = _inboundTask(9, "IN_FLIGHT", 3, 1, "IN_FLIGHT")

        compare(OpsCommon.siteSection(out, false, false, 1, {}), -1, "夹具前提：两侧都不勾 ⇒ 未入列")
        compare(OpsCommon.siteMarkerColor(out, false, false, 1, {}, 0, false),
                OpsCommon.statusColor(out, 0, {}, false), "未入列 ⇒ 沿用状态色")
        compare(OpsCommon.siteMarkerColor(out, false, false, 1, {}, 0, false), "#ffc107",
                "并且确实是**状态色**（`IN_FLIGHT` 的黄），不是出站黄")

        compare(OpsCommon.siteSection(inb, true, false, 1, {}), -1, "夹具前提：只勾出站 ⇒ 进站卡未入列")
        compare(OpsCommon.siteMarkerColor(inb, true, false, 1, {}, 0, false),
                OpsCommon.statusColor(inb, 0, {}, false), "只勾出站 ⇒ 到站飞机不得被涂成进站绿")
    }

    /// ‼️ 勾选框那**两个实参必须真的被读**。少了这一格，把实现写成"永远按出站处理"
    /// （忽略 `outbound`/`inbound`）也能让上面几格里的出站部分全绿——
    /// 而用户取消勾选"进站"之后，到站飞机在**列表里消失、地图上却仍是绿的**。
    /// 判据：同一条进站任务，两勾 ⇒ 进站绿；不勾进站 ⇒ 不再是进站绿。
    function test_siteMarkerColor_checkboxArgsAreActuallyRead() {
        var inb = _inboundTask(10, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        compare(OpsCommon.siteMarkerColor(inb, true, true, 1, {}, 0, false), "#00e676",
                "两勾 ⇒ 进站绿")
        verify(OpsCommon.siteMarkerColor(inb, true, false, 1, {}, 0, false) !== "#00e676",
               "取消勾选「进站」⇒ 该机不再取进站绿（否则那个勾选框对地图毫无作用）")

        var out = _siteTask(11, "TAKEOFF", 1, 3, undefined)
        compare(OpsCommon.siteMarkerColor(out, true, true, 1, {}, 0, false), "#ffd400",
                "两勾 ⇒ 出站黄")
        verify(OpsCommon.siteMarkerColor(out, false, true, 1, {}, 0, false) !== "#ffd400",
               "取消勾选「出站」⇒ 该机不再取出站黄")
    }

    /// ‼️ 与排序位置**同源**：同站起降的航班 `isInbound` 与 `isOutbound` 同时为真，
    /// 按既有口径（出站优先）落段 2 ⇒ 地图上必须是**出站黄**，与它排在出站那一段一致。
    /// 少了这一格，配色改判 `isInbound` 会让"位置说一套、颜色说另一套"，而卡片那边
    /// （`test_sectionIsInbound_matchesSortPosition`）照样全绿——两边用同一个函数才拦得住。
    function test_siteMarkerColor_matchesSortPosition() {
        var sameSite = _inboundTask(12, "IN_FLIGHT", 1, 1, "IN_FLIGHT")
        verify(OpsCommon.isInbound(sameSite, 1, {}), "夹具前提：同站起降**同时**满足进站判据")
        compare(OpsCommon.siteSection(sameSite, true, true, 1, {}), 2, "落段 2（出站优先）")
        compare(OpsCommon.siteMarkerColor(sameSite, true, true, 1, {}, 0, false), "#ffd400",
                "落段 2 ⇒ 出站黄（即使 isInbound 为真）：地图配色与列表排序位置必须一致")
    }

    //-------------------------------------------------------------------------
    // 进站卡片的动作闸（用户 2026-10-02 裁定③ + 第二轮裁定）
    //-------------------------------------------------------------------------

    /// ‼️ **需求③的正面判据**：本次新增的那一类卡片（到站本站、飞机在飞、零交接）上
    /// **没有任何进站动作**。这一格必须过，因为改前那张卡片根本不出现——
    /// 它是随 `isInbound` 放宽一起被"带进来"的，动作闸不能跟着一起放宽。
    /// ⚠️ 断言写 `=== false` 而不是 `!...`：`undefined` 会让 QML 的 `visible` 退回
    ///    默认值 **true**（每一张卡都冒出按钮），而 `!undefined` 是 true，会**假绿**。
    function test_inboundActionable_falseForNewlyVisibleAirborneCard() {
        var t = _inboundTask(91103, "IN_FLIGHT", 3, 1, "IN_FLIGHT")
        verify(OpsCommon.isInbound(t, 1, {}),
               "夹具前提：这类卡片确实进站（不成立的话本格退化成「什么都没测」）")
        verify(OpsCommon.inboundActionable(t, 1, {}) === false,
               "已进站但**未接引** ⇒ 动作闸必须给出真 bool false")
    }

    /// 「隐藏的按钮被点亮」的两个时刻（用户第二轮裁定：监控员签出、本站签入后才点亮）。
    /// 第四格是阴性对照：不在本站降落的在飞航班，飞机状态再"在飞"也不得可操作。
    function test_inboundActionable_trueOnceLandedHandedOver() {
        verify(OpsCommon.inboundActionable(
                   _inboundTask(1, "IN_FLIGHT", 3, 1, "IN_FLIGHT", "2026-10-02 09:00:00"), 1, {}),
               "已接引 ⇒ 可操作（签出→签入完成的那一刻点亮）")

        verify(OpsCommon.inboundActionable(_inboundTask(2, "LANDING", 3, 1, "LANDING"), 1, {}),
               "任务已进入 LANDING ⇒ 可操作（与飞机状态无关）")

        verify(OpsCommon.inboundActionable(
                   _inboundTask(3, "IN_FLIGHT", 3, 1, "PARKED", "2026-10-02 09:00:00"), 1, {}),
               "接引后飞机已停稳（PARKED，白名单外）⇒ 仍可操作（置顶卡片不得因此失效）")

        // ‼️ 这一格是 `inboundActionable` 里**「必须先进站」那一层**的**唯一**判据：
        //    它的 `status` 是 `LANDING` ⇒ `LANDING || landingAccepted` 那一半为**真**，
        //    只靠"降落在 99 站"把它挡下来 ⇒ 删掉那一层，本格立刻红。
        // ⚠️ 实测过：本格原写成"降落在 99 站 + 未接引 + 白名单内的飞机"，
        //    删掉那一层**全绿**——因为三项恰好都不满足，那一层被架空而无人发现。
        //    要判一个守卫，夹具必须**只**让它一个人挡得住（同"两层守卫都能拒同一请求"那形状）。
        // ⚠️ 可达性：本站起飞、他站降落、本站尚未签出的卡片此刻正是这个形状
        //    （它在列表里是**出站**卡）——不是为测试构造出来的。
        verify(OpsCommon.inboundActionable(_inboundTask(4, "LANDING", 3, 99, "LANDING"), 1, {}) === false,
               "降落在 99 站 ⇒ 对本站不是进站卡，动作闸必须为 false（哪怕它已是 LANDING）")
    }

    /// ⚠️ 2026-10-02 外层闸放宽**新开**的一格：任务**还没起飞**、却带着 `landing_accepted`
    ///    （例如被人工复位过）。`isInbound` 会放它进来（非终态 ∧ 降落本站 ∧ 已接引），
    ///    但卡上**不得**出现降落动作——对一架停在地上的飞机发降落指令没有意义。
    ///    ‼️ 本格钉的是 `inboundActionable` 里那个 `status === "IN_FLIGHT"` 合取项：它在改前
    ///    是**冗余**的（由外层白名单保证），外层一放宽就不再等价 ⇒ **删掉它本格即红**。
    /// ⚠️ 真库当前 **0 行**（结构上可达，未实测到实例）。写成本格不是因为观测到了它，
    ///    而是因为那个合取项当初被删的理由（"外层保证 IN_FLIGHT"）已被本次改动作废。
    function test_inboundActionable_notAirborneEvenIfAccepted() {
        var t = _inboundTask(91107, "READY", 1, 2, "READY_TO_TAKEOFF", "2026-10-02 09:00:00")
        verify(OpsCommon.isInbound(t, 2, {}),
               "夹具前提：它确实进站（不成立的话本格退化成「什么都没测」）")
        verify(OpsCommon.landingAccepted(t), "夹具前提：`landing_accepted` 确实为真")
        verify(OpsCommon.inboundActionable(t, 2, {}) === false,
               "任务 READY（还没起飞）⇒ 动作闸必须给出**真 bool** false，哪怕已接引")
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

    //-------------------------------------------------------------------------
    // 中段的**分段标题**（《航线监控员主界面设计-20260922.md》§4.2）
    //   用户 2026-09-29 报障：「点航线，航班列表不变」——第 1 节（异常 ∪ 待我签入）
    //   本就**不受航线选中过滤**（裁定 ⑥ 的硬约束，见 `middleSectionTasks` 注释），
    //   但那两节此前被**拍平成一个数组**渲染 ⇒ 用户看不出哪些是"因为异常才常驻"的，
    //   整体读起来就是"点了航线列表没反应"。
    //   裁定（用户 2026-09-29）：**补分段标题、过滤不动**（第 1 节照旧常驻，不推翻裁定 ⑥）。
    //   ⇒ 本组钉住拆出来的**两节本身**；渲染（段头位置、空段头）由 QML 侧承担。
    //-------------------------------------------------------------------------

    /// ‼️ **重构保护格**：拆出来的两节拼回去，必须与既有 `middleSectionTasks`
    /// **逐项同序**。`middleSectionTasks` 的调用点（`OpsCommon.siteTasks` 之外的
    /// 视图接线）在本次改动里**不该有任何行为变化**——分段是**渲染层**的事。
    /// 若实现成"two-section 版本重写一遍判据"，两处判据迟早漂移，而漂移的症状是
    /// 列表与地图 marker 不一致，不报错。
    function test_middleSectionSplit_flattensToSameOrderAsMiddleSectionTasks() {
        var ab = _abnormalTask(1)
        var n1 = _routeTask(2, 7)
        var n2 = _routeTask(3, 8)
        var all = [ab, n1, n2]

        // 路径 A：分段结果拼接
        var split = OpsCommon.middleSectionSplit(all, null, {})
        compare(split.first.length, 1, "第 1 节只收异常/待签入")
        compare(split.first[0].task_id, 1)
        compare(split.second.length, 2, "第 2 节收其余在航航班")
        compare(split.second[0].task_id, 2)
        compare(split.second[1].task_id, 3)

        // 路径 B：既有拍平函数。两条路径必须**同长同序**（阳性对照在下面那条 assert 里）
        var flat = OpsCommon.middleSectionTasks(all, null, {})
        var joined = split.first.concat(split.second)
        compare(joined.length, flat.length, "两节拼起来必须与拍平结果等长")
        for (var i = 0; i < flat.length; i++)
            compare(joined[i].task_id, flat[i].task_id, "第 " + i + " 项次序必须一致")
    }

    /// 选中航线时**只有第 2 节**被过滤；第 1 节照旧常驻——这正是"点航线列表不变"的
    /// 合法来源，也是分段标题要解释给用户看的那件事。
    function test_middleSectionSplit_filtersSecondSectionOnly() {
        var abOther = _abnormalTask(1)          // 异常航班，属于**未被选中**的航线
        var nSel = _routeTask(2, 7)             // 选中航线的航班
        var nOther = _routeTask(3, 8)           // 别的航线的航班

        var split = OpsCommon.middleSectionSplit([abOther, nSel, nOther], 7, {})
        compare(split.first.length, 1, "异常航班不受选中航线过滤（裁定 ⑥）")
        compare(split.first[0].task_id, 1, "常驻的那条恰恰属于别的航线")
        compare(split.second.length, 1, "第 2 节只留选中航线的")
        compare(split.second[0].task_id, 2, "且留下的必须是选中航线那一条，不是别的")
    }

    /// 既异常、又属于选中航线的航班：**只出现在第 1 节**。
    /// 漏了去重的症状是同一条航班在列表里出现两次，看起来像"重复的数据"，不报错。
    function test_middleSectionSplit_dedupesIntoFirstSection() {
        var both = _abnormalTask(1)
        both.route_id = 7                       // 既是异常、又在选中航线上
        var nSel = _routeTask(2, 7)

        var split = OpsCommon.middleSectionSplit([both, nSel], 7, {})
        compare(split.first.length, 1)
        compare(split.first[0].task_id, 1)
        compare(split.second.length, 1, "已在第 1 节的不得在第 2 节再出现一次")
        compare(split.second[0].task_id, 2)
    }

    /// 「待我签入」与异常**同口径**进第 1 节——分段后它也得在置顶那一段里，
    /// 否则"补分段标题"会把 2026-09-24 裁定 丙-2 的提示推到下面去。
    function test_middleSectionSplit_putsAwaitingCheckinInFirstSection() {
        var t = _hoTask(91103, "IN_FLIGHT", 1, _embeddedHo(7, "ROUTE", 16))
        var split = OpsCommon.middleSectionSplit(
                    [t, _routeTask(2, 7)], 7, { 91103: _embeddedHo(7, "ROUTE", 16) })
        compare(split.first.length, 1, "待我签入必须进置顶节")
        compare(split.first[0].task_id, 91103)
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
    /// 可选第 5 参 `id`（航点 id）：只有"指认终点站"那一组用例用得上，
    /// 其余调用点照旧传 4 个实参 ⇒ `id` 为 `undefined`，行为一字不变。
    function _wp(lat, lon, alt, cmd, id) {
        return { id: id, lat: lat, lon: lon, altitude: alt, command: cmd }
    }

    /// route 20 的两个航点。值依据：**本计划 brief（2026-09-23）转述的真库观察**，
    /// 未经本任务独立复核（本任务无数据库访问权限）；下游落地前须在有库环境核验。
    function _route20() {
        return [_wp(39.748800, 116.143400, 50.0, 16),
                _wp(39.748823, 116.143486, 50.0, 21)]
    }

    function test_routeMissionItems_emptyReturnsEmpty() {
        // ‼️ NRRSM 后签名多了第 4 参 `cruiseAGL`，**缺它一律回 `[]`**（见 `OpsCommon.js`）。
        //    既有各格测的是 wps 侧的口径 ⇒ 一律显式补上后继实参，否则本组会**为错误的理由**通过
        //    （全部回 `[]`，看不出 wps 守卫有没有坏）。
        compare(OpsCommon.routeMissionItems([], undefined, undefined, 0).length, 0, "空数组应回空")
        compare(OpsCommon.routeMissionItems(null, undefined, undefined, 0).length, 0, "null 应回空")
        compare(OpsCommon.routeMissionItems(undefined, undefined, undefined, 0).length, 0, "undefined 应回空")
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
        // ‼️ `cruiseAGL = 0`（未设定）⇒ 高度与加参前**逐字相同** ⇒ 本格照旧断"原样透传"。
        var items = OpsCommon.routeMissionItems([_wp(39.7488, 116.1434, 463.0, 16)], undefined, undefined, 0)
        compare(items.length, 1)
        compare(items[0].alt, 463.0, "高度必须原样透传，不得做任何转换")
        compare(items[0].frame, 0,
                "frame 必须是 MAV_FRAME_GLOBAL(0)=AMSL；写成 3 会让 463 被当成离地高度")
        compare(items[0].command, 16)
    }

    /// ‼️ `command=21` 是**航线设计域**的"站点"标记，不是 `MAV_CMD_NAV_LAND`
    ///（后者也恰好是 21，纯属数值巧合）。这条防的是"看到 21 就发降落指令"这个误读 ——
    /// 一旦误读，飞机会在中途**直接降落**，而界面上看不出任何异常。
    ///
    /// 【2026-09-28 裁定更新】用户裁定：**终点站**的站点航点在 **VTOL** 机型上映射为
    /// `MAV_CMD_NAV_VTOL_LAND(85)`（垂起着陆）。本用例覆盖的因此**收窄**为
    /// "非终点 / 非 VTOL"两支。
    /// ⚠️ 85 **不是** 21 —— 本用例顺带钉住"不许有人图省事直接返回设计域那个 21"。
    function test_routeMissionItems_siteWaypointBecomesPlainWaypoint() {
        var items = OpsCommon.routeMissionItems([_wp(39.748823, 116.143486, 50.0, 21)], false, undefined, 0)
        compare(items.length, 1)
        compare(items[0].command, 16, "非 VTOL ⇒ 站点航点必须映射成 NAV_WAYPOINT(16)")
        // 省略第二/第三个实参（显式传 `undefined`）同样按"非 VTOL / 无终点"处理：默认值必须是
        // fail-closed 的那一侧（漏掉降落＝飞机可见地盘旋；多发一个降落＝飞机真的落下去，不可撤销）。
        // （第 4 参 `cruiseAGL` 不可省 —— 省了会整体回 `[]`，本格就会为错误的理由通过。）
        compare(OpsCommon.routeMissionItems([_wp(39.748823, 116.143486, 50.0, 21)], undefined, undefined, 0)[0].command, 16,
                "不传 isVtol ⇒ 默认按非 VTOL，绝不默认启用垂起着陆")
    }

    // ─────────────────────────────────────────────────────────────────────
    // 垂起着陆（VTOL_LAND=85）一组
    //
    // ‼️ 本组的夹具一律**带航点 id**，且分两类形状：
    //   · `_routeRt003()` —— **当前数据源的真实形状**：列表里**没有终点站**；
    //   · `_routeWithEnd()` —— **后端补上起降点之后**才会出现的形状。
    //   两类都要有，缺了任何一类都会得到一个假绿的 ✓：
    //   只测后者 ⇒ 看不见"当前根本不触发"；只测前者 ⇒ 看不见功能是否真的接得上。
    // ─────────────────────────────────────────────────────────────────────

    /// **当前数据源的真实点集**，逐字取自真库（2026-09-28 实测）：
    /// 航线 RT-003 `start_waypoint_id=2`（北七家镇政府）/ `end_waypoint_id=5`（保定市政府），
    /// 而 `GET /routes/:id/waypoints` 返回的**只有** `table_route_waypoint` 两行：
    /// `seq=0 → wp3` 良乡区政府(cmd 21)、`seq=1 → wp4` 房山镇政府(cmd 16)。
    /// ⇒ 起降站是 `table_route` 的两列、**不在该表内**，所以列表里**没有终点站**。
    ///
    /// ⚠️ **危险形状要用它的重排版**（见 `_routeMidStationLast`），不能只用本函数：
    /// RT-003 的**末项**恰好是普通航点(cmd 16)，而 `16 → 16` 与"是不是终点"无关
    /// ⇒ 单用本函数时，"末尾=终点"那条错判据**照样全绿**（已实测：只红 1 格）。
    /// 这正是"夹具必须覆盖能分辨两种实现的那一格"的实例。
    function _routeRt003() {
        return [_wp(39.748823, 116.143486, 50.0, 21, 3),   // 良乡区政府（站点，中途）
                _wp(39.748800, 116.143400, 50.0, 16, 4)]   // 房山镇政府（普通航点，中途）
    }
    /// RT-003 的终点航点 id（= 保定市政府）。**它不在上面那个列表里**。
    readonly property int _rt003EndId: 5

    /// **危险形状**：和 `_routeRt003()` 同点集，只是把两个中途点**换个顺序**，
    /// 于是**末项是站点航点(21) 而它不是终点**。
    /// 真库可达性：webui 的 `moveWp`（`RouteList.vue`）允许自由调整中途点顺序 ⇒
    /// 这个形状在真实链路上**随手可得**。
    /// 判据价值：旧的"末尾=终点"错判据在本形状下会把**良乡区政府**打成 85
    /// ⇒ 飞机在航路中途降落，而目的地是保定市政府。
    function _routeMidStationLast() {
        return [_wp(39.748800, 116.143400, 50.0, 16, 4),   // 房山镇政府（普通航点，中途）
                _wp(39.748823, 116.143486, 50.0, 21, 3)]   // 良乡区政府（站点，中途）← 末项
    }

    /// **后端补上起降点之后**的形状：终点站（id = `_rt003EndId`，站点，cmd 21）
    /// 作为最后一项出现在列表里。坐标取自真库 `table_waypoint.id=5`。
    function _routeWithEnd() {
        var wps = _routeMidStationLast()
        return wps.concat([_wp(38.874500, 115.464500, 30.0, 21, 5)])
    }

    /// 【2026-09-28 用户裁定】**终点站**站点航点 + VTOL ⇒ `MAV_CMD_NAV_VTOL_LAND(85)`。
    ///
    /// 语义（`MavCmdInfoCommon.json:363-389` 逐字）：「Fly to specified location at
    /// current altitude, transition to multi-rotor and land.」—— 这正是单机版航线编辑器
    /// 「选择航线任务指令」里那一项**垂起着陆**。
    ///
    /// 本条是本次改动的**主判据**：VTOL 飞机在终点**转为多旋翼着陆**，
    /// 而不是像固定翼那样绕终点一直盘旋（用户实测的故障现象）。
    function test_routeMissionItems_vtolEndStationBecomesVtolLand() {
        var items = OpsCommon.routeMissionItems(_routeWithEnd(), true, _rt003EndId, 0)
        compare(items.length, 3, "三点都要下发：降落是**映射**终点那一点，不是**替换**它")
        compare(items[0].command, 16, "中途站点(21)不是终点 ⇒ 保持 16")
        compare(items[1].command, 16, "中途普通航点 ⇒ 保持 16")
        compare(items[2].command, 85, "终点站 + VTOL ⇒ 必须是 VTOL_LAND(85)")
        // ‼️ 阴性对照：85 ≠ 21。写成 21 会被 MAVLink 当成 `MAV_CMD_NAV_LAND`
        //    （数值巧合），行为完全不同。这条断言防的是"顺手返回设计域那个 21"。
        verify(items[2].command !== 21, "85 与 21 是两条不同的指令，绝不能写成 21(=NAV_LAND)")
        // 降落的**坐标**必须原样透传：85 是 specifiesCoordinate 的命令，
        // 坐标错了飞机就落到别处去了，而界面上看不出异常。
        compare(items[2].lat, 38.8745, "降落点纬度必须原样透传")
        compare(items[2].lon, 115.4645, "降落点经度必须原样透传")
    }

    /// ‼️ **本组最关键的一格 —— 它钉的是一条已被真库实测推翻的旧判据。**
    ///
    /// 旧判据是"列表里的**最后一项**就是终点站"。它在 `_routeRt003()` 这种形状上会让
    /// **房山镇政府（中途点，id=4）** 变成 85 ⇒ 飞机在**航路中途**降落，
    /// 而任务的目的地是保定市政府（id=5）—— 正是用户红线上"只能在机位上降落"那类事故，
    /// 且界面上看不出任何异常。
    ///
    /// ⚠️ 这条用例之所以必须有：**反例 RT-006**（云端权威库航线 id 23）的
    ///    `start_waypoint_id` / `end_waypoint_id` **恰好也在** `table_route_waypoint` 里
    ///    （两行 → wp1 / wp2，wp2 排在末位），于是"最后一项"在
    ///    那条航线上**恰好**对 —— 只拿它当样本的验证会给出一个假绿的 ✓。
    ///    ⚠️ **出处等级**：本注释里所有「云端权威库」读数**不是本任务测的**，是
    ///       **控制方（编排者）2026-10-01 只读实测**；采集口径 = `ssh root@39.97.235.226`、
    ///       库 `/opt/uavm/var/db_uavm.db`、**只读**打开（`file:...?mode=ro&immutable=1`）、
    ///       范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    ///       **本任务（QGC 仓）无云端凭据，未独立复核。**
    ///    ⚠️ 出处更正（修复轮 2 / 3）：本注释原先引的反例是 **`RT-SITL01`**。
    ///       **该航线在权威库里存在**（航线 id 24，`route_code='RT-SITL01'`，
    ///       `route_name='SITL 苏黎世调试航线'`）—— **变的是它的数据**：
    ///       权威库现行值为 `start_waypoint_id=NULL` / `end_waypoint_id=NULL`，
    ///       且 `table_route_waypoint` **零行**；另据同一次控制方读数，该行
    ///       `deleted_at='2026-10-01 00:58:29'` ⇒ **它已被软删除**。
    ///       （‼️ 只登记"同时存在"这两类事实，**不推断**「被软删 ⇒ 关联行被清空」的因果。）
    ///       而原注释引的 `start=26` / `end=28`、三行 `wp 26/27/28`，在
    ///       **2026-09-26 的本机 `db_uavm.db` 陈旧副本**里**逐字可复现**
    ///       ⇒ 那组数字取自该副本，**09-26 之后数据被改动过**，样本已不可用。
    ///       **结论不变**（"按位置推断终点"照样被推翻），样本已换成权威库现行的 **RT-006**（id 23）。
    function test_routeMissionItems_vtolLastItemIsNotTheEnd() {
        var wps = _routeMidStationLast()
        var items = OpsCommon.routeMissionItems(wps, true, _rt003EndId, 0)
        compare(items.length, 2)
        compare(items[1].command, 16,
                "列表最后一项是**中途**的良乡区政府(id=3)，而航线终点是 id=5 ⇒ 不得变 85")
        verify(items[1].command !== 85, "旧判据（最后一项=终点）在本形状下会让飞机中途降落")
        compare(items[1].lat, 39.748823, "坐标原样透传，别为了避开 85 而改动坐标")
    }

    /// 终点站**不在**下发列表里（＝当前数据源的真实情形）⇒ **不产生降落指令**。
    /// 这是 fail-closed 的落点：行为与本改动之前完全一致（飞机在最后一个航点盘旋），
    /// 而不是"改错了但看起来在工作"。解封条件见 `_endWaypointIndex` 的注释。
    function test_routeMissionItems_vtolEndMissingProducesNoLand() {
        var wps = _routeMidStationLast()
        compare(OpsCommon.routeMissionItems(wps, true, undefined, 0)[1].command, 16,
                "不传 endWaypointId ⇒ 指认不出终点 ⇒ 一概 16")
        compare(OpsCommon.routeMissionItems(wps, true, undefined, 0)[1].command, 16, "undefined ⇒ 16")
        compare(OpsCommon.routeMissionItems(wps, true, null, 0)[1].command, 16, "null ⇒ 16")
        // 端点值本身也按类型收：`"5"` 不是 number，`0` / 负数不是合法 id。
        compare(OpsCommon.routeMissionItems(wps, true, "5", 0)[1].command, 16,
                "字符串 \"5\" 不是 number ⇒ 不指认（按类型收，与其余字段同口径）")
        compare(OpsCommon.routeMissionItems(wps, true, 0, 0)[1].command, 16, "0 不是合法航点 id")
        compare(OpsCommon.routeMissionItems(wps, true, -1, 0)[1].command, 16, "负数不是合法航点 id")
        // 阳性对照：没有这一条，上面六条对一个"永远返回 16"的实现**全是绿的**。
        compare(OpsCommon.routeMissionItems(_routeWithEnd(), true, _rt003EndId, 0)[2].command, 85,
                "阳性对照：终点站确实在列表里时，必须能指认出来并映射成 85")
    }

    /// 航线的**始发站**也是 `command=21`（站点航点在你们模型里**首尾都用**）。
    /// 若把 21 整体映射成降落，飞机会在**始发站就降落**，整条航线被中途截断 ——
    /// 而界面上看不出任何异常。
    ///
    /// ⚠️ 本形状（起降站**都在** route_waypoint 里）**当前不会出现**，
    ///    它测的是"后端补上起降点之后"的行为。
    function test_routeMissionItems_vtolStartStationIsNotLand() {
        var wps = [_wp(40.117950, 116.424789, 50.0, 21, 2),   // 始发站（站点）
                   _wp(39.748823, 116.143486, 50.0, 21, 3),   // 中途（站点）
                   _wp(38.874500, 115.464500, 30.0, 21, 5)]   // 终点站（站点）
        var items = OpsCommon.routeMissionItems(wps, true, 5, 0)
        compare(items.length, 3)
        compare(items[0].command, 16,
                "始发站也是站点(command=21)，但**不是终点** ⇒ 必须仍是普通航点(16)")
        compare(items[1].command, 16, "中途站点(21)同样不是终点 ⇒ 16")
        compare(items[2].command, 85, "只有**终点站**那一点才是垂起着陆")
    }

    /// 终点站是**普通航点**（用户没把它设成站点）⇒ **不发明用户没画的东西**。
    /// 飞机在最后一个航点盘旋是既有行为，不因本次改动而变。
    function test_routeMissionItems_vtolEndPlainWaypointStaysWaypoint() {
        var wps = [_wp(39.748800, 116.143400, 50.0, 21, 3),
                   _wp(39.748823, 116.143486, 50.0, 16, 5)]
        var items = OpsCommon.routeMissionItems(wps, true, 5, 0)
        compare(items.length, 2)
        compare(items[1].command, 16, "终点站是普通航点 ⇒ 不得自动补一条降落指令")
    }

    /// 单点航线：那个点**既是始发站也是终点站**（`id` 就是航线的终点 id）。
    /// VTOL 下它变成 85 ⇒ mission 为 `[TAKEOFF, VTOL_LAND]`。
    /// 钉住它是为了让这条裁量**可见**：日后若要改成"单点航线不降落"，
    /// 必须先显式推翻本用例，而不是悄悄改掉。
    function test_routeMissionItems_vtolSinglePointIsLand() {
        var single = [_wp(39.748823, 116.143486, 50.0, 21, 7)]
        var items = OpsCommon.routeMissionItems(single, true, 7, 0)
        compare(items.length, 1)
        compare(items[0].command, 85, "单点航线的那个点就是航线终点 ⇒ 它就是降落点")
        // 起飞高度取**首点**高度，与"首点是不是降落点"无关 ⇒ 不得被本次改动波及。
        compare(OpsCommon.takeoffAltitude(single), 50.0,
                "起飞高度仍取首点高度；引入 85 不得改变它")
    }

    /// 同一个 `endWaypointId` 在列表里命中**多于一处** ⇒ 无法确定哪一个是终点
    /// ⇒ **不产生**降落（fail-closed）。两条 85 会让飞机在航路中途落一次，不可撤销。
    /// 这是数据异常（`table_route_waypoint` 没有 `(route_id, waypoint_id)` 唯一约束），
    /// 真实链路上不该出现，但后果不可撤销 ⇒ 值得一格。
    function test_routeMissionItems_vtolAmbiguousEndProducesNoLand() {
        var wps = [_wp(39.748800, 116.143400, 50.0, 21, 5),
                   _wp(39.748823, 116.143486, 50.0, 21, 5)]   // 同一个 id 出现两次
        var items = OpsCommon.routeMissionItems(wps, true, 5, 0)
        compare(items.length, 2)
        compare(items[0].command, 16, "终点 id 有歧义 ⇒ 第 0 点不得变成降落")
        compare(items[1].command, 16, "终点 id 有歧义 ⇒ 第 1 点也不得变成降落")
    }

    /// ‼️ `isVtol` **只认真布尔 `true`**（与本文件其余部分"按类型收"同一口径）。
    /// 真值非布尔（`1` / `"true"` / `"false"`）一律**不启用**垂起着陆。
    ///
    /// 选 fail-closed 这一侧的理由：**漏掉降落**的后果是飞机在终点**可见地**盘旋
    ///（与今天的行为一致，用户一眼能看出不对）；**多插一个降落**的后果是飞机
    /// 真的落下去，不可撤销。默认值取后果较轻的那一侧。
    /// ⚠️ 尤其 `"false"` 在 JS 里是**真值** —— 凡用 `if (isVtol)` 强转的实现都会放行它。
    function test_routeMissionItems_vtolFlagRequiresStrictBoolean() {
        var wps = _routeWithEnd()
        var end = _rt003EndId
        compare(OpsCommon.routeMissionItems(wps, 1, end, 0)[2].command, 16, "数值 1 不是 true ⇒ 不启用")
        compare(OpsCommon.routeMissionItems(wps, "true", end, 0)[2].command, 16,
                "字符串 \"true\" 不是 true ⇒ 不启用")
        compare(OpsCommon.routeMissionItems(wps, "false", end, 0)[2].command, 16,
                "字符串 \"false\" 在 JS 里是真值 ⇒ 更不能靠强转放行")
        compare(OpsCommon.routeMissionItems(wps, null, end, 0)[2].command, 16, "null ⇒ 不启用")
        compare(OpsCommon.routeMissionItems(wps, undefined, end, 0)[2].command, 16, "undefined ⇒ 不启用")
        // 阳性对照：没有这一条，上面五条对一个"永远返回 16"的实现**全是绿的**。
        compare(OpsCommon.routeMissionItems(wps, true, end, 0)[2].command, 85,
                "阳性对照：真布尔 true 必须启用垂起着陆")
    }

    /// 未知的设计域 `command` ⇒ **整条航线作废**（回空数组），不做"跳过这一点"。
    /// ‼️ 跳过会让飞机飞出一条用户没画过的路径，而界面上点的编号仍然连续、
    ///    看不出少了哪一个。这里是 fail-closed：宁可起飞按钮不亮。
    function test_routeMissionItems_unknownCommandVoidsWholeRoute() {
        var wps = [_wp(39.7488, 116.1434, 50.0, 16), _wp(39.7489, 116.1435, 50.0, 99)]
        compare(OpsCommon.routeMissionItems(wps, undefined, undefined, 0).length, 0,
                "含未知 command 时应整体作废，而不是静默跳过那一点")
    }

    /// 坐标无效（`(0,0)` / 单轴为 0 / NaN / **真缺字段**）⇒ 同样整体作废，理由同上。
    /// ‼️ 判据是 `routeMissionItems` 内复用的单点定义 `isValidWaypoint`：**任一轴为 0 即无效**
    ///（不是"两轴同时为 0"）。(0,0) 是"没有定位"的常见缺省值。
    function test_routeMissionItems_invalidCoordinateVoidsWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        compare(OpsCommon.routeMissionItems([good, _wp(0, 0, 50.0, 16)], undefined, undefined, 0).length, 0, "(0,0) 应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(NaN, 116.1, 50.0, 16)], undefined, undefined, 0).length, 0, "NaN 纬度应作废")
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 116.1, NaN, 16)], undefined, undefined, 0).length, 0, "NaN 高度应作废")
        compare(OpsCommon.routeMissionItems([good, null], undefined, undefined, 0).length, 0, "null 元素应作废")
        // 单轴为 0：只挡"两轴同时为 0"的实现会在这里放行，把飞机送到赤道 / 本初子午线。
        compare(OpsCommon.routeMissionItems([good, _wp(0, 116.1, 50.0, 16)], undefined, undefined, 0).length, 0,
                "纬度单轴为 0 应作废（判据是「任一轴为 0」，不是「两轴同时为 0」）")
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 0, 50.0, 16)], undefined, undefined, 0).length, 0,
                "经度单轴为 0 应作废")
        // 真缺键（不是显式 NaN）——后端可空列 / 字段缺失的实际形态。
        compare(OpsCommon.routeMissionItems([good, { lat: 39.7, lon: 116.1, command: 16 }], undefined, undefined, 0).length, 0,
                "真缺 altitude 键应作废")
        compare(OpsCommon.routeMissionItems([good, { lat: 39.7, lon: 116.1, altitude: 50.0 }], undefined, undefined, 0).length, 0,
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
        compare(OpsCommon.routeMissionItems(nullAlt, undefined, undefined, 0).length, 0, "altitude 为 null 应作废")
        compare(OpsCommon.routeMissionItems(emptyAlt, undefined, undefined, 0).length, 0, "altitude 为空串应作废")
    }

    /// ‼️ **类型闸**：`lat` / `lon` / `altitude` 三处**统一**只接受 JSON number。
    /// 下列形态的 `Number()` 结果都是 `0`（`"50"` 是 `50`），若不按类型拒绝，它们会从
    /// **同一道门**进来 ⇒ `takeoffAltitude` 回 0（或 50）而不是 `NaN`。
    /// 「枚举坏值」永远会漏 —— 本用例就是那些"漏"的集合。
    /// ⚠️ 坏点一律放**索引 0**（`takeoffAltitude` 读首点），否则断言无鉴别力。
    function test_routeMissionItems_nonNumberTypesVoidWholeRoute() {
        var good = _wp(39.7488, 116.1434, 50.0, 16)
        var badAlt = function (v) { return [_wp(39.7, 116.1, v, 16), good] }
        compare(OpsCommon.routeMissionItems(badAlt(" "), undefined, undefined, 0).length, 0,
                "空白串：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("\t"), undefined, undefined, 0).length, 0,
                "制表符串：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("0"), undefined, undefined, 0).length, 0,
                "字符串 0：Number 结果为 0 ⇒ 必须按类型拒绝")
        compare(OpsCommon.routeMissionItems(badAlt("50"), undefined, undefined, 0).length, 0,
                "数值字符串 50：能转成合法数，但类型不对 ⇒ 同样拒绝（不得靠能转成数放行）")
        compare(OpsCommon.routeMissionItems(badAlt(false), undefined, undefined, 0).length, 0,
                "布尔 false：Number(false) === 0 ⇒ 必须拒绝")
        compare(OpsCommon.routeMissionItems(badAlt([]), undefined, undefined, 0).length, 0,
                "空数组：Number([]) === 0 ⇒ 必须拒绝")
        // lat / lon 同样按类型收 —— 三处口径必须一致。只改 altitude 就是再造一次
        // 「同一件事三处三种口径」（`isValidWaypoint` 上方那段注释记录的教训）。
        compare(OpsCommon.routeMissionItems([_wp("39.7", 116.1, 50.0, 16), good], undefined, undefined, 0).length, 0,
                "lat 为数值字符串 ⇒ 必须拒绝（不得靠 isValidWaypoint 侥幸兜住）")
        compare(OpsCommon.routeMissionItems([_wp(39.7, "116.1", 50.0, 16), good], undefined, undefined, 0).length, 0,
                "lon 为数值字符串 ⇒ 必须拒绝")
        // fail-closed 与位置无关：坏点在末位同样整体作废。
        compare(OpsCommon.routeMissionItems([good, _wp(39.7, 116.1, [], 16)], undefined, undefined, 0).length, 0,
                "坏点在末位也应整体作废")
    }

    /// ‼️ **数值 `0` 有意放行** —— 把这条**裁量**钉成**可执行判据**，而不是只写在注释里。
    /// `routeMissionItems` 只做**类型**检查：「高度恰好为 0」是**数据问题**（后端该不该存 0），
    /// 不是**类型问题**，业务判定留给调用方的起飞闸（那里能给出中文文案）。
    /// 本用例的意义：日后若有人把 `0` 也一并拒掉，必须**显式推翻**这个裁量 —— 会有人变红。
    function test_routeMissionItems_numericZeroAltitudeIsDeliberatelyAllowed() {
        var wps = [_wp(39.7, 116.1, 0, 16)]
        // `cruiseAGL = 0`：本格钉的是 **wps 侧**的 0 被放行；巡航高度侧的 0 同样合法
        // （见新增的 `test_routeMissionItems_zeroCruiseIsIdentity`），两者都不得被拒。
        var items = OpsCommon.routeMissionItems(wps, undefined, undefined, 0)
        compare(items.length, 1, "数值 0 是合法 number ⇒ 本函数**有意放行**（见 routeMissionItems 内注释）")
        compare(items[0].alt, 0, "高度原样透传，不做任何转换")
        compare(OpsCommon.takeoffAltitude(wps), 0,
                "起飞高度回 0（**不是** NaN）：类型闸不等于业务闸，拦起飞是调用方的事")
    }

    /// 顺序即输入顺序（调用方已按 `seq` 取好），且**不掺任何私货** ——
    /// 本函数不生成起飞项（起飞点的坐标是"飞机当前 home"，运行时才知道）。
    function test_routeMissionItems_preservesOrderAndAddsNoTakeoff() {
        var items = OpsCommon.routeMissionItems(_route20(), undefined, undefined, 0)
        compare(items.length, 2, "不该额外插入起飞项——起飞项由调用方在拿到 home 之后插")
        verify(Math.abs(items[0].lat - 39.748800) < 1e-9, "第 0 点顺序错了")
        verify(Math.abs(items[1].lat - 39.748823) < 1e-9, "第 1 点顺序错了")
    }

    // ─────────────────────────────────────────────────────────────────────
    // NRRSM D7（2026-10-01）：中间项加 `cruiseAGL`
    //
    // 组装式：**中间项 = 该航点地面海拔 + 本架次飞行高度（AGL）**（设计稿 §5.2 规则表第 2 行）。
    //   · 本函数的**第 0 项是航线的第一个中间航点** —— 起飞项是调用方自己插的
    //     `NAV_TAKEOFF`，**不在产出里** ⇒ 第 0 项**也要**加（最容易被写错的一格）。
    //   · **末项不加**（原样透传），随后由 `applyLandingAltitude` 覆盖成降落高度。
    //   · `cruiseAGL === 0`（未设定）⇒ 输出与加参前**逐字相同**；不可用 ⇒ 整条作废（回 `[]`）。
    // ─────────────────────────────────────────────────────────────────────

    /// 四个航点、高度**两两不同**且都 > 0。
    /// ‼️ 首点(100) 与末点(400) 刻意不等 —— 否则"首末互换"的实现也会全绿。
    function _routeFourAlt() {
        return [_wp(39.748800, 116.143400, 100.0, 16),
                _wp(39.748900, 116.143500, 200.0, 16),
                _wp(39.749000, 116.143600, 300.0, 16),
                _wp(39.749100, 116.143700, 400.0, 16)]
    }

    /// 三点版（brief「首项 / 末项」两条用例的形状）。
    function _routeThreeAlt() {
        return [_wp(39.748800, 116.143400, 100.0, 16),
                _wp(39.748900, 116.143500, 200.0, 16),
                _wp(39.749000, 116.143600, 300.0, 16)]
    }

    /// ‼️ **首项也要加** —— 裁定一的阳性判据，也是本任务最容易被写错的一格。
    /// 若实现写成 `i > 0`（只给 1..n-2 加），本格必红：首个中间航点会比其余中间点低
    /// `cruiseAGL` 米，而**界面上完全看不出来**。
    function test_routeMissionItems_firstItemAlsoGetsCruise() {
        var wps = _routeThreeAlt()
        var out = OpsCommon.routeMissionItems(wps, undefined, undefined, 30)
        compare(out.length, 3)
        compare(out[0].alt, 130.0, "首个中间航点**也要**加 30；等于 100.0 就是写成了 `i > 0`")
        verify(out[0].alt !== wps[0].altitude, "「没加」的那种实现正好产出这个值")
    }

    /// 其余中间项都加（四点 ⇒ 下标 1、2 都加）。
    function test_routeMissionItems_middleItemsAllGetCruise() {
        var wps = _routeFourAlt()
        var out = OpsCommon.routeMissionItems(wps, undefined, undefined, 30)
        compare(out.length, 4)
        compare(out[1].alt, 230.0)
        compare(out[2].alt, 330.0)
    }

    /// 末项**不加**（原样透传），由 `applyLandingAltitude` 覆盖成降落高度。
    /// 写成"全部加"会让末项先高一个 `cruiseAGL` ⇒ 本格是唯一能看出"组装式多加了末项"的地方。
    function test_routeMissionItems_lastItemKeepsRawAltitude() {
        var wps = _routeThreeAlt()
        var out = OpsCommon.routeMissionItems(wps, undefined, undefined, 30)
        compare(out[out.length - 1].alt, 300.0, "末项原样透传，不得加 cruiseAGL")
        verify(out[out.length - 1].alt !== wps[wps.length - 1].altitude + 30,
               "300.0 + 30 是「末项也加了」的实现会产出的值")
    }

    /// `cruiseAGL === 0` 是**合法输入**（本仓口径：`0` = 未设定）⇒ 输出与加参前**逐字相同**。
    /// 「`0` 该不该起飞」是闸的事（`takeoffAGL > 0`），不是本函数的事。
    function test_routeMissionItems_zeroCruiseIsIdentity() {
        var wps = _routeFourAlt()
        var out = OpsCommon.routeMissionItems(wps, undefined, undefined, 0)
        compare(out.length, 4)
        compare(out[0].alt, 100.0)
        compare(out[1].alt, 200.0)
        compare(out[2].alt, 300.0)
        compare(out[3].alt, 400.0)
    }

    /// ‼️ `cruiseAGL` 不可用 ⇒ **整条航线作废（回 `[]`）**，**不是**"按 0 处理"。
    /// 静默按 0 = 少一个偏移、零报错 —— 正是本函数要杀的那类缺陷；回 `[]` 让调用方
    /// 看到**响亮**的失败。
    function test_routeMissionItems_unusableCruiseVoidsRoute() {
        var wps = _routeThreeAlt()
        compare(OpsCommon.routeMissionItems(wps).length, 0, "不传第 4 参 ⇒ 空数组（不是按 0 处理）")
        compare(OpsCommon.routeMissionItems(wps, undefined, undefined, undefined).length, 0, "undefined ⇒ 空数组")
        compare(OpsCommon.routeMissionItems(wps, undefined, undefined, NaN).length, 0, "NaN ⇒ 空数组")
        compare(OpsCommon.routeMissionItems(wps, undefined, undefined, "30").length, 0,
                "字符串 \"30\" ⇒ 空数组（按类型收，与其余字段同口径）")
        // ‼️ 阳性对照：没有这一条，上面四条对一个"永远回 `[]`"的实现**全是绿的**。
        compare(OpsCommon.routeMissionItems(wps, undefined, undefined, 30).length, 3,
                "阳性对照：可用的 cruiseAGL 必须产出非空航线")
    }

    /// 负数是**业务校验**的事（后端 `TaskList.vue` 已有 `cruise_alt_agl < 0 ⇒ 报错`），
    /// 本函数是**纯算术** ⇒ 照常参与计算，不做额外拒绝。这一格是钉子，不是疏漏。
    function test_routeMissionItems_negativeCruiseParticipatesInArithmetic() {
        var wps = _routeThreeAlt()
        var out = OpsCommon.routeMissionItems(wps, undefined, undefined, -5)
        compare(out.length, 3, "负数不得被拒（被拒会回 []）")
        compare(out[0].alt, 95.0, "首个中间航点 100 + (-5) = 95")
        compare(out[2].alt, 300.0, "末项仍原样透传")
    }

    /// `frame` 不随加法改变：加法已在末端合成 **AMSL**，参考系仍是 `MAV_FRAME_GLOBAL(0)`。
    /// 这一格防的是"顺手把 frame 改成相对高度系(3)"—— 那会让每个航点都偏高一个 home 高程，
    /// 而任务卡上显示的高度看着完全正常。
    function test_routeMissionItems_frameStaysGlobalWithCruise() {
        var out = OpsCommon.routeMissionItems(_routeFourAlt(), undefined, undefined, 30)
        compare(out.length, 4)
        for (var i = 0; i < out.length; i++) {
            compare(out[i].frame, 0, "第 " + i + " 项 frame 必须仍是 MAV_FRAME_GLOBAL(0)")
        }
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

    //-------------------------------------------------------------------------
    // takeoffSlotPose / takeoffTransitionPoint：起飞点（cmd 84）按机位朝向偏移
    //-------------------------------------------------------------------------

    /// 大圆距离（米）—— **本文件里的独立实现**，与被测的目标点公式互为反函数。
    /// 「距离守恒」那条断言必须用它反算，**不能**照抄被测实现的公式：
    /// 两边共用同一套推导时，半径/单位/经纬顺序写错会一起错、一起绿。
    function _haversineM(lat1, lon1, lat2, lon2) {
        var R = 6371000.0
        var p1 = lat1 * Math.PI / 180, p2 = lat2 * Math.PI / 180
        var dp = (lat2 - lat1) * Math.PI / 180
        var dl = (lon2 - lon1) * Math.PI / 180
        var a = Math.sin(dp / 2) * Math.sin(dp / 2)
                + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2)
        return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    }

    /// 起点→终点的**初始方位角**（度，0=正北、顺时针）。同上，独立实现。
    function _bearingDeg(lat1, lon1, lat2, lon2) {
        var p1 = lat1 * Math.PI / 180, p2 = lat2 * Math.PI / 180
        var dl = (lon2 - lon1) * Math.PI / 180
        var y = Math.sin(dl) * Math.cos(p2)
        var x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)
        return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360
    }

    /// 1e-6 度 ≈ 0.11 m。这个容差**不是随手取的**：离屏探针（`/tmp/calib_azimuth.qml`，
    /// 用 Qt 自己的 `QGeoCoordinate::atDistanceAndAzimuth`）实测，球面公式（R=6371000）
    /// 与 Qt 在四方位上的最大偏差是 3.98e-9 度 ≈ 0.44 mm ⇒ 远在容差内；
    /// 而**若误用赤道半径 6378137**，偏差是 3.02e-6 度 ⇒ 超容差、会红。
    /// 即：这个容差既容得下实现差异，又拦得住半径写错。
    function _nearDeg(a, b) { return Math.abs(a - b) < 1e-6 }

    // ---- takeoffTransitionPoint ----

    /// 期望值取自**离屏探针实测**（Qt 的 `atDistanceAndAzimuth`），
    /// **不是**照抄被测实现的输出 —— 否则这里只是把实现重写一遍。
    function test_takeoffTransitionPoint_fourCardinals_data() {
        return [
            { tag: "正北", heading: 0,   lat: 40.002697961769, lon: 116.000000000000 },
            { tag: "正东", heading: 90,  lat: 39.999999946699, lon: 116.003521938957 },
            { tag: "正南", heading: 180, lat: 39.997302038231, lon: 116.000000000000 },
            { tag: "正西", heading: 270, lat: 39.999999946699, lon: 115.996478061043 },
        ]
    }

    /// 四方位落点。基准点 40°N 116°E、偏移 300 m（`vtolTransitionDistance` 的默认值）。
    ///
    /// ‼️ 方位语义是 **0=正北、顺时针**（与 `table_slot.heading` 同口径，见
    /// `SiteList.vue` 的「朝向(°)」输入框；Qt 的 `atDistanceAndAzimuth` 也是这个口径）。
    /// 若实现按数学惯例写成「0=正东、逆时针」，本组四格会**整组错位 90°** ⇒ 红。
    function test_takeoffTransitionPoint_fourCardinals(data) {
        var p = OpsCommon.takeoffTransitionPoint(40.0, 116.0, data.heading, 300.0)
        verify(p !== null, data.tag + "：应返回坐标而不是 null")
        verify(_nearDeg(p.lat, data.lat),
               data.tag + " lat=" + p.lat + "，期望 " + data.lat)
        verify(_nearDeg(p.lon, data.lon),
               data.tag + " lon=" + p.lon + "，期望 " + data.lon)
    }

    /// **独立方法交叉验证**：反算距离仍应是 300 m、反算方位角仍应是输入的朝向。
    /// 这一条不看被测函数的公式形状 ⇒ 能抓住「半径写错」「度/弧度混用」「经纬写反」
    /// 这三类四面位用例**抓不到**的错（四面位只钉四个点，公式整体偏移可能仍落在容差外但形态相似）。
    function test_takeoffTransitionPoint_distanceAndBearingPreserved_data() {
        return [
            { tag: "正北", heading: 0 },
            { tag: "正东", heading: 90 },
            { tag: "正南", heading: 180 },
            { tag: "正西", heading: 270 },
            { tag: "东北", heading: 45 },
            { tag: "西南", heading: 225 },
            { tag: "东南偏东", heading: 112.5 },
        ]
    }

    function test_takeoffTransitionPoint_distanceAndBearingPreserved(data) {
        var p = OpsCommon.takeoffTransitionPoint(40.0, 116.0, data.heading, 300.0)
        verify(p !== null, data.tag + "：应返回坐标")
        var d = _haversineM(40.0, 116.0, p.lat, p.lon)
        verify(Math.abs(d - 300.0) < 0.01,
               data.tag + "：反算距离 = " + d + " m，期望 300 m")
        var b = _bearingDeg(40.0, 116.0, p.lat, p.lon)
        var raw = (b - data.heading + 360) % 360
        var diff = raw > 180 ? 360 - raw : raw      // 处理 0/360 环绕
        verify(diff < 1e-3,
               data.tag + "：反算方位角 = " + b + "°，期望 " + data.heading + "°")
    }

    /// 距离 0 **是合法输入**（偏移 0），必须原样返回起点，不能当成"无效"回 null。
    function test_takeoffTransitionPoint_zeroDistanceIsIdentity() {
        var p = OpsCommon.takeoffTransitionPoint(40.0, 116.0, 123.0, 0.0)
        verify(p !== null, "距离 0 是合法偏移，不该回 null")
        verify(_nearDeg(p.lat, 40.0) && _nearDeg(p.lon, 116.0),
               "距离 0 应原样返回起点，实得 " + p.lat + "," + p.lon)
    }

    /// 高纬：同距离下经度变化明显更大（cos φ 更小）。期望值同样取自探针。
    function test_takeoffTransitionPoint_highLatitude() {
        var p = OpsCommon.takeoffTransitionPoint(60.0, 10.0, 90.0, 300.0)
        verify(p !== null, "应返回坐标")
        verify(_nearDeg(p.lat, 59.999999889978), "60°N lat=" + p.lat)
        verify(_nearDeg(p.lon, 10.005395923526), "60°N lon=" + p.lon)
    }

    function test_takeoffTransitionPoint_missingHeadingIsNull_data() {
        return [
            { tag: "undefined", heading: undefined },
            { tag: "null",      heading: null },
            { tag: "NaN",       heading: NaN },
            { tag: "字符串",     heading: "90" },
            { tag: "Infinity",  heading: Infinity },
        ]
    }

    /// ‼️ 朝向拿不到时**必须回 null**（调用方据此回落 `home`），**不能**悄悄按 0（正北）偏移。
    /// 那正是本功能要消灭的默认行为 —— 回落 `home` 至少是"原地起飞"，静默按正北偏移
    /// 却会让飞机朝一个**谁都没指定过**的方向飞，且界面上看不出任何异常。
    /// 「字符串 "90"」那一格钉的是"只认数字类型"：`Number("90")` 是 90，强转就会放行。
    function test_takeoffTransitionPoint_missingHeadingIsNull(data) {
        verify(OpsCommon.takeoffTransitionPoint(40.0, 116.0, data.heading, 300.0) === null,
               data.tag + "：朝向不可用时必须回 null，不能按正北偏移")
    }

    function test_takeoffTransitionPoint_invalidDistanceIsNull_data() {
        return [
            { tag: "undefined", dist: undefined },
            { tag: "NaN",       dist: NaN },
            { tag: "Infinity",  dist: Infinity },
            { tag: "负距离",     dist: -1 },
        ]
    }

    /// 距离不可用 ⇒ null。负距离**刻意不取绝对值**：那是调用方的错，
    /// 静默取绝对值等于替调用方猜意图。
    function test_takeoffTransitionPoint_invalidDistanceIsNull(data) {
        verify(OpsCommon.takeoffTransitionPoint(40.0, 116.0, 90.0, data.dist) === null,
               data.tag + "：距离不可用时必须回 null")
    }

    function test_takeoffTransitionPoint_invalidCoordinateIsNull() {
        verify(OpsCommon.takeoffTransitionPoint(NaN, 116.0, 90.0, 300.0) === null, "lat=NaN")
        verify(OpsCommon.takeoffTransitionPoint(40.0, undefined, 90.0, 300.0) === null, "lon=undefined")
        verify(OpsCommon.takeoffTransitionPoint(91.0, 116.0, 90.0, 300.0) === null, "lat 越界")
        verify(OpsCommon.takeoffTransitionPoint(40.0, 181.0, 90.0, 300.0) === null, "lon 越界")
    }

    /// 朝向可以是任意实数（机位朝向是人工填的 `step="any"`），归一化到 [0,360) 后等价。
    function test_takeoffTransitionPoint_headingNormalisation() {
        var a = OpsCommon.takeoffTransitionPoint(40.0, 116.0, 90.0, 300.0)
        var b = OpsCommon.takeoffTransitionPoint(40.0, 116.0, 450.0, 300.0)
        var c = OpsCommon.takeoffTransitionPoint(40.0, 116.0, -270.0, 300.0)
        verify(a !== null && b !== null && c !== null, "三个朝向都该算出点")
        verify(_nearDeg(a.lat, b.lat) && _nearDeg(a.lon, b.lon), "450° 应等价于 90°")
        verify(_nearDeg(a.lat, c.lat) && _nearDeg(a.lon, c.lon), "−270° 应等价于 90°")
    }

    // ---- takeoffSlotHeading ----

    /// 三字段齐备 ⇒ 原样取出朝向（**不经任何换算**：`heading` 单位就是度，
    /// 与 `atDistanceAndAzimuth` 的方位角同口径）。
    function test_takeoffSlotHeading_readsHeading() {
        compare(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 117.121397, current_slot_heading: 90
        }), 90)
    }

    /// ‼️ `heading === 0` 是**合法朝向**（正北），**不是**哨兵 —— 真库里 12 个机位
    /// 的朝向只有 0 和 1.0 两种取值。把 0 当"没填"会让绝大多数机位静默回落 `home`。
    /// 哨兵只由**坐标**判定：后端未指定机位时下发 0/0/0。
    ///
    /// ⚠️ 断言写成 `h === 0` 而**不是** `verify(h)`：后者对 `0` 也会红，但红的理由不对
    /// （红在"0 是 falsy"，而不是红在"函数把 0 当哨兵了"）。本函数用 `null` 表示"没有"、
    /// 用 `0` 表示"正北"，这条同时把这个区分钉住 —— 调用方据此必须写 `!== null`。
    function test_takeoffSlotHeading_headingZeroIsNotASentinel() {
        var h = OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 117.121397, current_slot_heading: 0
        })
        verify(h !== null, "朝向 0（正北）是合法值，不该被当成「没填」")
        verify(h === 0, "正北应原样返回 0，实得 " + h)
    }

    /// 哨兵：后端「未指定机位」时下发 0/0/0 ⇒ 无位姿 ⇒ 调用方回落 `home`。
    function test_takeoffSlotHeading_sentinelIsNull() {
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 0, current_slot_lon: 0, current_slot_heading: 0
        }) === null, "0/0/0 是哨兵，应回 null")
    }

    /// 坐标半填（只有一个 0）也当无效：中国境内不可能出现经度或纬度为 0 的机位，
    /// 拿它去偏移会得到一个**看似正常、实际错在地球另一边**的点。
    function test_takeoffSlotHeading_halfZeroCoordinateIsNull() {
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 0, current_slot_lon: 117.121397, current_slot_heading: 90
        }) === null, "lat=0 而 lon 有效 ⇒ 数据不可用，应回 null")
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 0, current_slot_heading: 90
        }) === null, "lon=0 而 lat 有效 ⇒ 数据不可用，应回 null")
    }

    /// 字段整体缺失（后端未升级 / 老响应）⇒ null。**不能**当 0 处理。
    function test_takeoffSlotHeading_missingFieldsIsNull() {
        verify(OpsCommon.takeoffSlotHeading({}) === null, "空对象应回 null")
        verify(OpsCommon.takeoffSlotHeading(null) === null, "null 应回 null")
        verify(OpsCommon.takeoffSlotHeading(undefined) === null, "undefined 应回 null")
        verify(OpsCommon.takeoffSlotHeading({ current_slot_lat: 40.140578 }) === null,
               "只有 lat、没有 lon/heading ⇒ 应回 null")
    }

    /// 坐标有效但**朝向缺失** ⇒ null（回落 `home`）。理由同 `missingHeadingIsNull`：
    /// 宁可原地起飞，也不朝一个没人指定过的方向飞。
    function test_takeoffSlotHeading_missingHeadingIsNull() {
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 117.121397
        }) === null, "缺 heading ⇒ 应回 null")
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 117.121397, current_slot_heading: NaN
        }) === null, "heading=NaN ⇒ 应回 null")
        verify(OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.140578, current_slot_lon: 117.121397, current_slot_heading: "90"
        }) === null, "heading 是字符串 ⇒ 应回 null（只认数字类型）")
    }

    /// 端到端形状：后端三字段 → 朝向 → 偏移点。把两段接起来跑一遍，
    /// 免得两个函数各自绿、接在一起却单位不匹配（度 vs 弧度、lat/lon 顺序）。
    function test_takeoffSlotHeading_thenTransitionPoint() {
        var h = OpsCommon.takeoffSlotHeading({
            current_slot_lat: 40.0, current_slot_lon: 116.0, current_slot_heading: 90
        })
        verify(h !== null, "朝向应可取")
        var p = OpsCommon.takeoffTransitionPoint(40.0, 116.0, h, 300.0)
        verify(p !== null, "偏移点应可算")
        verify(_nearDeg(p.lat, 39.999999946699), "端到端 lat=" + p.lat)
        verify(_nearDeg(p.lon, 116.003521938957), "端到端 lon=" + p.lon)
    }

    //----------------------------------------------------------------
    // 「切换多旋翼是否已完成」判据
    //----------------------------------------------------------------
    //
    // ‼️ 本组测试的存在理由：原实现的判据是 `Vehicle::multiRotor`，而它对 VTOL 机体
    // **恒为 false** —— `QGCMAVLink::vehicleClass()` 是纯 switch，`MAV_TYPE_VTOL_*` 全部
    // 归 `VehicleClassVTOL`，与 `VehicleClassMultiRotor` 不相交。于是飞机切到多旋翼之后
    // 判据仍为假 ⇒ 必然走满 30 秒超时、回航指令永不发出（2026-09-28 实测现象）。
    // 正确判据是「转换**已完成**」，而只有 `MAV_VTOL_STATE_MC` 一个取值代表它。

    /// 五档必须分清：未定义 / 转固定翼中 / **转多旋翼中** / 多旋翼 / 固定翼。
    ///
    /// ‼️ 「转多旋翼中」(2) 这一格是本组的核心。若把判据写成 `!vtolInFwdFlight`
    /// （等价于 `vtolState !== 4`），这一格会红：飞机刚开始转多旋翼时 `vtol_state`
    /// 就已不再是 FW，会在**转换途中**就发出回航，而 PX4 此刻仍视机体为固定翼，
    /// 回航会重新落回那个卡死的 LOITER_DOWN 格 —— 症状与修复前一模一样。
    function test_vtolTransitionDone_stateMapping_data() {
        return [
            { tag: "0 未定义 ⇒ 未完成",     state: 0, expected: false },
            { tag: "1 转固定翼中 ⇒ 未完成", state: 1, expected: false },
            { tag: "2 转多旋翼中 ⇒ 未完成", state: 2, expected: false },
            { tag: "3 多旋翼 ⇒ 已完成",     state: 3, expected: true  },
            { tag: "4 固定翼 ⇒ 未完成",     state: 4, expected: false }
        ]
    }
    function test_vtolTransitionDone_stateMapping(data) {
        verify(OpsCommon.vtolTransitionDone(data.state) === data.expected, data.tag)
    }

    /// 非法 / 缺失输入 ⇒ false（不宣布完成）。
    /// 宁可让操作员看到超时提示，也不在没有证据时宣布完成 —— 后者会发出一份
    /// 落在错误状态机上的回航指令，且界面上一切正常、无人知道。
    function test_vtolTransitionDone_invalidIsNotDone() {
        verify(OpsCommon.vtolTransitionDone(undefined) === false, "undefined")
        verify(OpsCommon.vtolTransitionDone(null) === false, "null")
        verify(OpsCommon.vtolTransitionDone(NaN) === false, "NaN")
        verify(OpsCommon.vtolTransitionDone("3") === false, "字符串 3 ⇒ 不算（只认数字类型）")
        verify(OpsCommon.vtolTransitionDone(-1) === false, "负数")
        verify(OpsCommon.vtolTransitionDone(3.5) === false, "非整数")
    }

    //----------------------------------------------------------------
    // 「是否已飞抵接机机位」判据
    //----------------------------------------------------------------
    //
    // 用户 2026-09-29 裁定：降落落点从 `home`（= 起飞点）改为**接机机位坐标**，
    // 方案 A = `guidedModeGotoLocation(机位坐标)` → **到达** → `guidedModeLand()`。
    // 本函数就是那个中间环节的判据 —— 它回 true 的那一刻，程序会发出「降落」。
    //
    // ‼️ 所以本函数的**假阳性**代价是不对称的：说"到了"而其实没到 ⇒ 飞机在多旋翼模式下
    // `AUTO.LAND` **原地降落**（`PX4-Autopilot/src/modules/navigator/land.cpp` 里唯一的
    // `DO_REPOSITION` 是"中止降落"用的，不是水平接近）⇒ 落在机位之外的任意位置，
    // 违反用户 2026-09-28 定的红线「除非要坠机了，否则飞机只能在机位上降落」。
    // 反之"没到"的代价只是多盘旋几秒，最后走超时提示。**故一切存疑输入一律回 false。**

    /// 基本几何：0 距离、界内、界外、以及**经纬两轴都偏离**的斜向点。
    ///
    /// ‼️ 斜向那一格（tag「斜向」）不是凑数：只测"纯纬度偏离"或"纯经度偏离"的话，
    ///    把两轴距离取 `max` 而不是 `sqrt(a²+b²)` 的实现**照样全绿**，
    ///    而它在 45° 方向的判定圈会大出 √2 倍。
    function test_reachedSlot_data() {
        // (40, 117) 处：纬度 1° = 111194.9 m，经度 1° = 111194.9 × cos40° ≈ 85176.3 m
        return [
            { tag: "机位正上方 ⇒ 已抵达",       la: 40.0, lo: 117.0, sla: 40.0, slo: 117.0, r: 1.0,   expected: true  },
            { tag: "纯纬度偏 0.0005°(≈55.6m) 圈 60m ⇒ 已抵达", la: 40.0005, lo: 117.0, sla: 40.0, slo: 117.0, r: 60.0, expected: true  },
            { tag: "纯纬度偏 0.0005°(≈55.6m) 圈 50m ⇒ 未抵达", la: 40.0005, lo: 117.0, sla: 40.0, slo: 117.0, r: 50.0, expected: false },
            // 斜向：纬 55.6 m + 经 42.6 m ⇒ 直线 ≈ 70.0 m。取 max 的实现会算成 55.6 m ⇒ 圈 65m 时误报"已抵达"。
            { tag: "斜向偏(≈70.0m) 圈 65m ⇒ 未抵达", la: 40.0005, lo: 117.0005, sla: 40.0, slo: 117.0, r: 65.0, expected: false },
            { tag: "斜向偏(≈70.0m) 圈 75m ⇒ 已抵达", la: 40.0005, lo: 117.0005, sla: 40.0, slo: 117.0, r: 75.0, expected: true  }
        ]
    }
    function test_reachedSlot(data) {
        verify(OpsCommon.reachedSlot(data.la, data.lo, data.sla, data.slo, data.r) === data.expected,
               data.tag)
    }

    /// **边界包含性**用独立复算锁死：距离由本文件的 `_distM`（另一处手写的 haversine）算出，
    /// 生产函数取同一个地球半径 ⇒ 两次算的必须是同一个数。
    ///
    /// ‼️ 为什么不用"正好等于半径"去测：那要靠浮点逐位相等，改一次实现就红一次，
    ///    最后一定被人加容差加到失去意义。用 `d × 1.001` / `d × 0.999` 两侧夹逼，
    ///    既钉住"半径是可抵达范围"（含边界），又不依赖最后一位。
    /// ‼️ 这一格同时是**距离公式分叉**的探测器：生产函数若改用地平面近似、
    ///    或忘了经度的 `cos(lat)` 缩放，`0.999d` 那一侧就可能翻成 true。
    function test_reachedSlot_boundarySides() {
        var la1 = 40.0005, lo1 = 117.0005
        var la2 = 40.0, lo2 = 117.0
        var d = _distM(la1, lo1, la2, lo2)
        verify(d > 10, "前置：两点距离 = " + d + " m，夹具本身要足以分辨（否则两侧夹逼无意义）")
        verify(OpsCommon.reachedSlot(la1, lo1, la2, lo2, d * 1.001) === true,
               "半径略大于距离 ⇒ 已抵达（" + d + " m）")
        verify(OpsCommon.reachedSlot(la1, lo1, la2, lo2, d * 0.999) === false,
               "半径略小于距离 ⇒ 未抵达（" + d + " m）")
        // **正边界**：半径恰好等于距离。两侧夹逼（上面两行）**测不出** `<=` 被写成 `<`，
        // 因为两侧都留了 0.1% 的余量。这一行专门钉住边界**含**等号。
        // ⚠️ 它是浮点逐位相等 ⇒ 只在 `_greatCircleM` 与 `_distM` 是同一个算式时成立；
        //    那正是本节要的（两处距离公式一旦分叉，两行一起红）。
        verify(OpsCommon.reachedSlot(la1, lo1, la2, lo2, d) === true,
               "半径恰好等于距离 ⇒ 已抵达（边界含等号）")
    }

    /// **经度必须按纬度缩放**：同样的 `0.001°` 经度差，在赤道是 111.19 m，在 40°N 只有 85.18 m。
    /// 圈取 100 m ⇒ 40°N 判"已抵达"、赤道判"未抵达"。
    ///
    /// ‼️ 把经纬度当平面直角坐标（漏掉 `cos(lat)`）的实现在本格会**两格全绿或全红**，
    ///    而它在 40°N 会把判定圈在东西方向拉大成 111 m —— 比机位间距还大，
    ///    于是飞机会在离机位 100 m 处就宣布抵达并原地降落。
    function test_reachedSlot_longitudeScalesWithLatitude() {
        // 40°N：0.001° 经度 ≈ 85.18 m
        verify(OpsCommon.reachedSlot(40.0, 117.001, 40.0, 117.0, 100.0) === true,
               "40°N 的 0.001° 经度 ≈ 85.18 m，应在 100 m 圈内")
        // 赤道：同样的 0.001° 经度 ≈ 111.19 m
        verify(OpsCommon.reachedSlot(0.001, 117.001, 0.001, 117.0, 100.0) === false,
               "赤道的 0.001° 经度 ≈ 111.19 m，应在 100 m 圈外")
    }

    /// **一切存疑输入 ⇒ false**（不宣布抵达）。
    ///
    /// ‼️ 本格最重要的三行是 `slotLat / slotLon = 0`：后端 `opsOverviewItem` 的
    ///    「无可用接机机位」哨兵**就是 0/0**（机位未指派、或机位已软删 —— 见
    ///    `ops_overview_assign_slot_coord_test.go`）。少了这三行，接口字段一旦漏掉/改名，
    ///    `undefined` 会参与算术得 NaN，而 **NaN 的比较恒假** ⇒ 结论碰巧也是 false。
    ///    但那是靠巧合，不是靠代码：换一个算术顺序就可能翻成 true，
    ///    而那意味着**飞机飞向 (0, 0)**（几内亚湾）或"原地降落"。
    ///
    /// ‼️ `radiusM <= 0` 也回 false 而不是"半径 0 表示必须精确重合"：
    ///    后者在 GPS 噪声下**永不成立** ⇒ 飞机永远盘旋到超时，而界面上
    ///    显示的是"正在飞往机位"，与真实故障无法区分。宁可立刻判"未抵达"。
    function test_reachedSlot_invalidIsNotReached() {
        var la = 40.0, lo = 117.0
        // ‼️ 下面三格**必须让两点重合**（距离恰为 0）——这是唯一能打到哨兵检查上的形状。
        //    第一版写的是"机位在 (0,117)、目标在 (40,117)"（相距 4400 km）：那种写法下
        //    **距离判据自己就回 false**，断言靠的是距离而不是哨兵检查 ⇒
        //    变异实测（把 `isValidWaypoint(...)` 整行删掉）**四格全绿**，那几格是空的。
        //    ‼️ 这正是「探针要打在生产判据上」：一个恒假的断言看起来在测，其实什么都没测。
        //
        //    重合形状也正是**真实故障形状**：飞机没拿到 GPS 定位时坐标为 0/0，
        //    而接机机位未指派时后端哨兵也是 0/0 ⇒ 距离算出来是 **0** ⇒
        //    少了哨兵检查就会宣布"已抵达"并发出 `AUTO.LAND`（**原地降落**）。
        verify(OpsCommon.reachedSlot(0, 0, 0, 0, 100) === false,
               "机位与目标同为 0/0（未定位 + 后端哨兵）⇒ 距离 0，只有哨兵检查拦得住")
        verify(OpsCommon.reachedSlot(0, 117.0, 0, 117.0, 100) === false,
               "两点重合于**纬度 0** ⇒ 距离 0，只有哨兵检查拦得住")
        verify(OpsCommon.reachedSlot(40.0, 0, 40.0, 0, 100) === false,
               "两点重合于**经度 0** ⇒ 距离 0，只有哨兵检查拦得住")
        // 下面两格是"哨兵"这个契约的**命名**（飞机在真实坐标上）。⚠️ 诚实地说：
        // 这两格**同时**被距离判据覆盖（(0,0) 与 (40,117) 相距 4400 km），
        // 所以它们不是 load-bearing 的 —— 真正扛住哨兵契约的是上面三格。
        verify(OpsCommon.reachedSlot(la, lo, 0, 0, 100) === false,
               "接机机位 0/0（后端哨兵「无可用接机机位」）")
        verify(OpsCommon.reachedSlot(la, lo, 0, 117.0, 100) === false,
               "接机机位纬度 0（后端哨兵）")

        verify(OpsCommon.reachedSlot(NaN, lo, la, lo, 100) === false, "机位纬度 NaN")
        verify(OpsCommon.reachedSlot(la, NaN, la, lo, 100) === false, "机位经度 NaN")
        verify(OpsCommon.reachedSlot(la, lo, NaN, lo, 100) === false, "目标纬度 NaN")
        verify(OpsCommon.reachedSlot(la, lo, la, NaN, 100) === false, "目标经度 NaN")
        verify(OpsCommon.reachedSlot(undefined, lo, la, lo, 100) === false, "机位纬度 undefined")
        verify(OpsCommon.reachedSlot(null, lo, la, lo, 100) === false, "机位纬度 null")
        verify(OpsCommon.reachedSlot(la, lo, undefined, lo, 100) === false, "目标纬度 undefined")
        verify(OpsCommon.reachedSlot(la, lo, null, lo, 100) === false, "目标纬度 null")
        verify(OpsCommon.reachedSlot("40.0", lo, la, lo, 100) === false, "字符串纬度 ⇒ 只认数字类型")
        verify(OpsCommon.reachedSlot(la, lo, la, lo, "100") === false, "字符串半径 ⇒ 只认数字类型")

        verify(OpsCommon.reachedSlot(la, lo, la, lo, 0) === false, "半径 0")
        verify(OpsCommon.reachedSlot(la, lo, la, lo, -1) === false, "半径负数")
        verify(OpsCommon.reachedSlot(la, lo, la, lo, NaN) === false, "半径 NaN")
        verify(OpsCommon.reachedSlot(la, lo, la, lo, undefined) === false, "半径 undefined")
        verify(OpsCommon.reachedSlot(la, lo, la, lo, Infinity) === false, "半径 Infinity")
        verify(OpsCommon.reachedSlot(Infinity, lo, la, lo, 100) === false, "机位纬度 Infinity")
    }

    //-------------------------------------------------------------------------
    // 航线列表的显示顺序：**有告警的航线置顶**
    //   用户 2026-09-29 要求：「如果有航班告警，则航线列表、航班列表中告警对应的
    //   航线、航班置顶」。航班侧（`middleSectionSplit` 第 1 节）**现状即符合，不动**；
    //   航线侧此前**没有任何排序** —— `_routeRows` 按 `_routeOrder` 的自然顺序 push。
    //   判据住 `OpsCommon` 而不写在骨架里：骨架里那个 `readonly property var` 表达式
    //   QML 测试够不着，纯函数才钉得住（与 `groupTasksByRoute` 同一条理由）。
    //-------------------------------------------------------------------------

    /// `_routeRows` 里一项的最小形状：置顶只看 `has_abnormal`
    /// （它由 `g.some(OpsCommon.isAbnormal)` 算出，见 `OpsShell.qml` 的 `_routeRows`）。
    function _route(routeId, hasAbnormal) {
        return { route_id: routeId, route_code: "R" + routeId, has_abnormal: hasAbnormal }
    }

    /// 有告警的置顶，且**稳定**：组内保持原自然顺序（不是按告警数、也不是倒序）。
    function test_routesAbnormalFirst_stablePartition() {
        var r1 = _route(1, false)
        var r2 = _route(2, true)
        var r3 = _route(3, false)
        var r4 = _route(4, true)
        var out = OpsCommon.routesAbnormalFirst([r1, r2, r3, r4])
        compare(out.length, 4, "置顶不得多收或少收行")
        compare(out[0].route_id, 2, "有告警的排最前，且组内保持原顺序（2 在 4 之前）")
        compare(out[1].route_id, 4)
        compare(out[2].route_id, 1, "无告警的跟在后面，组内同样保持原顺序（1 在 3 之前）")
        compare(out[3].route_id, 3)
    }

    /// ‼️ **阴性对照**：一条告警都没有时**逐项同序**。
    /// 没有这一格，一个「把所有行倒过来」或「按 route_id 排序」的实现也能让上一格绿。
    function test_routesAbnormalFirst_noAbnormalKeepsOrder() {
        var all = [_route(3, false), _route(1, false), _route(2, false)]
        var out = OpsCommon.routesAbnormalFirst(all)
        compare(out.length, all.length)
        for (var i = 0; i < all.length; i++)
            compare(out[i].route_id, all[i].route_id, "无告警时第 " + i + " 项不得动")
    }

    /// ‼️ 判据是**真值即告警**，两边的误写各有症状、都不报错：
    ///   ⓐ `!== false`（"不是明确的 false 就算告警"）⇒ **缺键 / null 的行全被判成告警**
    ///     ⇒ 整张表都在置顶组里、顺序反而不变，看起来只是"排序没生效"；
    ///   ⓑ `=== true` ⇒ 真值 `1` / 非空串被静默漏掉，该置顶的不置顶。
    /// 本格用阳性（`1` 必须置顶）与阴性（缺键 / `null` / `0` 必须不置顶）把两边都钉死。
    function test_routesAbnormalFirst_truthyIsAbnormalFalsyIsNot() {
        var absent = { route_id: 1 }                                        // 缺 has_abnormal 键
        var nul = { route_id: 2, has_abnormal: null }
        var zero = { route_id: 3, has_abnormal: 0 }
        var one = { route_id: 4, has_abnormal: 1 }
        var real = { route_id: 5, has_abnormal: true }
        var out = OpsCommon.routesAbnormalFirst([absent, nul, zero, one, real])
        compare(out.length, 5, "置顶不得多收或少收行")
        compare(out[0].route_id, 4, "真值 1 也算告警（按 `=== true` 写会把这条静默漏掉）")
        compare(out[1].route_id, 5, "真 bool true 算告警，且组内保持原顺序（4 在 5 之前）")
        compare(out[2].route_id, 1, "缺键不算告警，且不得把它排到置顶组里去")
        compare(out[3].route_id, 2, "null 不算告警")
        compare(out[4].route_id, 3, "0 不算告警")
    }

    /// 空 / `null` / `undefined` 入参不得抛错；夹带的空项**不得被吞掉**
    /// （吞掉 ⇒ 列表行数会在有告警时凭空少一行，且只在告警时出现）。
    /// 返回 `undefined` 会让 QML 侧的 `routes:` 绑定报错，所以必须返回数组。
    function test_routesAbnormalFirst_emptyAndJunk() {
        compare(OpsCommon.routesAbnormalFirst(null).length, 0, "null ⇒ 空数组")
        compare(OpsCommon.routesAbnormalFirst(undefined).length, 0, "undefined ⇒ 空数组")
        compare(OpsCommon.routesAbnormalFirst([]).length, 0, "空数组 ⇒ 空数组")
        var out = OpsCommon.routesAbnormalFirst([null, _route(1, true), undefined])
        compare(out.length, 3, "夹带的空项不得被吞掉")
        compare(out[0].route_id, 1, "空项不算告警，真告警那条照样置顶")
    }

    //-------------------------------------------------------------------------
    // 规则 1（用户 2026-09-29 原话）：「航线列表中列出当前有执行任务的航线」
    //   ⇒ 一条**当前没有航班**的航线不进右栏列表。此前 `_routeRows` 对名册里每条航线
    //   都 push 一行（哪怕一条航班都没有，界面上就是 `active_count: 0` 的空行）。
    //   判据住 `OpsCommon` 而不写在骨架里：`_routeRows` 那个 `readonly property var`
    //   表达式 QML 测试够不着（同 `routesAbnormalFirst` 的理由）。
    //-------------------------------------------------------------------------

    /// `_routeRows` 里一项的最小形状：收窄只看 `tasks`（其余字段原样透传）。
    function _routeWithTasks(routeId, tasks) {
        return { route_id: routeId, route_code: "R" + routeId, tasks: tasks }
    }

    /// 差分点 + 阳性对照。‼️ 两格缺一不可：只断言"空的不在"的话，
    /// 一个 `return []` 的实现也全绿——而它会让右栏变成空的。
    function test_routesWithTasks_dropsRoutesWithoutTasks() {
        var out = OpsCommon.routesWithTasks([
            _routeWithTasks(1, [{ task_id: 101 }]),
            _routeWithTasks(2, []),
            _routeWithTasks(3, [{ task_id: 103 }, { task_id: 104 }])
        ])
        compare(out.length, 2, "有航班的 2 条留下，没航班的 1 条剔除")
        compare(out[0].route_id, 1, "阳性对照：有航班的必须留下")
        compare(out[1].route_id, 3, "阳性对照：多航班的也必须留下")
    }

    /// 保留项的相对顺序**逐项不动**（本函数只管收窄，排序是 `routesAbnormalFirst` 的事）。
    /// ‼️ 输入刻意用**降序**：若实现里顺手写了 `sort`（按 route_id 或按航班数），
    /// 上一格的 `[1, 3]` 恰好也是升序 ⇒ 测不出来，只会表现成"排序好像生效了"。
    function test_routesWithTasks_keepsRelativeOrder() {
        var out = OpsCommon.routesWithTasks([
            _routeWithTasks(9, [{ task_id: 1 }]),
            _routeWithTasks(4, []),
            _routeWithTasks(7, [{ task_id: 2 }]),
            _routeWithTasks(5, [{ task_id: 3 }])
        ])
        compare(out.length, 3)
        compare(out[0].route_id, 9, "第 0 项不得被排序挪走")
        compare(out[1].route_id, 7, "第 1 项不得被排序挪走")
        compare(out[2].route_id, 5, "第 2 项不得被排序挪走")
    }

    /// `tasks` 不是"非空数组"一律**剔除**；只有真数组且长度 > 0 才算有航班。
    ///
    /// 判据写 `Array.isArray(t) && t.length > 0`（fail-closed，与本仓守卫取向一致）。
    /// 写成 `t.length > 0` 的漏网口子：真值 `{}` 的 `.length` 是 `undefined`，
    /// `undefined > 0` 恰好也是 false ⇒ 这格抓不到 `{}`，但字符串 `"ab"` 会溜进去
    /// ——数据源一旦从数组变成字符串（接口改形状），列表会多出一行渲染不出卡片的航线。
    /// 写成 `t != null`（"有 tasks 键就算有航班"）⇒ `[]` 也算 ⇒ 规则 1 整个失效。
    function test_routesWithTasks_onlyNonEmptyArrayCounts() {
        var out = OpsCommon.routesWithTasks([
            _routeWithTasks(1, undefined),
            _routeWithTasks(2, null),
            _routeWithTasks(3, []),
            _routeWithTasks(4, ""),
            _routeWithTasks(5, "ab"),
            _routeWithTasks(6, {}),
            _routeWithTasks(7, 0),
            _routeWithTasks(8, { task_id: 1 }),
            _routeWithTasks(9, [{ task_id: 9 }])
        ])
        compare(out.length, 1, "只有第 9 条是真·非空数组")
        compare(out[0].route_id, 9)
    }

    /// 缺 `tasks` 键（不是 `null`，是**根本没有这个键**）同样剔除。
    /// 单独一格：`_routeRows` 里 `tasks` 恒存在，但别的调用点（或将来重构）可能漏传，
    /// 而漏传的症状是"整张表少了一半行"，不是报错。
    function test_routesWithTasks_missingTasksKeyIsDropped() {
        var out = OpsCommon.routesWithTasks([
            { route_id: 1, route_code: "R1" },
            _routeWithTasks(2, [{ task_id: 2 }])
        ])
        compare(out.length, 1, "缺 tasks 键的整行剔除")
        compare(out[0].route_id, 2)
    }

    /// 空 / `null` / `undefined` 入参不得抛错，且**必须返回数组**
    /// （返回 `undefined` 会让 QML 侧的 `routes:` 绑定报错）。夹带的空项不得被吞掉
    /// ——"吞掉"在这里是**对**的（它就是"没有航班"），所以本格只钉"不抛错 + 返回数组"。
    function test_routesWithTasks_emptyAndJunkInput() {
        compare(OpsCommon.routesWithTasks(null).length, 0, "null ⇒ 空数组")
        compare(OpsCommon.routesWithTasks(undefined).length, 0, "undefined ⇒ 空数组")
        compare(OpsCommon.routesWithTasks([]).length, 0, "空数组 ⇒ 空数组")
        var out = OpsCommon.routesWithTasks([null, undefined, _routeWithTasks(1, [{ task_id: 1 }])])
        compare(out.length, 1, "夹带的空项不得抛错（它没有 tasks ⇒ 按无航班剔除）")
        compare(out[0].route_id, 1, "同一批里的真航班照样留下")
    }

    /// 纯函数：**不得修改入参**。`_routeRows` 的入参 `out` 是当场构造的，
    /// 但函数被别处复用后"就地 splice"会让调用方看到一张被掏空的表，且不报错。
    function test_routesWithTasks_doesNotMutateInput() {
        var rows = [
            _routeWithTasks(1, [{ task_id: 1 }]),
            _routeWithTasks(2, []),
            _routeWithTasks(3, [{ task_id: 3 }])
        ]
        var out = OpsCommon.routesWithTasks(rows)
        compare(rows.length, 3, "入参数组长度不得被改动")
        compare(rows[0].route_id, 1, "入参第 0 项不得被改动")
        compare(rows[1].route_id, 2, "入参第 1 项（被剔除的那条）仍须留在入参里")
        compare(rows[2].route_id, 3)
        verify(out !== rows, "必须返回新数组，不得返回入参本身")
    }

    //-------------------------------------------------------------------------
    // NRRSM（2026-09-30 / D7 2026-10-01）：航线的**六个原始高度量 + 两个合成量**
    //
    // 三层高度：**地面海拔（MSL）** / **站点最低安全高度（AGL）** / **架次飞行高度（AGL）**。
    // 两个合成量 `takeoffAGL` / `landingAGL` 是**闸的判据项**（`> 0`）—— 注意判据是 AGL 量，
    // **不是**"组装后的 AMSL"：地面海拔会把 `0` 救活（站点地面海拔 100 米、两个高度都没设 ⇒
    // AMSL 100 > 0 ⇒ 闸放行 ⇒ 飞机贴地 100 米飞）。
    //-------------------------------------------------------------------------

    /// 六个量**两两不同**的 route 响应体。
    /// ‼️ 两两不同是**必须的**：若有重复，把 `takeoffClearAGL` 读成 `takeoffAltAGL` 之类的
    ///    键名写错也会全绿 —— 那是"断言等于在断常量"那一类假绿。
    /// 两侧刻意各有一个"大者"：起飞侧航线值(150) > 站点值(80)，降落侧站点值(200) > 航线值(120)
    /// ⇒ 一条夹具同时覆盖 `Math.max` 的两个分支。
    function _routeAltSix() {
        return {
            takeoff_alt_agl: 150,
            takeoff_site_clear_alt_agl: 80,
            takeoff_ground_msl: 100,
            landing_alt_agl: 120,
            landing_site_clear_alt_agl: 200,
            landing_ground_msl: 50
        }
    }

    /// 六个原始量**逐一对号**（每个键各等于各自那个数）。
    function test_routeAltitudeBounds_picksEachOfSixRawFields() {
        var b = OpsCommon.routeAltitudeBounds(_routeAltSix())
        compare(b.takeoffAltAGL, 150)
        compare(b.takeoffClearAGL, 80)
        compare(b.takeoffGroundMSL, 100)
        compare(b.landingAltAGL, 120)
        compare(b.landingClearAGL, 200)
        compare(b.landingGroundMSL, 50)
    }

    /// 合成量取两侧**大者**（D6 硬下限的生效值），起飞/降落各验一次
    /// ⇒ `Math.max` 的两个分支都覆盖到。
    function test_routeAltitudeBounds_compositeTakesMax() {
        var b = OpsCommon.routeAltitudeBounds(_routeAltSix())
        compare(b.takeoffAGL, 150, "起飞侧：航线值 150 > 站点安全高度 80 ⇒ 取 150")
        compare(b.landingAGL, 200, "降落侧：站点安全高度 200 > 航线值 120 ⇒ 取 200")
    }

    /// ‼️ 上一格的夹具**区分不出「起飞侧只取航线值」**：那里 `takeoffAltAGL(150)` 本来就大于
    ///    `takeoffClearAGL(80)`，漏掉后者的实现照样得 150（已实测：把 `takeoffAGL` 写成
    ///    `orZero(takeoffAltAGL)` 时，上一格**全绿**）。
    ///    本格把**两侧的支配者反过来**（起飞侧站点值大、降落侧航线值大）⇒ 与上一格合起来，
    ///    `Math.max` 的**四种支配组合**全被覆盖，"漏掉某一个操作数"必红。
    function test_routeAltitudeBounds_compositeTakesMaxOnBothSidesEitherWay() {
        var b = OpsCommon.routeAltitudeBounds({
            takeoff_alt_agl: 60, takeoff_site_clear_alt_agl: 140,
            landing_alt_agl: 300, landing_site_clear_alt_agl: 40
        })
        compare(b.takeoffAGL, 140, "起飞侧：站点安全高度 140 > 航线值 60 ⇒ 取 140")
        compare(b.landingAGL, 300, "降落侧：航线值 300 > 站点安全高度 40 ⇒ 取 300")
        // 阳性对照：原始量各自可读 —— 免得上面两条靠"实现里写死的常量"通过。
        compare(b.takeoffAltAGL, 60)
        compare(b.takeoffClearAGL, 140)
        compare(b.landingAltAGL, 300)
        compare(b.landingClearAGL, 40)
    }

    /// 两侧都是 `0`（未设定 / 未勘测）⇒ 合成量是 **`0`**，不是 `null`、也不是 `NaN`。
    /// ‼️ `0` 正是闸的"拦住"值：合成量恒为有限数字，调用方才能写值域判据 `> 0`。
    function test_routeAltitudeBounds_bothZeroCompositesToZero() {
        var b = OpsCommon.routeAltitudeBounds({
            takeoff_alt_agl: 0, takeoff_site_clear_alt_agl: 0,
            landing_alt_agl: 0, landing_site_clear_alt_agl: 0
        })
        compare(b.takeoffAGL, 0)
        compare(b.landingAGL, 0)
        compare(typeof b.takeoffAGL, "number", "必须是数字 0，而不是 null / NaN")
        compare(typeof b.landingAGL, "number")
    }

    /// 键缺失（后端没发这个字段）⇒ 六个原始量回 `null`（**类型层不可用**），
    /// **但两个合成量仍是 `0`**（`null` 不外传），且**不抛异常**。
    function test_routeAltitudeBounds_missingKeysCompositeToZero() {
        var b = OpsCommon.routeAltitudeBounds({})
        compare(b.takeoffAltAGL, null)
        compare(b.takeoffClearAGL, null)
        compare(b.takeoffGroundMSL, null)
        compare(b.landingAltAGL, null)
        compare(b.landingClearAGL, null)
        compare(b.landingGroundMSL, null)
        compare(b.takeoffAGL, 0)
        compare(b.landingAGL, 0)
        compare(typeof b.takeoffAGL, "number")
        compare(typeof b.landingAGL, "number")
    }

    /// `route` 为 `null` / `undefined` ⇒ **不抛异常**，合成量都是 `0`。
    /// （抛异常会让整条起飞流程炸在回调里，而界面上只看到"没反应"。）
    function test_routeAltitudeBounds_nullRouteDoesNotThrow() {
        var n = OpsCommon.routeAltitudeBounds(null)
        compare(n.takeoffAGL, 0)
        compare(n.landingAGL, 0)
        var u = OpsCommon.routeAltitudeBounds(undefined)
        compare(u.takeoffAGL, 0)
        compare(u.landingAGL, 0)
    }

    /// ‼️ **「键缺失」与「键在、但值非法」必须分开钉住**（补遗 §4）。
    /// 两者都回 `null`，但成因不同：前者是后端没发这个字段，后者是发了非 JSON number。
    /// 若只测其中一种，另一种的实现写错会被静默掩盖 —— 尤其"夹具键名与读键不一致"时，
    /// 用例会**为错误的理由通过**（键缺失 ⇒ `pick(undefined)` ⇒ `null`，看上去一样）。
    function test_routeAltitudeBounds_distinguishesMissingKeyFromInvalidValue() {
        // ① 键缺失 ⇒ null
        compare(OpsCommon.routeAltitudeBounds({}).takeoffAltAGL, null, "键缺失 ⇒ null")
        // ② 键在、值非法（字符串 / NaN）⇒ 同样 null
        var invalid = OpsCommon.routeAltitudeBounds({ takeoff_alt_agl: "500", landing_alt_agl: NaN })
        compare(invalid.takeoffAltAGL, null, "字符串 500 不认 —— 后端给的一定是 JSON number")
        compare(invalid.landingAltAGL, null, "NaN 不认")
        compare(invalid.takeoffAGL, 0, "值非法 ⇒ 合成量仍是 0（不得是 NaN）")
        compare(typeof invalid.landingAGL, "number")
        // ‼️ 阳性对照：没有这两条，上面几句对一个"永远回 null / 永远回 0"的实现**全是绿的**。
        var ok = OpsCommon.routeAltitudeBounds({ takeoff_alt_agl: 150, landing_alt_agl: 120 })
        compare(ok.takeoffAltAGL, 150, "阳性对照：值合法必须逐字取到")
        compare(ok.landingAltAGL, 120, "阳性对照：值合法必须逐字取到")
    }

    function test_applyLandingAltitude_replacesLastItemOnly() {
        // ‼️ 末项的四个字段（lat/lon/command/frame）取值**必须与入参可区分** ——
        //    若夹具末项取 `command: 16 / lat: 47.3 / frame: 0`，断言就等于在断常量：
        //    把实现改成 `command: MAV_CMD_NAV_WAYPOINT`（= 16）/ `lat: 47.3` / `frame: 0`
        //    照样全绿 ⇒ 末项真为 85（垂起着陆）时会被静默降级成普通航点。
        var items = [
            { command: 16, lat: 47.1, lon: 8.1, alt: 463.0, frame: 0 },
            { command: 16, lat: 47.2, lon: 8.2, alt: 410.0, frame: 0 },
            { command: 85, lat: 48.9, lon: 9.9, alt: 405.0, frame: 3 }
        ]
        var out = OpsCommon.applyLandingAltitude(items, 500.0)
        compare(out.length, 3)
        compare(out[0].alt, 463.0)   // 中间航点高度**原样**
        compare(out[1].alt, 410.0)
        compare(out[2].alt, 500.0)   // 末项换成航线降落高度
        compare(out[2].lat, 48.9)    // 坐标不动
        compare(out[2].lon, 9.9)
        compare(out[2].command, 85)  // command 不动 —— 被"规范化"成 16 必须红
        compare(out[2].frame, 3)     // frame 不动
    }

    function test_applyLandingAltitude_doesNotMutateInput() {
        // ‼️ 纯函数不得改入参：调用方可能还要用原始 items（比如算 waypointCount）。
        var items = [ { command: 16, lat: 1, lon: 2, alt: 10, frame: 0 },
                      { command: 16, lat: 3, lon: 4, alt: 20, frame: 0 } ]
        var out = OpsCommon.applyLandingAltitude(items, 999)
        compare(items[1].alt, 20)
        verify(out !== items, "必须返回新数组，不得返回入参本身")
        // ‼️ 阳性对照（修复轮 4 / 复审发现 ⑤ 的遗留）：上面两条对**恒回 `[]`** 的实现**全绿**
        //    —— `[]` 既不改入参、`[] !== items` 又对任何实现都真 ⇒ 必须有一条落在 `out`
        //    **内容**上的正断言，否则本格钉不住那种实现。
        compare(out.length, 2, "阳性对照：两元素入参 ⇒ 两元素出参（恒回 [] 会在这里红）")
        compare(out[1].alt, 999, "阳性对照：末项必须被 999 覆盖（只断「不改入参」钉不住恒回 []）")
    }

    /// 单点序列**也要被覆盖**（修复轮 2 / 发现 ①）。
    /// ‼️ 旧守卫是 `items.length < 2`，理由写的是"只有一个点时它既是起飞又是降落，语义不清"——
    ///    **该前提在 A1 之后已不成立**：起飞项**不在 `items` 里**（由 `OpsRouteSync.qml` 用
    ///    `insertTakeoffItem` 单独插进 plan 第 0 位），`items` 就是航点序列，
    ///    其末项**恒为降落站点航点**（行为 1 追加来的，或行为 2 本来就在末位）。
    ///    ⇒ 单点序列是**正常编辑可得到的形状**，不是畸形输入。
    /// ⚠️ 本格是**上一轮那条用例的翻版**：它原先断言 `out[0].alt === 10`（旧行为）。
    ///    旧行为会让末项**停在该航点地面海拔**、不加 `max(landing_alt_agl, clear_alt_agl)`
    ///    ⇒ 飞机被指令到**贴地**飞，而两道闸读的是 AGL 项 ⇒ **全绿放行**。
    function test_applyLandingAltitude_singleItemIsCovered() {
        var items = [ { command: 16, lat: 1, lon: 2, alt: 10, frame: 0 } ]
        var out = OpsCommon.applyLandingAltitude(items, 999)
        compare(out[0].alt, 999, "单点也必须被覆盖（旧的 `length < 2` 会让它停在 10）")
        compare(items[0].alt, 10, "不改入参")
        verify(out !== items, "必须返回新数组")
        compare(OpsCommon.applyLandingAltitude([], 999).length, 0, "空数组才「没事可做」")
        compare(OpsCommon.applyLandingAltitude(null, 999), null, "null 原样返回")
    }

    /// 发现 ① 的**端到端串联**：单点 `wps`（该点即终点）走完
    /// `appendLandingWaypoint → routeMissionItems → applyLandingAltitude` 后，
    /// 末项高度必须是 `assembledAltitude(地面海拔, max(landing_alt_agl, 站点安全高度))`。
    /// ‼️ 改动前（`applyLandingAltitude` 的 `length < 2` 早退）本格的末项会停在 **30**（地面海拔）
    ///    而不是 **230** —— 那正是"判据 ⑥ 在单点形状上静默失效"。
    function test_singleWaypointChain_lastAltitudeIsAssembled() {
        var groundMSL = 30.0
        var wps = [_wp(38.874500, 115.464500, groundMSL, 21, 5)]   // 唯一一点，且它就是终点
        var landed = OpsCommon.appendLandingWaypoint(wps, 5, 38.8745, 115.4645, groundMSL)
        compare(landed.length, 1, "单点且该点即终点 ⇒ 行为 2，长度仍是 1")
        var items = OpsCommon.routeMissionItems(landed, true, undefined, 30)
        compare(items.length, 1, "一个航点 ⇒ 一项")
        compare(items[0].alt, groundMSL, "唯一一项既是首项又是末项 ⇒ 不加 cruise，原样透传地面海拔")
        var landingAGL = OpsCommon.nrrsmEffectiveAGL(120, 200)   // D6 硬下限：站点安全高度 200 更大
        compare(landingAGL, 200, "硬下限取站点值")
        var final = OpsCommon.applyLandingAltitude(items,
            OpsCommon.assembledAltitude(groundMSL, landingAGL))
        compare(final.length, 1, "单点序列也必须进入覆盖分支（旧守卫会在这里早退）")
        compare(final[0].alt, 230.0, "末项 = 地面海拔 30 + max(120, 200) = 230（改动前是 30）")
    }

    function test_applyLandingAltitude_unusableAltitudeIsUnchanged() {
        var items = [ { command: 16, lat: 1, lon: 2, alt: 10, frame: 0 },
                      { command: 16, lat: 3, lon: 4, alt: 20, frame: 0 } ]
        compare(OpsCommon.applyLandingAltitude(items, null)[1].alt, 20)
        compare(OpsCommon.applyLandingAltitude(items, NaN)[1].alt, 20)
        compare(OpsCommon.applyLandingAltitude(items, "500")[1].alt, 20)
        compare(OpsCommon.applyLandingAltitude([], 500).length, 0)
        compare(OpsCommon.applyLandingAltitude(null, 500), null)
    }

    //-------------------------------------------------------------------------
    // A1（2026-10-01）：把「降落站点对应的航点」追加为 mission 末项
    //
    // 用户 A1 原话：「qgc发给px4的航线中**没有降落点**，是由一系列航点组成。A1 就是**最后一个
    // 航点**（同时也是降落站点所在位置，**经纬度由降落站点对应的航点的经纬度定**，……）」。
    // 「降落站点对应的航点」= `table_route.end_waypoint_id` 所指的那个航点。
    // ‼️ 裁定 R-A1：末项是**普通航点**，**不产生 85 NAV_VTOL_LAND** —— 追加项的 `command: 21`
    //    是**设计域**的「站点」标记，经 `_designCommandToMavCmd(21, false, …)` 映射成 `16`。
    //-------------------------------------------------------------------------

    /// 真库**固定航线**的形状：返回列表**非空**、且终点航点**不在**其中（⇒ 行为 1：追加）。
    /// 依据：**云端权威库** 2026-10-01 把全部 7 条航线逐一核算 —— 落到行为 1 的是 **1 / 20 / 21** 三条。
    /// ⚠️ 别再写「1/20/21/22」：**22 的 `table_route_waypoint` 是零行** ⇒ 它先撞**行为 7（空序列）**，
    ///    **根本到不了追加分支**（那一条走 `appendLandingWaypoint` 回 `[]`，不是本夹具的形状）。
    /// （本机 `db_uavm.db` 是陈旧副本、连 NRRSM 的列都没有，**不能**拿它当判据。）
    /// ⚠️ **出处等级**：上面这组读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
    ///    采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
    ///    （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    ///    **本任务（QGC 仓）无云端凭据，未独立复核。**
    function _wpsWithoutEnd() {
        return [_wp(39.748823, 116.143486, 50.0, 21, 3),
                _wp(39.748800, 116.143400, 50.0, 16, 4)]
    }

    /// 真库**QGC 上传航线**的形状：终点航点**恰为末项**（⇒ 行为 2：原样返回）。
    /// 依据：云端真库 2026-10-01 复核 —— 航线 4/5/23 的 `last_wp == end_waypoint_id`。
    /// ⚠️ **出处等级**：「云端真库 4/5/23」这条读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
    ///    采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
    ///    （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    ///    **本任务（QGC 仓）无云端凭据，未独立复核。**
    function _wpsWithEndLast() {
        return [_wp(39.748800, 116.143400, 50.0, 16, 4),
                _wp(38.874500, 115.464500, 30.0, 21, 5)]
    }

    /// 危险形状：终点航点**在列表里但不是末项**（⇒ 行为 3：作废，fail-closed）。
    function _wpsWithEndFirst() {
        return [_wp(38.874500, 115.464500, 30.0, 21, 5),
                _wp(39.748800, 116.143400, 50.0, 16, 4)]
    }

    /// 行为 1 + 反向用例：追加项**落在末尾**，且**坐标取自入参**（不是列表里任何一点）。
    /// ‼️ 只断 `length + 1` 的实现**照样绿** —— 那钉不住「坐标取的是降落站点航点」。
    function test_appendLandingWaypoint_appendsEndAtTail() {
        var out = OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 413.0)
        compare(out.length, 3, "列表里没有终点站 ⇒ 追加一项，长度 +1")
        compare(out[2].id, 5, "追加项必须是终点航点 id")
        compare(out[2].lat, 48.1, "纬度必须取自入参 endLat（取列表里任何一点都会 < 40）")
        compare(out[2].lon, 11.5, "经度必须取自入参 endLon")
        compare(out[2].altitude, 413.0, "地面海拔取自入参 endGroundMSL")
        compare(out[2].command, 21, "设计域「站点」标记 21（≠ MAVLink NAV_LAND(21)）")
        compare(out[0].id, 3, "原列表第 0 项保持不动")
        compare(out[1].id, 4, "原列表第 1 项保持不动")
    }

    /// 反向用例：**不原地改入参**（纯函数）。
    function test_appendLandingWaypoint_doesNotMutateInput() {
        var wps = _wpsWithoutEnd()
        var out = OpsCommon.appendLandingWaypoint(wps, 5, 48.1, 11.5, 413.0)
        compare(wps.length, 2, "入参数组长度不得被改动")
        compare(wps[0].id, 3, "入参第 0 项不得被改动")
        compare(wps[1].id, 4, "入参第 1 项不得被改动")
        verify(out !== wps, "必须返回新数组，不得返回入参本身")
        // ‼️ 下面两条必须落在 `out` 的**内容**上：上面四条全部落在入参 `wps` 或恒真式上，
        //    把 `appendLandingWaypoint` 变形成**恒回 `[]`** 时它们全过
        //    （`[] !== wps` 对任何实现都真）⇒ 该格照样全绿，钉不住任何东西。
        //    入参 2 元素（id 3 / 4）、列表里没有终点 ⇒ 期望追加成 3 项且末项 id 为 5。
        compare(out.length, 3, "列表里没有终点 ⇒ out 必须为 3 项（恒回 [] 会在此变红）")
        compare(out[2].id, 5, "追加项必须是终点航点 id（只钉长度钉不住「追加的是终点」）")
    }

    /// 行为 2：末项**恰好**就是终点 ⇒ 原样返回，**不重复追加**。
    /// 真库 4/5/23 就是这个形状；重复追加会让飞机到终点后再多飞一段回头路。
    /// ‼️ 与下一格（行为 3）只差一个顺序 —— 合成一格的话，写反了也测不出来。
    function test_appendLandingWaypoint_endAlreadyLastIsNotDuplicated() {
        var out = OpsCommon.appendLandingWaypoint(_wpsWithEndLast(), 5, 38.8745, 115.4645, 30.0)
        compare(out.length, 2, "末项已经是终点 ⇒ 长度不得变（重复追加会让飞机多飞一段）")
        compare(out[0].id, 4, "首项不动")
        compare(out[1].id, 5, "末项仍是终点航点")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithEndLast(), 5, 38.8745, 115.4645, 30.0).length, 2,
                "幂等：再调一次长度仍是 2")
    }

    /// 裁定 B（2026-10-01，修复轮 1）：末项**已经是终点**时，`endLat` / `endLon` /
    /// `endGroundMSL` **三者同时不可用**也**照样原样返回** —— 那一档走的是 `wps.slice()`，
    /// 这三个值在这条路上一次都不被读到。要求它们可用＝守卫过宽：会把云端真库 4 / 5 / 23
    /// 那三条**本来能发**的航线，因为一个**与它们正确性无关**的后端字段而拒掉，换不到任何安全性。
    /// ⚠️ **出处等级**：「云端真库 4 / 5 / 23」这条读数**不是本任务测的**，是**控制方（编排者）2026-10-01 只读实测**；
    ///    采集口径 = `ssh root@39.97.235.226`、库 `/opt/uavm/var/db_uavm.db`、**只读**打开
    ///    （`file:...?mode=ro&immutable=1`）、范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    ///    **本任务（QGC 仓）无云端凭据，未独立复核。**
    /// 末项坐标真的坏掉时，下游 `routeMissionItems` 会逐点校验 `lat` / `lon` / `altitude`
    /// 并回 `[]`（见 `test_appendLandingWaypoint_appendedItemBecomesPlainWaypoint` 同族的
    /// `routeMissionItems` 用例）⇒ 报的是**更贴近真相**的那句话。
    /// ‼️ 这一格是钉裁定 B 的**关键格**：把三道守卫挪回行为 2 **之前**（即读法 A），本格必红；
    ///    而"正常入参下原样返回"那种格（见上一格）在**两种实现下都绿**，钉不住这里。
    function test_appendLandingWaypoint_endAlreadyLastIgnoresUnusedInputs() {
        var out = OpsCommon.appendLandingWaypoint(_wpsWithEndLast(), 5, 0, 0, NaN)
        compare(out.length, 2, "末项已是终点 ⇒ 三个仅追加分支消费的入参全不可用，也应原样返回")
        compare(out[0].id, 4, "首项不动")
        compare(out[1].id, 5, "末项仍是终点航点")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithEndLast(), 5, 0, 0, NaN).length, 2, "幂等")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithEndLast(), 5, undefined, undefined, "x").length, 2,
                "undefined / 字符串同样不影响这一档")
    }

    /// 反向格：`endWaypointId` **本身**不可用 ⇒ 即使末项 id 与它"长得一样"，也回 `[]`
    /// （行为 4 是**先**判的 ⇒ 它必须在行为 2 **之前**拦掉）。
    /// ‼️ 挑 `"5"`（字符串）与 `NaN` 是有意的：把行为 2 写成宽松比较 `last.id == endWaypointId`、
    ///    或把它提到行为 4 之前的实现，都会在本格红。
    function test_appendLandingWaypoint_invalidEndIdBeatsEndAlreadyLast() {
        var wps = _wpsWithEndLast()
        compare(OpsCommon.appendLandingWaypoint(wps, "5", 0, 0, NaN).length, 0,
                "字符串「5」≠ number 5 ⇒ 作废（宽松 == 会把它误当成末项）")
        compare(OpsCommon.appendLandingWaypoint(wps, NaN, 0, 0, NaN).length, 0,
                "NaN ⇒ 作废（即使末项 id 是 5）")
        compare(OpsCommon.appendLandingWaypoint(wps, null, 0, 0, NaN).length, 0, "null ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(wps, 0, 0, 0, NaN).length, 0, "0 ⇒ 作废（「没有终点」哨兵）")
        // 阳性对照：同一个 wps、只把 id 换成合法的 5 ⇒ 必须原样返回（长度 2）。
        // 缺了它，上面几条对一个「永远回 []」的实现**全是绿的**。
        compare(OpsCommon.appendLandingWaypoint(wps, 5, 0, 0, NaN).length, 2,
                "阳性对照：id 合法 ⇒ 走行为 2，长度仍 2")
    }

    /// 行为 3：**在列表里但不是末项** ⇒ 回 `[]`（fail-closed）。
    /// 追加会绕回、不追加则末项不是降落点 —— 两条路都会飞出一条用户没画过的路径。
    /// 代价（已上报控制方）：**云端权威库全量 7 条里面没有一条**落到行为 3
    ///（落点：1/20/21 → 行为 1；4/5/23 → 行为 2；22 → 行为 7），但一旦出现，**同步会整个失败**
    /// （界面文案 = 「该航线未设定可用的降落站点，无法下发」）。
    /// ⚠️ **出处等级**：那句「全量 7 条里面没有一条落到行为 3」**不是本任务测的**，是
    ///    **控制方（编排者）2026-10-01 只读实测**；采集口径 = `ssh root@39.97.235.226`、
    ///    库 `/opt/uavm/var/db_uavm.db`、**只读**打开（`file:...?mode=ro&immutable=1`）、
    ///    范围 `table_route` 中 `deleted_at IS NULL` 的全量 7 条。
    ///    **本任务（QGC 仓）无云端凭据，未独立复核。**
    function test_appendLandingWaypoint_endInMiddleVoidsRoute() {
        compare(OpsCommon.appendLandingWaypoint(_wpsWithEndFirst(), 5, 38.8745, 115.4645, 30.0).length, 0,
                "终点不是末项 ⇒ 整条作废（不得追加、也不得原样返回）")
        // ‼️ 阳性对照（修复轮 2 / 发现 ⑤）：本格是该行为的**唯一覆盖格**，而上面全是否定断言
        //    ⇒ 一个**恒回 `[]`** 的实现单看它**全绿**。同一个夹具、只把"终点在列表里但非末项"
        //    换成"终点恰为末项"（末项 id = 4）⇒ 必须**非空**。
        var out = OpsCommon.appendLandingWaypoint(_wpsWithEndFirst(), 4, 39.7488, 116.1434, 50.0)
        compare(out.length, 2, "阳性对照：终点移到末项 ⇒ 必须原样返回（长度 2），否则本格钉不住")
    }

    /// 行为 4：`endWaypointId` 不是合法 id（口径与 `_endWaypointIndex` **逐字相同**）⇒ `[]`。
    function test_appendLandingWaypoint_invalidEndIdVoidsRoute() {
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), undefined, 48.1, 11.5, 413.0).length, 0,
                "undefined ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), null, 48.1, 11.5, 413.0).length, 0,
                "null ⇒ 作废（可空列被后端置 NULL 的常态）")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), "5", 48.1, 11.5, 413.0).length, 0,
                "字符串「5」⇒ 作废（只认 JSON number）")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 0, 48.1, 11.5, 413.0).length, 0,
                "0 ⇒ 作废（0 是「没有终点」的哨兵）")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), -1, 48.1, 11.5, 413.0).length, 0,
                "负数 ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), NaN, 48.1, 11.5, 413.0).length, 0,
                "NaN ⇒ 作废（NaN 是 number 但不是有限数）")
        // ‼️ 阳性对照（修复轮 2 / 发现 ⑤）：本格全是否定断言 ⇒ 恒回 `[]` 的实现全绿。
        //    同一个 wps、只把 id 换成合法的 5 ⇒ 必须追加成功。
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 413.0).length, 3,
                "阳性对照：id 合法必须追加成功（否则本格钉不住恒回 [] 的实现）")
    }

    /// 行为 5：终点坐标过不了单点定义 `isValidWaypoint`（**任一轴为 0 即无效**）⇒ `[]`。
    /// 后端在**没有终点航点**时把两键 `COALESCE` 成 `0` ⇒ 这一条同时也是「后端没给终点」的闸。
    function test_appendLandingWaypoint_invalidEndCoordsVoidsRoute() {
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 0, 11.5, 413.0).length, 0,
                "纬度 0（后端 COALESCE 的哨兵）⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 0, 413.0).length, 0,
                "经度 0 ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, NaN, 11.5, 413.0).length, 0,
                "NaN 纬度 ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, undefined, 11.5, 413.0).length, 0,
                "undefined 纬度 ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, null, 11.5, 413.0).length, 0,
                "null 纬度 ⇒ 作废")
        // 阳性对照：同样的入参、只把坐标换成合法值 ⇒ 必须成功。
        // 缺了它，上面几条对一个「永远回 []」的实现**全是绿的**。
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 413.0).length, 3,
                "阳性对照：坐标合法必须追加成功")
    }

    /// 行为 6：`endGroundMSL` 非有限数 ⇒ `[]`（它随后会进组装式算术，NaN 会污染末项高度）。
    function test_appendLandingWaypoint_nonFiniteGroundMSLVoidsRoute() {
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, NaN).length, 0, "NaN ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, undefined).length, 0,
                "undefined ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, "413").length, 0,
                "字符串 ⇒ 作废（只认 JSON number）")
        // 阳性对照：地面海拔为 0 是合法值（站点在海拔 0 米），**不得**被当成「缺」。
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 0).length, 3,
                "阳性对照：地面海拔 0 合法（不是「缺」）")
    }

    /// 行为 7：`wps` 为空 / 非数组 ⇒ `[]`。
    /// ‼️ **注意调用方**：`OpsRouteSync.qml` 在调本函数**之前**已用**另一句文案**
    ///（「航线没有可用航点，无法下发」）把空序列拦下了 —— 本函数回 `[]` 与它**不同因**，
    /// 所以两句话必须在那一侧分开（否则「航线一个航点都没有」会被报成「降落站点不可用」，
    /// 把用户指向错误的方向；该坑 `OpsRouteSync.qml` 的 `start()` 里「未设定飞行高度」
    /// 那道拒发闸的注释已明文警告过）。
    function test_appendLandingWaypoint_emptyWpsVoidsRoute() {
        compare(OpsCommon.appendLandingWaypoint([], 5, 48.1, 11.5, 413.0).length, 0, "空数组 ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(null, 5, 48.1, 11.5, 413.0).length, 0, "null ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint(undefined, 5, 48.1, 11.5, 413.0).length, 0, "undefined ⇒ 作废")
        compare(OpsCommon.appendLandingWaypoint("x", 5, 48.1, 11.5, 413.0).length, 0, "非数组 ⇒ 作废")
        // ‼️ 阳性对照（修复轮 2 / 发现 ⑤）：本格全是否定断言 ⇒ 恒回 `[]` 的实现全绿。
        //    只把第一个实参换成非空数组、其余**逐字不动** ⇒ 必须追加成功。
        compare(OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 413.0).length, 3,
                "阳性对照：同一组入参、只把 wps 换成非空数组 ⇒ 必须追加成功")
    }

    /// 端到端形状：追加项经 `routeMissionItems` 后必须是 **`16 NAV_WAYPOINT`**，且**不带 85**
    /// —— 这是裁定 R-A1 的主判据（末项是普通航点，不产生 `NAV_VTOL_LAND`）。
    function test_appendLandingWaypoint_appendedItemBecomesPlainWaypoint() {
        var landed = OpsCommon.appendLandingWaypoint(_wpsWithoutEnd(), 5, 48.1, 11.5, 413.0)
        var items = OpsCommon.routeMissionItems(landed, true, undefined, 30)
        compare(items.length, 3, "三点都要下发")
        compare(items[2].command, 16, "追加项是**普通航点** 16 —— 出现 85 即违反裁定 R-A1")
        for (var i = 0; i < items.length; i++) {
            verify(items[i].command !== 85, "R-A1：本链路不产生 NAV_VTOL_LAND(85)")
        }
        // 追加项是**末项** ⇒ `routeMissionItems` 对它原样透传 altitude（不加 cruise），
        // 随后再由 `applyLandingAltitude` 覆盖成降落端组装式 AMSL（判据 6）。
        compare(items[2].alt, 413.0, "末项在 routeMissionItems 里原样透传 altitude")
        compare(items[0].alt, 80.0, "中间项仍组装成「该航点地面海拔 + cruiseAGL」= 50 + 30")
    }

    //-------------------------------------------------------------------------
    // A2（2026-10-01）：判据 5 / 6 的**最后一跳** —— 组装式高度
    //-------------------------------------------------------------------------

    function test_assembledAltitude_addsGroundPlusAgl() {
        compare(OpsCommon.assembledAltitude(413, 50), 463, "判据 5/6 的字面算式：413 + 50")
        compare(OpsCommon.assembledAltitude(413, 100), 513,
                "只改第二个加数 ⇒ 463→513；写成「groundMSL + 常量」或漏掉 agl 必红")
        compare(OpsCommon.assembledAltitude(0, 50), 50, "站点地面海拔 0 是合法值，不得被当成「缺」")
        compare(OpsCommon.assembledAltitude(100, 0), 100, "AGL 为 0 时地面海拔照旧透传（本函数只做算术）")
    }

    function test_assembledAltitude_nonFiniteIsNaN() {
        verify(isNaN(OpsCommon.assembledAltitude(undefined, 50)), "undefined 地面海拔 ⇒ NaN")
        verify(isNaN(OpsCommon.assembledAltitude(413, undefined)), "undefined AGL ⇒ NaN")
        verify(isNaN(OpsCommon.assembledAltitude(NaN, 50)), "NaN ⇒ NaN")
        verify(isNaN(OpsCommon.assembledAltitude(413, NaN)), "NaN AGL ⇒ NaN")
        verify(isNaN(OpsCommon.assembledAltitude(null, 50)), "null ⇒ NaN（null 不是「缺」，是类型不符）")
        verify(isNaN(OpsCommon.assembledAltitude("413", 50)), "字符串 ⇒ NaN")
        verify(OpsCommon.assembledAltitude(undefined, 50) !== 0,
               "必须是 NaN 而不是 0 —— 0 会让下游闸的 !(x > 0) 失效（未设定被当成有效高度）")
        // ‼️ 阳性对照（修复轮 2 / 发现 ⑤）：上面全是否定断言 ⇒ 一个**恒回 NaN** 的实现
        //    单看本格**全绿**。下面这一条把它挡住。
        verify(!isNaN(OpsCommon.assembledAltitude(413, 50)),
               "阳性对照：合法输入必须得数（否则本格对恒回 NaN 的实现全绿）")
    }

    //-------------------------------------------------------------------------
    // B7（2026-10-01）：D6 硬下限的单点定义
    //-------------------------------------------------------------------------

    function test_nrrsmEffectiveAGL_takesMaxOfBothSides() {
        compare(OpsCommon.nrrsmEffectiveAGL(150, 80), 150, "航线值大 ⇒ 取航线值")
        compare(OpsCommon.nrrsmEffectiveAGL(60, 140), 140, "站点值大 ⇒ 取站点值")
        compare(OpsCommon.nrrsmEffectiveAGL(100, 100), 100, "相等 ⇒ 取该值")
        compare(OpsCommon.nrrsmEffectiveAGL(0, 0), 0, "两侧都是 0（未设定）⇒ 0")
    }

    function test_nrrsmEffectiveAGL_unusableInputsCountAsZero() {
        compare(OpsCommon.nrrsmEffectiveAGL(null, null), 0, "两侧都不可用 ⇒ 0（不是 NaN）")
        compare(OpsCommon.nrrsmEffectiveAGL(null, 50), 50, "null 按 0 计 ⇒ 取另一侧")
        compare(OpsCommon.nrrsmEffectiveAGL(NaN, 50), 50, "NaN 按 0 计 ⇒ 取另一侧")
        compare(OpsCommon.nrrsmEffectiveAGL(undefined, undefined), 0, "undefined 按 0 计")
        compare(typeof OpsCommon.nrrsmEffectiveAGL(NaN, NaN), "number",
                "恒为有限数字 —— null / NaN 不外传")
    }

    /// 新增的三个终点航点量：键名 + `pick` 口径（键缺失 / 非数字 ⇒ `null`）。
    function test_routeAltitudeBounds_picksEndWaypointFields() {
        var b = OpsCommon.routeAltitudeBounds({
            end_waypoint_id: 5, end_waypoint_lat: 38.8745, end_waypoint_lon: 115.4645
        })
        compare(b.endWaypointId, 5, "键名 endWaypointId ← route.end_waypoint_id")
        compare(b.endLat, 38.8745, "键名 endLat ← route.end_waypoint_lat")
        compare(b.endLon, 115.4645, "键名 endLon ← route.end_waypoint_lon")
        // 键缺失 ⇒ null（与六个高度原始量同口径）
        var missing = OpsCommon.routeAltitudeBounds({})
        compare(missing.endWaypointId, null, "键缺失 ⇒ null")
        compare(missing.endLat, null)
        compare(missing.endLon, null)
        // 后端在**没有终点航点**时把经纬度 COALESCE 成 0 ⇒ `pick(0)` 回**数字 0**（不是 null）
        var noEnd = OpsCommon.routeAltitudeBounds({ end_waypoint_id: null, end_waypoint_lat: 0, end_waypoint_lon: 0 })
        compare(noEnd.endWaypointId, null, "可空列 NULL ⇒ pick 回 null")
        compare(noEnd.endLat, 0, "COALESCE 后的 0 是**数字 0**，不是 null")
        compare(noEnd.endLon, 0)
    }

    /// 扩键之后，既有的六个高度量 + 两个合成量**逐字不变**（回归护栏），
    /// 且合成量必须与单点定义 `nrrsmEffectiveAGL` **完全一致**（B7 的承重点）。
    function test_routeAltitudeBounds_existingKeysUnchangedAfterA1() {
        var b = OpsCommon.routeAltitudeBounds(_routeAltSix())
        compare(b.takeoffAGL, 150, "合成量仍取两侧大者")
        compare(b.landingAGL, 200)
        compare(b.takeoffGroundMSL, 100, "原始量仍在")
        compare(b.landingGroundMSL, 50)
        compare(b.takeoffAGL, OpsCommon.nrrsmEffectiveAGL(b.takeoffAltAGL, b.takeoffClearAGL),
                "bounds 的合成量必须与单点定义 nrrsmEffectiveAGL 完全一致")
        compare(b.landingAGL, OpsCommon.nrrsmEffectiveAGL(b.landingAltAGL, b.landingClearAGL),
                "bounds 的合成量必须与单点定义 nrrsmEffectiveAGL 完全一致")
    }

    //-------------------------------------------------------------------------
    // W1（2026-10-01）：NRRSM「一个 AGL 米值是否已设定」的可测谓词
    //
    // ‼️ `0` 在本系统里是「未设定」的**编码**，不是「贴地飞」这个合法高度 ——
    //    判据 4/7 下 `cruise_alt_agl = 0` 会算出「飞行高度 = 航点地面海拔」，
    //    也就是降到**地形高度平飞**。起飞/降落两端同理。
    //    「三道高度闸收敛到同一个谓词」的**唯一承重点就在本组**（`OpsRouteSync.qml`
    //    全仓零测试 ⇒ 那边改了没有测试会红）。
    //
    // ‼️ 每一格**单独一个测试函数**（不是把七条 `compare` 塞进一个函数）：
    //    QtTest 里一格里第一处 `compare` 失败即中止该格，合并成一格的话
    //    变异只能数出「打到没打到」，分辨不出**打到哪几格** —— 而红格清单正是判据。
    //-------------------------------------------------------------------------

    /// 格 1 · 阳性对照 —— 只写「0 被拒」时，`return false` 这种常数实现**也全绿**。
    function test_nrrsmUsableAGL_positiveNumberIsUsable() {
        compare(OpsCommon.nrrsmUsableAGL(50), true, "50 ⇒ 已设定")
        compare(typeof OpsCommon.nrrsmUsableAGL(50), "boolean", "必须是真布尔，不是 1/0")
    }

    /// 格 2 · 核心：`0` = 未设定（判据 4 的编码）。
    function test_nrrsmUsableAGL_zeroIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL(0), false, "0 ⇒ 未设定，不是「贴地飞」")
    }

    /// 格 3 · 负值。
    function test_nrrsmUsableAGL_negativeIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL(-1), false, "负值 ⇒ 不可用")
    }

    /// 格 4 · QML `property real` 的缺省值就是 `NaN`（没取到值时的形态）。
    function test_nrrsmUsableAGL_nanIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL(NaN), false, "NaN ⇒ 不可用")
    }

    /// 格 5 · 键缺失。
    function test_nrrsmUsableAGL_undefinedIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL(undefined), false, "undefined ⇒ 不可用")
    }

    /// 格 6 · 类型判据 —— 只写 `v > 0` 的实现会**静默放行**字符串 `"50"`（JS 里 `"50" > 0` 为真）。
    function test_nrrsmUsableAGL_numericStringIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL("50"), false, "字符串 \"50\" ⇒ 不可用（类型判据，不是装饰）")
    }

    /// 格 7 · 有限性。
    function test_nrrsmUsableAGL_infinityIsNotUsable() {
        compare(OpsCommon.nrrsmUsableAGL(Infinity), false, "Infinity ⇒ 不可用（有限性）")
    }

    //-------------------------------------------------------------------------
    // 起/终维：**指令权持有方**（规范 §2.7.2 h，2026-10-06 由"起飞站"扩到三档）
    //
    //   ① 起飞站：`takeoff_site_id == 本端` 且 `checkout_state !== 'ACCEPTED'`
    //   ② 监控员：`signed_in`               且 `!landing_accepted`
    //   ③ 降落站：`landing_site_id == 本端` 且 `landing_accepted`
    //
    // 三档**互斥** ⇒ 同一架飞机在任一时刻恰好只有一处"本端持有它的指令权"。
    // ‼️ 这不是"谁能看"（可接引范围，服务端判），是"该由谁**发言**"（建链权，客户端判）。
    //    判错的后果不是显示不对，而是同一 deviceID 两端各取一个 counter ⇒ nonce 重复
    //    ⇒ GCM keystream 泄漏（规范 §2.5）——**链路上没有任何一处会报错。**
    //
    // ⚠️ 本组夹具**刻意不造**实现不该读的字段（`landing_state`、监控员侧的 `checkout_state`）：
    //    一旦实现去读它们，读到的是 `undefined`，本组会当场红。
    //-------------------------------------------------------------------------

    /// 与 `opsOverviewItem`（`GET /api/ops/overview?view=site`）同形的最小任务项。
    /// 站点侧判据**只吃**这四个字段 —— 多造一个都会让"实现读错字段"这件事变得不可观测。
    function _ctlSiteTask(takeoffSite, landingSite, checkoutState, landingAccepted) {
        return {
            task_id: 91103,
            takeoff_site_id: takeoffSite,
            landing_site_id: landingSite,
            checkout_state: checkoutState,
            landing_accepted: landingAccepted
        }
    }

    /// 与 `opsMonitorDevice`（③ `devices[]`）同形的最小项。
    /// ‼️ 服务端的 `opsMonitorDevice` 上**没有** `checkout_state`、**也没有** `landing_state`。
    function _ctlDevice(deviceId, signedIn, landingAccepted) {
        return { device_id: deviceId, signed_in: signedIn, landing_accepted: landingAccepted }
    }

    /// ① 起飞站档：闸是 `checkout_state !== 'ACCEPTED'` —— 一个**否定**判据。
    ///
    /// 三格分别钉住三种写法，缺任何一格都有一种错法全绿：
    ///   · `''`（无交接）⇒ true —— 钉"把判据写成 `=== 'PENDING'`"（那样立刻能飞的任务没人管）；
    ///   · `'REJECTED'/'CANCELLED'/'TIMEOUT'` ⇒ **仍** true —— 钉"把判据写成 `=== ''`"。
    ///     签出被驳回/撤回/超时之后责任**还在起飞站手上**（这正是用户 2026-09-23 要求
    ///     那三种终态仍显示【签出】【回航】的原因）⇒ 这三格是**与 `checkoutPending` 的分界**；
    ///   · `'ACCEPTED'` ⇒ **必须 false** —— 钉"漏掉整条判据"（那样交棒之后起飞站还在抢话）。
    function test_siteHoldsControl_takeoffTierIsNegatedCheckoutState() {
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "", false), 1) === true,
               "无交接 ⇒ 责任在起飞站，必须持有")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "PENDING", false), 1) === true,
               "签出等待确认中 ⇒ 责任仍在起飞站（判定写成 === 'PENDING' 会漏掉下面三格）")
        var ended = ["REJECTED", "CANCELLED", "TIMEOUT"]
        for (var i = 0; i < ended.length; i++) {
            verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, ended[i], false), 1) === true,
                   "签出终态 " + ended[i] + " ⇒ 责任**仍在**起飞站（判据若写成 === '' 这里会红）")
        }
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", false), 1) === false,
               "监控员已签入 ⇒ 起飞站**当场让出**（漏掉本格，交棒之后起飞站还在抢话）")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", false), 2) === false,
               "非本站 ⇒ 无论状态如何都不得持有")
    }

    /// ③ 降落站档：`landing_site_id == 本端` **且** `landing_accepted`。
    /// `landing_accepted`（= `EXISTS(phase_to='LANDING' ∧ status='ACCEPTED')`）与
    /// `tasks[].landing_state`（= 最近一条 LANDING 交接的状态）不是一回事。
    ///
    /// ⚠️ 本行此前称 `landing_accepted` 为**单调**——**2026-10-06 订正**，与 `OpsCommon.js`
    ///    `monitorHoldsControl` 上方那段同步：它**不是无条件单调**的，改降作废会把那条
    ///    ACCEPTED 行改写成 `CANCELLED` ⇒ EXISTS 当场翻假。准确的说法是「**不随重提翻假**」
    ///    （多一条 PENDING 不影响它），而**不是**「永真」。
    function test_siteHoldsControl_landingTierNeedsLandingAccepted() {
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", true), 2) === true,
               "降落本站 + 已签入 LANDING ⇒ 起飞站交棒完毕，责任在**降落站**")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", false), 2) === false,
               "降落本站但**尚未**签入 ⇒ 责任还在监控员手上，降落站不得持有")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", true), 3) === false,
               "本站既非起飞也非降落、却已签入 LANDING ⇒ 不得持有")
    }

    /// ‼️ **站点字段的合取不可省**（两格，各钉一种简化写法）：
    ///   · 只写 `landingAccepted(task)` ⇒ 凡是有人签入 LANDING 的飞机，**每个**站点都自称持有；
    ///   · 只写 `checkoutState(task) !== 'ACCEPTED'` ⇒ 凡是还没签出的飞机，**每个**站点都自称持有。
    /// 两种简化都不会报错，只会在多站点场景下让**不相干的站**一起抢着建链。
    function test_siteHoldsControl_siteFieldIsNotOptional() {
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", true), 3) === false,
               "只写 landingAccepted 的实现会让**第三站**也持有（本站与这架飞机毫无关系）")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "", false), 3) === false,
               "只写 !checkoutState 的实现会让**第三站**也持有")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "ACCEPTED", true), 0) === false,
               "`mySiteId` 无效（0 / 未登录）⇒ fail-closed，不得因 `Number(undefined)>0` 为假而误判")
        verify(OpsCommon.siteHoldsControl(null, 1) === false, "无任务 ⇒ false，且不得抛错")
        verify(OpsCommon.siteHoldsControl(_ctlSiteTask(1, 2, "", false), undefined) === false,
               "`mySiteId` 为 undefined ⇒ false（不得让 `Number(undefined) === NaN` 蒙混过关）")
    }

    /// ‼️ **三档互斥**：把四格**可达**组合枚举一遍，逐格数"有几处持有"。
    ///
    /// 只断言"某格为 false"是不够的 —— 那样一个"谁来问都说 true"的实现在逐格断言下
    /// 只会红一格，而**互斥性**才是本组要保的东西（两端同时持有 ⇒ nonce 重复）。
    /// ⇒ 本格断言的是**持有者的集合**，不是单点取值。
    ///
    /// ⚠️ 只枚举四格：`landing_accepted=true` 而 `checkout_state!=='ACCEPTED'` 的两格由后端不变量
    ///    `landing_accepted ⟹ checkout_state === 'ACCEPTED'` 排除（LANDING 交接只可能在 ROUTE
    ///    被签入之后提出）。该不变量属服务端，本组断言不到它 —— 但它一旦被破坏，
    ///    `siteHoldsControl` 会让起飞站与降落站**同时**为真，所以在这里写明。
    function test_siteHoldsControl_atMostOneSiteHoldsControl() {
        var combos = [
            { checkout: "",         accepted: false, want: [1] },   // 责任在起飞站
            { checkout: "PENDING",  accepted: false, want: [1] },   // 同上（签出等待确认）
            { checkout: "REJECTED", accepted: false, want: [1] },   // 同上（终态退回起飞站）
            { checkout: "ACCEPTED", accepted: false, want: []  },   // 已交棒，责任在监控员——两站皆无
            { checkout: "ACCEPTED", accepted: true,  want: [2] }    // 交棒完毕，责任在降落站
        ]
        for (var i = 0; i < combos.length; i++) {
            var c = combos[i]
            var task = _ctlSiteTask(1, 2, c.checkout, c.accepted)
            var holders = []
            if (OpsCommon.siteHoldsControl(task, 1)) holders.push(1)
            if (OpsCommon.siteHoldsControl(task, 2)) holders.push(2)
            compare(holders.join(","), c.want.join(","),
                    "checkout_state=" + c.checkout + " landing_accepted=" + c.accepted +
                    " ⇒ 持有方必须是 [" + c.want + "]")
        }
    }

    /// ② 监控员档：`signed_in` **且** `!landing_accepted`。
    ///
    /// 两格缺一不可，且各自钉掉一种错法：
    ///   · `signed_in=false` ⇒ false：钉"恒 true"（那会让**每个**监控员都去建链）；
    ///   · `landing_accepted=true` ⇒ **必须 false**：这是第三跳的**让位点**。
    ///     少了它，监控员与降落站会**同时**持有上行权 ⇒ 同 deviceID 两端各取一个 counter
    ///     ⇒ nonce 重复（规范 §2.5）。
    function test_monitorHoldsControl_needsSignedInAndNotLandingAccepted() {
        verify(OpsCommon.monitorHoldsControl(_ctlDevice(9103, true, false)) === true,
               "已签入、尚未签入 LANDING ⇒ 监控员持有")
        verify(OpsCommon.monitorHoldsControl(_ctlDevice(9103, false, false)) === false,
               "未签入 ⇒ 不得持有（恒 true 的实现会让每个监控员都去建链）")
        verify(OpsCommon.monitorHoldsControl(_ctlDevice(9103, true, true)) === false,
               "已签入 LANDING ⇒ 监控员**当场让出**（少了本格，两端同时持有）")
        verify(OpsCommon.monitorHoldsControl(_ctlDevice(9103, false, true)) === false,
               "两者皆非 ⇒ false")
        verify(OpsCommon.monitorHoldsControl(null) === false, "无设备 ⇒ false，且不得抛错")
    }

    /// ‼️ 本组钉的是**取值来源**：监控员侧必须读 `landing_accepted`，不得读
    ///    `tasks[].landing_state`，也不得读站点侧的 `checkout_state`。
    ///
    /// 两格构造出"两个字段给出相反答案"的输入 —— 这是能把取值来源钉死的形状。
    ///
    /// ⚠️ **两格的输入在现行实现下都不是生产可达的形状**，本注释此前把它们说成可达，
    ///    **2026-10-06 订正**（静态论证，未做运行时探针）：
    ///   · `landing_accepted=true` 而 `landing_state='PENDING'` ⇒ 本格仍要求 **false**。
    ///     **修复前**它真实可达：`Propose` 的 LANDING 分支只挡 PENDING（不像 ROUTE 分支还挡
    ///     ACCEPTED）⇒ 签入之后再提一条就把 `landing_state` 打回 PENDING，此时若实现读
    ///     `landing_state` 判据翻真 ⇒ 监控员与降落站**同时**持有（规范 §2.5）。
    ///     **2026-10-06 起该缺口已堵**（LANDING 闸改成 `status IN ('PENDING','ACCEPTED')`）⇒
    ///     LANDING 的 PENDING 行只能由 `Propose` 产生，而它此刻必被 409 挡下
    ///     （`task.Return` 那条 INSERT 只写 ACCEPTED，且仅在无 ACCEPTED 时写）⇒ 形状不再可达。
    ///     ⚠️ 闸一旦被放宽，形状立刻回来 —— 本格是那道闸的**下游**保险，别因"不可达"删格。
    ///   · `landing_accepted=false` 而 `landing_state='ACCEPTED'` ⇒ 本格仍要求 **true**。
    ///     此形状**结构上不可能**，不只是"少见"：`landing_state` 取 max-id LANDING 行的状态
    ///     （`lastLandingHandover`），而 `landing_accepted` ＝ `EXISTS(phase_to='LANDING' ∧
    ///     status='ACCEPTED')` —— max-id 行是 ACCEPTED ⟹ `EXISTS` 必为真。
    ///     ⇒ 本格**纯属合成输入**，价值仅剩"实现读了哪个字段"这一条（那正是本组要钉的）。
    function test_monitorHoldsControl_readsMonotonicFieldNotLandingState() {
        var stale = _ctlDevice(9103, true, true)
        stale.landing_state = "PENDING"
        verify(OpsCommon.monitorHoldsControl(stale) === false,
               "landing_accepted=true 而 landing_state=PENDING ⇒ 必须 false" +
               "（读 landing_state 会翻真，两端同时持有上行权）")

        var reverted = _ctlDevice(9103, true, false)
        reverted.landing_state = "ACCEPTED"
        verify(OpsCommon.monitorHoldsControl(reverted) === true,
               "landing_accepted=false 而 landing_state=ACCEPTED ⇒ 必须 true" +
               "（这一格挡住『反正都是 LANDING 的状态，挑一个读就行』）")

        // 站点侧的 `checkout_state` 在 ③ 的 `devices[]` 上**根本不存在**：读它得到 undefined，
        // 而 `undefined !== 'ACCEPTED'` 恒真 ⇒ 判据恒真 ⇒ 监控员永远不让位。这里把那个输入
        // 显式造出来，钉住"实现不得回头去找站点侧的字段"。
        verify(OpsCommon.monitorHoldsControl(_ctlDevice(9103, true, true)) === false,
               "构造的项上没有任何 checkout_state：若实现拿它兜底，本格会因恒真而红")
    }

    /// ③ 名单提取：`initiatorDeviceIds` 与 `monitorDeviceIds` **不是同一份清单，不得合并**。
    ///
    /// 两者管的是两件事：前者＝建链权（**当前**持有指令权的那一架），后者＝80005 登记集合
    /// （本端名册上的**全部**飞机，收了帧才不掉线）。合并的后果不是"多推了几个 id"，
    /// 而是**用可接引范围顶替责任方判据**——两个正交维被压成一维。
    /// ⇒ 本格的核心断言是**两份清单不相等**，而不是各查各的。
    function test_initiatorDeviceIds_isNotTheMonitorRoster() {
        var devices = [
            _ctlDevice(9103, true,  false),   // 持有 ⇒ 两份都在
            _ctlDevice(9104, false, false),   // 未签入 ⇒ 只在登记集合里
            _ctlDevice(9105, true,  true),    // 已让位 ⇒ 只在登记集合里
            _ctlDevice(9103, true,  false)    // 重复项（后端已去重，此处是第二道）
        ]
        compare(JSON.stringify(OpsCommon.initiatorDeviceIds(devices)), "[9103]",
                "指令权名单 = 当前持有指令权的那一架；未签入的（9104）与已让位的（9105）都不得进")
        compare(JSON.stringify(OpsCommon.monitorDeviceIds(devices)), "[9103,9104,9105]",
                "登记集合 = 名册上的全部飞机（两者**必须**不同，否则本函数没有存在意义）")
    }

    /// 名单提取的边角：`device_id <= 0` 必须在 **QML → C++ 的唯一入口**上被挡掉。
    /// 漏掉它会在 mavp2p 侧建出一个 `deviceID=0` 的 pair —— **没有任何一处会报错**。
    /// 另：无人持有 ⇒ 返回**空数组**（不是 null/undefined）：它表示"本端此刻不持有任何一架"，
    /// 是**有效**结论 ⇒ 全拒（fail-closed）；与"从未推送过"是相反的建链答案。
    function test_initiatorDeviceIds_filtersInvalidIdsAndNeverReturnsNull() {
        var withBad = [
            _ctlDevice(0,    true, false),
            _ctlDevice(-1,   true, false),
            _ctlDevice(9103, true, false)
        ]
        compare(JSON.stringify(OpsCommon.initiatorDeviceIds(withBad)), "[9103]",
                "device_id <= 0 必须被挡（否则会建出 deviceID=0 的 pair，零报错）")
        verify(Array.isArray(OpsCommon.initiatorDeviceIds([_ctlDevice(9104, false, false)])),
               "无人持有 ⇒ 必须是空**数组**，表示『本端此刻不持有任何一架』（有效结论，全拒）")
        compare(OpsCommon.initiatorDeviceIds([_ctlDevice(9104, false, false)]).length, 0,
                "同上：长度为 0 —— 与『从未推送过』在建链答案上相反，故不得返回 null/undefined")
        verify(Array.isArray(OpsCommon.initiatorDeviceIds(null)), "null ⇒ 空数组，且不得抛错")
    }

    //=========================================================================
    // 交接操作失败的原因句（2026-10-06，审查 C1）
    //
    // 三个端点（`gcs_server/handlers/ops.go` 的 `Accept`/`Reject`/`Cancel`）的错误集合
    // 是 **400/403/404/409/500 五类**，而调用点原先一律报「操作未送达服务端」——
    // 那句话**只在 `status === 0` 时成立**。本组钉的就是这条分界。
    //=========================================================================

    /// ‼️ 本组的核心格：**除了 `status === 0`，任何状态码都不许说"未送达"**。
    /// 遍历的正是"服务端已答复"这一整类：403（权限）/409（竞态）/500（故障）会**带 error**，
    /// 500/502 也可能不带（反代吐 HTML ⇒ `_send` 的 `JSON.parse` 失败 ⇒ `data` 为 `null`）。
    /// 退化实现（恒返回「操作未送达服务端，请重试」）会让本格全红——这正是本次要防的形状。
    /// ⚠️ 为什么这不是"文案测试"：403 被说成"没送到"时，操作员会一直重试一个**权限**问题；
    ///    409 被说成"没送到"时，本该刷新却反复重试。两者该做的处置**相反**。
    function test_handoverActionErrorText_neverClaimsUndeliveredWhenServerReplied() {
        var replied = [
            { s: 400, d: { error: "无效交接 id" } },
            { s: 403, d: { error: "非降落机场操作员" } },
            { s: 409, d: { error: "交接已被处理或已超时" } },
            { s: 500, d: { error: "database is locked" } },
            { s: 502, d: null },
            { s: 500, d: null }
        ]
        for (var i = 0; i < replied.length; i++) {
            var t = OpsCommon.handoverActionErrorText(replied[i].s, replied[i].d)
            verify(t && t.indexOf("未送达") < 0,
                   "HTTP " + replied[i].s + " 是服务端**已答复**，不得报成「未送达」：实得「" + t + "」")
        }
    }

    /// 只有 `status === 0` 才说"未送达"——那是 `_send` 在 `_apiBase` 为空、
    /// 或请求根本没发出去时回调的码（见 `_send` 里那句 `onDone(0, null)`）。
    /// ⚠️ 与上一格是**两半**：只留上一格的话，一个恒返回状态码兜底的实现也能全绿，
    ///    而那会让"网线断了"和"权限不够"在操作员眼里长得一样。
    function test_handoverActionErrorText_zeroMeansNotDelivered() {
        var t = OpsCommon.handoverActionErrorText(0, null)
        verify(t.indexOf("未送达") >= 0, "status=0 是唯一该说「未送达」的一格，实得「" + t + "」")
    }

    /// 服务端给了 `error` ⇒ **逐字透出**，不再由前端改写。
    /// 为什么必须逐字：这几句（「非降落机场操作员」）本就是给人看的完整句子，
    /// 前端再译一层只会与后端漂移——后端每加一处分支，前端那张映射表就漏一处，**漏了不报错**。
    /// ⚠️ 判据用 403/409 的**具体文案**而非"非空"：用非空的话，把 `error` 前面拼一段
    ///    固定话术（或整个换成"操作失败"）也照样全绿。
    function test_handoverActionErrorText_passesServerReasonVerbatim() {
        compare(OpsCommon.handoverActionErrorText(403, { error: "非降落机场操作员" }),
                "非降落机场操作员")
        compare(OpsCommon.handoverActionErrorText(409, { error: "交接已被处理或已超时" }),
                "交接已被处理或已超时")
    }

    /// ‼️ **5xx 不得透出服务端原文**（2026-10-06 审查 §1①）。
    ///
    /// 为什么必须单列一格：上面那格只断言"不说未送达"，于是把 `database is locked`
    /// **原样渲染进交接弹框照样全绿**——而那正是本仓三个端点 500 出口的形态
    /// （`ops.go` 的 `Accept`/`Reject`/`Cancel` 共 10 处裸 `err.Error()`）。
    /// 操作员读到的是英文库内部措辞，而调用点还会在它后面拼一句「；仍失败请通知对方人工处理」
    /// ——**处置说反了**：那是本地瞬时锁争用，正确动作是过几秒**自己重试**，不是去找人。
    ///
    /// ⚠️ 与 `..._passesServerReasonVerbatim` 是**互补的两半**，缺一不可：
    ///    只留本格 ⇒ 一个"4xx 也收敛成固定话术"的实现会漏网（那会丢掉「非降落机场操作员」
    ///    这类**可行动**的原因）；只留那格 ⇒ 本条泄漏漏网。两格一起才钉住"**分档**透出"。
    /// ⚠️ 判据取"不含原文"而**不是**"等于某句固定话术"：本格管的是**不泄漏**，不是**措辞**
    ///    ——将来改文案不该让本格变红。
    function test_handoverActionErrorText_doesNotLeakRawServerErrorOn5xx() {
        var raw = [
            "database is locked",
            "no such table: table_task_operation_history",
            "sql: database is closed",
            "UNIQUE constraint failed: table_task_handover.task_id"
        ]
        for (var i = 0; i < raw.length; i++) {
            var t = OpsCommon.handoverActionErrorText(500, { error: raw[i] })
            verify(t.indexOf(raw[i]) < 0,
                   "5xx 的 error 是给机器看的原文，不得透给操作员：实得「" + t + "」")
            verify(t && t.length > 0, "收敛之后仍要给一句话，不能返回空串")
        }
        // 整个 5xx 档，不只看 500：网关侧 502/503/504 的正文也可能被 `JSON.parse` 成对象。
        verify(OpsCommon.handoverActionErrorText(503, { error: "upstream connect error" })
                   .indexOf("upstream connect error") < 0,
               "5xx 整档都收敛，只挡 500 不够")
    }

    /// ‼️ 服务端答复了却**没带** `error` ⇒ 给状态码，**不许替它猜原因**。
    /// 这条路径真实存在：反代 502/504 吐 HTML ⇒ `JSON.parse` 失败 ⇒ `data` 为 `null`。
    /// ⚠️ 顺带钉住 `data` 不是对象时不得抛：`data.error` 在字符串上求值是 `undefined`，
    ///    落在同一兜底（实际 `_send` 只给对象或 `null`，这两格是防御性的）。
    function test_handoverActionErrorText_fallsBackToStatusCode() {
        var t = OpsCommon.handoverActionErrorText(502, null)
        verify(t.indexOf("502") >= 0, "无 error 时至少要说明是哪个状态码，实得「" + t + "」")
        verify(OpsCommon.handoverActionErrorText(502, "HTML").indexOf("502") >= 0,
               "data 非对象（如解析失败留下的原串）不得抛错，且走同一兜底")
        verify(OpsCommon.handoverActionErrorText(502, {}).indexOf("502") >= 0,
               "data 是空对象（无 error 键）同样走兜底")
    }
}
