pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// 解锁密码对话框：输入当前用户密码，后台验证通过后解除屏幕锁定。
/// 打开/关闭时同步 AuthController.unlockDialogOpen，使事件过滤器放行本框输入。
QGCPopupDialog {
    id:                     unlockDialog
    title:                  qsTr("屏幕解锁")
    buttons:                Dialog.Ok | Dialog.Cancel
    acceptButtonEnabled:    passwordField.text !== ""

    onOpened:   AuthController.unlockDialogOpen = true
    onClosed:   AuthController.unlockDialogOpen = false

    onAccepted: {
        unlockDialog.preventClose = true   // 等后台结果，不立即关闭
        errorLabel.text = ""
        AuthController.unlock(passwordField.text)
    }

    Connections {
        target: AuthController
        function onUnlockSucceeded() {
            unlockDialog.close()
        }
        function onUnlockFailed(error) {
            errorLabel.text = qsTr("解锁失败：%1").arg(error)
            unlockDialog.preventClose = false   // 允许用户重试或取消
        }
    }

    ColumnLayout {
        spacing: ScreenTools.defaultFontPixelHeight / 2

        QGCLabel {
            text:               qsTr("当前用户：%1").arg(AuthController.currentUser)
            Layout.fillWidth:   true
        }

        QGCLabel { text: qsTr("请输入密码") }
        QGCTextField {
            id:                     passwordField
            Layout.fillWidth:       true
            Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 30
            placeholderText:        qsTr("输入密码")
            echoMode:               TextInput.Password
            inputMethodHints:       Qt.ImhNoPredictiveText
            onAccepted:             unlockDialog._accept()
        }

        QGCLabel {
            id:                 errorLabel
            visible:            text !== ""
            Layout.fillWidth:   true
            color:              QGroundControl.globalPalette.warningText
            font.pointSize:     ScreenTools.smallFontPointSize
            wrapMode:           Text.WordWrap
        }
    }
}
