#!/usr/bin/env python3
"""Fix the last remaining untranslated multi-line strings."""
from xml.etree import ElementTree as ET

SRC_TS = 'translations/qgc_source_zh_CN.ts'
JSON_TS = 'translations/qgc_json_zh_CN.ts'

# Multi-line translations keyed by (context, source_text)
ml_map = {}

def add(ctx, src, trans):
    ml_map[(ctx, src)] = trans

add('AltitudeFactTextField', '%1', '%1')
add('AudioOutput', '%1', '%1')
add('GeoTagPage', 'ULog (*.ulg)', 'ULog文件(*.ulg)')
add('GeoTagPage', 'DataFlash (*.bin)', 'DataFlash文件(*.bin)')
add('JoystickComponentSummary', '%1%', '%1%')
add('JoystickIndicator', '%1%', '%1%')
add('NmeaGpsSettings', 'NMEA GPS', 'NMEA GPS')
add('TransformEditor', 'MGRS', 'MGRS')

add('MotorAssignment',
    '<br />No motors are assigned yet.\nBy saying yes, all motors will be assigned to the first %1 channels of the selected output (%2)\n (you can also first assign all motors, then start the identification).<br />',
    '<br />尚未分配任何电机。\n确认后,所有电机将被分配到所选输出(%2)的前%1个通道\n（您也可以先分配所有电机,然后开始识别）。<br />')

add('MotorAssignment',
    '<br />Motors are currently assigned to a different output.\nBy saying yes, all motors will be reassigned to the first %1 channels of the selected output (%2).<br />',
    '<br />电机当前已分配到另一个输出。\n确认后,所有电机将被重新分配到所选输出(%2)的前%1个通道。<br />')

add('MotorAssignment',
    'This will automatically spin individual motors at 15% thrust.<br /><br />\n<b>Warning: Only proceed if you removed all propellers</b>.<br />\n%1\n<br />\nThe procedure is as following:<br />\n- After confirming, the first motor starts to spin for 0.5 seconds.<br />\n- Then click on the motor that was spinning.<br />\n- The above steps are repeated for all motors.<br />\n- The motor output functions will automatically be reassigned by the selected order.<br />\n<br />\nDo you wish to proceed?',
    '这将自动以15%油门逐个旋转电机。<br /><br />\n<b>警告：仅在已拆除所有螺旋桨的情况下继续</b>。<br />\n%1\n<br />\n步骤如下：<br />\n- 确认后,第一个电机开始旋转0.5秒。<br />\n- 然后点击正在旋转的电机。<br />\n- 对所有电机重复上述步骤。<br />\n- 电机输出功能将按所选顺序自动重新分配。<br />\n<br />\n是否继续？')

add('OfflineMapEditor',
    'This will delete all tiles INCLUDING the tile sets you have created yourself.\n\nIs this really what you want?',
    '这将删除所有瓦片,包括您自己创建的瓦片集。\n\n确定要这样做吗？')

add('OfflineMapEditor',
    'Delete %1 and all its tiles.\n\nIs this really what you want?',
    '删除%1及其所有瓦片。\n\n确定要这样做吗？')

add('ParameterEditor',
    'Select Reset to reset all parameters to their defaults.\n\nNote that this will also completely reset everything, including UAVCAN nodes, all vehicle settings, setup and calibrations.',
    '选择Reset将恢复所有参数为默认值。\n\n请注意,这也会完全重置所有内容,包括UAVCAN节点、所有飞行器设置、配置和校准。')

add('PlanView',
    'This Plan was created for a different firmware or vehicle type than the firmware/vehicle type of vehicle you are uploading to. This can lead to errors or incorrect behavior. It is recommended to recreate the Plan for the correct firmware/vehicle type.\n\nClick \'Ok\' to upload the Plan anyway.',
    '此航线规划使用的固件或飞行器类型与您上传目标不匹配。这可能导致错误或异常行为。建议为正确的固件/飞行器类型重新创建航线规划。\n\n点击Ok仍上传此航线规划。')

add('RemoteControlCalibration',
    'Before calibrating you should zero all your trims and subtrims. Click Ok to start Calibration.\n\n%1',
    '校准前请将所有微调和副微调归零。点击Ok开始校准。\n\n%1')

add('RemoteControlCalibrationController',
    '* Lower the Throttle stick all the way down as shown in diagram\n* Please ensure all motor power is disconnected AND all props are removed from the vehicle.\n* Click Next to continue',
    '* 将油门杆完全拉下,如图所示\n* 请确保所有电机电源已断开且所有螺旋桨已从飞行器上拆除\n* 点击Next继续')

add('RemoteControlCalibrationController',
    '* Center all sticks as shown in diagram.\n* Make sure any additional axes are at a neutral position.\n* Please ensure all motor power is disconnected from the vehicle.\n* Click Next to continue',
    '* 将所有摇杆回中,如图所示。\n* 确保所有附加轴处于中位。\n* 请确保所有电机电源已从飞行器断开。\n* 点击Next继续')

