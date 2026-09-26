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
                // 联网运营模式（standaloneMode == false）隐掉。判据**只**来自 AuthController 那一个属性，
                // 不在本文件重写表达式 —— 见 docs/qgc/联网运营模式界面裁剪-20260926.md 的 N5。
                // ‼️ 只改 visible：showPlanView() 等函数依然存在且可调（§5.2），本设计要的是界面干净，不是安全边界。
                visible: AuthController.standaloneMode
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
                // 本项原已有可见性条件 ⇒ 用合取叠加，**不覆盖**原条件（同 N5 的 Settings 一项）。
                visible: QGroundControl.corePlugin.showAdvancedUI && AuthController.standaloneMode
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
                visible: AuthController.standaloneMode
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
                visible: !QGroundControl.corePlugin.options.combineSettingsAndSetup && AuthController.standaloneMode
                onClicked: {
                    if (mainWindow.allowViewSwitch()) {
                        mainWindow.closeIndicatorDrawer()
                        mainWindow.showSettingsTool()
                    }
                }
            }

            // §7.3「刷新航线与航点」（裁定 ② 明确要求）。放在视图组之后、Close 之前：
            // 它与上面几项**不同类**——那些是"切换视图"，这一项是"在当前视图里重拉数据"，
            // 混进视图组会让人以为点了会跳走。
            SubMenuButton {
                objectName: "toolbar_refreshRoutes"
                implicitHeight: root._toolButtonHeight
                Layout.fillWidth: true
                // ⚠️ 读 `roles` 属性（NOTIFY rolesChanged）而非 `hasRole()` 方法：方法调用
                //    不注册 QML 绑定依赖 ⇒ 若本项在 roles 填充**之前**被求值过一次，它就
                //    永远停在 false。与 `RomView._isRouteMon` 同源同写法。
                // ‼️ 只对航线监控员显示：站点视图没有航线缓存（`routeLayersEnabled` 恒 false），
                //    这个动作在那边无事可做。
                visible: AuthController.roles.indexOf("ROUTE_MONITOR") >= 0
                text: qsTr("刷新航线与航点")
                imageResource: "/res/clockwise-arrow.svg"
                // ‼️ **刻意不调 `mainWindow.allowViewSwitch()`**（上面每一项都调了）。
                //    那不是本项的语义，且会**挡掉它最该起作用的那一次重试**：
                //    ① `allowViewSwitch()` 是"切换视图前的闸"（navigationBlockedReason、
                //       聚焦控件的校验错误、未保存的航点/参数/连接），而本项**不切视图**；
                //    ② §7.2 的失败提示恰恰是"航点加载失败"⇒ 用户点这里重试的那一刻，
                //       屏幕上很可能正有一个校验未过的控件 ⇒ 闸返回 false ⇒ 最需要重试的
                //       场景反而被自己的闸挡死。关抽屉自己做（其余几项是过闸之后才关的）。
                onClicked: {
                    mainWindow.closeIndicatorDrawer()
                    mainWindow.refreshOpsRoutes()
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
