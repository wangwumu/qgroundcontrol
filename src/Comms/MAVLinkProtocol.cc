#include "MAVLinkProtocol.h"

#include <QtCore/QApplicationStatic>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QMetaType>
#include <QtCore/QSettings>
#include <QtCore/QStandardPaths>
#include <QtCore/QTimer>
#include <cstring>

#include "AppMessages.h"
#include "AppSettings.h"
#include "LinkManager.h"
#include "MAVLinkLib.h"
#include "LinkInterface.h"
#include "MAVLinkSigning.h"
#include "SigningController.h"
#include "MavlinkSettings.h"
#include "MultiVehicleManager.h"
#include "QGCFileHelper.h"
#include "QGCLoggingCategory.h"
#include "QmlObjectListModel.h"
#include "SettingsManager.h"
#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/CryptoHeartbeatExt.h"
#include "Crypto/CryptoLinkLogger.h"

QGC_LOGGING_CATEGORY(MAVLinkProtocolLog, "Comms.MAVLinkProtocol")

Q_APPLICATION_STATIC(MAVLinkProtocol, _mavlinkProtocolInstance);

MAVLinkProtocol::MAVLinkProtocol(QObject* parent) : QObject(parent), _tempLogFile(new QFile(this))
{
    qCDebug(MAVLinkProtocolLog) << this;
}

MAVLinkProtocol::~MAVLinkProtocol()
{
    _closeLogFile();

    qCDebug(MAVLinkProtocolLog) << this;
}

MAVLinkProtocol* MAVLinkProtocol::instance()
{
    return _mavlinkProtocolInstance();
}

void MAVLinkProtocol::init()
{
    if (_initialized) {
        return;
    }

    (void)connect(MultiVehicleManager::instance(), &MultiVehicleManager::vehicleRemoved, this,
                  &MAVLinkProtocol::_vehicleCountChanged);

    _initialized = true;
}

void MAVLinkProtocol::resetMetadataForLink(LinkInterface* link)
{
    const uint8_t channel = link->mavlinkChannel();
    _totalReceiveCounter[channel] = 0;
    _totalLossCounter[channel] = 0;
    _runningLossPercent[channel] = 0.f;

    link->setDecodedFirstMavlinkPacket(false);
}

void MAVLinkProtocol::resetSequenceTracking(LinkInterface* link)
{
    // Clear per-(sysid,compid) sequence state so next packet isn't counted as a gap.
    const uint8_t channel = link->mavlinkChannel();
    _firstMessageSeen[channel].clear();
    std::memset(_lastIndex[channel], 0, sizeof(_lastIndex[channel]));
}

void MAVLinkProtocol::logSentBytes(const LinkInterface* link, const QByteArray& data)
{
    Q_UNUSED(link);

    if (_logSuspendError || _logSuspendReplay || !_tempLogFile->isOpen()) {
        return;
    }

    const quint64 time = static_cast<quint64>(QDateTime::currentMSecsSinceEpoch() * 1000);
    uint8_t bytes_time[sizeof(quint64)]{};
    qToBigEndian(time, bytes_time);

    QByteArray logData = data;
    QByteArray timeData = QByteArray::fromRawData(reinterpret_cast<const char*>(bytes_time), sizeof(bytes_time));
    (void)logData.prepend(timeData);
    if (_tempLogFile->write(logData) != logData.length()) {
        const QString message = QStringLiteral("MAVLink Logging failed. Could not write to file %1, logging disabled.")
                                    .arg(_tempLogFile->fileName());
        QGC::showAppMessage(message, getName());
        _stopLogging();
        _logSuspendError = true;
    }
}

