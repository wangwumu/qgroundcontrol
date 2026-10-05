#include "LinkInterface.h"
#include "MAVLinkLib.h"
#include "LinkManager.h"
#include "AppMessages.h"
#include "QGCApplication.h"
#include "QGCLoggingCategory.h"
#include "SigningController.h"
#include "FlightEventLogger.h"
#include "Crypto/CryptoCodec.h"
#include "Crypto/CryptoController.h"
#include "Crypto/CryptoLinkLogger.h"
#include "Extensions/VTOLSafetyMessages.h"

#include <QtQml/QQmlEngine>

QGC_LOGGING_CATEGORY(LinkInterfaceLog, "Comms.LinkInterface")

LinkInterface::LinkInterface(SharedLinkConfigurationPtr &config, QObject *parent)
    : QObject(parent)
    , _config(config)
{
    QQmlEngine::setObjectOwnership(this, QQmlEngine::CppOwnership);
}

LinkInterface::~LinkInterface()
{
    if (_vehicleReferenceCount != 0) {
        qCWarning(LinkInterfaceLog) << "still have vehicle references:" << _vehicleReferenceCount;
    }

    _config.reset();
}

uint8_t LinkInterface::mavlinkChannel() const
{
    if (!mavlinkChannelIsSet()) {
        qCWarning(LinkInterfaceLog) << "mavlinkChannelIsSet() == false";
    }

    return _mavlinkChannel;
}

bool LinkInterface::mavlinkChannelIsSet() const
{
    return (LinkManager::invalidMavlinkChannel() != _mavlinkChannel);
}

bool LinkInterface::_allocateMavlinkChannel()
{
    Q_ASSERT(!mavlinkChannelIsSet());

    if (mavlinkChannelIsSet()) {
        qCWarning(LinkInterfaceLog) << "already have" << _mavlinkChannel;
        return true;
    }

    _mavlinkChannel = LinkManager::instance()->allocateMavlinkChannel();

    if (!mavlinkChannelIsSet()) {
        qCWarning(LinkInterfaceLog) << "failed";
        return false;
    }

    qCDebug(LinkInterfaceLog) << "_allocateMavlinkChannel" << _mavlinkChannel;

    mavlink_set_proto_version(_mavlinkChannel, MAVLINK_VERSION); // We only support v2 protcol

    _signingController = std::make_unique<SigningController>(static_cast<mavlink_channel_t>(_mavlinkChannel));
    _signingController->clearSigning();

    qCDebug(LinkInterfaceLog) << "SigningController created for channel" << _mavlinkChannel
                              << (isSecureConnection() ? "(secure)" : "(will auto-detect)");

    return true;
}

void LinkInterface::_freeMavlinkChannel()
{
    qCDebug(LinkInterfaceLog) << _mavlinkChannel;

    if (!mavlinkChannelIsSet()) {
        return;
    }

    // Destroy the controller before freeing the channel so it can flush the final timestamp.
    _signingController.reset();

    // mavlink_reset_channel_status only resets parse_state — null signing/streams explicitly to avoid dangling derefs.
    mavlink_status_t* const status = mavlink_get_channel_status(_mavlinkChannel);
    status->signing = nullptr;
    status->signing_streams = nullptr;
    mavlink_reset_channel_status(_mavlinkChannel);

    LinkManager::instance()->freeMavlinkChannel(_mavlinkChannel);
    _mavlinkChannel = LinkManager::invalidMavlinkChannel();
}

void LinkInterface::writeBytesThreadSafe(const char *bytes, int length)
{
    const QByteArray data(bytes, length);
    (void) QMetaObject::invokeMethod(this, "_writeBytes", Qt::AutoConnection, data);
}

