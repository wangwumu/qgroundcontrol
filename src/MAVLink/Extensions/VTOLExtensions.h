#pragma once

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtQmlIntegration/QtQmlIntegration>

#include "VTOLExtensionsEnums.h"
#include "VTOLSafetyMessages.h"

class Vehicle;

Q_DECLARE_LOGGING_CATEGORY(VTOLExtensionsLog)

/// @brief QML singleton providing VTOL safety extension message send helpers.
///
/// All send methods are static Q_INVOKABLE — callable directly from QML.
/// Enums are exposed via VTOLExtensionsEnums (Q_NAMESPACE), referenced in
/// QML as e.g. VTOLExtensionsEnums.WeatherClear.
class VTOLExtensions : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(VTOLExtensions)
    QML_SINGLETON

public:
    explicit VTOLExtensions(QObject* parent = nullptr);
    ~VTOLExtensions() override;

    // ------------------------------------------------------------------------
    // Weather Forecast (msg_id 80000)
    // ------------------------------------------------------------------------
    /// Send a single-point weather forecast. Multiple points sent as separate messages.
    /// @param vehicle      Target vehicle (null-checked; silently returns if null)
    /// @param latitude     WGS84 latitude in decimal degrees
    /// @param longitude    WGS84 longitude in decimal degrees
    /// @param altitude     MSL altitude in meters
    /// @param validFrom    Forecast valid-start UTC timestamp (seconds)
    /// @param validTo      Forecast valid-end UTC timestamp (seconds)
    /// @param weatherType  VTOLWeatherType enum value
    /// @param severity     VTOLWeatherSeverity enum value
    /// @param confidence   Confidence 0-100
    /// @param windSpeed    Wind speed m/s
    /// @param windDirection Wind direction degrees (0 = north)
    /// @param temperature  Temperature Celsius
    /// @param rainfall     Rainfall intensity mm/h
    /// @param visibility   Visibility meters (0 = unlimited)
    /// @param description  Text description (max 20 chars, truncated if longer)
    Q_INVOKABLE static void sendWeatherForecast(
        Vehicle* vehicle,
        double latitude, double longitude, float altitude,
        quint32 validFrom, quint32 validTo,
        quint8 weatherType, quint8 severity, quint8 confidence,
        float windSpeed, float windDirection,
        float temperature, float rainfall, float visibility,
        const QString& description);

    // ------------------------------------------------------------------------
    // Alternate Landing (msg_id 80001)
    // ------------------------------------------------------------------------
    /// Send an alternate landing site. One message per site.
    /// @param vehicle              Target vehicle
    /// @param siteId              Unique site identifier (max 15 chars)
    /// @param latitude            WGS84 latitude in decimal degrees
    /// @param longitude           WGS84 longitude in decimal degrees
    /// @param altitude            MSL altitude in meters
    /// @param siteType            VTOLAltType enum value
    /// @param priority            Priority (1 = highest)
    /// @param runwayLength        Runway length meters (0 if N/A)
    /// @param runwayHeading       Runway heading degrees (0 if N/A)
    /// @param surfaceCondition    VTOLSurfaceCondition enum value
    /// @param distanceFromCurrent Straight-line distance from current position (m)
    /// @param description         Text description (max 30 chars)
    Q_INVOKABLE static void sendAlternateLanding(
        Vehicle* vehicle,
        const QString& siteId,
        double latitude, double longitude, float altitude,
        quint8 siteType, quint8 priority,
        float runwayLength, float runwayHeading,
        quint8 surfaceCondition, quint32 distanceFromCurrent,
        const QString& description);

    // ------------------------------------------------------------------------
    // Sensor Control (msg_id 80002)
    // ------------------------------------------------------------------------
    /// Send a sensor enable/disable command.
    /// @param vehicle          Target vehicle
    /// @param targetSystem     Target system ID
    /// @param targetComponent  Target component ID
    /// @param sensorId         VTOLSensorID enum value
    /// @param command          VTOLSensorCmd enum value (0=DISABLE, 1=ENABLE)
    Q_INVOKABLE static void sendSensorCtrl(
        Vehicle* vehicle,
        quint8 targetSystem, quint8 targetComponent,
        quint8 sensorId, quint8 command);

    // ------------------------------------------------------------------------
    // Emergency Landing Notify (msg_id 80009)
    // ------------------------------------------------------------------------
    /// 迫降通告：告知机载计算机「本次迫降已开始、落点在此」，由它接管降落监控与
    /// 落地后的处置。**不是控制指令** —— 飞行控制由紧随其前的
    /// `MAV_CMD_NAV_LAND(21)` 完成；本消息只在上位机侧建立上下文。
    /// @param vehicle    Target vehicle
    /// @param taskNo     Flight task number (UTF-8, max 16 **bytes**). Truncation is
    ///                   by raw bytes, so a multi-byte char may be split at the
    ///                   boundary. The wire field is fixed-length and **not**
    ///                   NUL-terminated.
    /// @param latitude   Coordinates as sent to the autopilot alongside this notice,
    ///                   decimal degrees. ⚠️ They are **not** what PX4 lands on —
    ///                   `MAV_CMD_NAV_LAND` makes PX4 land at its own position at
    ///                   command time; these are for the companion computer's record.
    /// @param longitude  Ditto
    /// @param altitude   MSL altitude of the aircraft at send time, meters (0 = unknown).
    ///                   Context only — not a landing target height.
    /// @param reason     VTOL_EMERGENCY_REASON_* (1 = operator confirmed)
    /// @return true=已交给链路发送；false=载具/链路不可用，或坐标非法（未发送）。
    ///         ⚠️ 协议里本消息**没有应答**，true 只代表「已发出」，不代表上位机已收到。
    Q_INVOKABLE static bool sendEmergencyLandingCmd(
        Vehicle* vehicle, const QString& taskNo,
        double latitude, double longitude, float altitude,
        quint8 reason);

    // ------------------------------------------------------------------------
    // Video Control (msg_id 80003)
    // ------------------------------------------------------------------------
    /// Send a video control command.
    /// @param vehicle          Target vehicle
    /// @param targetSystem     Target system ID
    /// @param targetComponent  Target component ID
    /// @param cameraId         VTOLCameraID enum value
    /// @param videoCmd         VTOLVideoCmd enum value
    /// @param resolutionW      Horizontal pixels (0 = no change)
    /// @param resolutionH      Vertical pixels (0 = no change)
    /// @param framerate        Frame rate Hz (0 = no change)
    /// @param bitrateKbps      Bitrate kbps (0 = no change)
    /// @param codec            Codec string ("h264", "h265", "mjpeg"; empty = no change)
    Q_INVOKABLE static void sendVideoCtrl(
        Vehicle* vehicle,
        quint8 targetSystem, quint8 targetComponent,
        quint8 cameraId, quint8 videoCmd,
        quint16 resolutionW, quint16 resolutionH,
        quint8 framerate, quint16 bitrateKbps,
        const QString& codec);

private:
    /// Helper: pack, finalize, and send a message on the vehicle's primary link.
    /// Returns true if sent, false if no link or vehicle is null.
    static bool _sendMessage(Vehicle* vehicle, mavlink_message_t& msg);
};
