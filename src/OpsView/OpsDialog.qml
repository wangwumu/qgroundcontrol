import QtQuick
import QtQuick.Controls

/*!
    \qmltype OpsDialog
    \brief OpsView / OpsShell 家族动作弹框的**共用皮肤**（用户 2026-10-08 第四轮）。

    「与任务卡片同族」的那一组色，原先是**各弹框各写一份**。用户第四轮要求
    「选择完机位后，进入确认界面的风格也要与此相同。包括航线签出，站点提示签入的
    对话框，也要此风格」⇒ 改为**单点定义**：改配色只改这里一处，
    不会再出现"改了三个、还剩一个浅底混在里面"。

    ‼️ 覆写的是两件**必须成对**的东西，缺一都会留下看不见的字：

      · `background` —— 深色卡底。不换它，深色家族的文字落在平台默认的**白底**
        `Dialog` 上（`OpsShell.qml` 实测未覆写时 `palette.window = #ffffff`）。
      · `header`    —— `Dialog.title` 是交给**缺省 header**（一个 `Label`）渲染的，
        而 `Label` 缺省字色是**深色**。只换 `background` 的话标题直接压在深底上。

    这两条是同一个病的两面 —— "只改背景"这个漏项在本仓已经踩过一次
    （`slotDialog` 2026-10-08 第三轮）。

    ⚠️‼️ 底色一换，**框内所有字色都要跟着换**，不是只换标题。
    浅底那套色搬到深绿底 `#0f2f2c` 上的**实算**对比度（WCAG 相对亮度公式，
    本机 python 一行可复现）：

        `#1565c0` 深蓝 → **2.50:1**（白底上 5.75:1）
        `#c62828` 深红 → **2.55:1**（白底上 5.62:1）
        `#1f2937` 深灰 → **1.02:1**（白底上 14.68:1 —— 即"看不见"）

    ⇒ 一律改用深底家族（括号内为在 `#0f2f2c` 上的实算值，全部过 AA 4.5:1）：

        正文 `#e6edf7`(12.18) · 次要 `#9fb3d4`(6.75) · 警示 `#ffc107`(8.80) · 错误 `#ff6b6b`(5.17)

    结论与 `slotDialog` 2026-10-08 那条**同源**：**字色跟着底走**。
    两个值都不"错"，错的是把某个底上量过的色搬到另一个底上。

    \note 使用者只需给 `id` / `parent` / `width` / `x` / `y` / `title` 和正文；
    `background` 与 `header` **不要再在本组件实例里覆写**（同一处有两个定义会打架）。
*/
Dialog {
    id: opsDialogRoot

    // ‼️ 深色卡片底 —— 色值与 `TaskListPanel.qml` 的**进站任务卡片**
    //    （`inboundCardColor` / `inboundCardBorderColor`）**同值**。
    //    降落站点的任务卡就是进站卡，所以用户说的"跟降落卡片风格相同"= 这一组色。
    //    改配色时 `TaskListPanel.qml` 与这里要**一起看**。
    background: Rectangle {
        color: "#0f2f2c"
        radius: 4
        border.width: 1
        border.color: "#26a69a"
    }

    // ‼️ `text: opsDialogRoot.title` 而不是裸写 `title`：`header` 的求值作用域在派生
    //    组件内部，裸写要靠 unqualified access 的兜底查找。加根 id 把它钉死。
    header: Item {
        implicitHeight: opsDialogTitle.implicitHeight + 20
        Text {
            id: opsDialogTitle
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
            text: opsDialogRoot.title
            color: "#e6edf7"; font.pixelSize: 14; font.bold: true
            elide: Text.ElideRight
        }
    }
}
