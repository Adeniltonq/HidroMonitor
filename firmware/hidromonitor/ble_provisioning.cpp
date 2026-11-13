#include "ble_provisioning.h"

#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEAdvertising.h>
#include <WiFi.h>
#include <esp_mac.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <time.h>

#include <vector>

#if defined(CONFIG_NIMBLE_ENABLED)
#include <host/ble_store.h>
#endif

#include "config.h"
#include "storage.h"

namespace {

BleProvisioning* g_owner = nullptr;

/// Lê um campo de texto do JSON. Sem isso, `as<String>()` em campo ausente
/// devolve a string literal "null" (o ArduinoJson serializa o null), e a
/// validação de campos obrigatórios acabava aceitando payload incompleto.
String texto(JsonVariantConst v) {
  return v.is<const char*>() ? v.as<String>() : String();
}

/// Protege buffer/seq/creds entre a task do BLE (callbacks) e a task do loop().
struct Lock {
  explicit Lock(SemaphoreHandle_t semaphore) : sem(semaphore) {
    if (sem != nullptr) xSemaphoreTake(sem, portMAX_DELAY);
  }
  ~Lock() {
    if (sem != nullptr) xSemaphoreGive(sem);
  }
  SemaphoreHandle_t sem;

 private:
  Lock(const Lock&) = delete;
  Lock& operator=(const Lock&) = delete;
};

class ServerCallbacks : public BLEServerCallbacks {
 public:
  explicit ServerCallbacks(BleProvisioning* owner) : owner_(owner) {}

  void onConnect(BLEServer* server) override { owner_->handleConnect(); }

  void onDisconnect(BLEServer* server) override {
    owner_->handleDisconnect();
    server->startAdvertising();
  }

  // O core 3.x usa NimBLE: (BLEServer*, ble_gap_conn_desc*, uint16_t mtu).
  void onMtuChanged(BLEServer* server, ble_gap_conn_desc* desc,
                    uint16_t mtu) override {
    (void)server;
    (void)desc;
    owner_->handleMtuChange(static_cast<int>(mtu));
  }

 private:
  BleProvisioning* owner_;
};

class RxCallbacks : public BLECharacteristicCallbacks {
 public:
  explicit RxCallbacks(BleProvisioning* owner) : owner_(owner) {}

  void onWrite(BLECharacteristic* characteristic) override {
    owner_->handleWrite(characteristic->getData(),
                        characteristic->getLength());
  }

 private:
  BleProvisioning* owner_;
};

}  // namespace

String BleProvisioning::advertisingName() {
  // Nome curto e sem números: precisa caber no pacote de advertisement JUNTO
  // com o UUID de 128 bits do NUS (3 flags + 18 UUID + 7 nome = 28 de 31).
  // Com o nome antigo ("HIDRO-08B5", 12 bytes) ele não cabia e era empurrado
  // para o scan response — celulares que não mesclam adv + scan response
  // simplesmente não encontravam o dispositivo.
  return "HIDRO";
}

String BleProvisioning::deviceAddress() {
  uint8_t mac[6] = {0, 0, 0, 0, 0, 0};
  if (esp_read_mac(mac, ESP_MAC_BT) != ESP_OK) return "";
  char buffer[18];
  snprintf(buffer, sizeof(buffer), "%02X:%02X:%02X:%02X:%02X:%02X", mac[0],
           mac[1], mac[2], mac[3], mac[4], mac[5]);
  return String(buffer);
}

uint16_t BleProvisioning::crc16(const uint8_t* data, size_t length) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < length; ++i) {
    crc ^= static_cast<uint16_t>(data[i]) << 8;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                           : static_cast<uint16_t>(crc << 1);
    }
  }
  return crc;
}

String BleProvisioning::isoNow() {
  const time_t now = time(nullptr);
  if (now < 1700000000) return "";
  struct tm tmUtc;
  gmtime_r(&now, &tmUtc);
  char buffer[26];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);
  return String(buffer);
}

