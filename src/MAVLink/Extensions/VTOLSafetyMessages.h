#pragma once

/// @file VTOLSafetyMessages.h
/// @brief Custom MAVLink messages (msg_id 80000-80003) for VTOL flight safety management.
///
/// These messages are defined in docs/mavlink_extension_protocol.md and are
/// transparent to PX4 (silently dropped). As task frames they are **encrypted**
/// (docs/10_deviceID与payload加密公共规范.md §2.2): QGC encrypts with deviceID=D +
/// odd counter, mavros Router transparently forwards, and mavlink_crypto_node
/// decrypts on the companion computer.
///
/// 字段按 MAVLink 规范「类型大小降序」排序（pymavlink 强制），与接收端
/// `mavlink_custom_receiver`（pymavlink 解析 vtol_safety.xml）的 wire 布局一致。
/// CRC_EXTRA 由 pymavlink `message_checksum` 算法计算（已对 HEARTBEAT=50 校验）。

#include <mavlink_types.h>
#include <mavlink_helpers.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Message ID Constants
// ============================================================================

#define MAVLINK_MSG_ID_WEATHER_FORECAST  80000
#define MAVLINK_MSG_ID_ALTERNATE_LANDING 80001
#define MAVLINK_MSG_ID_SENSOR_CTRL       80002
#define MAVLINK_MSG_ID_VIDEO_CTRL        80003

// ============================================================================
// 80000: WEATHER_FORECAST
// ============================================================================

MAVPACKED(
typedef struct __mavlink_weather_forecast_t {
    int32_t  latitude;          ///< WGS84 latitude (degE7, x 10^7)
    int32_t  longitude;         ///< WGS84 longitude (degE7, x 10^7)
    int32_t  altitude;          ///< MSL altitude (mm)
    uint32_t valid_from;        ///< Forecast valid start (UTC seconds)
    uint32_t valid_to;          ///< Forecast valid end (UTC seconds)
    uint16_t wind_speed;        ///< Wind speed (cm/s)
    uint16_t wind_direction;    ///< Wind direction (cdeg, 0 = north)
    int16_t  temperature;       ///< Temperature (cdegC, x 100)
    uint16_t rainfall;          ///< Rainfall intensity (mm/h x 10)
    uint16_t visibility;        ///< Visibility (m, 0 = unlimited)
    uint8_t  weather_type;      ///< Weather type (VTOL_WEATHER_TYPE enum)
    uint8_t  severity;          ///< Severity level (VTOL_WEATHER_SEVERITY enum)
    uint8_t  confidence;        ///< Confidence percentage (0-100)
    char     description[21];   ///< Text description (not null-terminated)
}) mavlink_weather_forecast_t;

#define MAVLINK_MSG_ID_WEATHER_FORECAST_LEN     54U
#define MAVLINK_MSG_ID_WEATHER_FORECAST_MIN_LEN  54U
#define MAVLINK_MSG_ID_80000_LEN                 54U
#define MAVLINK_MSG_ID_80000_MIN_LEN             54U

#define MAVLINK_MSG_ID_WEATHER_FORECAST_CRC 152
#define MAVLINK_MSG_ID_80000_CRC            152

#define MAVLINK_MSG_WEATHER_FORECAST_FIELD_DESCRIPTION_LEN 21