void MAVLinkProtocol::receiveBytes(LinkInterface* link, const QByteArray& data)
{
    const SharedLinkInterfacePtr linkPtr = LinkManager::instance()->sharedLinkInterfacePointerForLink(link);
    if (!linkPtr) {
        qCDebug(MAVLinkProtocolLog) << "receiveBytes: link gone!" << data.size() << "bytes arrived too late";
        return;
    }

    // 加密链路：先重组/解密/还原标准帧，再走常规解析。
    if (MAVLinkCrypto::CryptoController::instance()->cryptoEnabled()) {
        _receiveEncryptedBytes(link, linkPtr, data);
        return;
    }

    for (uint8_t byte : data) {
        const uint8_t mavlinkChannel = link->mavlinkChannel();
        mavlink_message_t message{};
        mavlink_status_t status{};

        const uint8_t framing = mavlink_parse_char(mavlinkChannel, byte, &message, &status);
        if (framing == MAVLINK_FRAMING_OK || framing == MAVLINK_FRAMING_BAD_SIGNATURE) {
            if (SigningController* const sigCtrl = link->signing()) {
                // Auto-detected key: reset sequence tracking so the key-install gap isn't counted as loss.
                if (sigCtrl->processFrame(framing == MAVLINK_FRAMING_OK, message)) {
                    resetSequenceTracking(link);
                }
            }
        }
        if (framing != MAVLINK_FRAMING_OK) {
            continue;
        }

        // v1/v2 share per-(sysid,compid) sequence counters; counting v1 makes every v2 appear lost. Skip v1 non-heartbeats.
        // RADIO_STATUS is exempt: SiK radios always frame it as v1, so it is processed and never triggers the v1 warning.
        const bool isV1 = (status.flags & MAVLINK_STATUS_FLAG_IN_MAVLINK1);
        if (isV1 && (message.msgid != MAVLINK_MSG_ID_HEARTBEAT) && (message.msgid != MAVLINK_MSG_ID_RADIO_STATUS)) {
            link->reportMavlinkV1Traffic();
            continue;
        }

        if (!isV1) {
            link->reportMavlinkV2Traffic();
            _updateCounters(mavlinkChannel, message);
        }
        if (!linkPtr->linkConfiguration()->isForwarding()) {
            _forward(message);
            _forwardSupport(message);
        }
        _logData(link, message);

        // 联调日志：非加密接收路径（cryptoEnabled=false）也记录收到的帧，
        // 使 QGC 侧日志包含双方信息（与 PX4 mavlink_trace 双向记录对应）。
        // 加密路径（_receiveEncryptedBytes）已在各分支记录 incoming，此处不重复。
        uint8_t logFrame[MAVLINK_MAX_PACKET_LEN];
        const int logFrameLen = mavlink_msg_to_send_buffer(logFrame, &message);
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            message.msgid, MAVLinkCrypto::fromMessage(message), false,
            reinterpret_cast<const char*>(logFrame), logFrameLen, nullptr, 0, true);

        if (!_updateStatus(link, linkPtr, mavlinkChannel, message)) {
            break;
        }
    }
}