bool BleProvisioning::begin() {
  g_owner = this;
  if (mux == nullptr) mux = xSemaphoreCreateMutex();
  const String name = advertisingName();
  macAddress = deviceAddress();
  Serial.print(F("[BLE] advertising: "));
  Serial.print(name);
  Serial.print(F(" ("));
  Serial.print(macAddress);
  Serial.println(F(")"));

  BLEDevice::init(name.c_str());
  BLEDevice::setMTU(BLE_MTU_ALVO);

#if defined(CONFIG_NIMBLE_ENABLED)
  // Cada entrada no provisioning começa sem vínculos antigos. Um "parear" feito
  // pelas configurações do Android cria um bond que pode impedir o app de
  // conectar depois; como o firmware não usa bonding, apagamos todos.
  const int rcBonds = ble_store_clear();
  Serial.print(F("[BLE] bonds antigos apagados (rc="));
  Serial.print(rcBonds);
  Serial.println(F(")"));
#endif

  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks(this));

  BLEService* service = server->createService(BLE_SERVICE_UUID);

  BLECharacteristic* rx = service->createCharacteristic(
      BLE_RX_UUID, BLECharacteristic::PROPERTY_WRITE);
  rx->setCallbacks(new RxCallbacks(this));

  txChar = service->createCharacteristic(
      BLE_TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->setName(name.c_str());
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  // Anúncio rápido (100 ms) para o celular achar o device na primeira varredura.
  advertising->setMinInterval(0xA0);
  advertising->setMaxInterval(0xA0);
  advertising->setScanResponse(true);
  advertising->start();

  active = true;
  state = WAIT_PAYLOAD;
  resetSession();
  Serial.print(F("[BLE] handshake a cada "));
  Serial.print(BLE_HELLO_INTERVAL_MS);
  Serial.println(F(" ms enquanto o app não enviar dados"));
  return true;
}

void BleProvisioning::resetSession() {
  {
    Lock lock(mux);
    buffer.clear();
    expectedSeq = 0;
    lastFrameSeen = false;
  }
  helloAt = millis() - BLE_HELLO_INTERVAL_MS;  // primeiro hello imediato
  lastActivity = millis();
  helloCount = 0;
  wifiStarted = false;
  wifiAttempts = 0;
  state = WAIT_PAYLOAD;
}

void BleProvisioning::stop() {
  if (!active) return;
  active = false;
  BLEDevice::deinit(true);
}

void BleProvisioning::clearBonds() {
#if defined(CONFIG_NIMBLE_ENABLED)
  const bool estavaAtivo = active;
  if (!estavaAtivo) {
    // Fora do provisioning o BLE fica desligado. Sobe o host por alguns
    // instantes só para conseguir limpar o store (bonds/CCCDs) na NVS.
    if (!BLEDevice::init(advertisingName().c_str())) {
      Serial.println(F("[BLE] falha ao iniciar para limpar bonds"));
      return;
    }
  }
  const int rc = ble_store_clear();
  Serial.print(F("[BLE] bonds BLE apagados (rc="));
  Serial.print(rc);
  Serial.println(F(")"));
  if (!estavaAtivo) {
    BLEDevice::deinit(true);
  }
#else
  Serial.println(F("[BLE] limpeza de bonds indisponivel neste stack"));
#endif
}

void BleProvisioning::sendRaw(const String& message) {
  if (txChar == nullptr) return;
  txChar->setValue(reinterpret_cast<const uint8_t*>(message.c_str()),
                   message.length());
  txChar->notify();
}

void BleProvisioning::sendHello() {
  String msg = "{\"op\":\"hello\",\"ver\":1,\"mtu\":";
  msg += String(negotiatedMtu);
  msg += ",\"name\":\"";
  msg += advertisingName();
  msg += "\"";
  if (macAddress.length() > 0) {
    msg += ",\"mac\":\"";
    msg += macAddress;
    msg += "\"";
  }
  msg += "}\n";
  sendRaw(msg);
  helloAt = millis();
  helloCount++;
  if (helloCount == 1 || helloCount % 10 == 0) {
    Serial.print(F("[BLE] hello #"));
    Serial.print(helloCount);
    Serial.print(F(" mtu="));
    Serial.println(negotiatedMtu);
  }
}

void BleProvisioning::sendAck(uint8_t seq) {
  String msg = "{\"op\":\"ack\",\"seq\":";
  msg += String(seq);
  msg += "}\n";
  sendRaw(msg);
}

void BleProvisioning::sendStage(const String& stage, const String& code) {
  String msg = "{\"op\":\"stage\",\"s\":\"";
  msg += stage;
  msg += "\"";
  if (code.length() > 0) {
    msg += ",\"code\":\"";
    msg += code;
    msg += "\"";
  }
  msg += "}\n";
  sendRaw(msg);
}

void BleProvisioning::sendError(const String& code) {
  String msg = "{\"op\":\"error\",\"stage\":\"provisioning\",\"code\":\"";
  msg += code;
  msg += "\"}\n";
  sendRaw(msg);
}

void BleProvisioning::handleConnect() {
  connected = true;
  resetSession();
  Serial.println(F("[BLE] cliente conectado"));
}

void BleProvisioning::handleDisconnect() {
  connected = false;
  lastActivity = millis();
  Serial.println(F("[BLE] cliente desconectado"));
  if (!provisioned) {
    resetSession();
    WiFi.disconnect(true);
  }
}

