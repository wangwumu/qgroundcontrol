#include "OpsRouteSyncUITest.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QRegularExpression>
#include <QtCore/QScopeGuard>
#include <QtCore/QUrl>
#include <QtCore/QVariantMap>
#include <QtQml/QQmlApplicationEngine>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtQml/QJSValue>
#include <QtTest/QTest>

UT_REGISTER_TEST(OpsRouteSyncUITest, TestLabel::Integration)

// ============================================================================
// 被测对象
// ============================================================================
//
// `OpsRouteSync.qml` 是 `<OpsViewModule>` 的 QML 成员，随 `qt_add_qml_module` 进资源系统，
// 运行期 URL = `qrc:/qml/QGroundControl/OpsView/OpsRouteSync.qml`
// （RESOURCE_PREFIX `/qml` + URI `QGroundControl.OpsView`）。
// 本文件用 `QQmlComponent(_engine, url)` 把它**单独**实例化 —— 不走 MainWindow 树上的
// `objectName` 查找（`QmlUITestBase` 的公开 API 全是那一类），因为三道闸要的是
// **注入 `task` 后的取值行为**，而不是界面上点了哪个按钮。
static const char *kOpsRouteSyncUrl = "qrc:/qml/QGroundControl/OpsView/OpsRouteSync.qml";

// 三道闸的文案 —— **逐字**，与 `OpsRouteSync.qml` 里 `_fail(qsTr(...))` 的实参一致。
// 它们是既有口径（界面上有对应用户认知），改动这句话就是改行为。
static const char *kFlightGateText  = "该任务未设定飞行高度，无法下发";
static const char *kTakeoffGateText = "该航线未设定有效的起飞高度，无法下发";
static const char *kLandingGateText = "该航线未设定有效的降落高度，无法下发";
static const char *kGroundMSLGateText = "该航线未取到起降站点的地面海拔，无法下发";

namespace {

/// `GET /api/routes/<id>` 的响应体。键名与 `OpsCommon.routeAltitudeBounds` 读取的一致。
///
/// ‼️ 后两个形参**有缺省值** ⇒ 既有各格的实参形状（只传前四个）**一个字符都没动**。
///    它们只是为 I2 的两格新用例（「起飞地面海拔键缺失」/「起飞地面海拔为 0」）开的口子，
///    不改变任何既有格的输入。
/// ⚠️ 不要把它改成「按参数决定写不写 `landing_ground_msl`」之类 —— 本仓两个键恒写是共用夹具的
///    基线，扩大可变量会牵动所有既有格（历史上「改夹具基线」的建议已被控制方驳回过）。
QString routeJsonOf(double takeoffAGL, double takeoffClearAGL, double landingAGL, double landingClearAGL,
                    bool omitTakeoffGroundMSL = false, double takeoffGroundMSL = 450.0)
{
    QVariantMap r;
    r[QStringLiteral("takeoff_alt_agl")]            = takeoffAGL;
    r[QStringLiteral("takeoff_site_clear_alt_agl")] = takeoffClearAGL;
    // 「键缺失」由**不写入该键**来表达（`QJsonObject` 序列化后该键整个消失）——
    // 这与后端 `routeAltitudeBounds.pick()` 收到的 `undefined` 同判（都落成 `null` ⇒ QML 侧 NaN）。
    if (!omitTakeoffGroundMSL) {
        r[QStringLiteral("takeoff_ground_msl")]     = takeoffGroundMSL;
    }
    r[QStringLiteral("landing_alt_agl")]            = landingAGL;
    r[QStringLiteral("landing_site_clear_alt_agl")] = landingClearAGL;
    r[QStringLiteral("landing_ground_msl")]         = 480.0;
    r[QStringLiteral("end_waypoint_id")]            = 7;
    r[QStringLiteral("end_waypoint_lat")]           = 47.42;
    r[QStringLiteral("end_waypoint_lon")]           = 8.56;
    return QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(r)).toJson(QJsonDocument::Compact));
}

