import QtQuick
import QtQuick.Shapes

/*!
    \qmltype OpsWarnIcon
    \brief OpsView / OpsShell 家族**通知类**弹框的标记图标：三角形外框 + 叹号。

    用户 2026-10-10 第七轮原话：「这个这几个对话框中，增加一个警告图标，就是三角形
    外框，里边有个叹号那个。位置在标题一下，警告文字的左边」。
    范围由用户当场裁定：「你自己判断，这个不是功能类的，比如选择机位肯定不在范围你。
    他是通知类的，警告只是更重要的通知」。

    ⇒ 判据与 `OpsDialog` 的 `alert` 开关**同一条**：**这个框要不要人做决定**。
      要（确认 / 拒绝 / 接管）＝不加；只告知、看完就走＝加。

    ‼️ 用户那句话同时钉死了命名口径：**图标标的是"通知类"，不是"警告"** ——
      「警告只是更重要的通知」，两者同一档、都加。别自作主张只给"警告"加。

    当前使用者（全部 `OpsDialog` 实例已逐个核过，共 5 个）：
      · 加：`OpsView.qml` 的 `landBlockDialog`（降落被阻止 —— 两条文字、无可选项）
      · 加：`OpsShell.qml` 的 `handoverGoneDialog`（交接已结束 —— 只告知、5 秒自关）
      · 不加：`slotDialog`（选择机位 —— 用户点名排除）、`actionConfirmDialog`、
              `handoverDialog`（后两个都在等一个决定）

    本仓没有现成的三角叹号图元（`src/FlightMap/Images/AlertAircraft.svg` 是圆圈里的
    飞机剪影，不是这个），故与 `OpsShell.qml` 的航班箭头同法自绘。

    ⚠️ `Shape` 属于 `QtQuick.Shapes`，**不属于** `QtQuick`。少了上面那行 import，
      构建、单测、qmllint **三者都不报错**，只有真的加载本组件时才炸
      （报错原文与完整教训见 `OpsShell.qml` 顶部注释）。

    \note 实例这样用 —— `Layout.alignment` 必须给：
    \code
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        OpsWarnIcon { Layout.alignment: Qt.AlignTop; color: handoverGoneDialog.warnIconColor }
        Text { Layout.fillWidth: true; color: handoverGoneDialog.bodyColor; ... }
    }
    \endcode
    ‼️ 缺了 `Layout.alignment: Qt.AlignTop` 时 `RowLayout` 会把图标**垂直居中**，
      正文折行成两行以上时它就飘到文字块中间去了，不再是"第一行的左边"。
*/
Item {
    id: root

    /// 线色。**实例里写 `<dialogId>.warnIconColor`**，不要写死 hex ——
    /// 与正文 / 标题同一条纪律「字色跟着底走」，色值只留在 `OpsDialog.qml` 一处。
    property color color: "#ffc107"

    /// 图标边长。**缺省 48** —— 用户 2026-10-10 第八轮原话：「图标太小，要三倍大」。
    ///
    /// 16 → 48 是**线性三倍**（面积九倍）。离屏实测（只有图标、纯黑底、无文字干扰）：
    ///     改前缺省值 → 墨迹 **16×16**
    ///     `size: 48` → 墨迹 **48×46**
    /// 宽正好 3.00 倍；高 46 而非 48，是三角形墨迹本就不满格（竖向 0.055‥0.945）
    /// 加抗锯齿取整，与缩放比例无关，不是尺寸没跟上。
    ///
    /// 本文件所有几何都写成 `size` 的比例，所以改这一个数就整体缩放、不会错位 ——
    /// 当初那样写正是为了今天能一行改完。
    /// ⚠️ 旧注释这里写的是「缺省 16 —— 比 13px 正文略高，压得住又不喧宾夺主」。
    ///    那是 16 的说法：48 是正文的 **3.7 倍高**，故意不再含蓄。别照那句往回改。
    /// ⚠️ 两个实例（`OpsView.qml` 的 `landBlockDialog`、`OpsShell.qml` 的
    ///    `handoverGoneDialog`）**都没显式传 `size`** ⇒ 改缺省值两处同时变，
    ///    这正是单点定义想要的；要分开调再给实例传 `size`。
    property real size: 48

    implicitWidth: size
    implicitHeight: size

    // 三角形外框：**只描边、不填充**（用户原话「三角形外框」）。
    // 三个点按 `size` 的比例算，换尺寸不会错位。这里用 `PathLine` 而不是
    // `PathSvg` —— 同目录 `SlotLayout.qml` 用 `PathSvg` 是因为那条路径的**点数**
    // 随比例在变、只能拼字符串；本图形恒为三点，绑定更好读也更好改。
    //
    // 竖向占满 0.055‥0.945 而横向只到 0.038‥0.962：三角本来就该比高更宽一些，
    // 而**底下那截留给叹号**才是重点 —— 内沿在 0.9025，见下面 `Rectangle` 的算式。
    Shape {
        anchors.fill: parent
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.size * 0.085
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            startX: root.size * 0.5
            startY: root.size * 0.055
            PathLine { x: root.size * 0.962; y: root.size * 0.945 }
            PathLine { x: root.size * 0.038; y: root.size * 0.945 }
            PathLine { x: root.size * 0.5; y: root.size * 0.055 }
        }
    }

    // ‼️ 叹号的**竖笔与点是两个同宽、同 x 的 `Rectangle`**，竖笔**不是** `ShapePath` 描边。
    //    这不是随手写的 —— 离屏渲染**当时缺省的 16px 样张**（第八轮把缺省改成 48 之前
    //    那次实测，1.52px 就是 0.095×16）、按底色反解覆盖率实测：
    //      · 竖笔若用 `ShapePath` + `strokeWidth: 0.095·size`（16px 时 = 1.52px），描边被
    //        摊到相邻两列，**每列只覆盖 0.78**；
    //      · 点用同宽、同 x 的 `Rectangle` 时，两列都是 **1.00**。
    //    ⇒ 同一张图里**点比竖笔重 28%**，肉眼就是「下面那个点比上面那笔粗一圈」。
    //      两者换成同一种图元后都是 1.00，权重才一致。实测前后对比见交付说明。
    //      （三角仍走 `Shape`：对角线只能描边，且它是斜的、本来就软，不参与这个比较。）
    //    ⚠️ 这条覆盖率结论**与尺寸无关**（只取决于图元种类），第八轮 16→48 之后依然成立。
    //
    //    长度 0.375·size = **2.95 倍宽** —— 第一版给的是 0.385‥0.60（2.26 倍），
    //    实测在 **48px 试看样张**上看着像块方疙瘩而不是叹号。
    //    ‼️ 那个 48px 是当年为了"放大看清楚"临时试看的尺寸，与第八轮把缺省值定成 48
    //       只是**数值巧合**，两者没有因果关系，别混成一件。
    //    上下沿 0.2475‥0.6225 是**照上一版「描边端点 + `RoundCap` 圆头」的可见范围**取的
    //    （端点 0.295 / 0.575 各向外伸半个笔宽 0.0475）⇒ 下面那条 0.110s 的间隙不受影响。
    //    上端仍不碰边：0.2475·size 处三角半宽 0.0999·size，笔半宽只有 0.0475·size。
    Rectangle {
        width: root.size * 0.095
        height: root.size * 0.375
        radius: width / 2
        color: root.color
        x: root.size * 0.5 - width / 2
        y: root.size * 0.2475
    }

    // 叹号下面的点。与竖笔**同一种图元、同一个宽度、同一个 x**（理由见上）。
    //
    // 三处间距都是算过的（`s` = `size`；本行下面那个 `y` 是点的**上沿**，圆心在 y + 0.0475s）。
    // 以下像素值按**当前缺省 48px** 折算；改尺寸时这些数要跟着重算，比例值不会变：
    //   · 竖笔下沿 0.6225s → 点上沿 0.7325s ⇒ **间隙 0.110s**，48px 下 5.28px。
    //     ‼️ 这个 0.6225s 是**量出来的可见下沿**、不是端点值：上一版竖笔是描边，端点 0.575s
    //     要靠 `RoundCap` 的圆头再往下伸半个笔宽才到 0.6225s。当年漏算这一步，把端点推到
    //     0.605s、点放到 0.715s，看着差了 0.11s，扣掉两个圆头后**还是 0.0625s**（当年
    //     16px 样张下 1px）—— 白改。现在竖笔是矩形，下沿就是算出来的 0.6225s：同一个数、
    //     同一条间隙。
    //   · 点下沿 0.8275s vs 三角底边**内沿** 0.945s − 0.085s/2 = 0.9025s
    //     ⇒ 余 0.075s，48px 下仍有 3.6px。
    //   · 圆心 0.78s 处三角半宽 0.3763s，点半径 0.0475s ⇒ 稳稳在三角内，不碰边。
    Rectangle {
        width: root.size * 0.095
        height: width
        radius: width / 2
        color: root.color
        x: root.size * 0.5 - width / 2
        y: root.size * 0.7325
    }
}