void BleProvisioning::handleMtuChange(int mtu) {
  if (mtu >= 23 && mtu <= 517) {
    negotiatedMtu = mtu;
    // Cliente GATT de verdade: não é uma conexão ociosa do sistema operacional.
    lastActivity = millis();
    Serial.print(F("[BLE] MTU negociado: "));
    Serial.println(mtu);
    // Informa o app imediatamente quando o MTU muda (o chunk depende disso).
    if (connected && !provisioned && !lastFrameSeen) {
      sendHello();
    }
  }
}

void BleProvisioning::handleWrite(const uint8_t* data, size_t length) {
  if (!active || data == nullptr || length < 2) return;

  Lock lock(mux);
  lastActivity = millis();

  const uint8_t seq = data[0];
  const uint8_t flags = data[1];

  // Pedido explícito de handshake (frame sem payload). Resolve a corrida em que
  // o app só assina o CCCD depois dos hellos iniciais.
  if (flags & 0x04) {
    // Ack ANTES do hello: o app espera o hello para começar a enviar e usa o
    // mesmo seq=0 no primeiro frame de dados. Mandando o hello primeiro, o ack
    // do handshake podia chegar depois e ser confundido com o ack do frame 0.
    sendAck(seq);
    sendHello();
    return;
  }

  if (flags & 0x02) {
    // Frame de checksum: 2 bytes big-endian após o header.
    if (length < 4) {
      sendError("checksum");
      return;
    }
    // Retry do frame de checksum: apenas reconfirma.
    if (state != WAIT_PAYLOAD) {
      sendAck(seq);
      return;
    }
    const uint16_t received = (static_cast<uint16_t>(data[2]) << 8) | data[3];
    const uint16_t computed = crc16(buffer.data(), buffer.size());
    sendAck(seq);
    if (received != computed) {
      sendError("checksum");
      return;
    }
    if (!lastFrameSeen) {
      sendError("fields");
      return;
    }
    const String error = parsePayload();
    if (!error.isEmpty()) {
      sendError(error);
      return;
    }
    return;
  }

  // Retry do app reenvia o mesmo seq: apenas reconfirma o ack, sem duplicar.
  if (seq == static_cast<uint8_t>(expectedSeq - 1) && !buffer.empty()) {
    sendAck(seq);
    return;
  }
  if (seq != expectedSeq) {
    Serial.print(F("[BLE] seq fora de ordem: esperado "));
    Serial.print(expectedSeq);
    Serial.print(F(", recebido "));
    Serial.println(seq);
    sendError("seq");
    return;
  }
  if (buffer.size() + (length - 2) > 4096) {
    sendError("json");
    return;
  }
  buffer.insert(buffer.end(), data + 2, data + length);
  if (flags & 0x01) lastFrameSeen = true;
  expectedSeq = static_cast<uint8_t>(expectedSeq + 1);
  sendAck(seq);
}

String BleProvisioning::parsePayload() {
  JsonDocument doc;
  const DeserializationError error =
      deserializeJson(doc, buffer.data(), buffer.size());
  if (error) {
    Serial.print(F("[BLE] JSON invalido: "));
    Serial.println(error.c_str());
    return "json";
  }

  if (texto(doc["op"]) != "prov") return "fields";

  Credentials received;
  received.ssid = texto(doc["ssid"]);
  received.wifiPass = texto(doc["pass"]);
  received.fbEmail = texto(doc["fbEmail"]);
  received.fbPass = texto(doc["fbPass"]);
  received.houseId = texto(doc["houseId"]);
  received.deviceId = texto(doc["deviceId"]);
  received.serial = texto(doc["serial"]);
  received.provisioned = false;

  if (received.ssid.isEmpty() || received.fbEmail.isEmpty() ||
      received.fbPass.isEmpty() || received.houseId.isEmpty() ||
      received.deviceId.isEmpty()) {
    Serial.println(F("[BLE] payload sem campos obrigatorios"));
    return "fields";
  }
  if (received.ssid.length() > 64 || received.wifiPass.length() > 64 ||
      received.fbEmail.length() > 128 || received.fbPass.length() > 128) {
    return "fields";
  }

  creds = received;
  if (!storage::saveCredentials(creds)) {
    return "nvs";
  }

  Serial.println(F("[BLE] payload valido; gravado na NVS"));
  // Não logar ssid/senha.
  sendStage("wifi_connecting");
  state = WIFI_CONNECTING;
  wifiStarted = false;
  wifiAttempts = 0;
  wifiAttemptAt = millis();
  return "";
}