/// `routeJsonOf` 的结果**去掉降落侧地面海拔键**（G2，2026-10-01）。
///
/// ‼️ **不扩 `routeJsonOf` 的形参** —— 上面那条注解说得很明确：「两个键恒写」是共用夹具的
///    基线，把它变成可变量会牵动**全部**既有格。这里只在**新格的构造点**上做减法，
///    既有各格的输入**一个字节不变**。
///
/// 为什么要这一格：地面海拔闸是 `!finite(起飞值) || !finite(降落值)`，而既有夹具把
/// `landing_ground_msl` 硬编码成 `480.0` ⇒ **永远走不到 `||` 的右半边**。
/// 把实现改成只判起飞侧，改前 12 格**全绿** —— 挡不住。
QString routeJsonOmittingLandingGroundMSL(double takeoffAGL, double takeoffClearAGL,
                                          double landingAGL, double landingClearAGL)
{
    QJsonObject o = QJsonDocument::fromJson(
        routeJsonOf(takeoffAGL, takeoffClearAGL, landingAGL, landingClearAGL).toUtf8()).object();
    o.remove(QStringLiteral("landing_ground_msl"));
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

/// 航点列表里的一项。下面两个夹具共用（原来只在 `waypointsJson()` 里内联着）。
QVariant waypointRow(int id, double lat, double lon, double alt, int cmd)
{
    QVariantMap m;
    m[QStringLiteral("id")]       = id;
    m[QStringLiteral("lat")]      = lat;
    m[QStringLiteral("lon")]      = lon;
    m[QStringLiteral("altitude")] = alt;
    m[QStringLiteral("command")]  = cmd;
    return QVariant(m);
}

/// `GET /api/routes/<id>/waypoints` 的响应体。
/// 形状取「终点**不在**列表里」那一档（`appendLandingWaypoint` 的追加分支）——
/// 它是云端权威库里 1 / 20 / 21 三条的形状，也是这条链上输入最多的一档。
QString waypointsJson()
{
    QVariantList wps;
    wps << waypointRow(3, 47.40, 8.54, 500.0, 16);
    wps << waypointRow(4, 47.41, 8.55, 510.0, 16);
    return QString::fromUtf8(QJsonDocument(QJsonArray::fromVariantList(wps)).toJson(QJsonDocument::Compact));
}

/// `GET /api/routes/<id>/waypoints` 的响应体，形状取「终点**恰好是末项**」那一档。
///
/// ‼️ 与 `waypointsJson()` **不是**同一档，差在 `appendLandingWaypoint` 走哪条分支：
///    · 本档 ⇒ **行为 2**（`OpsCommon.js` 里 `last.id === endWaypointId`）⇒ **原样返回、不追加**，
///      且**不读** `endLat` / `endLon` / `endGroundMSL` 三个入参；
///    · `waypointsJson()` ⇒ 追加分支（行为 1），**会读** `endGroundMSL`，且它非有限时**整条作废**。
///    这个差别是下面 groundMSL 两格的**全部意义**：追加分支下「降落侧地面海拔缺失」会先撞
///    `OpsRouteSync.qml` 的「该航线未设定可用的降落站点」（`return _fail(...)` 的那一处），
///    **根本走不到**地面海拔闸 ⇒ 只判追加分支，那道闸 `||` 的**右半边永远测不到**。
QString waypointsJsonEndIsLast()
{
    QVariantList wps;
    wps << waypointRow(3, 47.40, 8.54, 500.0, 16);
    // id 必须是 `routeJsonOf` 里的 `end_waypoint_id`（= 7），否则走不到行为 2。
    wps << waypointRow(7, 47.42, 8.56, 520.0, 16);
    return QString::fromUtf8(QJsonDocument(QJsonArray::fromVariantList(wps)).toJson(QJsonDocument::Compact));
}

}  // namespace