#if MAVLINK_COMMAND_24BIT
#define MAVLINK_MESSAGE_INFO_WEATHER_FORECAST { \
    80000, \
    "WEATHER_FORECAST", \
    14, \
    {  { "latitude", NULL, MAVLINK_TYPE_INT32_T, 0, 0, offsetof(mavlink_weather_forecast_t, latitude) }, \
       { "longitude", NULL, MAVLINK_TYPE_INT32_T, 0, 4, offsetof(mavlink_weather_forecast_t, longitude) }, \
       { "altitude", NULL, MAVLINK_TYPE_INT32_T, 0, 8, offsetof(mavlink_weather_forecast_t, altitude) }, \
       { "valid_from", NULL, MAVLINK_TYPE_UINT32_T, 0, 12, offsetof(mavlink_weather_forecast_t, valid_from) }, \
       { "valid_to", NULL, MAVLINK_TYPE_UINT32_T, 0, 16, offsetof(mavlink_weather_forecast_t, valid_to) }, \
       { "wind_speed", NULL, MAVLINK_TYPE_UINT16_T, 0, 20, offsetof(mavlink_weather_forecast_t, wind_speed) }, \
       { "wind_direction", NULL, MAVLINK_TYPE_UINT16_T, 0, 22, offsetof(mavlink_weather_forecast_t, wind_direction) }, \
       { "temperature", NULL, MAVLINK_TYPE_INT16_T, 0, 24, offsetof(mavlink_weather_forecast_t, temperature) }, \
       { "rainfall", NULL, MAVLINK_TYPE_UINT16_T, 0, 26, offsetof(mavlink_weather_forecast_t, rainfall) }, \
       { "visibility", NULL, MAVLINK_TYPE_UINT16_T, 0, 28, offsetof(mavlink_weather_forecast_t, visibility) }, \
       { "weather_type", NULL, MAVLINK_TYPE_UINT8_T, 0, 30, offsetof(mavlink_weather_forecast_t, weather_type) }, \
       { "severity", NULL, MAVLINK_TYPE_UINT8_T, 0, 31, offsetof(mavlink_weather_forecast_t, severity) }, \
       { "confidence", NULL, MAVLINK_TYPE_UINT8_T, 0, 32, offsetof(mavlink_weather_forecast_t, confidence) }, \
       { "description", NULL, MAVLINK_TYPE_CHAR, 21, 33, offsetof(mavlink_weather_forecast_t, description) }, \
    } \
}
#else
#define MAVLINK_MESSAGE_INFO_WEATHER_FORECAST { \
    "WEATHER_FORECAST", \
    14, \
    {  { "latitude", NULL, MAVLINK_TYPE_INT32_T, 0, 0, offsetof(mavlink_weather_forecast_t, latitude) }, \
       { "longitude", NULL, MAVLINK_TYPE_INT32_T, 0, 4, offsetof(mavlink_weather_forecast_t, longitude) }, \
       { "altitude", NULL, MAVLINK_TYPE_INT32_T, 0, 8, offsetof(mavlink_weather_forecast_t, altitude) }, \
       { "valid_from", NULL, MAVLINK_TYPE_UINT32_T, 0, 12, offsetof(mavlink_weather_forecast_t, valid_from) }, \
       { "valid_to", NULL, MAVLINK_TYPE_UINT32_T, 0, 16, offsetof(mavlink_weather_forecast_t, valid_to) }, \
       { "wind_speed", NULL, MAVLINK_TYPE_UINT16_T, 0, 20, offsetof(mavlink_weather_forecast_t, wind_speed) }, \
       { "wind_direction", NULL, MAVLINK_TYPE_UINT16_T, 0, 22, offsetof(mavlink_weather_forecast_t, wind_direction) }, \
       { "temperature", NULL, MAVLINK_TYPE_INT16_T, 0, 24, offsetof(mavlink_weather_forecast_t, temperature) }, \
       { "rainfall", NULL, MAVLINK_TYPE_UINT16_T, 0, 26, offsetof(mavlink_weather_forecast_t, rainfall) }, \
       { "visibility", NULL, MAVLINK_TYPE_UINT16_T, 0, 28, offsetof(mavlink_weather_forecast_t, visibility) }, \
       { "weather_type", NULL, MAVLINK_TYPE_UINT8_T, 0, 30, offsetof(mavlink_weather_forecast_t, weather_type) }, \
       { "severity", NULL, MAVLINK_TYPE_UINT8_T, 0, 31, offsetof(mavlink_weather_forecast_t, severity) }, \
       { "confidence", NULL, MAVLINK_TYPE_UINT8_T, 0, 32, offsetof(mavlink_weather_forecast_t, confidence) }, \
       { "description", NULL, MAVLINK_TYPE_CHAR, 21, 33, offsetof(mavlink_weather_forecast_t, description) }, \
    } \
}
#endif

static inline uint16_t mavlink_msg_weather_forecast_pack(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    int32_t latitude, int32_t longitude, int32_t altitude,
    uint32_t valid_from, uint32_t valid_to,
    uint8_t weather_type, uint8_t severity, uint8_t confidence,
    uint16_t wind_speed, uint16_t wind_direction,
    int16_t temperature, uint16_t rainfall, uint16_t visibility,
    const char *description)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    char buf[MAVLINK_MSG_ID_WEATHER_FORECAST_LEN];
    _mav_put_int32_t(buf, 0, latitude);
    _mav_put_int32_t(buf, 4, longitude);
    _mav_put_int32_t(buf, 8, altitude);
    _mav_put_uint32_t(buf, 12, valid_from);
    _mav_put_uint32_t(buf, 16, valid_to);
    _mav_put_uint16_t(buf, 20, wind_speed);
    _mav_put_uint16_t(buf, 22, wind_direction);
    _mav_put_int16_t(buf, 24, temperature);
    _mav_put_uint16_t(buf, 26, rainfall);
    _mav_put_uint16_t(buf, 28, visibility);
    _mav_put_uint8_t(buf, 30, weather_type);
    _mav_put_uint8_t(buf, 31, severity);
    _mav_put_uint8_t(buf, 32, confidence);
    _mav_put_char_array(buf, 33, description, 21);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), buf, MAVLINK_MSG_ID_WEATHER_FORECAST_LEN);
#else
    mavlink_weather_forecast_t packet;
    memset(&packet, 0, sizeof(packet));
    packet.latitude = latitude;
    packet.longitude = longitude;
    packet.altitude = altitude;
    packet.valid_from = valid_from;
    packet.valid_to = valid_to;
    packet.weather_type = weather_type;
    packet.severity = severity;
    packet.confidence = confidence;
    packet.wind_speed = wind_speed;
    packet.wind_direction = wind_direction;
    packet.temperature = temperature;
    packet.rainfall = rainfall;
    packet.visibility = visibility;
    mav_array_memcpy(packet.description, description, sizeof(char) * 21);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), &packet, MAVLINK_MSG_ID_WEATHER_FORECAST_LEN);
#endif

    msg->msgid = MAVLINK_MSG_ID_WEATHER_FORECAST;
    return mavlink_finalize_message(msg, system_id, component_id,
                                    MAVLINK_MSG_ID_WEATHER_FORECAST_MIN_LEN,
                                    MAVLINK_MSG_ID_WEATHER_FORECAST_LEN,
                                    MAVLINK_MSG_ID_WEATHER_FORECAST_CRC);
}

static inline uint16_t mavlink_msg_weather_forecast_encode(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    const mavlink_weather_forecast_t* weather_forecast)
{
    return mavlink_msg_weather_forecast_pack(system_id, component_id, msg,
        weather_forecast->latitude, weather_forecast->longitude,
        weather_forecast->altitude, weather_forecast->valid_from,
        weather_forecast->valid_to, weather_forecast->weather_type,
        weather_forecast->severity, weather_forecast->confidence,
        weather_forecast->wind_speed, weather_forecast->wind_direction,
        weather_forecast->temperature, weather_forecast->rainfall,
        weather_forecast->visibility, weather_forecast->description);
}


