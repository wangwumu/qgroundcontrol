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
///   2. 右栏两段（§4.1）：上段**航线列表（常驻）** + 中段**航班列表**，没有机位平面图。
///      ⚠️ 下段**机载告警**（§6）未做——它要先补一处 C++（`StatusTextHandler` 把结构化告警
///      暴露给 QML，§6.1），属于另一摊工作。
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
    // 数据源参数（吃进 GET /api/ops/overview?view=）。**不是**显示开关。
    // ⚠️ `view=route` 现已被本视图**降级为兜底**：它的判据是「任务 IN_FLIGHT 或存在 PENDING
    //    的航线移交」，与裁定 ③ 要求的「航线常驻、不看有没有航班」**不是一回事**（真库实测
    //    该端点恒回 0 条——全库没有 IN_FLIGHT 的任务）⇒ 右栏中段曾长期必然是空的。
    //    真正的数据源是本视图下面开的 `routeLayersEnabled`（① 缓存 + ③ 轮询）。
    overviewView: "route"
    // 开航线图层：骨架据此跑 §7.2 的首拉序列（① → ② → ③）、推监控清单、并把地图的
    // L1/L3 改吃航线缓存与 `devices`。**站点视图保持 false**，不受影响。
    routeLayersEnabled: true
    // `rightPanelWidth` **刻意不传**，用骨架缺省值 `_rightPanelMinW`（340）：本视图没有机位
    // 平面图，也就没有"按图所需宽在 340~510 之间伸缩"这回事。写这一行是为了让"为什么没有"
    // 有个落点，免得日后有人以为漏了。

    //-------------------------------------------------------------------------
    // 会话与身份
    //-------------------------------------------------------------------------
    // 读 roles 属性（NOTIFY rolesChanged）而非 hasRole() 方法：方法调用不注册 QML 绑定依赖，
    // 登录后才填充的 roles 不会触发重估 → 视图永不显示。indexOf 读属性值，登录后绑定自动更新。
    readonly property bool _isRouteMon: AuthController.roles.indexOf("ROUTE_MONITOR") >= 0

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

    // ③ 每次**成功**后推清单（§3.5.3）。⚠️ 不能挂在 `onPolled` 上：`_poll()` 发出信号时
    // ③ 的异步响应还没回来，那时读到的是**上一轮**的 devices，首拉时更是空的。
    onRouteTasksUpdated: _pushMonitorDevices()
    // 超时检查与轮询同相、每 2s 一次（§3.6.2）：**即使 ③ 失败也要跑**——超过阈值收不到帧
    // 正是它要自愈的场景，而那种时刻 ③ 往往也在失败。
    onPolled: _checkFrameTimeouts()

    //=========================================================================
    // 右栏内容（设计文档 §4.1）
    //=========================================================================
    // 中段（航班列表）的行集合 = 异常航班（置顶常驻）∪ 在航航班，按 task_id 去重。
    // ‼️ 第 2 节的口径随选中状态变（用户 2026-09-23 定）：**选中某航线 ⇒ 只列该航线的；
    //    一条都没选中 ⇒ 列全部在航**（"所有在航无人机"）。判据细节见 `middleSectionTasks`。
    // ‼️ 判据住 `OpsCommon.middleSectionTasks`（纯函数，可测），本视图只传实参——
    //    写成这里的 inline function 的话，QML 测试基础设施**测不到**它（§2.3）。
    readonly property var _panelTasks: OpsCommon.middleSectionTasks(romView._routeTasks,
                                                                   romView._selectedRouteId)
    // 陈旧提示条上的时刻（③ 上次**成功**的时刻）
    readonly property string _routeUpdatedText: romView._routeUpdatedAt
                                               ? Qt.formatTime(romView._routeUpdatedAt, "hh:mm:ss") : "—"

    // 槽 ①（commandBarExtras）本视图不填，见文件头注释。
    rightPanelContent: Component {
        ColumnLayout {
            id: romRight
            anchors.fill: parent
            spacing: 0

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
                    color: "#ffd9a0"; font.pixelSize: 11
                    text: romView._routeLoadError !== ""
                          ? romView._routeLoadError
                          : qsTr("数据更新于 %1，当前不可达").arg(romView._routeUpdatedText)
                }
            }

            //-----------------------------------------------------------------
            // 上段：航线列表（常驻）。
            // ‼️ 「常驻」= **不看该航线有没有航班**（裁定 ③）——数据源是 ① 的缓存，
            //    不是 ③ 的轮询结果。
            //-----------------------------------------------------------------
            RouteListPanel {
                id: routeListPanel
                Layout.fillWidth: true
                // 最多占右栏内容区的一半，超出滚动：常驻段**不能无界增长**，否则航线多的
                // 监控员会把中段的航班列表挤没。上限写**使用方**（这里）而不是面板内部——
                // 面板内部自己写 `height * 系数` 会与使用方给的高度形成自引用绑定。
                Layout.maximumHeight: romRight.height * 0.5
                headerText: qsTr("负责航线")
                routes: romView._routeRows
                ready: romView._routeCacheReady
                selectedRouteId: romView._selectedRouteId
                // 选中航线（骨架里 toggle：再点一次取消）；地图的 L2 由骨架按同一状态点亮
                onRouteSelected: function(routeId) { romView.selectRoute(routeId) }
                // 与中段同一个面板参数，两段的卡片因此天然同宽同距
                cardMargin: romView._taskCardMargin
                cardRightGap: romView._taskCardRightGap
                cardGap: romView._taskCardGap
            }

            //-----------------------------------------------------------------
            // 中段：航班列表（异常置顶常驻 ∪ 选中航线的航班）
            //-----------------------------------------------------------------
            TaskListPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                headerText: qsTr("航班列表 · 异常置顶")
                tasks: romView._panelTasks
                handoverById: romView._handoverById
                nowMs: romView._now
                mySiteId: romView._mySiteId
                selectedTaskId: romView._selectedTaskId
                // 站点专属动作组（起飞/降落/停泊/指定机位）在监控员视图**不出现**；
                // 监控员自己的动作是"移交降落指挥"，由 isRouteMonitor 开（见 TaskListPanel:247）
                showSiteActions: false
                isRouteMonitor: romView._isRouteMon
                // 与站点视图同一个面板、同一份左空位与间距——两个"决定者"会得到两种疏密。
                // 这几个数全部来自骨架，视图侧只绑不算，故两个视图天然同值。
                cardMargin: romView._taskCardMargin
                cardRightGap: romView._taskCardRightGap
                cardGap: romView._taskCardGap
                liveTelemetryWindowMs: romView._liveTelemetryWindowMs
                // 点整项由骨架写 _selectedTaskId 并发 taskSelected（机位同步是站点视图的事）
                onTaskSelected: function(task) { romView.selectTask(task) }
                onHandoverProposed: function(taskId, phase) { romView._proposeHandover(taskId, phase) }
                onHandoverCancelRequested: function(handoverId) { romView._cancelHandover(handoverId) }
            }
        }
    }
}
