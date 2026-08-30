import QtQuick
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// 屏幕锁定覆盖层：半透明遮罩 + 当前用户 + 解锁按钮。
///
/// - `visible` 绑定 AuthController.screenLocked（锁定即出现）。
/// - 半透明 Rectangle 不消费鼠标/滚轮/触摸：滚轮缩放与触摸拖动穿透到下层地图；
///   鼠标按钮与键盘由 AuthController 的 qApp 事件过滤器吞掉（解锁按钮位置例外）。
/// - 解锁按钮 objectName="lockScreenUnlockButton"，供事件过滤器按坐标放行。
Item {
    id:             lockOverlay
    anchors.fill:   parent
    visible:        AuthController.screenLocked
    z:              10000

    Rectangle {
        anchors.fill:   parent
        color:          Qt.rgba(0, 0, 0, 0.65)
    }

    ColumnLayout {
        anchors.centerIn:   parent
        spacing:            ScreenTools.defaultFontPixelHeight / 2

        QGCLabel {
            text:               qsTr("屏幕已锁定")
            font.pointSize:     ScreenTools.largeFontPointSize
            color:              "white"
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth:   true
        }

        QGCLabel {
            text:               qsTr("当前用户：%1").arg(AuthController.currentUser)
            color:              "white"
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth:   true
        }

        QGCButton {
            id:                 unlockButton
            objectName:         "lockScreenUnlockButton"
            text:               qsTr("屏幕解锁")
            primary:            true
            Layout.alignment:   Qt.AlignHCenter
            Layout.topMargin:   ScreenTools.defaultFontPixelHeight
            onClicked:          mainWindow.openUnlockDialog()
        }
    }
}