static inline void mavlink_msg_weather_forecast_decode(
    const mavlink_message_t* msg, mavlink_weather_forecast_t* weather_forecast)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    weather_forecast->latitude = mavlink_msg_weather_forecast_get_latitude(msg);
    weather_forecast->longitude = mavlink_msg_weather_forecast_get_longitude(msg);
    weather_forecast->altitude = mavlink_msg_weather_forecast_get_altitude(msg);
    weather_forecast->valid_from = mavlink_msg_weather_forecast_get_valid_from(msg);
    weather_forecast->valid_to = mavlink_msg_weather_forecast_get_valid_to(msg);
    weather_forecast->weather_type = mavlink_msg_weather_forecast_get_weather_type(msg);
    weather_forecast->severity = mavlink_msg_weather_forecast_get_severity(msg);
    weather_forecast->confidence = mavlink_msg_weather_forecast_get_confidence(msg);
    weather_forecast->wind_speed = mavlink_msg_weather_forecast_get_wind_speed(msg);
    weather_forecast->wind_direction = mavlink_msg_weather_forecast_get_wind_direction(msg);
    weather_forecast->temperature = mavlink_msg_weather_forecast_get_temperature(msg);
    weather_forecast->rainfall = mavlink_msg_weather_forecast_get_rainfall(msg);
    weather_forecast->visibility = mavlink_msg_weather_forecast_get_visibility(msg);
    mavlink_msg_weather_forecast_get_description(msg, weather_forecast->description);
#else
    memcpy(weather_forecast, _MAV_PAYLOAD(msg), MAVLINK_MSG_ID_WEATHER_FORECAST_LEN);
#endif
}

/// @brief Get field latitude from weather_forecast message
static inline int32_t mavlink_msg_weather_forecast_get_latitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 0); }

/// @brief Get field longitude from weather_forecast message
static inline int32_t mavlink_msg_weather_forecast_get_longitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 4); }

/// @brief Get field altitude from weather_forecast message
static inline int32_t mavlink_msg_weather_forecast_get_altitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 8); }

/// @brief Get field valid_from from weather_forecast message
static inline uint32_t mavlink_msg_weather_forecast_get_valid_from(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint32_t(msg, 12); }

/// @brief Get field valid_to from weather_forecast message
static inline uint32_t mavlink_msg_weather_forecast_get_valid_to(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint32_t(msg, 16); }

/// @brief Get field wind_speed from weather_forecast message
static inline uint16_t mavlink_msg_weather_forecast_get_wind_speed(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 20); }

/// @brief Get field wind_direction from weather_forecast message
static inline uint16_t mavlink_msg_weather_forecast_get_wind_direction(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 22); }

/// @brief Get field temperature from weather_forecast message
static inline int16_t mavlink_msg_weather_forecast_get_temperature(const mavlink_message_t* msg)
    { return _MAV_RETURN_int16_t(msg, 24); }

/// @brief Get field rainfall from weather_forecast message
static inline uint16_t mavlink_msg_weather_forecast_get_rainfall(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 26); }

/// @brief Get field visibility from weather_forecast message
static inline uint16_t mavlink_msg_weather_forecast_get_visibility(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 28); }

/// @brief Get field weather_type from weather_forecast message
static inline uint8_t mavlink_msg_weather_forecast_get_weather_type(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 30); }

/// @brief Get field severity from weather_forecast message
static inline uint8_t mavlink_msg_weather_forecast_get_severity(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 31); }

/// @brief Get field confidence from weather_forecast message
static inline uint8_t mavlink_msg_weather_forecast_get_confidence(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 32); }

/// @brief Get field description from weather_forecast message
static inline uint16_t mavlink_msg_weather_forecast_get_description(const mavlink_message_t* msg, char *description)
    { return _MAV_RETURN_char_array(msg, description, 21, 33); }

// ============================================================================
// 80001: ALTERNATE_LANDING
// ============================================================================

MAVPACKED(
typedef struct __mavlink_alternate_landing_t {
    int32_t  latitude;                ///< WGS84 latitude (degE7, x 10^7)
    int32_t  longitude;               ///< WGS84 longitude (degE7, x 10^7)
    int32_t  altitude;                ///< MSL altitude (mm)
    uint32_t distance_from_current;   ///< Straight-line distance from current position (m)
    uint16_t runway_length;           ///< Runway length (m, 0 if N/A)
    uint16_t runway_heading;          ///< Runway direction (cdeg, 0 if N/A)
    char     site_id[16];             ///< Unique site identifier (not null-terminated)
    uint8_t  site_type;               ///< Landing site type (VTOL_ALT_TYPE enum)
    uint8_t  priority;                ///< Priority (1 = highest)
    uint8_t  surface_condition;       ///< Surface condition (0=unknown, 1=dry, 2=wet, 3=snow, 4=ice)
    char     description[31];         ///< Text description (not null-terminated)
}) mavlink_alternate_landing_t;

#define MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN     70U
#define MAVLINK_MSG_ID_ALTERNATE_LANDING_MIN_LEN  70U
#define MAVLINK_MSG_ID_80001_LEN                  70U
#define MAVLINK_MSG_ID_80001_MIN_LEN              70U

