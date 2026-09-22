# P5 接引链路 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 QGC 能把「需要监控的飞机」全集（而非前 16 架）通过 80005 分批轮转接引到 mavp2p，并能检测某架飞机多久没收到帧、超时则定向重发同一条登记。

**Architecture:** 改动集中在 `CryptoController` 这一个 C++ 单例（分批游标 + 监控清单 + 收帧时间戳 + 定向重发），加上三处接线：`MAVLinkProtocol` 的两个收帧分支各加一行 `noteDeviceFrame`、`AuthController` 登录成功后触发加速首轮、`RomView.qml` 在每次轮询成功后推送清单与阈值并做超时检查。**mavp2p 与 80005 协议零改动**——分批方案成立的依据是 `m.pairs` 累积且只按 TTL 过期（设计文档 §3.2）。

**Tech Stack:** C++20 / Qt 6.11（`QTimer`、`QMutex`、`QElapsedTimer`、`QVariantList`）、QML（QtQuick）、Qt Test（`UnitTest` 框架 + `MultiSignalSpy`）、CMake + `add_qgc_test`。

**Spec:** `docs/docs/qgc/航线监控员主界面设计-20260922.md`（§3 全章；§8.2 的改动清单；§9.2 的判据表）

## Global Constraints

以下每条都取自设计文档，**每个任务的要求都隐含包含本节**。

1. **`MAX_QGC_LINKED_PX4` 保持 16 不动**（`src/MAVLink/Extensions/VTOLSafetyMessages.h`）。它现在表达的是「每批多少」，恰好仍是 16（§3.2/§3.3）。
2. **`mavp2p` 零改动**（它在仓库外 `~/uavm/mavp2p`，是第三进程）。不改 `--max-qgc-linked-px4`，不改 `--map-ttl`（§3.2）。
3. **协议零改动**：不扩 `deviceIDs` 数组、不加新消息、不改 `mavlink_msg_qgc_registration_pack`（§3.2）。
4. **容量天花板 `n ≤ 80`**（`batches = ceil(n/16) ≤ 5`，因为 `batches × 10s < 60s` 的 TTL 约束，§3.4）。超过时**不扩上限**，按 §3.4 的升级路径另行处理。
5. **`deviceBytes` 必须是定长 `uint8_t[MAX_QGC_LINKED_PX4 * 4]`**，`count` 只控制填几个与传给 pack 的 `deviceIDCount`。**绝不写成 `uint8_t deviceBytes[count * 4]`**——那是 VLA，GCC 作为扩展接受但不是标准 C++，MSVC 直接编译失败，本仓是多平台构建（§3.3 关键点 1）。
6. **超时只触发「多发一次」，永远不触发「少登记一个」**。任何情况下都不得把飞机移出 `_monitorDevices`（§3.6.2，这是本节最重要的一条）。
7. **`noteDeviceFrame` 必须加在两个收帧点各一行**（`src/Comms/MAVLinkProtocol.cc` 的明文待命心跳支、加密帧支），**不加在 `learnDeviceSystemMapping` 内部**（那个名字只承诺「学习映射」，§3.6.1）。
8. **判据是「该 deviceID 的任意一帧」，不是心跳帧**。命名必须叫 `msSinceLastFrame`，**不得**叫 `msSinceLastHeartbeat`（§3.6.1，只说心跳会让判据在接引成功的那一刻起永久失效）。
9. **超时阈值与清单必须同一次调用传入**（`setMonitorDevices(ids, frameTimeoutMs)`），**不得拆成两个 setter**——那会造出「新阈值配旧清单」的中间态（§3.6.4）。
10. **轮询失败时 QML 侧什么都不做**（保留上一次的清单）。**绝不可**把「请求失败」当成「没有需要监控的飞机」——那会清空登记集合，所有飞机在 60s TTL 后集体掉线（§3.5.4）。
11. **`frame_timeout_ms` 缺失或非法时用编译期默认 `DEFAULT_FRAME_TIMEOUT_MS = 3000`**，且**不报错、不清空清单**（§3.5.4）。
12. **不在 QGC 的 `.ini` 里再放一份超时配置**。只有两处：后端下发 + 编译期默认（§3.6.4）。
13. **批间隔用 `QTimer::singleShot` 串，绝不用 `QThread::msleep` 或忙等**——那会卡住 GUI 线程（§3.4）。
14. **`device_id <= 0` 或签名位非法的 id 必须被跳过并记日志**，不能默默变成 0（§3.5.2/§3.5.3）。
15. **UI 不得显示原始枚举值**（本仓库全局规则）。
16. **单测是 strict mode：未预期的日志 = 用例失败**。要期待某条日志用 `expectLogMessage(精确类别串, ...)` + `verifyExpectedLogMessage()`，**禁 `QTest::ignoreMessage`**。类别真名照抄日志行末尾那段：`CryptoController` 是 `MAVLink.Crypto.CryptoController`，`MAVLinkProtocol` 是 `Comms.MAVLinkProtocol`。
17. **`just` 前必须 `source .venv/bin/activate`**（系统 `just` 1.21 太老）。`ctest` 的工作目录必须是 `build/`。
18. **`just lint` 的 QML 检查在本机必红**（PATH 里的 `qmllint` 是 Qt5 老版、不认 `--bare`），与文件无关。要比对 lint 结果必须用 `~/Qt/6.11.1/gcc_64/bin` 那份，且**同目录、看消息类别**而非总数。

---

## 与设计文档的偏差：三处裁定（执行前必读）

写本计划时逐行核过设计文档 §3 与 §8.2，发现三处**文档内部矛盾或缺口**。按 superpowers 的「spec 是约束权威、plan 是它的论证」原则，下面三条在此裁定并记录。**执行时按本计划走，不要回改设计文档**（改文档需用户批准，另行走一次提交）。

| # | 文档原文 | 问题 | 本计划的裁定 |
|---|---|---|---|
| R1 | §3.3 伪码 `const int count = qMin(n, batch);` | n=18、batch=16 时 `count` 恒为 16 ⇒ 每批发满 16 个、游标步进 16。而 §9.2 的实测判据写的是「`deviceID_num` 依次为 **16、2、16、2…**」，§3.4 的 `batches = ceil(n/16)` 也是「切批」语义 | **采用「切批」**：`count = qMin(batch, n - cursor)`。理由：与 §9.2 判据、§3.4 的 `batches` 定义都一致；且第二批只带 2 个 deviceID（8 字节）而不是 16 个（64 字节）。`n ≤ batch` 时退化为现状，与 §3.3 关键点 3 相容 |
| R2 | §3.6.2 伪码 `if (msSinceLastFrame(id) > frameTimeoutMs)` | `msSinceLastFrame` 对「从未收到帧」返回 `-1`（§3.6.1 的 API 契约），而 `-1 > 3000` 为假 ⇒ **从未收到过帧的飞机永远不触发重发**。可「接引失败」恰恰是本节要自愈的头号场景（§3.6.3 的场景表第 2 行） | **`since < 0` 与 `since > timeout` 同判**（`if (since < 0 \|\| since > timeout)`）。理由：约 24 字节/2s/架的代价，而 §3.6.2 自陈「误判的代价是一个 24 字节的帧，这允许判据取得比较激进」 |
| R3 | §8.2 路径 `src/MAVLink/MAVLinkProtocol.cc` | 该文件**实际在 `src/Comms/MAVLinkProtocol.cc`**（`src/MAVLink/` 下没有它） | 按 **`src/Comms/MAVLinkProtocol.cc`** 改 |

**另有两处缺口**（文档没写，本计划补上并给出理由）：

| # | 缺口 | 本计划的裁定 |
|---|---|---|
| G1 | `CryptoController` 当前**没有暴露给 QML**（无 `QML_ELEMENT`、不在任何 `qt_add_qml_module` 里，`instance()` 只在 C++ 内用），但 §8.2 要求 RomView 调 `cryptoController.setMonitorDevices(...)` | 用 **`qmlEngine->rootContext()->setContextProperty(QStringLiteral("cryptoController"), ...)`**，落在 `QGCCorePlugin::createQmlApplicationEngine()`，与紧邻的 `joystickManager` / `planUploader` 同形。**不给它加 `QML_SINGLETON`**：那需要把它加进某个 QML 模块的 SOURCES 并处理 `create()` 语义，改动面大且与本设计无关 |
| G2 | §3.6.2 说「立即单独发一个只含该 deviceID 的 80005 报文」，但**没有给这个入口的函数名**——而超时检查按 §8.2 是在 QML 里做的，必须有一个 `Q_INVOKABLE` 可调 | 新增 `Q_INVOKABLE void reRegisterDevice(quint32 deviceID)` |

> ⚠️ **G2 的一个连带裁定**：§3.5.3 的图把「超时检查每 2s」画在 `setMonitorDevices` 下面（像 C++ 内部定时器），而 §8.2 逐字写的是「每 2s 调 `cryptoController.msSinceLastFrame()`」。**采信 §8.2**（QML 驱动），因为 `msSinceLastFrame` 被设计成 `Q_INVOKABLE`——若走 C++ 内部定时器，它应当是 private 的普通方法。C++ 侧因此**不新增定时器**。

---

## File Structure

| 文件 | 责任 | 任务 |
|---|---|---|
| `src/MAVLink/Crypto/CryptoController.h` | 新增 API 声明、`_monitorDevices` / `_frameTimeoutMs` / `_regCursor` / `_lastFrameMs` / `_frameClock` 成员 | 1, 3, 4, 5, 6 |
| `src/MAVLink/Crypto/CryptoController.cc` | 上述实现；`_sendRegistration` 拆出 `_sendRegistrationFrame` | 1, 3, 4, 5, 6 |
| `src/Comms/MAVLinkProtocol.cc` | 两个收帧分支各加一行 `noteDeviceFrame` | 2 |
| `src/Auth/AuthController.cc` | 登录成功后触发加速首轮 | 5 |
| `src/API/QGCCorePlugin.cc` | 把 `cryptoController` 暴露给 QML | 7 |
| `src/OpsView/RomView.qml` | 轮询成功推送清单+阈值；每 2s 超时检查 | 8 |
| `test/MAVLink/CryptoTest.h/.cc` | `CryptoController` 的单元用例 | 1, 3, 4, 5, 6 |
| `test/Comms/MAVLinkCryptoFrameTest.h/.cc`（新） | 两个收帧分支的接线（集成） | 2 |
| `test/Comms/CMakeLists.txt` | 注册新测试文件与 `add_qgc_test` | 2 |