void BleProvisioning::processWifi() {
  const Credentials local = creds;

  if (!wifiStarted) {
    WiFi.mode(WIFI_STA);
    WiFi.disconnect(true);
    delay(100);
    WiFi.begin(local.ssid.c_str(), local.wifiPass.c_str());
    wifiStarted = true;
    wifiAttempts = 0;
    wifiAttemptAt = millis();
    Serial.println(F("[WiFi] conectando..."));
    return;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println(F("[WiFi] conectado"));
    sendStage("wifi_ok");
    state = AUTHENTICATING;
    authAttemptAt = millis();

    // Relógio para o lastSeen (o app confirma o pareamento pela nuvem).
    configTime(0, 0, "pool.ntp.org", "time.google.com");
    return;
  }

  if (millis() - wifiAttemptAt >= BLE_WIFI_TIMEOUT_MS) {
    wifiAttempts++;
    if (wifiAttempts >= 3) {
      String code = "timeout";
      const wl_status_t status = WiFi.status();
      if (status == WL_NO_SSID_AVAIL) {
        code = "not_found";
      } else if (status == WL_CONNECT_FAILED) {
        code = "auth";
      }
      Serial.print(F("[WiFi] falhou: "));
      Serial.println(code);
      sendStage("wifi_fail", code);
      state = FAILED;
      return;
    }
    WiFi.disconnect(true);
    delay(200);
    WiFi.begin(local.ssid.c_str(), local.wifiPass.c_str());
    wifiAttemptAt = millis();
  }
}

void BleProvisioning::processAuth() {
  const Credentials local = creds;

  // Espera o NTP (até 10 s) para o timestamp do lastSeen ser útil ao app.
  if (millis() - authAttemptAt < 10000 && time(nullptr) < 1700000000) {
    return;
  }

  firebase.configure(local);
  if (!firebase.signIn()) {
    Serial.println(F("[Firebase] login falhou"));
    sendStage("fb_fail", "auth");
    state = FAILED;
    return;
  }

  const String ts = isoNow();
  if (ts.isEmpty()) {
    Serial.println(F("[Firebase] sem relogio valido"));
    sendStage("fb_fail", "time");
    state = FAILED;
    return;
  }

  // Primeiro contato: lastSeen é o que o app usa para confirmar o pareamento.
  if (!firebase.patchLastSeen(ts)) {
    Serial.print(F("[Firebase] lastSeen falhou: "));
    Serial.println(firebase.lastError);
    sendStage("fb_fail", "network");
    state = FAILED;
    return;
  }

  sendStage("fb_ok");
  sendStage("ready");
  storage::setProvisioned(true);
  storage::setForceProvisioning(false);
  provisioned = true;
  state = READY;
  Serial.println(F("[BLE] provisionado; reiniciando em modo normal"));
  delay(1500);
  ESP.restart();
}

void BleProvisioning::loop() {
  if (!active) return;

  // Handshake: repete enquanto o app não começou a enviar o payload. Antes era
  // limitado a 8 tentativas em ~7 s, o que quebrava o pareamento quando a
  // descoberta de serviços do celular demorava mais que isso.
  const unsigned long intervalo = helloCount < BLE_HELLO_BURST
                                      ? BLE_HELLO_INTERVAL_MS
                                      : BLE_HELLO_INTERVAL_LONGO_MS;
  if (connected && !provisioned && !lastFrameSeen && state == WAIT_PAYLOAD &&
      millis() - helloAt >= intervalo) {
    sendHello();
  }

  // Cliente ocioso: celular conectado apenas pelo Bluetooth do sistema (ou uma
  // conexão meio-aberta) segura o enlace, e enquanto conectado o ESP32 não
  // anuncia — o app simplesmente não encontra o dispositivo. Derruba para
  // voltar a anunciar. Só vale ANTES do payload: depois disso o app fica só
  // escutando (Wi-Fi/Firebase) e não pode ser desconectado.
  if (state != WAIT_PAYLOAD) {
    lastActivity = millis();
  }
  if (connected && !provisioned && state == WAIT_PAYLOAD &&
      millis() - lastActivity > BLE_CLIENTE_OCIOSO_MS) {
    Serial.println(
        F("[BLE] cliente ocioso; desconectando para voltar a anunciar"));
    if (server != nullptr) server->disconnect(server->getConnId());
    lastActivity = millis();
  }

  const State current = state;
  if (current == WIFI_CONNECTING) {
    processWifi();
  } else if (current == AUTHENTICATING) {
    processAuth();
  }

  // Auto-desligamento por INATIVIDADE (não conta o tempo desde o boot): o
  // device não pode reiniciar no meio de um pareamento em andamento.
  if (!provisioned && millis() - lastActivity > BLE_SESSAO_MS) {
    Serial.println(F("[BLE] timeout de sessao; reiniciando"));
    stop();
    delay(200);
    ESP.restart();
  }
}