void MAVLinkProtocol::_receiveEncryptedBytes(LinkInterface* link, const SharedLinkInterfacePtr& linkPtr,
                                             const QByteArray& data)
{
    const uint8_t channel = link->mavlinkChannel();
    QByteArray& buffer = _cryptoRxBuffer[channel];
    buffer.append(data);

    // 流式重组完整加密帧：magic(0xFD) + len + 10 字节头 + payload block + CRC。
    while (buffer.size() >= static_cast<int>(MAVLinkCrypto::kV2HeaderLen)) {
        if (static_cast<uint8_t>(buffer[0]) != 0xFD) {
            buffer.remove(0, 1); // 丢弃非 magic 字节，重新同步
            continue;
        }
        const int payloadBlockLen = static_cast<uint8_t>(buffer[1]);
        const int totalLen = static_cast<int>(MAVLinkCrypto::kV2HeaderLen) + payloadBlockLen +
                             static_cast<int>(MAVLinkCrypto::kCrcLen);
        if (buffer.size() < totalLen) {
            break; // 不完整帧，等待更多字节
        }

        const QByteArray frame = buffer.left(totalLen);
        buffer.remove(0, totalLen);

        const uint8_t* const frameData = reinterpret_cast<const uint8_t*>(frame.constData());
        const uint32_t msgid = MAVLinkCrypto::msgidFromFrame(frameData);
        // 明文待命心跳判定：msgID=0 且 payload block < 28（counter+deviceID+tag 最小块）。
        // 加密帧 header 的 msgid 也是明文，建链后的加密 HEARTBEAT（msgID=0、payload≥28）
        // 必须走解密，否则密文会被标准解析器按 HEARTBEAT 字段解析成垃圾值（绕过 GCM 认证）。
        const bool isPlaintextHeartbeat =
            (msgid == MAVLINK_MSG_ID_HEARTBEAT) &&
            (payloadBlockLen < static_cast<int>(MAVLinkCrypto::kCounterSize + MAVLinkCrypto::kDeviceIDSize +
                                               MAVLinkCrypto::kTagSize));
        if (isPlaintextHeartbeat) {
            // 明文特例：待命心跳（msgID=0）不加密、无 counter/tag（规范 §2.2）。
            // 学习 deviceID↔sysid 映射后走标准解析器，识别在线/待命。
            const MAVLinkCrypto::DeviceID deviceID = MAVLinkCrypto::deviceIDFromFrame(frameData);
            MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
                0, deviceID, false, reinterpret_cast<const char*>(frameData), frame.size(), nullptr, 0, true);
            MAVLinkCrypto::CryptoController::instance()->learnDeviceSystemMapping(
                deviceID, MAVLinkCrypto::systemID(deviceID));

            // 自动建链（C2 修正）：待命心跳声明 PX4 在线，且本地已缓存该 deviceID 的密钥 → 自动建链。
            // 否则 QGC 初始连接状态机发出的 COMMAND_LONG 等命令在 Standby 下全被 LinkInterface 丢弃，
            // PX4 永远收不到任何请求 → 初始连接死锁（航线 UI 又依赖连接完成，形成鸡生蛋）。
            // 只对「本地已注入密钥」的设备自动建链：cryptoKeySource=0 本地联调 / 已缓存密钥的设备安全可控；
            // 无密钥设备维持原语义（用户发航线时手动 beginLinkingForSystemID）。
            MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
            if (crypto->state() == MAVLinkCrypto::CryptoController::State::Standby &&
                crypto->deviceKeyManager()->hasKey(deviceID)) {
                crypto->beginLinking(deviceID);
            }

            _feedStandardFrame(link, linkPtr, channel, frameData, frame.size());
        } else {
            _processEncryptedFrame(link, linkPtr, channel, frame);
        }
    }
}