add('RemoteControlCalibrationController',
    '* Move the %1 Extension stick to its low value position and hold it there...\n* Select \'One-Sided\' for controls like gamepad triggers.',
    '* 将%1扩展摇杆移至最低位置并保持住...\n* 对于游戏手柄扳机等控件,选择One-Sided。')

add('SensorsSetup',
    'Adjust orientations as needed.\n\nROTATION_NONE indicates component points in direction of flight.',
    '根据需要调整朝向。\n\nROTATION_NONE表示组件指向飞行方向。')

add('SigningKeyManager',
    'Vehicle is armed. ArduPilot will refuse to disable signing while armed and PX4 will not accept the disable packet without a valid signature. The disable attempt will likely time out and leave the link in an inconsistent state.\n\nDisarm the vehicle first.',
    '飞行器已解锁。ArduPilot在解锁状态拒绝禁用签名,PX4无有效签名时不接受禁用数据包。禁用尝试将超时,导致链路不一致。\n\n请先上锁飞行器。')

add('SigningKeyManager',
    "Are you sure you want to delete '%1'?\n\nIf a vehicle still has this key configured, you will no longer be able to communicate with it over a signed connection. Raw or generated keys cannot be recovered — Export the hex first if you may need it later.",
    "确定要删除'%1'吗？\n\n如果飞行器仍配置此密钥,将无法通过签名连接与之通信。原始或生成的密钥无法恢复——如果以后可能需要,请先导出十六进制密钥。")

# Video long technical descriptions
add('Video.SettingsGroup.json',
    'By default, when a hardware decoder produces GPU-backed frames (DMABuf, GLMemory, D3D11, IOSurface, AHardwareBuffer), the pipeline imports them directly into Qt\'s render thread to avoid a per-frame CPU copy. The pipeline already falls back to the CPU path automatically when a GPU import fails, so this option is only needed for debugging or to work around a broken driver.',
    '默认情况下,硬件解码器生成GPU帧(DMABuf/GLMemory/D3D11/IOSurface/AHardwareBuffer)时直接导入Qt渲染线程,避免每帧CPU拷贝。GPU导入失败时自动回退CPU路径,此选项仅用于调试或绕开驱动缺陷。')

add('Video.SettingsGroup.json',
    'Leave blank to auto-probe (SoC-native imxvideoconvert_g2d / nvvidconv when present, otherwise videoconvert). Set to a specific GStreamer factory name to force that element. Used as a workaround when an SoC\'s preferred element has a defect; takes effect on next stream restart.',
    '留空自动探测(优先SoC原生imxvideoconvert_g2d/nvvidconv,否则videoconvert)。设为特定GStreamer工厂名以强制使用该元件。当SoC首选元件存在缺陷时作为解决方案；下次流重启后生效。')

add('Video.SettingsGroup.json',
    "QGC normally inserts a pixel-aspect-ratio=1/1 capsfilter so non-square-pixel sources (some RTSP cams, DVB) don't render geometrically distorted. A few v4l2 drivers without VIDIOC_CROPCAP deadlock negotiation when PAR is forced; enable this option as a workaround. Takes effect on next stream restart.",
    'QGC通常插入像素宽高比1:1的capsfilter,确保非方形像素源(部分RTSP摄像头、DVB)渲染无几何畸变。部分无VIDIOC_CROPCAP的v4l2驱动在强制PAR时协商死锁；启用此选项作为解决方案。下次流重启后生效。')

# Apply
for ts_path, label in [(SRC_TS, 'Source'), (JSON_TS, 'JSON')]:
    tree = ET.parse(ts_path)
    root = tree.getroot()
    applied = 0
    for context in root:
        ctx_name = context.findtext('name', '')
        for msg in context:
            if msg.tag != 'message': continue
            se = msg.find('source')
            te = msg.find('translation')
            if se is None or te is None: continue
            source = se.text or ''
            if te.get('type') != 'unfinished': continue
            key = (ctx_name, source)
            if key in ml_map:
                te.text = ml_map[key]
                if 'type' in te.attrib: del te.attrib['type']
                applied += 1
    tree.write(ts_path, encoding='utf-8', xml_declaration=True)
    print(f'{label}: Applied {applied}')

# Final count
for ts_path, label in [(SRC_TS, 'Source'), (JSON_TS, 'JSON')]:
    tree = ET.parse(ts_path)
    cnt = total = 0
    for ctx in tree.getroot():
        for msg in ctx:
            if msg.tag != 'message': continue
            total += 1
            t = msg.find('translation')
            if t is not None and t.get('type') == 'unfinished':
                cnt += 1
    print(f'{label}: {cnt}/{total} ({100*(total-cnt)/total:.1f}% done)')
