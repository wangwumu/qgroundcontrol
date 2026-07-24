#!/usr/bin/env python3
"""Handle the final 140 remaining untranslated strings."""
from xml.etree import ElementTree as ET
import re

SRC_TS = 'translations/qgc_source_zh_CN.ts'
JSON_TS = 'translations/qgc_json_zh_CN.ts'

# Strings that should stay in English (acronyms, brands, technical constants)
KEEP_ENGLISH = {
    'GPS', 'RTK', 'LED', 'RGB', 'UDP', 'LiPo', 'CSV', 'OSM', 'WMS', 'NMEA',
    'SiK', 'APM', 'PX4', 'NTRIP', 'RTCM', 'GNSS', 'SBS', 'VTOL', 'EKF',
    'ArduPilot', 'ArduCopter', 'ArduPlane', 'Pixhawk', 'LibrePilot',
    'Mapbox', 'Google', 'Bing', 'Esri', 'VWorld', 'OpenAIP', 'OpenStreetMap',
    'GStreamer', 'SiK Radio', 'GStreamer,',
    '1Hz', '2Hz', '3Hz', '4Hz', '5Hz', '6Hz', '7Hz', '8Hz', '9Hz',
    '10Hz', '25Hz', '50Hz', '100Hz',
    '5760', '%', 'dBm', '–', '–.––', '.*',
    'ekf', 'ekf3', 'lipo', 'pwm', 'uavcan', 'dronecan',
    'amp', 'csv', 'apm', 'mavlink2', 'librepilot', 'nmea',
    'google', 'bing', 'mapbox', 'esri', 'vworld', 'openaip', 'wms',
    'osm', 'openstreetmap', 'gstreamer', 'faa', 'eu', 'gnss',
    'ntrip', 'rtcm', 'adsb', 'ads-b', 'sbs', 'rtsp', 'mpegts',
    'gpu', 'mp4', 'mkv', 'px4',
    'RPM 1', 'RPM 2', 'RPM 3', 'RPM 4',
}

PHRASES = {
    'AltitudeFactTextField': {'%1': '%1'},
    'AppLogging': {'.*': '.*'},
    'AudioOutput': {'%1': '%1'},
    'EscIndicatorPage': {'–': '–'},
    'InstrumentValueValue': {'–': '–'},
    'GPSIndicatorPage': {'–.––': '–.––'},
    'ProximityRadarValues': {'–.––': '–.––'},
    'Firmware Class': {'ArduPilot': 'ArduPilot'},
    'GPSIndicator': {'RTK': 'RTK'},
    'JoystickComponent': {'LED': 'LED'},
    'JoystickComponentSummary': {'%1%': '%1%', 'LED': 'LED'},
    'JoystickIndicator': {'%1%': '%1%', 'LED': 'LED', 'RGB': 'RGB'},
    'LogFileParser': {'GPS': 'GPS'},
    'MAVLink SYS_STATUS_SENSOR value': {'GPS': 'GPS'},
    'MainStatusIndicatorOfflinePage': {'Pixhawk': 'Pixhawk', 'UDP': 'UDP', 'RTK': 'RTK'},
    'MockLinkSettings': {
        'ArduPilot': 'ArduPilot', 'ArduCopter': 'ArduCopter', 'ArduPlane': 'ArduPlane'
    },
    'MotorComponent': {'%': '%'},
    'NmeaGpsSettings': {'NMEA GPS': 'NMEA GPS'},
    'TcpSettings': {'5760': '5760'},
    'TelemetryRSSIIndicator': {'dBm': 'dBm'},
    'TransformEditor': {'MGRS': 'MGRS'},
    'VideoSettings': {
        'UDP h.264 Video Stream': 'UDP H.264 视频流',
        'UDP h.265 Video Stream': 'UDP H.265 视频流',
        '3DR Solo (requires restart)': '3DR Solo（需要重启）',
    },
}

# Special translations (context -> source -> translation)
SPECIAL = {
    'APMDataFlashLogParser': {'GPS': 'GPS'},
    'AltitudeFactTextField': {'%1': '%1'},
}