void MAVLinkProtocol::_processEncryptedFrame(LinkInterface* link, const SharedLinkInterfacePtr& linkPtr,
                                             uint8_t channel, const QByteArray& encFrame)
{
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    const uint8_t* const encData = reinterpret_cast<const uint8_t*>(encFrame.constData());
    const int encLen = encFrame.size();

    // 帧头重组 deviceID、读 msgid（帧头 10 字节恒完整，payload 再短也可读）
    const MAVLinkCrypto::DeviceID deviceID = MAVLinkCrypto::deviceIDFromFrame(encData);
    const uint32_t msgid = MAVLinkCrypto::msgidFromFrame(encData);

    // 长度检查（规范 §2.6 第 0 步）：payload block >= counter(8) + deviceID(4) + tag(16) = 28
    const int payloadBlockLen = MAVLinkCrypto::frameLength(encData);
    if (payloadBlockLen < static_cast<int>(MAVLinkCrypto::kCounterSize + MAVLinkCrypto::kDeviceIDSize +
                                           MAVLinkCrypto::kTagSize)) {
        // 短帧：可能是明文短消息（对端未加密）或损坏帧，打日志便于排查「在线但无遥测」。
        qCWarning(MAVLinkProtocolLog) << "short frame on crypto link, len" << payloadBlockLen
                                      << "msgid" << msgid
                                      << "deviceID" << deviceID;
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
            QStringLiteral("畸形短帧"));
        return; // 畸形帧
    }

    // 读 counter（payload block 明文前 8 字节）
    const uint64_t counter = MAVLinkCrypto::counterFromFrame(encData);

    // 学习 deviceID ↔ systemID 映射（供上层按 vehicle->id() 触发建链）。
    // 明文帧头即可重组，无需密钥；放在取密钥前可打破全新启动的死锁
    //（否则无密钥→无法解密→无法学习映射→beginLinkingForSystemID 无从触发）。
    crypto->learnDeviceSystemMapping(deviceID, MAVLinkCrypto::systemID(deviceID));

    // 防重放「判定」（规范 §2.6 第 3 步：仅判定，不更新 lastNonce，
    // 更新须待解密 + tag 认证通过后，见下方 commitIncoming）。
    if (!crypto->isIncomingAcceptable(deviceID, counter)) {
        qCDebug(MAVLinkProtocolLog) << "encrypted frame replay dropped" << deviceID << counter;
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
            QStringLiteral("防重放拒绝"));
        return;
    }

    // 取密钥（规范 §2.6 第 5 步）
    MAVLinkCrypto::Key key;
    if (!crypto->deviceKeyManager()->keyForDevice(deviceID, key)) {
        qCWarning(MAVLinkProtocolLog) << "no key for device" << deviceID << ", dropping encrypted frame";
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
            QStringLiteral("无密钥"));
        return; // 未登记设备
    }

    // crc_extra（从帧头 msgid 查）
    const mavlink_msg_entry_t* const entry = mavlink_get_msg_entry(msgid);
    if (entry == nullptr) {
        qCWarning(MAVLinkProtocolLog) << "unknown msgid" << msgid << "for device" << deviceID << ", dropping";
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
            QStringLiteral("未知msgid"));
        return; // 未知 msgid，无法验证 CRC
    }
    const uint8_t crcExtra = entry->crc_extra;

    // 解密 + 密钥绑定 + 还原标准帧（规范 §2.6 第 6-8 步）
    uint8_t plainFrame[MAVLINK_MAX_PACKET_LEN];
    MAVLinkCrypto::DeviceID boundDeviceID;
    uint64_t boundCounter;
    int plainLen = 0;
    if (!MAVLinkCrypto::decryptFrame(encData, encLen, crcExtra, key, &boundDeviceID, &boundCounter, plainFrame,
                                     &plainLen)) {
        qCWarning(MAVLinkProtocolLog) << "decryptFrame failed for device" << deviceID << "msgid" << msgid;
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
            QStringLiteral("解密失败"));
        return; // 解密失败 / tag 校验失败 / 密钥绑定失败
    }

    // 防重放「提交」（规范 §2.6 第 9 步）：认证通过后才更新 lastNonce，
    // 防止未认证的伪造帧（明文 counter 可伪造）污染重放窗口。
    crypto->commitIncoming(deviceID, counter);

    // 空 payload 退化帧（规范 §2.3 超限退化）→ 丢弃消息（帧本身已通过认证）
    if (plainFrame[1] == 0) {
        qCDebug(MAVLinkProtocolLog) << "dropped empty-payload degraded frame for device" << deviceID << "msgid" << msgid;
        MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
            msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, true);
        return;
    }

    // 解密成功：记录收到（明文内容=解密后的可读字段）+ 还原的标准帧喂给标准解析器。
    MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
        msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen,
        reinterpret_cast<const char*>(plainFrame), plainLen, true);

    // 先喂标准帧（加密心跳内嵌的标准 HEARTBEAT：Vehicle 学 defaultComponentId + 更新模式/武装），
    // 再注入 EXT 遥测（协议 60822.0）：PX4 精简 GCS 链路独立遥测后，加密心跳是遥测唯一来源，
    // 明文 HEARTBEAT payload > 9 → 解析 EXT(37B) 构造标准遥测消息，替代原独立遥测流。
    _feedStandardFrame(link, linkPtr, channel, plainFrame, plainLen);
    // payload > 9 说明含 EXT。解析失败（PX4 版本漂移 / EXT 长度变更）会丢全部遥测——
    // 必须告警 + 日志，避免"在线但无遥测"静默（遥测唯一来源失效）。
    if (msgid == MAVLINK_MSG_ID_HEARTBEAT && plainFrame[1] > 9) {
        MAVLinkCrypto::HeartbeatExt ext;
        if (MAVLinkCrypto::parseHeartbeatExtFromFrame(msgid, plainFrame, plainLen, &ext)) {
            _injectHeartbeatExt(link, linkPtr, channel, plainFrame, ext);
        } else {
            qCWarning(MAVLinkProtocolLog) << "encrypted heartbeat EXT parse failed: device" << deviceID
                                          << "payloadLen" << static_cast<int>(plainFrame[1]);
            MAVLinkCrypto::CryptoLinkLogger::instance()->logIncoming(
                msgid, deviceID, true, reinterpret_cast<const char*>(encData), encLen, nullptr, 0, false,
                QStringLiteral("EXT解析失败"));
        }
    }
}

