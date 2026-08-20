#pragma once

#include <QtQmlIntegration/QtQmlIntegration>

#include "SettingsGroup.h"

/// \brief 加密 MAVLink 链路相关设置（deviceID + AES-256-GCM）。
///
class CryptoSettings : public SettingsGroup
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("")
public:
    CryptoSettings(QObject* parent = nullptr);

    DEFINE_SETTING_NAME_GROUP()

    DEFINE_SETTINGFACT(cryptoEnabled)
    DEFINE_SETTINGFACT(cryptoGcsServerUrl)
    DEFINE_SETTINGFACT(cryptoAuthToken)
    DEFINE_SETTINGFACT(cryptoGcsDeviceID)
    DEFINE_SETTINGFACT(cryptoKeySource)
    DEFINE_SETTINGFACT(cryptoLocalKeyDeviceID)
};