#define MAVLINK_MSG_ID_ALTERNATE_LANDING_CRC 84
#define MAVLINK_MSG_ID_80001_CRC            84

#define MAVLINK_MSG_ALTERNATE_LANDING_FIELD_SITE_ID_LEN 16
#define MAVLINK_MSG_ALTERNATE_LANDING_FIELD_DESCRIPTION_LEN 31

#if MAVLINK_COMMAND_24BIT
#define MAVLINK_MESSAGE_INFO_ALTERNATE_LANDING { \
    80001, \
    "ALTERNATE_LANDING", \
    11, \
    {  { "latitude", NULL, MAVLINK_TYPE_INT32_T, 0, 0, offsetof(mavlink_alternate_landing_t, latitude) }, \
       { "longitude", NULL, MAVLINK_TYPE_INT32_T, 0, 4, offsetof(mavlink_alternate_landing_t, longitude) }, \
       { "altitude", NULL, MAVLINK_TYPE_INT32_T, 0, 8, offsetof(mavlink_alternate_landing_t, altitude) }, \
       { "distance_from_current", NULL, MAVLINK_TYPE_UINT32_T, 0, 12, offsetof(mavlink_alternate_landing_t, distance_from_current) }, \
       { "runway_length", NULL, MAVLINK_TYPE_UINT16_T, 0, 16, offsetof(mavlink_alternate_landing_t, runway_length) }, \
       { "runway_heading", NULL, MAVLINK_TYPE_UINT16_T, 0, 18, offsetof(mavlink_alternate_landing_t, runway_heading) }, \
       { "site_id", NULL, MAVLINK_TYPE_CHAR, 16, 20, offsetof(mavlink_alternate_landing_t, site_id) }, \
       { "site_type", NULL, MAVLINK_TYPE_UINT8_T, 0, 36, offsetof(mavlink_alternate_landing_t, site_type) }, \
       { "priority", NULL, MAVLINK_TYPE_UINT8_T, 0, 37, offsetof(mavlink_alternate_landing_t, priority) }, \
       { "surface_condition", NULL, MAVLINK_TYPE_UINT8_T, 0, 38, offsetof(mavlink_alternate_landing_t, surface_condition) }, \
       { "description", NULL, MAVLINK_TYPE_CHAR, 31, 39, offsetof(mavlink_alternate_landing_t, description) }, \
    } \
}
#else
#define MAVLINK_MESSAGE_INFO_ALTERNATE_LANDING { \
    "ALTERNATE_LANDING", \
    11, \
    {  { "latitude", NULL, MAVLINK_TYPE_INT32_T, 0, 0, offsetof(mavlink_alternate_landing_t, latitude) }, \
       { "longitude", NULL, MAVLINK_TYPE_INT32_T, 0, 4, offsetof(mavlink_alternate_landing_t, longitude) }, \
       { "altitude", NULL, MAVLINK_TYPE_INT32_T, 0, 8, offsetof(mavlink_alternate_landing_t, altitude) }, \
       { "distance_from_current", NULL, MAVLINK_TYPE_UINT32_T, 0, 12, offsetof(mavlink_alternate_landing_t, distance_from_current) }, \
       { "runway_length", NULL, MAVLINK_TYPE_UINT16_T, 0, 16, offsetof(mavlink_alternate_landing_t, runway_length) }, \
       { "runway_heading", NULL, MAVLINK_TYPE_UINT16_T, 0, 18, offsetof(mavlink_alternate_landing_t, runway_heading) }, \
       { "site_id", NULL, MAVLINK_TYPE_CHAR, 16, 20, offsetof(mavlink_alternate_landing_t, site_id) }, \
       { "site_type", NULL, MAVLINK_TYPE_UINT8_T, 0, 36, offsetof(mavlink_alternate_landing_t, site_type) }, \
       { "priority", NULL, MAVLINK_TYPE_UINT8_T, 0, 37, offsetof(mavlink_alternate_landing_t, priority) }, \
       { "surface_condition", NULL, MAVLINK_TYPE_UINT8_T, 0, 38, offsetof(mavlink_alternate_landing_t, surface_condition) }, \
       { "description", NULL, MAVLINK_TYPE_CHAR, 31, 39, offsetof(mavlink_alternate_landing_t, description) }, \
    } \
}
#endif

static inline uint16_t mavlink_msg_alternate_landing_pack(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    const char *site_id, int32_t latitude, int32_t longitude, int32_t altitude,
    uint8_t site_type, uint8_t priority,
    uint16_t runway_length, uint16_t runway_heading,
    uint8_t surface_condition, uint32_t distance_from_current,
    const char *description)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    char buf[MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN];
    _mav_put_int32_t(buf, 0, latitude);
    _mav_put_int32_t(buf, 4, longitude);
    _mav_put_int32_t(buf, 8, altitude);
    _mav_put_uint32_t(buf, 12, distance_from_current);
    _mav_put_uint16_t(buf, 16, runway_length);
    _mav_put_uint16_t(buf, 18, runway_heading);
    _mav_put_char_array(buf, 20, site_id, 16);
    _mav_put_uint8_t(buf, 36, site_type);
    _mav_put_uint8_t(buf, 37, priority);
    _mav_put_uint8_t(buf, 38, surface_condition);
    _mav_put_char_array(buf, 39, description, 31);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), buf, MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN);
