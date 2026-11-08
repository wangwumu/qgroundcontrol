#pragma once

#include <QtCore/QObject>
#include <QtQmlIntegration/QtQmlIntegration>

namespace VTOLExtensionsEnums {
    Q_NAMESPACE
    QML_NAMED_ELEMENT(VTOLExtensionsEnums)

    // -- VTOL Weather Type (protocol Section 3.1) --
    enum VTOLWeatherType : quint8 {
        WeatherUnknown      = 0,
        WeatherClear        = 1,
        WeatherCloudy       = 2,
        WeatherRain         = 3,
        WeatherHeavyRain    = 4,
        WeatherSnow         = 5,
        WeatherFog          = 6,
        WeatherThunderstorm = 7,
        WeatherStrongWind   = 8,
        WeatherHail         = 9,
    };
    Q_ENUM_NS(VTOLWeatherType)

    // -- VTOL Weather Severity (protocol Section 3.2) --
    enum VTOLWeatherSeverity : quint8 {
        SeverityUnknown   = 0,
        SeverityAdvisory  = 1,
        SeverityWatch     = 2,
        SeverityWarning   = 3,
        SeverityCritical  = 4,
    };
    Q_ENUM_NS(VTOLWeatherSeverity)

    // -- VTOL Alternate Landing Type (protocol Section 3.3) --
    enum VTOLAltType : quint8 {
        AltRunway  = 0,
        AltField   = 1,
        AltWater   = 2,
        AltHelipad = 3,
        AltRoad    = 4,
        AltOther   = 5,
    };
    Q_ENUM_NS(VTOLAltType)

    // -- Surface Condition (protocol Section 4.2) --
    enum VTOLSurfaceCondition : quint8 {
        SurfaceUnknown = 0,
        SurfaceDry     = 1,
        SurfaceWet     = 2,
        SurfaceSnow    = 3,
        SurfaceIce     = 4,
    };
    Q_ENUM_NS(VTOLSurfaceCondition)

    // -- VTOL Sensor ID (protocol Section 3.4) --
    enum VTOLSensorID : quint8 {
        SensorFrontLidar   = 0,
        SensorRearLidar    = 1,
        SensorFrontMMWave  = 2,
        SensorTempHumidity = 3,
        SensorRain         = 4,
        SensorAll          = 15,
    };
    Q_ENUM_NS(VTOLSensorID)

    // -- VTOL Sensor Command (protocol Section 3.5) --
    enum VTOLSensorCmd : quint8 {
        SensorCmdDisable = 0,
        SensorCmdEnable  = 1,
    };
    Q_ENUM_NS(VTOLSensorCmd)

    // -- VTOL Camera ID (protocol Section 3.6) --
    enum VTOLCameraID : quint8 {
        CameraNose = 0,
        CameraDown = 1,
        CameraTail = 2,
        CameraAll  = 15,
    };
    Q_ENUM_NS(VTOLCameraID)

    // -- VTOL Video Command (protocol Section 3.7) --
    enum VTOLVideoCmd : quint8 {
        VideoCmdStartStream   = 0,
        VideoCmdStopStream    = 1,
        VideoCmdSetResolution = 2,
        VideoCmdSetFramerate  = 3,
        VideoCmdSetBitrate    = 4,
        VideoCmdSnapshot      = 5,
        VideoCmdReconfigure   = 6,
        VideoCmdQuery         = 7,
    };
    Q_ENUM_NS(VTOLVideoCmd)

    // -- VTOL Emergency Reason (protocol Section 3.8) --
    // 80009 EMERGENCY_LANDING_CMD 的 `reason` 字段。QML 侧只应引用本枚举，
    // 不要另写 JSON/JS 字面量（C 侧同名宏见 VTOLSafetyMessages.h:VTOL_EMERGENCY_REASON_*）。
    enum VTOL_EMERGENCY_REASON : quint8 {
        EmergencyReasonUnknown    = 0,
        EmergencyReasonOperator   = 1,   ///< 监控员在地面站确认迫降（当前唯一来源）
        EmergencyReasonAutopilot  = 2,   ///< 飞控自主触发（保留）
        EmergencyReasonLinkLoss   = 3,   ///< 链路丢失触发（保留）
    };
    Q_ENUM_NS(VTOL_EMERGENCY_REASON)
}
