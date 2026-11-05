#pragma once

#include <QtQmlIntegration/QtQmlIntegration>

#include "SettingsGroup.h"

/// \brief Screen-relative layout sizing settings
///
/// Toolbar height, status bar height and right panel width are calculated from
/// these percentages, the window size and a manual scale factor. The scale
/// factor is never derived from the screen resolution automatically.
///
class LayoutSettings : public SettingsGroup
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("")
public:
    LayoutSettings(QObject* parent = nullptr);

    DEFINE_SETTING_NAME_GROUP()

    DEFINE_SETTINGFACT(toolbarHeightPercent)
    DEFINE_SETTINGFACT(statusBarHeightPercent)
    DEFINE_SETTINGFACT(rightPanelMinPercent)
    DEFINE_SETTINGFACT(rightPanelMaxPercent)
    DEFINE_SETTINGFACT(scaleFactor)
    DEFINE_SETTINGFACT(fontScalePercent)
};