**明确不动**：`src/MAVLink/Extensions/VTOLSafetyMessages.h`（`MAX_QGC_LINKED_PX4` 保持 16）、`~/uavm/mavp2p`（仓库外）、`OpsCommon.js`（属 P2）、`OpsShell.qml` 的轮询结构（RomView 复用它的 `_get`，不改它）。

---

### Task 1: 收帧时间戳 API

**Files:**
- Modify: `src/MAVLink/Crypto/CryptoController.h`（在 `learnDeviceSystemMapping` 声明之后）
- Modify: `src/MAVLink/Crypto/CryptoController.cc`（在 `learnDeviceSystemMapping` 定义之后）
- Test: `test/MAVLink/CryptoTest.h`、`test/MAVLink/CryptoTest.cc`

**Interfaces:**
- Consumes: `MAVLinkCrypto::DeviceID`（`uint32_t`）、`kInvalidDeviceID`（`DeviceID.h`）
- Produces:
  - `void CryptoController::noteDeviceFrame(DeviceID deviceID)`
  - `Q_INVOKABLE qint64 CryptoController::msSinceLastFrame(quint32 deviceID) const` —— 返回毫秒；**`-1` = 从未收到**

> **为什么时间戳表不需要清理**：条目数 = 本进程见过的 deviceID 数（上限即平台设备数，当前 18、天花板 80），内存可忽略；而加清理就会引入「清理时机」这个新判据，是净损失。故**不做清理**，并在头文件注释里写明这是有意的。

- [ ] **Step 1: 写失败测试**

在 `test/MAVLink/CryptoTest.h` 的 `private slots:` 里追加（放在「防重放」那组之后即可）：

```cpp
    // 收帧时间戳（§3.6.1）：判据是「任意一帧」不是「心跳帧」，载体是本地单调时钟
    void _testNoteDeviceFrame();
```

在 `test/MAVLink/CryptoTest.cc` 末尾（`UT_REGISTER_TEST_LIGHTWEIGHT` **之前**）追加：

```cpp
void CryptoTest::_testNoteDeviceFrame()
{
    // §3.6.1：QGC 必须自己记 per-deviceID 的收帧时刻——不能用服务端的
    // last_heartbeat_at（接引成功后反而停更）或 last_telemetry_at（回答的是
    // 另一个问题："飞机有没有在发"，而非"mavp2p 有没有转给我"）。
    //
    // 三个读数各有判别力，缺一不可：
    //   ① 从未收到 = -1（不是 0——0 会被下游当成"刚刚收到"）
    //   ② 收到后 ≈ 0
    //   ③ 时间在走（读数随时钟增长）——只测 ①② 的话，一个"恒返回 0"的
    //      实现会全绿，而它在生产里的表现是"永不超时"，即整个机制失效
    CryptoController* const crypto = CryptoController::instance();
    const DeviceID deviceID = 0x0A0B0C10u;  // 本用例独占：单例状态跨用例共享

    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));

    crypto->noteDeviceFrame(deviceID);
    const qint64 t0 = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(t0 >= 0 && t0 < 100, qPrintable(QStringLiteral("t0=%1").arg(t0)));

    QTest::qWait(60);
    const qint64 t1 = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(t1 >= 50, qPrintable(QStringLiteral("t1=%1").arg(t1)));

    // 再次收帧 ⇒ 时间戳被刷新。
    // 变异自证：把 _lastFrameMs.insert 改成"仅当不存在时插入"，此处变红。
    crypto->noteDeviceFrame(deviceID);
    const qint64 t2 = crypto->msSinceLastFrame(deviceID);
    QVERIFY2(t2 < 50, qPrintable(QStringLiteral("t2=%1").arg(t2)));

    // 非法 deviceID 不记账。0 是 kInvalidDeviceID；一条 device_id=0 的登记会在
    // mavp2p 里建出一个无意义的 pair（0x00000000），且没有任何一处会报错（§3.5.2）。
    crypto->noteDeviceFrame(kInvalidDeviceID);
    QCOMPARE(crypto->msSinceLastFrame(kInvalidDeviceID), qint64(-1));
}
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
```
Expected: 编译失败，`error: no member named 'noteDeviceFrame' in 'MAVLinkCrypto::CryptoController'` 与 `no member named 'msSinceLastFrame'`。

- [ ] **Step 3: 实现**

`src/MAVLink/Crypto/CryptoController.h`：

在顶部 include 区加 `#include <QtCore/QElapsedTimer>`（与既有的 `QHash`/`QTimer` 并列）。

在 `learnDeviceSystemMapping(DeviceID deviceID, uint8_t systemID);` 声明**之后**加：

```cpp
    /// 记录「收到了该 deviceID 的任意一帧」的时刻（设计文档 §3.6.1）。
    ///
    /// ‼️ 是**任意帧**，不是心跳帧——建链后 PX4 停发明文心跳、改发加密遥测
    /// （`data_writer/writer.go` 的「语义注意」段），只记心跳会让判据在
    /// **接引成功那一刻起永久失效**，表现为每 2s 判一次超时、无限定向重发，
    /// 而链路完全正常、日志上看不出任何异常。
    ///
    /// 由 `MAVLinkProtocol` 在**两个**收帧分支各显式调用一行（明文待命心跳支、
    /// 加密帧支）。**不要**塞进 `learnDeviceSystemMapping` 内部——那个函数的名字
    /// 只承诺"学习映射"，隐式更新时间戳属于名字没体现的行为。
    void noteDeviceFrame(DeviceID deviceID);

    /// 距上次收到该 deviceID 的帧过去了多少毫秒；**-1 = 从未收到**。
    /// 由 `RomView.qml` 在每 2s 的轮询节拍上读取，与生效的阈值比较（§3.6.2）。
    Q_INVOKABLE qint64 msSinceLastFrame(quint32 deviceID) const;
```

在 private 成员区（与 `_deviceToSystem` 并列处）加：

```cpp
    /// deviceID → 最近一次收帧时 `_frameClock` 的毫秒读数。
    /// ⚠️ 刻意**不做清理**：条目数 = 本进程见过的 deviceID 数（天花板 80），
    ///    内存可忽略；加清理反而引入"清理时机"这个新判据，是净损失。
    QHash<DeviceID, qint64> _lastFrameMs;
    /// `_lastFrameMs` 的时间基准。单调、不受系统时钟调整影响。
    QElapsedTimer _frameClock;
```

`src/MAVLink/Crypto/CryptoController.cc`：

在 `learnDeviceSystemMapping` 的定义**之后**加：

```cpp
void CryptoController::noteDeviceFrame(DeviceID deviceID)
{
    if (deviceID == kInvalidDeviceID) {
        return;
    }
    const QMutexLocker locker(&_mutex);
    _lastFrameMs.insert(deviceID, _frameClock.elapsed());
}

qint64 CryptoController::msSinceLastFrame(quint32 deviceID) const
{
    const QMutexLocker locker(&_mutex);
    const auto it = _lastFrameMs.constFind(static_cast<DeviceID>(deviceID));
    if (it == _lastFrameMs.constEnd()) {
        return -1;
    }
    return _frameClock.elapsed() - it.value();
}
```

`_frameClock` 必须在**构造函数**里 `start()`（未 start 的 `QElapsedTimer` 的 `elapsed()` 值无意义）。在 `CryptoController::CryptoController(...)` 的函数体第一行加：

```cpp
    _frameClock.start();
```

> ⚠️ `_frameClock.elapsed()` 在**持有 `_mutex` 时**读是安全的：`QElapsedTimer` 是 POD 式值类型，不涉及本类的锁序（本类的锁序是 `CryptoController::_mutex` → `ReplayGuard` 内部锁，单向）。

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R CryptoTest --output-on-failure 2>&1 | tail -20
```
Expected: `CryptoTest` 全绿（含新增的 `_testNoteDeviceFrame`）。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/MAVLink/Crypto/CryptoController.h src/MAVLink/Crypto/CryptoController.cc test/MAVLink/CryptoTest.h test/MAVLink/CryptoTest.cc
git commit -m "feat(crypto): per-deviceID 收帧时间戳 noteDeviceFrame/msSinceLastFrame（P5 §3.6.1）"
```

---

### Task 2: 两个收帧分支各接一行

**Files:**
- Modify: `src/Comms/MAVLinkProtocol.cc`（明文待命心跳支、加密帧支）
- Test: `test/Comms/MAVLinkCryptoFrameTest.h`（新）、`test/Comms/MAVLinkCryptoFrameTest.cc`（新）
- Modify: `test/Comms/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 的 `noteDeviceFrame` / `msSinceLastFrame`
- Produces: 无新 API（纯接线）

> **为什么这一格必须是集成测试**：要钉的是 `MAVLinkProtocol` 里**两个分支各有一行**，而那两个分支（`isPlaintextHeartbeat` 支、`_processEncryptedFrame`）都只能从 `receiveBytes()` 喂真实字节到达——它们是私有方法。照 `test/Comms/MAVLinkV1TrafficTest.cc` 的骨架（`VehicleTestManualConnect` + `_mockLink` + `protocol->receiveBytes(_mockLink, bytes)`）。

> **加密帧那一格为什么不需要真密钥**：`noteDeviceFrame` 放在**防重放检查之前**（§3.6.1 明确说这是有意的——重放帧同样是「mavp2p 在转给我」的证据）。所以测试可以**故意喂一个会被防重放拒的 counter**：它走到 `noteDeviceFrame` 之后就被 `qCDebug` 挡回，既证明了「加密分支记了」，又证明了「位置在检查之前」，还不需要构造密钥与密文。`qCDebug` 在 strict mode 下不算失败。

- [ ] **Step 1: 写失败测试**

创建 `test/Comms/MAVLinkCryptoFrameTest.h`：

```cpp
#pragma once

#include "BaseClasses/VehicleTestManualConnect.h"

/// 加密链路下的收帧时间戳接线（设计文档 §3.6.1）。
///
/// 钉的是 `MAVLinkProtocol` 里**两个分支各有一行** `noteDeviceFrame`：
///   ① `_receiveEncryptedBytes` 的明文待命心跳支；
///   ② `_processEncryptedFrame` 取完 deviceID 处（**防重放检查之前**）。
///
/// ⚠️ 两格必须**对称**且各自独立。若只写 ②，把 ① 那行删掉不会有任何用例变红；
///    若两格其实走的是同一条路径（例如都用了加密帧），删任一行会**两格一起红**——
///    那时它们并没有分别守住两条分支。
class MAVLinkCryptoFrameTest : public VehicleTestManualConnect
{
    Q_OBJECT

protected slots:
    void cleanup() override;

private slots:
    void _testPlaintextHeartbeatNotesFrame();
    void _testEncryptedFrameNotesFrame();
};
```

创建 `test/Comms/MAVLinkCryptoFrameTest.cc`：

```cpp
#include "MAVLinkCryptoFrameTest.h"