void MAVLinkProtocol::_feedStandardFrame(LinkInterface* link, const SharedLinkInterfacePtr& linkPtr, uint8_t channel,
                                         const uint8_t* bytes, int len)
{
    for (int i = 0; i < len; ++i) {
        mavlink_message_t message{};
        mavlink_status_t status{};
        const uint8_t framing = mavlink_parse_char(channel, bytes[i], &message, &status);
        if (framing != MAVLINK_FRAMING_OK) {
            continue;
        }

        const bool isV1 = (status.flags & MAVLINK_STATUS_FLAG_IN_MAVLINK1);
        if (isV1 && (message.msgid != MAVLINK_MSG_ID_HEARTBEAT) && (message.msgid != MAVLINK_MSG_ID_RADIO_STATUS)) {
            link->reportMavlinkV1Traffic();
            continue;
        }

        if (!isV1) {
            link->reportMavlinkV2Traffic();
            _updateCounters(channel, message);
        }
        if (!linkPtr->linkConfiguration()->isForwarding()) {
            _forward(message);
            _forwardSupport(message);
        }
        _logData(link, message);

        if (!_updateStatus(link, linkPtr, channel, message)) {
            return;
        }
    }
}

void MAVLinkProtocol::_injectHeartbeatExt(LinkInterface* link, const SharedLinkInterfacePtr& linkPtr, uint8_t channel,
                                          const uint8_t* plainFrame, const MAVLinkCrypto::HeartbeatExt& ext)
{
    Q_UNUSED(linkPtr)
    Q_UNUSED(channel)

    // 打包逻辑（门控/哨兵/字段映射）提取在 CryptoHeartbeatExt::buildHeartbeatExtTelemetry（可单测）。
    // 此处只遍历 emit，经 telemetryInjected 走 Vehicle 消费（绕过 seq/丢包统计，避免合成消息污染 _messagesLost）。
    const QList<mavlink_message_t> msgs = MAVLinkCrypto::buildHeartbeatExtTelemetry(plainFrame, ext);
    for (const mavlink_message_t& msg : msgs) {
        emit telemetryInjected(link, msg);
    }
}

void MAVLinkProtocol::_updateCounters(uint8_t mavlinkChannel, const mavlink_message_t& message)
{
    _totalReceiveCounter[mavlinkChannel]++;

    uint8_t& lastSeq = _lastIndex[mavlinkChannel][message.sysid][message.compid];

    const QPair<uint8_t, uint8_t> key(message.sysid, message.compid);
    uint8_t expectedSeq;
    if (!_firstMessageSeen[mavlinkChannel].contains(key)) {
        _firstMessageSeen[mavlinkChannel].insert(key);
        expectedSeq = message.seq;
    } else if (message.seq == lastSeq) {
        // v1/v2 of the same message share sequence numbers — duplicate seq isn't loss.
        return;
    } else {
        expectedSeq = lastSeq + 1;
    }

    uint64_t lostMessages;
    if (message.seq >= expectedSeq) {
        lostMessages = message.seq - expectedSeq;
    } else {
        lostMessages = static_cast<uint64_t>(message.seq) + 256ULL - expectedSeq;
    }
    _totalLossCounter[mavlinkChannel] += lostMessages;

    lastSeq = message.seq;

    const uint64_t totalSent = _totalReceiveCounter[mavlinkChannel] + _totalLossCounter[mavlinkChannel];
    const float currentLossPercent = (static_cast<double>(_totalLossCounter[mavlinkChannel]) / totalSent) * 100.0f;
    _runningLossPercent[mavlinkChannel] = (currentLossPercent + _runningLossPercent[mavlinkChannel]) * 0.5f;
}

void MAVLinkProtocol::_forward(const mavlink_message_t& message)
{
    if (message.msgid == MAVLINK_MSG_ID_SETUP_SIGNING) {
        return;
    }

    if (!SettingsManager::instance()->mavlinkSettings()->forwardMavlink()->rawValue().toBool()) {
        return;
    }

    SharedLinkInterfacePtr forwardingLink = LinkManager::instance()->mavlinkForwardingLink();
    if (!forwardingLink) {
        return;
    }

    // Strip signature on forward: foreign key would BAD_SIGNATURE on downstream signing-aware parsers.
    const QByteArray bytes = MAVLinkSigning::serializeUnsignedCopy(message);
    (void)forwardingLink->writeBytesThreadSafe(bytes.constData(), bytes.size());
}

