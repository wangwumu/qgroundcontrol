import QtQuick
import QtQuick.Controls

import QGroundControl.Controls

import "OpsCommon.js" as OpsCommon

/*!
    \qmltype OpsDialogButton
    \brief `OpsDialog` 家族的动作按钮（2026-11-07 用户裁定）。

    用户原话：「强烈建议用户点击且没有危险的用绿色（在正常业务流程内），
    取消保持白色，应急处理，救济处理或者其他有风险的处理按钮使用红色」。

    ⇒ 三档语义，**色值单点在 `OpsCommon.js` 的 `BUTTON_*_COLOR` 常量**
       （对话框按钮与任务卡按钮共用；改配色改那里，不会漏改某个实例）：

      | kind | 语义 | 何时用 |
      |---|---|---|
      | `primary` | 绿 | **推荐点击、且不危险**的正常业务动作：起飞 / 降落 / 签出 / 回航 / 重试 / 继续任务 / 确认接管 |
      | `cancel`  | 白 | 取消、拒绝、撤回、知道了 —— 退出或**不改变状态**的一侧 |
      | `danger`  | 红 | **应急处理、救济处理**以及其他有风险的处理：`mcRescueLand`（救济）、迫降/备降的确认（若将来加确认框）、未识别的动作（fail-safe） |

    ‼️ **旧约定是「红 = 确认执行、绿 = 取消」，已被这条推翻，别改回去。**
    旧写法里每个框各写一份 hex（`#d63031` / `#2ecc71` / `#1f6fd0`），改一次要翻四个文件；
    本组件把底色、字色、尺寸、字号缩放收在一处。

    配色实算（WCAG 相对亮度公式，本机 python 可复现；深绿卡底 `#0f2f2c`）：

        绿底 `#1a7f46` 白字 → **5.04:1**（过 AA 4.5:1）
        白底 `#ffffff` 深绿字 `#0f2f2c` → **14.35:1**
        红底 `#d63031` 白字 → **4.85:1**

    ⚠️ 旧绿 `#2ecc71` + 白字只有 **2.10:1**（小文本不及格）—— 本组件特意换成更深的绿。
    别为了「和卡片上的绿一致」把 `#2ecc71` 搬回来：那是**底色/描边**用色，不是文字按钮底色。
*/
Button {
    id: root

    /// 语义档：`"primary"`（绿） | `"cancel"`（白） | `"danger"`（红）。
    /// ‼️ 只允许这三个值；写错（包括空串）按 `primary` 渲染不会报错，所以实例取色必须走
    ///    `kind` 这一条路，别在实例里另写 `background`。
    property string kind: "primary"

    /// 供实例/测试读取：本档的底色与字色。**不要在实例里覆写**。
    /// ‼️ 色值不写在这里，取 `OpsCommon.js` 的常量——任务卡按钮共用同一份。
    readonly property color fillColor: kind === "danger" ? OpsCommon.BUTTON_DANGER_COLOR
                                     : kind === "cancel" ? OpsCommon.BUTTON_CANCEL_COLOR
                                     : OpsCommon.BUTTON_PRIMARY_COLOR
    readonly property color labelColor: kind === "cancel" ? OpsCommon.BUTTON_CANCEL_TEXT_COLOR
                                                         : OpsCommon.BUTTON_ON_COLOR

    // 尺寸与旧实现一致：高 40、取消 96 / 其余 132 的数据基线；两者都乘字号因子。
    // ‼️ 只比内容宽会更糟：翻译变长时按钮会被 96/132 下限掩盖，随后内容区放不下而被省略。
    // ⚠️ `contentItem` 在构造期可能还是 null ⇒ 先折成 0 再算，别直接读它的属性
    //    （那会在组件创建时报 "Cannot read property 'implicitWidth' of null"）。
    readonly property real _contentW: contentItem ? contentItem.implicitWidth : 0
    readonly property real _contentH: contentItem ? contentItem.implicitHeight : 0
    implicitWidth: Math.max(Math.round((kind === "cancel" ? 96 : 132) * ScreenTools.uiTextScaleFactor),
                            _contentW + leftPadding + rightPadding)
    implicitHeight: Math.max(Math.round(40 * ScreenTools.uiTextScaleFactor),
                             _contentH + topPadding + bottomPadding)

    // 不可点（如回航选点还没选）时整体压暗：自绘 background 不会像平台默认按钮那样自动变灰。
    opacity: enabled ? 1.0 : 0.45

    background: Rectangle {
        color: root.fillColor
        radius: 3
    }

    contentItem: Text {
        text: root.text
        color: root.labelColor
        font.pixelSize: Math.round(15 * ScreenTools.uiTextScaleFactor)
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
