# RomView 抽取与新增 — 设计稿

日期：2026-09-21 ｜ 仓库：`~/qgroundcontrol`（QGC fork，分支 `qgc-abcmav-px4`）
状态：设计已获用户批准；本稿为落盘固化。

---

## 1. 目标

新增 `RomView`——**航线监控员（ROUTE_MONITOR）登录后的主界面**，与 `OpsView`（站点操作员 SITE_ATC）并列。
两者**骨架、数据源、任务列表完全一致**，差异只在右栏下半区（机位平面图）与少量专属控件。

真正的目标不是"再写一个视图"，而是**把 `OpsView.qml`（1580 行）按职责拆开，让 `RomView` 复用而不是复制**。
复制一份 1580 行将产生两个必须同步修改的判据副本——本视图里几乎所有判据都是 fail-closed 的门控（能不能起飞、
能不能发降落指令、双身份与否），副本漂移的后果是静默放行。

---

## 2. 前提（已核实，非假定）

| 事实 | 判据 |
|---|---|
| 真库中 **ATC + RM 双身份 = 0 人** | 只读查询 `table_user_role` |
| 跨级组合（任一平台级 + 任一场地级）= **空** | 同上 |
| 后端 `ValidateRoleGrants` **有** `onlyATC && onlyRM` 显式豁免分支 | `common/models/roles.go:100-116` |
| webui **已**实现两级角色互斥（置灰 + 提交校验 + 编辑级别锁死） | `web-ui/src/views/user/UserList.vue:142-172, 327-329` |
| `roleInQGCAllowed` 白名单已含 `FLIGHT_SUPERVISOR` | `gcs_server/handlers/auth.go:35` |
| `.pragma library` 中 **`qsTr` 可用** | 离屏 QML 探针实测：`typeof === "function"`，返回实际文案 |

**用户裁定（2026-09-21）**：「这两个身份不允许重叠，不存在双身份」——**有数据支撑**。
后端豁免分支**保留不删**，webui 互斥使实际建不出双身份，QGC 据此按**单身份**分流。

---

## 3. 文件边界

四个文件，同属 `OpsViewModule`（`src/OpsView/`）：

| 文件 | 职责 | 不负责 |
|---|---|---|
| `OpsCommon.js` | **纯函数库**（`.pragma library`）：展示映射、交接派生、本地报文判定、流向派生 | 任何 QML 属性读取、任何 QML 单例 |
| `TaskListPanel.qml` | 任务列表（可选标题 + `ListView` + 卡片 delegate + 行内按钮） | 网络、弹窗、机位、地图 |
| `OpsShell.qml` | **骨架 + 数据源**：地图、右栏容器、命令条、底部状态栏、仪表、轮询与全部 HTTP、三个通用弹窗 | 角色判据、机位、飞控动作实现 |
| `OpsView.qml` | **瘦身**为 `OpsShell { 站点右栏（机位区）+ 飞控动作 }` | — |
| `RomView.qml` | **第二步**：`OpsShell { 监控员右栏 }`，约 50 行 | — |
| `SlotLayout.qml` | 不动 | — |

### 3.1 为什么纯函数要放 `.pragma library`

QML 里**方法调用不注册绑定依赖**——在 QML 文件内定义函数，函数体里读到的属性变化
**不会**让调用点重估（`OpsView.qml:23-24` 有同类记录：读 `AuthController.roles` 属性而非
`hasRole()` 方法，正是这个原因）。

搬进库文件后，一切输入必须走**实参**，绑定依赖因此落在调用点的实参表达式上——这正是两个视图
能共用同一份判据、还各自正确刷新的机制。代价是**依赖 QML 单例的判定搬不进去**（`multiVehicleManager`
/ `AuthController` / `QtPositioning` 在库文件里不存在，写了不报错、只求值为 `undefined`），
这类判定留在视图侧，用**函数属性**注入。

---

