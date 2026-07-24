#!/usr/bin/env python3
"""QGC 中文翻译脚本 — 将所有未翻译字符串翻译为中文,使用无人机行业标准术语。

用法:
    cd /path/to/qgroundcontrol
    python3 tools/translations/qgc_translate_zh.py

处理文件:
    - translations/qgc_source_zh_CN.ts  (源字符串翻译)
    - translations/qgc_json_zh_CN.ts    (JSON 字符串翻译)
"""

from __future__ import annotations

import re
from pathlib import Path

try:
    from defusedxml import ElementTree as ET
except ImportError:
    from xml.etree import ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[2]
TS_SOURCE = REPO_ROOT / "translations" / "qgc_source_zh_CN.ts"
TS_JSON = REPO_ROOT / "translations" / "qgc_json_zh_CN.ts"


# ==============================================================================
# 精确短语翻译表 (大小写敏感,完整匹配)
# ==============================================================================

PHRASES: dict[str, str] = {
    # --- 通用 UI ---
    "Basic": "基本",
    "Advanced": "高级",
    "Common": "通用",
    "General": "通用",
    "General Settings": "通用设置",
    "Standard": "标准",
    "Custom": "自定义",
    "Unknown": "未知",
    "None": "无",
    "All": "全部",
    "Any": "任意",
    "Other": "其他",
    "Multiple": "多选",
    "Some": "部分",
    "None": "无",
    "Default": "默认",

    # --- 操作 ---
    "Save": "保存",
    "Load": "加载",
    "Open": "打开",
    "Close": "关闭",
    "Cancel": "取消",
    "Apply": "应用",
    "Confirm": "确认",
    "Delete": "删除",
    "Remove": "移除",
    "Add": "添加",
    "Edit": "编辑",
    "Copy": "复制",
    "Paste": "粘贴",
    "Cut": "剪切",
    "Select": "选择",
    "Select All": "全选",
    "Clear": "清除",
    "Refresh": "刷新",
    "Update": "更新",
    "Reset": "重置",
    "Install": "安装",
    "Uninstall": "卸载",
    "Upgrade": "升级",
    "Retry": "重试",
    "Skip": "跳过",
    "Continue": "继续",
    "Proceed": "继续",
    "Finish": "完成",
    "Done": "完成",
    "Register": "注册",

    # --- 开关 ---
    "On": "开",
    "Off": "关",
    "Enable": "启用",
    "Disable": "禁用",
    "Enabled": "已启用",
    "Disabled": "已禁用",
    "Activate": "激活",
    "Deactivate": "停用",

    # --- 按钮 ---
    "Yes": "是",
    "No": "否",
    "OK": "确定",
    "Okay": "确定",
    "Next": "下一步",
    "Previous": "上一步",
    "Back": "返回",
    "Forward": "前进",
    "Help": "帮助",
    "About": "关于",
    "Exit": "退出",
    "Quit": "退出",
    "Logout": "注销",

    # --- 连接 ---
    "Connect": "连接",
    "Connected": "已连接",
    "Connecting": "连接中",
    "Disconnect": "断开",
    "Disconnected": "已断开",
    "Disconnecting": "断开中",
    "Reconnect": "重新连接",
    "Auto Connect": "自动连接",
    "Auto connect": "自动连接",
    "Auto-connect": "自动连接",

    # --- 状态 ---
    "Status": "状态",
    "Ready": "就绪",
    "Busy": "忙碌",
    "Idle": "空闲",
    "Active": "激活",
    "Inactive": "未激活",
    "Pending": "待处理",
    "Success": "成功",
    "Failed": "失败",
    "Complete": "完成",
    "Incomplete": "未完成",
    "Partial": "部分",

    # --- 消息 ---
    "Warning": "警告",
    "Warning:": "警告：",
    "Error": "错误",
    "Error:": "错误：",
    "Critical": "严重",
    "Critical:": "严重：",
    "Information": "信息",
    "Info": "信息",
    "Notice": "通知",
    "Notification": "通知",
    "Alert": "告警",
    "Hint": "提示",
    "Tip": "提示",
    "Note": "注意",
    "Caution": "注意",
    "Danger": "危险",
    "Message": "消息",

    # --- 文件 ---
    "File": "文件",
    "New": "新建",
    "Open File": "打开文件",
    "Save File": "保存文件",
    "Save As": "另存为",
    "Export": "导出",
    "Import": "导入",
    "Print": "打印",
    "Upload": "上传",
    "Download": "下载",
    "Send": "发送",
    "Receive": "接收",

    # --- 时间 ---
    "Year": "年",
    "Month": "月",
    "Week": "周",
    "Day": "天",
    "Hour": "小时",
    "Minute": "分钟",
    "Second": "秒",
    "Hours": "小时",
    "Minutes": "分钟",
    "Seconds": "秒",

    # --- 方向 ---
    "North": "北",
    "South": "南",
    "East": "东",
    "West": "西",
    "Up": "上",
    "Down": "下",
    "Left": "左",
    "Right": "右",
    "Forward": "前",
    "Backward": "后",
    "Vertical": "垂直",
    "Horizontal": "水平",

    # --- 飞行器类型 ---
    "Vehicle": "飞行器",
    "Multi-Rotor": "多旋翼",
    "Multicopter": "多旋翼",
    "Copter": "多旋翼",
    "Quad": "四旋翼",
    "Quadcopter": "四旋翼",
    "Hex": "六旋翼",
    "Hexacopter": "六旋翼",
    "Octo": "八旋翼",
    "Octocopter": "八旋翼",
    "Tri": "三旋翼",
    "Helicopter": "直升机",
    "Plane": "固定翼",
    "VTOL": "垂直起降固定翼",
    "Rover": "无人车",
    "Boat": "无人船",
    "Sub": "水下航行器",
    "Submarine": "水下航行器",
    "Antenna Tracker": "天线跟踪器",
    "Antenna tracker": "天线跟踪器",
    "GCS": "地面站",
    "UAV": "无人机",
    "UAS": "无人机系统",
    "Drone": "无人机",
    "Airframe": "机体",

    # --- 飞行模式 ---
    "Stabilize": "稳定模式",
    "Altitude Hold": "定高模式",
    "Position Hold": "定点模式",
    "Loiter": "悬停",
    "RTL": "返航",
    "Return to Launch": "返航",
    "Return to Home": "返航",
    "Return": "返航",
    "Auto": "自动模式",
    "Guided": "引导模式",
    "Land": "降落",
    "Takeoff": "起飞",
    "Take off": "起飞",
    "Follow Me": "跟随模式",
    "Circle": "环绕",
    "Sport": "运动模式",
    "Acro": "特技模式",
    "Manual": "手动模式",
    "Hold": "保持",
    "Brake": "制动模式",
    "Smart RTL": "智能返航",
    "Mission": "航线任务",
    "Flight Mode": "飞行模式",
    "Flight mode": "飞行模式",
    "Flight Modes": "飞行模式",

    # --- 飞行控制 ---
    "Roll": "横滚",
    "Pitch": "俯仰",
    "Yaw": "偏航",
    "Throttle": "油门",

    # PID 调参 - 常见完整短语
    "Roll axis angle controller P gain": "横滚轴角度控制器P增益",
    "Roll axis angle controller I gain": "横滚轴角度控制器I增益",
    "Roll axis angle controller D gain": "横滚轴角度控制器D增益",
    "Roll axis rate controller P gain": "横滚轴速率控制器P增益",
    "Roll axis rate controller I gain": "横滚轴速率控制器I增益",
    "Roll axis rate controller D gain": "横滚轴速率控制器D增益",
    "Pitch axis angle controller P gain": "俯仰轴角度控制器P增益",
    "Pitch axis angle controller I gain": "俯仰轴角度控制器I增益",
    "Pitch axis angle controller D gain": "俯仰轴角度控制器D增益",
    "Pitch axis rate controller P gain": "俯仰轴速率控制器P增益",
    "Pitch axis rate controller I gain": "俯仰轴速率控制器I增益",
    "Pitch axis rate controller D gain": "俯仰轴速率控制器D增益",
    "Yaw axis angle controller P gain": "偏航轴角度控制器P增益",
    "Yaw axis angle controller I gain": "偏航轴角度控制器I增益",
    "Yaw axis angle controller D gain": "偏航轴角度控制器D增益",
    "Yaw axis rate controller P gain": "偏航轴速率控制器P增益",
    "Yaw axis rate controller I gain": "偏航轴速率控制器I增益",
    "Yaw axis rate controller D gain": "偏航轴速率控制器D增益",
    "Advanced rate controller PID tuning": "高级速率控制器PID调参",
    "Advanced rate controller PID tuning with live telemetry charts.": "通过实时遥测图表进行高级速率控制器PID调参。",
    "Tuning - Advanced": "调参 - 高级",
    "Roll axis rate controller PID": "横滚轴速率控制器PID",
    "Pitch axis rate controller PID": "俯仰轴速率控制器PID",
    "Yaw axis rate controller PID": "偏航轴速率控制器PID",
    "Roll axis angle controller PID": "横滚轴角度控制器PID",
    "Pitch axis angle controller PID": "俯仰轴角度控制器PID",
    "Yaw axis angle controller PID": "偏航轴角度控制器PID",

    # --- 机架 ---
    "Frame": "机架",
    "Frame Class": "机架种类",
    "Frame class": "机架种类",
    "Frame Type": "机架类型",
    "Frame type": "机架类型",
    "Airframe type": "机体类型",
    "X Frame": "X型机架",
    "X frame": "X型机架",
    "Plus Frame": "+型机架",
    "Plus frame": "+型机架",
    "H Frame": "H型机架",
    "H frame": "H型机架",

    # --- 传感器 ---
    "Sensor": "传感器",
    "Sensors": "传感器",
    "Sensor type": "传感器类型",
    "Sensor Types": "传感器类型",
    "Gyroscope": "陀螺仪",
    "Gyro": "陀螺仪",
    "Accelerometer": "加速度计",
    "Accel": "加速度计",
    "Magnetometer": "磁力计",
    "Mag": "磁力计",
    "Compass": "指南针",
    "Barometer": "气压计",
    "Baro": "气压计",
    "IMU": "IMU",
    "Lidar": "激光雷达",
    "LiDAR": "激光雷达",
    "Optical Flow": "光流",
    "Optical flow": "光流",
    "Flow": "光流",
    "Ultrasonic": "超声波",
    "RFID": "RFID",
    "Airspeed": "空速",
    "Airspeed sensor": "空速传感器",
    "Airspeed Sensor": "空速传感器",
    "Primary Airspeed Sensor": "主空速传感器",
    "Second Airspeed Sensor": "辅助空速传感器",
    "Multi-Sensor Options": "多传感器选项",
    "Primary sensor": "主传感器",
    "Use airspeed": "使用空速",
    "Airspeed ratio": "空速比",
    "Auto calibrate ratio in flight": "飞行中自动校准比率",

    # --- 校准 ---
    "Calibration": "校准",
    "Calibrate": "校准",
    "Level": "水平",
    "Level Horizon": "水平校准",
    "Accelerometer Calibration": "加速度计校准",
    "Compass Calibration": "指南针校准",
    "Level Calibration": "水平校准",
    "Radio Calibration": "遥控器校准",
    "ESC Calibration": "电调校准",
    "Sensor Calibration": "传感器校准",
    "Gyroscope Calibration": "陀螺仪校准",
    "Magnetometer Calibration": "磁力计校准",
    "Remote Calibration": "遥控校准",
    "Gimbal Calibration": "云台校准",

    # --- 导航 ---
    "Waypoint": "航点",
    "GPS": "GPS",
    "GPS Lock": "GPS锁定",
    "GPS lock": "GPS锁定",
    "GPS Fix": "GPS定位",
    "GPS fix": "GPS定位",
    "3D Fix": "3D定位",
    "3D GPS Fix": "3D GPS定位",
    "3D DGPS Fix": "3D差分GPS定位",
    "RTK Fixed": "RTK固定解",
    "RTK Float": "RTK浮点解",
    "No GPS": "无GPS",
    "Satellites": "卫星数",
    "HDOP": "水平精度因子",
    "VDOP": "垂直精度因子",
    "PDOP": "位置精度因子",
    "GPS Status": "GPS状态",
    "GPS status": "GPS状态",
    "Home": "家点",
    "Home Position": "家点位置",
    "Home position": "家点位置",
    "Start": "开始",
    "Stop": "停止",

    # --- 坐标 ---
    "Latitude": "纬度",
    "Lat": "纬度",
    "Longitude": "经度",
    "Lon": "经度",
    "Altitude": "高度",
    "Altitude MSL": "海拔高度",
    "AMSL": "海拔高度",
    "AGL": "离地高度",
    "Relative altitude": "相对高度",
    "Heading": "航向",
    "Course": "航线角",
    "Bearing": "方位角",
    "Yaw offset": "偏航偏移",

    # --- 速度 ---
    "Speed": "速度",
    "Groundspeed": "地速",
    "Wind Speed": "风速",
    "Wind speed": "风速",
    "Wind Direction": "风向",
    "Wind direction": "风向",
    "Climb rate": "爬升率",
    "Descent rate": "下降率",
    "Vertical speed": "垂直速度",

    # --- 电池 ---
    "Battery": "电池",
    "Battery 1": "电池1",
    "Battery 2": "电池2",
    "Voltage": "电压",
    "Current": "电流",
    "Remaining": "剩余",
    "mAh": "毫安时",
    "Cell": "电芯",
    "Cell count": "电芯数",
    "Capacity": "容量",
    "Full charge": "满充",
    "Power": "电源",
    "Power Module": "电源模块",
    "Power module": "电源模块",
    "Battery Status": "电池状态",
    "Battery status": "电池状态",

    # --- 故障保护 ---
    "Failsafe": "故障保护",
    "Low Voltage Failsafe": "低电压故障保护",
    "Critical Voltage Failsafe": "临界电压故障保护",
    "Vehicle Action": "飞行器动作",
    "Voltage Trigger": "电压触发值",
    "mAh Trigger": "毫安时触发值",
    "RTL Altitude": "返航高度",
    "Return Altitude": "返航高度",

    # --- 解锁 ---
    "Arm": "解锁",
    "Disarm": "上锁",
    "Armed": "已解锁",
    "Disarmed": "已上锁",
    "Arming": "解锁中",
    "Arming check": "解锁检查",
    "Pre-arm": "预解锁",
    "Prearm": "预解锁",
    "Safety": "安全开关",
    "Safe": "安全",

    # --- RC 遥控 ---
    "RC": "遥控",
    "RC Switch": "遥控开关",
    "RC Transmitter": "遥控发射机",
    "RC transmitter": "遥控发射机",
    "RSSI": "信号强度",
    "Fail Safe": "故障保护",
    "Transmitter": "发射机",
    "Receiver": "接收机",
    "Binding": "对频",
    "Bind": "对频",
    "Trim": "微调",
    "Subtrim": "副微调",
    "End Point": "行程终点",
    "Travel": "行程",
    "Reverse": "反向",
    "Throttle stick": "油门杆",
    "Control stick": "控制杆",
    "Joystick": "摇杆",
    "Gamepad": "游戏手柄",
    "Button": "按钮",
    "Switch": "开关",
    "Slider": "滑块",
    "Knob": "旋钮",
    "Dial": "旋钮",
    "Channel": "通道",
    "Channels": "通道",

    # --- 通信 ---
    "Telemetry": "遥测",
    "MAVLink": "MAVLink",
    "Heartbeat": "心跳",
    "Stream": "流",
    "Stream rate": "流速率",
    "Link": "链路",
    "Link quality": "链路质量",
    "Packet loss": "丢包",
    "Latency": "延迟",
    "Baud": "波特率",
    "Baud rate": "波特率",
    "Serial": "串口",
    "UDP": "UDP",
    "TCP": "TCP",
    "Bluetooth": "蓝牙",
    "Mock Link": "模拟链路",
    "Link Settings": "链路设置",

    # --- 固件/系统 ---
    "Firmware": "固件",
    "Bootloader": "引导加载程序",
    "Boot": "启动",
    "Reboot": "重启",
    "Reboot required": "需要重启",
    "Requires reboot": "需要重启",
    "Reset to defaults": "恢复默认",
    "Defaults": "默认值",

    # --- 云台/相机 ---
    "Gimbal": "云台",
    "Camera": "相机",
    "Cameras": "相机",
    "Photo": "照片",
    "Take photo": "拍照",
    "Take Photo": "拍照",
    "Start recording": "开始录像",
    "Stop recording": "停止录像",
    "Stop video": "停止录像",
    "Zoom": "变焦",
    "Focus": "对焦",
    "Focus mode": "对焦模式",
    "Auto Focus": "自动对焦",
    "Aperture": "光圈",
    "Shutter": "快门",
    "ISO": "感光度",
    "Exposure": "曝光",
    "White Balance": "白平衡",
    "White balance": "白平衡",
    "Resolution": "分辨率",
    "Frame Rate": "帧率",
    "Frame rate": "帧率",
    "FOV": "视场角",
    "ROI": "兴趣点",

    # --- 电机/执行器 ---
    "Motor": "电机",
    "Motors": "电机",
    "Servo": "舵机",
    "Actuator": "执行器",
    "Actuators": "执行器",
    "ESC": "电调",
    "Propeller": "螺旋桨",
    "Prop": "桨",

    # --- 日志 ---
    "Log": "日志",
    "Logs": "日志",
    "Log Download": "日志下载",
    "Log download": "日志下载",
    "Log View": "日志查看",
    "Log view": "日志查看",
    "Log Viewer": "日志查看器",
    "Log viewer": "日志查看器",
    "DataFlash": "飞行数据闪存",
    "GeoTag": "地理标签",
    "Geo-tag": "地理标签",
    "GeoTag images": "地理标签图像",

    # --- 分析 ---
    "Analyze": "分析",
    "Analysis": "分析",
    "Plot": "绘图",
    "Graph": "图表",
    "Parameter": "参数",
    "Parameters": "参数",
    "Summary": "概要",
    "Details": "详情",
    "Statistics": "统计",

    # --- 设置 ---
    "Settings": "设置",
    "App Settings": "应用设置",
    "Application Settings": "应用设置",
    "Vehicle Settings": "飞行器设置",
    "Preferences": "偏好设定",
    "Options": "选项",
    "Configuration": "配置",
    "Properties": "属性",

    # --- 显示 ---
    "Display": "显示",
    "Appearance": "外观",
    "Theme": "主题",
    "Language": "语言",
    "Units": "单位",
    "Distance": "距离",
    "Area": "面积",
    "Speed": "速度",
    "Horizontal Distance": "水平距离",
    "Vertical Distance": "垂直距离",
    "Volume": "音量",
    "Brightness": "亮度",
    "Full Screen": "全屏",
    "Full screen": "全屏",
    "Minimize": "最小化",
    "Maximize": "最大化",
    "Restore": "恢复",
    "Zoom In": "放大",
    "Zoom Out": "缩小",

    # --- 地图 ---
    "Map": "地图",
    "Map Type": "地图类型",
    "Map type": "地图类型",
    "Satellite": "卫星",
    "Hybrid": "混合",
    "Street": "街道",
    "Terrain": "地形",
    "Layer": "图层",

    # --- 航线/规划 ---
    "Plan": "航线规划",
    "New Plan": "新建航线",
    "Open Plan": "打开航线",
    "Save Plan": "保存航线",
    "Save Plan As": "航线另存为",
    "Send to Vehicle": "发送到飞行器",
    "Load from Vehicle": "从飞行器加载",
    "Geofence": "电子围栏",
    "GeoFence": "电子围栏",
    "Rally Point": "集结点",
    "Rally point": "集结点",
    "Rally Points": "集结点",
    "Rally points": "集结点",
    "Corridor": "廊道",
    "Survey": "测绘",
    "Survey Area": "测绘区域",
    "Survey area": "测绘区域",
    "Transect": "测绘线",
    "Overlap": "重叠率",
    "Sidelap": "旁向重叠率",
    "Frontal Overlap": "航向重叠率",
    "GSD": "地面分辨率",
    "Ground Resolution": "地面分辨率",
    "Polygon": "多边形",
    "KML": "KML",
    "SHP": "SHP",
    "GeoJSON": "GeoJSON",
    "UTM Zone": "UTM带",
    "UTM zone": "UTM带",
    "MGRS": "MGRS",
    "MGRS coordinate": "MGRS坐标",
    "WGS84": "WGS84",
    "Hemisphere": "半球",
    "Set Home": "设置家点",
    "Set Home Here": "设当前位置为家点",
    "Take photos": "拍照",
    "Start video": "开始录像",
    "Circle Turn": "盘旋",
    "Camera Trigger": "相机触发",
    "Camera trigger": "相机触发",
    "Set waypoint": "设置航点",
    "Flight time": "飞行时间",

    # --- 单位 ---
    "Feet": "英尺",
    "Meters": "米",
    "m/s": "米/秒",
    "km/h": "公里/小时",
    "mph": "英里/小时",
    "Knots": "节",
    "Celsius": "摄氏度",
    "C": "摄氏度",
    "Fahrenheit": "华氏度",
    "Percent": "百分比",
    "Degrees": "度",
    "Radians": "弧度",
    "Hertz": "赫兹",
    "Hz": "赫兹",
    "KHz": "千赫兹",
    "MHz": "兆赫兹",
    "GHz": "吉赫兹",
    "Bytes": "字节",
    "KB": "千字节",
    "MB": "兆字节",
    "GB": "吉字节",
    "bit": "比特",
    "bit/s": "比特/秒",
    "Kbit/s": "千比特/秒",
    "Mbit/s": "兆比特/秒",

    # --- 视图窗口 ---
    "Plan View": "航线视图",
    "Plan view": "航线视图",
    "Fly View": "飞行视图",
    "Fly view": "飞行视图",
    "Setup View": "设置视图",
    "Setup view": "设置视图",
    "Analyze View": "分析视图",
    "Analyze view": "分析视图",
    "Settings View": "设置视图",
    "Application Settings View": "应用设置视图",
    "Toolbar": "工具栏",
    "Status Bar": "状态栏",
    "Vehicle Setup": "飞行器设置",
    "Parameter Editor": "参数编辑器",
    "Parameter editor": "参数编辑器",
    "Mission Planner": "航线规划器",

    # --- MAVLink 枚举上下文 ---
    "MAV_TYPE": "MAV飞行器类型",
    "MAV_AUTOPILOT": "MAV飞控类型",
    "MAV_MODE_FLAG": "MAV模式标志",
    "MAV_STATE": "MAV状态",
    "MAV_COMPONENT": "MAV组件",
    "MAV_SYS_STATUS_SENSOR": "MAV系统状态传感器",
    "MAV_FRAME": "MAV坐标系",
    "MAV_CMD": "MAV指令",
    "MAV_DATA_STREAM": "MAV数据流",
    "MAV_RESULT": "MAV结果",
    "MAV_MISSION_RESULT": "MAV航线结果",
    "MAV_SEVERITY": "MAV严重程度",
    "MAV_BATTERY_TYPE": "MAV电池类型",
    "MAV_BATTERY_FUNCTION": "MAV电池功能",
    "MAV_BATTERY_CHARGE_STATE": "MAV电池充电状态",
    "MAV_LANDED_STATE": "MAV降落状态",
    "MAV_ESTIMATOR_TYPE": "MAV估计器类型",
    "FIRMWARE_VERSION_TYPE": "固件版本类型",
    "MISSION_STATE": "航线状态",

    # --- 航点相关参数 ---
    "Latitude of item position": "航点纬度",
    "Longitude of item position": "航点经度",
    "Easting of item position": "航点东向坐标",
    "Northing of item position": "航点北向坐标",
    "East offset": "东向偏移",
    "North offset": "北向偏移",
    "Up offset": "天向偏移",
    "Clockwise rotation": "顺时针旋转",
    "Counterclockwise rotation": "逆时针旋转",
    "Counter-clockwise rotation": "逆时针旋转",

    # --- 测绘参数 ---
    "Scale the RC range": "缩放遥控范围",
    "Minimum parameter value": "参数最小值",
    "Maximum parameter value": "参数最大值",
    "Parameter value when RC output is 0": "遥控输出为0时的参数值",
    "Radius for geofence circle.": "电子围栏半径。",
    "Specify whether the camera should take photos or video": "指定相机拍照或录像",
    "Specify the distance between each photo": "指定每次拍照间距",
    "Specify the time between each photo": "指定每次拍照时间间隔",
    "Gimbal pitch rotation.": "云台俯仰旋转。",
    "Gimbal yaw rotation.": "云台偏航旋转。",
    "Specify whether the camera should switch to Photo, Video or Survey mode": "指定相机切换至拍照、录像或测绘模式",
    "Amount of additional distance to add outside the survey area for vehicle turn around.": "飞行器转弯时测绘区域外增加的额外距离。",
    "Camera continues taking images in turn arounds.": "相机在转弯时继续拍摄。",
    "Stop and Hover at each image point before taking image": "在每个拍照点停稳悬停后拍摄",
    "Refly the pattern at a 90 degree angle": "以90度角重飞航线",
    "Additional waypoints within the transect will be added if the terrain altitude difference grows larger than this tolerance.": "当地形高度差超过容差时,在测绘线内添加额外航点。",
    "The maximum climb rate from one waypoint to another when adjusting for terrain. Set to 0 for no max.": "地形跟随调整时航点间的最大爬升率。设为0表示无限制。",
    "The maximum descent rate from one waypoint to another when adjusting for terrain. Set to 0 for no max.": "地形跟随调整时航点间的最大下降率。设为0表示无限制。",

    # --- 飞行器配置 ---
    "Configure the airframe type that matches your vehicle.": "配置与您的飞行器匹配的机体类型。",
    " To change this configuration, select the desired frame class below and then reboot the vehicle.": "要更改此配置,请在下方选择所需的机架种类,然后重启飞行器。",
    "Airframe is currently not set.": "当前未设置机体类型。",

    # --- 参数错误 ---
    "Param file github json download failed to start: %1": "从GitHub下载JSON参数文件启动失败：%1",
    "Param file download failed to start: %1": "参数文件下载启动失败：%1",
    "Param file github json download failed: %1": "从GitHub下载JSON参数文件失败：%1",
    "Param file download failed: %1": "参数文件下载失败：%1",

    # --- 提示/消息 ---
    "Invalid setting for FRAME_TYPE. Click to Reset.": "FRAME_TYPE参数设置无效。点击重置。",
    "Please reboot the vehicle for this change to take effect.": "请重启飞行器使更改生效。",
    "Firmware Version": "固件版本",
    "Unknown component": "未知组件",
    "Unknown command": "未知指令",
    "Calibration required": "需要校准",
    "Calibration completed": "校准完成",
    "Connection lost": "连接断开",
    "Connect failed": "连接失败",
    "Error loading parameters": "加载参数时出错",
    "Error loading parameter": "加载参数时出错",
    "Enable RC to parameter calibration": "启用遥控参数校准",
    "Link down": "链路断开",
    "Link up": "链路已连接",
    "Receiving": "接收中",
    "Sending": "发送中",
    "Reboot the vehicle": "重启飞行器",
    "Vehicle disconnected": "飞行器已断开",
    "Vehicle connected": "飞行器已连接",
    "Waiting": "等待中",
    "Requires vehicle reboot": "需要重启飞行器",

    # --- 调试 ---
    "Debug": "调试",
    "Debug Messages": "调试信息",
    "Console": "控制台",
    "Log Console": "日志控制台",
    "Telemetry Log": "遥测日志",
    "Command Line": "命令行",
    "Simulate": "模拟",

    # --- 杂项 ---
    "Mavlink": "MAVLink",
    "SysID": "系统ID",
    "CompID": "组件ID",
    "Serial port": "串口",
    "Port": "端口",
    "Port Settings": "端口设置",
    "USB": "USB",
    "Network": "网络",
    "WIFI": "WiFi",
    "Ethernet": "以太网",
    "Proxy": "代理",
    "Gateway": "网关",
    "Protocol": "协议",
    "Version": "版本",
    "Action": "动作",
    "Actions": "动作",
    "Current Action": "当前动作",
    "Command": "指令",
    "Commands": "指令",
    "Event": "事件",
    "Events": "事件",
    "Tasks": "任务",
    "Queue": "队列",
    "Progress": "进度",
    "Rate": "速率",
    "Ratio": "比率",
    "Factor": "因子",
    "Crosstrack error": "偏航距误差",
    "AirSpeed": "空速",
    "GroundSpeed": "地速",
    "Climb": "爬升",
    "Descent": "下降",
    "Distance to home": "到家距离",
    "Distance to next": "到下一航点距离",
    "Total flight time": "总飞行时间",
    "Flight time": "飞行时间",
    "Time since boot": "开机时长",
    "Satellite count": "卫星计数",
    "Satellite Count": "卫星计数",
    "RC RSSI": "遥控信号强度",
    "Remaining Battery": "剩余电池",
    "Battery Remaining": "电池剩余",
    "Set Current": "设为当前",
    "Default Value": "默认值",

    # --- APM空速组件 ---
    "Airspeed Limits": "空速限制",
    "Cruise airspeed": "巡航空速",
    "Minimum airspeed": "最小空速",
    "Maximum airspeed": "最大空速",
    "Stall airspeed": "失速空速",
    "Airspeed offset": "空速偏移",
    "Pitot tube order": "空速管顺序",
    "Analog pin": "模拟引脚",
    "I2C bus": "I2C总线",
    "PSI range": "PSI量程",
    "Primary Sensor": "主传感器",
    "Sensor 2 type": "传感器2类型",
    "Health Monitoring": "健康监测",
    "Max airspeed/groundspeed difference": "最大空速/地速差",
    "Warning threshold": "警告阈值",
    "Re-enable gate size": "重新启用门限",
    "Offset calibration error warning": "偏移校准错误警告",
    "Configure airspeed sensor type and calibration.": "配置空速传感器类型和校准。",
    "Channel for AutoTune switch:": "自动调参通道：",
    "Channel 7": "通道7",
    "Channel 8": "通道8",
    "Channel 9": "通道9",
    "Channel 10": "通道10",
    "Channel 11": "通道11",
    "Channel 12": "通道12",

    # --- 电流/电压计算 ---
    "Calculate Amps per Volt": "计算每伏安培数",
    "Calculate Voltage Multiplier": "计算电压倍率",
    "Measured current:": "测量电流：",
    "Measured voltage:": "测量电压：",
    "Amps per volt:": "每伏安培数：",
    "Voltage multiplier:": "电压倍率：",
    "Calculate And Set": "计算并设置",

    # --- 日志分析 ---
    "Main": "主状态",
    "Radio": "遥控器",
    "Optflow": "光流",
    "Radio Failsafe": "遥控故障保护",
    "GPS Failsafe": "GPS故障保护",
    "Fence Failsafe": "围栏故障保护",
    "EKF Failsafe": "EKF故障保护",
    "EKF Check": "EKF检查",
    "ADSB Failsafe": "ADS-B故障保护",
    "Crash Check": "撞击检查",
    "Terrain Data": "地形数据",
    "Navigation": "导航",
    "EKF Primary": "EKF主滤波器",
    "Thrust Loss Check": "推力损失检查",
    "Leak Failsafe": "渗漏故障保护",
    "Pilot Input": "飞行员输入",
    "CPU Load Watchdog": "CPU负载监视",
    "Autotune": "自动调参",
    "Parachute": "降落伞",
    "Flip": "翻转",

    # --- 地理标签 ---
    "Exif Tool Error": "Exif工具错误",
    "Loaded": "已加载",
    "No images found": "未找到图像",
    "Log File": "日志文件",
    "Image Directory": "图像目录",
    "Save Folder": "保存文件夹",
    "Time Zone": "时区",
    "Start GeoTag": "开始地理标签",
    "Flying Threshold": "飞行阈值",
    "Max GPS Accuracy": "最大GPS精度",
    "Camera orientation for specific tag:": "相机朝向：",

    # --- 蓝牙 ---
    "Local Device": "本地设备",
    "Remote Device": "远程设备",
    "Data Rate": "数据速率",

    # --- 遥控器校准 ---
    "RC Calibration": "遥控器校准",
    "Transmitter Mode": "发射机模式",
    "Mode 1": "模式1",
    "Mode 2": "模式2",
    "Mode 3": "模式3",
    "Mode 4": "模式4",
    "Calibration Steps": "校准步骤",
    "Step 1:": "第一步：",
    "Step 2:": "第二步：",
    "Step 3:": "第三步：",
    "Move all transmitter sticks and switches to their endpoints.": "将所有遥控器摇杆和开关移动至行程端点。",
    "Center all sticks and move all switches to their neutral position.": "将所有摇杆回中,将所有开关置于中位。",
    "Move throttle to full.": "将油门推至最大。",
    "Click Next when ready.": "准备就绪后点击下一步。",
    "Calibration Complete": "校准完成",
    "Calibration cancelled": "校准已取消",

    # --- 故障保护设置 ---
    "Battery Failsafe": "电池故障保护",
    "RC Failsafe": "遥控故障保护",
    "GCS Failsafe": "地面站故障保护",
    "Failsafe Action": "故障保护动作",
    "Continue with Mission": "继续航线任务",
    "Return to Launch": "返航",
    "Land at current position": "当前位置降落",
    "Always RTL": "始终返航",
    "Smart RTL": "智能返航",
    "Terminate": "终止",

    # --- GPS ---
    "GPS Status": "GPS状态",
    "GPS type": "GPS类型",
    "Auto Configure": "自动配置",
    "Satellite Based Augmentation System": "星基增强系统",

    # --- 电源 ---
    "Battery Monitor": "电池监视",
    "Battery Capacity": "电池容量",
    "Battery voltage": "电池电压",
    "Current Amps": "当前电流",
    "Power Monitor": "电源监视",
    "Voltage Divider": "分压器",
    "Amps per volt": "每伏安培数",

    # --- 日志上传 ---
    "Upload Log": "上传日志",
    "Uploading": "上传中",
    "Upload Complete": "上传完成",
    "Upload Failed": "上传失败",
    "Log Files": "日志文件",
    "Select Log": "选择日志",
    "Delete Log": "删除日志",
    "Delete All": "删除全部",

    # --- 安全 ---
    "Safety Settings": "安全设置",
    "Arming Checks": "解锁检查",
    "Pre-Arm Check": "预解锁检查",
    "Arming Check": "解锁检查",
    "Disarm after landing": "降落后自动上锁",
    "Kill switch": "急停开关",
    "Emergency Stop": "紧急停止",
    "Motor Test": "电机测试",

    # --- 编码器/变换 ---
    "Transform Editor": "变换编辑器",
    "Rotation": "旋转",
    "Translation": "平移",
    "Scale": "缩放",
    "Shear": "剪切",
    "Reflect": "反射",

    # --- 离线地图 ---
    "Offline Map": "离线地图",
    "Download Map": "下载地图",
    "Cancel Download": "取消下载",
    "Downloading...": "下载中...",
    "Download Complete": "下载完成",
    "Default Map Type": "默认地图类型",
    "Map Providers": "地图提供商",
    "Tile Set": "瓦片集",
    "Min Zoom": "最小缩放",
    "Max Zoom": "最大缩放",
    "Available": "可用",
    "Queued": "队列中",
    "Downloaded": "已下载",
    "All tiles": "全部瓦片",
    "Only this location": "仅此位置",
    "Bounding box": "边界框",

    # --- JSON 测绘参数描述 ---
    "Hemisphere for position": "位置所在半球",
    "North,South": "北纬,南纬",
    "Altitude for the bottom layer of the structure scan.": "结构扫描底层高度。",
    "Corridor width. Specify 0 width for a single pass scan.": "廊道宽度。设为0表示单次扫描。",
    "Distance between each triggering of the camera. 0 specifies not camera trigger.": "相机触发间隔距离。0表示不触发相机。",
    "Amount of spacing in between parallel grid lines.": "平行航线间距。",
    "Set the current flight speed": "设置当前飞行速度",
    "Camera name.": "相机名称。",
    "Value specified is distance to surface.": "指定值为到表面的距离。",
    "Distance vehicle is away from surface.": "飞行器距地面距离。",
    "Image density at surface.": "地面图像密度。",
    "Amount of overlap between images in the forward facing direction.": "航向前方图像重叠量。",
    "Amount of overlap between images in the side facing direction.": "侧方向图像重叠量。",
    "Distance between approach and land points.": "进近点和降落点之间的距离。",
    "Heading from approach to land point.": "从进近点到降落点的航向。",
    "Altitude to begin landing approach from.": "开始进场降落的高度。",
    "Speed to perform the approach at.": "进场速度。",
    "Loiter radius.": "悬停半径。",
    "Loiter clockwise around the final approach point.": "绕最终进近点顺时针悬停。",
    "Altitude for landing point.": "降落点高度。",
    "The glide slope between the loiter and landing point.": "悬停点和降落点之间的下滑坡度。",
    "Angle for parallel lines of grid.": "平行航线角度。",
    "Fly every other transect in each pass.": "每次飞越间隔测绘线。",
    "Split mission concave polygons into separate regular, convex polygons.": "将航线凹多边形拆分为独立凸多边形。",
    "Stop taking photos": "停止拍照",
    "Stop taking video": "停止录像",

    # --- JSON 通用字段 ---
    "Altitude (rel)": "高度（相对）",
    "Altitude type": "高度类型",
    "Camera action": "相机动作",
    "Camera trigger": "相机触发",
    "Vehicle type": "飞行器类型",
    "Firmware type": "固件类型",
    "Cruise speed": "巡航速度",
    "Hover speed": "悬停速度",
    "Planned home": "规划家点",
    "Terrain altitude": "地形高度",
    "Relative altitude": "相对高度",
    "Approach altitude": "进近高度",
    "Land altitude": "降落高度",
    "Loiter altitude": "悬停高度",
    "Takeoff altitude": "起飞高度",
    "Climb altitude": "爬升高度",
    "Survey area": "测绘区域",
    "Corridor width": "廊道宽度",
    "Grid angle": "航线角度",
    "Grid spacing": "航线间距",
    "Camera angle": "相机角度",
    "Gimbal angle": "云台角度",
    "Photo interval": "拍照间隔",
    "Trigger distance": "触发距离",
    "Trigger type": "触发类型",
    "Time interval": "时间间隔",
    "Distance interval": "距离间隔",
    "Overlap percentage": "重叠百分比",
    "Sidelap percentage": "旁向重叠百分比",
    "Turnaround distance": "转弯距离",
    "Entry point": "进入点",
    "Exit point": "退出点",
    "Start altitude": "起始高度",
    "End altitude": "结束高度",
    "Step size": "步长",
    "Layer count": "层数",
    "Turn type": "转弯类型",
    "Path type": "路径类型",
    "Terrain follow": "地形跟随",
    "Terrain margin": "地形余量",
    "Terrain tolerance": "地形容差",
    "Propagate to all items": "应用到所有项目",
    "Default altitude": "默认高度",
    "Default speed": "默认速度",
    "Vehicle speed": "飞行器速度",
    "Flight speed": "飞行速度",
    "Command this speed": "指令此速度",
    "Speed type": "速度类型",
    "Groundspeed": "地速",
    "AirSpeed": "空速",
    "Climb speed": "爬升速度",
    "Descent speed": "下降速度",
    "RTL speed": "返航速度",
    "Loiter direction": "悬停方向",
    "Clockwise": "顺时针",
    "CounterClockwise": "逆时针",
    "Show in map": "在地图中显示",
    "Show in list": "在列表中显示",
    "Show in 3D": "在3D中显示",
    "Show instrument panel": "显示仪表盘",

    # --- 3D视图 ---
    "3D View": "3D视图",
    "3D view": "3D视图",
    "Track": "跟踪",
    "Orbit": "环绕",
    "Pan": "平移",
    "Zoom": "缩放",
    "Auto Track": "自动跟踪",
    "Auto track": "自动跟踪",
    "Center on vehicle": "居中飞行器",
    "Center on Vehicle": "居中飞行器",
    "View Angle": "视角",
    "View angle": "视角",
    "Field of View": "视场角",
    "Follow vehicle": "跟随飞行器",
    "Lock to vehicle": "锁定飞行器",
    "Free camera": "自由相机",

    # --- 时间/频率 ---
    "2 Min": "2分钟",
    "5 Min": "5分钟",
    "30 ft": "30英尺",

    # --- 状态指示器 ---
    "Link Error": "链路错误",
    "Communication lost": "通信丢失",
    "Communication regained": "通信恢复",
    "command denied": "指令被拒",
    "command failed": "指令失败",
    "(-OFFLINE)": "（离线）",

    # --- 简单/短词 ---
    "Enabled:": "已启用：",
    "Disabled:": "已禁用：",
    "(selected)": "（已选择）",
    "(not set)": "（未设置）",
    "(Param not available)": "（参数不可用）",
    "(Passed)": "（通过）",
    "(Last Scan)": "（上次扫描）",
    "<None>": "（无）",
    "<Untitled>": "（未命名）",
    "<not set>": "（未设置）",
    "hex characters": "十六进制字符",
    "Communication lost": "通信丢失",
    "User Aborted": "用户中止",
    "User canceled": "用户取消",
    "No file": "无文件",
    "Wait...": "请稍候...",
    "Checking...": "检查中...",
    "Loading...": "加载中...",
    "Reading...": "读取中...",
    "Writing...": "写入中...",
    "Processing...": "处理中...",
    "Verifying...": "验证中...",
    "Initializing...": "初始化中...",
    "Updating...": "更新中...",
    "Saving...": "保存中...",
    "Error: Unknown": "错误：未知",
    "Unknown error": "未知错误",
    "Not connected": "未连接",
    "Not available": "不可用",
    "Not supported": "不支持",
    "Not configured": "未配置",
    "Not calibrated": "未校准",
    "Not found": "未找到",
    "Not set": "未设置",
    "Not ready": "未就绪",
    "Not active": "未激活",
    "Not enabled": "未启用",
    "Not installed": "未安装",

    # --- 百分比相关 ---
    "%1%": "%1%%",
    "%1 failed": "%1失败",
    "%1 skipped": "%1已跳过",
    "%1 messages": "%1条消息",
    "%1 axes": "%1轴",
    "%1 buttons": "%1个按钮",
    "%1 effects": "%1个效果",
    "%1 balls": "%1个滚珠",
    "%1 touchpads": "%1个触摸板",
    "%1 Version": "%1版本",
    "%1 Link Error": "%1链路错误",
    "%1Communication lost": "%1通信丢失",
    "%1Communication regained": "%1通信恢复",

    # --- 下载/上传 ---
    "Downloading...": "下载中...",
    "Uploading...": "上传中...",
    "Downloaded": "已下载",
    "Uploaded": "已上传",
    "Abort": "中止",
    "Abort upload": "中止上传",
    "Abort download": "中止下载",

    # --- 加密 ---
    "Encryption": "加密",
    "Decryption": "解密",
    "Encryption Key": "加密密钥",
    "Private Key": "私钥",
    "Public Key": "公钥",
    "Signing": "签名",
    "Signature": "签名",
    "Verify": "验证",
    "Verification": "验证",

    # --- 数据流 ---
    "Raw Sensors": "原始传感器",
    "Extended Status": "扩展状态",
    "RC Channels": "遥控通道",
    "Raw Controller": "原始控制器",
    "Position": "位置",
    "Extra 1": "额外1",
    "Extra 2": "额外2",
    "Extra 3": "额外3",

    # --- 调试值 ---
    "Sensors": "传感器",
    "Sensors Health": "传感器健康",
    "Wind": "风",
    "EKF Values": "EKF值",
    "GPS Info": "GPS信息",
    "GPS Raw": "GPS原始",
    "System Status": "系统状态",
    "Battery Info": "电池信息",
    "Motor Info": "电机信息",
    "Servo Info": "舵机信息",
    "ESC Info": "电调信息",

    # --- 参数前缀 ---
    "Parameter Search": "参数搜索",
    "Search Parameters": "搜索参数",
    "Search...": "搜索...",
    "Compare": "比较",
    "Compare to file": "与文件比较",
    "Compare to vehicle": "与飞行器比较",
    "Clear all": "清除全部",
    "Clear All": "清除全部",
    "Refresh All": "全部刷新",
    "Refresh all": "全部刷新",
    "Group": "分组",
    "Component": "组件",
    "Exclude": "排除",
    "Include": "包含",
    "Reroute": "重新路由",
    "Forward": "转发",
    "Block": "阻止",
    "Reboot Vehicle": "重启飞行器",
    "Shutdown": "关机",
    "Shutdown Vehicle": "关机飞行器",
    "Emergency Kill": "紧急终止",
    "Emergency Stop": "紧急停止",

    # --- "No" 开头的状态 ---
    "No log entries": "无日志条目",
    "No Template": "无模板",
    "No services found on BLE device": "在BLE设备上未找到服务",
    "No services available": "无可用服务",
    "No devices found": "未找到设备",
    "No archive path specified": "未指定归档路径",
    "No template selected": "未选择模板",
    "No matching files found": "未找到匹配文件",
    "No more data": "无更多数据",
    "No valid FMT messages were found": "未找到有效的FMT消息",

    # --- "Not" 开头的状态 ---
    "Not Landed": "未降落",
    "Not Surfaced": "未出水",
    "Not Bottomed": "未触底",
    "Not Supported(Over APM 4.1)": "不支持（APM 4.1以上）",

    # --- "Configure" 配置说明 ---
    "Configure and calibrate Electronic Speed Controllers.": "配置和校准电子调速器。",
    "Configure failsafe actions and leak detection.": "配置故障保护动作和渗漏检测。",
    "Configure battery, GCS, throttle, and EKF failsafes.": "配置电池、地面站、油门和EKF故障保护。",
    "Configure battery, GCS, and throttle failsafes.": "配置电池、地面站和油门故障保护。",
    "Configure battery, GCS, RC, throttle, EKF, and dead reckoning failsafes.": "配置电池、地面站、遥控、油门、EKF和航位推算故障保护。",
    "Configure transmitter switch assignments and flight mode selection.": "配置遥控器开关分配和飞行模式选择。",
    "Configure Return to Launch, geofence, and arming checks.": "配置返航、电子围栏和解锁检查。",
    "Configure camera mount type and stabilization settings.": "配置相机挂载类型和增稳设置。",
    "Configure swashplate, governor, and rotor parameters.": "配置斜盘、调速器和旋翼参数。",
    "Configure light output channels.": "配置灯光输出通道。",
    "Configure ArduPilot logging parameters.": "配置ArduPilot日志参数。",
    "Configure battery monitoring and capacity parameters.": "配置电池监测和容量参数。",
    "Configure transmitter calibration and channel assignment.": "配置遥控器校准和通道分配。",
    "Configure forwarding of MAVLink telemetry to a support engineer.": "配置MAVLink遥测转发给技术支持工程师。",
    "Configure Return to Launch, geofence, and arming checks.": "配置返航、电子围栏和解锁检查。",
    "Configure and calibrate compass, accelerometer, and other onboard sensors.": "配置和校准指南针、加速度计及其他板载传感器。",
    "Configure ArduPilot servo outputs.": "配置ArduPilot舵机输出。",
    "Configure servo PWM limits, trim, direction, and function assignment.": "配置舵机PWM限值、微调、方向和功能分配。",
    "Configure flight performance and controller parameters.": "配置飞行性能和控制器参数。",
    "Configure some outputs in order to test them.": "配置部分输出以便测试。",
    "Configure airspeed sensor type and calibration.": "配置空速传感器类型和校准。",

    # --- "Invalid" 开头的错误 ---
    "Invalid service UUID format: %1": "无效的服务UUID格式：%1",
    "Invalid read characteristic UUID format: %1": "无效的读取特征值UUID格式：%1",
    "Invalid write characteristic UUID format: %1": "无效的写入特征值UUID格式：%1",
    "Invalid Bluetooth address": "无效的蓝牙地址",
    "Invalid address": "无效的地址",
    "Invalid adapter address": "无效的适配器地址",
    "Invalid Nak format": "无效的NAK格式",

    # --- "Set" 开头 ---
    "Set as Home": "设家点",
    "Set to current": "设为当前",
    "Set to default": "设为默认",

    # --- 文件操作 ---
    "Select File": "选择文件",
    "Select Folder": "选择文件夹",
    "Select Directory": "选择目录",
    "Select All": "全选",
    "Deselect All": "取消全选",
    "Invert Selection": "反向选择",
    "Copy to Clipboard": "复制到剪贴板",
    "Copy to clipboard": "复制到剪贴板",

    # --- 界面 ---
    "Are you sure?": "确定吗？",
    "This operation cannot be undone.": "此操作不可撤销。",
    "Do not show again": "不再显示",
    "OK, Got it": "知道了",
    "I understand": "我理解",
    "Show Details": "显示详情",
    "Hide Details": "隐藏详情",
    "More Info": "更多信息",
    "Less Info": "更少信息",

    # --- 调试窗口 ---
    "Debug Window": "调试窗口",
    "MAVLink Console": "MAVLink控制台",
    "MAVLink Inspector": "MAVLink检查器",
    "MAVLink Analyzer": "MAVLink分析器",
    "Messages": "消息",
    "Clear Log": "清除日志",
    "Auto Scroll": "自动滚动",
    "Show Raw": "显示原始数据",
    "Show Decoded": "显示解码数据",
    "Show Hex": "显示十六进制",

    # --- 日志解析 ---
    "Log file :": "日志文件：",
    "File :": "文件：",
    "Time :": "时间：",
    "Duration :": "时长：",
    "Size :": "大小：",
    "Type :": "类型：",
    "Date :": "日期：",
    "Description :": "描述：",
    "Log start": "日志开始",
    "Log end": "日志结束",
    "Num events": "事件数",
    "Data loss": "数据丢失",

    # --- 版本 ---
    "Firmware version": "固件版本",
    "Bootloader version": "引导程序版本",
    "Hardware version": "硬件版本",
    "Software version": "软件版本",
    "OS version": "操作系统版本",
    "Build Time": "构建时间",
    "Git Hash": "Git哈希",

    # --- 单次批量翻译 ---
    "Aborted": "已中止",
    "Accuracy": "精度",
    "Acres": "英亩",
    "Adapter": "适配器",
    "Airship": "飞艇",
    "Antenna": "天线",
    "Approach": "进近",
    "ArduCopter": "ArduCopter",
    "ArduPilot": "ArduPilot",
    "ArduPlane": "ArduPlane",
    "Authentication": "认证",
    "Authorized": "已授权",
    "Auto-detect": "自动检测",
    "AutoConnect": "自动连接",
    "AutoRTL": "自动返航",
    "AutoRotate": "自动旋转",
    "Autoland": "自动降落",
    "Aux1": "辅助1",
    "Aux2": "辅助2",
    "Aux3": "辅助3",
    "Aux4": "辅助4",
    "Aux5": "辅助5",
    "Aux6": "辅助6",
    "Axis": "轴",
    "Backwards": "向后",
    "Baudrate": "波特率",
    "Beep": "蜂鸣",
    "Blend": "混合",
    "Bottomed": "已触底",
    "Breeze": "微风",
    "Broadcast": "广播",
    "Browse": "浏览",
    "Buttons": "按钮",
    "Calculate": "计算",
    "Calibrated": "已校准",
    "Calm": "无风",
    "Canceled": "已取消",
    "Categories": "类别",
    "Center": "中心",
    "Change": "更改",
    "Charting": "制图",
    "Classic": "经典",
    "Coloring": "着色",
    "Configure": "配置",
    "Configuring…": "配置中…",
    "Connecting…": "连接中…",
    "Connection": "连接",
    "Consumed": "已消耗",
    "CrashLogs": "崩溃日志",
    "Cruise": "巡航",
    "Dark": "深色",
    "Date": "日期",
    "Deadband": "死区",
    "Description": "描述",
    "Device": "设备",
    "Disabling…": "禁用中…",
    "Discoverable": "可发现",
    "Dock": "停靠",
    "Downwards": "向下",
    "Downloading": "下载中",
    "Drift": "漂移",
    "Dropouts": "丢帧",
    "Duration": "时长",
    "Easting": "东向坐标",
    "Elapsed": "已用时间",
    "Errors": "错误数",
    "Exporting": "导出中",
    "Failsafes": "故障保护",
    "Fatal": "致命",
    "Fav": "收藏",
    "Favorites": "收藏夹",
    "Features": "功能特性",
    "Fields": "字段",
    "Flash": "闪烁",
    "Fly": "飞行",
    "Flying": "飞行中",
    "Follow": "跟随",
    "Format": "格式",
    "Forwards": "向前",
    "Full": "满",
    "Function": "功能",
    "Gale": "大风",
    "Generate": "生成",
    "Generic": "通用",
    "Geographic": "地理",
    "Geometry": "几何",
    "Good": "良好",
    "Grab": "抓取",
    "Grams": "克",
    "Great": "极好",
    "Gripper": "机械爪",
    "Hectares": "公顷",
    "Hexarotor": "六旋翼",
    "Hide": "隐藏",
    "Id": "标识",
    "Ignore": "忽略",
    "Importing": "导入中",
    "Inputs": "输入",
    "Jamming": "干扰",
    "Kilograms": "公斤",
    "Kite": "风筝",
    "Label": "标签",
    "Landing": "降落中",
    "Leak": "渗漏",
    "Learning": "学习",
    "Leftwards": "向左",
    "Light": "浅色",
    "Links": "链路",
    "Logging": "日志记录中",
    "Low": "低",
    "Mixed": "混合",
    "Mode": "模式",
    "Modes": "模式",
    "Modified": "已修改",
    "Mono": "单声道",
    "Mountpoint": "挂载点",
    "Move": "移动",
    "Multirotor": "多旋翼",
    "Name": "名称",
    "Normal": "正常",
    "Northing": "北向坐标",
    "Octorotor": "八旋翼",
    "One-Sided": "单侧",
    "Orientations": "朝向",
    "Ounces": "盎司",
    "Pair": "配对",
    "Paired": "已配对",
    "Pairing": "配对中",
    "Parity": "校验位",
    "Passphrase": "密码短语",
    "Pause": "暂停",
    "Pixhawk": "Pixhawk",
    "Play": "播放",
    "Player": "播放器",
    "Pounds": "磅",
    "Presets": "预设",
    "Preview": "预览",
    "Processing": "处理中",
    "Propulsion": "推进",
    "Provider": "提供商",
    "Proximity": "近距离",
    "Quadrotor": "四旋翼",
    "Reconnecting…": "重连中…",
    "Release": "释放",
    "Repeat": "重复",
    "Responsiveness": "响应度",
    "Retract": "收回",
    "Retracted": "已收回",
    "Reversed": "已反向",
    "Rightwards": "向右",
    "Rocket": "火箭",
    "Rover-Boat": "无人车-船",
    "Rumble": "震动",
    "Scripting": "脚本",
    "Search": "搜索",
    "Search…": "搜索…",
    "Selected": "已选择",
    "Server": "服务器",
    "Show": "显示",
    "Simple": "简单",
    "Single": "单次",
    "Size": "大小",
    "Skipped": "已跳过",
    "Software": "软件",
    "Spacecraft": "航天器",
    "Spacing": "间距",
    "Spoofing": "欺骗",
    "Stats": "统计",
    "Steering": "转向",
    "Storage": "存储",
    "Storm": "暴风",
    "Surface": "表面",
    "Surfaced": "已出水",
    "Surftrak": "地形跟踪",
    "Temperature": "温度",
    "Thermal": "热成像",
    "Threshold": "阈值",
    "Throw": "抛投",
    "Timeout": "超时",
    "Tolerance": "容差",
    "Touchpad": "触摸板",
    "Training": "训练",
    "Transform": "变换",
    "Triggers": "触发器",
    "Turtle": "龟速",
    "Type": "类型",
    "Unavailable": "不可用",
    "Unhealthy": "不健康",
    "Unpair": "取消配对",
    "Unpaired": "未配对",
    "Unsatisfactory": "不达标",
    "Untitled": "无标题",
    "Upwards": "向上",
    "Value": "值",
    "Velocity": "速度",
    "Video": "视频",
    "Virtual": "虚拟",
    "Weight": "重量",
    "Zone": "区域",
    "boundary": "边界",
    "count": "计数",
    "directly": "直接",
    "filter": "滤波器",
    "id": "标识",
    "labels": "标签",
    "null": "空",
    "primary": "主要",
    "rules": "规则",
    "sec": "秒",
    "secondary": "辅助",
    "trirotor": "三旋翼",
    "AGLC": "AGL校正",
    "AHRS": "航姿参考系统",
    "BLE": "蓝牙低功耗",
    "DGPS": "差分GPS",
    "GPX": "GPX",
    "GUI": "图形界面",
    "IP": "IP",
    "LED": "LED",
    "PID": "PID",
    "RGB": "RGB",
    "RPM": "转/分",
    "RTK": "RTK",
    "SPI": "SPI",
    "SystemID": "系统ID",
    "UART": "UART",
    "ZigZag": "之字形",
    "MGRS": "MGRS",
    "PH": "酸碱度",
    "VR": "VR",
    "Survey-In": "初始定位",
    "Firmware:": "固件：",
    "GPS:": "GPS：",
    "Mode:": "模式：",
    "Name:": "名称：",
    "Path:": "路径：",
    "Size:": "大小：",
    "Time:": "时间：",
    "Total:": "总计：",
    "Type:": "类型：",
    "Speed:": "速度：",
    "Voltage:": "电压：",
    "Altitude:": "高度：",
    "Heading:": "航向：",
    "Channel:": "通道：",
    "Wind:": "风：",
    "Weight:": "重量：",
    "Throttle:": "油门：",
    "Roll:": "横滚：",
    "Pitch:": "俯仰：",
    "Yaw:": "偏航：",

    # --- 剩余常见短语 ---
    "Altitude fence breach": "高度围栏入侵",
    "Circular fence breach": "圆形围栏入侵",
    "Polygon fence breach": "多边形围栏入侵",
    "Altitude and circular fence breach": "高度和圆形围栏入侵",
    "Flight mode change failure": "飞行模式切换失败",
    "Loss of control detected": "检测到失控",
    "Glitch cleared": "抖动已清除",
    "INS delay": "惯导延迟",
    "Parachute not deployed (landed)": "降落伞未打开（已降落）",
    "Parachute not deployed (too low)": "降落伞未打开（高度过低）",
    "WARNING: Remove props prior to calibration!": "警告：校准前请拆下螺旋桨！",
    "WARNING: Props must be removed from vehicle prior to performing": "警告：操作前必须从飞行器上拆下螺旋桨！",
    "Propellers are removed - Enable sliders": "螺旋桨已拆下 - 启用滑块",
    "Vehicle does not support guided rotate": "飞行器不支持引导旋转",
    "Click Calibrate to start, then:": "点击校准开始,然后：",
    "Set Spin Direction 1": "设置旋转方向1",
    "Set Spin Direction 2": "设置旋转方向2",
    "Clicking 'Apply' will save the changes you have made to your": "点击'应用'将保存您所做的更改",
    "Gimbal 1": "云台1",
    "Gimbal 2": "云台2",
    "Battery %1": "电池%1",
    "Battery %1 Source": "电池%1来源",
    "MAVLink Actions": "MAVLink动作",
    "Signing key": "签名密钥",
    "Signing streams": "签名流",
    "Allow <br> takeover": "允许<br>接管",
    "Allow takeover": "允许接管",
    "Write characteristic is not valid": "写入特征值无效",
    "Write queue full, dropping data": "写入队列已满,丢弃数据",
    "Invalid mountpoint name (contains control characters)": "无效的挂载点名称（包含控制字符）",
    "Invalid HTTP response from caster": "来自转发器的HTTP响应无效",
    "Could not create directory %1": "无法创建目录%1",
    "Could not create output directory: %1": "无法创建输出目录：%1",
    "Make sure your BLE device is powered on and advertising": "确保您的蓝牙设备已开机并正在广播",
    "Make sure your Bluetooth device is powered on and discoverable": "确保您的蓝牙设备已开机且可被发现",
    "This will automatically spin individual motors at 15% thrust": "这将自动以15%油门旋转单个电机",
    "This will delete all tiles INCLUDING the tile sets you have": "这将删除所有瓦片,包括您已下载的瓦片集",
    "The image directory doesn't contain supported images.": "图像目录不包含支持的图像。",
    "The log file '%1' is corrupt or empty.": "日志文件'%1'已损坏或为空。",
    "Additional errors received": "收到额外错误",
    "Additional Axis 1": "附加轴1",
    "Allow take over": "允许接管",
    "You must disconnect the battery prior to performing ESC Cali": "执行电调校准前必须断开电池连接",
    "You must choose a board type.": "必须选择板卡类型。",
    "Are you sure you want to delete '%1'?": "确定要删除'%1'吗？",
    "Are you sure you want to remove all the items from the plan ": "确定要从航线中移除所有项目吗？",
    "Flip abandoned": "翻转中止",
    "Variance cleared": "方差已清除",
    "Bad variance": "方差异常",
    "Baro glitch": "气压计异常",
    "Bad depth": "深度异常",
    "Avoid by climb/descend": "通过爬升/下降规避",
    "Avoid by horizontal move": "通过水平移动规避",
    "Avoid perpendicular move": "通过垂直移动规避",
    "RTL invoked": "已启动返航",
    "Missing terrain data": "缺少地形数据",
    "RTL restarted": "返航已重启",
    "Destination outside fence": "目标在围栏外",
    "RTL missing rangefinder": "返航缺少测距仪",
    "1st EKF became primary": "第1个EKF变为主滤波器",
    "2nd EKF became primary": "第2个EKF变为主滤波器",
    "Excessive vibration compensation de-activated": "过激振动补偿已停用",
    "Excessive vibration compensation activated": "过激振动补偿已激活",
    "Internal errors detected": "检测到内部错误",
    "Lost GPS": "GPS丢失",
    "DataFlash file is empty": "DataFlash文件为空",
    "DataFlash file is too large to parse": "DataFlash文件过大无法解析",
    "Output PWM min": "PWM输出最小",
    "Output PWM max": "PWM输出最大",
    "Spin when armed": "解锁后旋转",
    "Spin minimum": "最小转速",
    "Spin maximum": "最大转速",
    "DShot output rate": "DShot输出速率",
    "Now perform these steps:": "现执行以下步骤：",
    "Gimbal configuration": "云台配置",
    "Gimbal settings": "云台设置",
    "Landing gear": "起落架",
    "Landing Gear": "起落架",
    "Retract landing gear": "收起起落架",
    "Deploy landing gear": "放下起落架",
    "Rangefinder": "测距仪",
    "Visual Odometry": "视觉里程计",
    "Proximity Sensor": "接近传感器",
    "GPS yaw": "GPS航向",
    "Wheel Encoder": "轮式编码器",
    "Surface Tracking": "表面跟踪",
    "Circle Mode": "环绕模式",
    "Land Mode": "降落模式",
    "Drift Mode": "漂移模式",
    "Follow Mode": "跟随模式",
    "Simple Mode": "简单模式",
    "ZigZag Mode": "之字模式",
    "Offboard Mode": "板外模式",
    "Throw Mode": "抛飞模式",
    "Payload Mode": "载荷模式",
    "Heavy payload": "重载荷",
    "VTOL Takeoff": "VTOL起飞",
    "VTOL Land": "VTOL降落",
    "Motor arm check": "电机解锁检查",
    "Motor interlock": "电机互锁",
    "Airspeed use": "空速使用",
    "Pre-arm check": "预解锁检查",
    "Mavlink forwarding": "MAVLink转发",
    "Home reset": "家点重置",
    "Mission resume": "航线任务恢复",
    "Mission change": "航线任务变更",
    "Fence breach": "围栏入侵",
    "High voltage": "高电压",
    "Low voltage": "低电压",
    "High current": "大电流",
    "ESC temperature": "电调温度",
    "Battery temperature": "电池温度",
    "GPS glitch": "GPS异常",
    "GPS accuracy": "GPS精度",
    "Unusual speed": "速度异常",
    "Unusual attitude": "姿态异常",
    "Leak detected": "检测到渗漏",
    "Autotune failure": "自动调参失败",
    "Autotune success": "自动调参成功",
    "Component ID": "组件ID",
    "Component id": "组件ID",
    "System id": "系统ID",
    "Custom mode": "自定义模式",
    "Standard mode": "标准模式",
    "Throttle limits": "油门限制",
    "Throttle min": "油门最小",
    "Throttle max": "油门最大",
    "Takeoff complete": "起飞完成",
    "Takeoff aborted": "起飞中止",
    "Land complete": "降落完成",
    "Land aborted": "降落中止",
    "RTL complete": "返航完成",
    "Mission complete": "航线任务完成",
    "Armed:": "已解锁：",
    "Disarmed:": "已上锁：",
    "Battery:": "电池：",
    "Satellites:": "卫星数：",
    "Attitude:": "姿态：",
    "Hover:": "悬停：",
    "Flight time:": "飞行时间：",
    "Battery remaining:": "电池剩余：",
    "Distance to home:": "到家距离：",
    "Distance to next:": "到下一航点：",
    "Ground speed:": "地速：",
    "Air speed:": "空速：",
    "Climb rate:": "爬升率：",
    "Descent rate:": "下降率：",
    "Altitude (MSL):": "高度（海拔）：",
    "Altitude (AGL):": "高度（离地）：",
    "Firmware:": "固件：",
    "Vehicle ID:": "飞行器ID：",
    "Frame:": "机架：",
    "Autopilot:": "飞控：",
    "System:": "系统：",
    "Uptime:": "运行时间：",
    "GPS:": "GPS：",
    "Compass:": "指南针：",
    "Gyro:": "陀螺仪：",
    "Accel:": "加速度计：",
    "Baro:": "气压计：",
    "Airspeed:": "空速：",
    "Battery:": "电池：",
    "Vehicle current telemetry is not available.": "飞行器电流遥测不可用。",
    "Vehicle voltage telemetry is not available.": "飞行器电压遥测不可用。",
    "Device %1 unpaired": "设备%1已取消配对",
    "Subsystem %1": "子系统%1",
    "Increase for more responsiveness, reduce if the attitude ove": "增加可提高响应度,如果姿态超调则减小",
    "Font Point Size 10": "字体点大小10",
    "Font Point Size 10.5": "字体点大小10.5",
    "Flip abandoned": "翻转中止",
    "Variance cleared": "方差已清除",
    "Bad variance": "方差异常",
    "Baro glitch": "气压计异常",
    "Bad depth": "深度异常",
    "Avoid by climb/descend": "通过爬升/下降规避",
    "Avoid by horizontal move": "通过水平移动规避",
    "Avoid perpendicular move": "通过垂直移动规避",
    "RTL invoked": "已启动返航",
    "Missing terrain data": "缺少地形数据",
    "RTL restarted": "返航已重启",
    "Destination outside fence": "目标在围栏外",
    "RTL missing rangefinder": "返航缺少测距仪",
    "1st EKF became primary": "第1个EKF变为主滤波器",
    "2nd EKF became primary": "第2个EKF变为主滤波器",
    "Excessive vibration compensation de-activated": "过激振动补偿已停用",
    "Excessive vibration compensation activated": "过激振动补偿已激活",
    "Internal errors detected": "检测到内部错误",
    "Lost GPS": "GPS丢失",
    "DataFlash file is empty": "DataFlash文件为空",
    "DataFlash file is too large to parse": "DataFlash文件过大无法解析",
    "Output PWM min": "PWM输出最小",
    "Output PWM max": "PWM输出最大",
    "Spin when armed": "解锁后旋转",
    "Spin minimum": "最小转速",
    "Spin maximum": "最大转速",
    "DShot output rate": "DShot输出速率",
    "Now perform these steps:": "现执行以下步骤：",
    "Rangefinder": "测距仪",
    "Visual Odometry": "视觉里程计",
    "GPS yaw": "GPS航向",
    "Wheel Encoder": "轮式编码器",
    "Surface Tracking": "表面跟踪",
    "Circle Mode": "环绕模式",
    "Land Mode": "降落模式",
    "Drift Mode": "漂移模式",
    "Simple Mode": "简单模式",
    "ZigZag Mode": "之字模式",
    "Offboard Mode": "板外模式",
    "Throw Mode": "抛飞模式",
    "Payload Mode": "载荷模式",
    "VTOL Takeoff": "VTOL起飞",
    "VTOL Land": "VTOL降落",
    "Fence breach": "围栏入侵",
    "High voltage": "高电压",
    "Low voltage": "低电压",
    "High current": "大电流",
    "ESC temperature": "电调温度",
    "Battery temperature": "电池温度",
    "GPS glitch": "GPS异常",
    "GPS accuracy": "GPS精度",
    "Unusual speed": "速度异常",
    "Unusual attitude": "姿态异常",
    "Leak detected": "检测到渗漏",
    "Autotune failure": "自动调参失败",
    "Autotune success": "自动调参成功",
    "Code %1": "代码%1",
    "Event %1": "事件%1",
    "Mode: %1": "模式：%1",
    "GPS: %1": "GPS：%1",
    "Failed to download %1": "下载%1失败",
    "Failed to list %1": "列出%1失败",
    "RTK status:": "RTK状态：",
    "Survey-in accuracy:": "初始定位精度：",
    "Observation time:": "观测时间：",
}



