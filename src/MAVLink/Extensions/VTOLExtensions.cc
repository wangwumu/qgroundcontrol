#include "VTOLExtensions.h"

#include <QtCore/QDateTime>

#include "MAVLinkLib.h"
#include "QGCLoggingCategory.h"

#include "Comms/LinkInterface.h"
#include "Comms/MAVLinkProtocol.h"
#include "Vehicle/Vehicle.h"
#include "Vehicle/VehicleLinkManager.h"

QGC_LOGGING_CATEGORY(VTOLExtensionsLog, "MAVLink.VTOLExtensions")

VTOLExtensions::VTOLExtensions(QObject* parent)
    : QObject(parent)
{
}

VTOLExtensions::~VTOLExtensions() = default;

bool VTOLExtensions::_sendMessage(Vehicle* vehicle, mavlink_message_t& msg)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "Cannot send VTOL message: null vehicle";
        return false;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "Cannot send VTOL message: no primary link";
        return false;
    }

    vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
    return true;
}

// ----------------------------------------------------------------------------
// Weather Forecast (msg_id 80000)
// ----------------------------------------------------------------------------
void VTOLExtensions::sendWeatherForecast(
    Vehicle* vehicle,
    double latitude, double longitude, float altitude,
    quint32 validFrom, quint32 validTo,
    quint8 weatherType, quint8 severity, quint8 confidence,
    float windSpeed, float windDirection,
    float temperature, float rainfall, float visibility,
    const QString& description)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "sendWeatherForecast: null vehicle";
        return;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "sendWeatherForecast: no primary link";
        return;
    }

    // Convert human-friendly units to MAVLink wire format (protocol Section 4.1)
    const auto latInt  = static_cast<int32_t>(latitude * 1e7);
    const auto lonInt  = static_cast<int32_t>(longitude * 1e7);
    const auto altInt  = static_cast<int32_t>(altitude * 1e3f);      // m → mm
    const auto wsInt   = static_cast<uint16_t>(qRound(windSpeed * 100.0f));     // m/s → cm/s
    const auto wdInt   = static_cast<uint16_t>(qRound(windDirection * 100.0f)); // deg → cdeg
    const auto tempInt = static_cast<int16_t>(qRound(temperature * 100.0f));    // °C → cdegC
    const auto rfInt   = static_cast<uint16_t>(qRound(rainfall * 10.0f));       // mm/h → mm/h×10
    const auto visInt  = static_cast<uint16_t>(visibility);

    // Truncate description to 21 bytes, pad with '\0'
    QByteArray descBytes = description.toUtf8().left(MAVLINK_MSG_WEATHER_FORECAST_FIELD_DESCRIPTION_LEN);
    descBytes.resize(MAVLINK_MSG_WEATHER_FORECAST_FIELD_DESCRIPTION_LEN, '\0');

    mavlink_message_t msg;
    mavlink_msg_weather_forecast_pack(
        static_cast<uint8_t>(MAVLinkProtocol::instance()->getSystemId()),
        MAVLinkProtocol::getComponentId(),
        &msg,
        latInt, lonInt, altInt,
        validFrom, validTo,
        weatherType, severity, confidence,
        wsInt, wdInt, tempInt, rfInt, visInt,
        descBytes.constData());

    vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
}

// ----------------------------------------------------------------------------
// Alternate Landing (msg_id 80001)
// ----------------------------------------------------------------------------
void VTOLExtensions::sendAlternateLanding(
    Vehicle* vehicle,
    const QString& siteId,
    double latitude, double longitude, float altitude,
    quint8 siteType, quint8 priority,
    float runwayLength, float runwayHeading,
    quint8 surfaceCondition, quint32 distanceFromCurrent,
    const QString& description)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "sendAlternateLanding: null vehicle";
        return;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "sendAlternateLanding: no primary link";
        return;
    }

    const auto latInt = static_cast<int32_t>(latitude * 1e7);
    const auto lonInt = static_cast<int32_t>(longitude * 1e7);
    const auto altInt = static_cast<int32_t>(altitude * 1e3f);           // m → mm
    const auto rLen   = static_cast<uint16_t>(runwayLength);
    const auto rHead  = static_cast<uint16_t>(qRound(runwayHeading * 100.0f)); // deg → cdeg

    QByteArray siteBytes = siteId.toUtf8().left(MAVLINK_MSG_ALTERNATE_LANDING_FIELD_SITE_ID_LEN);
    siteBytes.resize(MAVLINK_MSG_ALTERNATE_LANDING_FIELD_SITE_ID_LEN, '\0');

    QByteArray descBytes = description.toUtf8().left(MAVLINK_MSG_ALTERNATE_LANDING_FIELD_DESCRIPTION_LEN);
    descBytes.resize(MAVLINK_MSG_ALTERNATE_LANDING_FIELD_DESCRIPTION_LEN, '\0');

    mavlink_message_t msg;
    mavlink_msg_alternate_landing_pack(
        static_cast<uint8_t>(MAVLinkProtocol::instance()->getSystemId()),
        MAVLinkProtocol::getComponentId(),
        &msg,
        siteBytes.constData(),
        latInt, lonInt, altInt,
        siteType, priority,
        rLen, rHead,
        surfaceCondition, distanceFromCurrent,
        descBytes.constData());

    vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
}

