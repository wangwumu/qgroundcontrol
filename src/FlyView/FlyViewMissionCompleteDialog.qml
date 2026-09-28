import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// Dialog which shows up when a flight completes. Prompts the user for things like whether they should remove the plan from the vehicle.
Item {
    id:      missionCompleteDialogHelper
    visible: false

    property var missionController
    property var geoFenceController
    property var rallyPointController

    // The following code is used to track vehicle states for showing the mission complete dialog
    property var  _activeVehicle:                   QGroundControl.multiVehicleManager.activeVehicle
    property bool _vehicleArmed:                    _activeVehicle ? _activeVehicle.armed : true // true here prevents pop up from showing during shutdown
    property bool _vehicleWasArmed:                 false
    property bool _vehicleInMissionFlightMode:      _activeVehicle ? (_activeVehicle.flightMode === _activeVehicle.missionFlightMode) : false
    property bool _vehicleWasInMissionFlightMode:   false
    // ‼️ 联网运营模式下**不弹**（用户 2026-09-29 要求）。本弹窗问的是「从飞机上移除 / 在飞机上
    //    保留飞行计划」——那是**单机版**的取舍：计划由本机规划、由本机决定去留。运营模式下
    //    飞行计划由后端下发与管理，这里没有问用户的余地。
    //    判据 `AuthController.standaloneMode` 与其它界面裁剪是**同一个属性**（写法对照
    //    `SelectViewDropdown.qml:80/97/112/129` 四处同款 `visible:`）。
    // ⚠️ 闸**只在这里**加。不要去 `FlyViewWidgetLayer.qml` 的实例化处加 `visible`：
    //    `QGCPopupDialogFactory` 会把这个弹窗 reparent 到 `Overlay.overlay`，它**不受**父项
    //    可见性链约束，那样改是假修（`QGCPopupDialogFactory.qml:5-7` 注释）。
    // ⚠️ 本属性是**弹窗真正开不开**的判据（`on_VehicleArmedChanged` 里那道 `if`），不是显示开关，
    //    所以这一处就能盖住唯一那条 `open()` 调用，没有第二个入口。
    property bool _showMissionCompleteDialog:       AuthController.standaloneMode &&
                                                    _vehicleWasArmed && _vehicleWasInMissionFlightMode &&
                                                    (missionController.containsItems || geoFenceController.containsItems || rallyPointController.containsItems ||
                                                     (_activeVehicle ? _activeVehicle.cameraTriggerPoints.count !== 0 : false))

    on_VehicleArmedChanged: {
        if (_vehicleArmed) {
            _vehicleWasArmed = true
            _vehicleWasInMissionFlightMode = _vehicleInMissionFlightMode
        } else {
            if (_showMissionCompleteDialog) {
                missionCompleteDialogFactory.open()
            }
            _vehicleWasArmed = false
            _vehicleWasInMissionFlightMode = false
        }
    }

    on_VehicleInMissionFlightModeChanged: {
        if (_vehicleInMissionFlightMode && _vehicleArmed) {
            _vehicleWasInMissionFlightMode = true
        }
    }

    QGCPopupDialogFactory {
        id: missionCompleteDialogFactory

        dialogComponent: missionCompleteDialogComponent
    }

    Component {
        id: missionCompleteDialogComponent

        QGCPopupDialog {
            id:         missionCompleteDialog
            title:      qsTr("Flight Plan complete")
            buttons:    Dialog.Close

            property var activeVehicleCopy: _activeVehicle
            onActiveVehicleCopyChanged:
                if (!activeVehicleCopy) {
                    missionCompleteDialog.close()
                }

            ColumnLayout {
                id:         column
                width:      40 * ScreenTools.defaultFontPixelWidth
                spacing:    ScreenTools.defaultFontPixelHeight

                QGCLabel {
                    Layout.fillWidth:       true
                    text:                   qsTr("%1 Images Taken").arg(_activeVehicle.cameraTriggerPoints.count)
                    horizontalAlignment:    Text.AlignHCenter
                    visible:                _activeVehicle.cameraTriggerPoints.count !== 0
                }

                QGCButton {
                    Layout.fillWidth:   true
                    text:               qsTr("Remove plan from vehicle")
                    visible:            !_activeVehicle.communicationLost// && !_activeVehicle.apmFirmware  // ArduPilot has a bug somewhere with mission clear
                    onClicked: {
                        _planController.removeAllFromVehicle()
                        missionCompleteDialog.close()
                    }
                }

                QGCButton {
                    Layout.fillWidth:   true
                    Layout.alignment:   Qt.AlignHCenter
                    text:               qsTr("Leave plan on vehicle")
                    onClicked:          missionCompleteDialog.close()

                }

                Rectangle {
                    Layout.fillWidth:   true
                    color:              qgcPal.text
                    height:             1
                }

                ColumnLayout {
                    Layout.fillWidth:   true
                    spacing:            ScreenTools.defaultFontPixelHeight
                    visible:            !_activeVehicle.communicationLost && globals.guidedControllerFlyView.showResumeMission

                    QGCButton {
                        Layout.fillWidth:   true
                        Layout.alignment:   Qt.AlignHCenter
                        text:               qsTr("Resume Mission From Waypoint %1").arg(globals.guidedControllerFlyView._resumeMissionIndex)

                        onClicked: {
                            globals.guidedControllerFlyView.executeAction(globals.guidedControllerFlyView.actionResumeMission, null, null)
                            missionCompleteDialog.close()
                        }
                    }

                    QGCLabel {
                        Layout.fillWidth:   true
                        wrapMode:           Text.WordWrap
                        text:               qsTr("Resume Mission will rebuild the current mission from the last flown waypoint and upload it to the vehicle for the next flight.")
                    }
                }

                QGCLabel {
                    Layout.fillWidth:   true
                    wrapMode:           Text.WordWrap
                    color:              qgcPal.warningText
                    text:               qsTr("If you are changing batteries for Resume Mission do not disconnect from the vehicle.")
                    visible:            globals.guidedControllerFlyView.showResumeMission
                }
            }
        }
    }
}
