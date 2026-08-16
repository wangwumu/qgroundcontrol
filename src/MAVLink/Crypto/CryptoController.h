#pragma once

/// QGC 端加密链路握手状态机（依据 `docs/10_deviceID与payload加密公共规范.md` §2.5/§2.6 与第三部分「QGC 地面站」契约）。
///
/// 职责：
/// - 状态机：待命(Standby) → 建链中(Linking) → 正常(Active) → 回待命；
/// - counter 管理：QGC 发送用**奇数**，建链首帧取加密安全随机 62 位奇数起点，此后取「严格大于该 deviceID 全局 lastNonce 的最小奇数」；
/// - 防重放：按 deviceID 维护全局 lastNonce，`本次 > lastNonce` 才接受；
/// - 密钥：经 DeviceKeyManager 获取，本控制器持有一个「活跃目标 deviceID + 密钥」。
///
/// 本模块为**状态与 counter 管理核心**；收发 hook 由 LinkInterface/MAVLinkProtocol 接线调用。
/// 线程安全：状态/映射由本类 `_mutex` 保护；lastNonce 由 ReplayGuard 内部锁保护（二者独立，避免嵌套加锁）。

#include <QtCore/QHash>
#include <QtCore/QMutex>
#include <QtCore/QMutexLocker>
#include <QtCore/QObject>
#include <QtCore/QString>

#include "DeviceID.h"
#include "DeviceKeyManager.h"
#include "MAVLinkCrypto.h"
#include "ReplayGuard.h"

namespace MAVLinkCrypto {

class CryptoController : public QObject
{
    Q_OBJECT

public:
    enum class State {
        Standby, ///< 待命：只读（解密遥测），不建链、不发指令
        Linking, ///< 建链中：已选定目标、取密钥中/已就绪；密钥就绪后自动进入 Active
        Active,  ///< 正常：可加密下发指令
    };
    Q_ENUM(State)

    explicit CryptoController(QObject* parent = nullptr);
    ~CryptoController() override;

    CryptoController(const CryptoController&) = delete;
    CryptoController& operator=(const CryptoController&) = delete;

    /// 全局单例访问点（收发链路均通过它访问加密状态）。
    static CryptoController* instance();

    /// 本端 GCS 的 deviceID。
    void setGcsDeviceID(DeviceID deviceID);

    /// 是否启用加密链路（由 CryptoSettings 注入）。
    void setCryptoEnabled(bool enabled);
    bool cryptoEnabled() const;

    /// 设备密钥管理器（从 gcs_server 取密钥）。
    DeviceKeyManager* deviceKeyManager() { return &_keyManager; }

    /// 当前状态（线程安全，加锁读取）。
    State state() const;

    /// 本端 GCS 的 deviceID（线程安全，加锁读取）。
    DeviceID gcsDeviceID() const;

    /// 当前建链的目标无人机 deviceID（无任务时为 kInvalidDeviceID）。
    DeviceID activeDeviceID() const;

    /// 当前目标设备的通信密钥是否已就绪。
    bool hasActiveKey() const;

    /// 取当前目标设备的密钥。
    /// @return true=成功，outKey 填充；false=无活跃设备或密钥未就绪
    bool activeKey(Key& outKey) const;

    // -----------------------------------------------------------------------
    // 握手流程
    // -----------------------------------------------------------------------

    /// 任务建链：选定目标无人机，取密钥，进入 Linking。
    /// 由上层在「确定航线 + 选定无人机」时调用。
    void beginLinking(DeviceID targetDeviceID);

    /// 按 systemID 触发建链（便捷方法：内部查 deviceID↔systemID 映射）。
    /// 供上层（如 MissionController::sendToVehicle）用 vehicle->id() 触发。
    void beginLinkingForSystemID(uint8_t systemID);

    /// 学习 deviceID ↔ systemID 映射（接收端解密成功后调用）。
    void learnDeviceSystemMapping(DeviceID deviceID, uint8_t systemID);

    /// 按 systemID 查 deviceID。
    /// @return true=命中，outDeviceID 填充；false=未学习到映射
    bool deviceIDForSystemID(uint8_t systemID, DeviceID& outDeviceID) const;

    /// 密钥就绪后进入 Active（可下发指令）。
    /// 注意：当前实现把「gcs_server 取密钥成功」视为建链确认，并未等待 PX4 的显式确认报文。
    void confirmLinking();

    /// 建链失败（取密钥失败），回到 Standby。
    void failLinking(const QString& error);

    /// 任务结束 / 断链，回到 Standby（继续只读遥测）。
    void returnToStandby();

    // -----------------------------------------------------------------------
    // counter 管理与防重放
    // -----------------------------------------------------------------------

    /// 取下一个本方向（QGC 奇数）发送 counter，并**原子预留**（更新 lastNonce）。
    /// 仅 Active 状态可调用。
    /// @return true=成功，outCounter 填充；false=非 Active 状态
    bool nextOutgoingCounter(uint64_t& outCounter);

    /// 生成加密安全随机 62 位奇数 counter 起点（规范 §2.5：建链首帧用随机起点，
    /// 避免重启后从 1 重来导致同一密钥下 nonce 复用）。
    /// @return [1, 2^62) 内的奇数
    static uint64_t randomOddCounter();

    /// 接收帧防重放「判定」（协议 §2.6 第 3 步）：counter > lastNonce[deviceID]？
    /// 纯检查，不更新状态。@return true=可接受；false=重放/乱序
    bool isIncomingAcceptable(DeviceID deviceID, uint64_t counter) const;

    /// 接收帧防重放「提交」（协议 §2.6 第 9 步）：解密 + tag 认证通过后更新 lastNonce。
    void commitIncoming(DeviceID deviceID, uint64_t counter);

    /// 重置指定设备的 lastNonce（如建链时清历史）。
    void resetReplay(DeviceID deviceID);

signals:
    void stateChanged();
    void linkingConfirmed(DeviceID deviceID);
    void linkingFailed(DeviceID deviceID, const QString& error);

private:
    void _onKeyFetched(DeviceID deviceID);
    void _onFetchFailed(DeviceID deviceID, const QString& error);

    State _state = State::Standby;
    DeviceID _gcsDeviceID = kInvalidDeviceID;
    DeviceID _activeDeviceID = kInvalidDeviceID;
    DeviceKeyManager _keyManager; ///< 密钥管理（内部持有，构造时以 this 为 parent）
    bool _cryptoEnabled = false;
    ReplayGuard _replayGuard;
    QHash<DeviceID, uint8_t> _deviceToSystem; ///< deviceID → systemID 映射（接收端学习）
    QHash<uint8_t, DeviceID> _systemToDevice; ///< systemID → deviceID 反向映射
    mutable QMutex _mutex;
};

} // namespace MAVLinkCrypto
