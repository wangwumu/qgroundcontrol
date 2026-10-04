#include "DeviceKeyManager.h"

#include <QtCore/QJsonArray>
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

void DeviceKeyManager::fetchKeys(const QList<DeviceID>& deviceIDs)
{
    // N=1 也走本路径（服务端明说 ids 长度 1..N、N=1 合法，不必走别的路径）。
    // ⚠️ 校验口径与 CryptoController 里 addLinkedDevice / setMonitorDevices / releaseDevice
    //    那三处**逐字同组**（非 0 + 签名位合法）。口径漂移时没有任何东西会报错，
    //    只会表现为"某个 deviceID 在清单里却永远拉不到密钥"。
    QStringList ids;
    QList<DeviceID> accepted;
    for (DeviceID id : deviceIDs) {
        if (id == kInvalidDeviceID || !hasValidSignatureBit(id)) {
            continue;
        }
        ids << QString::number(id);
        accepted << id;
    }
    if (ids.isEmpty()) {
        // ‼️ 必须早退在 `keysRequested` **之前**——测试钉的就是"这一步之后什么都没发生"。
        return;
    }
    emit keysRequested(accepted); // 观测点：载荷是实际要拉的那批

    // GET /api/device-keys/batch?ids=…
    const QString url = QStringLiteral("%1/api/device-keys/batch?ids=%2")
                            .arg(_serverUrl, ids.join(QLatin1Char(',')));
    QNetworkRequest request = QGCNetworkHelper::createRequest(QUrl(url));
    if (!_authToken.isEmpty()) {
        QGCNetworkHelper::setBearerToken(request, _authToken);
    }

    QNetworkReply* reply = _networkManager->get(request);
    if (reply == nullptr) {
        // 静默：批量路径没有 fetchFailed 的逐条语义（见头文件说明）。
        qCWarning(DeviceKeyManagerLog) << "fetchKeys: 无法发起请求";
        return;
    }

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        _onBatchReplyFinished(reply);
        reply->deleteLater();
    });
}

void DeviceKeyManager::_onBatchReplyFinished(QNetworkReply* reply)
{
    // ⚠️ 判成功一律走 `QGCNetworkHelper::isSuccess`，**不写** `reply->error() != NoError`：
    //    Qt 的 `QNetworkReply::error()` 只在**网络层**出错时非 NoError，HTTP 404/401
    //    **不置**它。而服务端对"未登记密钥"与"范围外"正是回 **404**——那是**正常**情形，
    //    用 error() 判会把 404 当成成功、解析出空数组 ⇒ 静默吞掉（连日志都没有）。
    if (!QGCNetworkHelper::isSuccess(reply)) {
        qCWarning(DeviceKeyManagerLog) << "fetchKeys failed:" << QGCNetworkHelper::errorMessage(reply);
        return;
    }

    const QJsonDocument doc = QGCNetworkHelper::parseJsonReply(reply);
    if (doc.isNull() || !doc.isObject()) {
        qCWarning(DeviceKeyManagerLog) << "fetchKeys: 响应非合法 JSON";
        return;
    }

    // ⚠️ 服务端**已按可接引范围闸过滤**，这里拿到的就是本账号有权接引的那批——
    //    客户端不再判一次（两处判据必然漂移；客户端的职责只是"清单内才问"）。
    const QJsonArray arr = doc.object().value(QStringLiteral("devices")).toArray();
    for (const QJsonValue& value : arr) {
        const QJsonObject obj = value.toObject();
        // ‼️ 键名是 `deviceID`（驼峰），与登录响应原 `devices` 数组逐字同形。
        //    写成 `device_id` 会**静默**拿到 0 条 ⇒ 整条自动建链路径退回死锁，且无任何报错。
        const DeviceID deviceID =
            static_cast<DeviceID>(obj.value(QStringLiteral("deviceID")).toVariant().toUInt());
        const QByteArray keyBytes =
            QByteArray::fromBase64(obj.value(QStringLiteral("key")).toString().toUtf8());
        // ⚠️ `kKeySize` 是 size_t，与 `int` 比较触发 `-Wsign-compare`（本仓带 `-Werror`）
        //    ⇒ 与既有 `_onReplyFinished` 同款写字面 cast。
        if (keyBytes.size() != static_cast<int>(kKeySize)) {
            qCWarning(DeviceKeyManagerLog) << "fetchKeys: 密钥长度错误 device" << deviceID
                                           << keyBytes.size();
            continue;
        }

        Key key{};
        std::copy(keyBytes.constBegin(), keyBytes.constEnd(), key.begin());
        cacheKey(deviceID, key);

        qCDebug(DeviceKeyManagerLog) << "fetchKeys success for device" << deviceID;
        emit keyFetched(deviceID); // 复用既有信号，让 confirmLinking 那条既有链路照旧工作
    }
}

} // namespace MAVLinkCrypto
