#include "CryptoSettings.h"

// settingsGroup 用 "Crypto"（与 name 一致）而非 ""：否则 QSettings 在顶层读写
// cryptoEnabled 等键（beginGroup("")），与 ini 的 [Crypto] 段不匹配，配置不生效。
DECLARE_SETTINGGROUP(Crypto, "Crypto")
{
}

DECLARE_SETTINGSFACT(CryptoSettings, cryptoEnabled)
DECLARE_SETTINGSFACT(CryptoSettings, cryptoGcsServerUrl)
DECLARE_SETTINGSFACT(CryptoSettings, cryptoAuthToken)
DECLARE_SETTINGSFACT(CryptoSettings, cryptoGcsDeviceID)
DECLARE_SETTINGSFACT(CryptoSettings, cryptoKeySource)
DECLARE_SETTINGSFACT(CryptoSettings, cryptoLocalKeyDeviceID)