#include <QtTest/QTest>

#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/DeviceID.h"
#include "MAVLinkLib.h"
#include "MAVLinkProtocol.h"
#include "MockLink.h"

namespace {

/// 构造一个标准（明文）MAVLink v2 HEARTBEAT 帧的线上字节。
/// 帧头 layout：0=magic(0xFD) 1=len 2=incompat 3=compat 4=seq 5=sysid 6=compid 7..9=msgid
QByteArray plaintextHeartbeatFrame(uint8_t sysid, uint8_t compid)
{
    mavlink_message_t msg{};
    (void) mavlink_msg_heartbeat_pack(sysid, compid, &msg, MAV_TYPE_QUADROTOR, MAV_AUTOPILOT_GENERIC, 0, 0, 0);

    uint8_t buffer[MAVLINK_MAX_PACKET_LEN]{};
    const int len = mavlink_msg_to_send_buffer(buffer, &msg);
    return QByteArray(reinterpret_cast<const char*>(buffer), len);
}

/// 构造一个「不是明文待命心跳」的加密帧：msgid != 0 且 payload block >= 28
/// （counter 8 + deviceID 4 + tag 16 = 28，规范 §2.6 第 0 步的长度门槛）。
///
/// 内容不需要是真的密文——本用例只走到 `noteDeviceFrame` 那一行就被防重放拒回，
/// 永远走不到解密。**这正是要验证的**：位置在防重放检查之前。
QByteArray encryptedFrame(uint8_t sysid, uint8_t compid, uint64_t counter)
{
    constexpr int kPayloadBlockLen = 28;
    QByteArray frame;
    frame.reserve(static_cast<int>(MAVLinkCrypto::kV2HeaderLen) + kPayloadBlockLen + static_cast<int>(MAVLinkCrypto::kCrcLen));

    frame.append(static_cast<char>(0xFD));                                  // magic
    frame.append(static_cast<char>(kPayloadBlockLen));                      // len（payload block）
    frame.append(static_cast<char>(0));                                     // incompat（deviceID 高字节）
    frame.append(static_cast<char>(0));                                     // compat
    frame.append(static_cast<char>(0));                                     // seq
    frame.append(static_cast<char>(sysid));                                 // sysid
    frame.append(static_cast<char>(compid));                                // compid
    frame.append(static_cast<char>(1));                                     // msgid 低字节 = 1
    frame.append(static_cast<char>(0));
    frame.append(static_cast<char>(0));
    for (int i = 0; i < 8; i++) {                                           // counter：大端
        frame.append(static_cast<char>(static_cast<uint8_t>(counter >> (56 - i * 8))));
    }
    for (int i = 0; i < kPayloadBlockLen - 8; i++) {                        // 其余为占位字节
        frame.append(static_cast<char>(0xAB));
    }
    frame.append(static_cast<char>(0));                                     // CRC 占位（不会走到校验）
    frame.append(static_cast<char>(0));
    return frame;
}

} // namespace

void MAVLinkCryptoFrameTest::cleanup()
{
    // ⚠️ 本文件**不碰** `CryptoController` 的启用状态。`receiveBytes` 的分支只由**帧内容**
    // 决定（`isPlaintextHeartbeat = (msgid==0 && payloadBlockLen<28)`，`MAVLinkProtocol.cc:199`），
    // 与 `cryptoEnabled` 无关。开它反而会拉起登记定时器与状态机，引入未预期日志
    // ⇒ strict mode 下**用例失败**（本项目已记录的坑）。
    VehicleTestManualConnect::cleanup();
}

void MAVLinkCryptoFrameTest::_testPlaintextHeartbeatNotesFrame()
{
    // 明文待命心跳支：msgID=0 且 payload block < 28（规范 §2.2 的明文特例）
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    // 静音 MockLink 自身的遥测流：注入的帧必须是唯一的输入，
    // 否则 MockLink 的设备会污染读数（照 MAVLinkV1TrafficTest::_testV1RadioStatusDoesNotWarn）
    _mockLink->setCommLost(true);

    // 用 MockLink 之外的 sysid，确保这个 deviceID 本进程从未出现过
    const uint8_t sysid = 0x77;
    const uint8_t compid = 0x42;
    const MAVLinkCrypto::DeviceID deviceID = MAVLinkCrypto::makeDeviceID(0, 0, sysid, compid);
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));

    MAVLinkProtocol::instance()->receiveBytes(_mockLink, plaintextHeartbeatFrame(sysid, compid));

    // 变异自证：删掉明文心跳分支那一行 ⇒ 此处变红，而 _testEncryptedFrameNotesFrame 仍绿
    QVERIFY2(crypto->msSinceLastFrame(deviceID) >= 0, "明文待命心跳支必须记收帧时间戳");
}

void MAVLinkCryptoFrameTest::_testEncryptedFrameNotesFrame()
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();

    _connectMockLinkNoInitialConnectSequence();
    _mockLink->setCommLost(true);

    const uint8_t sysid = 0x78;
    const uint8_t compid = 0x43;
    const MAVLinkCrypto::DeviceID deviceID = MAVLinkCrypto::makeDeviceID(0, 0, sysid, compid);
    QCOMPARE(crypto->msSinceLastFrame(deviceID), qint64(-1));

    // 把防重放水位抬到 2000：随后喂 counter=1000 的帧必被拒。
    // 本用例的判别力全在这里——「记了」与「记在检查之前」是同一条断言的两面。
    QVERIFY(crypto->isIncomingAcceptable(deviceID, 2000));
    crypto->commitIncoming(deviceID, 2000);

    MAVLinkProtocol::instance()->receiveBytes(_mockLink, encryptedFrame(sysid, compid, 1000));

    // 变异自证①：删掉加密帧分支那一行 ⇒ 此处变红，而明文那一格仍绿
    // 变异自证②：把 noteDeviceFrame 挪到 isIncomingAcceptable 之后 ⇒ 此处同样变红
    QVERIFY2(crypto->msSinceLastFrame(deviceID) >= 0,
             "加密帧支必须记收帧时间戳，且须记在防重放检查之前");

    crypto->resetReplay(deviceID);  // 清理：单例状态跨用例共享
}
```

- [ ] **Step 2: 注册测试文件**

在 `test/Comms/CMakeLists.txt` 的 `target_sources(...)` 列表里按字母序插入：

```cmake
        MAVLinkCryptoFrameTest.cc
        MAVLinkCryptoFrameTest.h
```

在文件末尾的 `add_qgc_test(...)` 组里追加：

```cmake
add_qgc_test(MAVLinkCryptoFrameTest LABELS Integration Comms)
```

- [ ] **Step 3: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
cd build && ctest -R MAVLinkCryptoFrameTest --output-on-failure 2>&1 | tail -30
```
Expected: 两个用例都 **FAIL**，失败点是 `明文待命心跳支必须记收帧时间戳` / `加密帧支必须记收帧时间戳...`（此时还一行都没接）。若编译不过，先修编译错误再回到本步。

- [ ] **Step 4: 接线**

`src/Comms/MAVLinkProtocol.cc` 的 **明文待命心跳支**——在 `learnDeviceSystemMapping` 调用之后、自动建链判定之前：

```cpp
            MAVLinkCrypto::CryptoController::instance()->learnDeviceSystemMapping(
                deviceID, MAVLinkCrypto::systemID(deviceID));
            // 收帧时间戳（§3.6.1）：本分支覆盖「未建链」阶段。
            // ⚠️ 两处收帧点必须都记——只记心跳会让判据在接引成功那一刻起永久失效。
            MAVLinkCrypto::CryptoController::instance()->noteDeviceFrame(deviceID);
```

同文件的 **加密帧支**（`_processEncryptedFrame` 内）——在 `learnDeviceSystemMapping` 调用之后、`isIncomingAcceptable` **之前**：

```cpp
    crypto->learnDeviceSystemMapping(deviceID, MAVLinkCrypto::systemID(deviceID));
    // 收帧时间戳（§3.6.1）：本分支覆盖「已建链」阶段——建链后 PX4 停发明文心跳、
    // 改发加密遥测，只记心跳分支的实现在这里会漏掉全部在飞飞机。
    // ⚠️ 放在防重放检查**之前**是有意的：重放帧、重复帧同样是"mavp2p 在转给我"的证据。
    crypto->noteDeviceFrame(deviceID);
```

- [ ] **Step 5: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R MAVLinkCryptoFrameTest --output-on-failure 2>&1 | tail -20
```
Expected: 两个用例全绿。

- [ ] **Step 6: 变异自证（两格必须各红各的）**

```bash
cd /home/wangsl/qgroundcontrol
# 变异①：注掉明文分支那一行
sed -i 's|^            MAVLinkCrypto::CryptoController::instance()->noteDeviceFrame(deviceID);|            // MUTATION|' src/Comms/MAVLinkProtocol.cc
source .venv/bin/activate && just build 2>&1 | tail -3
cd build && ctest -R MAVLinkCryptoFrameTest --output-on-failure 2>&1 | tail -15
```
Expected: **只有 `_testPlaintextHeartbeatNotesFrame` 红**，`_testEncryptedFrameNotesFrame` 仍绿。

然后**还原**（`git checkout src/Comms/MAVLinkProtocol.cc` 会丢掉 Step 4 的两行——所以先手工还原那一行，或用 `git diff` 核对后重做 Step 4）。**判据：还原后 `git diff` 里恰好是 Step 4 加的那两行 + 注释**。

变异②同理，注掉加密支那一行 ⇒ **只有 `_testEncryptedFrameNotesFrame` 红**。两步做完必须回到两行都在的状态，并重跑一次确认全绿。

> ⚠️ **不要在活工作树上做变异**。若时间允许，把工作树快照到 `/tmp` 再变异；若就地变异，**每一步变异前先确认 `git status` 干净**，变异后立刻还原并重跑。

- [ ] **Step 7: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/Comms/MAVLinkProtocol.cc test/Comms/MAVLinkCryptoFrameTest.h test/Comms/MAVLinkCryptoFrameTest.cc test/Comms/CMakeLists.txt
git commit -m "feat(crypto): 两个收帧分支各记收帧时间戳 noteDeviceFrame（P5 §3.6.1）"
```

