import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

ToolIndicatorPage {
    id: root

    property real _toolButtonHeight: ScreenTools.defaultFontPixelHeight * 3

    contentComponent: Component {
        GridLayout {
            columns: 2
            columnSpacing: ScreenTools.defaultFontPixelWidth
            rowSpacing: columnSpacing

            // 用户会话：未登录为「登陆」，登录成功切换为「交接班」。
            SubMenuButton {
                objectName: "toolbar_authLogin"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: AuthController.loggedIn ? qsTr("交接班") : qsTr("登陆")
                imageResource: "/res/QGCLogoWhite.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        if (AuthController.loggedIn) {
                            mainWindow.openHandoverDialog()
                        } else {
                            mainWindow.openLoginDialog()
                        }
                    }
                }
            }

            // 屏幕锁定：未登录禁用；锁定态变为「屏幕解锁」（可点）。
            SubMenuButton {
                objectName: "toolbar_screenLock"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                enabled: AuthController.loggedIn
                text: AuthController.screenLocked ? qsTr("屏幕解锁") : qsTr("屏幕锁定")
                imageResource: "/res/QGCLogoWhite.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        if (AuthController.screenLocked) {
                            mainWindow.openUnlockDialog()
                        } else {
                            AuthController.lockScreen()
                        }
                    }
                }
            }

            SubMenuButton {
                objectName: "toolbar_viewFly"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Fly")
                imageResource: "/res/FlyingPaperPlane.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showFlyView()
                    }
                }
            }

            SubMenuButton {
                objectName: "toolbar_viewPlan"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Plan")
                imageResource: "/qmlimages/Plan.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showPlanView()
                    }
                }
            }

            SubMenuButton {
                objectName: "toolbar_viewAnalyze"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Analyze")
                imageResource: "/qmlimages/Analyze.svg"
                visible: QGroundControl.corePlugin.showAdvancedUI
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showAnalyzeTool()
                    }
                }
            }

            SubMenuButton {
                id: setupButton
                objectName: "toolbar_viewConfigure"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Configure")
                imageResource: "/res/GearWithPaperPlane.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showVehicleConfig()
                    }
                }
            }

            SubMenuButton {
                id: settingsButton
                objectName: "toolbar_viewSettings"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Settings")
                imageResource: "/res/QGCLogoWhite.svg"
                visible: !QGroundControl.corePlugin.options.combineSettingsAndSetup
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showSettingsTool()
                    }
                }
            }

            SubMenuButton {
                id: closeButton
                objectName: "toolbar_viewClose"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                text: qsTr("Close")
                imageResource: "/res/OpenDoor.svg"
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        // Route through the window close handler so the unsaved
                        // mission / pending parameter / active connection checks
                        // run, matching the desktop window-close behavior.
                        mainWindow.close()
                    }
                }
            }

            ColumnLayout {
                id: versionColumnLayout
                Layout.fillWidth: true
                Layout.columnSpan: 2
                spacing: 0

                QGCLabel {
                    id: versionLabel
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("%1 Version").arg(QGroundControl.appName)
                    font.pointSize: ScreenTools.smallFontPointSize
                    wrapMode: QGCLabel.WordWrap
                }

                QGCLabel {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: QGroundControl.qgcVersion
                    font.pointSize: ScreenTools.smallFontPointSize
                    wrapMode: QGCLabel.WrapAnywhere
                }

                QGCLabel {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: QGroundControl.qgcAppDate
                    font.pointSize: ScreenTools.smallFontPointSize
                    wrapMode: QGCLabel.WrapAnywhere
                    visible: QGroundControl.qgcDailyBuild

                    QGCMouseArea {
                        anchors.topMargin: -(parent.y - versionLabel.y)
                        anchors.fill: parent

                        onClicked: (mouse) => {
                            if (mouse.modifiers & Qt.ControlModifier) {
                                QGroundControl.corePlugin.showTouchAreas = !QGroundControl.corePlugin.showTouchAreas
                                showTouchAreasNotification.open()
                            } else if (ScreenTools.isMobile || mouse.modifiers & Qt.ShiftModifier) {
                                mainWindow.closeIndicatorDrawer()
                                if (!QGroundControl.corePlugin.showAdvancedUI) {
                                    advancedModeOnConfirmation.open()
                                } else {
                                    advancedModeOffConfirmation.open()
                                }
                            }
                        }

                        // This allows you to change this on mobile
                        onPressAndHold: {
                            QGroundControl.corePlugin.showTouchAreas = !QGroundControl.corePlugin.showTouchAreas
                            showTouchAreasNotification.open()
                        }
                    }
                }
            }
        }
    }
}
