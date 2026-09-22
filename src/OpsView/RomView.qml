import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// @brief 飞行监控主界面 —— **航线监控员（ROUTE_MONITOR）视图**
/// 设计见 docs/qgc/飞行监控主界面设计.md。
///
/// 与 `OpsView.qml`（站点操作员）是**并列的两个视图**，骨架/数据源完全相同——地图、右栏容器、
/// 命令条、底部状态栏、姿态仪/罗盘、轮询与全部 HTTP、交接弹框全在 `OpsShell.qml` 里。
/// 本文件只写两者**不同**的那部分，差异恰好两处：
///
///   1. `overviewView: "route"` —— 数据源参数，后端按**负责航线**过滤 IN_FLIGHT；
///   2. 右栏只放**任务列表**，没有机位平面图（监控员不调度机位）。
///
/// ‼️ 本视图连 `polled()`，但**只为接引链路**（§3.5.3/§3.6）：拉 ③ 端点推监控清单、
///    做每 2s 的超时定向重发。机位仍**不拉**——那是站点专属数据，监控员拉它没有消费者。
///    这正是骨架把 `polled()` 做成信号、而不是把机位一并塞进 `_poll()` 的原因。
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
    overviewView: "route"
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
    // 上次**成功**推送的清单与阈值。超时检查用它遍历；请求失败时**保留不动**（§3.5.4）。
    property var _monitorIds: []
    property int _frameTimeoutMs: 3000   // = CryptoController::DEFAULT_FRAME_TIMEOUT_MS

    /// 每次轮询拉一次 ③ 端点；**只有成功**才把清单与阈值推给 C++。
    /// ‼️ 失败时什么都不做——把"请求失败"当成"没有需要监控的飞机"会让登记集合
    ///    清空，全部飞机在 60s TTL 后集体掉线，而失败原因可能只是一次网络抖动（§3.5.4）。
    function _fetchMonitorDevices() {
        _get("/api/ops/route-tasks", function(status, data) {
            if (status !== 200 || !data || !Array.isArray(data.devices)) {
                // 失败 / 老后端 / 端点尚未部署（P1 未落地时走这一支）：
                // 保留上一次的清单，不推送、不清空
                return
            }
            var ids = data.devices.map(function(d) { return d.device_id })
            _monitorIds = ids
            _frameTimeoutMs = (typeof data.frame_timeout_ms === "number" && data.frame_timeout_ms > 0)
                              ? data.frame_timeout_ms
                              : 3000
            // ⚠️ 清单与阈值**同一次**传入：两个 setter 会造出"新阈值配旧清单"的中间态（§3.6.4）
            cryptoController.setMonitorDevices(ids, _frameTimeoutMs)
        })
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

    onPolled: {
        _fetchMonitorDevices()
        _checkFrameTimeouts()
    }

    //=========================================================================
    // 注入槽 ②：右栏中段 —— 任务列表（监控员视图的右栏**只有**这一块）
    //=========================================================================
    // 槽 ①（commandBarExtras）本视图不填，见文件头注释。
    rightPanelContent: Component {
        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            TaskListPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                headerText: qsTr("负责航线 · 执行中")
                // overview 已按负责航线过滤 IN_FLIGHT，原样返回，不再本地过滤
                tasks: romView._tasks
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
