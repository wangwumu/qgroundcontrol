import QtQuick
import QtPositioning

import QGroundControl

import "OpsCommon.js" as OpsCommon

/// @brief 「把一组航点上传成 mission 并切到航线模式」的公共段（2026-11-09 从
///        `OpsReturnRoute.qml` 抽出，供回航与备降共用）。
///
/// 输入是一份已经算好的 `items`（`[{command, lat, lon, alt}]`，AMSL、末项已按降落点组装），
/// 输出是一条 mission + 一次模式切换。**本组件不构造航线、不写数据库**——
/// 构造侧（`OpsReturnRoute` / `OpsDivertRoute`）负责所有 fail-closed 闸与航点切片。
///
/// ‼️ **独立** `PlanMasterController`：不复用 `OpsRouteSync` 的实例。后者承载原航线的
///    `_state` / `syncInProgress` / 轮询；覆盖会打乱原航线的状态机，而原航线在写库成功后
///    仍需被 reset。每个上传组件各持一个，互不干扰。
///
/// 调用方按需覆写文案属性（`uploadingText` 等）：本组件不知道自己是"回航"还是"备降"。
Item {
    id: root

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    /// 目标无人机（`Vehicle*`）。
    property var vehicle: null

    // 文案（调用方逐字覆写；默认值只作兜底，别指望它们出现在界面上）
    property string uploadingText: qsTr("正在上传航线…")
    property string timeoutText: qsTr("航线上传超时，请检查现场链路后重试")
    property string disconnectedText: qsTr("与飞机的连接已断开，航线未能确认；请重新连接后重试")
    /// `items` 为空时用。空是**构造侧**的问题（`routeMissionItems` fail-closed），
    /// 本组件只负责把这句可读的失败交回去，不在这里猜原因。
    property string invalidItemsText: qsTr("航线构造失败，未发送任何指令")
    property string noModeText: qsTr("当前固件没有航线模式名，无法切换模式；请手动检查飞控状态")
    property string modeFailText: qsTr("新航线已上传，但未能切到航线模式；请手动检查飞控状态")
    property string successText: qsTr("航线已上传")
    property string modeSuccessText: qsTr("航线已上传并切换到航线模式")

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

    /// 上传一份 items。调用方保证 `items` 已过自己的全部构造闸。
    function start(items) {
        if (!vehicle) { _fail(disconnectedText, "upload"); return }
        if (!items || !items.length) { _fail(invalidItemsText, "upload"); return }
        _build(items)
    }

    //-------------------------------------------------------------------------
    // 上传
    //-------------------------------------------------------------------------
    function _build(items) {
        // ‼️ 重试时上一轮的轮询可能还在跑（用户在上传中途点「重试上传」）。
        //    不先停掉，它下一次 tick 会按**旧**的 `_plan.syncInProgress` 判定完成并切模式，
        //    与新一次上传交错 —— 表现为偶发「上传好了但飞机没动」。
        _sendPoll.stop()

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
        //    ⇒ 直接以调用方给的第一项开头。若首项恰在身后（刚飞过的来路点），PX4 会做
        //      一次 U 型转弯再接受；只有「目标 == 当前点」才会永久相切绕圈。
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
        statusText = uploadingText
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
                stop()
                root._fail(root.timeoutText, "upload")
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
        //    不判空会抛 TypeError，`failed()` 不发、`busy` 卡 true，调用方的重试框也不会出现。
        if (!vehicle) {
            _fail(disconnectedText, "upload")
            return
        }
        // 非 PX4 固件下 `missionFlightMode` 可能为空串（`RomView.qml` 的模式切换处记着这个坑）。
        // 空串切模式必然静默失败，先拦下来。
        if (!vehicle.missionFlightMode) {
            _fail(noModeText, "mode")
            return
        }
        // 已在 missionFlightMode ⇒ 上传即载入，**不再切模式**
        //（同模式下发可能 ACK=0 却不做任何事）。
        if (vehicle.flightMode === vehicle.missionFlightMode) {
            busy = false
            statusText = successText
            succeeded()
            return
        }
        if (!vehicle.setFlightModeChecked(vehicle.missionFlightMode)) {
            _fail(modeFailText, "mode")
            return
        }
        busy = false
        statusText = modeSuccessText
        succeeded()
    }

    function _fail(msg, stage) {
        busy = false
        statusText = msg
        failed(msg, stage)
    }
}
