import QtQuick
import QtQuick.Controls // Popup.NoAutoClose
import QtQuick.Layouts

import QGroundControl.Controls // ScreenTools.uiTextScaleFactor

import "."

/// 回航流程（2026-11-07）：查候选 → 选点 → 二次确认 → POST /return → 构造上传。
///
/// 2026-11-24 增补 `beginHome()`：**回本场不选点**（站点视图的唯一入口）。
/// 两条路的差别只有三处：不弹选点框、`POST /return` 不带 `landing_site_id`、
/// 写库后后端会预派原机位并补签入(LANDING)（设计稿《回航回本场》§3.1 A 支）。
///
/// ‼️ 顺序是硬的：**先写库、再下指令**（用户 2026-09-23 工程指令）。写库失败 ⇒
///    不构造、不上传；上传失败 ⇒ 保留候选与选中项，重试时**只重传**（后端已记录）。
Item {
    id: root

    /// `OpsShell`（骨架）：HTTP 与轮询都走它，不另造封装。
    property var shell: null
    /// 取飞机：`OpsView` / `RomView` 各有自己的 `_vehicleForTask`，由视图注入，
    /// Flow 不复制匹配逻辑。
    property var vehicleFn: null
    /// 回航成功后清理原航线：`OpsView` 注入 `_routeSyncs[id].reset()`；
    /// `RomView` 不持有同步器，传 null。
    property var routeResetFn: null

    property var _task: null
    property var _candidates: null
    /// 选中那一行的 `seq`（唯一键）。‼️ 不是 `waypoint_id`：同一航点可被航线引用两次。
    property int _selectedSeq: -1
    /// 选中行的航点 id，只用于提示/排查，不参与定位。
    property int _selectedWaypointId: -1
    /// 选中航点对应的**站点** id —— POST /return 的 `landing_site_id` 取它。
    /// ‼️ 不是 `waypoint_id`：`/return` 写的是 `table_flight_task.landing_site_id`，
    ///    后端拿它跑 `siteUseReady` 与管辖判定；传航点 id 会命中另一个站点（或 0）。
    property int _selectedSiteId: -1
    /// 「回本场」标志：`true` 时 `POST /return` **不带** `landing_site_id`（缺省即回本场），
    /// 从而也不吃 `siteUseReady` 那道闸——回本场是安全动作，不该因为"本站此刻没有空闲机位"
    /// 被 409 挡在门外。落点由后端按 A 支预派给原机位。
    property bool _homeMode: false
    property real _aircraftLat: NaN
    property real _aircraftLon: NaN
    property string _busyStage: "" // "" | "query" | "write" | "upload" | "mode"
    /// 流程代号。看门狗超时后 `_busyStage` 被清空 ⇒ 用户可再点【回航】发起新一轮，
    /// 而**上一轮的网络回调仍可能到达**（XHR 不会因为没人等它就中止）。回调进门先比
    /// 代号：不是本人就原地返回，绝不碰 `_watchdog`（那是新一轮的）。
    property int _gen: 0

    signal message(string title, string text)

    function begin(task) {
        if (!task) return
        if (!shell) {
            message(qsTr("无法选择回航点"), qsTr("后台连接未就绪。数据库与飞机均未做任何改动。"))
            return
        }
        // 重复点击（设计稿 §7「弹窗与执行期间禁用按钮」）：上一轮还在查询/写库/上传时
        // 再点一次直接忽略。否则会并发两个 POST /return——后一个可能把监控员刚 Propose
        // 的那条交接一并作废（`closeReturnLoopTx` 取消所有 PENDING）。
        if (_busyStage !== "") return
        _homeMode = false
        _task = task
        _selectedSeq = -1
        _selectedWaypointId = -1
        _selectedSiteId = -1
        _candidates = null
        var v = vehicleFn ? vehicleFn(task) : null
        if (!v || !v.coordinate || !v.coordinate.isValid) {
            message(qsTr("无法选择回航点"), qsTr("未收到飞机位置。数据库与飞机均未做任何改动。"))
            return
        }
        // 记下本次查询使用的坐标：写库时回传同一组值，保证「已飞距离」与落库位置一致。
        _aircraftLat = v.coordinate.latitude
        _aircraftLon = v.coordinate.longitude
        _queryCandidates(task, function (data) {
            _candidates = data
            _dialog.open()
        })
    }

    /// **回本场**（2026-11-24，站点视图唯一入口）：不选点、不选机位。
    ///
    /// 为什么仍要查候选：倒序航线的几何与高度全部来自响应里的 `waypoints`
    /// （目标航点的地面海拔、站点最低安全高度、航线降落 AGL），**没有它构造不出航线**。
    /// 只是这次不把列表摆给用户看——落点由后端按「回本场」补齐（预派原机位 + 补签 LANDING）。
    ///
    /// 起飞机场航点找不到时**不猜**：退回选点框，让操作员自己指（猜错就是一条飞向错误站点的航线）。
    function beginHome(task) {
        if (!task) return
        if (!shell) {
            message(qsTr("无法回航"), qsTr("后台连接未就绪。数据库与飞机均未做任何改动。"))
            return
        }
        if (_busyStage !== "") return
        _homeMode = true
        _task = task
        _selectedSeq = -1
        _selectedWaypointId = -1
        _selectedSiteId = -1
        _candidates = null
        var v = vehicleFn ? vehicleFn(task) : null
        if (!v || !v.coordinate || !v.coordinate.isValid) {
            message(qsTr("无法回航"), qsTr("未收到飞机位置。数据库与飞机均未做任何改动。"))
            return
        }
        _aircraftLat = v.coordinate.latitude
        _aircraftLon = v.coordinate.longitude
        _queryCandidates(task, function (data) {
            _candidates = data
            var w = _homeWaypoint()
            if (!w) {
                // 明确告诉用户为什么退了回来，再摆出选点框（**不静默**、**不猜**）。
                message(qsTr("未能确定起飞机场航点"),
                        qsTr("请在列表里手动选择落点。数据库与飞机均未做任何改动。"))
                _homeMode = false
                _dialog.open()
                return
            }
            _selectedSeq = w.seq
            _selectedWaypointId = w.waypoint_id
            _selectedSiteId = w.site_id
            _execute()
        })
    }

    /// 查候选的公共前半段（`begin` / `beginHome` 共用）：忙碌闸、取飞机、取坐标、看门狗。
    /// `onData` 只在 200 且代号仍有效时调用。
    function _queryCandidates(task, onData) {
        _busyStage = "query"
        var gen = ++_gen
        _watchdog.restart()
        shell._get("/api/tasks/" + task.task_id + "/return-candidates?lat="
                   + _aircraftLat + "&lon=" + _aircraftLon,
                   function (status, data) {
                       if (gen !== _gen) return
                       _watchdog.stop()
                       _busyStage = ""
                       if (status !== 200) {
                           message(qsTr("无法获取回航点"),
                                   (data && data.error) || ("HTTP " + status))
                           return
                       }
                       onData(data)
                   })
    }

    /// 起飞机场在来路上的那个航点（判据与全部理由见 `OpsCommon.homeReturnWaypoint`，
    /// 那里是**唯一**实现、`tst_OpsCommon.qml` 有单测钉住）。
    /// 本函数只负责把两个**来源**拼上去：候选数组（`_queryCandidates` 的回调）与
    /// 制单场地（`_task.takeoff_site_id`）。
    /// 返回 `null` ⇒ 调用方**退回人工选点**（不静默、不猜）。
    function _homeWaypoint() {
        if (!_candidates) return null
        return OpsCommon.homeReturnWaypoint(_candidates.waypoints,
                                            _task ? _task.takeoff_site_id : 0)
    }

    function _confirm(seq) {
        var w = _findWaypoint(seq)
        // 纯函数/弹窗已保证只可能选 available 的点；这里再 fail-closed 一次：
        // 没有 site_id 就没有管辖权、没飞过就没有倒序几何，落库后会无人能收尾。
        if (!w || !(w.site_id > 0) || !w.flown || !w.landable) {
            message(qsTr("回航未生效"), qsTr("所选航点当前不可用，数据库未做任何改动。"))
            return
        }
        _selectedSeq = seq
        _selectedWaypointId = w.waypoint_id
        _selectedSiteId = w.site_id
        _homeMode = false   // 人工选点 ⇒ 按选点流程（带 landing_site_id）
        _dialog.close()
        var name = w.site_name || ("#" + w.site_id)
        // 2026-11-24：选中的若就是**起飞机场**，后端走 A 支（预派原机位 + 补降落指挥交接），
        // 与 07 稿「回航一律释放机位、到站再人工指派」不再一样 ⇒ 必须在**确认之前**说出来。
        // 判据与后端 `homeReturn` 同源：目的地场地 == 制单场地（`takeoff_site_id`）。
        // 文案只说**会发生什么**，不说"机位保留"——监控员这条路进来时 `current_slot_id`
        // 通常在签入航线时已被清空，本就没有可保留的东西。
        var homeNote = ""
        if (_task && Number(w.site_id) === Number(_task.takeoff_site_id))
            homeNote = qsTr("\n回本场：落点就是原机位，写库后自动预派并在本站签入降落指挥。")
        _confirmDialog.text = qsTr("目标：%1\n沿航线回退距离：%2")
                .arg(name).arg(_fmtM(w.distance_m)) + homeNote
        _confirmDialog.open()
    }

    function _execute() {
        _confirmDialog.close()
        if (_selectedSiteId <= 0) return
        _busyStage = "write"
        var gen = ++_gen
        _watchdog.restart()
        // 回本场**不带** `landing_site_id`：后端缺省把它补成 `task.site_id`，并据此走
        // 「保留机位 + 预派 + 补签 LANDING」那一支（设计稿 §3.1 A 支）。
        var body = { lat: _aircraftLat, lon: _aircraftLon }
        if (!_homeMode) body.landing_site_id = _selectedSiteId
        shell._post("/api/tasks/" + _task.task_id + "/return",
                    body,
                    function (status, data) {
                        if (gen !== _gen) return
                        _watchdog.stop()
                        if (status !== 200) {
                            _busyStage = ""
                            var errText = (data && data.error) || ("HTTP " + status)
                            message(qsTr("回航未生效"),
                                    errText + qsTr("\n数据库未做任何改动，飞机仍在原航线上。"))
                            // 409 = 「目标此刻不可用 / 飞机偏离过远 ⇒ 列表已过期」⇒ 重新拉候选，
                            // 不对旧列表重试（设计稿 §7）。403/404/500 不重拉：那不是列表过期，
                            // 重拉只会把同一个错误再弹一遍。
                            // ‼️ 重拉要**留在原来那条路上**：回本场崩溃时弹回选点框，等于让操作员
                            //    在应急时刻多做一次选择，而他要的落点从来没变过。
                            if (status === 409) {
                                _candidates = null
                                if (_homeMode) beginHome(_task)
                                else begin(_task)
                            }
                            return
                        }
                        // 库已改：立刻刷新卡片流向（出站→进站），无论上传成败。
                        shell._poll()
                        _upload()
                    })
    }

    function _upload() {
        _busyStage = "upload"
        // ‼️ `vehicle` 必须**每次现取**：`OpsReturnRoute._prepare()` 的第一道闸就是它。
        //    漏赋这一行，每次回航都会停在「未找到该任务无人机的连接」——
        //    而此时库已经改了、飞机还在原航线上，是最坏的一种半成功。
        _route.vehicle = vehicleFn ? vehicleFn(_task) : null
        _route.targetSeq = _selectedSeq
        _route.candidate = _candidates
        _route.task = _task
        _route.start()
    }

    /// 上传失败后只重传（后端已记录，重复 POST 会再写一条流水）。
    function retryUpload() {
        if (_busyStage !== "upload") return
        // ‼️ 重试前**重新取一次** vehicle：上传失败最常见的场景就是链路断了，而 QGC 的
        //    `Vehicle` 对象只在建链/重启时重建——飞机重连后旧引用已不在 `_vehicleForTask` 里，
        //    拿它重传会发到一条死链上。
        _route.vehicle = vehicleFn ? vehicleFn(_task) : null
        _route.retryUpload()
    }

    function _findWaypoint(seq) {
        if (!_candidates || !_candidates.waypoints) return null
        for (var i = 0; i < _candidates.waypoints.length; i++)
            if (_candidates.waypoints[i].seq === seq) return _candidates.waypoints[i]
        return null
    }

    function _fmtM(m) {
        if (!m && m !== 0) return "—"
        return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"
    }

    // 查询/写库的看门狗（15 s）。`OpsShell._send` 没有超时、QML XHR 本身也没有：
    // 服务端接受连接却不回包时，回调永不执行 ⇒ `_busyStage` 永远停在 query/write，
    // 后续【回航】全部被静默忽略、界面零提示。超时后**不自动重发**——写库可能已经在
    // 服务端生效，重发会再写一条流水。
    Timer {
        id: _watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            if (root._busyStage !== "query" && root._busyStage !== "write") return
            var wasWrite = root._busyStage === "write"
            root._busyStage = ""
            root.message(qsTr("服务器未回应"),
                         wasWrite
                         ? qsTr("回航请求超时。后端可能已经记录，请刷新任务状态后再操作，避免重复提交。")
                         : qsTr("回航点查询超时，请稍后重试。数据库与飞机均未做任何改动。"))
        }
    }

    OpsReturnDialog {
        id: _dialog
        // ‼️ 不设 parent 时 `Dialog` 落在父项 (0,0)——本组件是 0×0 的 Item，表现为
        //    弹框贴着屏幕左上角。既有 OpsDialog 实例全部显式给 parent/x/y。
        parent: root.shell
        x: root.shell ? Math.round((root.shell.width - width) / 2) : 0
        y: root.shell ? Math.round((root.shell.height - height) / 2) : 0
        task: root._task
        candidates: root._candidates
        onWaypointAccepted: function (seq) { root._confirm(seq) }
        onWaypointCancelled: root._candidates = null
    }

    OpsDialog {
        id: _confirmDialog
        parent: root.shell
        x: root.shell ? Math.round((root.shell.width - width) / 2) : 0
        y: root.shell ? Math.round((root.shell.height - height) / 2) : 0
        title: qsTr("确认回航")
        width: Math.round(420 * ScreenTools.uiTextScaleFactor)
        // 必须显式选「回航」或「取消」：点框外只是 `close()`，不会发 `rejected()`，
        // 确认框悄悄消失会让用户以为回航已取消（实际什么都没发生，这次倒无副作用）。
        modal: true
        closePolicy: Popup.NoAutoClose
        property string text: ""
        // ‼️ 正文与按钮**必须包在同一个 `ColumnLayout` 里**：`Dialog` 的缺省
        //    `contentItem` 是一个**普通 Item**（不是布局，`implicitW/H` 恒 0），
        //    两个平级子项会一起落在 (0,0) —— 2026-11-07 用户截图里按钮正好压在
        //    「目标：…/沿航线回退距离：…」这两行上，就是因为它。
        ColumnLayout {
            width: parent.width
            spacing: Math.round(12 * ScreenTools.uiTextScaleFactor)
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"
                wrapMode: Text.Wrap
                text: _confirmDialog.text
            }
            // ‼️ 不用 `standardButtons`：平台默认按钮是白底浅灰字，落在深绿卡上既不是
            //    用户 2026-11-07 裁定的三档色，也读不清。改用 `OpsDialogButton`（色值单点）。
            //    自定义按钮**不会**触发 `accepted()/rejected()`，动作直接写在 `onClicked` 里。
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(16 * ScreenTools.uiTextScaleFactor)
                Item { Layout.fillWidth: true }
                // 白 = 取消（不改变任何状态）
                OpsDialogButton {
                    text: qsTr("取消")
                    kind: "cancel"
                    onClicked: _confirmDialog.close()
                }
                // 绿 = 确认执行（回航是正常业务流程，不是应急/救济）
                OpsDialogButton {
                    text: qsTr("确认")
                    kind: "primary"
                    onClicked: root._execute()
                }
            }
        }
    }

    // 上传失败后的**重试入口**（设计稿 §6.3「重试路径」）。
    // ‼️ 没有这个框，`retryUpload()` 就是死代码：用户看到"目的地已记录、可重试上传"，
    //    却没有任何地方能点。
    OpsDialog {
        id: _retryDialog
        parent: root.shell
        x: root.shell ? Math.round((root.shell.width - width) / 2) : 0
        y: root.shell ? Math.round((root.shell.height - height) / 2) : 0
        title: qsTr("回航航线上传失败")
        width: Math.round(420 * ScreenTools.uiTextScaleFactor)
        // ‼️ `modal` + `NoAutoClose` 缺一不可：点框外走 `Popup.close()`，**不发** `rejected()`
        //    （Qt 文档明确），`onRejected` 里清 `_busyStage` 的那行不会执行 ⇒ stage 永停
        //    "upload"，之后每次点【回航】都被 `begin()` 的重复点击闸静默吞掉。
        modal: true
        closePolicy: Popup.NoAutoClose
        property string text: ""
        // ‼️ 与 `_confirmDialog` 同一个坑：正文与按钮必须同在一个 `ColumnLayout` 内，
        //    否则 `Dialog` 的缺省 `contentItem`（普通 Item）会把两者叠放在 (0,0)。
        ColumnLayout {
            width: parent.width
            spacing: Math.round(12 * ScreenTools.uiTextScaleFactor)
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"
                wrapMode: Text.Wrap
                text: _retryDialog.text
            }
            // ‼️ 同 `_confirmDialog`：不用 `standardButtons`（平台默认配色）。
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(16 * ScreenTools.uiTextScaleFactor)
                Item { Layout.fillWidth: true }
                // 白 = 取消。‼️ 取消重试必须**解除忙碌态**：`_busyStage` 停在 "upload" 会让
                //    下一次 `begin()` 被「重复点击」闸直接挡回——用户关掉重试框后再点「回航」，
                //    界面毫无反应。（原先挂在 `onRejected` 上；自定义按钮不走它，写在这里。）
                OpsDialogButton {
                    text: qsTr("取消")
                    kind: "cancel"
                    onClicked: { _retryDialog.close(); root._busyStage = "" }
                }
                // 绿 = 重试（正常业务流程，不是危险动作）
                OpsDialogButton {
                    text: qsTr("重试")
                    kind: "primary"
                    onClicked: { _retryDialog.close(); root.retryUpload() }
                }
            }
        }
    }

    OpsReturnRoute {
        id: _route
        onSucceeded: {
            root._busyStage = ""
            // 原航线轮询停掉，不再复用。由视图注入（`OpsView` 有 `_routeSyncs`，`RomView` 没有）。
            if (root.routeResetFn) root.routeResetFn(root._task)
            // 2026-11-24 删掉「回航航线已上传」成功提示（原文：「无人机沿原航线倒序飞回起飞机场。落点＝
            // 原机位（已保留），待飞机到达后点卡片上的【降落】即可完成降落。」）。它经 `OpsShell`
            // 的 `onMessage` 走 `QGroundControl.showMessageDialog`（`QGCSimpleMessageDialog`，系统默认
            // 样式），用户判定为"临时 debug 提示"、不是正式流程的 `OpsDialog`，要求去掉。
            // ‼️ 只删这一条**成功**提示：本文件其余 `root.message(...)` 全是失败反馈（写库 / 上传 /
            //    切模式失败），一条都不能删——没有它们，"框关了" 与 "回航生效了" 在界面上逐字相同。
            //    回航是否真的开始，由任务卡状态（轮询）体现，不再另弹框。
        }
        onFailed: function (message, stage) {
            // 只有 "upload" 还留着可重试的在途动作；"mode" 是一次终局失败，
            // 保留忙碌态会把后续每一次「回航」都挡在重复点击闸上。
            root._busyStage = (stage === "upload") ? "upload" : ""
            if (stage === "mode") {
                // 模式切换失败**不重试**（设计稿 §7）：重传只会再走一遍同样必然失败的路径。
                root.message(qsTr("模式切换未完成"), message)
            } else {
                // 上传失败 ⇒ 弹「重试上传」框，而不是只弹一条通知。
                _retryDialog.text = message + qsTr("\n目的地已记录，飞机仍在原航线上。")
                _retryDialog.open()
            }
        }
    }
}