TRANSLATIONS = {
    # Video source descriptions
    'Video.SettingsGroup.json | Source for video stream (UDP, TCP, RTSP, or connected USB camera).': '视频流来源（UDP、TCP、RTSP或连接的USB摄像头）。',
    'Video.SettingsGroup.json | Source for video. UDP, TCP, RTSP and UVC Cameras may be supported depending on Vehicle and ground station version.': '视频来源。UDP、TCP、RTSP和UVC摄像头的支持取决于飞行器和地面站版本。',
    'Video.SettingsGroup.json | UDP URL': 'UDP URL',
    'Video.SettingsGroup.json | udp,mpegts,video url,stream url': 'UDP, MPEG-TS, 视频URL, 流URL',
    'Video.SettingsGroup.json | RTSP url address and port to bind to for video stream. Example: rtsp://192.168.42.1:554/live': '视频流绑定的RTSP URL地址和端口。示例：rtsp://192.168.42.1:554/live',
    'Video.SettingsGroup.json | TCP URL': 'TCP URL',
    'Video.SettingsGroup.json | mp4,mov,mkv': 'MP4, MOV, MKV',
    'Video.SettingsGroup.json | Default,Force software decoder,Force hardware decoder,Force NVIDIA decoder,Force VA-API decoder,Force DirectX3D 11 decoder,Force VideoToolbox decoder,Force Intel decoder,Force Vulkan decoder': '默认, 强制软件解码, 强制硬件解码, 强制NVIDIA解码, 强制VA-API解码, 强制DirectX3D 11解码, 强制VideoToolbox解码, 强制Intel解码, 强制Vulkan解码',
    'Video.SettingsGroup.json | videoconvert,nvvidconv,imxvideoconvert,gstreamer,advanced': 'videoconvert, nvvidconv, imxvideoconvert, GStreamer, 高级',

    # Signing key
    'SigningKeyManager | Vehicle is armed. ArduPilot will refuse to disable signing while armed and PX4 will not accept the disable packet without a valid signature. The disable attempt will likely time out and leave the link in an inconsistent state.': '飞行器已解锁。ArduPilot在解锁状态拒绝禁用签名,PX4在无有效签名时不会接受禁用数据包。禁用尝试将超时,导致链路处于不一致状态。',
    'SigningKeyManager | Are you sure you want to delete \'%1\'?': '确定要删除\'%1\'吗？',

    # Motor assignment
    'MotorAssignment | <br />No motors are assigned yet.': '<br />尚未分配任何电机。',
    'MotorAssignment | <br />Motors are currently assigned to a different output.': '<br />电机当前已分配到另一个输出。',
    'MotorAssignment | This will automatically spin individual motors at 15% thrust.<br /><br />': '这将自动以15%油门逐个旋转电机。<br /><br />',

    # Calibration
    'RemoteControlCalibration | Before calibrating you should zero all your trims and subtrims. Click Ok to start Calibration.': '校准前请将所有微调和副微调归零。点击"确定"开始校准。',
    'RemoteControlCalibrationController | * Lower the Throttle stick all the way down as shown in diagram': '* 将油门杆完全拉下,如图所示',
    'RemoteControlCalibrationController | * Center all sticks as shown in diagram.': '* 将所有摇杆回中,如图所示。',
    'RemoteControlCalibrationController | * Move the %1 Extension stick to its low value position and hold it there...': '* 将%1扩展摇杆移至最低位置并保持住...',

    # Parameter editor
    'ParameterEditor | Select Reset to reset all parameters to their defaults.': '选择"重置"将所有参数重置为默认值。',

    # Plan view
    'PlanView | This Plan was created for a different firmware or vehicle type than the firmware/vehicle type of vehicle you are uploading to. This can lead to errors or incorrect behavior. It is recommended to recreate the Plan for the correct firmware/vehicle type.': '此航线规划使用的固件或飞行器类型与您上传的目标不同。这可能导致错误或不正确行为。建议为正确的固件/飞行器类型重新创建航线规划。',

    # Sensors
    'SensorsSetup | Adjust orientations as needed.': '根据需要调整朝向。',

    # NTRIP
    'NTRIPHttpTransport | HTTP %1': 'HTTP %1',
    'NTRIPHttpTransport | HTTP %1: %2': 'HTTP %1: %2',
    'NtripConnectionStatus | GGA: %1': 'GGA：%1',

    # OfflineMap
    'OfflineMapEditor | This will delete all tiles INCLUDING the tile sets you have created yourself.': '这将删除所有瓦片,包括您自己创建的瓦片集。',
    'OfflineMapEditor | Delete %1 and all its tiles.': '删除%1及其所有瓦片。',

    # Log viewer
    'LogViewerPage | Open and inspect DataFlash (.bin), PX4 ULog (.ulg), and telemetry (.tlog) logs in a unified workflow.': '在统一工作流中打开并检查DataFlash (.bin)、PX4 ULog (.ulg)和遥测(.tlog)日志。',

    # Guided
    'GuidedActionsController | _activeVehicle(%1) _vehicleArmed(%2) guidedModeSupported(%3) _vehicleFlying(%4) _vehicleWasFlying(%5) _vehicleInRTLMode(%6) pauseVehicleSupported(%7) _vehiclePaused(%8) _flightMode(%9) _visualItemsCount(%10) roiSupported(%11) orbitSupported(%12) _missionActive(%13) _hideROI(%14) _hideOrbit(%15)': '_activeVehicle(%1) _vehicleArmed(%2) guidedModeSupported(%3) _vehicleFlying(%4) _vehicleWasFlying(%5) _vehicleInRTLMode(%6) pauseVehicleSupported(%7) _vehiclePaused(%8) _flightMode(%9) _visualItemsCount(%10) roiSupported(%11) orbitSupported(%12) _missionActive(%13) _hideROI(%14) _hideOrbit(%15)',

    # SHP
    'SHP | Unsupported projection: %1. Supported projections are: WGS84 (GEOGCS["GCS_WGS_1984"]) and UTM (PROJCS["WGS_1984_UTM_Zone_##N/S"]). Convert your shapefile to WGS84 using QGIS or ogr2ogr.': '不支持的投影：%1。支持的投影：WGS84 (GEOGCS["GCS_WGS_1984"])和UTM (PROJCS["WGS_1984_UTM_Zone_##N/S"])。使用QGIS或ogr2ogr将shapefile转换为WGS84。',
    'SHP | UTM projection is not in supported format. Must be PROJCS["WGS_1984_UTM_Zone_##N/S': 'UTM投影格式不受支持。必须为PROJCS["WGS_1984_UTM_Zone_##N/S',

    # Vibration page
    'VibrationPage | X (%1)': 'X（%1）',
    'VibrationPage | Y (%1)': 'Y（%1）',
    'VibrationPage | Z (%1)': 'Z（%1）',
    'VibrationPage | Accel 2: %1': '加速度计2：%1',
    'VibrationPage | Accel 3: %1': '加速度计3：%1',

    # PX4
    'PX4TuningComponentCopterRate | Airmode (disable during tuning) <b><a href="https://docs.px4.io/main/en/config_mc/pid_tuning_guide_multicopter.html#airmode-mixer-saturation">?</a></b>': '空中模式（调参时禁用）<b><a href="https://docs.px4.io/main/en/config_mc/pid_tuning_guide_multicopter.html#airmode-mixer-saturation">?</a></b>',

    # Main
    'main | Filter tests by label (unit, integration, vehicle, missionmanager, etc.).': '按标签筛选测试（unit, integration, vehicle, missionmanager等）。',
    'main | --unittest/--unittest-stress/--unittest-output/--list-tests options are only available in unittest builds.': '--unittest/--unittest-stress/--unittest-output/--list-tests选项仅在unittest构建中可用。',
    'main | --fake-mobile/--allow-multiple are not supported on mobile platforms.': '--fake-mobile/--allow-multiple不支持移动平台。',
    'main | --desktop/--no-windows-assert-ui are only supported on Windows.': '--desktop/--no-windows-assert-ui仅在Windows上支持。',

    # Config files
    'APMFailsafes.VehicleConfig.json | lipo': 'LiPo',
    'APMFailsafes.VehicleConfig.json | pwm': 'PWM',
    'APMFailsafes.VehicleConfig.json | ekf': 'EKF',
    'APMLogging.VehicleConfig.json | ekf': 'EKF',
    'APMLogging.VehicleConfig.json | ekf3': 'EKF3',
    'Power.VehicleConfig.json | lipo': 'LiPo',
    'Power.VehicleConfig.json | pwm': 'PWM',
    'Power.VehicleConfig.json | uavcan': 'UAVCAN',
    'Power.VehicleConfig.json | dronecan': 'DroneCAN',
    'FirmwareUpgrade.SettingsGroup.json | apmChibiOS': 'APM ChibiOS',

    # Telemetry
    'Telemetry.SettingsUI.json | csv': 'CSV',
    'Telemetry.SettingsUI.json | apm': 'APM',
    'Telemetry.SettingsUI.json | mavlink2': 'MAVLink 2',
    'CommLinks.SettingsUI.json | librepilot': 'LibrePilot',
    'CommLinks.SettingsUI.json | NMEA GPS': 'NMEA GPS',
    'CommLinks.SettingsUI.json | nmea': 'NMEA',
    'Maps.SettingsUI.json | google': 'Google',
    'Maps.SettingsUI.json | bing': 'Bing',
    'Maps.SettingsUI.json | mapbox': 'Mapbox',
    'Maps.SettingsUI.json | esri': 'Esri',
    'Maps.SettingsUI.json | vworld': 'VWorld',
    'Maps.SettingsUI.json | openaip': 'OpenAIP',
    'Maps.SettingsUI.json | wms': 'WMS',
    'Viewer3D.SettingsUI.json | osm': 'OSM',
    'Viewer3D.SettingsUI.json | openstreetmap': 'OpenStreetMap',
    'RemoteID.SettingsUI.json | faa': 'FAA',
    'RemoteID.SettingsUI.json | eu': 'EU',
    'RemoteID.SettingsUI.json | gnss': 'GNSS',
    'RemoteID.SettingsUI.json | nmea': 'NMEA',
    'NTRIP.SettingsUI.json | ntrip': 'NTRIP',
    'NTRIP.SettingsUI.json | rtcm': 'RTCM',
    'NTRIP.SettingsUI.json | udp rtcm': 'UDP RTCM',
    'ADSBVehicleManager.SettingsUI.json | adsb': 'ADS-B',
    'ADSBVehicleManager.SettingsUI.json | ads-b': 'ADS-B',
    'ADSBVehicleManager.SettingsUI.json | sbs': 'SBS',
    'Video.SettingsUI.json | rtsp': 'RTSP',
    'Video.SettingsUI.json | mpegts': 'MPEG-TS',
    'Video.SettingsUI.json | gpu': 'GPU',
    'Video.SettingsUI.json | mp4': 'MP4',
    'Video.SettingsUI.json | mkv': 'MKV',
    'General.SettingsUI.json | gstreamer': 'GStreamer',
    'General.SettingsUI.json | px4': 'PX4',
    'Logging.SettingsUI.json | gstreamer': 'GStreamer',

    # Video settings - technical descriptions
    'Video.SettingsGroup.json | By default, when a hardware decoder produces GPU-backed frames (DMABuf, GLMemory, D3D11, IOSurface, AHardwareBuffer), the pipeline imports them directly into Qts render thread to avoid a per-frame CPU copy. The pipeline already falls back to the CPU path automatically when a GPU import fails, so this option is only needed for debugging or to work around a broken driver.': '默认情况下,硬件解码器生成的GPU帧（DMABuf、GLMemory、D3D11、IOSurface、AHardwareBuffer）直接导入Qt渲染线程,避免每帧CPU拷贝。GPU导入失败时自动回退CPU路径,此选项仅用于调试或绕开驱动问题。',
    'Video.SettingsGroup.json | Leave blank to auto-probe (SoC-native imxvideoconvert_g2d / nvvidconv when present, otherwise videoconvert). Set to a specific GStreamer factory name to force that element. Used as a workaround when an SoCs preferred element has a defect; takes effect on next stream restart.': '留空自动探测（优先SoC原生imxvideoconvert_g2d/nvvidconv,否则videoconvert）。设为特定GStreamer工厂名强制使用该元件。用于SoC首选元件有缺陷时的解决方案；下次流重启生效。',
    'Video.SettingsGroup.json | QGC normally inserts a pixel-aspect-ratio=1/1 capsfilter so non-square-pixel sources (some RTSP cams, DVB) dont render geometrically distorted. A few v4l2 drivers without VIDIOC_CROPCAP deadlock negotiation when PAR is forced; enable this option as a workaround. Takes effect on next stream restart.': 'QGC通常插入像素宽高比1:1的capsfilter,确保非方形像素源（部分RTSP摄像头、DVB）渲染无畸变。部分无VIDIOC_CROPCAP的v4l2驱动在强制PAR时协商死锁；启用此选项作为解决方案。下次流重启生效。',
    'Video.SettingsGroup.json | Disables the video stream when the vehicle is disarmed to save bandwidth.': '飞行器上锁时禁用视频流以节省带宽。',

    # NTRIP
    'NTRIP.SettingsGroup.json | Listen on a UDP port for incoming RTCM3 correction data and forward it to connected vehicles via MAVLink GPS_RTCM_DATA.': '在UDP端口监听传入的RTCM3修正数据,通过MAVLink GPS_RTCM_DATA转发到已连接的飞行器。',

    # Mavlink settings
    'Mavlink.SettingsGroup.json | Ardupilot Support server to forward mavlink to. i.e: support.ardupilot.org:xxxx': '转发MAVLink的ArduPilot支持服务器。例如：support.ardupilot.org:xxxx',

    # App settings
    'App.SettingsGroup.json | URL for X Y Z map with {x} {y} {z} or {zoom} substitutions. Eg: https://basemaps.linz.govt.nz/v1/tiles/aerial/EPSG:3857/{z}/{x}/{y}.png?api=d01ev80nqcjxddfvc6amyvkk1ka': '使用{x}{y}{z}或{zoom}替换的XYZ地图URL。例如：https://basemaps.linz.govt.nz/v1/tiles/aerial/EPSG:3857/{z}/{x}/{y}.png?api=d01ev80nqcjxddfvc6amyvkk1ka',
    'App.SettingsGroup.json | Your personal API key for OpenAIP aviation maps. Get one at https://www.openaip.net': 'OpenAIP航空地图的个人API密钥。请访问https://www.openaip.net获取',

    # Battery
    'BatteryFact.json | n/a,LIPO,LIFE,LION,NIMH': '不适用,LiPo,LiFe,Li-ion,NiMH',

    # GPS
    'GPSFact.json | None,No Fix,2D Lock,3D Lock,3D DGPS Lock,3D RTK GPS Lock (float),3D RTK GPS Lock (fixed),Static (fixed)': '无,未定位,2D锁定,3D锁定,3D差分锁定,3D RTK浮动,3D RTK固定,静态固定',

    # RemoteID
    'RemoteID.SettingsGroup.json | Undeclared,Class 0,Class 1,Class 2,Class 3,Class 4,Class 5,Class 6': '未声明,Class 0,Class 1,Class 2,Class 3,Class 4,Class 5,Class 6',

    # Video stream settings
    'VideoSettings | UDP h.264 Video Stream': 'UDP H.264 视频流',
    'VideoSettings | UDP h.265 Video Stream': 'UDP H.265 视频流',
    'VideoSettings | 3DR Solo (requires restart)': '3DR Solo（需要重启）',
}