# ==============================================================================
# 正则模式翻译规则
# ==============================================================================

def _translate_part(part: str) -> str:
    """尝试查找单个词/短语的翻译。"""
    if part in PHRASES:
        return PHRASES[part]
    # 大小写不敏感查找
    for k, v in PHRASES.items():
        if k.lower() == part.lower():
            return v
    return part


PATTERNS: list[tuple[re.Pattern, str]] = [
    # PID控制器
    (re.compile(r"^(\w+) axis angle controller (P|I|D|PI|PD) gain$"), "{0}轴角度控制器{1}增益"),
    (re.compile(r"^(\w+) axis rate controller (P|I|D|PI|PD) gain$"), "{0}轴速率控制器{1}增益"),

    # 传感器
    (re.compile(r"^(Primary|Secondary|Third|Backup) (\w+) Sensor$", re.I), "{0}{1}传感器"),

    # 故障保护
    (re.compile(r"^(Low|High|Critical|Emergency) (.+) Failsafe$", re.I), "{0}{1}故障保护"),
    (re.compile(r"^(.+) Failsafe Action$", re.I), "{0}故障保护动作"),

    # 日志项 (DataFlash log parser)
    (re.compile(r"^(Radio|GPS|Fence|EKF|ADSB|Leak|Crash|Terrain|Thrust|Pilot|Motor|Servo|Calibration|Rangefinder|Optflow)\s+(.+)$"),
     "{0}{1}"),
    (re.compile(r"^([a-zA-Z]+)\s+Check$"), "{0}检查"),
    (re.compile(r"^(Autotune|Parachute|Flip)$"), "{0}"),

    # 空速相关
    (re.compile(r"^(Cruise|Minimum|Maximum|Stall|Min|Max)\s+airspeed$", re.I), "{0}空速"),
    (re.compile(r"^Airspeed\s+(.+)$", re.I), "空速{0}"),
    (re.compile(r"^(.+)\sairspeed$", re.I), "{0}空速"),

    # 通道
    (re.compile(r"^Channel (\d+)$", re.I), "通道{0}"),

    # 对话框
    (re.compile(r"^Calculate (.+)$"), "计算{0}"),
    (re.compile(r"^Measured (.+):$"), "测量{0}："),

    # 日志条目（简易匹配）
    (re.compile(r"^([A-Z][a-z]+ [A-Z][a-z]+)$"), "{0}"),  # 保持专有名词不变

    # N/A
    (re.compile(r"^N/A$", re.I), "无"),

    # 蓝牙配置
    (re.compile(r"^(.+) Service$"), "{0}服务"),
    (re.compile(r"^(.+) Characteristic$"), "{0}特征值"),

    # PID 术语
    (re.compile(r"^Integral\s+(.+)$", re.I), "积分{0}"),
    (re.compile(r"^Proportional\s+(.+)$", re.I), "比例{0}"),
    (re.compile(r"^Differential\s+(.+)$", re.I), "微分{0}"),

    # "无"开头
    (re.compile(r"^No\s+(.+)$", re.I), "无{0}"),
    (re.compile(r"^Not\s+(.+)$", re.I), "未{0}"),

    # 配置
    (re.compile(r"^Configure (.+)$", re.I), "配置{0}"),

    # 文件操作
    (re.compile(r"^File open failed: (.+)$", re.I), "文件打开失败：{0}"),
    (re.compile(r"^File (.+) failed: (.+)$", re.I), "文件{0}失败：{1}"),
    (re.compile(r"^File (.+) does not exist$", re.I), "文件{0}不存在"),
    (re.compile(r"^Unable to open file: (.+)$", re.I), "无法打开文件：{0}"),
    (re.compile(r"^Failed to download (.+)$", re.I), "下载{0}失败"),
    (re.compile(r"^Failed to list (.+)$", re.I), "列出{0}失败"),

    # 操作指南
    (re.compile(r"^You must (.+)$", re.I), "必须{0}"),
    (re.compile(r"^Move the (.+)$", re.I), "移动{0}"),
    (re.compile(r"^Move (.+)$", re.I), "移动{0}"),
    (re.compile(r"^Make sure (.+)$", re.I), "确保{0}"),
    (re.compile(r"^Are you sure you want to (.+)$", re.I), "确定要{0}吗？"),

    # 地理标签
    (re.compile(r"^Geotagging failed\. (.+)$", re.I), "地理标签失败。{0}"),

    # 上传/下载/列表失败
    (re.compile(r"^Upload failed for: (.+)$", re.I), "上传失败：{0}"),
    (re.compile(r"^Failed to ([^:]+)$", re.I), "{0}失败"),

    # AUX通道
    (re.compile(r"^Aux (\d+)$", re.I), "辅助{0}"),

    # 字体
    (re.compile(r"^Font (.+)$", re.I), "字体{0}"),

    # 增加/减少
    (re.compile(r"^Increase (.+)$", re.I), "增加{0}"),
    (re.compile(r"^Reduce (.+)$", re.I), "减小{0}"),

    # 电池
    (re.compile(r"^Battery (\d+) (.+)$", re.I), "电池{0}{1}"),

    # JSON 条件
    (re.compile(r"^If the (.+) is (.+)$", re.I), "如果{0}为{1},则"),
    (re.compile(r"^If (.+) is (.+)$", re.I), "如果{0}为{1},则"),
    (re.compile(r"^When (.+) is (.+)$", re.I), "当{0}为{1}时"),
    (re.compile(r"^Automatically (.+)$", re.I), "自动{0}"),

    # JSON 描述
    (re.compile(r"^Comma separated (.+)$", re.I), "逗号分隔的{0}"),
    (re.compile(r"^Fixed (.+)$", re.I), "固定{0}"),

    # 参数文件下载错误
    (re.compile(r"^(Param|Parameter|Log|File) (download|upload|load|save) failed: (.+)$", re.I), "{0}{1}失败：{2}"),
    (re.compile(r"^(Param|Parameter|Log|File) (download|upload|load|save) failed to start: (.+)$", re.I), "{0}{1}启动失败：{2}"),

    # 操作失败
    (re.compile(r"^Failed to ([^.!?]+)[.!?]?$", re.I), "{0}失败"),
    (re.compile(r"^Unable to (.+)$", re.I), "无法{0}"),
    (re.compile(r"^Could not (.+)$", re.I), "无法{0}"),

    # 错误
    (re.compile(r"^Error (.+) loading (.+)$", re.I), "加载{1}时出错：{0}"),
    (re.compile(r"^(.+) error$", re.I), "{0}错误"),

    # 点击操作
    (re.compile(r"^Click to (.+)$", re.I), "点击{0}"),

    # 配置
    (re.compile(r"^Configure the (.+)$", re.I), "配置{0}"),

    # 计数
    (re.compile(r"^Number of (.+)$", re.I), "{0}数量"),
    (re.compile(r"^Count of (.+)$", re.I), "{0}计数"),

    # 启用/禁用/使用
    (re.compile(r"^Use (.+)$", re.I), "使用{0}"),
    (re.compile(r"^Enable (.+)$", re.I), "启用{0}"),
    (re.compile(r"^Disable (.+)$", re.I), "禁用{0}"),

    # 范围与最小值/最大值
    (re.compile(r"^(Minimum|Maximum) (.+) value$", re.I), "{0}{1}值"),
    (re.compile(r"^(Minimum|Maximum) (.+) parameter$", re.I), "{0}{1}参数"),
    (re.compile(r"^Scale the (.+) range$", re.I), "缩放{0}范围"),

    # 位置
    (re.compile(r"^Latitude of (.+) position$", re.I), "{0}纬度"),
    (re.compile(r"^Longitude of (.+) position$", re.I), "{0}经度"),
    (re.compile(r"^Easting of (.+) position$", re.I), "{0}东向坐标"),
    (re.compile(r"^Northing of (.+) position$", re.I), "{0}北向坐标"),
    (re.compile(r"^(.+) of item position$", re.I), "航点{0}"),

    # 云台旋转
    (re.compile(r"^(\w+) (pitch|yaw|roll) rotation\.$", re.I), "{0}{1}旋转。"),
    (re.compile(r"^(\w+) (pitch|yaw|roll) rotation$", re.I), "{0}{1}旋转"),

    # 相机操作
    (re.compile(r"^Specify whether the camera should take (.+) or (.+)$", re.I), "指定相机拍摄{0}或{1}"),
    (re.compile(r"^Specify the distance between each (.+)$", re.I), "指定每个{0}间距"),
    (re.compile(r"^Specify the time between each (.+)$", re.I), "指定每个{0}时间间隔"),

    # 测绘/航线
    (re.compile(r"^Stop and Hover at each (.+) point before taking (.+)$", re.I), "在每个{0}点停稳悬停后拍摄{1}"),
    (re.compile(r"^(.+) continues taking images in turn arounds\.$", re.I), "{0}在转弯时继续拍摄。"),
    (re.compile(r"^Refly the pattern at a (\d+) degree angle$", re.I), "以{0}度角重飞航线"),

    # RC输出相关
    (re.compile(r"^(.+) value when RC output is (\d+)$", re.I), "遥控输出为{1}时的{0}值"),
]