void MAVLinkProtocol::_forwardSupport(const mavlink_message_t& message)
{
    if (message.msgid == MAVLINK_MSG_ID_SETUP_SIGNING) {
        return;
    }

    if (!LinkManager::instance()->mavlinkSupportForwardingEnabled()) {
        return;
    }

    SharedLinkInterfacePtr forwardingSupportLink = LinkManager::instance()->mavlinkForwardingSupportLink();
    if (!forwardingSupportLink) {
        return;
    }

    const QByteArray bytes = MAVLinkSigning::serializeUnsignedCopy(message);
    (void)forwardingSupportLink->writeBytesThreadSafe(bytes.constData(), bytes.size());
}

void MAVLinkProtocol::_logData(LinkInterface* link, const mavlink_message_t& message)
{
    if (!_logSuspendError && !_logSuspendReplay && _tempLogFile->isOpen()) {
        // MAVLink spec §Logging: omit SETUP_SIGNING (contains secret key)
        if (message.msgid != MAVLINK_MSG_ID_SETUP_SIGNING) {
            // MAVLink spec §Logging: strip signature block from logged packets.
            const QByteArray msgBytes = MAVLinkSigning::serializeUnsignedCopy(message);
            const quint64 timestamp = static_cast<quint64>(QDateTime::currentMSecsSinceEpoch() * 1000);
            QByteArray log_data;
            log_data.resize(static_cast<qsizetype>(sizeof(timestamp)) + msgBytes.size());
            qToBigEndian(timestamp, reinterpret_cast<uint8_t*>(log_data.data()));
            std::memcpy(log_data.data() + sizeof(timestamp), msgBytes.constData(), msgBytes.size());
            if (_tempLogFile->write(log_data) != log_data.size()) {
                const QString logErrorMessage =
                    QStringLiteral("MAVLink Logging failed. Could not write to file %1, logging disabled.")
                        .arg(_tempLogFile->fileName());
                QGC::showAppMessage(logErrorMessage, getName());
                _stopLogging();
                _logSuspendError = true;
            }
        }

        if ((message.msgid == MAVLINK_MSG_ID_HEARTBEAT) && !_vehicleWasArmed) {
            if (mavlink_msg_heartbeat_get_base_mode(&message) & MAV_MODE_FLAG_DECODE_POSITION_SAFETY) {
                _vehicleWasArmed = true;
            }
        }
    }

    switch (message.msgid) {
        case MAVLINK_MSG_ID_HEARTBEAT: {
            _startLogging();
            mavlink_heartbeat_t heartbeat{};
            mavlink_msg_heartbeat_decode(&message, &heartbeat);
            emit vehicleHeartbeatInfo(link, message.sysid, message.compid, heartbeat.autopilot, heartbeat.type);
            break;
        }
        case MAVLINK_MSG_ID_HIGH_LATENCY: {
            _startLogging();
            mavlink_high_latency_t highLatency{};
            mavlink_msg_high_latency_decode(&message, &highLatency);
            // HIGH_LATENCY does not provide autopilot or type information, generic is our safest bet
            emit vehicleHeartbeatInfo(link, message.sysid, message.compid, MAV_AUTOPILOT_GENERIC, MAV_TYPE_GENERIC);
            break;
        }
        case MAVLINK_MSG_ID_HIGH_LATENCY2: {
            _startLogging();
            mavlink_high_latency2_t highLatency2{};
            mavlink_msg_high_latency2_decode(&message, &highLatency2);
            emit vehicleHeartbeatInfo(link, message.sysid, message.compid, highLatency2.autopilot, highLatency2.type);
            break;
        }
        default:
            break;
    }
}

bool MAVLinkProtocol::_updateStatus(LinkInterface* link, const SharedLinkInterfacePtr linkPtr, uint8_t mavlinkChannel,
                                    const mavlink_message_t& message)
{
    if ((_totalReceiveCounter[mavlinkChannel] % 31) == 0) {
        const uint64_t totalSent = _totalReceiveCounter[mavlinkChannel] + _totalLossCounter[mavlinkChannel];
        emit mavlinkMessageStatus(message.sysid, totalSent, _totalReceiveCounter[mavlinkChannel],
                                  _totalLossCounter[mavlinkChannel], _runningLossPercent[mavlinkChannel]);
    }

    emit messageReceived(link, message);

    if (linkPtr.use_count() == 1) {
        return false;
    }

    return true;
}