---

### Task 3: 分批算法（纯函数）

**Files:**
- Modify: `src/MAVLink/Crypto/CryptoController.h`
- Modify: `src/MAVLink/Crypto/CryptoController.cc`
- Test: `test/MAVLink/CryptoTest.h`、`test/MAVLink/CryptoTest.cc`

**Interfaces:**
- Produces: `static QList<DeviceID> CryptoController::nextRegistrationBatch(const QList<DeviceID>& devices, int batch, int& cursor)` —— 从 `cursor` 起取至多 `batch` 个（环形回绕），并把 `cursor` 推进到**下一批的起点**

> **为什么抽成 `public static` 纯函数**：`_sendRegistration()` 的发送路径依赖 `LinkManager::instance()->links()`，单测里没有 UDP link，无法观察它实际发了什么。把算法与发送分离后，`n=18` 时「16、2、16、2…」这条判据（§9.2）变成一格可断言的值。
>
> **`cursor` 用引用传递而不是成员**：这样函数是纯的（同输入同输出），测试不需要构造 `CryptoController` 实例即可覆盖。成员 `_regCursor` 由调用方传入。

- [ ] **Step 1: 写失败测试**

`test/MAVLink/CryptoTest.h` 的 `private slots:` 追加：

```cpp
    // 80005 分批（§3.3/§3.4）：切批 + 环形轮转 + 覆盖性
    void _testNextRegistrationBatch();
```

`test/MAVLink/CryptoTest.cc` 末尾追加：

```cpp
void CryptoTest::_testNextRegistrationBatch()
{
    // §3.3 的算法，§9.2 的判据。n=18、batch=16 ⇒ 每轮 2 批，批次大小依次 16、2。
    // ⚠️ 设计文档 §3.3 的伪码写的是 `count = qMin(n, batch)`——那在 n=18 时恒为 16，
    //    与 §9.2 的「16、2、16、2…」不符。本实现取「切批」语义，理由见计划 R1。
    QList<DeviceID> ids;
    for (int i = 0; i < 18; i++) {
        ids.append(10000030u + static_cast<uint32_t>(i));
    }

    int cursor = 0;
    const QList<DeviceID> b1 = CryptoController::nextRegistrationBatch(ids, 16, cursor);
    QCOMPARE(b1.size(), 16);
    QCOMPARE(b1.first(), static_cast<DeviceID>(10000030u));
    QCOMPARE(b1.last(), static_cast<DeviceID>(10000045u));
    QCOMPARE(cursor, 16);

    const QList<DeviceID> b2 = CryptoController::nextRegistrationBatch(ids, 16, cursor);
    QCOMPARE(b2.size(), 2);
    QCOMPARE(b2.at(0), static_cast<DeviceID>(10000046u));
    QCOMPARE(b2.at(1), static_cast<DeviceID>(10000047u));
    QCOMPARE(cursor, 0);   // 回绕到起点，下一轮从头开始

    // ‼️ 覆盖性：判据是「集合里每个 id 都被登记过」，不是「第一批 16 个都对」。
    //    只跑一轮时，第一批之后的都没轮到，而"16 个都出现了"看起来像全对（§9.2）。
    QSet<DeviceID> seen;
    cursor = 0;
    const int batches = (ids.size() + 15) / 16;   // ceil(18/16) = 2（§3.4）
    for (int round = 0; round < 2; round++) {
        for (int b = 0; b < batches; b++) {
            const QList<DeviceID> batch = CryptoController::nextRegistrationBatch(ids, 16, cursor);
            for (const DeviceID id : batch) {
                seen.insert(id);
            }
        }
    }
    QCOMPARE(seen.size(), ids.size());

    // n ≤ batch ⇒ 退化为「一批全取、游标恒 0」，与改动前的行为完全一致（§3.3 关键点 3）。
    // 这是零回归风险的依据：监控清单 ≤16 架时行为一字不变。
    QList<DeviceID> small;
    for (int i = 0; i < 5; i++) {
        small.append(20000000u + static_cast<uint32_t>(i));
    }
    int smallCursor = 0;
    const QList<DeviceID> s1 = CryptoController::nextRegistrationBatch(small, 16, smallCursor);
    QCOMPARE(s1.size(), 5);
    QCOMPARE(smallCursor, 0);

    // 空集合 ⇒ 空批、游标归零（调用方据此走"发 num=0 的登记"的现状分支）
    int emptyCursor = 7;
    QVERIFY(CryptoController::nextRegistrationBatch(QList<DeviceID>(), 16, emptyCursor).isEmpty());
    QCOMPARE(emptyCursor, 0);

    // 游标越界防御：集合缩小后旧游标可能落在界外，必须回到 0 而不是越界读
    int staleCursor = 40;
    const QList<DeviceID> s2 = CryptoController::nextRegistrationBatch(small, 16, staleCursor);
    QCOMPARE(s2.size(), 5);
    QCOMPARE(s2.first(), static_cast<DeviceID>(20000000u));
}
```

在 `test/MAVLink/CryptoTest.cc` 的 include 区补 `#include <QSet>`（若尚未包含）。

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
```
Expected: 编译失败，`no member named 'nextRegistrationBatch'`。

- [ ] **Step 3: 实现**

`src/MAVLink/Crypto/CryptoController.h` 的 **public** 区（放在 `setRegistrationEnabled` 声明附近）：

```cpp
    /// 从 `devices` 的 `cursor` 位置起取至多 `batch` 个（环形回绕），
    /// 并把 `cursor` 就地推进到**下一批的起点**（§3.3）。
    ///
    /// 语义：把 n 架切成 ceil(n/batch) 批，每批 ≤ batch
    /// （n=18、batch=16 ⇒ 批次大小依次 16、2、16、2…）。
    /// ⚠️ 不是"每次取满 batch 个的滑窗"——那样每批恒为 16 个，第二批会白白多带
    ///    14 个 deviceID（56 字节），且与 §9.2 的实测判据不符。
    ///
    /// n ≤ batch 时退化为「一批全取、游标恒 0」，与改动前行为完全一致。
    ///
    /// 抽成 public static 纯函数是为了单测：`_sendRegistration()` 的发送路径依赖
    /// `LinkManager`（单测里无 UDP link），无法观察它实际发了什么。
    static QList<DeviceID> nextRegistrationBatch(const QList<DeviceID>& devices, int batch, int& cursor);
```

`src/MAVLink/Crypto/CryptoController.cc`：

```cpp
QList<DeviceID> CryptoController::nextRegistrationBatch(const QList<DeviceID>& devices, int batch, int& cursor)
{
    const int n = devices.size();
    if (n <= 0 || batch <= 0) {
        cursor = 0;
        return {};
    }
    // 防御：监控清单缩小后，上一轮留下的游标可能已越界
    if (cursor < 0 || cursor >= n) {
        cursor = 0;
    }
    const int count = qMin(batch, n - cursor);

    QList<DeviceID> out;
    out.reserve(count);
    for (int i = 0; i < count; i++) {
        out.append(devices.at((cursor + i) % n));
    }
    cursor = (cursor + count) % n;
    return out;
}
```

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R CryptoTest --output-on-failure 2>&1 | tail -15
```
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/MAVLink/Crypto/CryptoController.h src/MAVLink/Crypto/CryptoController.cc test/MAVLink/CryptoTest.h test/MAVLink/CryptoTest.cc
git commit -m "feat(crypto): 80005 分批算法 nextRegistrationBatch（P5 §3.3）"
```

---

### Task 4: 监控清单 + 阈值 + `_sendRegistration` 接入分批

**Files:**
- Modify: `src/MAVLink/Crypto/CryptoController.h`
- Modify: `src/MAVLink/Crypto/CryptoController.cc`（`_sendRegistration` 拆成两个函数）
- Test: `test/MAVLink/CryptoTest.h`、`test/MAVLink/CryptoTest.cc`

**Interfaces:**
- Consumes: Task 3 的 `nextRegistrationBatch`
- Produces:
  - `static constexpr int CryptoController::DEFAULT_FRAME_TIMEOUT_MS = 3000`
  - `Q_INVOKABLE void CryptoController::setMonitorDevices(const QVariantList& deviceIds, int frameTimeoutMs)`
  - `int CryptoController::frameTimeoutMs() const`（测试与诊断读用）
  - private: `void _sendRegistrationFrame(const QList<DeviceID>& ids)`

> **`_sendRegistration` 为什么要拆**：Task 6 的定向重发要「只发一个 deviceID」，它必须复用同一套组帧+发送逻辑（含定长 `deviceBytes`、UDP link 过滤、`sent` 日志）。复制一份会让 §3.3 的定长约束出现两个维护点。

- [ ] **Step 1: 写失败测试**

`test/MAVLink/CryptoTest.h` 追加：

```cpp
    // 监控清单与超时阈值（§3.5.3/§3.6.4）：一次调用两个实参、非法 id 跳过、空清单回退
    void _testSetMonitorDevices();
```

`test/MAVLink/CryptoTest.cc` 追加：

```cpp
void CryptoTest::_testSetMonitorDevices()
{
    CryptoController* const crypto = CryptoController::instance();

    // 缺省阈值 = 编译期默认（§3.6.4：后端不下发时用它兜底）
    QCOMPARE(crypto->frameTimeoutMs(), CryptoController::DEFAULT_FRAME_TIMEOUT_MS);

    const DeviceID a = makeDeviceID(0, 0, 0x31, 0x01);
    const DeviceID b = makeDeviceID(0, 0, 0x31, 0x02);

    // ⚠️ 阈值与清单**同一次**传入。判别力在于"故意选一个不同于默认值的数"——
    //    若这里也传 3000，那么"实现了透传"和"完全没读这个实参"表现完全一致，
    //    这一格会假绿（本项目已记录过的判据失效模式）。
    const QVariantList ids{ static_cast<uint>(a), static_cast<uint>(b) };
    crypto->setMonitorDevices(ids, 9000);
    QCOMPARE(crypto->frameTimeoutMs(), 9000);
    QCOMPARE(crypto->monitorDeviceCount(), 2);

    // 非法条目必须跳过并留下日志，不能默默变成 0：
    // 一条 device_id=0 的登记会在 mavp2p 里建出无意义的 pair，且没有任何一处会报错（§3.5.2）
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression("setMonitorDevices"));
    const QVariantList withBad{ static_cast<uint>(a), QStringLiteral("not-a-number"), 0u };
    crypto->setMonitorDevices(withBad, 5000);
    verifyExpectedLogMessage();
    QCOMPARE(crypto->monitorDeviceCount(), 1);   // 只剩 a

    // 阈值 ≤ 0 或非法 ⇒ 回落默认，且**不清空清单**（§3.5.4：失败只降灵敏度、不改变方向）
    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(b) }, -1);
    QCOMPARE(crypto->frameTimeoutMs(), CryptoController::DEFAULT_FRAME_TIMEOUT_MS);
    QCOMPARE(crypto->monitorDeviceCount(), 1);

    // 空清单 = "没有清单" ⇒ 回退到 _linkedDevices（§3.5.4 的未登录/RomView 未打开两支）
    crypto->setMonitorDevices(QVariantList(), 3000);
    QCOMPARE(crypto->monitorDeviceCount(), 0);
}
```

`test/MAVLink/CryptoTest.cc` 的 include 区补 `#include <QVariantList>`。`MAVLinkCrypto::makeDeviceID` 已经可用（`DeviceID.h` 已包含）。