## 4. 接口契约

### 4.1 `OpsCommon.js`（导出）

常量：`taskCardGap = 6`（任务卡间距 = 机位间距，单点定义）

```
taskNo(task)
statusLabel(s)                                // ⚠️ 原文无 qsTr，保持
phaseToLabel(p)
displayStatus(task, handoverById)
statusColor(task, nowMs, handoverById)
taskNature(task, mySiteId)
routeNature(task)
uavStatusLabel(s)

handoverFor(task, handoverById)
pendingPhase(task, phase, handoverById)
landingAccepted(task)
isMine(handover, userId)
deadlineMs(handover)
remainingSec(handover, nowMs)
isTimeout(handover, nowMs)

isCruising(task) / isLandedOnGround(task)
hasLiveTelemetry(task, nowMs, windowMs)

isOutbound(task, mySiteId, handoverById)
isInbound(task, mySiteId, handoverById)
siteTasks(tasks, outbound, inbound, mySiteId, handoverById)
routeTasks(tasks)
```

约定：**被判定对象在前，上下文参数在后**。所有判定函数返回**真 bool**（`!!` 不可省）。

### 4.2 `TaskListPanel.qml`

**输入属性**

```
tasks / pending / handoverById / nowMs / mySiteId / selectedTaskId
showSiteActions : bool      // 站点视图 ∧ SITE_ATC
isRouteMonitor  : bool
spacing / cardMargin / cardRightGap : real
headerText      : string    // 空串则不显示标题行
takeoffBlockReasonFn / canTakeoffFn : var   // 注入（依赖 multiVehicleManager，无法纯函数化）
```

**输出信号**

```
taskSelected(task)                     // 替代原来的 _selectedTaskId=… + _syncSlotForSelection(…)
takeoffRequested(task) / landRequested(task) / parkRequested(task) / assignSlotRequested(task)
handoverProposed(taskId, phase) / handoverCancelRequested(handoverId)
```

**为什么 `takeoffBlockReasonFn` 用注入而不是搬进库**：`_takeoffBlockReason` 要遍历
`multiVehicleManager.vehicles` 判在线、要读 `_slots` 判有机位——两者都是 QML 单例/视图状态。
注入的函数属性与原方法**依赖结构等价**（绑定依赖同为 `modelData` + delegate 重建），行为不变。

### 4.3 `OpsShell.qml`

**输入属性**：`overviewView : "site" | "route"`（**由视图传入，骨架自己不再判角色**）

**输出信号**：`signal polled()`（每次轮询后发；机位请求挂在它上面，OpsView 连、RomView 不连）

**两个对称注入槽**（用户 2026-09-21 明确要求）：
- 命令条右侧扩展区（`commandBarExtras` 内）
- 右栏下半区（站点视图放机位平面图）

**归属**

| 留在 OpsShell | 理由 |
|---|---|
| `_tasks` / `_pending` / `_handoverById` / `_selectedTaskId` / `_now` / `_mockVehicle` | 两个视图共用 |
| 全部 HTTP（`_send`/`_get`/`_post`）与轮询 | 数据源 |
| `_fetchOverview` / `_fetchPending` / `_notifyNewPending` | 数据源 |
| 交接四动作 `_proposeHandover` / `_acceptHandover` / `_rejectHandover` / `_cancelHandover` | 纯网络，两视图共用 |
| 地图、右栏容器、命令条、底部状态栏、姿态仪/罗盘、`handoverDialog` | 骨架 |
| `_firstTaskCoord` | 用 `QtPositioning` |
| `signal taskSelected(task)`（供视图侧同步机位） | — |

