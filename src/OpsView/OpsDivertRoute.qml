import QtQuick

import QGroundControl

import "OpsCommon.js" as OpsCommon

/// @brief 备降航线**构造**（2026-11-09，《备降选点-设计稿》§7）。
///
/// 输入是后端 `GET /api/tasks/:id/divert-candidates` 的响应 + 用户选中那一行的 `seq`；
/// 交给 `OpsMissionUpload` 的 `items` 按候选类别有两种形状：
///   · 本航线候选 ⇒ `OpsCommon.divertMissionWaypoints` 给出「沿途航点 → 目标」的切片
///     （目标已在身后时是倒序的来路点）；
///   · 名册 / 其它航线候选，或飞机已偏离本航线 ⇒ 直达目标单点。
///
/// ‼️ 与回航共用 `OpsMissionUpload`（上传 + 切模式），本文档只管「读候选 → 过闸 → 组装」。
/// ‼️ **不插「飞机当前位置」占位项**——理由见 `OpsMissionUpload._build()`（SITL 实测裁定）。
/// ‼️ 本组件**只构造**，不写数据库：写库由 `OpsDivertFlow` 先做（先库后指令）。
Item {
    id: root

    //-------------------------------------------------------------------------
    // 输入
    //-------------------------------------------------------------------------
    /// 目标无人机（`Vehicle*`）。
    property var vehicle: null
    /// 任务对象（overview 里的一项）。只读 `cruise_alt_agl`。
    property var task: null
    /// `GET /divert-candidates` 的完整响应（含 `own_route` / `candidates` / `departed`）。
    property var candidate: null
    /// 用户选中那一行的 `seq`（后端数组下标，唯一键）。
    property int targetSeq: -1

    //-------------------------------------------------------------------------
    // 输出（busy / statusText 都由上传段持有）
    //-------------------------------------------------------------------------
    property alias busy: _upload.busy
    property alias statusText: _upload.statusText

    /// `stage` ∈ {"upload", "mode"}：区分「航线没上去」与「航线上了但模式没切」。
    signal succeeded()
    signal failed(string message, string stage)

    /// 本轮 `_build()` 是否走了「原航线切片不可用 ⇒ 直达目标」的退化路径。
    /// 只在 `statusText` 里留痕；下次 `_build()` 开头清掉。
    property bool _degraded: false

    OpsMissionUpload {
        id: _upload
        vehicle: root.vehicle
        uploadingText: qsTr("正在上传备降航线…")
        timeoutText: qsTr("备降航线上传超时，请检查现场链路后重试")
        disconnectedText: qsTr("与飞机的连接已断开，备降航线未能确认；请重新连接后重试")
        invalidItemsText: qsTr("备降航线构造失败，未发送任何指令")
        noModeText: qsTr("当前固件没有航线模式名，无法切换模式；请手动检查飞控状态")
        modeFailText: qsTr("备降航线已上传，但未能切到航线模式；请手动检查飞控状态")
        successText: qsTr("备降航线已上传")
        modeSuccessText: qsTr("备降航线已上传并切换到航线模式")
        // ‼️ 降级提示必须在**成功之后**补写：`start()` 内部会把 `statusText` 覆成
        //    `uploadingText` / 成功文案，_build 里提前写会被冲掉。
        onSucceeded: {
            if (root._degraded)
                root.statusText = qsTr("原航线含特殊航段，已改为直达目标") + "；" + root.statusText
            root.succeeded()
        }
        onFailed: function (message, stage) { root.failed(message, stage) }
    }

    /// 由 `OpsDivertFlow` 在**写库成功之后**调用：构造并上传。
    function start() {
        if (!_prepare()) return
        _build()
    }

    /// 上传失败后的重试：**只重传**，不再 POST /divert（后端已记录，重复提交会再写一条流水）。
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
        // 候选与选中项必须先有：没有它们 `_build()` 会在读候选字段时抛 TypeError
        //（QML 里表现为控件静默不工作，而不是弹框）。
        if (!candidate || !candidate.candidates || !_targetItem()) {
            _fail(qsTr("备降候选数据缺失，请重新选点"), "upload"); return false
        }
        // 航线降落高度（AGL）必须是有限数。`Math.max(NaN, x)` 仍是 NaN，
        // `applyLandingAltitude` 会静默返回原 items ⇒ 末项贴在航点原海拔飞。
        if (typeof candidate.landing_alt_agl_m !== "number"
                || !isFinite(candidate.landing_alt_agl_m)
                || candidate.landing_alt_agl_m < 0) {
            _fail(qsTr("航线未设定有效的降落高度，无法构造备降航线"), "upload"); return false
        }
        // ① 本架次飞行高度（AGL）。与 OpsRouteSync / OpsReturnRoute 同一条单点判据。
        if (!OpsCommon.nrrsmUsableAGL(task.cruise_alt_agl)) {
            _fail(qsTr("本架次未设定有效的飞行高度，无法构造备降航线"), "upload"); return false
        }
        // ② home 必须有效：MissionController 的打包依赖它。
        if (!vehicle.homePosition || !vehicle.homePosition.isValid) {
            _fail(qsTr("飞机 home 位置无效，无法构造备降航线"), "upload"); return false
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
        // ⑤ 飞机当前位置 / 海拔：**不设闸**。同回航——本航线完全由候选算得，
        //    留着这两道闸只会在链路抖动时拒绝一条本来能上传的航线。
        return true
    }

    //-------------------------------------------------------------------------
    // 候选响应里目标行的三个量
    //-------------------------------------------------------------------------
    property real _targetGroundMSL: _targetItem() ? _targetItem().site_ground_msl_m : NaN
    property real _targetClearAGL: _targetItem() ? _targetItem().site_clear_alt_agl_m : NaN

    function _targetItem() {
        if (!candidate || !candidate.candidates) return null
        for (var i = 0; i < candidate.candidates.length; i++) {
            if (candidate.candidates[i].seq === targetSeq)
                return candidate.candidates[i]
        }
        return null
    }

    //-------------------------------------------------------------------------
    // 构造
    //-------------------------------------------------------------------------
    function _build() {
        _degraded = false
        var wps = OpsCommon.divertMissionWaypoints(candidate, targetSeq)
        if (!wps.length) {
            _fail(qsTr("备降候选数据不可用，无法构造备降航线"), "upload"); return
        }
        // ‼️ `endWaypointId` 传 `undefined`：备降航线的末项**就是**目标，
        //    不能按原航线的 `end_waypoint_id` 去指认终点（它指到的往往不在本次切片里）。
        var items = OpsCommon.routeMissionItems(wps, vehicle.vtol === true,
                                                undefined, task.cruise_alt_agl)
        if (!items.length) {
            // 退化：原航线含特殊航段时 `routeMissionItems` fail-closed 返回空数组。
            // 备降进行中不能因此卡住 ⇒ 直达目标单点（末项高度随后由 applyLandingAltitude 覆盖）。
            //
            // ‼️ 退化分支**必须自己再校验一次坐标**：`routeMissionItems` 回空的一大原因
            //    恰恰是目标坐标无效（`isValidWaypoint` 判任一轴为 0 / 非有限即无效）。
            //    不校验就直接拿它造单点，会下发一个 (0,0) 航点——而
            //    `QtPositioning.coordinate(0,0).isValid` 为**真**，上传会成功，
            //    表现为「界面报已改为直达目标，飞机被指令飞向几内亚湾」
            //    （2026-11-09 二次复核 Critical；后端已同口径过滤，这是第二道）。
            var t = _targetItem()
            if (!OpsCommon.isValidWaypoint(t.lat, t.lon)) {
                _fail(qsTr("目标站点坐标无效，无法构造备降航线"), "upload"); return
            }
            items = [ { lat: t.lat, lon: t.lon,
                        alt: 0, command: OpsCommon.MAV_CMD_NAV_WAYPOINT } ]
            _degraded = true
        }
        // 末项 = 目标站点航点。高度 = 地面海拔 + max(航线降落 AGL, 站点最低安全 AGL)。
        var landingAGL = Math.max(candidate.landing_alt_agl_m, _targetClearAGL)
        items = OpsCommon.applyLandingAltitude(items,
                    OpsCommon.assembledAltitude(_targetGroundMSL, landingAGL))
        if (!isFinite(items[items.length - 1].alt)) {
            _fail(qsTr("目标站点降落高度组装失败，无法构造备降航线"), "upload"); return
        }
        _upload.start(items)
    }

    /// 构造侧的失败出口（`_prepare` / `_build` 用）。上传段的失败走 `_upload` 自己的出口。
    function _fail(msg, stage) {
        busy = false
        statusText = msg
        failed(msg, stage)
    }
}
