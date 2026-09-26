import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

SettingsGroupLayout {
    id:                     _root
    Layout.fillWidth:       true
    heading:                qsTr("Return to Launch")
    // 联网运营模式下不下载参数 ⇒ rtlAltFact 为空，整组没有可编辑内容。
    // ‼️ 这个 visible 只是"不显示"；下面的绑定照常求值，所以每处读 rtlAltFact 的地方都另有空判。
    visible:                activeVehicle.multiRotor && rtlAltFact !== null

    property var activeVehicle: QGroundControl.multiVehicleManager.activeVehicle
    // 第三参必须显式给 false：缺省是 true，缺参数时会**自己触发**一次缺失参数聚合告警。
    property Fact rtlAltFact: controller.getParameterFact(-1, "RTL_ALT_M", false)
    // RTL_ALT_M (4.7+) is in meters, RTL_ALT (pre-4.7) is in centimeters
    property bool _rtlAltIsMeters: controller.parameterExists(-1, "noremap.RTL_ALT_M")

    FactPanelController { id: controller }

    RowLayout {
        Layout.fillWidth:   true
        spacing:            ScreenTools.defaultFontPixelWidth * 2

        QGCLabel {
            id:                 label
            Layout.fillWidth:   true
            text:               qsTr("Return At")
        }

        QGCComboBox {
            id:             returnAtCombo
            sizeToContents: true
            model:          [ qsTr("Current altitude"), qsTr("Specified altitude") ]

            function setCurrentIndex() {
                // 参数没下来（运营模式）时 rtlAltFact 为空。Component.onCompleted 会**无条件**调本函数，
                // 所以这个空判是必需的，不是防御性冗余 —— 少了它就是一条必现的 QML TypeError。
                if (!_root.rtlAltFact) {
                    return
                }
                if (_root.rtlAltFact.value === 0) {
                    returnAtCombo.currentIndex = 0
                } else {
                    returnAtCombo.currentIndex = 1
                }
            }

            Component.onCompleted: setCurrentIndex()

            onActivated: (index) => {
                if (!_root.rtlAltFact) {
                    return
                }
                if (index === 0) {
                    _root.rtlAltFact.rawValue = 0
                } else {
                    // RTL_ALT_M (4.7+) is in meters, RTL_ALT (pre-4.7) is in centimeters
                    _root.rtlAltFact.rawValue = _root._rtlAltIsMeters ? 15 : 1500
                }
            }

            Connections {
                target:             _root.rtlAltFact
                onRawValueChanged:  returnAtCombo.setCurrentIndex()
            }
        }

        FactTextField {
            fact:       _root.rtlAltFact
            enabled:    _root.rtlAltFact !== null && _root.rtlAltFact.rawValue !== 0
        }
    }
}