| 移到 `OpsView` | 理由 |
|---|---|
| `_slots` / `_slotsAll` / `_fetchSlots` / `_fetchSlotsAll` / `_decorateSlots` / `_slotsMapView` | 机位专属 |
| `_slotById` / `_slotAssignable` / `_slotAssignHint` / `_slotForTask` / `_taskForSlot` / `_selectSlot` / `_syncSlotForSelection` | 机位专属 |
| `_vehicleForTask` / `_uavOnline` / `_takeoffBlockReason` / `_canTakeoff` | 依赖 `multiVehicleManager` 与机位 |
| `_execPendingAction` / `_guidedTakeoff` / `_guidedLand` / `_execLand` / `_assignSlot` | 飞控动作 |
| `_pendingAction` / `actionConfirmDialog` / `slotDialog` / `landBlockDialog` / `_landBlockReason` | 站点专属弹窗 |
| `_slotOrient` / `_slotOrientSettingsKey` / `_loadSlotOrient` / `_showSlotLayout` / `_rightPanelW` | 机位平面图 |

### 4.4 角色分流判据

`MainWindow.qml` 的 `_onLoginSucceededForRole()`：按**单身份**分流
（`SITE_ATC` → `OpsView`；`ROUTE_MONITOR` → `RomView`；`FLIGHT_SUPERVISOR` → 待定，保持现状）。
双身份切换控件（`OpsView.qml:854-878`）**删除**——用户裁定不存在双身份。

---

## 5. 构建注册

`src/OpsView/CMakeLists.txt` 的 `qt_add_qml_module` → `QML_FILES` 增加
`OpsShell.qml` / `TaskListPanel.qml` / `RomView.qml`；`OpsCommon.js` 需作为
**JS 资源**注册（`qt_add_qml_module` 的 `QML_FILES` 可含 `.js`，或单列 `RESOURCES`）。

⚠️ QML 经 `qt_add_qml_module`（`RESOURCE_PREFIX /qml`）编成 rcc 资源进二进制
⇒ **改完必须重启 QGC**，不能只重跑进程。

---

## 6. 验证

**第一步（抽取）的验收标准：行为一个比特都不变。**

| 手段 | 判据 |
|---|---|
| `OpsCommon.js` 离线探针 | 逐函数断言（含时区、`undefined` 传染、流向边界），全 PASS |
| `source .venv/bin/activate && just build` | 构建通过；构建输出含 `Running rcc for ... OpsViewModule` |
| 离屏起 QGC | `QT_QPA_PLATFORM=offscreen` + `XDG_CONFIG_HOME=<tmp>` + `--allow-multiple`（⚠️ 不是 `--allow-multiple-instances`，写错只打印 `Unknown option` 且 exit=1） |
| 真实库副本端到端 | `GCS_PORT` + `GCS_DB_PATH` 起第二实例，登录 SITE_ATC 走完整界面流程 |

⚠️ 抽取的真实风险**不是**"构建过不过"，而是 **QML 读不存在的属性不报错、只给 `undefined`**——
写错一个属性名界面会**静默坏掉**。所以每一处跨文件引用都必须亲眼核对，且验证要**看界面**，
不能只看构建通过。

⚠️ 本机 `grep` 是包装 `ugrep --ignore-files` 的 shell function，会静默跳过 `.gitignore` 目录
⇒ 一切"X 是否存在"的检查必须用 `command grep`。

---

## 7. 范围外（本轮不做）

- **后端不改**（用户裁定：「后台暂时不处理」）。
- **webui 不改**——两级角色互斥**已实现**（`UserList.vue:142-172`），无需改动。
- `roles.go` 的 `onlyATC && onlyRM` 豁免分支**保留不删**（后端本轮不动）。
- `helpers.go:216-228` `canListAll` 的 `if r == RoleRouteMonitor { continue }` **一行都不动**：
  它不是双身份补丁，**纯 RM 也需要它**（RM 是平台级角色，不 `continue` 会全量可见）。
  只是注释里"否则双身份会绕过"的理由过时——订正注释，不改逻辑。

---

## 8. 待订正的文档