def _translate_group(g: str) -> str:
    """翻译正则匹配的分组内容。"""
    # 去除尾部标点以便查找
    clean = g.rstrip('.,;:!?)]}')
    punct = g[len(clean):]
    if clean in PHRASES:
        return PHRASES[clean] + punct
    # 大小写不敏感
    for k, v in PHRASES.items():
        if k.lower() == clean.lower():
            return v + punct
    # 逐词尝试
    words = clean.split()
    if len(words) <= 4:
        result = []
        for w in words:
            tw = _translate_part(w)
            if tw == w:
                return g  # 有词无法翻译,放弃
            result.append(tw)
        return ' '.join(result)
    return g


# ==============================================================================
# 工具函数
# ==============================================================================

def _contains_chinese(text: str) -> bool:
    return bool(re.search(r'[一-鿿㐀-䶿]', text))


def _is_param_name(text: str) -> bool:
    return bool(re.match(r'^[A-Z][A-Z0-9_]{2,}$', text))


def _is_pure_number_or_symbol(text: str) -> bool:
    return bool(re.match(r'^[\d\s,.%°\'"±×\-■–—/\\<>=+()\[\]{}]+$', text.strip()))


def _has_placeholder(text: str) -> bool:
    return '%' in text or '%1' in text or '%2' in text or '%3' in text


