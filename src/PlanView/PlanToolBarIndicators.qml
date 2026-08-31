import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

import QGroundControl
import QGroundControl.Controls
import QGroundControl.FactControls

// Toolbar for Plan View
RowLayout {
    required property var planMasterController
    property bool showRallyPointsHelp: false

    signal toolbarButtonClicked()

    id: root
    spacing: ScreenTools.defaultFontPixelWidth

    property var _planMasterController: planMasterController
    property var _missionController: _planMasterController.missionController
    property var _geoFenceController: _planMasterController.geoFenceController
    property var _rallyPointController: _planMasterController.rallyPointController
    property bool _controllerOffline: _planMasterController.offline
    property var _saveDirty: _planMasterController.dirtyForSave
    property var _uploadDirty: _planMasterController.dirtyForUpload
    property var _syncInProgress: _planMasterController.syncInProgress
    property var _visualItems: _missionController.visualItems
    property bool _hasPlanItems: _planMasterController.containsItems
    property var _uavDisplayList: []     ///< 无人机下拉显示文本（uav_no (deviceID xx)）

    readonly property real _margins: ScreenTools.defaultFontPixelWidth

    function _refreshUavDisplayList() {
        var list = []
        for (var i = 0; i < planUploader.uavList.length; i++) {
            var uav = planUploader.uavList[i]
            list.push(uav.uav_no + " (deviceID " + uav.device_id + ")")
        }
        _uavDisplayList = list
        uavCombo.currentIndex = -1   // 列表刷新后需重新选择
    }

    // 上传按钮改义：上传到后台创建临时飞行计划 + 飞行任务（等待批准），
    // 不再 MAVLink 上传到无人机。需已登录、已选无人机（任务创建必填 uav_id）、
    // 且航线标题非空（route_name，便于区分多条临时航线）。
    function _uploadClicked() {
        if (!AuthController.loggedIn) {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), qsTr("请先登录后再上传航线"))
            return
        }
        if (titleField.text.trim() === "") {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), qsTr("请先输入航线标题"))
            return
        }
        if (uavCombo.currentIndex < 0 || uavCombo.currentIndex >= planUploader.uavList.length) {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), qsTr("请先选择无人机"))
            return
        }
        var uavId = planUploader.uavList[uavCombo.currentIndex].id
        planUploader.uploadPlan(_planMasterController, uavId, titleField.text.trim())
    }

    function _downloadClicked() {
        if (_saveDirty) {
            QGroundControl.showMessageDialog(root, qsTr("Download"),
                                         qsTr("You have unsaved changes. Downloading from the Vehicle will lose these changes. Are you sure?"),
                                         Dialog.Yes | Dialog.Cancel,
                                         function() { _planMasterController.loadFromVehicle() })
        } else {
            _planMasterController.loadFromVehicle()
        }
    }

    function _openButtonClicked() {
        if (_saveDirty || _uploadDirty) {
            QGroundControl.showMessageDialog(root, qsTr("Open Plan"),
                                        qsTr("You have unsaved/unsent changes. Loading a new Plan will lose these changes. Are you sure?"),
                                        Dialog.Yes | Dialog.Cancel,
                                        function() { _planMasterController.loadFromSelectedFile() } )
        } else {
            _planMasterController.loadFromSelectedFile()
        }
    }

    function _saveButtonClicked() {
        if (_planMasterController.currentPlanFileName === "") {
            if (_planMasterController.currentPlanFile === "") {
                // No file and no name typed — open the file dialog
                _planMasterController.saveToSelectedFile()
            } else {
                // Have a file but name was cleared — save to the existing file
                _planMasterController.saveToCurrent()
            }
            return
        }

        if (_planMasterController.currentPlanFile === "" || _planMasterController.planFileRenamed) {
            // First save with a typed name, or name was changed since last save
            let fullName = _planMasterController.currentPlanFileName + "." + _planMasterController.fileExtension
            let msg = _planMasterController.resolvedPlanFileExists()
                ? qsTr("'%1' already exists. Overwrite?").arg(fullName)
                : qsTr("Save as '%1'?").arg(fullName)
            QGroundControl.showMessageDialog(root, qsTr("Save"), msg,
                Dialog.Yes | Dialog.No,
                function() { _planMasterController.saveWithCurrentName() })
        } else {
            _planMasterController.saveToCurrent()
        }
    }

    function _saveAsKMLClicked() {
        // Don't save if we only have Mission Settings item
        if (_visualItems.count > 1) {
            _planMasterController.saveKmlToSelectedFile()
        }
    }

    function _storageClearButtonClicked() {
        QGroundControl.showMessageDialog(root, qsTr("Clear"),
                                     qsTr("Are you sure you want to remove all the items from the plan editor?"),
                                     Dialog.Yes | Dialog.Cancel,
                                     function() { _planMasterController.removeAll(); })
    }

    function _vehicleClearButtonClicked() {
        QGroundControl.showMessageDialog(root, qsTr("Clear"),
                                     qsTr("Are you sure you want to remove the plan from the vehicle and the plan editor?"),
                                     Dialog.Yes | Dialog.Cancel,
                                     function() {
                                        _planMasterController.removeAllFromVehicle()
                                     })
    }

    function _clearClicked() {
        if (_planMasterController.offline) {
            _storageClearButtonClicked();
        } else {
            _vehicleClearButtonClicked();
        }
    }

    QGCPalette { id: qgcPal }

    QGCButton {
        objectName: "planToolbar_openButton"
        text: qsTr("Open")
        iconSource: "/qmlimages/Plan.svg"
        enabled: !_planMasterController.syncInProgress
        onClicked: { toolbarButtonClicked(); _openButtonClicked() }
    }

    QGCButton {
        objectName: "planToolbar_saveButton"
        text: qsTr("Save")
        iconSource: "/res/SaveToDisk.svg"
        enabled: !_syncInProgress && _hasPlanItems
        primary: _saveDirty
        onClicked: { toolbarButtonClicked(); _saveButtonClicked() }
    }

    // 无人机选择（上传后台创建飞行任务需要 uav_id）：登录后可见，列表来自 GET /api/uavs
    QGCComboBox {
        id: uavCombo
        objectName: "planToolbar_uavCombo"
        visible: AuthController.loggedIn
        enabled: AuthController.loggedIn && !_syncInProgress
        alternateText: currentIndex === -1 ? qsTr("选择无人机") : ""   // 未选中显示占位，选中后显示所选
        model: _uavDisplayList
        currentIndex: -1
        sizeToContents: true
        font.pointSize: ScreenTools.smallFontPointSize
    }

    // 航线标题（必填）：上传创建临时航线时作 route_name，便于区分多条临时航线
    QGCTextField {
        id: titleField
        objectName: "planToolbar_routeTitle"
        visible: AuthController.loggedIn
        enabled: AuthController.loggedIn && !_syncInProgress
        placeholderText: qsTr("航线标题（必填）")
        maximumLength: 50
        Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 16
    }

    QGCButton {
        id: uploadButton
        objectName: "planToolbar_uploadButton"
        text: qsTr("Upload")
        iconSource: "/res/UploadToVehicle.svg"
        enabled: !_syncInProgress && _hasPlanItems && AuthController.loggedIn && !planUploader.uploading
        visible: !_syncInProgress
        primary: _uploadDirty && AuthController.loggedIn
        onClicked: { toolbarButtonClicked(); _uploadClicked() }
    }

    QGCButton {
        objectName: "planToolbar_clearButton"
        text: qsTr("Clear")
        iconSource: "/res/TrashCan.svg"
        enabled: !_syncInProgress
        onClicked: { toolbarButtonClicked(); _clearClicked() }
    }

    QGCButton {
        iconSource: "qrc:/qmlimages/Hamburger.svg"

        onClicked: {
            let position = Qt.point(width, height / 2)
            // For some strange reason using mainWindow in mapToItem doesn't work, so we use globals.parent instead which also gets us mainWindow
            position = mapToItem(globals.parent, position)
            var dropPanel = hamburgerDropPanelComponent.createObject(mainWindow, { clickRect: Qt.rect(position.x, position.y, 0, 0) })
            dropPanel.open()
        }
    }

    QGCLabel {
        text:    qsTr("Click in map to add rally points")
        visible: root.showRallyPointsHelp
        Layout.alignment: Qt.AlignVCenter
    }

    Component {
        id: hamburgerDropPanelComponent

        DropPanel {
            id: dropPanel

            sourceComponent: Component {
                ColumnLayout {
                    spacing: ScreenTools.defaultFontPixelHeight / 2

                    QGCButton {
                        Layout.fillWidth: true
                        text: qsTr("Save as KML")
                        enabled: !_syncInProgress && _hasPlanItems

                        onClicked: {
                            dropPanel.close()
                            _saveAsKMLClicked()
                        }
                    }

                    QGCButton {
                        Layout.fillWidth: true
                        text: qsTr("Download")
                        enabled: !_syncInProgress && !_controllerOffline
                        visible: !_syncInProgress

                        onClicked: {
                            dropPanel.close()
                            _downloadClicked()
                        }
                    }
                }
            }
        }
    }

    // 上传结果提示
    Connections {
        target: planUploader
        function onUploadSucceeded(message) {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), message)
        }
        function onUploadFailed(error) {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), error)
        }
        function onUavListError(error) {
            QGroundControl.showMessageDialog(root, qsTr("Upload"), error)
        }
        function onUavListChanged() {
            _refreshUavDisplayList()
        }
    }

    // 登录后拉取无人机列表（供下拉选择）
    Connections {
        target: AuthController
        function onLoggedInChanged() {
            if (AuthController.loggedIn) {
                planUploader.fetchUavs()
            }
        }
    }

    Component.onCompleted: {
        if (AuthController.loggedIn) {
            planUploader.fetchUavs()
        }
    }
}