#else
    mavlink_alternate_landing_t packet;
    memset(&packet, 0, sizeof(packet));
    mav_array_memcpy(packet.site_id, site_id, sizeof(char) * 16);
    packet.latitude = latitude;
    packet.longitude = longitude;
    packet.altitude = altitude;
    packet.site_type = site_type;
    packet.priority = priority;
    packet.runway_length = runway_length;
    packet.runway_heading = runway_heading;
    packet.surface_condition = surface_condition;
    packet.distance_from_current = distance_from_current;
    mav_array_memcpy(packet.description, description, sizeof(char) * 31);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), &packet, MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN);
#endif

    msg->msgid = MAVLINK_MSG_ID_ALTERNATE_LANDING;
    return mavlink_finalize_message(msg, system_id, component_id,
                                    MAVLINK_MSG_ID_ALTERNATE_LANDING_MIN_LEN,
                                    MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN,
                                    MAVLINK_MSG_ID_ALTERNATE_LANDING_CRC);
}

static inline uint16_t mavlink_msg_alternate_landing_encode(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    const mavlink_alternate_landing_t* alternate_landing)
{
    return mavlink_msg_alternate_landing_pack(system_id, component_id, msg,
        alternate_landing->site_id, alternate_landing->latitude,
        alternate_landing->longitude, alternate_landing->altitude,
        alternate_landing->site_type, alternate_landing->priority,
        alternate_landing->runway_length, alternate_landing->runway_heading,
        alternate_landing->surface_condition, alternate_landing->distance_from_current,
        alternate_landing->description);
}


static inline void mavlink_msg_alternate_landing_decode(
    const mavlink_message_t* msg, mavlink_alternate_landing_t* alternate_landing)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    mavlink_msg_alternate_landing_get_site_id(msg, alternate_landing->site_id);
    alternate_landing->latitude = mavlink_msg_alternate_landing_get_latitude(msg);
    alternate_landing->longitude = mavlink_msg_alternate_landing_get_longitude(msg);
    alternate_landing->altitude = mavlink_msg_alternate_landing_get_altitude(msg);
    alternate_landing->site_type = mavlink_msg_alternate_landing_get_site_type(msg);
    alternate_landing->priority = mavlink_msg_alternate_landing_get_priority(msg);
    alternate_landing->runway_length = mavlink_msg_alternate_landing_get_runway_length(msg);
    alternate_landing->runway_heading = mavlink_msg_alternate_landing_get_runway_heading(msg);
    alternate_landing->surface_condition = mavlink_msg_alternate_landing_get_surface_condition(msg);
    alternate_landing->distance_from_current = mavlink_msg_alternate_landing_get_distance_from_current(msg);
    mavlink_msg_alternate_landing_get_description(msg, alternate_landing->description);
#else
    memcpy(alternate_landing, _MAV_PAYLOAD(msg), MAVLINK_MSG_ID_ALTERNATE_LANDING_LEN);
#endif
}

static inline uint16_t mavlink_msg_alternate_landing_get_site_id(const mavlink_message_t* msg, char *site_id)
    { return _MAV_RETURN_char_array(msg, site_id, 16, 20); }

static inline int32_t mavlink_msg_alternate_landing_get_latitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 0); }

static inline int32_t mavlink_msg_alternate_landing_get_longitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 4); }

static inline int32_t mavlink_msg_alternate_landing_get_altitude(const mavlink_message_t* msg)
    { return _MAV_RETURN_int32_t(msg, 8); }

static inline uint8_t mavlink_msg_alternate_landing_get_site_type(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 36); }

static inline uint8_t mavlink_msg_alternate_landing_get_priority(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 37); }

static inline uint16_t mavlink_msg_alternate_landing_get_runway_length(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 16); }

static inline uint16_t mavlink_msg_alternate_landing_get_runway_heading(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 18); }

static inline uint8_t mavlink_msg_alternate_landing_get_surface_condition(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 38); }

static inline uint32_t mavlink_msg_alternate_landing_get_distance_from_current(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint32_t(msg, 12); }

static inline uint16_t mavlink_msg_alternate_landing_get_description(const mavlink_message_t* msg, char *description)
    { return _MAV_RETURN_char_array(msg, description, 31, 39); }

// ============================================================================
// 80002: SENSOR_CTRL
// ============================================================================

MAVPACKED(
typedef struct __mavlink_sensor_ctrl_t {
    uint8_t target_system;      ///< Target system ID
    uint8_t target_component;   ///< Target component ID
    uint8_t sensor_id;          ///< Sensor ID (VTOL_SENSOR_ID enum)
    uint8_t command;            ///< Command (VTOL_SENSOR_CMD enum: 0=DISABLE, 1=ENABLE)
    uint8_t reserved[4];        ///< Reserved (set to 0)
}) mavlink_sensor_ctrl_t;

#define MAVLINK_MSG_ID_SENSOR_CTRL_LEN     8U
#define MAVLINK_MSG_ID_SENSOR_CTRL_MIN_LEN  8U
#define MAVLINK_MSG_ID_80002_LEN            8U
#define MAVLINK_MSG_ID_80002_MIN_LEN        8U

#define MAVLINK_MSG_ID_SENSOR_CTRL_CRC 78
#define MAVLINK_MSG_ID_80002_CRC       78

#define MAVLINK_MSG_SENSOR_CTRL_FIELD_RESERVED_LEN 4

