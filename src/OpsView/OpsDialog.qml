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
    要换色系**不覆写**，改传下面那个 `alert` 开关。

    ---- 告警档（用户 2026-10-10 第五轮）----

    用户原话：「告警类提示款不应该与其他提示框采用相同色系；……背景和边框改为黄色系
    颜色，背景为淡黄色。文字使用与背景反差较大的颜色」。

    ⇒ 这里多一个 `alert` 开关，**只换色系、不换结构**。判据不是"重要不重要"，是
    **这个框要不要人做决定**：要（确认/拒绝/接管）＝深绿卡；只是**告知**一件事、
    看完就走（「交接已结束」通知，5 秒自关）＝淡黄告警卡。前者是对话，后者是广播。

    ‼️ 换的不止边框：**底、边、标题、正文四处一起换**。只把边框改成黄的、正文留着
    `#e6edf7`，就是文件头上一条纪律（"只改背景"）的镜像错误，结果同样是看不见的字。
    淡黄底 `#fff8e1` 上的实算值（同一套 WCAG 公式，本机 python 可复现）：

        正文 `#3e2723` 深棕   → **13.01:1**
        标题 `#7a4f01` 深琥珀 → **6.71:1**（14px bold 属小文本，过 AA 4.5:1）
        边框 `#d48806`        → **2.70:1**（非文字，比 `#f9a825` 的 1.85 才压得住 1px 描边）
        ✗ 沿用深底家族的 `#e6edf7` → **1.11:1**（等于看不见）

    深绿档的四个原值**一个都没动**（正文 12.18 / 边框 4.79，同一脚本可复核）。
*/
Dialog {
    id: opsDialogRoot

    /// 告警档开关（用户 2026-10-10）。`false`（缺省）＝深绿卡片家族，动作弹框用；
    /// `true` ＝淡黄告警卡片，**只告知、不需决定**的提示用。
    /// ‼️ 实例**只传这个开关**，不传色值 —— 色值全部留在本文件，见上面那段纪律。
    property bool alert: false

    // 四个色值仍**只在本文件定义一处**。改配色改这里，不会漏改某一个实例。
    readonly property color cardColor:   alert ? "#fff8e1" : "#0f2f2c"
    /// 深绿档的边色与 `TaskListPanel.qml` 的**进站任务卡片**
    /// （`inboundCardColor` / `inboundCardBorderColor`）**同值** ——
    /// 降落站点的任务卡就是进站卡，用户说的"跟降落卡片风格相同"= 这一组。
    /// 改深绿档配色时 `TaskListPanel.qml` 与这里要**一起看**；告警档与之无关。
    readonly property color borderColor: alert ? "#d48806" : "#26a69a"
    readonly property color titleColor:  alert ? "#7a4f01" : "#e6edf7"
    /// 正文字色，**跟着底走**（见文件头那张实算表）。
    readonly property color bodyColor:   alert ? "#3e2723" : "#e6edf7"

    background: Rectangle {
        color: opsDialogRoot.cardColor
        radius: 4
        border.width: 1
        border.color: opsDialogRoot.borderColor
    }

    // ‼️ `text: opsDialogRoot.title` 而不是裸写 `title`：`header` 的求值作用域在派生
    //    组件内部，裸写要靠 unqualified access 的兜底查找。加根 id 把它钉死。
    header: Item {
        implicitHeight: opsDialogTitle.implicitHeight + 20
        Text {
            id: opsDialogTitle
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
            text: opsDialogRoot.title
            color: opsDialogRoot.titleColor; font.pixelSize: 14; font.bold: true
            elide: Text.ElideRight
        }
    }
}