> ⚠️ 测试里用 `monitorDeviceCount()` 而不是直接读 `_monitorDevices`：后者是 private。加一个只读 getter 比 `#define private public` 干净。

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
```
Expected: 编译失败（`setMonitorDevices` / `frameTimeoutMs` / `monitorDeviceCount` / `DEFAULT_FRAME_TIMEOUT_MS` 都不存在）。

- [ ] **Step 3: 实现**

`src/MAVLink/Crypto/CryptoController.h`：

顶部 include 区加 `#include <QtCore/QVariantList>`。

public 区（在 `setRegistrationEnabled` 声明之后）：

```cpp
    /// 超时阈值的编译期兜底（§3.6.4）。
    /// 对应 1Hz 发帧频率，是**保守**选择：20Hz 下偏慢（晚 1s 才发现），
    /// 但任何频率 ≥ 1Hz 都不会误判。
    /// ⚠️ 主路径必须是后端下发：若后端不下发、而 PX4 又降到了 0.2Hz 以下，
    ///    这个默认值会误判（每 3s 重发一次，而飞机 5s 才发一帧）。
    static constexpr int DEFAULT_FRAME_TIMEOUT_MS = 3000;

    /// 由 `RomView.qml` 在**每次成功轮询**后调用（§3.5.3）：
    /// 传入"需要监控的飞机"的 deviceID 列表，以及本次生效的超时阈值（毫秒）。
    ///
    /// - 空列表 = "没有清单" ⇒ `_sendRegistration` 回退到 `_linkedDevices` 全体。
    /// - `frameTimeoutMs <= 0` ⇒ 用 `DEFAULT_FRAME_TIMEOUT_MS`。
    /// - 集合**内容变化**时立即跑一轮加速发送（§3.4）；
    ///   内容不变则什么都不做——2s 轮询会反复调用本函数，
    ///   若每次都加速，10s 保活周期会被打乱。
    ///
    /// ‼️ **轮询失败时不要调用本函数**（保留上一次的清单）。
    ///    把"请求失败"当成"没有需要监控的飞机"会让登记集合清空，
    ///    全部飞机在 60s TTL 后集体掉线，而失败原因可能只是一次网络抖动（§3.5.4）。
    ///
    /// ‼️ 阈值与清单**必须同一次调用传入**：拆成两个 setter 会造出
    ///    "新阈值配旧清单"的中间态（§3.6.4）。
    Q_INVOKABLE void setMonitorDevices(const QVariantList& deviceIds, int frameTimeoutMs);

    /// 当前生效的超时阈值（毫秒）。
    int frameTimeoutMs() const;

    /// 当前监控清单的条数（0 = 无清单，回退 `_linkedDevices`）。
    /// 供测试与诊断读——`_monitorDevices` 本身是 private。
    int monitorDeviceCount() const;
```

private 区（在 `_sendRegistration` 声明旁）：

```cpp
    /// 把一批 deviceID 组帧并发出（§3.3 的组帧 + UDP link 过滤 + sent 日志）。
    /// 抽出来是为了让定向重发（`reRegisterDevice`）复用同一套逻辑，
    /// 避免 §3.3 的"定长 deviceBytes"约束出现两个维护点。
    void _sendRegistrationFrame(const QList<DeviceID>& ids);
```

private 成员区：

```cpp
    /// 「需要监控的飞机」的 deviceID 列表（§3.5.3）。
    /// 空 = 没有清单 ⇒ `_sendRegistration` 回退到 `_linkedDevices`。
    QList<DeviceID> _monitorDevices;
    /// 本次生效的超时阈值（毫秒）。与 `_monitorDevices` 同一次调用更新。
    int _frameTimeoutMs = DEFAULT_FRAME_TIMEOUT_MS;
    /// 分批发送的游标（§3.3），跨两次 `_sendRegistration()` 保持。
    int _regCursor = 0;
```

`src/MAVLink/Crypto/CryptoController.cc`：

```cpp
void CryptoController::setMonitorDevices(const QVariantList& deviceIds, int frameTimeoutMs)
{
    QList<DeviceID> parsed;
    parsed.reserve(deviceIds.size());
    for (const QVariant& v : deviceIds) {
        bool ok = false;
        const uint id = v.toUInt(&ok);
        // ⚠️ 与 addLinkedDevice 用**同一组**校验（非 0 + 签名位合法），
        //    保证"能进 _linkedDevices 的就能进 _monitorDevices"，两处口径不漂移。
        if (!ok || id == kInvalidDeviceID || !hasValidSignatureBit(static_cast<DeviceID>(id))) {
            qCWarning(CryptoControllerLog) << "setMonitorDevices: 非法 deviceID，已跳过" << v;
            continue;
        }
        parsed.append(static_cast<DeviceID>(id));
    }

    bool changed = false;
    {
        const QMutexLocker locker(&_mutex);
        _frameTimeoutMs = (frameTimeoutMs > 0) ? frameTimeoutMs : DEFAULT_FRAME_TIMEOUT_MS;
        // ‼️ 判据是"集合内容变了"，不是"被调用了一次"（§3.4）
        changed = (parsed != _monitorDevices);
        if (changed) {
            _monitorDevices = parsed;
            _regCursor = 0;  // 集合变了，旧游标没有意义
        }
    }

    if (changed) {
        requestAcceleratedRegistration();
    }
}

int CryptoController::frameTimeoutMs() const
{
    const QMutexLocker locker(&_mutex);
    return _frameTimeoutMs;
}

int CryptoController::monitorDeviceCount() const
{
    const QMutexLocker locker(&_mutex);
    return _monitorDevices.size();
}
```

把现有 `_sendRegistration()` **整体替换**为下面两个函数（组帧与发送部分**原样**搬进 `_sendRegistrationFrame`，只把 `devices` 的来源与 `deviceCount` 的算法换掉）：

```cpp
void CryptoController::_sendRegistration()
{
    QList<DeviceID> batch;
    {
        const QMutexLocker locker(&_mutex);
        // §3.5.3：有监控清单时用清单，否则回退 _linkedDevices
        //（未登录 / RomView 未打开 ⇒ 保持现状，零回归）
        QList<DeviceID> devices = _monitorDevices.isEmpty() ? _linkedDevices : _monitorDevices;
        if (_activeDeviceID != kInvalidDeviceID && !devices.contains(_activeDeviceID)) {
            devices.append(_activeDeviceID);
        }
        // §3.3：分批轮转。n ≤ 16 时退化为"一批全取、游标恒 0"，与改动前一致。
        batch = nextRegistrationBatch(devices, MAX_QGC_LINKED_PX4, _regCursor);
    }

    // 空批 = 没有关联设备：保持现状，发一个 num=0 的登记告诉 mavp2p "本 GCS 在线"
    _sendRegistrationFrame(batch);
}

void CryptoController::_sendRegistrationFrame(const QList<DeviceID>& ids)
{
    const int deviceCount = qMin(ids.size(), static_cast<int>(MAX_QGC_LINKED_PX4));

    // ⚠️ 定长数组，不是 VLA：`uint8_t deviceBytes[count * 4]` 是 GCC 扩展、
    //    不是标准 C++，MSVC 直接编译失败，本仓是多平台构建（§3.3 关键点 1）。
    //    count 恒 ≤ MAX_QGC_LINKED_PX4，故构造上不会越界。
    uint8_t deviceBytes[MAX_QGC_LINKED_PX4 * 4] = {};
    for (int i = 0; i < deviceCount; i++) {
        const uint32_t dev = ids.at(i);
        deviceBytes[i * 4 + 0] = static_cast<uint8_t>(dev >> 24);
        deviceBytes[i * 4 + 1] = static_cast<uint8_t>(dev >> 16);
        deviceBytes[i * 4 + 2] = static_cast<uint8_t>(dev >> 8);
        deviceBytes[i * 4 + 3] = static_cast<uint8_t>(dev);
    }

    mavlink_message_t message{};
    const uint16_t packLen = mavlink_msg_qgc_registration_pack(QGC_REGISTRATION_DEVICE_ID_DEFAULT, &message,
                                                               deviceCount > 0 ? deviceBytes : nullptr,
                                                               static_cast<uint8_t>(deviceCount));
    if (packLen == 0) {
        qCWarning(CryptoControllerLog) << "registration: pack failed (invalid deviceID), skip";
        return;
    }

    const auto links = LinkManager::instance()->links();
    bool sent = false;
    for (const auto& link : links) {
        if (!link || !link->isConnected()) {
            continue;
        }
        const auto cfg = link->linkConfiguration();
        if (!cfg || cfg->type() != LinkConfiguration::TypeUdp) {
            continue;
        }
        link->sendPlaintextMessageThreadSafe(message);
        sent = true;
    }
    qCDebug(CryptoControllerLog) << "registration sent, devices" << deviceCount
                                 << (sent ? "delivered" : "no udp link");
}
```

