pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

/// 交接班对话框：显示当前用户，输入接收人用户名。
/// v1：尽力 POST /api/auth/handover 记录，不阻塞 UI。
QGCPopupDialog {
    id:                     handoverDialog
    title:                  qsTr("交接班")
    buttons:                Dialog.Ok | Dialog.Cancel
    acceptButtonEnabled:    receiverField.text !== ""

    onAccepted: {
        AuthController.handover(receiverField.text)
        handoverDialog.close()
    }

    ColumnLayout {
        spacing: ScreenTools.defaultFontPixelHeight / 2

        QGCLabel {
            text:               qsTr("当前用户：%1").arg(AuthController.currentUser)
            Layout.fillWidth:   true
        }

        QGCLabel { text: qsTr("接收人") }
        QGCTextField {
            id:                     receiverField
            Layout.fillWidth:       true
            Layout.preferredWidth:  ScreenTools.defaultFontPixelWidth * 30
            placeholderText:        qsTr("输入接收人用户名")
            inputMethodHints:       Qt.ImhNoPredictiveText
            onAccepted:             handoverDialog._accept()
        }
    }
}
