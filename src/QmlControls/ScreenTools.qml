pragma Singleton

import QtQuick
import QtQuick.Controls
import QtQuick.Window

import QGroundControl

/*!
 The ScreenTools Singleton provides information on QGC's standard font metrics. It also provides information on screen
 size which can be used to adjust user interface for varying available screen real estate.

 QGC has four standard font sizes: default, small, medium and large. The QGC controls use the default font for display and you should use this font
 for most text within the system that is drawn using something other than a standard QGC control. The small font is smaller than the default font.
 The medium and large fonts are larger than the default font.

 Usage:

        import QGroundControl.Controls
        Rectangle {
            anchors.fill:       parent
            anchors.margins:    ScreenTools.defaultFontPixelWidth
            ...
        }
*/
Item {
    id: _screenTools

    //-- The point and pixel font size values are computed at runtime

    property real defaultFontPointSize:     10
    property real platformFontPointSize:    10

    readonly property real smallFontPointRatio:      0.75
    readonly property real mediumFontPointRatio:     1.25
    readonly property real largeFontPointRatio:      1.5

    /// You can use these properties to position ui elements in a screen resolution independent manner. Using fixed positioning values should not
    /// be done. All positioning should be done using anchors or a ratio of the defaultFontPixelHeight and defaultFontPixelWidth values. This way
    /// your ui elements will reposition themselves appropriately on varying screen sizes and resolutions.
    property real defaultFontPixelHeight:   10
    property real largeFontPixelHeight:     defaultFontPixelHeight * largeFontPointRatio
    property real mediumFontPixelHeight:    defaultFontPixelHeight * mediumFontPointRatio
    property real smallFontPixelHeight:     defaultFontPixelHeight * smallFontPointRatio

    /// You can use these properties to position ui elements in a screen resolution independent manner. Using fixed positioning values should not
    /// be done. All positioning should be done using anchors or a ratio of the defaultFontPixelHeight and defaultFontPixelWidth values. This way
    /// your ui elements will reposition themselves appropriately on varying screen sizes and resolutions.
    property real defaultFontPixelWidth:    10
    property real largeFontPixelWidth:      defaultFontPixelWidth * largeFontPointRatio
    property real mediumFontPixelWidth:     defaultFontPixelWidth * mediumFontPointRatio
    property real smallFontPixelWidth:      defaultFontPixelWidth * smallFontPointRatio

    /// QFontMetrics::descent for default font at default point size
    property real defaultFontDescent:       0

    /// The default amount of space in between controls in a dialog
    property real defaultDialogControlSpacing: defaultFontPixelHeight / 2

    property real smallFontPointSize:       10
    property real mediumFontPointSize:      10
    property real largeFontPointSize:       10

    /// Screen-relative layout parameters. These are manual settings; the scale
    /// factor is never derived from the screen resolution automatically.
    readonly property real layoutScaleFactor:       QGroundControl.settingsManager.layoutSettings.scaleFactor.value
    readonly property real _toolbarHeightPercent:   QGroundControl.settingsManager.layoutSettings.toolbarHeightPercent.value
    readonly property real _statusBarHeightPercent: QGroundControl.settingsManager.layoutSettings.statusBarHeightPercent.value
    readonly property real _rightPanelMinPercent:   QGroundControl.settingsManager.layoutSettings.rightPanelMinPercent.value
    readonly property real _rightPanelMaxPercent:   QGroundControl.settingsManager.layoutSettings.rightPanelMaxPercent.value
    /// Height of the main window content area. This singleton has no window of its own, so
    /// MainWindow injects the real value; `screenHeight` is only the fallback used before that
    /// binding is evaluated. Layout sizes must follow the window, not the monitor (design §6.3).
    property real windowContentHeight: screenHeight

    property real toolbarHeight: {
        const lo = 3 * defaultFontPixelHeight
        const hi = Math.max(lo, 0.20 * windowContentHeight)
        return Math.round(clamp(windowContentHeight * _toolbarHeightPercent / 100 * layoutScaleFactor, lo, hi))
                * QGroundControl.corePlugin.options.toolbarHeightMultiplier
    }

    property real realPixelDensity: {
        //-- If a plugin defines it, just use what it tells us
        if(QGroundControl.corePlugin.options.devicePixelDensity != 0) {
            return QGroundControl.corePlugin.options.devicePixelDensity
        }
        //-- Android is rather unreliable
        if(isAndroid) {
            // Lets assume it's unlikely you have a tablet over 300mm wide
            if((Screen.width / Screen.pixelDensity) > 300) {
                return Screen.pixelDensity * 2
            }
        }
        //-- Let's use what the system tells us
        return Screen.pixelDensity
    }

    // These properties allow us to create simulated mobile sizing for a desktop build.
    // This makes testing the UI for smaller mobile sizing much easier.
    // The 731x411 size is the size of the Herelink screen which is our target lower bound
    property real screenWidth:  ScreenToolsController.fakeMobile ? 731 : Screen.width
    property real screenHeight: ScreenToolsController.fakeMobile ? 411 : Screen.height

    property bool isAndroid:                        ScreenToolsController.isAndroid
    property bool isiOS:                            ScreenToolsController.isiOS
    property bool isMobile:                         ScreenToolsController.isMobile
    property bool isFakeMobile:                     ScreenToolsController.fakeMobile
    property bool isWindows:                        ScreenToolsController.isWindows
    property bool isDebug:                          ScreenToolsController.isDebug
    property bool isMac:                            ScreenToolsController.isMacOS
    property bool isLinux:                          ScreenToolsController.isLinux
    property bool isTinyScreen:                     (Screen.width / realPixelDensity) < 120 // 120mm
    property bool isShortScreen:                    ((Screen.height / realPixelDensity) < 120) || (ScreenToolsController.isMobile && ((Screen.height / Screen.width) < 0.6))
    property bool isHugeScreen:                     (Screen.width / realPixelDensity) >= (23.5 * 25.4) // 27" monitor
    property bool isSerialAvailable:                ScreenToolsController.isSerialAvailable

    readonly property real minTouchMillimeters:     5   ///< Minimum touch size in millimeters
    property real minTouchPixels:                   0   ///< Minimum touch size in pixels (calculatedd from minTouchMillimeters and realPixelDensity)

    // The implicit heights/widths for our custom control set
    property real implicitButtonWidth:              Math.round(defaultFontPixelWidth *  5.0)
    property real implicitButtonHeight:             Math.round(defaultFontPixelHeight * 1.6)
    property real implicitCheckBoxHeight:           Math.round(defaultFontPixelHeight * 1.0)
    property real implicitRadioButtonHeight:        implicitCheckBoxHeight
    property real implicitTextFieldWidth:           defaultFontPixelWidth * 10
    property real implicitTextFieldHeight:          implicitButtonHeight
    property real implicitComboBoxHeight:           implicitButtonHeight
    property real implicitComboBoxWidth:            implicitButtonWidth
    property real comboBoxPadding:                  defaultFontPixelWidth
    property real implicitSliderHeight:             defaultFontPixelHeight
    property real defaultBorderRadius:              defaultFontPixelWidth / 2

    // It's not possible to centralize an even number of pixels, checkBoxIndicatorSize should be an odd number to allow centralization
    property real checkBoxIndicatorSize:            2 * Math.floor(defaultFontPixelHeight / 2) + 1
    property real radioButtonIndicatorSize:         checkBoxIndicatorSize

    readonly property string normalFontFamily:      ScreenToolsController.normalFontFamily
    readonly property string fixedFontFamily:       ScreenToolsController.fixedFontFamily
    /* This mostly works but for some reason, reflowWidths() in SetupView doesn't change size.
       I've disabled (in release builds) until I figure out why. Changes require a restart for now.
    */
    Connections {
        target: QGroundControl.settingsManager.appSettings.uiScalePercent
        function onValueChanged() {
            _applyBasePointSize()
        }
    }

    Connections {
        target: QGroundControl.settingsManager.layoutSettings.fontScalePercent
        function onValueChanged() {
            _applyBasePointSize()
        }
    }

    onRealPixelDensityChanged: {
        _setBasePointSize(defaultFontPointSize)
    }

    function printScreenStats() {
        console.log('ScreenTools: Screen.width: ' + Screen.width + ' Screen.height: ' + Screen.height + ' Screen.pixelDensity: ' + Screen.pixelDensity)
    }

    /// Returns the current x position of the mouse in global screen coordinates.
    function mouseX() {
        return ScreenToolsController.mouseX()
    }

    /// Returns the current y position of the mouse in global screen coordinates.
    function mouseY() {
        return ScreenToolsController.mouseY()
    }

    /// \private
    /// Re-derives the base point size from the platform size, the App Settings UI Scaling and the
    /// Layout font scale. Call this whenever any of the three inputs changes.
    function _applyBasePointSize() {
        // Values written straight into the .ini / provision file are loaded without min/max
        // validation (SettingsFact loads them with convertOnly), so clamp here as well: an
        // out-of-range font scale must not be able to collapse every font-derived size.
        const uiScaleFact   = QGroundControl.settingsManager.appSettings.uiScalePercent
        const fontScaleFact = QGroundControl.settingsManager.layoutSettings.fontScalePercent
        const uiPct         = clamp(uiScaleFact.value,   uiScaleFact.min,   uiScaleFact.max)
        const fontPct       = clamp(fontScaleFact.value, fontScaleFact.min, fontScaleFact.max)
        _setBasePointSize(platformFontPointSize * uiPct / 100 * fontPct / 100)
    }

    /// \private
    function _setBasePointSize(pointSize) {
        _textMeasure.font.pointSize = pointSize
        defaultFontPointSize    = pointSize
        defaultFontPixelHeight  = Math.round(_textMeasure.fontHeight/2.0)*2
        defaultFontPixelWidth   = Math.round(_textMeasure.fontWidth/2.0)*2
        defaultFontDescent      = ScreenToolsController.defaultFontDescent(defaultFontPointSize)
        smallFontPointSize      = defaultFontPointSize  * _screenTools.smallFontPointRatio
        mediumFontPointSize     = defaultFontPointSize  * _screenTools.mediumFontPointRatio
        largeFontPointSize      = defaultFontPointSize  * _screenTools.largeFontPointRatio
        minTouchPixels          = Math.round(minTouchMillimeters * realPixelDensity)
        if (minTouchPixels / Screen.height > 0.15) {
            // If using physical sizing takes up too much of the vertical real estate fall back to font based sizing
            minTouchPixels      = defaultFontPixelHeight * 3
        }
    }

    function clamp(value, minValue, maxValue) {
        return Math.min(Math.max(value, minValue), maxValue)
    }

    function statusBarHeightFor(windowHeight) {
        // The absolute floor must stay below what a scaled-down font produces on small screens,
        // otherwise `fontScalePercent` cannot shrink the bar at all.
        const lo = Math.max(20, 1.8 * defaultFontPixelHeight)
        if (windowHeight <= 0) {
            return Math.round(lo)
        }
        const hi = Math.max(lo, 0.15 * windowHeight)
        return Math.round(clamp(windowHeight * _statusBarHeightPercent / 100 * layoutScaleFactor, lo, hi))
    }

    /// 右栏宽度**严格按参数**取比例，不再有内容派生的下限（2026-11-05 用户裁定
    /// 「参数优先」）。仅保留「不超过 45% 窗口宽」的防吞屏上限。
    /// 内容适配目前只做了 Ops/Rom（仪表按栏宽缩放、任务卡按钮夹到行宽并折行）；
    /// PlanView 的右栏内容（PlanTreeView）**尚未**按窄栏适配，小屏上需实测；
    /// FlyView 的 `_rightPanelWidth` / `FlyViewMap.rightPanelWidth` 只有声明、无读取。
    function rightPanelMinWidthFor(windowWidth) {
        if (windowWidth <= 0) {
            return 0
        }
        return Math.round(clamp(windowWidth * _rightPanelMinPercent / 100 * layoutScaleFactor, 0, 0.45 * windowWidth))
    }

    function rightPanelMaxWidthFor(windowWidth, panelMinWidth) {
        if (windowWidth <= 0) {
            return Math.round(panelMinWidth)
        }
        const hi = Math.max(panelMinWidth, 0.55 * windowWidth)
        return Math.round(clamp(windowWidth * _rightPanelMaxPercent / 100 * layoutScaleFactor, panelMinWidth, hi))
    }

    Text {
        id:     _defaultFont
        text:   "X"
    }

    Text {
        id:     _textMeasure
        text:   "X"
        font.family:    normalFontFamily
        property real   fontWidth:    contentWidth
        property real   fontHeight:   contentHeight
        Component.onCompleted: {
            //-- First, compute platform, default size
            if(ScreenToolsController.isMobile) {
                //-- Check iOS really tiny screens (iPhone 4s/5/5s)
                if(ScreenToolsController.isiOS) {
                    if(ScreenToolsController.isiOS && Screen.width < 570) {
                        // For iPhone 4s size we don't fit with additional tweaks to fit screen,
                        // we will just drop point size to make things fit. Correct size not yet determined.
                        platformFontPointSize = 12;  // This will be lowered in a future pull
                    } else {
                        platformFontPointSize = 14;
                    }
                } else if((Screen.width / realPixelDensity) < 120) {
                    platformFontPointSize = 11;
                // Other Android
                } else {
                    platformFontPointSize = 14;
                }
            } else {
                platformFontPointSize = _defaultFont.font.pointSize;
            }
            //-- See if we are using a custom size
            var _uiScalePercentFact = QGroundControl.settingsManager.appSettings.uiScalePercent
            var pct = _uiScalePercentFact.value
            //-- Sanity check
            if(pct < _uiScalePercentFact.min || pct > _uiScalePercentFact.max) {
                pct = 100;
                _uiScalePercentFact.value = pct
            }
            //-- Set size saved in settings (UI Scaling × Layout font scale)
            _screenTools._applyBasePointSize();
        }
    }
}