void LinkInterface::sendMessageThreadSafe(mavlink_message_t &message)
{
    // Re-sign with a current timestamp; the cached-resend path (Vehicle::sendMessageMultiple) otherwise ships frozen
    // signed bytes whose timestamp drifts behind wall clock and gets OLD_TIMESTAMP-rejected. No-op when signing is
    // disabled or the message isn't outgoing-signed. The secret key stays in the signing layer.
    if (_signingController) {
        (void) _signingController->signOutgoing(message);
    }

    uint8_t buffer[MAVLINK_MAX_PACKET_LEN];
    const int len = mavlink_msg_to_send_buffer(buffer, &message);

    // 加密链路：Active 状态下，对外发指令加密（deviceID 拆分 + payload AES-GCM）。
    MAVLinkCrypto::CryptoController* const crypto = MAVLinkCrypto::CryptoController::instance();
    if (crypto->cryptoEnabled()) {
        if (crypto->state() != MAVLinkCrypto::CryptoController::State::Active) {
            // GCS 心跳（msgid 0）被丢是**预期**行为，不是异常：协议 §2.5 下 PX4 结构性收不到
            // GCS 心跳（mavp2p 会拦），此处也不该发明文（全加密链路上接收端会丢弃明文帧）。
            // 它不构成「指令丢失」，因此：
            //   * **不进 FlightEventLogger** —— 否则 QGC 从启动到建链成功的整段时间里每秒
            //     一条「发送被丢弃」，会把真正的飞行事件淹掉；
            //   * 日志降到 Debug —— 默认不出现在控制台（原先 1Hz 刷屏），
            //     需要时 `--logging=Comms.LinkInterface` 仍看得到。
            // 其余 msgid 一律保留告警 + 事件日志：那些是用户真下发的命令（任务上传、起飞、
            // 降落…），事后必须能看出「没到飞控」。
            if (message.msgid == MAVLINK_MSG_ID_HEARTBEAT) {
                qCDebug(LinkInterfaceLog) << "crypto enabled, link not Active, dropping GCS heartbeat";
                return;
            }
            // 加密已启用但链路未就绪：不发明文（全加密链路上接收端会丢弃明文帧）。
            qCWarning(LinkInterfaceLog) << "crypto enabled, link not Active, dropping msgid" << message.msgid;
            // 帧被丢了就没发出去 —— 事件日志必须记「丢弃」而不是记「已发」，
            // 否则事后对着日志会以为命令下达到了飞控。
            FlightEventLogger::instance()->logLinkEvent(
                tr("发送被丢弃：加密已启用但链路未就绪（命令编号 %1）").arg(message.msgid));
            return;
        }
        MAVLinkCrypto::Key key;
        uint64_t counter = 0;
        if (crypto->activeKey(key) && crypto->nextOutgoingCounter(counter)) {
            // 80000-80003 未注册进 mavlink 生成层，mavlink_get_crc_extra 返回 0；
            // 走自定义 CRC 助手，否则加密帧 CRC 与接收端不一致（规范 mavlink_extension_protocol.md）。
            uint8_t crcExtra = 0;
            if (!mavlink_msg_vtol_crc_extra(message.msgid, &crcExtra)) {
                crcExtra = mavlink_get_crc_extra(&message);
            }
            uint8_t encBuffer[MAVLINK_MAX_PACKET_LEN + 32];
            int encLen = 0;
            // 帧头/明文内嵌/nonce 的 deviceID 一律用「目标无人机」，接收方按它查自己的密钥；
            // 用 GCS 自身 deviceID 会导致 PX4 查无密钥而丢弃。
            if (MAVLinkCrypto::encryptFrame(buffer, len, crcExtra, crypto->activeDeviceID(), counter, key, encBuffer, &encLen)) {
                MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
                    message.msgid, crypto->activeDeviceID(), true,
                    reinterpret_cast<const char*>(encBuffer), encLen,
                    reinterpret_cast<const char*>(buffer), len, true);
                writeBytesThreadSafe(reinterpret_cast<const char*>(encBuffer), encLen);
                // 发送侧事件日志挂在这里而**不是函数入口**：入口处还有「加密未就绪」「加密失败」
                // 两条 return，在入口记会把没发出去的帧记成已发出 —— 事后对着日志会以为命令到了飞控。
                // 此处 message 仍是明文（encryptFrame 不修改它），读得出发的是什么命令。
                FlightEventLogger::instance()->logFrame(FlightEventLogger::Direction::ToVehicle, message);
                return;
            }
            // 加密失败：丢弃帧，不回退明文（回退明文会被接收端丢弃，且违反全加密不变量）
            qCWarning(LinkInterfaceLog) << "encryptFrame failed for msgid" << message.msgid
                                        << "counter" << counter << "device" << crypto->activeDeviceID();
            FlightEventLogger::instance()->logLinkEvent(
                tr("发送被丢弃：帧加密失败（命令编号 %1）").arg(message.msgid));
            // 无线上密文帧：以明文记录（encrypted=false，避免把明文当密文读 counter 产生垃圾值）
            MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
                message.msgid, crypto->activeDeviceID(), false,
                reinterpret_cast<const char*>(buffer), len, nullptr, 0, false,
                QStringLiteral("加密失败"));
            return;
        }
        // 密钥未就绪（理论不可达：Active 保证有 key）
        qCWarning(LinkInterfaceLog) << "crypto active but no key/counter, dropping msgid" << message.msgid;
        return;
    }

    MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
        message.msgid,
        MAVLinkCrypto::CryptoLinkLogger::deviceIDFromFrameBytes(reinterpret_cast<const char*>(buffer), len),
        false, reinterpret_cast<const char*>(buffer), len, nullptr, 0, true);
    writeBytesThreadSafe(reinterpret_cast<const char *>(buffer), len);
    FlightEventLogger::instance()->logFrame(FlightEventLogger::Direction::ToVehicle, message);
}

