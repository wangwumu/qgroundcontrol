import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

ColumnLayout {
    id:                     _root
    Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 60
    spacing:                margins / 2

    property Fact mpcLandSpeedFact:         controller.getParameterFact(-1, "MPC_LAND_SPEED", false)
    property Fact precisionLandingFact:     controller.getParameterFact(-1, "RTL_PLD_MD", false)
    property Fact sys_vehicle_resp:         controller.getParameterFact(-1, "SYS_VEHICLE_RESP", false)
    property Fact mpc_xy_vel_all:           controller.getParameterFact(-1, "MPC_XY_VEL_ALL", false)
    property Fact mpc_z_vel_all:            controller.getParameterFact(-1, "MPC_Z_VEL_ALL", false)
    // 联网运营模式下**不下载参数**（见 ParameterManager 里与 isHighLatency 并列的那道判据）
    // ⇒ 下面这几个 Fact 在网络模式下都会是空。第三参必须显式给 false：缺省是 true，缺参数时会
    // **自己触发**一次缺失参数聚合告警（本文件是 FirmwarePlugin 真正加载的那个指示器，不是死文件）。
    property Fact rtlReturnAltFact:         controller.getParameterFact(-1, "RTL_RETURN_ALT", false)
    property Fact gfActionFact:             controller.getParameterFact(-1, "GF_ACTION", false)
    property Fact gfMaxHorDistFact:         controller.getParameterFact(-1, "GF_MAX_HOR_DIST", false)
    property Fact gfMaxVerDistFact:         controller.getParameterFact(-1, "GF_MAX_VER_DIST", false)
    property var  qgcPal:                   QGroundControl.globalPalette
    property real margins:                  ScreenTools.defaultFontPixelHeight
    property real sliderWidth:              ScreenTools.defaultFontPixelWidth * 40
    property var  flyViewSettings:          QGroundControl.settingsManager.flyViewSettings

    FactPanelController { id: controller }

    SettingsGroupLayout {
        Layout.fillWidth: true
        // 参数没下来（运营模式）⇒ 整组隐藏。
        // ‼️ visible **拦不住绑定求值** ⇒ 下面 FactSlider 自己那条 to: 里的空判是必需的，不是冗余：
        //    它引用的是 FactSlider 的 fact 属性（null），不是内部的 _nullFact 兜底。
        visible:            _root.rtlReturnAltFact !== null

        FactSlider {
            Layout.fillWidth:       true
            Layout.preferredWidth:  _root.sliderWidth
            label:                  qsTr("RTL Altitude")
            fact:                   _root.rtlReturnAltFact
            to:                     _root.rtlReturnAltFact ? (_root.rtlReturnAltFact.maxIsDefaultForType ? _root.rtlReturnAltFact.rawToCooked(121.92) : _root.rtlReturnAltFact.max) : 0
            majorTickStepSize:      10
        }
    }

    SettingsGroupLayout {
        Layout.fillWidth:   true
        heading:            qsTr("GeoFence")
        // 三个 Fact 全空才隐藏整组 —— 固件可能只提供其中一部分，不能拿任意一个当代表。
        visible:            _root.gfActionFact !== null || _root.gfMaxHorDistFact !== null || _root.gfMaxVerDistFact !== null

        LabelledFactComboBox {
            Layout.fillWidth:       true
            label:                  qsTr("Breach Action")
            fact:                   _root.gfActionFact
        }

        ColumnLayout {
            QGCCheckBoxSlider {
                Layout.fillWidth:   true
                text:               qsTr("Max Distance")
                checked:            maxDistanceSlider.value > 0

                onClicked: {
                    if (checked) {
                        maxDistanceSlider.setValue(prevValue != 0 ? prevValue : maxDistanceSlider.to)
                    } else {
                        prevValue = maxDistanceSlider.value
                        maxDistanceSlider.setValue(0)
                    }
                }

                property real prevValue: 0
            }

            FactSlider {
                id:                 maxDistanceSlider
                Layout.fillWidth:   true
                fact:               _root.gfMaxHorDistFact
                to:                 _root.flyViewSettings.maxGoToLocationDistance.value
                majorTickStepSize:  500
                enabled:            fact !== null && fact.value > 0
            }
        }

        ColumnLayout {
            QGCCheckBoxSlider {
                Layout.fillWidth:   true
                text:               qsTr("Max Altitude")
                checked:            maxAltitudeSlider.value > 0

                onClicked: {
                    if (checked) {
                        maxAltitudeSlider.setValue(prevValue != 0 ? prevValue : maxAltitudeSlider.to)
                    } else {
                        prevValue = maxAltitudeSlider.value
                        maxAltitudeSlider.setValue(0)
                    }
                }

                property real prevValue: 0
            }

            FactSlider {
                id:                 maxAltitudeSlider
                Layout.fillWidth:   true
                fact:               _root.gfMaxVerDistFact
                // Setting is "vertical m" family, slider fact may cook differently - convert through the fact's own translator
                to:                 fact ? fact.rawToCooked(_root.flyViewSettings.guidedMaximumAltitude.rawValue) : 0
                majorTickStepSize:  10
                enabled:            fact !== null && fact.value > 0
            }
        }
    }
}