bool MAVLinkProtocol::_closeLogFile()
{
    if (!_tempLogFile->isOpen()) {
        return false;
    }

    if (_tempLogFile->size() == 0) {
        (void)_tempLogFile->remove();
        return false;
    }

    (void)_tempLogFile->flush();
    _tempLogFile->close();
    return true;
}

void MAVLinkProtocol::_startLogging()
{
    if (QGC::runningUnitTests()) {
        return;
    }

    AppSettings* const appSettings = SettingsManager::instance()->appSettings();
    if (appSettings->disableAllPersistence()->rawValue().toBool()) {
        return;
    }

#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    if (!SettingsManager::instance()->mavlinkSettings()->telemetrySave()->rawValue().toBool()) {
        return;
    }
#endif

    if (_tempLogFile->isOpen()) {
        return;
    }

    if (_logSuspendReplay) {
        return;
    }

    // Generate unique temp file path for this logging session
    const QString logPath =
        QGCFileHelper::uniqueTempPath(QStringLiteral("%1.%2").arg(_tempLogFileTemplate, _logFileExtension));
    if (logPath.isEmpty()) {
        qCWarning(MAVLinkProtocolLog) << "Failed to generate temp log path";
        _logSuspendError = true;
        return;
    }

    _tempLogFile->setFileName(logPath);
    if (!_tempLogFile->open(QIODevice::WriteOnly)) {
        const QString message = QStringLiteral(
                                    "Opening Flight Data file for writing failed. "
                                    "Unable to write to %1. Please choose a different file location.")
                                    .arg(_tempLogFile->fileName());
        QGC::showAppMessage(message, getName());
        _closeLogFile();
        _logSuspendError = true;
        return;
    }

    qCDebug(MAVLinkProtocolLog) << "Temp log" << _tempLogFile->fileName();
    (void)_checkTelemetrySavePath();

    _logSuspendError = false;
}

void MAVLinkProtocol::_stopLogging()
{
    if (_tempLogFile->isOpen() && _closeLogFile()) {
        auto appSettings = SettingsManager::instance()->appSettings();
        auto mavlinkSettings = SettingsManager::instance()->mavlinkSettings();
        if ((_vehicleWasArmed || mavlinkSettings->telemetrySaveNotArmed()->rawValue().toBool()) &&
            mavlinkSettings->telemetrySave()->rawValue().toBool() &&
            !appSettings->disableAllPersistence()->rawValue().toBool()) {
            _saveTelemetryLog(_tempLogFile->fileName());
        } else {
            (void)QFile::remove(_tempLogFile->fileName());
        }
    }

    _vehicleWasArmed = false;
}

void MAVLinkProtocol::checkForLostLogFiles()
{
    static const QDir tempDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation));
    static const QString filter(QStringLiteral("*.%1").arg(_logFileExtension));
    static const QStringList filterList(filter);

    const QFileInfoList fileInfoList = tempDir.entryInfoList(filterList, QDir::Files);
    qCDebug(MAVLinkProtocolLog) << "Orphaned log file count" << fileInfoList.count();

    for (const QFileInfo& fileInfo : fileInfoList) {
        qCDebug(MAVLinkProtocolLog) << "Orphaned log file" << fileInfo.filePath();
        if (fileInfo.size() == 0) {
            (void)QFile::remove(fileInfo.filePath());
            continue;
        }
        _saveTelemetryLog(fileInfo.filePath());
    }
}

void MAVLinkProtocol::deleteTempLogFiles()
{
    static const QDir tempDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation));
    static const QString filter(QStringLiteral("*.%1").arg(_logFileExtension));

    const QFileInfoList fileInfoList = tempDir.entryInfoList(QStringList(filter), QDir::Files);
    qCDebug(MAVLinkProtocolLog) << "Temp log file count" << fileInfoList.count();

    for (const QFileInfo& fileInfo : fileInfoList) {
        qCDebug(MAVLinkProtocolLog) << "Temp log file" << fileInfo.filePath();
        (void)QFile::remove(fileInfo.filePath());
    }
}

