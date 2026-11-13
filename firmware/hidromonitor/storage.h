#pragma once

#include "types.h"

namespace storage {

/// Abre a NVS (namespace "hidro").
bool begin();

bool isProvisioned();

Credentials loadCredentials();
bool saveCredentials(const Credentials& credentials);
bool setProvisioned(bool value);

/// Pede para entrar no modo provisioning no próximo boot (sem apagar dados).
bool isForceProvisioning();
bool setForceProvisioning(bool value);

DeviceConfig loadConfig();
bool saveConfig(const DeviceConfig& config);

/// Impressão digital (MD5) do binário que gravou os dados atuais. Usada para
/// detectar um upload de firmware novo e limpar a NVS no primeiro boot.
String loadFirmwareFingerprint();
bool saveFirmwareFingerprint(const String& fingerprint);

/// Apaga TODAS as chaves (factory reset). Reinicie depois.
bool factoryReset();

}  // namespace storage
