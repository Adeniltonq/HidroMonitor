#pragma once

#include <Arduino.h>

/// Credenciais recebidas por BLE no provisioning e persistidas em NVS.
/// Nunca são enviadas ao Firestore nem impressas no Serial.
struct Credentials {
  String ssid;
  String wifiPass;
  String fbEmail;
  String fbPass;
  String houseId;
  String deviceId;
  String serial;
  bool provisioned = false;
};

/// Comando manual enfileirado pelo app (Firestore) para o device executar.
struct DeviceCommand {
  String id;
  String action;          // pump_on | pump_off | auto
  String createdByName;
};

/// Configuração da caixa, espelho de houses/{houseId}/devices/{deviceId}.config
struct DeviceConfig {
  int version = 1;
  uint16_t intervalSec = 60;
  uint16_t sensorWindowSec = 20;
  float ligaCm = 80.0f;
  float desligaCm = 25.0f;
  float minRangeCm = 25.0f;
  float maxRangeCm = 150.0f;
  float heightCm = 100.0f;
  float capacityL = 500.0f;
  float sensorOffsetCm = 0.0f;
  int lowLevelPct = 20;
  uint32_t offlineAfterSec = 180;
  uint32_t sensorFailAfterSec = 180;
};