void MAVLinkProtocol::_saveTelemetryLog(const QString& tempLogfile)
{
    if (_checkTelemetrySavePath()) {
        const QString saveDirPath = SettingsManager::instance()->appSettings()->telemetrySavePath();
        const QDir saveDir(saveDirPath);

        const QString nameFormat("%1%2.%3");
        const QString dtFormat("yyyy-MM-dd hh-mm-ss");

        int tryIndex = 1;
        QString saveFileName = nameFormat.arg(QDateTime::currentDateTime().toString(dtFormat), QString(),
                                              AppSettings::telemetryFileExtension);
        while (saveDir.exists(saveFileName)) {
            saveFileName = nameFormat.arg(QDateTime::currentDateTime().toString(dtFormat),
                                          QStringLiteral(".%1").arg(tryIndex++), AppSettings::telemetryFileExtension);
        }

        const QString saveFilePath = saveDir.absoluteFilePath(saveFileName);

        QFile in(tempLogfile);
        if (!in.open(QIODevice::ReadOnly)) {
            const QString error =
                tr("Unable to save telemetry log. Error opening source '%1': '%2'.").arg(tempLogfile, in.errorString());
            QGC::showAppMessage(error);
            (void)QFile::remove(tempLogfile);
            return;
        }

        QSaveFile out(saveFilePath);
        out.setDirectWriteFallback(true);  // allows non-atomic fallback where rename isn’t possible

        if (!out.open(QIODevice::WriteOnly)) {
            const QString error = tr("Unable to save telemetry log. Error opening destination '%1': '%2'.")
                                      .arg(saveFilePath, out.errorString());
            QGC::showAppMessage(error);
            (void)QFile::remove(tempLogfile);
            return;
        }

        // Stream copy to avoid large allocations.
        QByteArray buffer;
        constexpr int bufferSize = 256 * 1024;  // 256 KiB
        buffer.resize(bufferSize);
        while (true) {
            const qint64 n = in.read(buffer.data(), buffer.size());
            if (n == 0) {
                break;
            }
            if (n < 0) {
                const QString error = tr("Unable to save telemetry log. Error reading source '%1': '%2'.")
                                          .arg(tempLogfile, in.errorString());
                QGC::showAppMessage(error);
                out.cancelWriting();
                (void)QFile::remove(tempLogfile);
                return;
            }
            if (out.write(buffer.constData(), n) != n) {
                const QString error = tr("Unable to save telemetry log. Error writing destination '%1': '%2'.")
                                          .arg(saveFilePath, out.errorString());
                QGC::showAppMessage(error);
                out.cancelWriting();
                (void)QFile::remove(tempLogfile);
                return;
            }
        }

        if (!out.commit()) {
            const QString error =
                tr("Unable to finalize telemetry log '%1': '%2'.").arg(saveFilePath, out.errorString());
            QGC::showAppMessage(error);
            (void)QFile::remove(tempLogfile);
            return;
        }

        constexpr QFileDevice::Permissions perms =
            QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ReadGroup | QFileDevice::ReadOther;
        (void)out.setPermissions(perms);
    }

    (void)QFile::remove(tempLogfile);
}

bool MAVLinkProtocol::_checkTelemetrySavePath()
{
    const QString saveDirPath = SettingsManager::instance()->appSettings()->telemetrySavePath();
    if (saveDirPath.isEmpty()) {
        const QString error = tr("Unable to save telemetry log. Application save directory is not set.");
        QGC::showAppMessage(error);
        return false;
    }

    const QDir saveDir(saveDirPath);
    if (!saveDir.exists()) {
        const QString error =
            tr("Unable to save telemetry log. Telemetry save directory \"%1\" does not exist.").arg(saveDirPath);
        QGC::showAppMessage(error);
        return false;
    }

    return true;
}

void MAVLinkProtocol::_vehicleCountChanged()
{
    if (MultiVehicleManager::instance()->vehicles()->count() == 0) {
        _stopLogging();
    }
}

int MAVLinkProtocol::getSystemId() const
{
    return SettingsManager::instance()->mavlinkSettings()->gcsMavlinkSystemID()->rawValue().toInt();
}