// ============================================================================
// 用例
// ============================================================================
//
// 数据表每一行 = 一个格子，各跑一次（Qt 数据驱动：一行失败不影响其它行）。
// 覆盖四组：
//   · 飞行高度闸（`task.cruise_alt_agl`）—— 在 `start()` 顶部，早于任何 `get()`；
//   · 起飞高度闸（`route.takeoff_alt_agl` + 起飞站点安全高度，D6 取大）；
//   · 降落高度闸（`route.landing_alt_agl` + 降落站点安全高度，D6 取大）；
//   · 地面海拔闸（`route.takeoff_ground_msl` / `route.landing_ground_msl` 须为**有限数**，I2）。
//     ⚠️ 这一组判的**不是**值域：地面海拔 `0` / 负数是合法值，专门有一格阴性对照钉住这点。
//
// ‼️ 每组都**必须有阳性对照**：只写「坏输入被拒」时，`return _fail(固定文案)` 这种
//    常数实现会把所有格子都蒙成绿的。阳性对照断言的是 `state` 已经走过那道闸
//    （`fetching` / `building`），而不是"没报错"。
//
// ---- 两种**航点夹具形状**都必须出现（G2，2026-10-01）----
//   · `waypointsJson()`：终点**不在**列表里 ⇒ `appendLandingWaypoint` 走**追加分支**；
//   · `waypointsJsonEndIsLast()`：终点**恰是末项** ⇒ 走**行为 2**（原样返回，**不读**三个末项入参）。
//   ‼️ 只出追加分支时，地面海拔闸 `||` 的**右半边（降落侧）永远测不到** —— 追加分支里
//      `endGroundMSL` 非有限会让 `appendLandingWaypoint` **整条作废**，于是先撞「该航线未设定
//      可用的降落站点」那道**更早**的闸。2026-10-01 实测：拿追加分支去配「降落侧缺失」，
//      红的是 **`statusText` 文案**，不是本文件要测的那道闸。
//
// ---- 两个**跨闸**断言（G1 / G3，2026-10-01）----
//   · `expectWaypointCount`：判 `_waypointCount` **等于**该夹具形状的真实点数
//     （追加分支 **3** / 行为 2 **2**，逐格给在数据表里）。**不写通吃的下界** ——
//     写 `> 0` 的话「追加整个没接上」（长度 2 > 0）照样全绿，而那正是它要挡的缺陷。
//   · `errSink`：替身回调里捕获到的异常**条数与内容**。`building` 格必须**恰好 1 条**、
//     且是那道已知的替身类型错误；其余格必须 **0 条**（详见 `_testGates()` 尾部）。
//     旧的裸 `catch (e) { }` 抑制范围过宽：闸**之前**的意外异常同样被吞，
//     而 `state` 可能**恰好**停在断言的期望值上 ⇒ 假绿。
void OpsRouteSyncUITest::_testGates_data()
{
    QTest::addColumn<QString>("taskJson");          // 空 ⇒ 不注入 task（保持默认 null）
    QTest::addColumn<QString>("routeJson");
    QTest::addColumn<QString>("wpsJson");
    QTest::addColumn<bool>("stubFetch");            // true ⇒ 注入会回调的 get；false ⇒ 注入空实现
    QTest::addColumn<QString>("expectState");
    QTest::addColumn<QString>("expectStatusText");  // 空 ⇒ 走「按 state 分支」的默认断言（见 _testGates 尾部）
    QTest::addColumn<int>("expectWaypointCount");   // G1：`_waypointCount` 的期望值；**-1 = 本格不判**

    // 阳性对照用的航线的起降高度：起飞 60 / 降落 50（两端的站点安全高度都是 0）。
    const QString goodRoute  = routeJsonOf(60.0, 0.0, 50.0, 0.0);
    const QString wps        = waypointsJson();           // 追加分支（终点**不在**列表里）
    const QString wpsEndLast = waypointsJsonEndIsLast();  // 行为 2（终点**恰是**末项）
    const QString cruise50   = QStringLiteral("{\"cruise_alt_agl\":50}");

    // ‼️ `expectWaypointCount` 只在 `expectState == "building"` 的格上填真值（其余一律 `-1`）：
    //    闸在 `_waypointCount = items.length` **之前**就 `_fail` 返回时，那个属性还是初值 `0`，
    //    判它等于 `0` 只是把「没跑到」包装成判据，没有区分力。
    //    两种夹具形状的期望值：**追加分支 3**（2 个 + 追加 1 个）、**行为 2 是 2**（原样返回、不追加）。

    // ---- 飞行高度闸（读 `task.cruise_alt_agl`，在 `start()` 顶部；走不到 `get`） ----
    QTest::newRow("flight / 50：阳性对照 —— 不得是「未设定飞行高度」")
        << cruise50 << goodRoute << wps << false << QStringLiteral("fetching") << QString() << -1;
    QTest::newRow("flight / 0：「未设定」的编码 ⇒ 拒发")
        << QStringLiteral("{\"cruise_alt_agl\":0}") << goodRoute << wps << false
        << QStringLiteral("failed") << QString::fromUtf8(kFlightGateText) << -1;
    QTest::newRow("flight / task 整个为 null ⇒ 拒发")
        << QString() << goodRoute << wps << false
        << QStringLiteral("failed") << QString::fromUtf8(kFlightGateText) << -1;
    QTest::newRow("flight / 字符串 \"50\"：闸读的是后端原始字段（非 number ⇒ 拒），不是被 real 属性同化后的值")
        << QStringLiteral("{\"cruise_alt_agl\":\"50\"}") << goodRoute << wps << false
        << QStringLiteral("failed") << QString::fromUtf8(kFlightGateText) << -1;

    // ---- 起飞高度闸（`_takeoffAGL = max(route.takeoff_alt_agl, route.takeoff_site_clear_alt_agl)`） ----
    QTest::newRow("takeoff / 航线值 0 且站点安全高度 0 ⇒ 拒发")
        << cruise50 << routeJsonOf(0.0, 0.0, 50.0, 0.0) << wps << true
        << QStringLiteral("failed") << QString::fromUtf8(kTakeoffGateText) << -1;
    QTest::newRow("takeoff / 60：阳性对照")
        << cruise50 << routeJsonOf(60.0, 0.0, 50.0, 0.0) << wps << true
        << QStringLiteral("building") << QString() << 3;
    QTest::newRow("takeoff / 航线值 0 但站点安全高度 60：D6 取大 ⇒ 放行")
        << cruise50 << routeJsonOf(0.0, 60.0, 50.0, 0.0) << wps << true
        << QStringLiteral("building") << QString() << 3;

    // ---- 降落高度闸（`_landingAGL = max(route.landing_alt_agl, route.landing_site_clear_alt_agl)`） ----
    // ‼️ 起飞那一侧**必须**是正数，否则先撞起飞闸，本格测不到降落闸。
    QTest::newRow("landing / 航线值 0 且站点安全高度 0 ⇒ 拒发")
        << cruise50 << routeJsonOf(60.0, 0.0, 0.0, 0.0) << wps << true
        << QStringLiteral("failed") << QString::fromUtf8(kLandingGateText) << -1;
    QTest::newRow("landing / 50：阳性对照")
        << cruise50 << routeJsonOf(60.0, 0.0, 50.0, 0.0) << wps << true
        << QStringLiteral("building") << QString() << 3;
    QTest::newRow("landing / 航线值 0 但站点安全高度 50：D6 取大 ⇒ 放行")
        << cruise50 << routeJsonOf(60.0, 0.0, 0.0, 50.0) << wps << true
        << QStringLiteral("building") << QString() << 3;

    // ---- 地面海拔闸（I2，2026-10-01）：**两侧**地面海拔项都必须是**有限数** ----
    // 上面三道闸判的都只是 **AGL 项**；而 `OpsCommon.assembledAltitude(groundMSL, agl)` 有两个
    // 输入项 ⇒ 地面海拔项此前**两侧都没有闸**，三个消费点（末项 `applyLandingAltitude`、
    // 起飞项 `_applyAltitude`、`_statusText` 的两个 `arg`）全部无守卫且**完全静默**。
    //
    // ‼️ 判据**只判有限性、不判值域**（`OpsCommon.nrrsmFiniteGroundMSL`）：地面海拔 `0`（海平面）
    //    甚至负数（低于海平面）都是**合法**取值，复用 `nrrsmUsableAGL` 的 `> 0` 会把这类
    //    合法航线一并拒掉 —— 下面那格阴性对照就是专门钉这个陷阱的。
    QTest::newRow("groundMSL / 起飞地面海拔键缺失 ⇒ 拒发")
        << cruise50 << routeJsonOf(60.0, 0.0, 50.0, 0.0, /*omitTakeoffGroundMSL=*/true) << wps << true
        << QStringLiteral("failed") << QString::fromUtf8(kGroundMSLGateText) << -1;
    // ‼️ 与上一格**配对**：上一格钉 `||` 的**左半边**（起飞侧缺失），下面两格钉**右半边**
    //    （降落侧缺失）。只留任何一半，「把实现改成只判一侧」都能全绿。
    //
    // ‼️ **本格必须用 `wpsEndLast`（行为 2）而不是 `wps`** —— 这不是随手挑的：
    //    追加分支（`wps`）里 `appendLandingWaypoint` **要读** `endGroundMSL`，它非有限就
    //    **整条作废**（`OpsCommon.js` 的「行为 6」）⇒ 先撞 `OpsRouteSync.qml` 的
    //    「该航线未设定可用的降落站点」**早退**，**根本走不到** `:496-497` 那道闸。
    //    （2026-10-01 实测：拿 `wps` 配本行的输入，`statusText` 得到的是"降落站点不可用"，
    //     不是本格期望的地面海拔文案 —— 那一版就是**红**的。）
    //    行为 2（末项 `.id` 恰为 `end_waypoint_id`）**原样返回、不读**那三个入参
    //    ⇒ `_landingGroundMSL` 为 NaN 也能活到那道闸 ⇒ 右半边**可达**。
    // 起飞 60 / 降落 50 都是正数 ⇒ 先撞不到那两道 AGL 闸，只有地面海拔闸拦得住本格。
    QTest::newRow("groundMSL / 降落地面海拔键缺失 ⇒ 拒发")
        << cruise50 << routeJsonOmittingLandingGroundMSL(60.0, 0.0, 50.0, 0.0) << wpsEndLast << true
        << QStringLiteral("failed") << QString::fromUtf8(kGroundMSLGateText) << -1;
    // 阳性对照（与上一格**同形状**、只把降落侧地面海拔补回来）：证明"行为 2 这个形状本身"
    // 过得去这道闸 ⇒ 上一格的红**归因于地面海拔缺失**，而不是归因于形状。
    // 过闸后起飞端组装值 = 450 + max(60,0) = 510；降落端 = 480 + max(50,0) = 530（与既有各格同）。
    QTest::newRow("groundMSL / 行为 2 形状 + 两侧地面海拔齐全：阳性对照")
        << cruise50 << routeJsonOf(60.0, 0.0, 50.0, 0.0) << wpsEndLast << true
        << QStringLiteral("building") << QString() << 2;
    // 阴性对照：`0` 是**合法**地面海拔（海平面）⇒ 必须放行。
    // 放行后起飞端组装值 = 0 + max(60,0) = 60；降落端仍是 480 + max(50,0) = 530。
    QTest::newRow("groundMSL / 起飞地面海拔 0（海平面）：合法 ⇒ 放行")
        << cruise50 << routeJsonOf(60.0, 0.0, 50.0, 0.0, /*omitTakeoffGroundMSL=*/false, /*takeoffGroundMSL=*/0.0)
        << wps << true
        << QStringLiteral("building")
        << QStringLiteral("正在构造航线…（起飞 60 m / 降落 530 m）") << 3;
}