`docs/docs/qgc/飞行监控主界面设计.md`（`docs/docs` → `~/abc_common/docs` 符号链接）：
`:68-73` 角色→跳转表、`:77` 双身份并存、`:148` 双身份视图切换、`:226-237` UI 图、
`:243` 命令条双身份控件、`:386` 分流说明——全部订正为**单身份分流**的实际状态。

---

## 9. 第一步实施记录（2026-09-21，与 §4.3 的偏差）

抽取已完成并落盘：`OpsShell.qml`（新）/ `OpsView.qml`（瘦身）/ `TaskListPanel.qml`（新）/
`OpsCommon.js`（新），四个文件均已注册进 `CMakeLists.txt` 的 `QML_FILES`。
以下是与 §4.3 的**实际差异**——§4.3 是按职责推演的，实现时撞到两条 QML 作用域事实，
不得不改形状。逐条记下，供第二步参照。

### 9.1 骨架多了一个输入 `rightPanelWidth`

§4.3 只列了 `overviewView` 一个输入。实际多一个 `rightPanelWidth : real`（缺省 340）：
右栏是骨架的容器，而"多宽"由站点视图按机位图所需宽决定。骨架**不判角色**这条纪律未破——
它只是收一个数字。（原 `_rightPanelW` 是函数，现改为属性输入。）

### 9.2 `slotLayout` 的两个尺寸必须**回送**，不能跨文件读

`slotLayout` 声明在注入的 `Component` 里。骨架/视图在组件展开**之前**读它只会拿到 `null`，
而此后**没有任何 NOTIFY 会让那个绑定重估** ⇒ 边栏宽会被永久钉死在 340。故：

- 组件**内部**放一个 `Binding { target: opsView; property: "_slotDesiredPanelWidth"; value: slotLayout.desiredPanelWidth }`
  ——依赖因此落在"一个真属性发生变化"这件有信号的事上；
- 同理 `_slotAreaH` **不再存在**：它原本要读 `slotLayout.naturalHeight`，现改为在组件内部就地展开成
  `Math.min(_slotAreaMaxH, slotLayout.naturalHeight + _slotMargin)`（下面的 `slotFlick._areaH`）。
  防成环纪律不变——`_slotAreaMaxH` 仍由骨架转发的 `rightPanel`/`instrumentsBlock` 尺寸推出，
  **依旧不许读 `siteViewArea.height`**。
- 骨架新增三个转发属性 `rightPanelHeight` / `instrumentsHeight` / `instrumentsVGap`
  （`rightPanel`/`instrumentsBlock` 是骨架的内部 id）。

**判据（实测）**：把 `Binding.value` 单变量变异为 `4711` 后离屏跑，探针打出
`sentW=4711 wantW=340` ⇒ 回送链路确实是活的（若只在原地读，两值会相同）。已撤销变异并双向复核
（源码与二进制里 `PROBE-`/`4711` 命中数均为 0）。

### 9.3 双身份控件本轮**保留未删**

§4.4 要求删除双身份切换控件——那是**第二步**的事。第一步的验收标准是"一个比特都不变"，
故 `_isDual` / `_showSiteView` / 命令条上那组「站点/监控员」按钮**原样保留**，
`overviewView` 也仍写着 `(_showSiteView && _isSiteATC) ? "site" : "route"`（等价于原 `_currentView()`）。

### 9.4 `selectTask()` 成为选中任务的**唯一写点**

骨架新增 `function selectTask(task)`：写 `_selectedTaskId` 并发 `taskSelected(task)`。
地图 marker 与两个列表都走它——此前两处各写各的。视图侧仍用 `onTaskSelected` 接信号做机位同步。

### 9.5 零回归的机械核对（不靠肉眼）

