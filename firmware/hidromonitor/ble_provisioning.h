#pragma once

#include <Arduino.h>
#include <BLECharacteristic.h>
#include <BLEDevice.h>
#include <BLEServer.h>

#include <vector>

#include "firebase_client.h"
#include "types.h"

/// Provisioning BLE (Nordic UART Service) — lado periférico.
///
/// Protocolo (ver docs/CONTRATO_ESP32.md):
///  - hello:   {"op":"hello","ver":1,"mtu":n}  (MTU efetivamente negociado)
///  - frames:  [seq][flags][payload...]  (flags: 0x01 último dado, 0x02 checksum,
///                                        0x04 pedido de hello — sem payload)
///  - ack:     {"op":"ack","seq":n}
///  - stages:  wifi_connecting/wifi_ok/wifi_fail/fb_ok/fb_fail/ready
class BleProvisioning {
 public:
  bool begin();
  void loop();
  void stop();

  /// Apaga bonds/CCCDs gravados pelo host BLE na NVS. Funciona com o BLE ativo
  /// ou não (fora do provisioning ele sobe o host só para limpar e desce).
  void clearBonds();

  bool isProvisioned() const { return provisioned; }

  // Chamados pelos callbacks do BLE (executam na task do BLE).
  void handleConnect();
  void handleDisconnect();
  void handleMtuChange(int mtu);
  void handleWrite(const uint8_t* data, size_t length);

 private:
  enum State { WAIT_PAYLOAD, WIFI_CONNECTING, AUTHENTICATING, READY, FAILED };

  BLEServer* server = nullptr;
  BLECharacteristic* txChar = nullptr;

  Credentials creds;
  volatile State state = WAIT_PAYLOAD;
  volatile bool active = false;
  volatile bool connected = false;
  volatile bool provisioned = false;

  bool lastFrameSeen = false;
  uint8_t expectedSeq = 0;
  std::vector<uint8_t> buffer;

  unsigned long helloAt = 0;
  unsigned long lastActivity = 0;
  unsigned long wifiAttemptAt = 0;
  unsigned long authAttemptAt = 0;
  uint8_t wifiAttempts = 0;
  bool wifiStarted = false;

  int negotiatedMtu = 23;
  uint32_t helloCount = 0;
  String macAddress;

  SemaphoreHandle_t mux = nullptr;

  FirebaseClient firebase;

  void resetSession();
  void sendRaw(const String& message);
  void sendHello();
  void sendAck(uint8_t seq);
  void sendStage(const String& stage, const String& code = "");
  void sendError(const String& code);
  String parsePayload();
  void processWifi();
  void processAuth();

  static String advertisingName();
  static String deviceAddress();
  static uint16_t crc16(const uint8_t* data, size_t length);
  static String isoNow();
};