void OpsRouteSyncUITest::_testGates()
{
    QFETCH(QString, taskJson);
    QFETCH(QString, routeJson);
    QFETCH(QString, wpsJson);
    QFETCH(bool, stubFetch);
    QFETCH(QString, expectState);
    QFETCH(QString, expectStatusText);
    QFETCH(int, expectWaypointCount);

    startUI();
    if (QTest::currentTestFailed()) return;

    // ---- 阳性对照格的**边界** ----
    // 三道闸全部放行之后，代码会走到 `_plan.startStaticActiveVehicle(vehicle, false)`
    // （即 `OpsRouteSync.qml` 里 `_plan.startStaticActiveVehicle(vehicle, false)` 那一句）
    // —— 那一步的形参类型是 `Vehicle*`，本用例的替身在那里
    // 被 QML 拒绝，拒绝会连同 JS 调用栈作为 **warning** 写进日志（一条主句 + 若干帧）。
    // 本用例**只判到闸为止**（断言 `state` 已走到 building），所以这条边界产生的日志
    // 按模式忽略。⚠️ 这是**弃真**，但范围被钉死：
    //   · 只在「注入 stub get」且「期望不是 failed」的格子里注册；
    //   · 只吞三类消息：替身转换失败的主句、`OpsRouteSync.qml` 的行号栈帧、`"@:1"` 帧。
    // 断言本身仍然非平凡：`state` 必须是 `building`，且 `statusText` 必须是
    // 「正在构造航线…」—— 那一句写在 `OpsRouteSync.qml` 里给 `_statusText` 赋「正在构造航线…」的那一处，
    // **在两道闸之后、`_plan.startStaticActiveVehicle(...)` 那一句之前**。
    if (stubFetch && expectState != QStringLiteral("failed")) {
        ignoreLogMessage("default", QtWarningMsg,
                         QRegularExpression(QStringLiteral("Could not convert argument 0 from OpsRouteSyncFakeVehicle")));
        // ‼️ 这条**必须**要求栈帧分隔符 `@`：`ignoreLogMessage` 是**部分匹配**，
        //    若只写 `OpsRouteSync\.qml:\d+`，本文件的**真告警**（形如
        //    「qrc:/qml/OpsView/OpsRouteSync.qml:206:5: Unable to assign [undefined] to double」）
        //    会被一并吞掉 ⇒ 「日志里不再出现其它 warning」这条保护在这几格里被削弱。
        //    实测：本用例产生的栈帧原文一律带 `@`（如「_buildAndSend@qrc:/…/OpsRouteSync.qml:474」），
        //    真告警则不带 —— 两边都有原文，见 `l2-raw-warnings.txt`。
        //    ⚠️ 上面那条引文里的 `:474` 是**采集当时的原样**，引文不改：本文件（`OpsRouteSync.qml`）
        //       一增删行它就会漂 ⇒ 定位请按**函数名 `_buildAndSend`**，不要按这个行号去找。
        ignoreLogMessage("default", QtWarningMsg,
                         QRegularExpression(QStringLiteral("[^\"]*@[^\"]*OpsRouteSync\\.qml:\\d+")));
        ignoreLogMessage("default", QtWarningMsg,
                         QRegularExpression(QStringLiteral("\"@:1\"")));
    }

    QQmlComponent component(_engine, QUrl(QString::fromLatin1(kOpsRouteSyncUrl)));
    QVERIFY2(!component.isError(),
             qPrintable(QStringLiteral("加载 %1 失败：%2").arg(QLatin1String(kOpsRouteSyncUrl), component.errorString())));

    QScopedPointer<QObject> sync(component.create());
    QVERIFY2(sync, qPrintable(QStringLiteral("实例化失败：%1").arg(component.errorString())));

    // `start()` 的头三道门（`!vehicle` / `routeId <= 0` / `!get`）必须先过，
    // 否则走不到任何一道高度闸。
    OpsRouteSyncFakeVehicle vehicle;
    sync->setProperty("vehicle", QVariant::fromValue(static_cast<QObject *>(&vehicle)));
    sync->setProperty("routeId", 1);

    // ---- 注入 `get` ----
    // `stubFetch` 为真时，回调**同步**把两条 GET 的响应喂回去，并把回调包在 `try/catch` 里：
    // 三道闸全部放行之后，代码会走到 `_plan.startStaticActiveVehicle(vehicle, …)`，
    // 那一步要求实参是真正的 `Vehicle*`，替身会抛类型错误。**本用例只判到闸为止**
    // ⇒ 越过闸之后的抛错在这里被截断，不影响断言（阳性对照断言的是「已走到 building」）。
    // 为假时注入空实现：`start()` 停在 `fetching`，不碰任何网络/航点逻辑 —— 飞行高度闸
    // 位于这一切之前，用它来验最干净。
    //
    // ‼️ **G3（2026-10-01）：截断 ≠ 丢弃。** 旧写法是裸的 `catch (e) { }`，它吞掉的是
    //    `cb(...)` 里**同步跑完的整段**异常 —— 范围远大于上面那句注释声称的那一处类型错误。
    //    后果：`_buildAndSend` 在到达 `startStaticActiveVehicle` **之前**炸掉时异常同样被吞，
    //    而 `state` 可能**恰好**停在断言的期望值上 ⇒ **假绿**（「跑完了」与「刚过闸就炸了」
    //    不可区分）。⇒ 现在把异常收进 `errSink`，由 `_testGates()` 末尾按**格**判定条数与内容。
    //    ⚠️ 靠日志判**不行**：那道替身转换失败的 warning 已被 `ignoreLogMessage` 按模式忽略
    //    （见 `_testGates()` 开头），别的异常只要带 `@…OpsRouteSync.qml:<n>` 栈帧会被一并吞掉。
    // G3：替身回调里捕获到的异常。声明在 `if` **外面** —— 断言在 `_testGates()` 末尾。
    // `else` 分支注入的是空实现、根本不回调 ⇒ 本对象恒空；那种格由断言处的 `if (stubFetch)` 跳过。
    QJSValue errSink = _engine->evaluate(QStringLiteral("[]"));
    QVERIFY2(errSink.isArray(), qPrintable(errSink.toString()));
    if (stubFetch) {
        const QString factorySrc = QStringLiteral(
            "(function(routeJson, wpsJson, errSink) {"
            "  var route = JSON.parse(routeJson);"
            "  var wps = JSON.parse(wpsJson);"
            "  return function(path, cb) {"
            "    try { cb(200, String(path).indexOf('/waypoints') >= 0 ? wps : route) }"
            "    catch (e) { errSink.push(String(e)); }"
            "  }"
            "})");
        QJSValue factory = _engine->evaluate(factorySrc);
        QVERIFY2(!factory.isError(), qPrintable(factory.toString()));
        QJSValueList args;
        args << routeJson << wpsJson << errSink;
        QJSValue getFn = factory.call(args);
        QVERIFY2(!getFn.isError(), qPrintable(getFn.toString()));
        sync->setProperty("get", QVariant::fromValue(getFn));
    } else {
        QJSValue getFn = _engine->evaluate(QStringLiteral("(function(path, cb) {})"));
        QVERIFY2(!getFn.isError(), qPrintable(getFn.toString()));
        sync->setProperty("get", QVariant::fromValue(getFn));
    }

    // ---- 注入 `task` ----
    if (!taskJson.isEmpty()) {
        QJSValue taskVal = _engine->evaluate(QStringLiteral("(") + taskJson + QStringLiteral(")"));
        QVERIFY2(!taskVal.isError(), qPrintable(taskVal.toString()));
        sync->setProperty("task", QVariant::fromValue(taskVal));
    }  // 否则保持属性默认值 null —— 「task 整个为 null」那一格

    QVERIFY2(QMetaObject::invokeMethod(sync.data(), "start"),
             "start() 不是可调用的 QML 方法 —— 组件没被正确实例化");

    const QString state      = sync->property("state").toString();
    const QString statusText = sync->property("statusText").toString();

    QCOMPARE(state, expectState);
    if (!expectStatusText.isEmpty()) {
        QCOMPARE(statusText, expectStatusText);
    } else if (expectState == QStringLiteral("fetching")) {
        // 飞行高度闸的阳性对照：`start()` 走过那道闸、进到 `fetching`（第一次 `get()`）。
        QCOMPARE(statusText, QStringLiteral("正在获取航线…"));
    } else {
        // 起飞 / 降落闸的阳性对照：`_state = "building"` 与这一句都写在**两道闸之后**
        // （`OpsRouteSync.qml` 里 `_state = "building"` 那一句，以及它后面给 `_statusText` 赋
        // 「正在构造航线…」的那一处）⇒ 走到这里就证明两道闸都没拒这个好值。
        //
        // ‼️ **全串相等**（I1，2026-10-01），**不是** `startsWith("正在构造航线")`。
        //    这一句是 QML 层**唯一**把起降两端组装后的 AMSL 写出来的地方；只判前缀会把夹具
        //    刻意造的区分力**原样丢掉**（本段注释声称的判据是「statusText 必须是「正在构造航线…」」，
        //    而旧代码只比了前缀 ⇒ 断言强度与声称的判据**不对称**）。
        //
        // 期望值**照抄控制方算好的字面量**，**不用 `.arg()` 现算**（避免浮点/格式差异引入假红）。
        // 可复算分解（夹具 `routeJsonOf` 两端地面海拔硬编码 `takeoff=450` / `landing=480`）：
        //   起飞 = 450 + max(60, 0) = **510**      降落 = 480 + max(50, 0) = **530**
        // 落到这一支的四格（起飞两条 + 降落两条阳性对照）输入互不相同、输出**恰好相同** ——
        // 因为地面海拔是常量。它们彼此之间仍靠 `state` 区分（例如把 D6 的 `max` 误实现成
        // 「只取站点值」，第一格会被起飞闸拒 ⇒ state=failed ⇒ 红）。
        QCOMPARE(statusText, QStringLiteral("正在构造航线…（起飞 510 m / 降落 530 m）"));
    }

    // ---- G1（2026-10-01）：**接线段**真的跑过了 ----
    // `_waypointCount` 由 `OpsRouteSync.qml` 的 `_waypointCount = items.length` 写入，位置在
    // 「追加降落端末项 → `routeMissionItems` → `applyLandingAltitude`」三步**之后**、
    // `startStaticActiveVehicle` **之前** ⇒ building 格走到这里它必然已被赋值。
    // 期望值逐格给在数据表的 `expectWaypointCount` 列（`-1` = 不判，用于闸先 `_fail` 的格）。
    // ‼️ **判等、不判 `> 0`**：`> 0` 挡不住「少追加一项」（2 也 > 0）—— 而 2 恰好是
    //    行为 2 形状的**正确**值 ⇒ 只能按夹具形状逐格给期望，写一个通吃的下界是不行的。
    if (expectWaypointCount >= 0) {
        QCOMPARE(sync->property("_waypointCount").toInt(), expectWaypointCount);
    }

    // ---- G3（2026-10-01）：替身回调里捕获到的异常，按**格**判定 ----
    // 期望值不是猜的，是**实测标定**出来的（2026-10-01，本文件当前形状）：
    //   · 走到 building 的格 ⇒ **恰好 1 条**，且是
    //     `TypeError: Passing incompatible arguments to C++ functions from JavaScript is not allowed.`
    //     —— 那来自 `_plan.startStaticActiveVehicle(vehicle, false)`（`OpsRouteSync.qml` 里那一句）
    //     要求真正的 `Vehicle*`、替身在那里被拒。**走到它 == 三道闸都放行了**，正是本格要证的。
    //     ⚠️ 异常串里**没有** `OpsRouteSyncFakeVehicle` 字样 —— 那个词只出现在 QML 写的**日志**里，
    //     不在 JS 异常对象里，按它匹配会**恒红**。
    //   · 其余 `stubFetch` 格 ⇒ **0 条**：闸在 `startStaticActiveVehicle` **之前**就 `_fail` 返回了。
    // ‼️ **不能只判 `>= 1`**：闸**之前**的意外异常（bounds 解析、航点追加）会顶替掉那一条，
    //    而 `state` 仍停在 `building` ⇒ 断言照样绿 —— 那正是 G3 要杀的假绿。下面的 `else`
    //    是它的另一半：**多出来的**异常同样要红。
    if (stubFetch) {
        const int errCount = errSink.property(QStringLiteral("length")).toInt();
        if (expectState == QStringLiteral("building")) {
            QCOMPARE(errCount, 1);
            if (errCount == 1) {
                const QString msg = errSink.property(0).toString();
                QVERIFY2(msg.startsWith(QStringLiteral("TypeError: Passing incompatible arguments")),
                         qPrintable(QStringLiteral("building 格里捕获到的异常不是那道已知的替身类型错误 ⇒ "
                                                   "`_buildAndSend` 在到达 `startStaticActiveVehicle` 之前"
                                                   "就炸了（而 state 恰好停在 building ⇒ 假绿）。实际：") + msg));
            }
        } else {
            QCOMPARE(errCount, 0);
        }
    }
}
