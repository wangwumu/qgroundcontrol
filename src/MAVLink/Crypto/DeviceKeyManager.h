#pragma once

/// 设备通信密钥管理（依据 `docs/10_deviceID与payload加密公共规范.md` §2.7）。
///
/// QGC 经 HTTPS/REST 向 gcs_server 获取某设备的 AES-256 通信密钥（`GET /api/device-keys/:deviceId`），
/// 本地内存缓存，密钥不走 MAVLink 链路。本模块为独立组件：
/// - 通过 setServerUrl()/setAuthToken() 接收 gcs_server 配置（接线阶段由设置模块注入）；
/// - 密钥缓存在内存，进程退出即失效（如需持久化再另行设计，当前遵循"开发阶段"约定）。
///
/// 线程安全：密钥缓存由互斥锁保护（接收链路可能多线程查询）。

#include <QtCore/QHash>
#include <QtCore/QMutex>
#include <QtCore/QObject>
#include <QtCore/QString>

#include "DeviceID.h"
#include "MAVLinkCrypto.h"

class QNetworkAccessManager;
class QNetworkReply;

namespace MAVLinkCrypto {

class DeviceKeyManager : public QObject
{
    Q_OBJECT

public:
    explicit DeviceKeyManager(QObject* parent = nullptr);
    ~DeviceKeyManager() override;

    DeviceKeyManager(const DeviceKeyManager&) = delete;
    DeviceKeyManager& operator=(const DeviceKeyManager&) = delete;

    /// 配置 gcs_server 地址（如 https://uav.example.com，不含尾斜杠）。
    void setServerUrl(const QString& url) { _serverUrl = url; }

    /// 配置登录认证 token（Bearer，不含 "Bearer " 前缀）。
    void setAuthToken(const QString& token) { _authToken = token; }

    /// 是否已配置服务器地址。
    bool isConfigured() const { return !_serverUrl.isEmpty(); }

    /// 本地是否已缓存该设备密钥。
    bool hasKey(DeviceID deviceID) const;

    /// 取本地缓存密钥。
    /// @return true=命中，outKey 填充；false=未缓存
    bool keyForDevice(DeviceID deviceID, Key& outKey) const;

    /// 手动缓存密钥（如密钥轮换后由上层写入）。
    void cacheKey(DeviceID deviceID, const Key& key);

    /// 清除指定设备的缓存密钥。
    void removeKey(DeviceID deviceID);

    /// 清空全部缓存。
    void clearCache();

    /// 异步向 gcs_server 获取设备密钥。
    /// 完成后发 keyFetched()（成功）或 fetchFailed()（失败）。
    void fetchKey(DeviceID deviceID);

signals:
    /// 密钥获取成功（已缓存，可通过 keyForDevice 读取）。
    void keyFetched(DeviceID deviceID);

    /// 密钥获取失败。
    void fetchFailed(DeviceID deviceID, const QString& error);

private:
    void _onReplyFinished(DeviceID deviceID, QNetworkReply* reply);

    QNetworkAccessManager* _networkManager = nullptr;
    QString _serverUrl;
    QString _authToken;
    QHash<DeviceID, Key> _keyCache;
    mutable QMutex _cacheMutex;
};

} // namespace MAVLinkCrypto