> ⚠️ **`requestAcceleratedRegistration()` 在 Task 5 实现**。本任务为了让代码能编译，先加一个**空实现**占位是**不允许的**（空实现会让 Task 5 的用例假绿）。⇒ **Task 4 与 Task 5 的 `setMonitorDevices` 部分必须一起落地**：把 `setMonitorDevices` 里 `if (changed) { requestAcceleratedRegistration(); }` 这三行**推迟到 Task 5 的 Step 3 再加**，本任务的 `setMonitorDevices` 先以 `if (changed) { _monitorDevices = parsed; _regCursor = 0; }` 结束（`changed` 计算保留，供 Task 5 使用）。

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R CryptoTest --output-on-failure 2>&1 | tail -15
```
Expected: 全绿。**同时确认 `CryptoTest` 里既有的 `_testQgcRegistration` 仍绿**——它钉的是 `mavlink_msg_qgc_registration_pack` 本身，本次未动协议，应当不受影响；若它红了说明组帧被改坏了。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/MAVLink/Crypto/CryptoController.h src/MAVLink/Crypto/CryptoController.cc test/MAVLink/CryptoTest.h test/MAVLink/CryptoTest.cc
git commit -m "feat(crypto): 监控清单与超时阈值 setMonitorDevices，登记改分批轮转（P5 §3.5.3/§3.3）"
```

---

### Task 5: 加速首轮（登录成功 / 清单变化）

**Files:**
- Modify: `src/MAVLink/Crypto/CryptoController.h`
- Modify: `src/MAVLink/Crypto/CryptoController.cc`
- Modify: `src/Auth/AuthController.cc`
- Test: `test/MAVLink/CryptoTest.h`、`test/MAVLink/CryptoTest.cc`

**Interfaces:**
- Consumes: Task 4 的 `setMonitorDevices`、`_sendRegistrationFrame`（经 `_sendRegistration`）
- Produces: `Q_INVOKABLE void CryptoController::requestAcceleratedRegistration()`

> **触发点两处**：① `setMonitorDevices` 检测到集合变化；② 登录成功后 `AuthController` 通知。§3.4 特别指出「**`_monitorDevices` 与 `_linkedDevices` 的切换本身就是一次集合变化**，必须在同一条判据里覆盖——否则『登录 → 打开 RomView』这条最常见的路径恰好不触发加速」。① 天然覆盖了它（空 → 非空即 changed）。

- [ ] **Step 1: 写失败测试**

`test/MAVLink/CryptoTest.h` 追加：

```cpp
    // 加速首轮（§3.4）：集合变化触发连续发送、集合不变不触发、容量天花板截断
    void _testRequestAcceleratedRegistration();
```

`test/MAVLink/CryptoTest.cc` 追加：

```cpp
void CryptoTest::_testRequestAcceleratedRegistration()
{
    CryptoController* const crypto = CryptoController::instance();

    // 加速发送走 QTimer::singleShot，观察点是「_sendRegistration 被调了几次」。
    // 单测里没有 UDP link，_sendRegistration 会走 "no udp link" 分支（qCDebug，不算失败），
    // 但**批次组装与游标推进照常发生** ⇒ 用 monitorDeviceCount 与多次调用的累积效果判定。

    // ⚠️ 判别力：断言"清单变小时游标被重置"会与 Task 4 的回合混淆。
    //    本用例只钉三件事：① 集合变化后不需要等 10s 周期（用 QSignalSpy 太脆，
    //    改为直接调 requestAcceleratedRegistration 并验证它是幂等安全的）；
    //    ② 集合不变时 setMonitorDevices 不触发加速；③ 容量超过天花板时的行为。
    const DeviceID a = makeDeviceID(0, 0, 0x41, 0x01);
    const DeviceID b = makeDeviceID(0, 0, 0x41, 0x02);
    const DeviceID c = makeDeviceID(0, 0, 0x41, 0x03);

    // ② 集合不变 ⇒ 不触发加速。判据用 _regCursor：加速会连跑 batches 次发送，
    //    每跑一次游标都推进；集合不变时游标必须**不动**。
    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(a), static_cast<uint>(b) }, 3000);
    crypto->resetRegistrationCursorForTest();   // 归零后观察"不变是否不推进"
    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(a), static_cast<uint>(b) }, 3000);
    QCOMPARE(crypto->registrationCursorForTest(), 0);

    // ① 集合变化 ⇒ 触发加速（游标被推进，说明发送跑了）
    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(a), static_cast<uint>(b), static_cast<uint>(c) }, 3000);
    QVERIFY2(crypto->registrationCursorForTest() != 0, "集合变化必须触发加速发送");

    // 显式调用也必须安全（幂等：多调一次最多多发几帧，不改集合）
    crypto->requestAcceleratedRegistration();
    QCOMPARE(crypto->monitorDeviceCount(), 3);

    // ③ 容量天花板：batches ≤ 5（§3.4）。造 96 架 ⇒ ceil(96/16) = 6 批 ⇒ 截断到 5 批。
    //    这一格钉的是"清单越过 n ≤ 80 时不发爆"。
    QVariantList over;
    for (int i = 0; i < 96; i++) {
        over.append(static_cast<uint>(makeDeviceID(0, 0, 0x51, static_cast<uint8_t>(i + 1))));
    }
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression("容量天花板"));
    crypto->setMonitorDevices(over, 3000);
    verifyExpectedLogMessage();
    QCOMPARE(crypto->monitorDeviceCount(), 96);   // ‼️ 截断的是**发送批数**，不是集合

    // 清理
    crypto->setMonitorDevices(QVariantList(), 3000);
}
```

`test/MAVLink/CryptoTest.cc` 追加所需的两个测试专用访问点（它们是**测井**，不是生产 API）：

```cpp
// 放在 CryptoTest.cc 里没有意义（它们是 private 成员），故这两个 getter 落在
// CryptoController 的 public 区，命名带 ForTest 后缀以示区别。
```

> ⚠️ **测试专用 getter 的取舍**：`resetRegistrationCursorForTest()` / `registrationCursorForTest()` 直接暴露 `_regCursor`。替代方案是 `#define private public`（本仓无先例）或把游标做成 `Q_PROPERTY`（污染生产接口）。这里选**显式命名的测试 getter**，并在头文件注释里标注它们只服务于 §9.2 的判据。若评审认为不可接受，退路是删掉这两格断言、只保留 ① 与 ③——**但那样"集合不变不打乱 10s 周期"这条就没有哨兵了**。

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
```
Expected: 编译失败（`requestAcceleratedRegistration` / `registrationCursorForTest` / `resetRegistrationCursorForTest` 不存在）。

- [ ] **Step 3: 实现**

`src/MAVLink/Crypto/CryptoController.h` public 区：

```cpp
    /// 立即跑一轮加速登记（§3.4）：连续 `batches` 次发送、批间隔
    /// `kRegistrationBurstIntervalMs`，让新集合在**秒级**内全部接上，
    /// 而不是等 `batches × 10s` 的游标周期。
    ///
    /// 触发点两处：① `setMonitorDevices` 检测到集合变化；② 登录成功后
    /// `AuthController` 通知（`_linkedDevices` 刚被填充）。
    ///
    /// ⚠️ **不要把它接到 2s 轮询上**——那会打乱 10s 保活周期。
    /// ⚠️ 集合没变时反复调用它最多多花几帧，不改集合、不改变行为方向。
    Q_INVOKABLE void requestAcceleratedRegistration();
```

private 区加常量与测试访问点：

```cpp
    /// 加速发送的批间隔（§3.4：批间隔 ~200ms，用一次性定时器串，不阻塞主线程）。
    static constexpr int kRegistrationBurstIntervalMs = 200;
    /// 加速发送的批数上限，与 §3.4 的容量约束同源（batches ≤ 5 ⇔ n ≤ 80）。
    static constexpr int kMaxRegistrationBatches = 5;
```

public 区（测试访问点）：

```cpp
    /// ---- 仅供单测读写的内部状态（§9.2 的判据需要观察分批游标） ----
    /// 生产代码不得调用；`_regCursor` 的正常更新路径只有 `_sendRegistration`。
    int registrationCursorForTest() const;
    void resetRegistrationCursorForTest();
```

`src/MAVLink/Crypto/CryptoController.cc`：

```cpp
void CryptoController::requestAcceleratedRegistration()
{
    if (!registrationEnabled()) {
        return;  // 未启用登记时不加速（与 _sendRegistration 的门一致）
    }

    int n = 0;
    {
        const QMutexLocker locker(&_mutex);
        n = _monitorDevices.isEmpty() ? _linkedDevices.size() : _monitorDevices.size();
    }

    const int batches = (n <= 0) ? 1 : ((n + MAX_QGC_LINKED_PX4 - 1) / MAX_QGC_LINKED_PX4);
    const int capped = qMin(batches, kMaxRegistrationBatches);
    if (capped < batches) {
        // 容量天花板（§3.4）：越过 n ≤ 80 时稳态本来就保证不了 TTL，
        // 加速发送再多也只是把这一轮塞满。**截断的是批数，不是集合**——
        // 集合永远不动（§3.6.2）。
        qCWarning(CryptoControllerLog) << "监控清单超过容量天花板（n ≤ 80），加速发送已截断"
                                       << n << "架 / 需" << batches << "批";
    }

    // ⚠️ 用 QTimer::singleShot 串，**不要**用 QThread::msleep 或忙等——那会卡 GUI 线程（§3.4）
    for (int i = 0; i < capped; i++) {
        QTimer::singleShot(i * kRegistrationBurstIntervalMs, this, [this]() {
            _sendRegistration();
        });
    }
}

int CryptoController::registrationCursorForTest() const
{
    const QMutexLocker locker(&_mutex);
    return _regCursor;
}

void CryptoController::resetRegistrationCursorForTest()
{
    const QMutexLocker locker(&_mutex);
    _regCursor = 0;
}
```

把 Task 4 里**推迟的那三行**加回 `setMonitorDevices` 的末尾：

```cpp
    if (changed) {
        requestAcceleratedRegistration();
    }
```

`src/Auth/AuthController.cc`：在登录成功、`emit loginSucceeded()` **之前**（与 `crypto->addLinkedDevice(...)` 同一段流程内，`AuthController.cc:376` 附近）加：

```cpp
    // 80005 登记集合刚被填充 ⇒ 立即跑一轮加速，让全平台设备在秒级内接上，
    // 而不是等 batches × 10s 的游标周期（设计文档 §3.4）。
    // ⚠️ 放在 emit loginSucceeded() 之前：那块信号已经接了一堆消费者
    //    （计划控制器的自动装载等），把登记加速排在它们后面没有意义。
    crypto->requestAcceleratedRegistration();
