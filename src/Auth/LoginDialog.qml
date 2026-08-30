pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// 登录对话框：用户名 + 密码，后台验证。
/// 登录成功（AuthController.loginSucceeded）自动关闭；
/// 失败（loginFailed）在对话框内显示错误，可修改后重试。
QGCPopupDialog {
    id:                     loginDialog
    title:                  qsTr("登陆")
    buttons:                Dialog.Ok | Dialog.Cancel
    acceptButtonEnabled:    usernameField.text !== "" && passwordField.text !== ""

    onAccepted: {
        loginDialog.preventClose = true   // 等后台结果，不立即关闭
        errorLabel.text = ""
        AuthController.login(usernameField.text, passwordField.text)
    }

    Connections {
        target: AuthController
        function onLoginSucceeded() {
            loginDialog.close()
        }
        function onLoginFailed(error) {
            errorLabel.text = qsTr("登录失败：%1").arg(error)
            loginDialog.preventClose = false   // 允许用户重试或取消
        }
    }

    ColumnLayout {
        spacing: ScreenTools.defaultFontPixelHeight / 2

        QGCLabel { text: qsTr("用户名") }
        QGCTextField {
            id:                     usernameField
            Layout.fillWidth:       true
            Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 30
            placeholderText:        qsTr("输入用户名")
            inputMethodHints:       Qt.ImhNoPredictiveText
        }

        QGCLabel { text: qsTr("密码") }
        QGCTextField {
            id:                     passwordField
            Layout.fillWidth:       true
            Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 30
            placeholderText:        qsTr("输入密码")
            echoMode:               TextInput.Password
            inputMethodHints:       Qt.ImhNoPredictiveText
            onAccepted:             loginDialog._accept()
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