void LinkInterface::sendPlaintextMessageThreadSafe(const mavlink_message_t& message)
{
    // 明文特例（规范 §2.2）：如 80005 QGC 登记/保活心跳——不加密、无 counter/tag。
    // 直接序列化后写入，绕过 sendMessageThreadSafe 的加密路径（加密会破坏明文特例语义）。
    uint8_t buffer[MAVLINK_MAX_PACKET_LEN];
    const int len = mavlink_msg_to_send_buffer(buffer, &message);
    MAVLinkCrypto::CryptoLinkLogger::instance()->logOutgoing(
        message.msgid, QGC_REGISTRATION_DEVICE_ID_DEFAULT, false,
        reinterpret_cast<const char*>(buffer), len, nullptr, 0, true);
    writeBytesThreadSafe(reinterpret_cast<const char*>(buffer), len);
    // 第二个发送咽喉：80005 登记保活走这里，绕过 sendMessageThreadSafe，漏挂就整条看不见。
    FlightEventLogger::instance()->logFrame(FlightEventLogger::Direction::ToVehicle, message);
}

void LinkInterface::removeVehicleReference()
{
    if (_vehicleReferenceCount != 0) {
        _vehicleReferenceCount--;
        _connectionRemoved();
    } else {
        qCWarning(LinkInterfaceLog) << "called with no vehicle references";
    }
}

void LinkInterface::_connectionRemoved()
{
    if (_vehicleReferenceCount == 0) {
        // Since there are no vehicles on the link we can disconnect it right now
        disconnect();
    } else {
        // If there are still vehicles on this link we allow communication lost to trigger and don't automatically disconect until all the vehicles go away
    }
}

void LinkInterface::reportMavlinkV1Traffic()
{
    if (_mavlinkV1TrafficReported || _mavlinkV2TrafficSeen) {
        return;
    }

    // Defer the warning: ArduPilot starts out sending v1 and upgrades to v2 once it sees v2
    // traffic from QGC. Only warn if the link never produces v2 within the grace period.
    if (!_mavlinkV1FirstSeenTimer.isValid()) {
        _mavlinkV1FirstSeenTimer.start();
    }
    if (_mavlinkV1FirstSeenTimer.elapsed() < _mavlinkV1TrafficGraceMsecs) {
        return;
    }

    _mavlinkV1TrafficReported = true;

    const SharedLinkConfigurationPtr linkConfig = linkConfiguration();
    const QString linkName = linkConfig ? linkConfig->name() : QStringLiteral("unknown");
    qCWarning(LinkInterfaceLog) << "MAVLink v1 traffic detected on link" << linkName;
    const QString message = tr("MAVLink v1 traffic detected on link '%1'. "
                               "%2 only supports MAVLink v2. "
                               "Please ensure your vehicle is configured to use MAVLink v2.")
                                .arg(linkName).arg(qgcApp()->applicationName());
    QGC::showAppMessage(message);
}