| 检查 | 结果 |
|---|---|
| 字符串字面量集合差（旧 242 条 vs 新四文件并集 255 条） | **无用户可见文案丢失**；唯一"缺"的是一条被重新折行的注释片段 |
| 函数定义集合差（旧 63 vs 新 63） | 23 个纯函数移入 `OpsCommon.js`（仅去掉 `_` 前缀）；`_currentView` ⇒ `overviewView` 属性（等价）；新增 `selectTask` |
| 旧站点列表 `Layout.topMargin` | 旧值本就是 **0**（无此属性）⇒ 面板的 `headerText !== "" ? 4 : 0` 得 0，一致 |
| 旧监控员列表 `Layout.topMargin` | 旧值本就是 **4** ⇒ 同一三元式得 4，一致 |
| 离屏启动（`QT_QPA_PLATFORM=offscreen` + 隔离 `XDG_CONFIG_HOME` + `--allow-multiple`） | 输出中**零** QML 报错/警告（无 Duplicate / Binding loop / TypeError / is not a type） |
| 注入槽是否真的展开 | 临时探针实测 `rightPanelContent` 的 Loader **确实实例化**（能读到 `slotLayout.desiredPanelWidth`）⇒ 上面那份"干净日志"不是"组件压根没建"的假绿 |

**仍未验证的**（诚实记下，留给用户真机验收）：视图 `visible: false` 直到登录，离屏拿不到渲染画面，
故**布局尺寸（右栏宽、机位区高、卡片位置）与点击行为只能由登录后的真机确认**。

---

## 十、第二步实施记录（RomView + 单身份分流）

第一步经用户验收通过后执行。**代码侧全部完成并验证；文档订正同批完成。**

### 10.1 三处改动

**① 新建 `src/OpsView/RomView.qml`**（约 80 行，其中一半是注释）

只写与 `OpsView` **不同**的那部分：

- `overviewView: "route"`；
- 右栏放一个 `TaskListPanel`，`showSiteActions: false` / `isRouteMonitor: _isRouteMon`；
- `rightPanelWidth` **刻意不传**（用骨架缺省 340：没有机位平面图，就没有"按图所需宽伸缩"这回事）；
- `commandBarExtras` **刻意不填**（出站/进站与机位朝向都是站点专属语义）；
- **不连** `polled()`（机位是站点专属数据，监控员拉它没有消费者）。

已注册进 `src/OpsView/CMakeLists.txt` 的 `QML_FILES`。

**② `OpsView.qml` / `OpsShell.qml` 去双身份**

| 删除 | 说明 |
|---|---|
| `_isRouteMon` / `_isDual` / `_showSiteView` | 双身份判据，全部随身份互斥失效 |
| 命令条上「站点／监控员」切换 `Row` | 没有可切换的第二种形态（原 §4.4 要求） |
| 视图内监控员分支 `Item` | 已独立成 `RomView.qml` |

`_showSlotLayout` **保留**（名字是语义化的"机位图是否在场"），判据收敛为 `_isSiteATC` 一个条件。

骨架**新增** `_taskCardMargin: 10`：任务卡左空位原在 `OpsView.qml` 上由机位边距派生
（`_taskCardMargin: _slotMargin`），拆开后那根线断了。提升到骨架做单点定义，方向顺势掰正为
**任务卡是源、机位是派生**（`OpsView._slotMargin: _taskCardMargin`），与 2026-09-18 用户要求
「机位间隔参照任务列表中两个卡片的间隔」一致。值不变，两视图天然同值。

**③ `MainWindow.qml` 单身份分流**

`_onLoginSucceededForRole()` 成为**全仓唯一**判据：`SITE_ATC → showOpsView()`、
`ROUTE_MONITOR → showRomView()`、其余 → `showFlyView()`。新增 `showRomView()`/`hideRomView()`
（与 `showOpsView()` 逐行对称），三个 `showXxxView` 各补一行 `romView.visible = false`。

⚠ 判据用 `hasRole()`（方法）而非 `roles.indexOf()`（属性）：**只有绑定**才需要读属性来注册依赖
（见 §4.4 与第一步的 C1 教训）；本函数是信号回调里的一次性判断，不参与绑定重估。