// ----------------------------------------------------------------------------
// Sensor Control (msg_id 80002)
// ----------------------------------------------------------------------------
void VTOLExtensions::sendSensorCtrl(
    Vehicle* vehicle,
    quint8 targetSystem, quint8 targetComponent,
    quint8 sensorId, quint8 command)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "sendSensorCtrl: null vehicle";
        return;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "sendSensorCtrl: no primary link";
        return;
    }

    mavlink_message_t msg;
    mavlink_msg_sensor_ctrl_pack(
        static_cast<uint8_t>(MAVLinkProtocol::instance()->getSystemId()),
        MAVLinkProtocol::getComponentId(),
        &msg,
        targetSystem, targetComponent,
        sensorId, command);

    vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
}

// ----------------------------------------------------------------------------
// Emergency Landing Notify (msg_id 80009)
// ----------------------------------------------------------------------------
bool VTOLExtensions::sendEmergencyLandingCmd(
    Vehicle* vehicle, const QString& taskNo,
    double latitude, double longitude, float altitude,
    quint8 reason)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "sendEmergencyLandingCmd: null vehicle";
        return false;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "sendEmergencyLandingCmd: no primary link";
        return false;
    }

    // ‼️ `static_cast<int32_t>(NaN/Inf/超范围)` 是 UB：落点会静默变成一个**错误但合法**的
    //    坐标（x86 常见 INT_MIN）。QML 调用方已挡了大部分，但这是公开的 Q_INVOKABLE，
    //    必须在 C++ 侧自己 fail-closed。`altitude` 非法时退化为 0（=未知），不影响落点。
    if (!qIsFinite(latitude) || !qIsFinite(longitude)
        || qAbs(latitude) > 90.0 || qAbs(longitude) > 180.0) {
        qCWarning(VTOLExtensionsLog) << "sendEmergencyLandingCmd: invalid coordinates"
                                     << latitude << longitude;
        return false;
    }
    const double safeAltitude = qIsFinite(altitude) ? static_cast<double>(altitude) : 0.0;

    const auto latInt = static_cast<int32_t>(latitude * 1e7);
    const auto lonInt = static_cast<int32_t>(longitude * 1e7);
    const auto altInt = static_cast<int32_t>(safeAltitude * 1e3);   // m → mm
    // 秒级时间戳：上位机只拿它判重/算超时，不要求毫秒精度（与 80000 valid_from 同口径）。
    const auto timestamp = static_cast<uint32_t>(QDateTime::currentSecsSinceEpoch());

    // pack 里是 `_mav_put_char_array(..., 16)`（memcpy 16 字节）⇒ 必须补齐到定长，
    // 否则会读到 `constData()` 之外。截断按**原始字节**：若任务号含多字节 UTF-8 且正好
    // 被截在第 16 字节中间，接收端会拿到一个不完整的字符（协议字段没有长度前缀，无法规避）。
    QByteArray taskBytes = taskNo.toUtf8().left(MAVLINK_MSG_EMERGENCY_LANDING_CMD_FIELD_TASK_NO_LEN);
    taskBytes.resize(MAVLINK_MSG_EMERGENCY_LANDING_CMD_FIELD_TASK_NO_LEN, '\0');

    mavlink_message_t msg;
    mavlink_msg_emergency_landing_cmd_pack(
        static_cast<uint8_t>(MAVLinkProtocol::instance()->getSystemId()),
        MAVLinkProtocol::getComponentId(),
        &msg,
        latInt, lonInt, altInt,
        timestamp, taskBytes.constData(), reason);

    return vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
}

// ----------------------------------------------------------------------------
// Video Control (msg_id 80003)
// ----------------------------------------------------------------------------
void VTOLExtensions::sendVideoCtrl(
    Vehicle* vehicle,
    quint8 targetSystem, quint8 targetComponent,
    quint8 cameraId, quint8 videoCmd,
    quint16 resolutionW, quint16 resolutionH,
    quint8 framerate, quint16 bitrateKbps,
    const QString& codec)
{
    if (!vehicle) {
        qCWarning(VTOLExtensionsLog) << "sendVideoCtrl: null vehicle";
        return;
    }

    const SharedLinkInterfacePtr sharedLink = vehicle->vehicleLinkManager()->primaryLink().lock();
    if (!sharedLink) {
        qCWarning(VTOLExtensionsLog) << "sendVideoCtrl: no primary link";
        return;
    }

    QByteArray codecBytes = codec.toUtf8().left(MAVLINK_MSG_VIDEO_CTRL_FIELD_CODEC_LEN);
    codecBytes.resize(MAVLINK_MSG_VIDEO_CTRL_FIELD_CODEC_LEN, '\0');

    mavlink_message_t msg;
    mavlink_msg_video_ctrl_pack(
        static_cast<uint8_t>(MAVLinkProtocol::instance()->getSystemId()),
        MAVLinkProtocol::getComponentId(),
        &msg,
        targetSystem, targetComponent,
        cameraId, videoCmd,
        resolutionW, resolutionH,
        framerate, bitrateKbps,
        codecBytes.constData());

    vehicle->sendMessageOnLinkThreadSafe(sharedLink.get(), msg);
}