def apply():
    for ts_path, label in [(SRC_TS, 'Source'), (JSON_TS, 'JSON')]:
        tree = ET.parse(ts_path)
        root = tree.getroot()
        applied = 0
        for context in root:
            ctx_name = context.findtext('name', '')
            for msg in context:
                if msg.tag != 'message':
                    continue
                source_elem = msg.find('source')
                trans_elem = msg.find('translation')
                if source_elem is None or trans_elem is None:
                    continue
                source = (source_elem.text or '').strip()
                if trans_elem.get('type') != 'unfinished':
                    continue

                key = f'{ctx_name} | {source}'
                if key in TRANSLATIONS:
                    trans_elem.text = TRANSLATIONS[key]
                    if 'type' in trans_elem.attrib:
                        del trans_elem.attrib['type']
                    applied += 1
                elif source in KEEP_ENGLISH:
                    trans_elem.text = source
                    if 'type' in trans_elem.attrib:
                        del trans_elem.attrib['type']
                    applied += 1

        tree.write(ts_path, encoding='utf-8', xml_declaration=True)
        print(f'{label}: Applied {applied} final translations')

    # Count remaining
    for ts_path, label in [(SRC_TS, 'Source'), (JSON_TS, 'JSON')]:
        tree = ET.parse(ts_path)
        cnt = 0
        for context in tree.getroot():
            for msg in context:
                if msg.tag != 'message': continue
                t = msg.find('translation')
                if t is not None and t.get('type') == 'unfinished':
                    cnt += 1
        print(f'{label} remaining: {cnt}')


if __name__ == '__main__':
    apply()