### 10.2 刻意不动的地方

- **后端一行未改**（用户裁定"先不改后端"）。`roles.go` 的 `onlyATC && onlyRM` 豁免分支保留 ——
  前端互斥后它等价于死代码，删它属独立改动。
- **`OpsView.qml` 的 `_isSiteATC` 读取方式不变**（仍是 `roles.indexOf` 属性读法）。

### 10.3 验证记录

| 检查 | 结果 |
|---|---|
| 探针（RomView 根 + TaskListPanel 级） | `overviewView=route`、`headerText=负责航线 · 执行中`、`cardMargin=10`，右栏注入槽**确实展开** |
| 单变量变异（`_taskCardMargin` 10 → 4711） | 探针应声打出 `4711` ⇒ 回送链路是活的，且确认 RomView 确实从**骨架**读该属性 |
| 撤销变异 + 删探针后的残留 | 三个源文件 `PROBE-`/`4711` 命中 0；二进制内命中 0；最终离屏探针输出 0 行 |
| 去双身份残留 | `_showSiteView`/`_isDual` 在 `OpsView.qml` 零残留 |
| 离屏启动 | 零 QML 报错/警告 |
| `just build` | exit 0；`RomView.qml` 已进 `build/qml/QGroundControl/OpsView/` |

⚠ **离屏零报错不构成正面证据**：QML 读不存在的属性不报错、只给 `undefined`（NaN 赋 int 更会静默变 1）。
故必须加探针取正面证据，并用变异确认探针本身是活的 —— 这一步不能省。

**仍未验证的**（同第一步）：视图 `visible: false` 直到登录，离屏拿不到渲染画面，
**RomView 登录后的实际布局与点击行为只能由用户以 ROUTE_MONITOR 账号真机验收**。

### 10.4 文档订正（`docs/qgc/飞行监控主界面设计.md`）

按 §8 清单执行，实际改了 **10 处**（比 §8 列的多，因为连带处不少）：

| 位置 | 改动 |
|---|---|
| 头部修订记录 | 追加 **v11（2026-09-21）单身份拆分** 条目 |
| §二 角色跳转表 | `ROUTE_MONITOR` 改 `showRomView()`；**删除「双身份并存」行** |
| §二 说明段 | "**刻意偏离**"段改为"**现已一致**"（含 webui 两级互斥、真库 0 人、后端分支保留三点） |
| §3.2 `accepted_by != proposed_by` | 原括注"双身份/多角色用户不得自提自接"订正：双身份废除后该校验恒真，保留作防御性约束 |
| §4 `?view` 过滤引言 + 视图判别 | 删"双身份用户由前端显式传"；判别段改为**单身份**，说明每个用户只对应一个 `view` |
| §5.1 布局 | 标题改 `src/OpsView/`（骨架 + 两视图）；布局图命令条行改"本视图专属控件(注入槽)"；补一句"右栏两栏是同一位置的两种形态，非并存" |
| §5.2 命令条 | "双身份切换"从控件清单删除；补 `commandBarExtras` 注入槽说明与让位说明 |
| §5.2 锚点条目 | "三组"改"两组"（含 2026-09-18 教训保留）；**新增白字条目**（本窗口用户裁定，含 1.72:1 实测） |
| §六 对照表两行 | 双身份两行加删除线 + "已废除/前提已消失"，并注明 `canListAll` 的独立议题未消失 |
| §九 改动清单 | QGC 侧补 §10.1① 的现状；MainWindow 条目补 `showRomView` 与唯一判据；AuthController 条目改"按角色分流"；后端 `ValidateRoleGrants` 条目**标注作废** |
| §11.1 / 新增 §11.5 | 分流说明改单身份；**新增 §11.5 单身份拆分实施记录**（动因、两步、刻意决定、验证记录、未验证项、后端未动） |