# ==============================================================================
# 主翻译引擎
# ==============================================================================

def translate_string(source: str, context: str = "") -> str:
    """将英文字符串翻译为中文。"""
    s = source.strip()

    # --- 跳过处理 ---
    if not s:
        return s
    if _contains_chinese(s):
        return s  # 已有中文
    if _is_pure_number_or_symbol(s):
        return s
    if context == "FactMetaData" and _is_param_name(s):
        return s  # 参数名不翻译
    if s.startswith('/') or s.startswith('./') or s.startswith(':/') or s.startswith('http'):
        return s  # 路径/URL不翻译

    # --- 1. 精确短语匹配 ---
    if s in PHRASES:
        return PHRASES[s]

    # --- 2. 含占位符的短语匹配（忽略%1、%2等动态部分）---
    if _has_placeholder(s):
        return s  # 已通过精确匹配处理

    # --- 3. 正则模式匹配 ---
    for pattern, template in PATTERNS:
        m = pattern.fullmatch(s)
        if m:
            groups = m.groups()
            # 翻译每个分组
            translated_groups = [_translate_group(g) for g in groups]
            result = template.format(*translated_groups)
            if result != s:
                return result

    # --- 4. 保守逐词翻译（≤4词,所有词都必须可译） ---
    words = s.split()
    if 1 <= len(words) <= 4 and len(s) < 80:
        translated_parts = []
        all_found = True
        for w in words:
            clean = w.strip('.,;:!?()[]{}\'"\'""')
            punct_before = w[:len(w)-len(clean)]
            punct_after = w[len(clean):]
            t = _translate_part(clean)
            # 如果词以大写字母开头但找不到,尝试小写
            if t == clean and clean[0:1].isupper():
                t = _translate_part(clean[0].lower() + clean[1:])
            if t == clean:
                all_found = False
                break
            translated_parts.append(punct_before + t + punct_after)
        if all_found:
            result = ''.join(translated_parts)
            if result != s:
                return result

    # --- 5. 更简单的词替换 - 仅当字符串简短且大部分可译 ---
    if len(s) < 120 and len(words) <= 8:
        translated_parts = []
        known_count = 0
        for w in words:
            clean = w.strip('.,;:!?()[]{}\'"')
            t = _translate_part(clean) if clean else clean
            if t != clean:
                known_count += 1
        # 如果超过60%的词可译,尝试翻译
        if known_count >= max(2, len(words) * 0.6):
            for w in words:
                clean = w.strip('.,;:!?()[]{}\'"')
                punct_before = w[:len(w)-len(clean)]
                punct_after = w[len(clean):]
                t = _translate_part(clean)
                if t == clean and clean[0:1].isupper():
                    t = _translate_part(clean[0].lower() + clean[1:])
                if t == clean:
                    translated_parts.append(w)
                else:
                    translated_parts.append(punct_before + t + punct_after)
            result = ' '.join(translated_parts)
            if result != s:
                return result

    # --- 无法翻译,返回原文 ---
    return s


