import QtQuick

import QGroundControl

import "OpsCommon.js" as OpsCommon

/// @brief 回航航线**构造**（2026-11-07，设计稿 §6.2/§6.3）。
///
/// 输入是后端 `GET /api/tasks/:id/return-candidates` 的响应 + 用户选中那一行的 `seq`；
/// 输出交给 `OpsMissionUpload` 的 `items` 是一条**倒序**的 mission：
/// `[最后一个已飞点, …, 选中点]`。
/// ‼️ **不插「飞机当前位置」占位项**——2026-11-07 SITL 实测证明它会让固定翼永久绕圈。
///    那段理由随逐点插入一起搬到了 `OpsMissionUpload.qml`（它才是真的插点的人）。
///
/// ‼️ 上传与模式切换在 `OpsMissionUpload`（2026-11-09 抽出，备降复用同一段）。
///    本文件只留「读候选 → 过闸 → 切片 → 组装高度」。
///
/// ‼️ 本组件**只构造**，不写数据库。写库由 `OpsReturnFlow` 先做
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
    // 输出（都由上传段持有）
    //-------------------------------------------------------------------------
    property alias busy: _upload.busy
    property alias statusText: _upload.statusText

    /// `stage` ∈ {"upload", "mode"}：区分「航线没上去」与「航线上了但模式没切」——
    /// 后者允许用户只重试切模式（现场链路恢复后），不必重新选点。
    signal succeeded()
    signal failed(string message, string stage)

    OpsMissionUpload {
        id: _upload
        vehicle: root.vehicle
        uploadingText: qsTr("正在上传回航航线…")
        timeoutText: qsTr("回航航线上传超时，请检查现场链路后重试")
        disconnectedText: qsTr("与飞机的连接已断开，回航航线未能确认；请重新连接后重试")
        invalidItemsText: qsTr("回航航线构造失败，未发送任何指令")
        noModeText: qsTr("当前固件没有航线模式名，无法切换模式；请手动检查飞控状态")
        modeFailText: qsTr("新航线已上传，但未能切到航线模式；请手动检查飞控状态")
        successText: qsTr("回航航线已上传")
        modeSuccessText: qsTr("回航航线已上传并切换到航线模式")
        onSucceeded: root.succeeded()
        onFailed: function (message, stage) { root.failed(message, stage) }
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
        //    2026-11-07 的 SITL 实测证伪（见 `OpsMissionUpload._build()`）。回航航线完全由
        //    候选航点算出，不读当前位置；留着这两道闸只会在链路抖动时拒绝一条本来能上传的航线。
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
    // 构造
    //-------------------------------------------------------------------------
    function _build() {
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

        _upload.start(items)
    }

    /// 构造侧的失败出口（`_prepare` / `_build` 用）。上传段的失败走 `_upload` 自己的出口，
    /// 两者最终都汇到本组件的 `failed()`。
    function _fail(msg, stage) {
        busy = false
        statusText = msg
        failed(msg, stage)
    }
}