#if MAVLINK_COMMAND_24BIT
#define MAVLINK_MESSAGE_INFO_SENSOR_CTRL { \
    80002, \
    "SENSOR_CTRL", \
    5, \
    {  { "target_system", NULL, MAVLINK_TYPE_UINT8_T, 0, 0, offsetof(mavlink_sensor_ctrl_t, target_system) }, \
       { "target_component", NULL, MAVLINK_TYPE_UINT8_T, 0, 1, offsetof(mavlink_sensor_ctrl_t, target_component) }, \
       { "sensor_id", NULL, MAVLINK_TYPE_UINT8_T, 0, 2, offsetof(mavlink_sensor_ctrl_t, sensor_id) }, \
       { "command", NULL, MAVLINK_TYPE_UINT8_T, 0, 3, offsetof(mavlink_sensor_ctrl_t, command) }, \
       { "reserved", NULL, MAVLINK_TYPE_UINT8_T, 4, 4, offsetof(mavlink_sensor_ctrl_t, reserved) }, \
    } \
}
#else
#define MAVLINK_MESSAGE_INFO_SENSOR_CTRL { \
    "SENSOR_CTRL", \
    5, \
    {  { "target_system", NULL, MAVLINK_TYPE_UINT8_T, 0, 0, offsetof(mavlink_sensor_ctrl_t, target_system) }, \
       { "target_component", NULL, MAVLINK_TYPE_UINT8_T, 0, 1, offsetof(mavlink_sensor_ctrl_t, target_component) }, \
       { "sensor_id", NULL, MAVLINK_TYPE_UINT8_T, 0, 2, offsetof(mavlink_sensor_ctrl_t, sensor_id) }, \
       { "command", NULL, MAVLINK_TYPE_UINT8_T, 0, 3, offsetof(mavlink_sensor_ctrl_t, command) }, \
       { "reserved", NULL, MAVLINK_TYPE_UINT8_T, 4, 4, offsetof(mavlink_sensor_ctrl_t, reserved) }, \
    } \
}
#endif

static inline uint16_t mavlink_msg_sensor_ctrl_pack(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    uint8_t target_system, uint8_t target_component,
    uint8_t sensor_id, uint8_t command)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    char buf[MAVLINK_MSG_ID_SENSOR_CTRL_LEN];
    _mav_put_uint8_t(buf, 0, target_system);
    _mav_put_uint8_t(buf, 1, target_component);
    _mav_put_uint8_t(buf, 2, sensor_id);
    _mav_put_uint8_t(buf, 3, command);
    memset(&buf[4], 0, 4);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), buf, MAVLINK_MSG_ID_SENSOR_CTRL_LEN);
#else
    mavlink_sensor_ctrl_t packet;
    memset(&packet, 0, sizeof(packet));
    packet.target_system = target_system;
    packet.target_component = target_component;
    packet.sensor_id = sensor_id;
    packet.command = command;
    memset(packet.reserved, 0, sizeof(packet.reserved));
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), &packet, MAVLINK_MSG_ID_SENSOR_CTRL_LEN);
#endif

    msg->msgid = MAVLINK_MSG_ID_SENSOR_CTRL;
    return mavlink_finalize_message(msg, system_id, component_id,
                                    MAVLINK_MSG_ID_SENSOR_CTRL_MIN_LEN,
                                    MAVLINK_MSG_ID_SENSOR_CTRL_LEN,
                                    MAVLINK_MSG_ID_SENSOR_CTRL_CRC);
}

static inline uint16_t mavlink_msg_sensor_ctrl_encode(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    const mavlink_sensor_ctrl_t* sensor_ctrl)
{
    return mavlink_msg_sensor_ctrl_pack(system_id, component_id, msg,
        sensor_ctrl->target_system, sensor_ctrl->target_component,
        sensor_ctrl->sensor_id, sensor_ctrl->command);
}


static inline void mavlink_msg_sensor_ctrl_decode(
    const mavlink_message_t* msg, mavlink_sensor_ctrl_t* sensor_ctrl)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    sensor_ctrl->target_system = mavlink_msg_sensor_ctrl_get_target_system(msg);
    sensor_ctrl->target_component = mavlink_msg_sensor_ctrl_get_target_component(msg);
    sensor_ctrl->sensor_id = mavlink_msg_sensor_ctrl_get_sensor_id(msg);
    sensor_ctrl->command = mavlink_msg_sensor_ctrl_get_command(msg);
#else
    memcpy(sensor_ctrl, _MAV_PAYLOAD(msg), MAVLINK_MSG_ID_SENSOR_CTRL_LEN);
#endif
}

static inline uint8_t mavlink_msg_sensor_ctrl_get_target_system(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 0); }

static inline uint8_t mavlink_msg_sensor_ctrl_get_target_component(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 1); }

static inline uint8_t mavlink_msg_sensor_ctrl_get_sensor_id(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 2); }

static inline uint8_t mavlink_msg_sensor_ctrl_get_command(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 3); }

// ============================================================================
// 80003: VIDEO_CTRL
// ============================================================================

MAVPACKED(
typedef struct __mavlink_video_ctrl_t {
    uint16_t resolution_w;      ///< Horizontal pixels (0 = no change)
    uint16_t resolution_h;      ///< Vertical pixels (0 = no change)
    uint16_t bitrate_kbps;      ///< Bitrate in kbps (0 = no change)
    uint8_t  target_system;     ///< Target system ID
    uint8_t  target_component;  ///< Target component ID
    uint8_t  camera_id;         ///< Camera ID (VTOL_CAMERA_ID enum)
    uint8_t  command;           ///< Video command (VTOL_VIDEO_CMD enum)
    uint8_t  framerate;         ///< Frame rate in Hz (0 = no change)
    char     codec[8];          ///< Codec format ("h264", "h265", "mjpeg"; empty = no change)
    uint8_t  reserved[6];       ///< Reserved (set to 0)
}) mavlink_video_ctrl_t;