# ==============================================================================
# .ts 文件处理
# ==============================================================================

def process_ts_file(ts_path: Path, file_label: str) -> int:
    """处理一个 .ts 文件,翻译所有未完成的条目。"""
    print(f"\n{'='*60}")
    print(f"处理: {file_label}")
    print(f"路径: {ts_path}")
    print(f"{'='*60}")

    # 读取并解析
    tree = ET.parse(str(ts_path))
    root = tree.getroot()

    unfinished_count = 0
    translated_count = 0
    skipped_count = 0

    for context in root:
        ctx_name = context.get('name', '')
        for msg in context:
            if msg.tag != 'message':
                continue
            source_elem = msg.find('source')
            trans_elem = msg.find('translation')
            if source_elem is None or trans_elem is None:
                continue

            source = source_elem.text or ''
            is_unfinished = trans_elem.get('type') == 'unfinished'

            if not is_unfinished:
                continue

            unfinished_count += 1
            translation = translate_string(source, ctx_name)

            if translation == source or translation == '':
                skipped_count += 1
                continue

            trans_elem.text = translation
            if 'type' in trans_elem.attrib:
                del trans_elem.attrib['type']
            translated_count += 1

            if translated_count <= 8:
                src_short = source[:55] + '...' if len(source) > 58 else source
                print(f"  ✓ \"{src_short}\"")

    # 写回
    if translated_count > 0:
        xml_bytes = ET.tostring(root, encoding='unicode', xml_declaration=True)
        # 确保正确格式
        xml_bytes = xml_bytes.replace("<?xml version='1.0' encoding='utf-8'?>",
                                      '<?xml version="1.0" encoding="utf-8"?>')
        ts_path.write_text(xml_bytes, encoding='utf-8')

    print(f"\n结果: {translated_count}/{unfinished_count} 已翻译 ({skipped_count} 跳过)")
    return translated_count


def main():
    print("QGC 中文翻译工具")
    print("=" * 60)

    total = 0
    for ts_path, label in [
        (TS_SOURCE, "源字符串 (qgc_source_zh_CN.ts)"),
        (TS_JSON, "JSON 字符串 (qgc_json_zh_CN.ts)"),
    ]:
        if not ts_path.exists():
            print(f"错误: 找不到 {ts_path}")
            continue
        count = process_ts_file(ts_path, label)
        total += count

    print(f"\n{'='*60}")
    print(f"总计翻译: {total} 条字符串")
    print(f"{'='*60}")


if __name__ == '__main__':
    main()
