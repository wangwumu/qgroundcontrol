#include "DeviceKeyManager.h"

#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLoggingCategory>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>

#include "QGCLoggingCategory.h"
#include "Utilities/Network/QGCNetworkHelper.h"

#include <algorithm>

QGC_LOGGING_CATEGORY(DeviceKeyManagerLog, "MAVLink.Crypto.DeviceKeyManager")

namespace MAVLinkCrypto {

DeviceKeyManager::DeviceKeyManager(QObject* parent)
    : QObject(parent)
    , _networkManager(QGCNetworkHelper::createNetworkManager(this))
{
}

DeviceKeyManager::~DeviceKeyManager()
{
    // 安全清零缓存中的密钥
    clearCache();
}

bool DeviceKeyManager::hasKey(DeviceID deviceID) const
{
    const QMutexLocker locker(&_cacheMutex);
    return _keyCache.contains(deviceID);
}

bool DeviceKeyManager::keyForDevice(DeviceID deviceID, Key& outKey) const
{
    const QMutexLocker locker(&_cacheMutex);
    const auto it = _keyCache.constFind(deviceID);
    if (it == _keyCache.constEnd()) {
        return false;
    }
    outKey = it.value();
    return true;
}

void DeviceKeyManager::cacheKey(DeviceID deviceID, const Key& key)
{
    const QMutexLocker locker(&_cacheMutex);
    _keyCache.insert(deviceID, key);
}

void DeviceKeyManager::removeKey(DeviceID deviceID)
{
    const QMutexLocker locker(&_cacheMutex);
    auto it = _keyCache.find(deviceID);
    if (it != _keyCache.end()) {
        std::fill(it.value().begin(), it.value().end(), 0); // 安全清零
        _keyCache.erase(it);
    }
}

void DeviceKeyManager::clearCache()
{
    const QMutexLocker locker(&_cacheMutex);
    for (auto& key : _keyCache) {
        std::fill(key.begin(), key.end(), 0); // 安全清零
    }
    _keyCache.clear();
}

void DeviceKeyManager::fetchKey(DeviceID deviceID)
{
    if (!isConfigured()) {
        qCWarning(DeviceKeyManagerLog) << "fetchKey: gcs_server not configured";
        emit fetchFailed(deviceID, QStringLiteral("gcs_server 未配置"));
        return;
    }

    // GET /api/device-keys/:deviceId
    const QString url = QStringLiteral("%1/api/device-keys/%2").arg(_serverUrl).arg(deviceID);
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    QNetworkReply* reply = _networkManager->get(request);
    if (reply == nullptr) {
        emit fetchFailed(deviceID, QStringLiteral("无法发起请求"));
        return;
    }

    connect(reply, &QNetworkReply::finished, this, [this, deviceID, reply]() {
        _onReplyFinished(deviceID, reply);
        reply->deleteLater();
    });
}

void DeviceKeyManager::_onReplyFinished(DeviceID deviceID, QNetworkReply* reply)
{
    if (!QGCNetworkHelper::isSuccess(reply)) {
        const QString error = QGCNetworkHelper::errorMessage(reply);
        qCWarning(DeviceKeyManagerLog) << "fetchKey failed:" << error;
        emit fetchFailed(deviceID, error);
        return;
    }

    const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
    if (doc.isNull() || !doc.isObject()) {
        emit fetchFailed(deviceID, QStringLiteral("响应非合法 JSON"));
        return;
    }

    const QJsonObject obj = doc.object();
    // 兼容 { "key": "<base64>" } 与 { "data": { "key": "<base64>" } } 两种常见形态
    const QJsonValue keyValue = obj.contains(QStringLiteral("key"))
                                    ? obj.value(QStringLiteral("key"))
                                    : obj.value(QStringLiteral("data")).toObject().value(QStringLiteral("key"));
    if (!keyValue.isString()) {
        emit fetchFailed(deviceID, QStringLiteral("响应缺少 key 字段"));
        return;
    }

    const QByteArray keyBytes = QByteArray::fromBase64(keyValue.toString().toUtf8());
    if (keyBytes.size() != static_cast<int>(kKeySize)) {
        emit fetchFailed(deviceID, QStringLiteral("密钥长度错误：%1（应为 %2）").arg(keyBytes.size()).arg(kKeySize));
        return;
    }

    Key key{};
    std::copy(keyBytes.constBegin(), keyBytes.constEnd(), key.begin());
    cacheKey(deviceID, key);

    qCDebug(DeviceKeyManagerLog) << "fetchKey success for device" << deviceID;
    emit keyFetched(deviceID);
}

} // namespace MAVLinkCrypto
