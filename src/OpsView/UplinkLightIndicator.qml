import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

/// 加密**上行灯**（规范 §3.1.1 节末「界面灯」，2026-11-24 接线）。
///
/// 灯色直接来自 `CryptoController::uplinkLight()`，而它的 `tier` 又直接取自
/// `uplinkTier()`——阈值判据（2/5/10 s）全仓只有那一处（**灯与闸同源**，见该函数头注）。
/// 本文件只做呈现，**不写任何阈值**，也不从别的字段推灯色。
///
///   | 呈现                    | 含义                         | 常规上行 / 安全指令 |
///   | 灰点「—」               | 未建链（本表不约束）          | 由 §2.5.1 决定 / 同左 |
///   | **空心环**「无权限」     | 本端不是指令权方              | 不发 / 不发           |
///     ⚠️ 无权限时环色是链路档：若该机**从未**有过加密下行，环也是灰的（「灰空心环」）。
///        灰实心点（上表第一行）只出现在本端**有**权限、但该机尚未建链时。
///   | 蓝点「握手」             | 握手期（根帧 X 待发）         | 放行根帧 / 同左       |
///   | 绿点「正常」             | 下行 < 2 s                    | 放行 / 放行           |
///   | 黄点「延迟」             | 2–5 s                         | 放行（宽限） / 放行   |
///   | 琥珀点「暂停」           | 5–10 s                        | 暂停 / 盲发放行       |
///   | 红点「仅安全指令」       | > 10 s（已建链之后）          | 暂停 / 盲发放行       |
///
/// ‼️ **两维分开画**（2026-11-24 用户报「RomView 里没点、状态栏灰」后定）：
///    **实心/空心**表示本端有没有该机指令权（`uplinkDotStyle`）；**颜色**跟呈现档走
///    （`uplinkDotColor`：四档链路色 + 握手蓝，唯一绕回 `light.tier` 的是 `noPermission`）。
///    无权限时是空心环 + 环色=链路档，文字写「上行 无权限（链路正常）」。
///    改前无权限只能画兜底灰，监控员视图整屏无有效灯——那正是用户看到的现象。
///
/// ‼️ 「暂停 / 仅安全指令」是**我方主动静默**（下行锚过期），**不是链路故障**——提示语必须
///    把这一点说清，否则操作员会去查网络（规范 §3.1.1「界面必须区分」）。
/// ‼️ 灰灯也**不是故障**：未建链 = 「无加密链路、不适用」。
///
/// 挂载点（**只有这一处带文字**）：`OpsShell.qml` 的底部状态栏（紧挨「选中任务」），
/// 两个视图共用骨架 ⇒ 站点视图与监控视图都有；它描述的是**选中任务**那一架。
/// 多机总览靠另外两处**不带文字**的灯：任务卡片上的灯点（`TaskListPanel.qml`，每卡一架）
/// 与地图机号标签里的灯点（`OpsShell.qml` 两处 marker）——三者档位/颜色/画法同读
/// `OpsCommon.uplinkLightKey/Color/DotStyle/DotColor`，只有这一份映射。
/// ⚠️ 唯一有意的不一致：卡片与地图在 `off` / `gray` 档**不画**，状态栏这里仍画灰点配
///    「上行 —」——状态栏是常驻位，宁可留一个说明性的灰点，也不要忽隐忽现。
/// **不要**再往 `FlyViewToolBar` 里加一份：同一屏放两盏带字的灯，多机时两处还可能
/// 跟着不同的载具走。
RowLayout {
    id: root

    /// 本灯描述哪一架载具的加密上行。状态栏传 `_selectedVehicle`（选中任务对应的那架），
    /// **不能**用 `activeVehicle` 代替——多机同屏时两者可以不是同一架。
    property var vehicle: QGroundControl.multiVehicleManager.activeVehicle

    /// 是否显示灯点后面的文字（「上行 正常」等）。窄屏放不下时由状态栏置 false，
    /// 只留灯点；**悬停提示不受影响**（提示挂在根项上，见文件末）。
    /// ⚠️ 关掉文字会让本组件变窄——调用方若要预留宽度，必须按"文字开着"的最宽形态预留，
    ///    不要读本组件当前宽度（否则形成「去文字⇒变窄⇒又放得下⇒文字回来」的振荡）。
    property bool showText: true

    spacing: ScreenTools.defaultFontPixelWidth * 0.5

    readonly property int _deviceID: vehicle ? vehicle.deviceID() : 0

    // `uplinkLight()` 是纯调用（`Q_INVOKABLE`），QML 不会为它注册绑定依赖；而灯色
    // **只随时间衰减**（下行一停，2 s / 5 s / 10 s 三档会自己往下掉）⇒ 必须由下面的
    // Timer 按秒重读。同手法见 `OpsShell.qml` 的 `_now`。
    property var _light: ({ crypto: false, roleAllowed: false, handshake: false, tier: "gray" })

    function _refresh() {
        if (!vehicle || _deviceID <= 0 || typeof cryptoController === "undefined") {
            _light = { crypto: false, roleAllowed: false, handshake: false, tier: "gray" }
            return
        }
        _light = cryptoController.uplinkLight(_deviceID)
    }

    /// 呈现档：把「角色 / 握手」两维并进 tier，界面只认这一个字符串。
    /// ‼️ 档位与颜色都走 `OpsCommon`（任务卡灯点、地图灯点读的是同一组函数）——
    ///    本文件只补**文字**，不另写一套判据。
    function _key() {
        return OpsCommon.uplinkLightKey(_light)
    }

    /// 画法（实心/空心）与颜色分开取：颜色**永远按链路档**，无权限时也不退回兜底灰。
    function _style() {
        return OpsCommon.uplinkDotStyle(_key())
    }

    function _color() {
        return OpsCommon.uplinkDotColor(_light)
    }

    /// 文字与提示同样走 `OpsCommon`：文字用 `uplinkDotLabel`，提示用 `uplinkLightHint(呈现档)`
    /// （任务卡用的是 `uplinkDotHint` = 同一行文字 + 同一段说明，只是多拼了一行）。
    /// ‼️ 无权限时文字要同时报链路档，否则绿环配「上行 无权限」会被读成矛盾。
    function _text() {
        return OpsCommon.uplinkDotLabel(_light)
    }

    function _hint() {
        return OpsCommon.uplinkLightHint(_key())
    }

    visible: _key() !== "off" && root._deviceID > 0

    on_DeviceIDChanged: _refresh()
    Component.onCompleted: _refresh()

    Timer {
        interval:        1000
        repeat:          true
        // ‼️ 不能绑 `root.visible`：`visible` 自己依赖 `_light.crypto`，而它只有刷新后
        //    才为真 ⇒ 绑 visible 会让「隐藏 ⇒ 不刷新 ⇒ 永远隐藏」自锁。
        running:         root._deviceID > 0
        onTriggered:     root._refresh()
    }

    Rectangle {
        readonly property real _dotSize: Math.round(ScreenTools.defaultFontPixelHeight * 0.55)

        // 尺寸走 Layout.preferred*：本元素由 RowLayout 摆放，直接写 width/height 属
        // 未定义行为（布局重排时会被覆盖）。
        Layout.alignment:       Qt.AlignVCenter
        Layout.preferredWidth:  _dotSize
        Layout.preferredHeight: _dotSize
        radius:                 _dotSize / 2
        // 空心环 = 无发送权（环色仍按链路档）；实心 = 持指令权。
        color:                  root._style() === "hollow" ? "transparent" : root._color()
        border.width:           root._style() === "hollow" ? 2 : 0
        border.color:           root._color()
    }

    QGCLabel {
        Layout.alignment:   Qt.AlignVCenter
        visible:            root.showText
        text:               root._text()
    }

    HoverHandler { id: hover }

    ToolTip.visible:    hover.hovered
    ToolTip.delay:      300
    ToolTip.text:       root._hint()
}
