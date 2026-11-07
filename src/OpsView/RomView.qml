import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

/// @brief 飞行监控主界面 —— **航线监控员（ROUTE_MONITOR）视图**
/// 设计见 docs/qgc/航线监控员主界面设计-20260922.md。
///
/// 与 `OpsView.qml`（站点操作员）是**并列的两个视图**，骨架/数据源完全相同——地图、右栏容器、
/// 命令条、底部状态栏、姿态仪/罗盘、轮询与全部 HTTP、交接弹框全在 `OpsShell.qml` 里。
/// 本文件只写两者**不同**的那部分：
///
///   1. `routeLayersEnabled: true` —— 开航线图层（① 缓存 + ② 航点 + ③ 轮询），
///      地图的 L1/L2/L3 与右栏上段都吃它；
///   2. 右栏三段（§4.1 / §6）：上段**航线列表（常驻）** + 中段**航班列表** + 下段**机载告警**，
///      没有机位平面图。下段吃的 C++ 面是 `Vehicle::statusTextMessages`（§6.1 路 B，
///      已在 `StatusTextHandler` / `Vehicle` 里补好）。
///   3. `overviewView: "route"` —— 保留但已**降级为兜底**，见下方该行的注释。
///
/// ‼️ 本视图连 `polled()`，但**只为超时检查**（§3.6.2）：每 2s 看一遍登记集合里有没有飞机
///    超过阈值没来帧，定向加速重发。推监控清单改挂 `routeTasksUpdated`（③ 成功之后）。
///    机位仍**不拉**——那是站点专属数据，监控员拉它没有消费者。
///
/// ‼️ 本视图**不填** `commandBarExtras`。出站/进站（本站语义）与机位朝向（无机位图可转）
///    都是站点专属；槽留空后，命令条上就只剩骨架自带的操作员名/时间与窗口按钮。
///    命令条右侧让开原生载具指示器区的让位逻辑在骨架里，两个视图自动共享，此处无需关心。
///
/// ‼️ 本视图**不认识** SITE_ATC。分流判据只有一处，在 `MainWindow.qml` 的
///    `_onLoginSucceededForRole()`——用户 2026-09-21 裁定两个身份不允许重叠、不存在双身份，
///    故这里是"登录身份**就是**监控员"，不是"监控员分支"。视图内若再判一次角色，
///    就又多出一份会漂移的判据副本。
OpsShell {
    id: romView

    //-------------------------------------------------------------------------
    // 骨架输入
    //-------------------------------------------------------------------------
    // 数据源参数（吃进 GET /api/snapshot/ops/overview?view=）。**不是**显示开关。
    // ⚠️ `view=route` 现已被本视图**降级为兜底**：它的判据是「任务 IN_FLIGHT 或存在 PENDING
    //    的航线移交」，与裁定 ③ 要求的「航线常驻、不看有没有航班」**不是一回事**（真库实测
    //    该端点恒回 0 条——全库没有 IN_FLIGHT 的任务）⇒ 右栏中段曾长期必然是空的。
    //    真正的数据源是本视图下面开的 `routeLayersEnabled`（① 缓存 + ③ 轮询）。
    overviewView: "route"
    // 开航线图层：骨架据此跑 §7.2 的首拉序列（① → ② → ③）、推监控清单、并把地图的
    // L1/L3 改吃航线缓存与 `devices`。**站点视图保持 false**，不受影响。
    routeLayersEnabled: true
    // `rightPanelWidth` **刻意不传**，用骨架缺省值 `_rightPanelMinW`（按窗口宽比例折算）：本视图
    // 没有机位平面图，也就没有"按图所需宽在下限与上限之间伸缩"这回事。写这一行是为了让
    // "为什么没有"有个落点，免得日后有人以为漏了。

    //-------------------------------------------------------------------------
    // 会话与身份
    //-------------------------------------------------------------------------
    // 读 roles 属性（NOTIFY rolesChanged）而非 hasRole() 方法：方法调用不注册 QML 绑定依赖，
    // 登录后才填充的 roles 不会触发重估 → 视图永不显示。indexOf 读属性值，登录后绑定自动更新。
    readonly property bool _isRouteMon: AuthController.roles.indexOf("ROUTE_MONITOR") >= 0

    //=========================================================================
    // 「继续完成航线任务」（RESUME）：异常派生状态 + n 秒抑制窗口
    //=========================================================================
    // 设计稿《应急情况处理》§5.1（2026-11-07 定稿）。无人机不是只发**一次**异常，而是连续
    // 重复下发一串 RTL/悬停状态 ⇒ 本端按设备维护**派生状态**，不按单条报文置位/清除。
    //
    // 状态机（逐条对应设计稿）：
    //   收到 RTL/悬停        ⇒ 置位并刷新 `lastAnomalyAt`
    //   遥测正常且 n 秒无异常 ⇒ 自动清除
    //   按下 RESUME 后        ⇒ t0（`AUTO_MISSION` 发送成功）起进入 n 秒抑制期：
    //                          期内报文不置位、但刷新 `lastAnomalyAt`；菜单保持置灰
    //                          t0+n 时最近 n 秒仍有异常 ⇒ 重新置位，并提示"恢复未生效"
    //   链路中断             ⇒ 不自动清除；恢复后重新开始 n 秒计时
    //
    // ‼️ 状态只在本端内存里，不落库：记录由**发命令前**的那次写库补上（§5.1「落库与状态修正」）。

    /// 异常判定 / 抑制窗口 n（毫秒）。设计稿要求"实现时落为可配置项"——这是唯一落点，
    /// 将来接设置项时只改这一处。5 秒是容忍上限：再长就"来得及处置"了（用户 2026-11-07）。
    property int resumeAnomalyWindowMs: 5000

    /// 抑制 / 异常状态的版本号。`_resumeStates` 是普通 JS 对象（QML 不观察其内容），
    /// 1s 刷新时自增它 ⇒ `TaskListPanel` 里 `enabled` 的绑定经函数调用读到它，会自动重估。
    property int _resumeRevision: 0

    /// deviceID -> {
    ///   active:         处理中派生出的"异常状态存在"
    ///   lastAnomalyAt:  最后一次观测到 RTL/悬停的时刻（抑制期内也刷新）
    ///   anomalySince:   本轮异常首次观测时刻（写进操作记录，供事后关联）
    ///   suppressedUntil: 抑制期结束时刻；0 = 不在抑制期
    ///   linkWasLost:    上次是否因链路中断而暂停自动清除
    ///   failNotified:   本轮抑制期是否已提示过"恢复未生效"
    ///   linkNotified:   本轮抑制期是否已提示过"链路中断，无法确认恢复"
    ///   sawNormalSinceCommand: 抑制期内是否**回读过**非 RTL/悬停模式（见抑制期结束的判据）
    /// }
    property var _resumeStates: ({})

    /// 待确认的任务（确认框打开期间非 null）。
    property var _resumePendingTask: null

    /// 写库请求是否在途。在途期间菜单置灰（防重复提交），并且超时后**丢弃迟到的响应**——
    /// 已经告诉用户"指令未发出"之后再补发 AUTO_MISSION，是更严重的谎报。
    property bool _resumeRequestPending: false

    /// 写库请求的代次。只判 `_resumeRequestPending` 不够：第 1 次超时后用户立刻重试，
    /// 第 1 次的迟到 200 会在第 2 次在途时到达，被当成第 2 次的成功 ⇒ 发两次 AUTO_MISSION。
    /// 回调只认自己那一代，超时/重试都自增把旧回调作废。
    property int _resumeRequestSeq: 0

    Timer {
        // 与骨架的 `_now` 时钟同频（1s），但**不复用**它：`_now` 只是界面时钟，
        // 本状态机还要在抑制期结束时弹提示，需要自己的触发点。
        interval: 1000; repeat: true
        running: romView.visible && AuthController.loggedIn
        onTriggered: romView._refreshResumeStates()
    }

    // 写库请求的超时兜底。**不能用 `xhr.timeout`**：Qt 6.11 的 QML XMLHttpRequest 没实现它
    // （赋值能读回、永不触发，见 `OpsView.qml` 里同款注释）。没有这一条，请求卡在网络上时
    // 弹框已关、菜单已灰，界面上就是"点了没反应"——应急处置里最不能出现的那种。
    Timer {
        id: resumeRequestTimer
        interval: 10000; repeat: false
        onTriggered: {
            if (!romView._resumeRequestPending) return
            romView._resumeRequestPending = false
            romView._resumeRequestSeq++   // 作废这一代的迟到响应（见 `_resumeRequestSeq` 注释）
            QGroundControl.showMessageDialog(romView, qsTr("继续任务未确认"),
                qsTr("请求超时：未收到服务器回应，AUTO_MISSION 未下发。\n"
                     + "数据库是否写入未能确认，请核对后决定是否重试（重试会再写一条记录）。"))
        }
    }

    /// 按 `task.device_id` 定位载具。与 `OpsView._vehicleForTask` 同解——`RomView` 是
    /// `OpsShell` 的子类而不是 `OpsView` 的子类，够不到那一份，故在此重写（逻辑只有一行）。
    function _vehicleForTask(task) {
        if (!task || !task.device_id) return null
        var vs = QGroundControl.multiVehicleManager.vehicles
        if (!vs || vs.count === 0) return null
        return OpsCommon.matchDeviceToVehicle(task, vs)
    }

    /// ‼️ 模式比较一律用 `Vehicle` 给出的模式名**属性**，不得写 `"Return"` / `"Hold"` 字面量：
    /// PX4 插件里的 `rtlFlightModeName = tr("Return")` 在中文界面会被翻译成「返航Return」。
    function _isAnomalyMode(v) {
        if (!v) return false
        return v.flightMode === v.rtlFlightMode || v.flightMode === v.pauseFlightMode
    }

    /// 读不到链路状态 ⇒ 按"不能确认恢复"处理（fail-closed）。
    function _vehicleLinkLost(v) {
        if (!v || !v.vehicleLinkManager) return true
        return v.vehicleLinkManager.communicationLost === true
    }

    /// 1s 推进一次派生状态。只碰当前仍连在本端的载具；已消失的载具条目会被清掉，
    /// 免得同一 deviceID 重连时带着上一轮的抑制窗口。
    function _refreshResumeStates() {
        var now = Date.now()
        var n = romView.resumeAnomalyWindowMs
        var vs = QGroundControl.multiVehicleManager.vehicles
        var states = romView._resumeStates
        var alive = {}
        var count = vs ? vs.count : 0
        for (var i = 0; i < count; i++) {
            var v = vs.get(i)
            if (!v) continue
            var deviceID = Number(v.deviceID())
            if (!(deviceID > 0)) continue
            alive[deviceID] = true
            var st = states[deviceID]
            if (!st) {
                st = { active: false, lastAnomalyAt: 0, anomalySince: 0,
                       suppressedUntil: 0, linkWasLost: false, failNotified: false,
                       linkNotified: false, sawNormalSinceCommand: false }
                states[deviceID] = st
            }
            // ‼️ 重新见到一辆**消失过**的载具（单链路断连会把 Vehicle 移出列表）：抑制期与
            //    异常状态都不许丢（§5.1「链路中断不自动清除、菜单不重新激活」）。
            //    · 抑制期内的断链 ⇒ 从"重新见到它"起重新计时 n 秒（恢复后的第一个 tick
            //      起才是完整的新窗口）；
            //    · 无抑制期但异常成立 ⇒ 把 n 秒自动清除的计时起点重置到现在（断链期间
            //      不能算"没有异常"）。
            if (st.linkWasLost) {
                st.linkWasLost = false
                if (st.suppressedUntil > 0) {
                    st.suppressedUntil = now + n
                    romView._notifyResumeLinkLost(st)
                    continue
                }
                st.lastAnomalyAt = now
            }
            var anomalous  = romView._isAnomalyMode(v)
            var linkLost   = romView._vehicleLinkLost(v)
            var suppressing        = st.suppressedUntil > now
            var suppressionExpired = st.suppressedUntil > 0 && now >= st.suppressedUntil

            // ‼️ 链路中断优先于一切**模式**判定：`flightMode` 是**最后一次收到的心跳里的模式**，
            //    断链后它只会停在旧值（多半还是 Return/Hold），而 `communicationLost` 有 3.5s
            //    去抖 ⇒ 断链恰好落在到期那几秒时，照常读缓存模式会把"读不到遥测"判成
            //    "仍有返航报文"并误报"切换未生效"。链路断 ⇒ 抑制期顺延、异常状态不置位、
            //    提示一次"无法确认恢复"（§5.1 明确要求这句提示）。
            if (linkLost && (suppressing || suppressionExpired)) {
                st.active = false
                st.suppressedUntil = now + n
                st.linkWasLost = true
                romView._notifyResumeLinkLost(st)
            } else if (anomalous) {
                // 抑制期内的报文是命令前那串重复报文的尾巴 / 模式切换的过渡残留：
                // 不置位，但**仍刷新** `lastAnomalyAt`，供抑制期结束时判断。
                st.lastAnomalyAt = now
                if (!st.anomalySince) st.anomalySince = now
                st.linkWasLost = linkLost
                if (suppressionExpired) {
                    st.suppressedUntil = 0
                    // **模式回读优先**（§5.1）：抑制期内只要回读到过一次非 RTL/悬停模式，
                    // 说明切换已生效 ⇒ 判成功、状态保持清除。到期这一刻仍为异常不算失败
                    // ——那是切换的过渡残留被 1 秒采样捞到。真正的"恢复后再次触发"会在
                    // 下一个 tick 作为**新的**异常重新置位（并重新给出判定），不在这里误报。
                    if (st.sawNormalSinceCommand) {
                        st.active = false
                        st.anomalySince = 0
                    } else {
                        st.active = true
                        romView._notifyResumeFailed(st)
                    }
                } else if (!suppressing) {
                    st.active = true
                }
            } else if (suppressing) {
                st.active = false
                st.linkWasLost = linkLost
                // 模式回读已经离开 RTL/悬停 ⇒ 指令确实生效过。记下它，抑制期结束时用来
                // 把"模式切换那一下的过渡残留"与"真正没生效"分开（见上一条判据）。
                st.sawNormalSinceCommand = true
            } else if (suppressionExpired) {
                // t0+n：最近 n 秒内仍有异常下发 ⇒ 重新成立；否则保持清除。
                // ‼️ 但若窗口内**已经回读到非 RTL/悬停模式**，说明切换生效过，此时仍在
                //    `lastAnomalyAt` 窗口里多半是切换那 1-2 秒的过渡残留（1s tick 采样，
                //    残留必然落在窗口前段）⇒ 判成功。只有"整段抑制期都没回读到正常模式"
                //    才用时间窗兜底。设计稿的口径是"模式回读 + 最近 n 秒是否仍有异常"，
                //    两者是合取，不是只看后一半。
                st.active = !st.sawNormalSinceCommand
                            && st.lastAnomalyAt > 0 && (now - st.lastAnomalyAt < n)
                st.suppressedUntil = 0
                if (st.active) {
                    romView._notifyResumeFailed(st)
                } else {
                    st.anomalySince = 0
                }
            } else if (linkLost) {
                // 遥测不正常不满足"正常情况" ⇒ 不自动清除。恢复后重新开始 n 秒计时（见上）。
                st.linkWasLost = true
            } else {
                if (st.active && now - st.lastAnomalyAt >= n) {
                    st.active = false
                    st.anomalySince = 0
                }
            }
        }
        for (var key in states) {
            if (!alive[Number(key)]) {
                var gone = states[key]
                // 载具暂时消失（断连会把 Vehicle 从列表移除）⇒ 抑制期/异常状态保留。
                // 直接删条目会让同一 deviceID 重连后读到 RTL 时**立刻**可点：既没有剩余
                // 抑制期，也没有"未生效"提示。只有"无异常也不在抑制期"的条目才清掉，
                // 避免状态表随历史设备无限增长。
                if (gone.suppressedUntil > 0 || gone.active === true) {
                    gone.linkWasLost = true
                } else {
                    delete states[key]
                }
            }
        }
        romView._resumeRevision++
    }

    /// 抑制期结束仍判为异常 ⇒ 提示"恢复未生效"。每个抑制期只提示一次。
    /// 设计稿要求"结合无人机轨迹判断是切换未生效还是恢复后再次触发"——轨迹判读是人的事，
    /// 这里只把两种可能都摆出来，不替操作员下结论。
    function _notifyResumeFailed(st) {
        if (st.failNotified) return
        st.failNotified = true
        QGroundControl.showMessageDialog(romView, qsTr("继续任务未生效"),
            qsTr("指令已下发，但未能确认飞机已恢复航线任务（最近 %1 秒内仍有返航/悬停状态）。\n"
                 + "可能是模式切换未生效，也可能是异常原因仍未解除；"
                 + "请结合飞机航迹判断后重新处置。")
                .arg(Math.round(romView.resumeAnomalyWindowMs / 1000)))
    }

    /// 抑制期内链路中断 ⇒ 提示"无法确认恢复"（§5.1 明确要求）。每个抑制期只提示一次。
    /// ‼️ 措辞不得写成"仍有返航/悬停"或"切换未生效"：断链时模式是缓存值，我们**不知道**
    ///    飞机当前在做什么；把它说成任一结论都是无依据的断言。
    function _notifyResumeLinkLost(st) {
        if (st.linkNotified) return
        st.linkNotified = true
        QGroundControl.showMessageDialog(romView, qsTr("链路中断，无法确认恢复"),
            qsTr("恢复指令已下发，但之后与飞机的链路中断，无法确认是否已切回航线任务。\n"
                 + "链路恢复后将重新观察 %1 秒；请确认链路恢复后再处置。")
                .arg(Math.round(romView.resumeAnomalyWindowMs / 1000)))
    }

    /// 取**当前**任务行（按 task_id 从最新一轮轮询结果里找）。
    /// ‼️ `TaskListPanel` 传进来的 `modelData` 是**渲染快照**，停在模型刷新那一刻。确认框
    ///    是模态的、可以开着很久：期间降落站接受交接、任务状态/处置方式都可能变化 ⇒
    ///    发指令前必须按 task_id 重新取当前行，不能拿快照当"现在的状态"。
    function _freshTask(task) {
        if (!task) return null
        var rows = romView._routeTasks
        if (!rows) return null
        for (var i = 0; i < rows.length; i++) {
            if (rows[i] && Number(rows[i].task_id) === Number(task.task_id)) return rows[i]
        }
        return null
    }

    /// 「继续完成航线任务」是否可点（§5.1「菜单项置灰」唯一的判据实现点）。
    /// 前置的 `IN_FLIGHT` / 指令权 / 降落交接条件由 `TaskListPanel._monitorHandoverVisible`
    /// 保证（菜单借此才可见），这里补的是 RESUME 特有的四条。
    function _resumeAvailable(task) {
        // ‼️ 读 `_resumeRevision` 是本函数对 1s 刷新的**唯一**绑定依赖：`_resumeStates`
        //    是普通 JS 对象，改内容不会通知 QML；不读它，抑制期结束/自动清除后按钮不会变灰/变亮。
        //    条件永不成立，只为在绑定求值时登记这次属性读取（写成裸表达式会被编译器当无副作用丢弃）。
        if (romView._resumeRevision < 0) return false
        if (!task) return false
        // 上一次写库请求还没回来 ⇒ 不可重复提交（两次请求会产生两条记录、两条指令）。
        if (romView._resumeRequestPending) return false
        // 抛异常（如载具对象在求值途中被销毁）一律按"不可用"——否则绑定求值失败会得到
        // undefined，而 `enabled:` 把 undefined 当"无绑定值"退回 true，菜单反而可点。
        try {
            // ‼️ 用**当前**任务行，不用调用方给的渲染快照（见 `_freshTask`）。
            var fresh = romView._freshTask(task)
            if (!fresh) return false   // 已不在列表里 ⇒ 不处置
            if (fresh.status !== "IN_FLIGHT") return false
            // 已人工回航/备降/迫降：原任务不再是要执行的对象（§5.1「边界」）。缺字段 ⇒ fail-closed。
            if (fresh.disposition !== "NONE") return false
            // 指令权（与卡片出现条件**同一份**判据，见 `TaskListPanel._monitorHandoverVisible`）：
            // 确认框是模态的、可以开着很久，期间降落站可能已接受 LANDING 交接 ⇒ 卡片上的
            // 按钮会消失，但快照里的字段不会变。不在这里重判，就会对已移交的飞机发指令。
            if (!OpsCommon.signedIn(fresh)) return false
            if (OpsCommon.pendingPhase(fresh, "LANDING", romView._handoverById)) return false
            if (OpsCommon.landingState(fresh) === "ACCEPTED") return false
            var v = romView._vehicleForTask(fresh)
            if (!v) return false
            if (romView._vehicleLinkLost(v)) return false
            // 只有 RTL/悬停两种模式视为"可恢复"；Mission/Land/Offboard 一律置灰。
            if (!romView._isAnomalyMode(v)) return false
            var st = romView._resumeStates[Number(fresh.device_id)]
            // ‼️ `=== true`：状态缺失时 `st && st.active` 会求值成 undefined，
            //    而 QML 的 `enabled:` 把 undefined 当"绑定无值"退回默认值 true（fail-open）。
            return !!(st && st.active === true)
        } catch (e) {
            console.warn("RomView._resumeAvailable 判据异常:", e)
            return false
        }
    }

    //=========================================================================
    // 接引清单与超时（设计文档 §3.5.3 / §3.6）
    //=========================================================================
    // 上次**成功**推送的清单。超时检查用它遍历；请求失败时**保留不动**（§3.5.4）。
    property var _monitorIds: []
    // 阈值**不在前端写死**：由 ③ 的 `frame_timeout_ms` 下发（骨架 `_routeFrameTimeoutMs`，
    // 初值等于 `CryptoController::DEFAULT_FRAME_TIMEOUT_MS`，用于"从未成功轮询过"的兜底）。
    readonly property int _frameTimeoutMs: romView._routeFrameTimeoutMs

    /// ③ **成功**后由骨架发 `routeTasksUpdated` 触发；把清单与阈值推给 C++。
    /// ‼️ 失败时**什么都不做**——把"请求失败"当成"没有需要监控的飞机"会让登记集合
    ///    清空，全部飞机在 60s TTL 后集体掉线，而失败原因可能只是一次网络抖动（§3.5.4）。
    /// ‼️ **不再自己发 ③ 的请求**：骨架的 `_poll()` 已经拉了，这里再拉一次会让同一次轮询
    ///    打两个 ③、且两个响应到达次序不定 ⇒ 推送的清单可能与界面上的列表不是同一份快照。
    function _pushMonitorDevices() {
        var ids = OpsCommon.monitorDeviceIds(romView._routeDevices)
        // ‼️ 异常闸：有行但一个合法 ID 都没有 ⇒ **不推**。`setMonitorDevices` 是整份替换
        //    且无条件把 `_monitorListActive` 置真 ⇒ 推空集会立刻清掉 C++ 侧名册，
        //    这一侧刚接手的飞机从下一次合法响应之前都收不到下行（mavp2p 侧该配对在
        //    `qgcSeen` 超过 `MAP_TTL` 后停止投递，默认 60s）。数据源异常 ≠ 名册清空。
        if (OpsCommon.deviceRowsAreAnomalous(romView._routeDevices)) {
            OpsCommon.warnDeviceIdAnomaly(romView._routeDevices.length)
            return
        }
        _monitorIds = ids
        // ⚠️ 清单与阈值**同一次**传入：两个 setter 会造出"新阈值配旧清单"的中间态（§3.6.4）
        cryptoController.setMonitorDevices(ids, _frameTimeoutMs)
    }

    /// 每 2s 的超时检查（与轮询同相，§3.6.2）。**只重发，绝不改清单。**
    /// ⚠️ `since < 0` 表示"从未收到过帧"，同样判超时——那正是**接引失败**的形状，
    ///    也恰恰是本机制最该自愈的场景（设计文档 §3.6.3 的场景表第 2 行）。
    function _checkFrameTimeouts() {
        for (var i = 0; i < _monitorIds.length; i++) {
            var id = _monitorIds[i]
            var since = cryptoController.msSinceLastFrame(id)
            if (since < 0 || since > _frameTimeoutMs) {
                cryptoController.reRegisterDevice(id)
            }
        }
    }

    /// ③ **成功**后由骨架发 `routeTasksUpdated` 触发；推**指令权**名单（起/终维，§2.7.2 h）。
    ///
    /// ‼️ 与 `_pushMonitorDevices` 是**两份不同的清单**，绝不合并——差别与各自的失败形状见
    ///    `OpsCommon.initiatorDeviceIds` 的头注：那份管 80005 登记（本端名册上的**全部**飞机，
    ///    掉了就集体掉线），本份管建链权（**当前**签入的那一架，错了就两端同时说话）。
    ///
    /// ‼️ **每轮整份替换**，不能塞进"清单变了才推"的 diff：`landing_accepted` 能在行的集合
    ///    **完全不变**时翻转（降落站签入那一刻本端就该让出）⇒ 靠 diff 判必漏这一格。
    /// ⚠️ 失败时不推（`routeTasksUpdated` 本来就不发），理由与 `_pushMonitorDevices` 同：
    ///    把"请求失败"当成"本端不持有任何一架的指令权"会让本端在监控员阶段**静默让出**上行权，
    ///    而失败原因可能只是一次网络抖动（§3.5.4）——那时本端仍该说话。
    function _pushInitiatorDevices() {
        // ‼️ 与登记名册**共用同一个异常闸**（`deviceRowsAreAnomalous`）：全非法行集会算出
        //    空名单，而 `CryptoController::setInitiatorDevices([])` 把它当作**有效结论**
        //    （`_initiatorScopeValid=true`、全拒），且当前不在 Standby 时会当场
        //    `returnToStandby()` —— 一次脏响应就会打断在飞链路。数据源异常 ≠ 责任方消失。
        if (OpsCommon.deviceRowsAreAnomalous(romView._routeDevices)) {
            OpsCommon.warnDeviceIdAnomaly(romView._routeDevices.length)
            return
        }
        var _initIds = OpsCommon.initiatorDeviceIds(romView._routeDevices)
        cryptoController.setInitiatorDevices(_initIds)
    }

    // ③ 每次**成功**后推清单（§3.5.3）。⚠️ 不能挂在 `onPolled` 上：`_poll()` 发出信号时
    // ③ 的异步响应还没回来，那时读到的是**上一轮**的 devices，首拉时更是空的。
    // ⚠️ 两份清单**同一次**推：登记集合与指令权名单取自**同一份** `_routeDevices` 快照，
    //    分两个处理器读会让两者可能落在不同轮次上（指令权名单与登记集合短暂不一致）。
    // ‼️ 顺序**不可颠倒**：`setMonitorDevices` 会触发取密钥/登记（异步的），而
    //    `isInitiatorFor` 在**首次**推名单之前是 **fail-open**（`_initiatorScopeValid`
    //    为假 ⇒ 任何有密钥的 deviceID 都放行）。先推登记集合，就会留下一段"密钥到了、
    //    名单还没到"的窗口——那窗口里本端会对**整份名册**开闸，而不只是签入的那一架。
    //    先推指令权名单把这个窗口压成零。
    onRouteTasksUpdated: {
        _pushInitiatorDevices()
        _pushMonitorDevices()
    }
    // 超时检查与轮询同相、每 2s 一次（§3.6.2）：**即使 ③ 失败也要跑**——超过阈值收不到帧
    // 正是它要自愈的场景，而那种时刻 ③ 往往也在失败。
    onPolled: _checkFrameTimeouts()

    /// 回航流程（2026-11-07）：`OpsShell` 只提供骨架（HTTP / 轮询）与实例；
    /// 取飞机必须由本视图注入 —— `_vehicleForTask` 是本文件私有的匹配逻辑。
    /// ⚠️ 本视图不持有 `OpsRouteSync`，`routeResetFn` 保持 null（没有原航线轮询要停）。
    Component.onCompleted: {
        returnFlow.vehicleFn = function (task) { return romView._vehicleForTask(task) }
    }

    /// 卡片上的「应急情况处理」菜单（用户 2026-11-06）。
    /// 2026-11-07：`RESUME` 与 `RETURN` 已接线；其余两项仍是 UI 壳，明确告诉用户"尚未接入"。
    /// 这不是多余的提示——在应急处置里，点了没反应的菜单项会被当成"指令已下发"，
    /// 那正是本项目反复防的那类"谎报成功"。
    /// ⚠️ 其余两项接线时按 `action` 分派，两条链路各不相同：
    ///    · `RETURN`  → 选点流程（`OpsReturnFlow.begin`）：查候选 → 选点 → 写库 →
    ///      构造倒序航线并上传。写库与上传都在流程内完成；**不发 RTL**。
    ///    · `DIVERT`  → `POST /tasks/:id/divert` 需要备降场 `site_id` + 经纬度；而"生成并
    ///      上传到备降站点的续飞航线"在设计稿 §6.1-g 里仍是**未实现缺口**——只调后端
    ///      而天上不飞，同样是谎报成功。
    ///    · `EMERGENCY_LANDING` → `POST /tasks/:id/disposition`（带实时位置）；发给飞机的
    ///      载体是本系统扩展 80000–80003，格式尚待补充。
    function _onEmergencyAction(task, action) {
        if (action === "RESUME") {
            romView._beginResumeConfirm(task)
            return
        }
        if (action === "RETURN") {
            // `returnFlow` 由 `OpsShell` 以 `property alias` 暴露；RomView 是它的子视图，直接可见。
            // 若将来 RomView 被提到独立窗口导致作用域断开，改为在实例化时注入回调。
            returnFlow.begin(task)
            return
        }
        var labels = {
            "RESUME":            qsTr("继续完成航线任务"),
            "RETURN":            qsTr("回航"),
            "DIVERT":            qsTr("备降"),
            "EMERGENCY_LANDING": qsTr("迫降")
        }
        var label = labels[action] !== undefined ? labels[action] : action
        QGroundControl.showMessageDialog(romView,
            qsTr("「%1」尚未接入").arg(label),
            qsTr("数据库与飞机均未做任何改动。")
            + qsTr("\n任务 %1 仍在原航线上。")
                .arg(task && task.task_no ? task.task_no : "—"))
    }

    /// 打开 RESUME 确认框（§5.1「确认框」：先弹框、不直接发指令）。
    /// 菜单项置灰时本就点不到这里，但仍重查一次 `_resumeAvailable`：菜单可能已开着而
    /// 状态在打开瞬间变化（1s 刷新周期内）。
    function _beginResumeConfirm(task) {
        if (!romView._resumeAvailable(task)) {
            QGroundControl.showMessageDialog(romView, qsTr("无法继续任务"),
                qsTr("当前条件不满足（异常状态已消失、模式已变化或链路中断）。\n"
                     + "数据库与飞机均未做任何改动。"))
            return
        }
        romView._resumePendingTask = task
        resumeConfirmDialog.open()
    }

    /// 确认框里「继续任务」：**先写库、写成功后才发 `AUTO_MISSION`**（2026-11-07 定）。
    ///
    /// 失败语义（§5.1「回执与失败」，逐字实现）：
    ///   · 写库失败 ⇒ 不发指令、不进入抑制期，提示"本次未生效、指令未发出"；
    ///   · 指令未发出（库已写）⇒ 记录保留为一次尝试，提示"记录已写、指令未发出"；
    ///   · 发送成功后 ⇒ 进入 n 秒抑制期，菜单置灰；是否生效由模式回读 + 异常状态判定。
    function _execResume() {
        var task = romView._resumePendingTask
        romView._resumePendingTask = null
        if (!task) return
        // 确认框打开期间条件可能已经变化（飞机恢复、链路断开、模式被改）⇒ 重查。
        // 此刻若照原样发出去，就可能把一架已经恢复的飞机再切一次模式。
        if (!romView._resumeAvailable(task)) {
            QGroundControl.showMessageDialog(romView, qsTr("继续任务已取消"),
                qsTr("等待确认期间条件已变化（异常状态消失、模式改变或链路中断），本次指令未发出。\n"
                     + "数据库未做任何改动。"))
            return
        }
        // `_resumeAvailable` 刚刚用**当前行**判过（指令权/状态/处置方式），这里取同一份当前行
        // 传给后续步骤；不要退回上面那个渲染快照。
        var fresh = romView._freshTask(task)
        if (!fresh) return
        var v = romView._vehicleForTask(fresh)
        if (!v) return   // _resumeAvailable 已保证非空，这里只做防御
        // `mode_before`：QGC 把载具的模式名映射成后端白名单值（不用字面量比较，理由见 _isAnomalyMode）。
        var modeBefore = (v.flightMode === v.rtlFlightMode) ? "auto_rtl" : "auto_loiter"
        var st = romView._resumeStates[Number(fresh.device_id)]
        var body = {
            mode_before: modeBefore,
            // `missionManager` / `currentIndex` 由 2026-11-07 的 Q_PROPERTY 暴露（此前 QML 够不到）。
            // 读不到时送 -1：后端允许"QGC 尚不知道当前序号"，恢复本身不依赖它。
            mission_seq: (v.missionManager && typeof v.missionManager.currentIndex === "number")
                         ? v.missionManager.currentIndex : -1,
            note: qsTr("监控员确认异常原因已解除，继续原航线任务"),
            telemetry_at: new Date().toISOString()
        }
        if (st && st.anomalySince > 0) body.anomaly_since = new Date(st.anomalySince).toISOString()
        if (v.coordinate && isFinite(v.coordinate.latitude) && isFinite(v.coordinate.longitude)
                && v.coordinate.latitude !== 0) {
            body.lat = v.coordinate.latitude
            body.lon = v.coordinate.longitude
        }
        var seq = ++romView._resumeRequestSeq
        romView._resumeRequestPending = true
        resumeRequestTimer.restart()
        romView._post("/api/tasks/" + fresh.task_id + "/resume", body, function(status, data) {
            // 超时兜底已经向用户报过"未确认、指令未下发" ⇒ 迟到的响应一律丢弃。
            // （若此时再补发 AUTO_MISSION，用户刚被告知"没发"，天上却发了。）
            // ‼️ 判代次而不只判 pending：超时后用户立刻重试时，第 1 次的迟到 200 会在
            //    第 2 次在途期间到达，只判 pending 会把它当第 2 次的成功 ⇒ 发两次指令。
            if (seq !== romView._resumeRequestSeq) return
            romView._resumeRequestPending = false
            resumeRequestTimer.stop()
            if (status === 0) {
                // 请求根本没发出去，或响应在网络上丢了：两种情况下我们都**不知道**库写了没有，
                // 不能替服务端担保"未做改动"。
                QGroundControl.showMessageDialog(romView, qsTr("继续任务未确认"),
                    qsTr("与服务器的通信中断，无法确认写库结果，AUTO_MISSION 未下发。\n"
                         + "请先确认飞机仍处于返航/悬停，再决定是否重试（重试会再写一条记录）。"))
                console.warn("RomView 继续任务无响应（status 0）")
                return
            }
            // ‼️ 成功 = 2xx **且回执明确说记录已落**。中间层 200 HTML 错误页、被截断的
            //    JSON、`operation_logged:false` 都必须按"写库结果未确认"处理——否则就是
            //    在库没写的情况下发指令，事后审计断链且界面不报错。
            if (status !== 200 || !data || data.operation_logged !== true) {
                if (status >= 400 && status < 500) {
                    // 4xx = 服务端**明确拒绝**，此时"库未写、指令未发"才是确定的。
                    QGroundControl.showMessageDialog(romView, qsTr("继续任务未生效"),
                        ((data && (data.error || data.reason)) || ("HTTP " + status))
                        + qsTr("\n本次未生效，指令未发出。"))
                } else {
                    // 5xx / 2xx 但不合契约：提交结果**未知**（COMMIT 报文丢失时服务端也可能
                    // 已提交），不许替服务端担保"未做改动"，也不许发指令。
                    QGroundControl.showMessageDialog(romView, qsTr("继续任务未确认"),
                        qsTr("服务器未确认操作记录已写入（HTTP %1），AUTO_MISSION 未下发。\n"
                             + "数据库是否写入未能确认，请核对后决定是否重试（重试会再写一条记录）。")
                            .arg(status))
                }
                console.warn("RomView 继续任务失败:", status, JSON.stringify(data))
                return
            }
            // 写库成功后才发 AUTO_MISSION。载具可能在写库往返期间掉线 ⇒ 重新定位。
            var live = romView._vehicleForTask(fresh)
            if (!live) {
                QGroundControl.showMessageDialog(romView, qsTr("记录已写、指令未发出"),
                    qsTr("未找到该任务无人机（deviceID %1）的连接。\n"
                         + "操作记录已写入；是否重试由你决定（重试会再写一条记录）。")
                        .arg(fresh && fresh.device_id ? fresh.device_id : "—"))
                return
            }
            if (romView._vehicleLinkLost(live)) {
                QGroundControl.showMessageDialog(romView, qsTr("记录已写、指令未发出"),
                    qsTr("链路中断，AUTO_MISSION 未下发。\n"
                         + "操作记录已写入；是否重试由你决定（重试会再写一条记录）。"))
                return
            }
            // ‼️ 写库往返期间模式可能已经变化（异常自解、操作员/别人切了 Land/Offboard 等）。
            //    此刻仍照原样发 AUTO_MISSION 会**覆盖当前模式**——尤其是降落/迫降途中被切回
            //    航线任务，后果比"少发一条指令"严重得多。条件已变 ⇒ 记录保留、指令不发。
            if (!romView._isAnomalyMode(live)) {
                QGroundControl.showMessageDialog(romView, qsTr("记录已写、指令未发出"),
                    qsTr("写库期间飞机的模式已变化（不再是返航/悬停），AUTO_MISSION 未下发，以免覆盖当前模式。\n"
                         + "操作记录已写入；是否重新处置由你决定（重试会再写一条记录）。"))
                return
            }
            // ‼️ 用 `setFlightModeChecked()` 而不是给 `flightMode` 属性赋值：后者 (void) 有两处
            //    静默失败——模式名不在本固件模式表（非 PX4 的 `missionFlightMode` 是空串）、
            //    或真正发帧前 primary link 消失——都会"看着成功"，让抑制期和之后的失败提示
            //    建立在一个根本没发出去的指令上。返回 false ⇒ 一个字节都没发，按"记录已写、
            //    指令未发出"处理，**不进入抑制期**。
            if (!live.setFlightModeChecked(live.missionFlightMode)) {
                QGroundControl.showMessageDialog(romView, qsTr("记录已写、指令未发出"),
                    qsTr("无法发送模式指令（当前固件不支持该模式，或链路已在发送前断开），AUTO_MISSION 未下发。\n"
                         + "操作记录已写入；是否重新处置由你决定（重试会再写一条记录）。"))
                return
            }
            // 指令已发出；是否生效由模式回读 + 异常状态判定。
            // ⚠️ 抑制期**只在指令发出后**开始：写库失败或上面几条提前返回时不得抑制。
            romView._beginResumeSuppression(Number(live.deviceID()))
            romView._poll()   // 库已写：卡片/任务数据立即刷新
        })
    }

    /// 进入 n 秒抑制期：期内收到的 RTL/悬停报文不置位，菜单保持置灰。
    /// `_resumeRevision++` 让 `enabled` 绑定**立刻**重估（不等下一次 1s tick）。
    function _beginResumeSuppression(deviceID) {
        var states = romView._resumeStates
        var st = states[deviceID]
        if (!st) {
            st = { active: false, lastAnomalyAt: 0, anomalySince: 0,
                   suppressedUntil: 0, linkWasLost: false, failNotified: false,
                   linkNotified: false, sawNormalSinceCommand: false }
            states[deviceID] = st
        }
        st.suppressedUntil = Date.now() + romView.resumeAnomalyWindowMs
        st.active = false
        st.linkWasLost = false
        st.failNotified = false
        st.linkNotified = false
        st.sawNormalSinceCommand = false
        romView._resumeRevision++
    }

    //=========================================================================
    // 右栏内容（设计文档 §4.1）
    //=========================================================================
    // 中段（航班列表）= （异常航班 ∪ 待我签入）（置顶常驻）∪ 在航航班，按 task_id 去重。
    // ‼️ 第 2 节的口径随选中状态变（用户 2026-09-23 定）：**选中某航线 ⇒ 只列该航线的；
    //    一条都没选中 ⇒ 列全部在航**（"所有在航无人机"）。
    // ‼️ 判据住 `OpsCommon.middleSectionTasks`（纯函数，可测），本视图只传实参——
    //    写成这里的 inline function 的话，QML 测试基础设施**测不到**它（§2.3）。
    // ‼️ 第三个实参 `_handoverById` 是 2026-09-24 裁定 丙-2 加的：置顶判据问的是
    //    「该谁动手」⇒ 必须走**待办**口径（`/handovers/pending`，按角色过滤），
    //    不能用任务自带的 `handover`（那是**事实**口径）。见 `awaitingMyCheckin`。
    // ‼️ 这里**只取拍平后的单一数组**。2026-09-29 曾另有一个 `_panelSplit`（调
    //    `middleSectionSplit`）专供"两节分开渲染"的分段标题用，同日段头被用户裁定删除
    //    ⇒ `_panelSplit` 一并删掉：它**唯一**的消费点就是传 `sectionBreak`。
    //    ⚠️ 删 `_panelSplit` **不影响** `_panelTasks` 的取值：写反成 `second.concat(first)`
    //      会让异常航班沉底，而"异常常驻置顶"正是裁定 ⑥ 的核心 —— 这一条由
    //      `tst_OpsCommon.qml` 的
    //      `test_middleSectionSplit_flattensToSameOrderAsMiddleSectionTasks` 钉住。
    //    ⚠️ 分节**行为**也没有消失：`middleSectionTasks` 内部调的就是 `middleSectionSplit`，
    //      第 1 节照旧不受航线选中过滤。删掉的只是"把两节分开渲染"，不是分节本身。
    readonly property var _panelTasks: OpsCommon.middleSectionTasks(romView._routeTasks,
                                                                   romView._selectedRouteId,
                                                                   romView._handoverById)
    // 段头 1（「异常 / 待我签入（置顶常驻）」）、段头 2（「全部在航航班」/「选中航线 XX 的
    // 航班」）与它们依赖的 `_selectedRouteName` 全部已删：用户 2026-09-29 裁定「两行段头全删」。
    // ⚠️ 后果（用户明示接受）：置顶节为什么置顶、以及第 2 节当前是不是"选中航线的航班"，
    //    界面上都不再有文字解释。
    // 陈旧提示条上的时刻（③ 上次**成功**的时刻）
    readonly property string _routeUpdatedText: romView._routeUpdatedAt
                                               ? Qt.formatTime(romView._routeUpdatedAt, "hh:mm:ss") : "—"

    // 右栏三段的**固定比例**（用户 2026-09-29 终裁：航线 : 航班 : 告警 = 40 : 50 : 10）。
    // ‼️ 三者之和必须恰好是 1.0：`ColumnLayout` 先按 `preferredHeight` 分配、再按
    //    `fillHeight` 摊差额，和不等于 1 时实际比例就不再是这里写的数——症状是
    //    "改了系数界面没变"，**不报错**。
    readonly property real _ratioRoute: 0.4
    readonly property real _ratioTask:  0.5
    readonly property real _ratioAlert: 0.1
    // 三段轮廓线的颜色。取比卡片描边（`#2a3a55`）亮一档的蓝灰：轮廓是**区域**的边界，
    // 与区域内卡片的边界同色会让两层框糊在一起，反而看不出分了几块。
    readonly property color _sectionOutlineColor: "#3d5175"
    // 轮廓线内缘到卡片之间的左右留白（用户 2026-09-29：「轮廓线里左右边界留 2-3 个像素即可，
    // 航线卡片和航班卡片也是如此」）。
    // 实际水平留白 = 面板的 `anchors.margins`（= 2，见下三处）**加上**这两个数 ⇒ 这里取 0，
    // 让"离框几像素"只有一个决定者。两处各留一点会**相加**，且改一处看不出预期效果。
    // ‼️ 只在本视图覆盖，**不动骨架的 `_taskCardMargin` / `_taskCardRightGap`**：
    //    前者被站点视图的机位边距 `_slotMargin` 反过来绑着（用户 2026-09-18「机位间隔参照
    //    任务列表中两个卡片的间隔」）⇒ 改它会连锁改动站点视图的**机位图版式**，那与本次报障无关。
    //    RomView 本来就在逐处显式传这两个参数，覆写是它既有的接线方式。
    // ⚠️ 骨架那个 `_taskCardRightGap: 20` 的注释写着「来历不明的右侧留白，只保持原值」，
    //    并记着用户曾要求"不能挤到右侧的滚动条"。本次用户明确要求压缩它，故本视图不再保留那 20。
    //    该注释里已实测过「本模块没有任何 ScrollBar」，压到 0 不会挤到谁。
    readonly property real _panelCardMargin: 0
    readonly property real _panelCardRightGap: 0

    // 槽 ①（commandBarExtras）本视图不填，见文件头注释。
    rightPanelContent: Component {
        ColumnLayout {
            id: romRight
            anchors.fill: parent
            // 段与段之间的分隔（用户 2026-09-29：「两个功能段的轮廓线之间应该有几个像素的分隔」）。
            // ‼️ 原值 0 ⇒ 相邻两框的 1px 边框**贴在一起**，看起来是一条 2px 的粗线，
            //    读起来不像"两段之间"、像"这一段的框画重了"。
            // ⚠️ `ColumnLayout.spacing` 的两处间隙（6×2 = 12）是**从总高里扣**的：
            //    三段 `preferredHeight` 之和是右栏高的 100%，扣掉 12 之后按比例缩到 98.5%。
            //    比例关系不变，只是每段各少约 5px——这正是要的"分隔"。
            spacing: 6

            //-----------------------------------------------------------------
            // 数据陈旧 / 加载失败 提示条（§2.4）。成功一次即自动消失。
            // ‼️ 失败**不清空**地图与列表（陈旧好过空白：地图上飞机消失会被误读成"飞机没了"），
            //    但必须让用户**看得见**它陈旧了——静默陈旧的界面与正常的界面长得一样。
            //-----------------------------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 10; Layout.rightMargin: 10; Layout.topMargin: 6
                implicitHeight: staleText.implicitHeight + 8
                radius: 3
                color: romView._routeTasksStale ? "#5a2020" : "#4a3a10"
                border.color: romView._routeTasksStale ? "#ff3b3b" : "#ffc107"
                border.width: 1
                visible: romView._routeTasksStale || romView._routeLoadError !== ""
                Text {
                    id: staleText
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                    anchors.leftMargin: 6; anchors.rightMargin: 6
                    wrapMode: Text.Wrap
                    color: "#ffd9a0"; font.pixelSize: Math.round(11 * ScreenTools.uiTextScaleFactor)
                    text: romView._routeLoadError !== ""
                          ? romView._routeLoadError
                          : qsTr("数据更新于 %1，当前不可达").arg(romView._routeUpdatedText)
                }
            }

            //-----------------------------------------------------------------
            // 三段各包一层 `Rectangle` 只做一件事：**画轮廓线**
            //（用户 2026-09-29：「可以把各部分的标题去掉……可以使用轮廓线把各部分分别勾勒出来」）。
            // ⚠️ 边框**不写进三个面板内部**：那三个面板是站点视图共用的（`OpsView.qml` 也在用），
            //    框是"右栏怎么排版"的决定，属于使用方。面板内部加框会让站点视图跟着多两条线。
            // ‼️ 高度全部是**固定比例**（见 `_ratioRoute` 等三个常量），不让内容撑：
            //    内容一变（告警来一条、航班少一条）三段就互相挤，整个右栏跟着跳。
            //    代价是内容少的段留白——这是用户在"固定比例 / 随内容"两选项里**明示选定**的取舍。
            // ‼️ 三个 `fillHeight` 都得是 true：`ColumnLayout` 先按 `preferredHeight` 分配，
            //    再把差额按 `fillHeight` 摊平；缺了它，三段之和凑不满右栏时底部会空一条。
            // ‼️ 旧代码里上段的 `Layout.maximumHeight: romRight.height * 0.5` 已删。它是
            //    "上段最多占一半"，而中段**只有** `fillHeight`、没有最小高度 ⇒ 航线一多就把
            //    航班列表挤到只剩一张卡（正是 2026-09-29 报障里中段只剩一张卡的成因之一）。
            //    份额写死之后这个挤法不再可能。
            //-----------------------------------------------------------------

            // 上段：航线列表（常驻）。
            // ‼️ 「常驻」= **不看该航线有没有航班**（裁定 ③）——数据源是 ① 的缓存，
            //    不是 ③ 的轮询结果。
            Rectangle {
                id: routeSectionBox
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: romRight.height * romView._ratioRoute
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                color: "transparent"
                border.color: romView._sectionOutlineColor
                border.width: 1
                radius: 4

                RouteListPanel {
                    id: routeListPanel
                    anchors.fill: parent
                    anchors.margins: 2
                    routes: romView._routeRows
                    ready: romView._routeCacheReady
                    selectedRouteId: romView._selectedRouteId
                    // 选中航线（骨架里 toggle：再点一次取消）；地图的 L2 由骨架按同一状态点亮
                    onRouteSelected: function(routeId) { romView.selectRoute(routeId) }
                    // 与中段同一个面板参数，两段的卡片因此天然同宽同距
                    // （留白取本视图的 `_panelCardMargin` / `_panelCardRightGap` = 0，见其定义）
                    cardMargin: romView._panelCardMargin
                    cardRightGap: romView._panelCardRightGap
                    cardGap: romView._taskCardGap
                    // 航线卡边框＝浅蓝（用户 2026-10-06：「RomView 的右边栏中的航线列表和
                    // 任务列表也加一个浅蓝色的边框，如刚刚你在OpsView中做的那样」）。
                    // 选中蓝仍然优先（见 `RouteListPanel.border.color`）。
                    cardBorderColor: "#6f9fd8"
                }
            }

            // 中段：航班列表（异常 ∪ 待我签入 置顶常驻 ∪ 选中航线的航班）
            Rectangle {
                id: taskSectionBox
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: romRight.height * romView._ratioTask
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                color: "transparent"
                border.color: romView._sectionOutlineColor
                border.width: 1
                radius: 4

                TaskListPanel {
                    id: taskListPanel
                    anchors.fill: parent
                    anchors.margins: 2
                    // 本视图此前没有给这个面板 id（不用它的内部状态）；交接弹框的锚点要按 `task_id`
                    // 回列表里找卡片，才需要它。见下面 `Component.onCompleted`。
                    // 交接弹框的位置锚点（`OpsShell._handoverAnchorFn`）。与站点视图那一份对称——同一个
                    // 弹框住骨架、两个视图各注入一次自己的求值闭包。`null` 与负数是两回事，见
                    // `TaskListPanel.cardBottomYForTask`。
                    Component.onCompleted: romView._handoverAnchorFn = function(taskId) {
                        var y = taskListPanel.cardBottomYForTask(taskId)
                        if (y === null) return -1
                        return taskListPanel.mapToItem(romView, 0, y).y
                    }
                    // ⚠️ 置顶**必须真的置顶**（判据见 `middleSectionSplit`），反过来第 1 节
                    //    **每一条都得自带徽标说明自己为什么在顶上**：异常航班走 `abnormalLabel`，
                    //    待签入走 `_awaitingMe` 那条警示条。
                    // ‼️ 表头 `headerText` 已删（用户 2026-09-29：「可以把各部分的标题去掉，
                    //    使用的都是专业培训的熟练人员」）。段头 1 逐字承担的那句置顶承诺也随之
                    //    只剩徽标本身——不再有文字解释，这是用户明示接受的代价。
                    // 分段标题（`sectionBreak` / `sectionTitleFirst` / `sectionTitleSecond`）
                    // 不再传：用户 2026-09-29 裁定「两行段头全删」。`_panelTasks` 本身仍是
                    // `middleSectionTasks` 的输出，两节的**拼接顺序**（异常 ∪ 待签入 在前）
                    // 一字未动——删的是渲染，不是分节。
                    // 「性质」= 本站相对航线的角色。监控员没有 `site_id` ⇒ 恒回「—」⇒ 隐藏。
                    showTaskNature: false
                    tasks: romView._panelTasks
                    handoverById: romView._handoverById
                    nowMs: romView._now
                    mySiteId: romView._mySiteId
                    selectedTaskId: romView._selectedTaskId
                    // 站点专属动作组（起飞/降落/停泊/指定机位）在监控员视图**不出现**；
                    // 监控员自己的动作是"移交降落指挥"，由 isRouteMonitor 开（见 TaskListPanel:247）
                    showSiteActions: false
                    isRouteMonitor: romView._isRouteMon
                    // 与站点视图同一个面板，但留白**不共用**：本站的框是 RomView 独有的，
                    // 卡片要贴着框走（`_panelCardMargin` / `_panelCardRightGap` = 0 + 面板
                    // `anchors.margins` 2 ⇒ 离框 2px）；站点视图没有框，仍用骨架的 10 / 20。
                    // ⚠️ 两个视图各自决定留白，改一处**不会**影响另一处——这正是本次要的
                    //   （骨架那份还牵着机位图边距，动不得）。
                    cardMargin: romView._panelCardMargin
                    cardRightGap: romView._panelCardRightGap
                    cardGap: romView._taskCardGap
                    // 任务卡边框＝浅蓝，与上面航线列表、以及 `OpsView` 同一色值（用户 2026-10-06）。
                    // ⚠️ 三处字面量各自独立，改色值要一起改。
                    cardBorderColor: "#6f9fd8"
                    // 点整项由骨架写 _selectedTaskId 并发 taskSelected（机位同步是站点视图的事）
                    onTaskSelected: function(task) { romView.selectTask(task) }
                    onHandoverProposed: function(taskId, phase) { romView._proposeHandover(taskId, phase) }
                    onHandoverCancelRequested: function(handoverId) { romView._cancelHandoverWithFeedback(handoverId) }
                    // 【签入】接管本航班（ROUTE 相位）。**不弹窗**（同族先例见 OpsView 那一处注释）；
                    // 失败反馈走 `_checkinFromCard`——它住在骨架里，本视图因此不必自备错误提示机制
                    // （本视图除了下面那条陈旧提示条之外没有任何弹窗设施）。
                    // ⚠️ `task` 要收：`_checkinFromCard` 用它回查待办名单，决定失败后还有没有可重试
                    //    的对象。上面那条 `handoverCancelRequested` 少收一个参数是合法的（QML 允许
                    //    处理器少声明实参），但那是因为它不需要；不要照抄成习惯。
                    onCheckinRequested: function(handoverId, task) { romView._checkinFromCard(handoverId, task) }
                    // 「继续完成航线任务」的置灰判据（异常派生状态 / 模式 / 链路 / disposition）。
                    // 注入函数而不是值：面板只消费，判据唯一实现在本视图（`_resumeAvailable`）。
                    resumeAvailable: romView._resumeAvailable
                    // 「应急情况处理」菜单的四项（用户 2026-11-06）。`RESUME` 已接线
                    // （`_onEmergencyAction` → 确认框 → 先写库 → 切 AUTO_MISSION）；其余三项
                    // 仍只给出"尚未接入"的明确提示，不写库、不下发指令。
                    onEmergencyActionRequested: function(task, action) {
                        romView._onEmergencyAction(task, action)
                    }
                }
            }

            // 下段：机载告警（§6）
            // ‼️ **不要**把 `devices` 当成"该显示哪些告警"的判据：飞机落地转 PARKED 后会从
            //    `devices[]` 里消失，但它此刻若还在发 `STATUSTEXT`，那一行恰恰最该被看见。
            //    `devices` 在这里**只用来把 `device_id` 翻译成 `uav_no` 与 `task_no`**（§6.2 步骤 4）。
            // ‼️ 高度份额由**这里**的 `_ratioAlert` 给（10%），面板内部那个写死的
            //    `_listHeight := ScreenTools.defaultFontPixelHeight * 15` 已删：
            //    两个地方各定一次高度，改一处看不出效果（面板内部那个会赢），改错了也不报错。
            // ⚠️ 10% 在 971px 高的窗口上约 77px，扣掉内边距与实际行高（约 15–18px/行）
            //    大致只装得下一行半 ⇒ **两条告警就要滚动**。这是用户选定固定比例时已知的代价。
            Rectangle {
                id: alertSectionBox
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: romRight.height * romView._ratioAlert
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                Layout.bottomMargin: 6
                color: "transparent"
                border.color: romView._sectionOutlineColor
                border.width: 1
                radius: 4

                AlertListPanel {
                    anchors.fill: parent
                    anchors.margins: 2
                    devices: romView._routeDevices
                }
            }
        }
    }

    //-------------------------------------------------------------------------
    // 「继续完成航线任务」确认框（设计稿 §5.1「确认框」，用户 2026-11-07）
    //-------------------------------------------------------------------------
    // 只对 RESUME 生效；退路/改降/迫降三项不加确认框（将来接线时另行决定；
    // 将来若加，它们的确认按钮按 2026-11-07 的语义必须是**红**）。
    // 版式复用 `OpsDialog` 深色皮肤；按钮语义见 `OpsDialogButton.qml`（2026-11-07 裁定）：
    // 继续任务 = 正常业务动作 ⇒ 绿；取消 ⇒ 白。
    // ⚠️ 定位不贴任务卡片：菜单信号不带卡片坐标，本视图也没有 `_confirmAnchorY` 这套锚点；
    //    直接垂直居中（与 `landBlockDialog` 的"无锚点来源"同款）。
    OpsDialog {
        id: resumeConfirmDialog
        parent: romView
        width: Math.min(Math.round(Math.max(romView.rightPanelWidth, 320) * ScreenTools.uiTextScaleFactor),
                        Math.round(romView.width * 0.95))
        x: romView.width - width
        y: (romView.height - height) / 2
        modal: true
        title: qsTr("继续完成航线任务")

        ColumnLayout {
            width: parent.width
            spacing: 8
            Text {
                Layout.fillWidth: true
                color: "#e6edf7"; font.pixelSize: Math.round(13 * ScreenTools.uiTextScaleFactor)
                wrapMode: Text.Wrap
                // 三行条目，与 `actionConfirmDialog` / `slotDialog` 的条目名逐字一致。
                // ⚠️ 模式名从**载具当前属性**取，不写字面量（中文界面会翻译）。
                text: {
                    var t = romView._resumePendingTask
                    if (!t) return ""
                    var v = romView._vehicleForTask(t)
                    var modeLabel = "—"
                    if (v && v.flightMode === v.rtlFlightMode) modeLabel = qsTr("返航（RTL）")
                    else if (v && v.flightMode === v.pauseFlightMode) modeLabel = qsTr("悬停")
                    return qsTr("飞行任务：%1\n无人机：%2\n当前异常：%3")
                        .arg(t.task_no ? t.task_no : "—")
                        .arg(t.uav_no ? t.uav_no : "—")
                        .arg(modeLabel)
                }
            }
            Text {
                Layout.fillWidth: true
                // 亮琥珀 `#ffc107` —— 深绿底 `#0f2f2c` 上 8.80:1（`OpsDialog.qml` 文件头的实算表）。
                color: "#ffc107"; font.pixelSize: Math.round(12 * ScreenTools.uiTextScaleFactor)
                wrapMode: Text.Wrap
                // 必须写明后果（§5.1）：恢复是按机上 `current_seq` 继续，可能掉头飞回已过航点。
                text: qsTr("将切回原航线任务：飞机飞回离开时的下一个航点，可能掉头飞回已经过的航点。")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(16 * ScreenTools.uiTextScaleFactor)
                Item { Layout.fillWidth: true }
                // 绿 = 继续任务（正常业务流程，非应急/救济）
                OpsDialogButton {
                    text: qsTr("继续任务")
                    kind: "primary"
                    onClicked: { resumeConfirmDialog.close(); romView._execResume() }
                }
                // 白 = 取消
                OpsDialogButton {
                    text: qsTr("取消")
                    kind: "cancel"
                    onClicked: { romView._resumePendingTask = null; resumeConfirmDialog.close() }
                }
            }
        }
    }
}