#define MAVLINK_MSG_ID_VIDEO_CTRL_LEN     25U
#define MAVLINK_MSG_ID_VIDEO_CTRL_MIN_LEN  25U
#define MAVLINK_MSG_ID_80003_LEN           25U
#define MAVLINK_MSG_ID_80003_MIN_LEN       25U

#define MAVLINK_MSG_ID_VIDEO_CTRL_CRC 22
#define MAVLINK_MSG_ID_80003_CRC      22

#define MAVLINK_MSG_VIDEO_CTRL_FIELD_CODEC_LEN 8
#define MAVLINK_MSG_VIDEO_CTRL_FIELD_RESERVED_LEN 6

#if MAVLINK_COMMAND_24BIT
#define MAVLINK_MESSAGE_INFO_VIDEO_CTRL { \
    80003, \
    "VIDEO_CTRL", \
    10, \
    {  { "resolution_w", NULL, MAVLINK_TYPE_UINT16_T, 0, 0, offsetof(mavlink_video_ctrl_t, resolution_w) }, \
       { "resolution_h", NULL, MAVLINK_TYPE_UINT16_T, 0, 2, offsetof(mavlink_video_ctrl_t, resolution_h) }, \
       { "bitrate_kbps", NULL, MAVLINK_TYPE_UINT16_T, 0, 4, offsetof(mavlink_video_ctrl_t, bitrate_kbps) }, \
       { "target_system", NULL, MAVLINK_TYPE_UINT8_T, 0, 6, offsetof(mavlink_video_ctrl_t, target_system) }, \
       { "target_component", NULL, MAVLINK_TYPE_UINT8_T, 0, 7, offsetof(mavlink_video_ctrl_t, target_component) }, \
       { "camera_id", NULL, MAVLINK_TYPE_UINT8_T, 0, 8, offsetof(mavlink_video_ctrl_t, camera_id) }, \
       { "command", NULL, MAVLINK_TYPE_UINT8_T, 0, 9, offsetof(mavlink_video_ctrl_t, command) }, \
       { "framerate", NULL, MAVLINK_TYPE_UINT8_T, 0, 10, offsetof(mavlink_video_ctrl_t, framerate) }, \
       { "codec", NULL, MAVLINK_TYPE_CHAR, 8, 11, offsetof(mavlink_video_ctrl_t, codec) }, \
       { "reserved", NULL, MAVLINK_TYPE_UINT8_T, 6, 19, offsetof(mavlink_video_ctrl_t, reserved) }, \
    } \
}
#else
#define MAVLINK_MESSAGE_INFO_VIDEO_CTRL { \
    "VIDEO_CTRL", \
    10, \
    {  { "resolution_w", NULL, MAVLINK_TYPE_UINT16_T, 0, 0, offsetof(mavlink_video_ctrl_t, resolution_w) }, \
       { "resolution_h", NULL, MAVLINK_TYPE_UINT16_T, 0, 2, offsetof(mavlink_video_ctrl_t, resolution_h) }, \
       { "bitrate_kbps", NULL, MAVLINK_TYPE_UINT16_T, 0, 4, offsetof(mavlink_video_ctrl_t, bitrate_kbps) }, \
       { "target_system", NULL, MAVLINK_TYPE_UINT8_T, 0, 6, offsetof(mavlink_video_ctrl_t, target_system) }, \
       { "target_component", NULL, MAVLINK_TYPE_UINT8_T, 0, 7, offsetof(mavlink_video_ctrl_t, target_component) }, \
       { "camera_id", NULL, MAVLINK_TYPE_UINT8_T, 0, 8, offsetof(mavlink_video_ctrl_t, camera_id) }, \
       { "command", NULL, MAVLINK_TYPE_UINT8_T, 0, 9, offsetof(mavlink_video_ctrl_t, command) }, \
       { "framerate", NULL, MAVLINK_TYPE_UINT8_T, 0, 10, offsetof(mavlink_video_ctrl_t, framerate) }, \
       { "codec", NULL, MAVLINK_TYPE_CHAR, 8, 11, offsetof(mavlink_video_ctrl_t, codec) }, \
       { "reserved", NULL, MAVLINK_TYPE_UINT8_T, 6, 19, offsetof(mavlink_video_ctrl_t, reserved) }, \
    } \
}
#endif

static inline uint16_t mavlink_msg_video_ctrl_pack(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    uint8_t target_system, uint8_t target_component,
    uint8_t camera_id, uint8_t command,
    uint16_t resolution_w, uint16_t resolution_h,
    uint8_t framerate, uint16_t bitrate_kbps, const char *codec)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    char buf[MAVLINK_MSG_ID_VIDEO_CTRL_LEN];
    _mav_put_uint16_t(buf, 0, resolution_w);
    _mav_put_uint16_t(buf, 2, resolution_h);
    _mav_put_uint16_t(buf, 4, bitrate_kbps);
    _mav_put_uint8_t(buf, 6, target_system);
    _mav_put_uint8_t(buf, 7, target_component);
    _mav_put_uint8_t(buf, 8, camera_id);
    _mav_put_uint8_t(buf, 9, command);
    _mav_put_uint8_t(buf, 10, framerate);
    _mav_put_char_array(buf, 11, codec, 8);
    memset(&buf[19], 0, 6);
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), buf, MAVLINK_MSG_ID_VIDEO_CTRL_LEN);
#else
    mavlink_video_ctrl_t packet;
    memset(&packet, 0, sizeof(packet));
    packet.target_system = target_system;
    packet.target_component = target_component;
    packet.camera_id = camera_id;
    packet.command = command;
    packet.resolution_w = resolution_w;
    packet.resolution_h = resolution_h;
    packet.framerate = framerate;
    packet.bitrate_kbps = bitrate_kbps;
    mav_array_memcpy(packet.codec, codec, sizeof(char) * 8);
    memset(packet.reserved, 0, sizeof(packet.reserved));
    memcpy(_MAV_PAYLOAD_NON_CONST(msg), &packet, MAVLINK_MSG_ID_VIDEO_CTRL_LEN);
