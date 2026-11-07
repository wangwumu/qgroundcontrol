import QtQuick
import QtPositioning

import QGroundControl

import "OpsCommon.js" as OpsCommon

/// @brief 回航航线构造与上传（2026-11-07，设计稿 §6.2/§6.3）。
///
/// 输入是后端 `GET /api/tasks/:id/return-candidates` 的响应 + 用户选中那一行的 `seq`；
/// 输出是一条**倒序**的 mission：`[最后一个已飞点, …, 选中点]`。
/// ‼️ **不插「飞机当前位置」占位项**——2026-11-07 SITL 实测证明它会让固定翼永久绕圈，
///    理由见 `_build()` 里那段注释。
///
/// ‼️ **独立** `PlanMasterController`：不复用 `OpsRouteSync` 的实例。后者承载原航线的
///    `_state` / `syncInProgress` / 轮询；覆盖会打乱原航线的状态机，而原航线在回航
///    写库成功后仍需被 reset。
///
/// ‼️ 本组件**只发 mission、只切模式**，不写数据库。写库由 `OpsReturnFlow` 先做
///    （用户 2026-09-23 工程指令：先库后指令），失败则**根本不会调用** `start()`。
Item {
    id: root

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    /// 目标无人机（`Vehicle*`）。
    property var vehicle: null
    /// 任务对象（overview 里的一项）。只读 `cruise_alt_agl`。
    property var task: null
    /// `GET /return-candidates` 的完整响应。
    property var candidate: null
    /// 用户选中那一行的 `seq`（后端数组下标，唯一键）。
    /// ‼️ 不用 `waypoint_id`：同一航点可被航线引用两次（后端不去重）。
    property int targetSeq: -1

    //-------------------------------------------------------------------------
    // 输出
    //-------------------------------------------------------------------------
    property bool busy: false
    property string statusText: ""

    /// `stage` ∈ {"upload", "mode"}：区分「航线没上去」与「航线上了但模式没切」——
    /// 后者允许用户只重试切模式（现场链路恢复后），不必重新选点。
    signal succeeded()
    signal failed(string message, string stage)

    //-------------------------------------------------------------------------
    // 独立控制器
    //-------------------------------------------------------------------------
    /// ⚠️ 与 `OpsRouteSync` 同一取向：`flyView: true` 走 Fly 支——已登录后台时
    ///    `_autoLoadPlanFromManagerVehicle()` 被登录闸挡住，不会把飞机上的旧航线
    ///    载入并覆盖我们刚构造的这份。
    PlanMasterController {
        id: _plan
        flyView: true
    }

    /// 由 `OpsReturnFlow` 在**写库成功之后**调用：构造并上传。
    function start() {
        if (!_prepare()) return
        _build()
    }

    /// 上传失败后的重试：**只重传**，不再 POST /return（后端已记录，重复提交会再写一条流水）。
    /// 闸全部重跑：两次点击之间飞机可能断链、home 可能失效。
    function retryUpload() {
        if (!_prepare()) return
        _build()
    }

    //-------------------------------------------------------------------------
    // 闸（fail-closed：任何一道不过 ⇒ 一个字节都不发，文案指明是哪一道）
    //-------------------------------------------------------------------------
    function _prepare() {
        if (!vehicle) { _fail(qsTr("未找到该任务无人机的连接"), "upload"); return false }
        if (!task) { _fail(qsTr("任务数据缺失"), "upload"); return false }
        // 候选与选中项必须先有：没有它们 `_build()` 会在读 `candidate.waypoints` 时抛
        // TypeError（QML 里表现为控件静默不工作，而不是弹框）。
        if (!candidate || !candidate.waypoints || targetSeq < 0) {
            _fail(qsTr("回航候选数据缺失，请重新选点"), "upload"); return false
        }
        // 航线降落高度（AGL）必须是有限数。`Math.max(NaN, x)` 仍是 NaN，
        // `applyLandingAltitude` 会静默返回原 items ⇒ 末项贴在航点原海拔飞。
        if (typeof candidate.landing_alt_agl_m !== "number"
                || !isFinite(candidate.landing_alt_agl_m)
                || candidate.landing_alt_agl_m < 0) {
            _fail(qsTr("航线未设定有效的降落高度，无法构造回航航线"), "upload"); return false
        }
        // ① 本架次飞行高度（AGL）。复用 OpsRouteSync 的同一条单点判据。
        if (!OpsCommon.nrrsmUsableAGL(task.cruise_alt_agl)) {
            _fail(qsTr("本架次未设定有效的飞行高度，无法构造回航航线"), "upload"); return false
        }
        // ② home 必须有效：MissionController 的打包依赖它。
        if (!vehicle.homePosition || !vehicle.homePosition.isValid) {
            _fail(qsTr("飞机 home 位置无效，无法构造回航航线"), "upload"); return false
        }
        // ③ 目标站点最低安全高度（AGL 项）。
        if (!OpsCommon.nrrsmUsableAGL(_targetClearAGL)) {
            _fail(qsTr("目标站点未设定有效的降落安全高度"), "upload"); return false
        }
        // ④ 目标站点地面海拔（AMSL 项）。缺了它 applyLandingAltitude 会静默跳过，
        //    末项停在该航点原海拔（≈贴地），飞机被指令贴地飞向站点。
        if (!OpsCommon.nrrsmFiniteGroundMSL(_targetGroundMSL)) {
            _fail(qsTr("目标站点地面海拔无效"), "upload"); return false
        }
        // ⑤ 飞机当前位置 / 海拔：**不再设闸**。它们原本只服务于「占位项」，而占位项已被
        //    2026-11-07 的 SITL 实测证伪（见 `_build()`）。回航航线完全由候选航点算出，
        //    不读当前位置；留着这两道闸只会在链路抖动时拒绝一条本来能上传的航线。
        return true
    }

    //-------------------------------------------------------------------------
    // 候选响应里目标站点的三个量：必须读**选中那一行**的值
    //-------------------------------------------------------------------------
    property real _targetGroundMSL: _targetItem() ? _targetItem().site_ground_msl_m : NaN
    property real _targetClearAGL: _targetItem() ? _targetItem().site_clear_alt_agl_m : NaN

    function _targetItem() {
        if (!candidate || !candidate.waypoints) return null
        for (var i = 0; i < candidate.waypoints.length; i++) {
            if (candidate.waypoints[i].seq === targetSeq)
                return candidate.waypoints[i]
        }
        return null
    }

    //-------------------------------------------------------------------------
    // 构造与上传
    //-------------------------------------------------------------------------
    function _build() {
        // ‼️ 重试时上一轮的轮询可能还在跑（用户在上传中途点「重试上传」）。
        //    不先停掉，它下一次 tick 会按**旧**的 `_plan.syncInProgress` 判定完成并切模式，
        //    与新一次上传交错 —— 表现为偶发「上传好了但飞机没动」。
        _sendPoll.stop()

        var rev = OpsCommon.returnRouteWaypoints(candidate.waypoints, targetSeq)
        if (!rev.length) {
            _fail(qsTr("航线含特殊航段或数据不可用，无法构造回航航线"), "upload")
            return
        }
        // ‼️ `endWaypointId` 传 `undefined`：回航航线的末项**就是**选中点，
        //    不能按原航线的 `end_waypoint_id` 去指认终点（它指到的往往不在本次切片里）。
        var items = OpsCommon.routeMissionItems(rev, vehicle.vtol === true, undefined, task.cruise_alt_agl)
        if (!items.length) {
            _fail(qsTr("航线含特殊航段或数据不可用，无法构造回航航线"), "upload")
            return
        }

        // 末项 = 目标站点航点（`returnRouteWaypoints` 保证）。高度 = 地面海拔 +
        // max(航线降落 AGL, 站点最低安全 AGL)。
        var landingAGL = Math.max(candidate.landing_alt_agl_m, _targetClearAGL)
        items = OpsCommon.applyLandingAltitude(items,
                    OpsCommon.assembledAltitude(_targetGroundMSL, landingAGL))
        if (!isFinite(items[items.length - 1].alt)) {
            _fail(qsTr("目标站点降落高度组装失败，无法构造回航航线"), "upload")
            return
        }

        _plan.startStaticActiveVehicle(vehicle, false)
        // ‼️ 顺序不可交换：`removeAll()` 走 `_setupNewVisualItems()`，会丢弃旧 settings item
        //    并新建一个坐标缺省的 —— 先写 home 会被它抹掉，而 `MissionController.start()`
        //    每次都会 `_addMissionSettings()`，所以**第二次构建起** `containsItems` 必为真。
        //    （参考实现 `OpsRouteSync.qml` 也是先 removeAll 再 setHomePosition。）
        if (_plan.containsItems) _plan.removeAll()
        _plan.missionController.setHomePosition(vehicle.homePosition)

        // ‼️ **不插「飞机当前位置」占位项**（2026-11-07 SITL 实测裁定，偏离设计稿 §6.2 第 4 步）。
        //
        //    设计稿原要求首项 =
        //      `insertSimpleMissionItem(vehicle.coordinate, -1)`、高度 = 当前 AMSL，
        //    理由是「PX4 删掉 HOME 后首项不能是空位」。这个理由不成立，且会致命：
        //
        //    · 实测（SITL `13_44_46.ulg` + PX4 `rootfs/dataman` 直接解析）：PX4 收下的
        //      mission 恰是 `[占位(40.1402559,117.1105065) cmd16, 目标(平谷)]`，count=2。
        //    · 固定翼转弯半径 ~200 m。**这个占位点就是飞机在上传那一刻的位置**——上传有
        //      RTT（实测上传期间飞机已飞出 100+ m），指令生效时它必然落在转弯圆内。
        //    · PX4 对落在转弯半径内的目标只能绕它飞圈：`mission_result seq=0/2` 恒定
        //      159 帧从不推进、`vehicle_global_position` 以该点为圆心 200 m 绕了 480 s。
        //      ⇒ 用户看到的「原地盘旋」就是这个，**不是**发了 LOITER
        //         （心跳 custom_mode 全程 0x04040000 = AUTO_MISSION，nav_state 3）。
        //
        //    结论：「当前位置」永远不能当 mission 首项——那不是偶发时序，是几何必然。
        //    同类教训见降落航线（`P0 = 飞机当前位置` 同样错）。
        //    ⇒ 直接以倒序航点开头。若首项恰在身后（刚飞过的来路点），PX4 会做一次
        //      U 型转弯再接受；只有「目标 == 当前点」才会永久相切绕圈。
        //
        //    逐点追加。‼️ 顺序不可交换：先 command 再 altitude——
        // `_setDefaultsForCommand` 会把 altitudeFrame 重置为 Relative。
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            var vi = _plan.missionController.insertSimpleMissionItem(
                QtPositioning.coordinate(it.lat, it.lon), -1)
            if (vi && it.command !== OpsCommon.MAV_CMD_NAV_WAYPOINT) vi.command = it.command
            _applyAltitude(vi, it.alt)
        }

        busy = true
        statusText = qsTr("正在上传回航航线…")
        _plan.sendToVehicle()
        _waitForSendComplete()
    }

    /// 把高度与**参考系**一起写进一个 mission item。
    /// `altitudeFrame` 必须显式设：`insertSimpleMissionItem()` 缺省留下的是
    /// `AltitudeFrameRelative` ⇒ AMSL 值会被当成"离地高度"。
    /// 高度写 `rawValue`（米）而不是 `value`（用户单位，可能是英尺）。
    function _applyAltitude(vi, amsl) {
        if (!vi) return
        vi.altitudeFrame = QGroundControl.AltitudeFrameAbsolute // AMSL
        vi.altitude.rawValue = amsl
    }

    function _waitForSendComplete() {
        _sendPoll.ticks = 0
        _sendPoll.restart()
    }

    Timer {
        id: _sendPoll
        interval: 500
        repeat: true
        property int ticks: 0
        onTriggered: {
            ticks++
            if (ticks > 120) {
                stop(); root.busy = false
                root._fail(qsTr("回航航线上传超时，请检查现场链路后重试"), "upload")
                return
            }
            // `sendToVehicle()` 返回时 `syncInProgress` 可能还没置起来 ⇒ 头几个 tick 看到
            // false 不代表完成。`ticks < 2` 跳过头一秒，避开这个假完成。
            // 第二个条件 `!dirtyForUpload` 是**必需**的：`sendToVehicle` 的两条静默出口
            //（sharedLink 为空 / offline）根本不发，此时 syncInProgress 恒 false，
            // 只看它会在 1 秒后假 done。
            if (ticks < 2) return
            if (!_plan.syncInProgress && !_plan.dirtyForUpload) {
                stop()
                root._switchMode()
            }
        }
    }

    function _switchMode() {
        // ‼️ 上传轮询的几十秒里链路可能断开、`Vehicle` 被重建 ⇒ `vehicle` 变 null。
        //    不判空会抛 TypeError，`failed()` 不发、`busy` 卡 true，Flow 的重试框也不会出现。
        if (!vehicle) {
            _fail(qsTr("与飞机的连接已断开，回航航线未能确认；请重新连接后重试"), "upload")
            return
        }
        // 非 PX4 固件下 `missionFlightMode` 可能为空串（`RomView.qml` 的模式切换处记着这个坑）。
        // 空串切模式必然静默失败，先拦下来。
        if (!vehicle.missionFlightMode) {
            busy = false
            _fail(qsTr("当前固件没有航线模式名，无法切换模式；请手动检查飞控状态"), "mode")
            return
        }
        // 已在 missionFlightMode ⇒ 上传即载入，**不再切模式**
        //（同模式下发可能 ACK=0 却不做任何事）。
        if (vehicle.flightMode === vehicle.missionFlightMode) {
            busy = false
            statusText = qsTr("回航航线已上传")
            succeeded()
            return
        }
        if (!vehicle.setFlightModeChecked(vehicle.missionFlightMode)) {
            busy = false
            _fail(qsTr("新航线已上传，但未能切到航线模式；请手动检查飞控状态"), "mode")
            return
        }
        busy = false
        statusText = qsTr("回航航线已上传并切换到航线模式")
        succeeded()
    }

    function _fail(msg, stage) {
        busy = false
        statusText = msg
        failed(msg, stage)
    }
}