```

> ⚠️ `crypto` 变量在该作用域已存在（`MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();`，`AuthController.cc:348`）。**不要**新起一个 `CryptoController::instance()` 调用点——那会多一个下一步要改的地方。

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R CryptoTest --output-on-failure 2>&1 | tail -15
```
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/MAVLink/Crypto/CryptoController.h src/MAVLink/Crypto/CryptoController.cc src/Auth/AuthController.cc test/MAVLink/CryptoTest.h test/MAVLink/CryptoTest.cc
git commit -m "feat(crypto): 加速首轮 requestAcceleratedRegistration，登录与清单变化触发（P5 §3.4）"
```

---

### Task 6: 定向重发

**Files:**
- Modify: `src/MAVLink/Crypto/CryptoController.h`
- Modify: `src/MAVLink/Crypto/CryptoController.cc`
- Test: `test/MAVLink/CryptoTest.h`、`test/MAVLink/CryptoTest.cc`

**Interfaces:**
- Consumes: Task 4 的 `_sendRegistrationFrame`
- Produces: `Q_INVOKABLE void CryptoController::reRegisterDevice(quint32 deviceID)`

- [ ] **Step 1: 写失败测试**

`test/MAVLink/CryptoTest.h` 追加：

```cpp
    // 定向重发（§3.6.2）：只发一帧、**绝不移出登记集合**
    void _testReRegisterDevice();
```

`test/MAVLink/CryptoTest.cc` 追加：

```cpp
void CryptoTest::_testReRegisterDevice()
{
    CryptoController* const crypto = CryptoController::instance();
    const DeviceID a = makeDeviceID(0, 0, 0x61, 0x01);
    const DeviceID b = makeDeviceID(0, 0, 0x61, 0x02);

    crypto->setMonitorDevices(QVariantList{ static_cast<uint>(a), static_cast<uint>(b) }, 3000);
    QCOMPARE(crypto->monitorDeviceCount(), 2);

    // ‼️ 本设计最危险的一处：超时只触发"多发一次"，**永远不触发"少登记一个"**。
    //    若实现顺手把它从集合里删掉，它就更收不到帧 ⇒ 下一轮又超时 ⇒ 永久静默失效，
    //    而日志上看不出任何异常（§3.6.2）。
    //    ⇒ 用例必须**同时**断言"发了"与"集合没动"——只断言前者会让那种实现照样通过。
    crypto->reRegisterDevice(a);
    QCOMPARE(crypto->monitorDeviceCount(), 2);

    // 集合里的另一个也必须原样在
    crypto->reRegisterDevice(b);
    QCOMPARE(crypto->monitorDeviceCount(), 2);

    // 不在清单里的 deviceID 也可以重发（幂等刷新，mavp2p 只刷 lastSeen）
    const DeviceID outsider = makeDeviceID(0, 0, 0x61, 0x09);
    crypto->reRegisterDevice(outsider);
    QCOMPARE(crypto->monitorDeviceCount(), 2);   // ‼️ 不得被"顺手加进清单"

    // 非法 deviceID：只记日志、不发、不改集合
    expectLogMessage("MAVLink.Crypto.CryptoController", QtWarningMsg,
                     QRegularExpression("reRegisterDevice"));
    crypto->reRegisterDevice(0);
    verifyExpectedLogMessage();
    QCOMPARE(crypto->monitorDeviceCount(), 2);

    crypto->setMonitorDevices(QVariantList(), 3000);
}
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -20
```
Expected: 编译失败（`no member named 'reRegisterDevice'`）。

- [ ] **Step 3: 实现**

`src/MAVLink/Crypto/CryptoController.h` public 区：

```cpp
    /// 对单个 deviceID 立即发一个只含它的 80005 报文（§3.6.2 的"定向加速重发"）。
    ///
    /// 由 `RomView.qml` 在每 2s 的轮询节拍上、对 `msSinceLastFrame(id)` 超过
    /// 生效阈值的飞机调用。
    ///
    /// ‼️ **只重发，绝不移出登记集合**——移出会让它更收不到帧 ⇒ 下一轮又超时
    ///    ⇒ 永久静默失效，且日志上看不出任何异常。代价是幂等的：
    ///    mavp2p 的 `processRegistration` 对该 deviceID 只做
    ///    `m.pairs[k] = e; e.lastSeen = now`，不触碰任何其它 pair、不断开已建立的链路。
    ///    单架报文的 MAVLink 帧约 24 字节 ⇒ **误判的代价是一个 24 字节的帧**。
    Q_INVOKABLE void reRegisterDevice(quint32 deviceID);
```

`src/MAVLink/Crypto/CryptoController.cc`：

```cpp
void CryptoController::reRegisterDevice(quint32 deviceID)
{
    if (deviceID == kInvalidDeviceID || !hasValidSignatureBit(static_cast<DeviceID>(deviceID))) {
        qCWarning(CryptoControllerLog) << "reRegisterDevice: 非法 deviceID，忽略" << deviceID;
        return;
    }
    // 单发一批（只含这一个），复用 _sendRegistrationFrame 的组帧与发送逻辑。
    // ‼️ 这里**不碰** _monitorDevices、不碰 _regCursor —— 重发是幂等刷新，
    //    任何集合改动都会把"超时自愈"变成"超时自我放逐"（§3.6.2）。
    _sendRegistrationFrame(QList<DeviceID>{ static_cast<DeviceID>(deviceID) });
}
```

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -5
cd build && ctest -R CryptoTest --output-on-failure 2>&1 | tail -15
```
Expected: 全绿。

- [ ] **Step 5: 变异自证**

把 `reRegisterDevice` 里 `_sendRegistrationFrame(...)` 那一行**前面**插一行 `_monitorDevices.removeAll(deviceID);`（模拟"顺手把它移出集合"），重编重跑。

Expected: **`_testReRegisterDevice` 红**（`monitorDeviceCount()` 变成 1），其余用例不受影响。**还原后再跑一次确认全绿。**

- [ ] **Step 6: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/MAVLink/Crypto/CryptoController.h src/MAVLink/Crypto/CryptoController.cc test/MAVLink/CryptoTest.h test/MAVLink/CryptoTest.cc
git commit -m "feat(crypto): 定向重发 reRegisterDevice，只发不动集合（P5 §3.6.2）"
```

---

### Task 7: 把 `CryptoController` 暴露给 QML

**Files:**
- Modify: `src/API/QGCCorePlugin.cc`

**Interfaces:**
- Produces: QML 全局标识符 `cryptoController`（类型 `MAVLinkCrypto::CryptoController*`）

> **判据**：本任务**没有自动化用例**（QGC 的 C++ 单测不覆盖 `createQmlApplicationEngine` 的上下文属性）。它的验收是 Task 8 的 QML 调用能跑起来——那个 `console.warn`（QML 侧改名**不报错**，只静默变成 `undefined`，调用会抛 `TypeError`）是唯一的信号。⇒ 本任务与 Task 8 **必须连续完成并一起验证**，中间不要插入其它改动。

- [ ] **Step 1: 加 include**

`src/API/QGCCorePlugin.cc` 的 include 区（在 `#include "MissionManager/PlanUploader.h"` 附近，按该文件既有的分组习惯）：

```cpp
#include "Crypto/CryptoController.h"
```

> 路径与 `src/Comms/MAVLinkProtocol.cc:27` 一致（`src/MAVLink/` 在 include path 上）。

- [ ] **Step 2: 注册上下文属性**

在 `QGCCorePlugin::createQmlApplicationEngine` 里，紧跟 `planUploader` 那一行之后：

```cpp
    // 80005 登记链路的 QML 接口（设计文档 §3.5.3）：RomView 在每次成功轮询后
    // 推监控清单与超时阈值，并在每 2s 的轮询节拍上做超时定向重发。
    // ⚠️ 用 setContextProperty 而非 QML_SINGLETON：CryptoController 不在任何
    //    qt_add_qml_module 里，加 QML_SINGLETON 要动 QML 模块结构，与本设计无关。
    //    惯例同紧邻的 joystickManager / planUploader。
    qmlEngine->rootContext()->setContextProperty(QStringLiteral("cryptoController"),
                                                 MAVLinkCrypto::CryptoController::instance());
```

- [ ] **Step 3: 编译并确认符号可达**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -10
```
Expected: 编译通过。

- [ ] **Step 4: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/API/QGCCorePlugin.cc
git commit -m "feat(ops): 把 cryptoController 暴露给 QML（P5 §3.5.3 的跨语言接缝）"
```

---

### Task 8: `RomView.qml` 接线（推送清单 + 超时检查）

**Files:**
- Modify: `src/OpsView/RomView.qml`

**Interfaces:**
- Consumes: Task 4/6/7 的 `cryptoController.setMonitorDevices` / `reRegisterDevice` / `msSinceLastFrame`；`OpsShell` 的 `_get(path, onDone)` 与 `polled()` 信号

> **两个落地决定**（本计划裁定，理由随代码注释保留）：
>
> **D1 —— RomView 自己发 ③ 端点请求，不挂 `polled()` 的数据。** `OpsShell._poll()` 里 `_fetchOverview()` 是异步 XHR，`polled()` 紧随其后**同步**发出 ⇒ 挂在 `polled()` 上拿到的是**上一轮**的数据，且在请求失败时也会触发。而 §3.5.4 要求「**轮询成功**才推送，失败什么都不做」。⇒ 在 ③ 请求**自己的成功回调**里推送。
>
> **D2 —— 清单映射先内联，P2 再抽函数。** §8.2 写的是 `OpsCommon.monitorDeviceIds(resp.devices)`，但那个纯函数属 P2 的 `OpsCommon.js`。P5 不改 P2 的文件，内联一行 `data.devices.map(...)`；P2 落地时替换成纯函数调用（届时 `OpsCommon.js` 的用例会覆盖去重与 `device_id <= 0` 的剔除，本处只做直通映射）。

- [ ] **Step 1: 确认 QML 侧能拿到 `cryptoController`**