#endif

    msg->msgid = MAVLINK_MSG_ID_VIDEO_CTRL;
    return mavlink_finalize_message(msg, system_id, component_id,
                                    MAVLINK_MSG_ID_VIDEO_CTRL_MIN_LEN,
                                    MAVLINK_MSG_ID_VIDEO_CTRL_LEN,
                                    MAVLINK_MSG_ID_VIDEO_CTRL_CRC);
}

static inline uint16_t mavlink_msg_video_ctrl_encode(
    uint8_t system_id, uint8_t component_id, mavlink_message_t* msg,
    const mavlink_video_ctrl_t* video_ctrl)
{
    return mavlink_msg_video_ctrl_pack(system_id, component_id, msg,
        video_ctrl->target_system, video_ctrl->target_component,
        video_ctrl->camera_id, video_ctrl->command,
        video_ctrl->resolution_w, video_ctrl->resolution_h,
        video_ctrl->framerate, video_ctrl->bitrate_kbps, video_ctrl->codec);
}


static inline void mavlink_msg_video_ctrl_decode(
    const mavlink_message_t* msg, mavlink_video_ctrl_t* video_ctrl)
{
#if MAVLINK_NEED_BYTE_SWAP || !MAVLINK_ALIGNED_FIELDS
    video_ctrl->target_system = mavlink_msg_video_ctrl_get_target_system(msg);
    video_ctrl->target_component = mavlink_msg_video_ctrl_get_target_component(msg);
    video_ctrl->camera_id = mavlink_msg_video_ctrl_get_camera_id(msg);
    video_ctrl->command = mavlink_msg_video_ctrl_get_command(msg);
    video_ctrl->resolution_w = mavlink_msg_video_ctrl_get_resolution_w(msg);
    video_ctrl->resolution_h = mavlink_msg_video_ctrl_get_resolution_h(msg);
    video_ctrl->framerate = mavlink_msg_video_ctrl_get_framerate(msg);
    video_ctrl->bitrate_kbps = mavlink_msg_video_ctrl_get_bitrate_kbps(msg);
    mavlink_msg_video_ctrl_get_codec(msg, video_ctrl->codec);
#else
    memcpy(video_ctrl, _MAV_PAYLOAD(msg), MAVLINK_MSG_ID_VIDEO_CTRL_LEN);
#endif
}

static inline uint8_t mavlink_msg_video_ctrl_get_target_system(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 6); }

static inline uint8_t mavlink_msg_video_ctrl_get_target_component(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 7); }

static inline uint8_t mavlink_msg_video_ctrl_get_camera_id(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 8); }

static inline uint8_t mavlink_msg_video_ctrl_get_command(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 9); }

static inline uint16_t mavlink_msg_video_ctrl_get_resolution_w(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 0); }

static inline uint16_t mavlink_msg_video_ctrl_get_resolution_h(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 2); }

static inline uint8_t mavlink_msg_video_ctrl_get_framerate(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint8_t(msg, 10); }

static inline uint16_t mavlink_msg_video_ctrl_get_bitrate_kbps(const mavlink_message_t* msg)
    { return _MAV_RETURN_uint16_t(msg, 4); }

static inline uint16_t mavlink_msg_video_ctrl_get_codec(const mavlink_message_t* msg, char *codec)
    { return _MAV_RETURN_char_array(msg, codec, 8, 11); }

// ============================================================================
// CRC_EXTRA 查询助手
// ============================================================================

/// @brief 返回 80000-80003 自定义消息的 CRC_EXTRA。
///
/// 这些消息独立于 mavlink 生成层，未注册进 `MAVLINK_MESSAGE_CRCS` 表，
/// 因此 `mavlink_get_crc_extra()` 对它们返回 0。加密链路（`encryptFrame`）
/// 需要正确的 crc_extra 计算加密帧 CRC，否则接收端 CRC 校验失败。
///
/// @param msgid     MAVLink 消息 ID
/// @param out_crc   输出 CRC_EXTRA（命中时写入）
/// @return true=命中 80000-80003；false=非 VTOL 消息（调用方回退 mavlink_get_crc_extra）
static inline bool mavlink_msg_vtol_crc_extra(uint32_t msgid, uint8_t* out_crc)
{
    switch (msgid) {
        case MAVLINK_MSG_ID_WEATHER_FORECAST:  *out_crc = MAVLINK_MSG_ID_WEATHER_FORECAST_CRC;  return true;
        case MAVLINK_MSG_ID_ALTERNATE_LANDING: *out_crc = MAVLINK_MSG_ID_ALTERNATE_LANDING_CRC; return true;
        case MAVLINK_MSG_ID_SENSOR_CTRL:       *out_crc = MAVLINK_MSG_ID_SENSOR_CTRL_CRC;       return true;
        case MAVLINK_MSG_ID_VIDEO_CTRL:        *out_crc = MAVLINK_MSG_ID_VIDEO_CTRL_CRC;        return true;
        default: return false;
    }
}

#ifdef __cplusplus
}
#endif
