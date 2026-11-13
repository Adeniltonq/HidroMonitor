#include "storage.h"

#include <Preferences.h>

#include "config.h"

namespace storage {
namespace {

Preferences prefs;
bool opened = false;

constexpr const char* kNamespace = "hidro";

}  // namespace

bool begin() {
  opened = prefs.begin(kNamespace, false);
  if (!opened) {
    Serial.println(F("[NVS] Falha ao abrir namespace."));
  }
  return opened;
}

bool isProvisioned() {
  if (!opened) return false;
  return prefs.getBool("prov", false);
}

Credentials loadCredentials() {
  Credentials c;
  if (!opened) return c;
  c.ssid = prefs.getString("ssid", "");
  c.wifiPass = prefs.getString("wifi_pass", "");
  c.fbEmail = prefs.getString("fb_email", "");
  c.fbPass = prefs.getString("fb_pass", "");
  c.houseId = prefs.getString("house", "");
  c.deviceId = prefs.getString("device", "");
  c.serial = prefs.getString("serial", "");
  c.provisioned = prefs.getBool("prov", false);
  return c;
}

bool saveCredentials(const Credentials& c) {
  if (!opened) return false;
  bool ok = prefs.putString("ssid", c.ssid) > 0;
  ok = prefs.putString("wifi_pass", c.wifiPass) > 0 && ok;
  ok = prefs.putString("fb_email", c.fbEmail) > 0 && ok;
  ok = prefs.putString("fb_pass", c.fbPass) > 0 && ok;
  ok = prefs.putString("house", c.houseId) > 0 && ok;
  ok = prefs.putString("device", c.deviceId) > 0 && ok;
  ok = prefs.putString("serial", c.serial) > 0 && ok;
  ok = prefs.putBool("prov", c.provisioned) && ok;
  return ok;
}

bool setProvisioned(bool value) {
  if (!opened) return false;
  return prefs.putBool("prov", value) > 0;
}

bool isForceProvisioning() {
  if (!opened) return false;
  return prefs.getBool("force_prov", false);
}

bool setForceProvisioning(bool value) {
  if (!opened) return false;
  return prefs.putBool("force_prov", value) > 0;
}

DeviceConfig loadConfig() {
  DeviceConfig cfg;
  if (!opened) return cfg;
  cfg.version = prefs.getInt("cfg_ver", 1);
  cfg.intervalSec = prefs.getUShort("interval", DEFAULT_INTERVAL_S);
  cfg.sensorWindowSec =
      prefs.getUShort("window_s", DEFAULT_SENSOR_WINDOW_S);
  cfg.ligaCm = prefs.getFloat("liga", DEFAULT_LIGA_CM);
  cfg.desligaCm = prefs.getFloat("desliga", DEFAULT_DESLIGA_CM);
  cfg.minRangeCm = prefs.getFloat("min_range", DEFAULT_MIN_RANGE_CM);
  cfg.maxRangeCm = prefs.getFloat("max_range", DEFAULT_MAX_RANGE_CM);
  cfg.heightCm = prefs.getFloat("height", DEFAULT_HEIGHT_CM);
  cfg.capacityL = prefs.getFloat("capacity", DEFAULT_CAPACITY_L);
  cfg.sensorOffsetCm = prefs.getFloat("offset", DEFAULT_OFFSET_CM);
  cfg.lowLevelPct = prefs.getInt("low_pct", DEFAULT_LOW_PCT);
  cfg.offlineAfterSec = prefs.getULong("offline_s", DEFAULT_OFFLINE_S);
  cfg.sensorFailAfterSec = prefs.getULong("sensor_s", DEFAULT_SENSOR_FAIL_S);
  return cfg;
}

bool saveConfig(const DeviceConfig& cfg) {
  if (!opened) return false;
  bool ok = prefs.putInt("cfg_ver", cfg.version) > 0;
  ok = prefs.putUShort("interval", cfg.intervalSec) > 0 && ok;
  ok = prefs.putUShort("window_s", cfg.sensorWindowSec) > 0 && ok;
  ok = prefs.putFloat("liga", cfg.ligaCm) > 0 && ok;
  ok = prefs.putFloat("desliga", cfg.desligaCm) > 0 && ok;
  ok = prefs.putFloat("min_range", cfg.minRangeCm) > 0 && ok;
  ok = prefs.putFloat("max_range", cfg.maxRangeCm) > 0 && ok;
  ok = prefs.putFloat("height", cfg.heightCm) > 0 && ok;
  ok = prefs.putFloat("capacity", cfg.capacityL) > 0 && ok;
  ok = prefs.putFloat("offset", cfg.sensorOffsetCm) > 0 && ok;
  ok = prefs.putInt("low_pct", cfg.lowLevelPct) > 0 && ok;
  ok = prefs.putULong("offline_s", cfg.offlineAfterSec) > 0 && ok;
  ok = prefs.putULong("sensor_s", cfg.sensorFailAfterSec) > 0 && ok;
  return ok;
}

String loadFirmwareFingerprint() {
  if (!opened) return "";
  return prefs.getString("fw_md5", "");
}

bool saveFirmwareFingerprint(const String& fingerprint) {
  if (!opened) return false;
  return prefs.putString("fw_md5", fingerprint) > 0;
}

bool factoryReset() {
  if (!opened) return false;
  return prefs.clear();
}

}  // namespace storage