先跑一次 Task 7 之后的构建产物，在 QML 里加一条**临时**探针（下一步会删）：

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
./build/Debug/QGroundControl 2>&1 | head -20
```

在 `RomView.qml` 的 `OpsShell {` 块内临时加：

```qml
    Component.onCompleted: console.log("PROBE cryptoController =", typeof cryptoController)
```

Expected: 控制台打印 `PROBE cryptoController = object`。若是 `undefined`，说明 Task 7 的注册没生效（**先解决它再往下**，否则 Step 3 的调用会抛 `TypeError`）。**验完立刻删掉这一行。**

- [ ] **Step 2: 加接引清单与超时检查**

在 `src/OpsView/RomView.qml` 的 `OpsShell { ... }` 块内、`rightPanelContent` 之前，加入：

```qml
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
```

- [ ] **Step 3: 更新文件头注释**

`RomView.qml` 顶部第 17-18 行现在写的是：

```
/// ‼️ 本视图**不连** `polled()`。机位是站点专属数据，监控员拉它没有消费者，白花一次请求。
///    这正是骨架把 `polled()` 做成信号、而不是把机位一并塞进 `_poll()` 的原因。
```

**这段已经过时**（本视图现在连 `polled()`，用途是接引清单与超时检查）。改为：

```qml
/// ‼️ 本视图连 `polled()`，但**只为接引链路**（§3.5.3/§3.6）：拉 ③ 端点推监控清单、
///    做每 2s 的超时定向重发。机位仍**不拉**——那是站点专属数据，监控员拉它没有消费者。
///    这正是骨架把 `polled()` 做成信号、而不是把机位一并塞进 `_poll()` 的原因。
```

- [ ] **Step 4: 构建并确认 QML 无错误**

```bash
cd /home/wangsl/qgroundcontrol && source .venv/bin/activate
just build 2>&1 | tail -10
```

启动一次，确认控制台没有 `TypeError: Cannot call method 'setMonitorDevices' of undefined`、没有 `Unable to assign [undefined]` 之类的 QML 报错。

> ⚠️ **P1 未落地时的预期行为**：③ 端点返回 404 ⇒ `_fetchMonitorDevices` 的失败分支 ⇒ **什么都不做**（清单保留为空）⇒ `_checkFrameTimeouts()` 遍历空数组 ⇒ 空转。**这是正确的降级**，不是缺陷。`CryptoController._monitorDevices` 为空 ⇒ `_sendRegistration` 回退 `_linkedDevices`，与改动前行为一致。

- [ ] **Step 5: 提交**

```bash
cd /home/wangsl/qgroundcontrol
git add src/OpsView/RomView.qml
git commit -m "feat(ops): RomView 推送接引清单与超时阈值，每 2s 定向重发（P5 §3.5.3/§3.6.2）"
```

---

## 验证边界：P5 能自证什么、不能自证什么

**能自证**（本计划的任务覆盖）：

| 判据（§9.2） | 落在哪个任务 |
|---|---|
| 分批：`n=18` 时批次大小依次 16、2、16、2… | Task 3 |
| 分批：跑满一轮后 **n 个 deviceID 全部出现过** | Task 3（覆盖性那一格） |
| `n ≤ 16` 时退化为现状（零回归） | Task 3 |
| `noteDeviceFrame` **两处都加了**（变异自证：删一行只红一格） | Task 2 |
| 超时判据吃「任意帧」不是「心跳帧」 | Task 2（加密帧那一格是核心格） |
| 超时**只重发、不移出登记集合** | Task 6（同时断言"发了"与"集合没动"） |
| 阈值与清单**同一次调用生效**（一个 setter 两个实参） | Task 4 |
| 老后端缺 `frame_timeout_ms` ⇒ 降级用默认，且不清空清单 | Task 4 |
| 集合不变时 2s 轮询不打乱 10s 周期 | Task 5 |
| 容量天花板（>80 架）时截断批数而非集合 | Task 5 |

**不能自证**（P5 单独跑完**证明不了**的，必须等 P1）：

1. **mavp2p 日志里去重后的 `linked PX4 deviceID=` 条数 == n**（§9.2 最硬的那条判据）。它需要一个真的返回 `devices[]` 的后端（P1 的 ③ 端点）与一条真实的 mavp2p 链路。
2. **「轮询失败不清空清单」的端到端格**（§9.2）。本计划在 C++ 侧由 Task 4 的"空清单回退"与 QML 侧 Step 2 的失败分支共同保证，但**「失败时确实没调用 `setMonitorDevices`」这件事没有自动化用例**——QML 侧无可注入的失败源。⇒ P1 落地后，端到端验证时用「停掉后端再观察 `_monitorDevices` 不变」补这一格。
3. **接引成功**（`multiVehicleManager.vehicles` 出现对应数量的真实 Vehicle）。同样依赖 P1。

⇒ **P5 完成后的状态是**：C++ 机制全绿、通道打通、在 P1 未落地时**安全降级为现状行为**（回退 `_linkedDevices`、清单为空、超时检查空转）。**不是**"接引已生效"。

## Self-Review

**1. Spec coverage（§3 逐节 → 任务）**

| §3 小节 | 覆盖 |
|---|---|
| §3.1 现状 | 无需改动（只读事实） |
| §3.2 结论：只改 QGC | Global Constraints 2/3 + 全程不改 mavp2p |
| §3.3 算法（游标 + 分批） | Task 3（算法）+ Task 4（接入） |
| §3.4 约束与边界（TTL/天花板/首次加速/200ms 间隔/不用 msleep） | Task 5（加速 + 天花板 + `QTimer::singleShot`）；约束 4/13 |
| §3.5.1 可见性判据 | **不在 P5**——判据在服务端（P1 的 ③ 端点），P5 只消费 `devices[]` |
| §3.5.2 两个数组 | **不在 P5**（P1）；P5 只吃 `devices[]` |
| §3.5.3 推送通道 + `setMonitorDevices` 签名 | Task 4（C++ 侧）+ Task 7（QML 暴露）+ Task 8（调用点） |
| §3.5.4 失败模式（陈旧好过清空） | Task 4（空清单回退 + 非法 id 跳过 + 阈值兜底）+ Task 8（失败分支什么都不做） |
| §3.6.1 判据在本地 + 两处收帧点 + 任意帧 | Task 1（API）+ Task 2（接线 + 变异自证） |
| §3.6.2 只管重发、不移出集合 | Task 6（含变异自证） |
| §3.6.3 定位是「加速」不是「保命」 | 不影响实现；已写进 Task 6 的注释 |
| §3.6.4 超时参数化（两个量、下限、TTL 上限、后端下发） | Task 4（`DEFAULT_FRAME_TIMEOUT_MS` + 同一次传入）+ Task 8（读 `frame_timeout_ms`） |

**无遗漏**。§3.5.1/§3.5.2 明确归 P1，已在「验证边界」写明。

**2. Placeholder scan**：全部步骤给出可直接落盘/执行的代码与命令。唯一的"待后续"是 Task 4 明确说明「`requestAcceleratedRegistration()` 的调用行推迟到 Task 5 加」，并给出了**理由**（空实现会让 Task 5 假绿）——这是排期约束，不是占位符。

**3. Type consistency**：
- `noteDeviceFrame(DeviceID)` / `msSinceLastFrame(quint32) const → qint64`：Task 1 定义，Task 2 使用，Task 8 调用的实参是 QML number（可转 quint32）✓
- `nextRegistrationBatch(const QList<DeviceID>&, int, int&) → QList<DeviceID>`：Task 3 定义，Task 4 使用 ✓
- `setMonitorDevices(const QVariantList&, int)`：Task 4 定义，Task 8 传 `(Array, Number)` ✓（QVariantList 接受 JS Array）
- `requestAcceleratedRegistration()`：Task 5 定义，Task 4 的 `setMonitorDevices` 与 `AuthController.cc` 使用 ✓
- `reRegisterDevice(quint32)`：Task 6 定义，Task 8 使用 ✓
- `frameTimeoutMs()` / `monitorDeviceCount()` / `registrationCursorForTest()` / `resetRegistrationCursorForTest()`：Task 4/5 定义，同名任务内使用 ✓
- `DEFAULT_FRAME_TIMEOUT_MS = 3000`：Task 4 定义，Task 4 测试与 Task 8 的 QML 初值（3000）一致 ✓

**4. 核实记录**（写计划时逐个 `command grep` 现数的，不是凭记忆）

本仓有一条已复发的教训：**注释里的「文件:行号」引用会被同文件增删行静默顶偏**。本计划里的行号因此全部现数过一次，执行前若文件已变动，**先重新数**（判据：`command grep -n` 一次，不要凭这里的数字）：

| 引用 | 现数结果 |
|---|---|
| `src/Comms/MAVLinkProtocol.cc:27` | `#include "Crypto/CryptoController.h"` ✓ |
| 明文心跳支的 `learnDeviceSystemMapping` | 209-210 行；自动建链判定 217-222 行；插桩点在其间 ✓ |
| `_processEncryptedFrame` 的 `learnDeviceSystemMapping` | 261 行；`isIncomingAcceptable` 265 行 ⇒ 插桩点在 261 与 265 之间 ✓ |
| `_processEncryptedFrame` 的局部变量名 | `crypto`（233 行定义）⇒ Task 2 用 `crypto->noteDeviceFrame(...)` ✓ |
| `src/Auth/AuthController.cc:348` | `CryptoController* const crypto = ...::instance();` ✓ |
| `src/Auth/AuthController.cc:376` | `crypto->addLinkedDevice(deviceID);` ✓ |
| `src/Auth/AuthController.cc:389` | `emit loginSucceeded();` ⇒ 插桩点在它**之前** ✓ |
| `test/MAVLink/CryptoTest.h:5` | `class CryptoTest : public UnitTest` ⇒ `expectLogMessage` 可用（`UnitTest.h:475`）✓ |
| `test/MAVLink/CryptoTest.cc:23` | `using namespace MAVLinkCrypto;` ⇒ 测试代码用**裸名**（本计划的 Task 4/5/6 照此写；Task 2 的新文件无 using，故保留完整限定）✓ |
| 符号存在性 | `makeDeviceID`（`DeviceID.h:35`）、`hasValidSignatureBit`（`:68`）、`setCryptoEnabled`（`CryptoController.h:66`）、`registrationEnabled`（`:74`）、`isIncomingAcceptable`/`commitIncoming`/`resetReplay`（`:156/159/162`）、`sendPlaintextMessageThreadSafe`（`LinkInterface.h:45`）、`QGC_REGISTRATION_DEVICE_ID_DEFAULT`（`VTOLSafetyMessages.h:732`，值 `10000U`）、`setCommLost`（`MockLink.h`，`MAVLinkV1TrafficTest.cc:89` 有实测用法）—— 全部存在 ✓ |

**核实中修掉的一处计划缺陷**：Task 2 原先让测试调 `crypto->setCryptoEnabled(true)`。**这是错的**——`receiveBytes` 的分支只由**帧内容**决定（`isPlaintextHeartbeat = (msgid==0 && payloadBlockLen<28)`，`MAVLinkProtocol.cc:199-202`），与 `cryptoEnabled` 全无关系；开它反而会拉起登记定时器与状态机，引入未预期日志，**strict mode 下会让用例失败**。已删除。
