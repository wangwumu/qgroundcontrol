import QtQuick
import QtQuick.Controls // Popup.NoAutoClose
import QtQuick.Layouts

import QGroundControl.Controls // ScreenTools.uiTextScaleFactor

import "."
import "OpsCommon.js" as OpsCommon

/// 备降流程（2026-11-09，《备降选点-设计稿》§7）：查候选 → 选点 → 二次确认 →
/// POST /divert → 构造上传。
///
/// ‼️ 顺序是硬的：**先写库、再下指令**（用户 2026-09-23 工程指令）。写库失败 ⇒
///    不构造、不上传；上传失败 ⇒ 保留候选与选中项，重试时**只重传**（后端已记录）。
///
/// 与 `OpsReturnFlow` 的差异：
///   · 候选来源是 `GET /divert-candidates`，选的是 `candidates`（站点候选）而非 `waypoints`；
///   · 写库接口是 `POST /divert`，落 `landing_site_id` + `divert_reason`；
///   · 成功后**不**清原航线同步器：备降没有「原航线必须 reset」的语义，原航线仍在
///     `OpsRouteSync` 手里照常更新（飞机还在飞，只是目的地变了）。
Item {
    id: root

    /// `OpsShell`（骨架）：HTTP 与轮询都走它，不另造封装。
    property var shell: null
    /// 取飞机：`OpsView` / `RomView` 各有自己的 `_vehicleForTask`，由视图注入，
    /// Flow 不复制匹配逻辑。
    property var vehicleFn: null

    property var _task: null
    property var _candidates: null
    /// 选中那一行的 `seq`（后端数组下标，唯一键）。
    property int _selectedSeq: -1
    /// 选中候选对应的**站点** id —— POST /divert 的 `site_id` 取它。
    /// ‼️ 不是 `waypoint_id`：`/divert` 写的是 `table_flight_task.landing_site_id`，
    ///    后端拿它跑 `siteUseReady` 与管辖判定；传航点 id 会命中另一个站点（或 0）。
    property int _selectedSiteId: -1
    property real _aircraftLat: NaN
    property real _aircraftLon: NaN
    property string _busyStage: "" // "" | "query" | "write" | "upload" | "mode"
    /// 流程代号。看门狗超时后 `_busyStage` 被清空 ⇒ 用户可再点【备降】发起新一轮，
    /// 而**上一轮的网络回调仍可能到达**。回调进门先比代号：不是本人就原地返回。
    property int _gen: 0

    signal message(string title, string text)

    function begin(task) {
        if (!task) return
        if (!shell) {
            message(qsTr("无法选择备降点"), qsTr("后台连接未就绪。数据库与飞机均未做任何改动。"))
            return
        }
        // 重复点击：上一轮还在查询/写库/上传时再点一次直接忽略。否则会并发两个
        // POST /divert——后一个会把前一个刚写的目的地再改一次，并再写一条流水。
        if (_busyStage !== "") return
        _task = task
        _selectedSeq = -1
        _selectedSiteId = -1
        _candidates = null
        var v = vehicleFn ? vehicleFn(task) : null
        if (!v || !v.coordinate || !v.coordinate.isValid) {
            message(qsTr("无法选择备降点"), qsTr("未收到飞机位置。数据库与飞机均未做任何改动。"))
            return
        }
        // 记下本次查询使用的坐标：写库时回传同一组值，事件行与「距离」才对得上。
        _aircraftLat = v.coordinate.latitude
        _aircraftLon = v.coordinate.longitude
        _busyStage = "query"
        var gen = ++_gen
        _watchdog.restart()
        shell._get("/api/tasks/" + task.task_id + "/divert-candidates?lat="
                   + _aircraftLat + "&lon=" + _aircraftLon,
                   function (status, data) {
                       if (gen !== _gen) return
                       _watchdog.stop()
                       _busyStage = ""
                       if (status !== 200) {
                           message(qsTr("无法获取备降点"),
                                   (data && data.error) || ("HTTP " + status))
                           return
                       }
                       _candidates = data
                       _dialog.open()
                   })
    }

    function _findCandidate(seq) {
        if (!_candidates || !_candidates.candidates) return null
        for (var i = 0; i < _candidates.candidates.length; i++)
            if (_candidates.candidates[i].seq === seq) return _candidates.candidates[i]
        return null
    }

    function _confirm(seq) {
        var c = _findCandidate(seq)
        // 候选侧已过滤不可用场地；这里再 fail-closed 一次：没有 site_id 就没有管辖权，
        // 落库后无人能签入/指派/收尾。
        if (!c || !(c.site_id > 0) || c.landable === false) {
            message(qsTr("备降未生效"), qsTr("所选站点当前不可用，数据库未做任何改动。"))
            return
        }
        _selectedSeq = seq
        _selectedSiteId = c.site_id
        _dialog.close()
        var name = c.site_name || ("#" + c.site_id)
        var note = OpsCommon.divertRouteNote(c, _candidates ? _candidates.departed === true : false)
        _confirmDialog.text = qsTr("目标：%1\n距离：%2\n%3")
                .arg(name).arg(_fmtM(c.distance_m)).arg(note)
        if (c.receivable === false) {
            _confirmDialog.text += qsTr("\n该场地未配置站点操作员，到站后可能无人接引。")
        }
        // ‼️ **不写「不可撤销」**：换场地是合法的新处置（设计稿 §6.5），说不可撤销
        //    既不符合事实，也会让人在真该换场地时不敢改。
        //
        // ‼️ 责任链怎么走**取决于目的地是否真的变了**（与 `/divert` 的收尾判据同源）：
        //    · 换了场地 ⇒ `closeReturnLoopTx` 释放机位、作废**全部 PENDING** 交接，
        //      `recordDispositionTx` ③b 再作废 LANDING 档 ⇒ 原降落指挥已作废，
        //      须由本航线监控员向备降场重新移交；
        //    · 选的是**当前**降落场 ⇒ 后端什么都不做（`changed=false` 幂等短路），
        //      原降落指挥仍然有效，说「作废」就是假话。
        //
        // ‼️ **不能写「请先由起飞机场重签 ROUTE」**：备降入口本身就要求已签入 ROUTE
        //    （应急菜单可见 ⟺ `signedIn` ⟺ ROUTE 交接 ACCEPTED），而收尾只作废
        //    `status='PENDING'` —— 那个 ACCEPTED 的 ROUTE 交接**不会被碰** ⇒ 起飞机场
        //    再 Propose(ROUTE) 必然撞 `该阶段已有生效中的交接` 409，把应急流程引向
        //    一个必然失败的动作（2026-11-09 二次复核 Important-2）。
        //    设计稿 §6.5 那句只适用于「ROUTE 交接仍是 PENDING」，而本入口排除了该前提。
        var sameSite = root._candidates
                && root._candidates.current_landing_site_id === c.site_id
        if (sameSite) {
            _confirmDialog.text += qsTr("\n目标即当前降落场地，原降落指挥不受影响。")
        } else {
            _confirmDialog.text += qsTr("\n备降后原降落指挥作废。落地前需由本航线监控员向备降场重新移交降落指挥（签出/签入）。")
        }
        _confirmDialog.open()
    }

    function _execute() {
        _confirmDialog.close()
        if (_selectedSiteId <= 0) return
        _busyStage = "write"
        var gen = ++_gen
        _watchdog.restart()
        shell._post("/api/tasks/" + _task.task_id + "/divert",
                    { site_id: _selectedSiteId,
                      lat: _aircraftLat, lon: _aircraftLon,
                      divert_reason: "" },
                    function (status, data) {
                        if (gen !== _gen) return
                        _watchdog.stop()
                        if (status !== 200) {
                            _busyStage = ""
                            var errText = (data && data.error) || ("HTTP " + status)
                            message(qsTr("备降未生效"),
                                    errText + qsTr("\n数据库未做任何改动，飞机仍在原航线上。"))
                            // 409 = 「目标此刻不可用 / 任务状态变了 ⇒ 列表已过期」⇒ 重新拉候选。
                            // 403/404/500 不重拉：那不是列表过期，重拉只会把同一个错误再弹一遍。
                            if (status === 409) {
                                _candidates = null
                                begin(_task)
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
        // ‼️ `vehicle` 必须**每次现取**：`OpsDivertRoute._prepare()` 的第一道闸就是它。
        //    漏赋这一行，每次备降都会停在「未找到该任务无人机的连接」——
        //    而此时库已经改了、飞机还在原航线上，是最坏的一种半成功。
        _route.vehicle = vehicleFn ? vehicleFn(_task) : null
        _route.task = _task
        _route.candidate = _candidates
        _route.targetSeq = _selectedSeq
        _route.start()
    }

    /// 上传失败后只重传（后端已记录，重复 POST 会再写一条流水）。
    function retryUpload() {
        if (_busyStage !== "upload") return
        // ‼️ 重试前**重新取一次** vehicle：`Vehicle` 只在建链/重启时重建，飞机重连后
        //    旧引用已不在 `_vehicleForTask` 里，拿它重传会发到一条死链上。
        _route.vehicle = vehicleFn ? vehicleFn(_task) : null
        _route.retryUpload()
    }

    function _fmtM(m) {
        if (!m && m !== 0) return "—"
        return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"
    }

    // 查询/写库的看门狗（15 s）。`OpsShell._send` 没有超时、QML XHR 本身也没有：
    // 服务端接受连接却不回包时，回调永不执行 ⇒ `_busyStage` 永远停在 query/write，
    // 后续【备降】全部被静默忽略、界面零提示。超时后**不自动重发**——写库可能已经在
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
                         ? qsTr("备降请求超时。后端可能已经记录，请刷新任务状态后再操作，避免重复提交。")
                         : qsTr("备降点查询超时，请稍后重试。数据库与飞机均未做任何改动。"))
        }
    }

    OpsDivertDialog {
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
        title: qsTr("确认备降")
        width: Math.round(440 * ScreenTools.uiTextScaleFactor)
        // 必须显式选「备降」或「取消」：点框外只是 `close()`，不会发 `rejected()`，
        // 确认框悄悄消失会让用户以为备降已取消。
        modal: true
        closePolicy: Popup.NoAutoClose
        property string text: ""
        // ‼️ 正文与按钮**必须包在同一个 `ColumnLayout` 里**：`Dialog` 的缺省
        //    `contentItem` 是一个**普通 Item**（不是布局），两个平级子项会一起落在 (0,0)。
        ColumnLayout {
            width: parent.width
            spacing: Math.round(12 * ScreenTools.uiTextScaleFactor)
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"
                wrapMode: Text.Wrap
                text: _confirmDialog.text
            }
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
                // 红 = 应急动作（备降不是正常业务流程）
                OpsDialogButton {
                    text: qsTr("确认备降")
                    kind: "danger"
                    onClicked: root._execute()
                }
            }
        }
    }

    // 上传失败后的**重试入口**（设计稿 §6.3「重试路径」同构）。
    // ‼️ 没有这个框，`retryUpload()` 就是死代码。
    OpsDialog {
        id: _retryDialog
        parent: root.shell
        x: root.shell ? Math.round((root.shell.width - width) / 2) : 0
        y: root.shell ? Math.round((root.shell.height - height) / 2) : 0
        title: qsTr("备降航线上传失败")
        width: Math.round(440 * ScreenTools.uiTextScaleFactor)
        // ‼️ `modal` + `NoAutoClose` 缺一不可：点框外走 `Popup.close()`，**不发** `rejected()`，
        //    `_busyStage` 会永停 "upload"，之后每次点【备降】都被 `begin()` 的重复点击闸吞掉。
        modal: true
        closePolicy: Popup.NoAutoClose
        property string text: ""
        ColumnLayout {
            width: parent.width
            spacing: Math.round(12 * ScreenTools.uiTextScaleFactor)
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"
                wrapMode: Text.Wrap
                text: _retryDialog.text
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(16 * ScreenTools.uiTextScaleFactor)
                Item { Layout.fillWidth: true }
                // 白 = 取消。‼️ 取消重试必须**解除忙碌态**，否则下一次 `begin()` 被挡回。
                OpsDialogButton {
                    text: qsTr("取消")
                    kind: "cancel"
                    onClicked: { _retryDialog.close(); root._busyStage = "" }
                }
                // 重试是常规动作 ⇒ 主色（不是应急）
                OpsDialogButton {
                    text: qsTr("重试")
                    kind: "primary"
                    onClicked: { _retryDialog.close(); root.retryUpload() }
                }
            }
        }
    }

    OpsDivertRoute {
        id: _route
        onSucceeded: {
            // 备降没有原航线同步器语义要清（飞机仍在飞，原航线照常在 OpsRouteSync 里）。
            root._busyStage = ""
        }
        onFailed: function (message, stage) {
            // 只有 "upload" 还留着可重试的在途动作；"mode" 是一次终局失败。
            root._busyStage = (stage === "upload") ? "upload" : ""
            if (stage === "mode") {
                // 模式切换失败**不重试**：重传只会再走一遍同样必然失败的路径。
                root.message(qsTr("模式切换未完成"), message)
            } else {
                _retryDialog.text = message + qsTr("\n目的地已记录，飞机仍在原航线上。")
                _retryDialog.open()
            }
        }
    }
}
