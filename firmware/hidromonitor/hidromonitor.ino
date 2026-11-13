// =============================================================================
//  HIDROMONITOR — firmware de referência do ESP32
// =============================================================================
//
//  Baseado no sketch original do usuário (sensor AJ-SR04M + OLED SSD1306 +
//  relés por 2N2222 + buzzer). Foram acrescentados:
//    - provisioning por BLE (NUS) com as credenciais de Wi-Fi e Firebase;
//    - autenticação Firebase (conta exclusiva do device);
//    - publicação de readings/events/alerts e leitura de config no Firestore;
//    - histerese e segurança local usando config.limits (ligaCm/desligaCm);
//    - NVS (credenciais + config), factory reset pelo botão BOOT.
//
//  O app NÃO comanda bomba/válvula. Todo acionamento é local.
//
//  Bibliotecas: Adafruit SSD1306 + GFX (já instaladas) e ArduinoJson.
//  Placa: ESP32 Dev Module (esp32:esp32:esp32).
// =============================================================================

#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <Wire.h>
#include <time.h>

#include "ble_provisioning.h"
#include "config.h"
#include "firebase_client.h"
#include "storage.h"
#include "types.h"

// ---------------------------------------------------------------------------
// OLED
// ---------------------------------------------------------------------------
#define OLED_LARGURA 128
#define OLED_ALTURA 64
Adafruit_SSD1306 display(OLED_LARGURA, OLED_ALTURA, &Wire, -1);
bool displayOk = false;

// ---------------------------------------------------------------------------
// Estado
// ---------------------------------------------------------------------------
Credentials creds;
DeviceConfig cfg;
FirebaseClient firebase;
BleProvisioning ble;

float distanciaCm = 0.0f;
float nivelPct = 0.0f;
float somaAmostras = 0.0f;
int qtdAmostras = 0;
unsigned long inicioJanela = 0;
unsigned long ultimaAmostra = 0;
bool janelaAtiva = false;
float levelCm = 0.0f;
float volumeL = 0.0f;
bool leituraOk = false;
bool sensorSemEco = false;
unsigned long ultimoEchoUs = 0;

// Controle rápido da bomba: últimas CONTROLE_AMOSTRAS leituras cruas.
float controleAmostras[CONTROLE_AMOSTRAS] = {0};
unsigned long controleAmostraMs[CONTROLE_AMOSTRAS] = {0};
int controleCount = 0;
int controleIdx = 0;
float controleDistanciaCm = 0.0f;
unsigned long ultimaAmostraControle = 0;
unsigned long controleRejeitadas = 0;
int controleSaltoCount = 0;

bool bombaLigada = false;
bool valvulaLigada = false;
unsigned long inicioBomba = 0;
unsigned long inicioValvula = 0;
float nivelInicioBomba = 0.0f;
float nivelRefDryRun = 0.0f;        // coluna d'água na última evolução
unsigned long ultimaChecagemDryRun = 0;
unsigned long inicioSemSubir = 0;

unsigned long ultimaLeitura = 0;
unsigned long ultimoDisplay = 0;
unsigned long ultimoPublish = 0;
unsigned long inicioFalhaSensor = 0;

bool sensorFailAlerted = false;
bool bombaTimeoutAlerted = false;
bool dryRunAlerted = false;
unsigned long ultimoAlertaLow = 0;
unsigned long ultimoAlertaSensor = 0;
unsigned long ultimoAlertaBomba = 0;

bool wifiWasConnected = false;
unsigned long ultimaTentativaWifi = 0;
bool cloudOk = false;
bool configLoaded = false;
unsigned long inicioManual = 0;
unsigned long ultimaMudancaBomba = 0;
bool avisoEsperaMinOn = false;

// Controle manual (comandos do app). Reinicia em automático no boot.
bool modoManual = false;
bool manualLigada = false;
unsigned long ultimoCommandPoll = 0;

unsigned long larguraTriggerUs = 10;

// ---------------------------------------------------------------------------
// Buzzer passivo (PWM via LEDC) — mantido do sketch original
// ---------------------------------------------------------------------------
const int16_t SEQ_BOMBA_LIGOU[] = {200, 0};
const int16_t SEQ_BOMBA_DESLIGOU[] = {150, -150, 150, 0};
const int16_t* buzzerSeq = nullptr;
int buzzerPassoIdx = 0;
unsigned long buzzerPassoIni = 0;

void somBuzzer(bool ligar) {
  ledcWrite(PINO_BUZZER, ligar ? BUZZER_DUTY : 0);
}

void iniciarBuzzer(const int16_t* seq) {
  buzzerSeq = seq;
  buzzerPassoIdx = 0;
  buzzerPassoIni = millis();
  somBuzzer(true);
}

void atualizarBuzzer() {
  if (buzzerSeq == nullptr) return;
  const int16_t passo = buzzerSeq[buzzerPassoIdx];
  if (passo == 0) {
    buzzerSeq = nullptr;
    somBuzzer(false);
    return;
  }
  const unsigned long duracao =
      (passo > 0) ? static_cast<unsigned long>(passo)
                  : static_cast<unsigned long>(-passo);
  if (millis() - buzzerPassoIni >= duracao) {
    buzzerPassoIdx++;
    const int16_t proximo = buzzerSeq[buzzerPassoIdx];
    if (proximo == 0) {
      buzzerSeq = nullptr;
      somBuzzer(false);
    } else {
      buzzerPassoIni = millis();
      somBuzzer(proximo > 0);
    }
  }
}

// ---------------------------------------------------------------------------
// Relés
// ---------------------------------------------------------------------------
void acionarRele(uint8_t pino, bool ligar) {
  const bool nivel = RELE_ATIVO_BAIXO ? !ligar : ligar;
  digitalWrite(pino, nivel ? HIGH : LOW);
}

// ---------------------------------------------------------------------------
// Tempo
// ---------------------------------------------------------------------------
String isoNow() {
  const time_t agora = time(nullptr);
  if (agora < 1700000000) return "";
  struct tm tmUtc;
  gmtime_r(&agora, &tmUtc);
  char buffer[26];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);
  return String(buffer);
}

bool relogioValido() { return time(nullptr) >= 1700000000; }

void sincronizarRelogio() {
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  for (int i = 0; i < 25 && !relogioValido(); i++) {
    delay(300);
  }
}

// ---------------------------------------------------------------------------
// Sensor AJ-SR04M (mesma lógica do sketch original)
// ---------------------------------------------------------------------------
float medirDistancia() {
  digitalWrite(PINO_TRIG, LOW);
  delayMicroseconds(5);
  digitalWrite(PINO_TRIG, HIGH);
  delayMicroseconds(larguraTriggerUs);
  digitalWrite(PINO_TRIG, LOW);

  ultimoEchoUs = pulseIn(PINO_ECHO, HIGH, 60000UL);
  if (ultimoEchoUs < 500) {
    sensorSemEco = true;
    return -1.0f;
  }
  sensorSemEco = false;
  return ultimoEchoUs * 0.0343f / 2.0f;
}


// ---------------------------------------------------------------------------
// Conversões (contrato: cm, %, litros)
// ---------------------------------------------------------------------------
float distanciaParaNivelCm(float d) {
  float nivel = cfg.heightCm + cfg.sensorOffsetCm - d;
  if (nivel < 0) nivel = 0;
  if (nivel > cfg.heightCm) nivel = cfg.heightCm;
  return nivel;
}

/// Converte coluna d'água (cm) em percentual da FAIXA ÚTIL.
///
/// O sensor não mede abaixo de `minRangeCm` (zona cega): essa é a maior coluna
/// d'água que ele consegue enxergar, então é ela que vale 100%. Ex.: caixa de
/// 80 cm com zona cega de 25 cm → 55 cm de coluna = 100% (25 cm de distância),
/// e 80 cm de distância = 0%. Antes 25 cm aparecia como 68,7%.
float nivelParaPercent(float cm) {
  if (cfg.heightCm <= 0) return 0;
  float colunaMaxima = cfg.heightCm - cfg.minRangeCm;
  if (colunaMaxima <= 0 || colunaMaxima > cfg.heightCm) {
    colunaMaxima = cfg.heightCm;  // configuração sem zona cega válida
  }
  float pct = cm / colunaMaxima * 100.0f;
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct;
}

// ---------------------------------------------------------------------------
// OLED
// ---------------------------------------------------------------------------
bool iniciarDisplay() {
  Wire.begin(PINO_SDA, PINO_SCL);
  if (display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    displayOk = true;
  } else if (display.begin(SSD1306_SWITCHCAPVCC, 0x3D)) {
    displayOk = true;
  }
  if (!displayOk) {
    Serial.println(F("[OLED] nao encontrado (SDA=7, SCL=6)"));
    return false;
  }
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(18, 22);
  display.println(F("HIDROMONITOR"));
  display.setCursor(34, 38);
  display.println(F("Iniciando..."));
  display.display();
  return true;
}

void telaModoProvisionamento() {
  if (!displayOk) return;
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(F("HIDROMONITOR"));
  display.setCursor(0, 18);
  display.println(F("MODO PROVISIONAMENTO"));
  display.setCursor(0, 34);
  display.println(F("Abra o app > Parear"));
  display.setCursor(0, 50);
  display.println(F("BLE: HIDRO"));
  display.display();
}

void telaFactoryReset() {
  if (!displayOk) return;
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(F("HIDROMONITOR"));
  display.setCursor(0, 20);
  display.println(F("FACTORY RESET"));
  display.setCursor(0, 38);
  display.println(F("Apagando dados..."));
  display.display();
}

/// Valores para o OLED: usa o caminho rápido (mediana das últimas 4 amostras,
/// ~0,8 s) para o mostrador ser praticamente em tempo real. A média da janela
/// de 20 s continua sendo o que vai para a nuvem/histórico.
void valoresExibicao(float& pct, float& distancia, bool& ok) {
  if (controleValido()) {
    distancia = controleDistanciaCm;
    pct = nivelParaPercent(distanciaParaNivelCm(controleDistanciaCm));
    ok = true;
  } else if (leituraOk) {
    distancia = distanciaCm;
    pct = nivelPct;
    ok = true;
  } else {
    distancia = 0.0f;
    pct = 0.0f;
    ok = false;
  }
}

void atualizarDisplay() {
  float exibePct = 0.0f;
  float exibeDist = 0.0f;
  bool exibeOk = false;
  valoresExibicao(exibePct, exibeDist, exibeOk);

  if (!displayOk) return;
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  display.setTextSize(1);
  display.setCursor(0, 0);
  display.print(F("HIDROMONITOR"));

  display.setTextSize(2);
  display.setCursor(0, 10);
  if (exibeOk) {
    display.print(exibePct, 0);
    display.print(F("%"));
  } else {
    display.print(F("--%"));
  }

  display.setTextSize(1);
  display.setCursor(70, 16);
  if (exibeOk) {
    display.print(exibeDist, 1);
    display.print(F(" cm"));
  } else {
    display.print(F("SEM ECHO"));
  }

  display.drawRect(0, 30, OLED_LARGURA, 10, SSD1306_WHITE);
  if (exibeOk) {
    const int cheio = static_cast<int>(exibePct * (OLED_LARGURA - 4) / 100.0f);
    if (cheio > 0) display.fillRect(2, 32, cheio, 6, SSD1306_WHITE);
  }

  display.setCursor(0, 45);
  display.print(F("BOMBA: "));
  display.print(bombaLigada ? F("ON") : F("off"));
  display.setCursor(72, 45);
  display.print(F("VALV: "));
  display.print(valvulaLigada ? F("ON") : F("off"));

  display.setCursor(0, 55);
  display.print(WiFi.status() == WL_CONNECTED ? F("WiFi OK") : F("WiFi --"));
  display.print(F("  "));
  display.print(cloudOk ? F("CLOUD") : F("offline"));
  display.print(modoManual ? F(" M") : F(" A"));
  display.display();
}

// ---------------------------------------------------------------------------
// Eventos e alertas (best effort; se offline, são descartados)
// ---------------------------------------------------------------------------
bool podePublicar() {
  return WiFi.status() == WL_CONNECTED && relogioValido();
}

void enviarEvento(const char* tipo, const char* detalhe) {
  if (!podePublicar()) return;
  const String ts = isoNow();
  if (ts.isEmpty()) return;
  firebase.postEvent(tipo, detalhe, ts);
}

void enviarAlerta(const char* tipo, const char* severidade,
                  const char* mensagem) {
  if (!podePublicar()) return;
  const String ts = isoNow();
  if (ts.isEmpty()) return;
  firebase.postAlert(tipo, severidade, mensagem, ts);
}

// ---------------------------------------------------------------------------
// Controle local (o app nunca comanda)
// ---------------------------------------------------------------------------
void ligarBomba() {
  bombaLigada = true;
  inicioBomba = millis();
  ultimaMudancaBomba = millis();
  nivelInicioBomba = nivelPct;
  nivelRefDryRun = nivelRapidoCm();
  if (isnan(nivelRefDryRun)) nivelRefDryRun = 0.0f;
  inicioSemSubir = millis();
  ultimaChecagemDryRun = millis();
  bombaTimeoutAlerted = false;
  dryRunAlerted = false;
  acionarRele(PINO_BOMBA, true);

  valvulaLigada = true;
  inicioValvula = millis();
  acionarRele(PINO_VALVULA, true);

  Serial.println(F("[CTRL] bomba ON (nivel baixo); valvula ON"));
  iniciarBuzzer(SEQ_BOMBA_LIGOU);
  enviarEvento("pump_on", "Nivel baixo - acionamento autonomo do firmware");
  enviarEvento("valve_open", "Valvula de irrigacao junto da bomba");
}

void desligarBomba(const char* motivo, bool desligarValvula = true) {
  if (!bombaLigada) return;
  bombaLigada = false;
  ultimaMudancaBomba = millis();
  acionarRele(PINO_BOMBA, false);
  Serial.print(F("[CTRL] bomba OFF: "));
  Serial.println(motivo);
  iniciarBuzzer(SEQ_BOMBA_DESLIGOU);
  enviarEvento("pump_off", motivo);

  if (desligarValvula && valvulaLigada) {
    valvulaLigada = false;
    acionarRele(PINO_VALVULA, false);
    enviarEvento("valve_close", "Valvula fechada");
  }
}

void ligarBombaManual() {
  bombaLigada = true;
  inicioBomba = millis();
  ultimaMudancaBomba = millis();
  nivelInicioBomba = nivelPct;
  bombaTimeoutAlerted = false;
  dryRunAlerted = false;
  acionarRele(PINO_BOMBA, true);
  Serial.println(F("[CTRL] bomba ON manual"));
  iniciarBuzzer(SEQ_BOMBA_LIGOU);
  enviarEvento("manual_on", "Comando manual pelo app");
}

void executarComando(const DeviceCommand& cmd) {
  String status = "done";
  String detalhe;

  if (cmd.action == "pump_on") {
    if (!controleValido()) {
      status = "rejected";
      detalhe = "Sensor sem leitura valida";
    } else if (controleDistanciaCm <= cfg.desligaCm) {
      status = "rejected";
      detalhe = "Caixa cheia (desligaCm)";
    } else {
      modoManual = true;
      inicioManual = millis();
      manualLigada = true;
      ligarBombaManual();
      detalhe = "Bomba ligada manualmente";
    }
  } else if (cmd.action == "pump_off") {
    modoManual = true;
    inicioManual = millis();
    manualLigada = false;
    desligarBomba("Comando manual: desligar");
    enviarEvento("manual_off", "Comando manual pelo app");
    detalhe = "Bomba desligada manualmente";
  } else {  // auto
    modoManual = false;
    manualLigada = false;
    enviarEvento("manual_auto", "Controle automatico restaurado");
    detalhe = "Controle automatico restaurado";
  }

  Serial.print(F("[CMD] "));
  Serial.print(cmd.action);
  Serial.print(F(" -> "));
  Serial.println(status);
  firebase.updateCommand(cmd.id, status, detalhe);
  ultimoPublish = 0;  // publica o novo estado no proximo loop
}

void verificarComandos() {
  const unsigned long agora = millis();
  if (agora - ultimoCommandPoll < COMMAND_POLL_MS) return;
  ultimoCommandPoll = agora;
  if (!podePublicar()) return;

  DeviceCommand cmd;
  if (firebase.fetchPendingCommand(cmd)) {
    executarComando(cmd);
  }
}

void controlarBomba() {
  // O comando manual do app é temporário: sem novo comando, volta ao
  // automático para a caixa não ficar sem enchimento indefinidamente.
  if (modoManual && millis() - inicioManual > MANUAL_TIMEOUT_MS) {
    modoManual = false;
    manualLigada = false;
    Serial.println(F("[CTRL] modo manual expirou; voltando ao automatico"));
    enviarEvento("manual_auto", "Modo manual expirou (15 min)");
  }

  // Decisão liga/desliga usa a mediana das últimas 4 amostras cruas (~0,8 s),
  // independente da janela de 20 s usada para medir/publicar o nível.
  const bool leituraControle = controleValido();
  const float distanciaControle = controleDistanciaCm;

  if (modoManual) {
    if (!manualLigada) {
      if (bombaLigada) desligarBomba("Modo manual: bomba desligada");
    } else if (!leituraControle && inicioFalhaSensor != 0 &&
               millis() - inicioFalhaSensor >=
                   cfg.sensorFailAfterSec * 1000UL) {
      manualLigada = false;
      desligarBomba("Falha no sensor (modo manual)");
    } else if (leituraControle && distanciaControle <= cfg.desligaCm) {
      manualLigada = false;
      desligarBomba("Caixa cheia (modo manual)");
    }
  } else if (leituraControle) {
    const unsigned long agora = millis();
    const bool podeLigar =
        !bombaLigada && (agora - ultimaMudancaBomba >= PUMP_MIN_OFF_MS);
    const bool podeDesligar =
        bombaLigada && (agora - ultimaMudancaBomba >= PUMP_MIN_ON_MS);

    if (podeLigar && distanciaControle >= cfg.ligaCm) {
      ligarBomba();
      if (nivelPct < cfg.lowLevelPct &&
          (ultimoAlertaLow == 0 || millis() - ultimoAlertaLow > 3600000UL)) {
        ultimoAlertaLow = millis();
        enviarAlerta("low_level", "warn",
                     "Nivel abaixo do limiar; bomba acionada pelo firmware");
      }
    } else if (distanciaControle <= cfg.desligaCm) {
      if (podeDesligar) {
        avisoEsperaMinOn = false;
        desligarBomba("Caixa cheia (limite desligaCm)");
      } else if (!avisoEsperaMinOn) {
        // Deixa explícito o motivo da espera (tempo mínimo ligada) no log.
        avisoEsperaMinOn = true;
        const unsigned long restante =
            (PUMP_MIN_ON_MS - (millis() - ultimaMudancaBomba)) / 1000UL;
        Serial.print(F("[CTRL] caixa cheia; desliga em "));
        Serial.print(restante);
        Serial.println(F("s (tempo minimo ligada)"));
      }
    }
  }

  // Falha de sensor: desliga a bomba após o tempo configurado.
  if (!leituraControle) {
    if (inicioFalhaSensor == 0) inicioFalhaSensor = millis();
    const unsigned long limite = cfg.sensorFailAfterSec * 1000UL;
    if (bombaLigada && millis() - inicioFalhaSensor >= limite) {
      manualLigada = false;
      desligarBomba("Falha no sensor ultrassonico");
    }
    if (!sensorFailAlerted && millis() - inicioFalhaSensor >= limite &&
        (ultimoAlertaSensor == 0 ||
         millis() - ultimoAlertaSensor > 1800000UL)) {
      sensorFailAlerted = true;
      ultimoAlertaSensor = millis();
      enviarAlerta("sensor_fail", "crit",
                   "Sensor sem leitura valida; bomba desligada por seguranca");
      enviarEvento("invalid_reading", "Falha persistente do sensor");
    }
  } else {
    inicioFalhaSensor = 0;
    sensorFailAlerted = false;
  }

  // Tempo máximo de corrida (proteção).
  if (bombaLigada && millis() - inicioBomba > MAX_PUMP_RUNTIME_MS) {
    if (!bombaTimeoutAlerted) {
      bombaTimeoutAlerted = true;
      enviarAlerta("pump_timeout", "crit",
                   "Tempo maximo de bomba atingido; desligada por seguranca");
    }
    manualLigada = false;
    desligarBomba("Tempo maximo de corrida");
  }

  // Proteção a seco (janela deslizante): a coluna d'água precisa subir
  // DRY_RUN_GANHO_CM dentro de DRY_RUN_JANELA_MS. Se ficar 5 min sem subir,
  // desliga. O relógio reinicia a cada ganho real de nível.
  if (bombaLigada) {
    if (millis() - ultimaChecagemDryRun >= DRY_RUN_PASSO_MS) {
      ultimaChecagemDryRun = millis();
      const float nivelAgora = nivelRapidoCm();
      if (!isnan(nivelAgora)) {
        if (nivelAgora >= nivelRefDryRun + DRY_RUN_GANHO_CM) {
          nivelRefDryRun = nivelAgora;  // subiu: janela reinicia
          inicioSemSubir = millis();
        } else if (!dryRunAlerted &&
                   millis() - inicioSemSubir >= DRY_RUN_JANELA_MS) {
          dryRunAlerted = true;
          Serial.print(F("[CTRL] sem ganho de nivel por 5 min (ref="));
          Serial.print(nivelRefDryRun, 1);
          Serial.print(F("cm agora="));
          Serial.print(nivelAgora, 1);
          Serial.println(F("cm)"));
          enviarAlerta("dry_run", "crit",
                       "Nivel nao subiu com a bomba ligada; possivel falta de agua");
          manualLigada = false;
          desligarBomba("Protecao a seco (5 min sem subir nivel)");
        }
      }
    }
  }

  // Válvula: no máximo 30 s e somente enquanto a bomba estiver ligada.
  if (valvulaLigada &&
      (millis() - inicioValvula > VALVULA_TEMPO_MAX_MS || !bombaLigada)) {
    valvulaLigada = false;
    acionarRele(PINO_VALVULA, false);
    enviarEvento("valve_close", "Valvula fechada (30 s ou bomba desligada)");
  }
}

// ---------------------------------------------------------------------------
// Wi-Fi / nuvem
// ---------------------------------------------------------------------------
void manterWifi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiWasConnected) {
      wifiWasConnected = true;
      Serial.println(F("[WiFi] conectado"));
      enviarEvento("wifi_conn", "Wi-Fi restabelecido");
    }
    return;
  }

  if (wifiWasConnected) {
    wifiWasConnected = false;
    Serial.println(F("[WiFi] caiu"));
    enviarEvento("wifi_drop", "Wi-Fi indisponivel");
  }

  if (millis() - ultimaTentativaWifi > WIFI_RETRY_MS) {
    ultimaTentativaWifi = millis();
    Serial.println(F("[WiFi] reconectando..."));
    WiFi.disconnect();
    WiFi.begin(creds.ssid.c_str(), creds.wifiPass.c_str());
  }
}

/// Corrige limites fisicamente impossíveis. Ex.: caixa de 80 cm com
/// `ligaCm = 80` só ligaria com a caixa no fundo — 1 cm d'água já dá 79 cm de
/// leitura e o limiar nunca é atingido. Sem isso a bomba pode nunca ligar.
void sanearLimites() {
  bool mudou = false;
  const float distanciaMax = cfg.heightCm - 1.0f;  // caixa vazia

  if (cfg.ligaCm > distanciaMax) {
    cfg.ligaCm = cfg.heightCm * 0.75f;  // liga com ~25% de nível
    mudou = true;
  }
  if (cfg.desligaCm < cfg.minRangeCm) {
    cfg.desligaCm = cfg.minRangeCm;  // abaixo da zona cega não mede
    mudou = true;
  }
  if (cfg.ligaCm <= cfg.desligaCm) {
    cfg.ligaCm = cfg.desligaCm + 10.0f;
    if (cfg.ligaCm > distanciaMax) cfg.ligaCm = distanciaMax;
    mudou = true;
  }

  if (mudou) {
    Serial.print(F("[CFG] limites ajustados: liga="));
    Serial.print(cfg.ligaCm, 1);
    Serial.print(F("cm desliga="));
    Serial.print(cfg.desligaCm, 1);
    Serial.print(F("cm (altura="));
    Serial.print(cfg.heightCm, 1);
    Serial.println(F("cm)"));
    storage::saveConfig(cfg);
  }
}

void aplicarConfigSeNova() {
  DeviceConfig candidato = cfg;
  if (!firebase.fetchConfig(candidato)) return;
  if (!configLoaded || candidato.version > cfg.version) {
    cfg = candidato;
    sanearLimites();
    storage::saveConfig(cfg);
    configLoaded = true;
    Serial.print(F("[CFG] configVersion="));
    Serial.print(cfg.version);
    Serial.print(F(" intervalo="));
    Serial.print(cfg.intervalSec);
    Serial.print(F("s janela="));
    Serial.print(cfg.sensorWindowSec);
    Serial.print(F("s liga="));
    Serial.print(cfg.ligaCm, 1);
    Serial.print(F("cm desliga="));
    Serial.print(cfg.desligaCm, 1);
    Serial.print(F("cm altura="));
    Serial.print(cfg.heightCm, 1);
    Serial.print(F("cm cap="));
    Serial.print(cfg.capacityL, 0);
    Serial.println(F("L"));
  }
}

void publicarCiclo() {
  if (!podePublicar()) {
    cloudOk = false;
    return;
  }
  if (!firebase.ensureToken()) {
    cloudOk = false;
    return;
  }

  const String ts = isoNow();
  if (ts.isEmpty()) {
    cloudOk = false;
    return;
  }

  const int rssi = WiFi.RSSI();
  const bool okReading = firebase.postReading(
      distanciaCm, nivelPct, levelCm, volumeL, bombaLigada, valvulaLigada,
      leituraOk, rssi, ts);
  if (!okReading) {
    cloudOk = false;
    return;
  }

  const bool okLatest = firebase.patchLatest(
      distanciaCm, nivelPct, levelCm, volumeL, bombaLigada, valvulaLigada,
      leituraOk, rssi, ts, ts);

  cloudOk = okLatest;
  aplicarConfigSeNova();
}

// ---------------------------------------------------------------------------
// Leitura + controle + display
// ---------------------------------------------------------------------------
/// Coluna d'água (cm) pela leitura rápida; NAN se não houver leitura válida.
float nivelRapidoCm() {
  if (!controleValido()) return NAN;
  return distanciaParaNivelCm(controleDistanciaCm);
}

/// Guarda a amostra crua para o controle da bomba e recalcula a mediana das
/// últimas CONTROLE_AMOSTRAS (4). A janela de publicação continua separada.
void registrarAmostraControle(float distancia) {
  const unsigned long agora = millis();

  // Rejeita salto fisicamente impossível (eco espúrio). Um passo real só passa
  // depois de CONTROLE_SALTO_CONFIRMA leituras seguidas no novo patamar.
  if (controleCount > 0 &&
      fabsf(distancia - controleDistanciaCm) > CONTROLE_SALTO_MAX_CM) {
    if (++controleSaltoCount < CONTROLE_SALTO_CONFIRMA) {
      controleRejeitadas++;
      return;
    }
  }
  controleSaltoCount = 0;

  controleAmostras[controleIdx] = distancia;
  controleAmostraMs[controleIdx] = agora;
  controleIdx = (controleIdx + 1) % CONTROLE_AMOSTRAS;
  if (controleCount < CONTROLE_AMOSTRAS) controleCount++;

  // Só entram na mediana amostras recentes: com sensor ruidoso as 4 posições
  // podiam guardar leituras de vários segundos atrás.
  float ordenado[CONTROLE_AMOSTRAS];
  int n = 0;
  for (int i = 0; i < controleCount; ++i) {
    if (agora - controleAmostraMs[i] <= CONTROLE_TIMEOUT_MS) {
      ordenado[n++] = controleAmostras[i];
    }
  }
  if (n == 0) return;
  for (int i = 1; i < n; ++i) {  // insertion sort (n <= 4)
    const float chave = ordenado[i];
    int j = i - 1;
    while (j >= 0 && ordenado[j] > chave) {
      ordenado[j + 1] = ordenado[j];
      --j;
    }
    ordenado[j + 1] = chave;
  }

  const float mediana =
      (n % 2 == 1) ? ordenado[n / 2]
                   : (ordenado[n / 2 - 1] + ordenado[n / 2]) / 2.0f;

  controleDistanciaCm = constrain(mediana, cfg.minRangeCm, cfg.maxRangeCm);
  ultimaAmostraControle = agora;
}

/// O controle só decide com leitura recente (evita acionar com eco velho).
bool controleValido() {
  return controleCount > 0 &&
         (millis() - ultimaAmostraControle) <= CONTROLE_TIMEOUT_MS;
}

/// Medição por janela: coleta amostras por SENSOR_WINDOW_MS e publica a media.
/// Nao bloqueia o loop (o controle, display e comandos continuam rodando).
void atualizarLeitura() {
  const unsigned long agora = millis();

  if (!janelaAtiva) {
    janelaAtiva = true;
    inicioJanela = agora;
    ultimaAmostra = 0;
    somaAmostras = 0;
    qtdAmostras = 0;
  }

  if (agora - ultimaAmostra >= SENSOR_SAMPLE_PERIOD_MS) {
    ultimaAmostra = agora;
    const float d = medirDistancia();
    if (d > 1.0f && d < 500.0f) {
      somaAmostras += d;
      qtdAmostras++;
      registrarAmostraControle(d);  // caminho rápido: bomba liga/desliga
    }
  }

  const unsigned long janelaMs =
      static_cast<unsigned long>(cfg.sensorWindowSec) * 1000UL;
  if (agora - inicioJanela >= janelaMs) {
    if (qtdAmostras > 0) {
      float media = somaAmostras / qtdAmostras;
      media = constrain(media, cfg.minRangeCm, cfg.maxRangeCm);
      distanciaCm = media;
      levelCm = distanciaParaNivelCm(media);
      nivelPct = nivelParaPercent(levelCm);
      volumeL = cfg.capacityL * nivelPct / 100.0f;
      leituraOk = true;

      // Diagnóstico: média da janela (publicação) x mediana do controle (bomba).
      Serial.print(F("[MED] janela="));
      Serial.print(media, 1);
      Serial.print(F("cm ("));
      Serial.print(qtdAmostras);
      Serial.print(F(" am., "));
      Serial.print(controleRejeitadas);
      Serial.print(F(" rej.) | controle="));
      Serial.print(controleDistanciaCm, 1);
      Serial.print(F("cm | nivel="));
      Serial.print(nivelPct, 1);
      Serial.print(F("% | bomba="));
      Serial.print(bombaLigada ? F("ON") : F("OFF"));
      Serial.print(F(" | modo="));
      Serial.print(modoManual ? F("MANUAL") : F("AUTO"));
      Serial.print(F(" | liga="));
      Serial.print(cfg.ligaCm, 1);
      Serial.print(F(" desliga="));
      Serial.println(cfg.desligaCm, 1);
    } else {
      leituraOk = false;
      Serial.print(F("[MED] janela sem amostra valida | controle="));
      Serial.print(controleValido() ? controleDistanciaCm : -1.0f, 1);
      Serial.print(F("cm | ultimoEcho="));
      Serial.print(ultimoEchoUs);
      Serial.print(F("us | ECHO em repouso="));
      Serial.println(digitalRead(PINO_ECHO));
      // Mantém o último nível válido (contrato §4) e sinaliza a falha.
    }
    janelaAtiva = false;  // próxima chamada inicia nova janela de 20 s
  }
}

// ---------------------------------------------------------------------------
// Botão BOOT
// ---------------------------------------------------------------------------
bool botaoPressionado() { return digitalRead(PINO_BOOT) == LOW; }
bool botaoProvPressionado() { return digitalRead(PINO_BOTAO) == LOW; }

bool aguardarBotao(unsigned long ms) {
  const unsigned long inicio = millis();
  while (millis() - inicio < ms) {
    if (!botaoPressionado()) return false;
    delay(20);
  }
  return true;
}

bool aguardarBotaoProv(unsigned long ms) {
  const unsigned long inicio = millis();
  while (millis() - inicio < ms) {
    if (!botaoProvPressionado()) return false;
    delay(20);
  }
  return true;
}

/// Detector de pressão longa SEM bloquear o loop. É o que permite o factory
/// reset continuar funcionando dentro do modo provisioning, onde o loop do BLE
/// precisa continuar rodando.
struct BotaoLongo {
  explicit BotaoLongo(uint8_t pino) : pino(pino) {}

  /// Retorna true uma única vez quando o botão completa `ms` pressionado.
  bool atingiu(unsigned long ms) {
    if (digitalRead(pino) != LOW) {
      ativo = false;
      disparado = false;
      return false;
    }
    if (!ativo) {
      ativo = true;
      inicio = millis();
      return false;
    }
    if (!disparado && millis() - inicio >= ms) {
      disparado = true;
      return true;
    }
    return false;
  }

  uint8_t pino;
  bool ativo = false;
  bool disparado = false;
  unsigned long inicio = 0;
};

/// Apaga a NVS e reinicia. Funciona tanto no modo normal quanto no modo
/// provisioning (antes o reset só era verificado no loop normal).
void executarFactoryReset(const char* origem) {
  Serial.print(F("[NVS] factory reset ("));
  Serial.print(origem);
  Serial.println(F(")"));

  // Estado seguro antes de apagar qualquer coisa.
  bombaLigada = false;
  valvulaLigada = false;
  acionarRele(PINO_BOMBA, false);
  acionarRele(PINO_VALVULA, false);

  telaFactoryReset();
  somBuzzer(true);
  delay(150);
  somBuzzer(false);

  // Apaga os bonds/CCCDs do BLE (o "parear" pelas configurações do Android
  // cria vínculos que podem impedir o app de conectar depois).
  ble.clearBonds();

  // Encerra BLE/Wi-Fi para que nada grave na NVS depois da limpeza.
  ble.stop();
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_OFF);

  if (!storage::factoryReset()) {
    Serial.println(F("[NVS] falha ao limpar a NVS; reiniciando mesmo assim"));
  }
  delay(300);
  ESP.restart();
}

// ---------------------------------------------------------------------------
// Provisioning
// ---------------------------------------------------------------------------
void modoProvisionamento(bool forcar) {
  (void)forcar;
  Serial.println(F("[BOOT] modo provisioning"));
  telaModoProvisionamento();
  delay(300);

  ble.begin();
  BotaoLongo botaoBoot(PINO_BOOT);
  BotaoLongo botaoProv(PINO_BOTAO);

  const unsigned long inicio = millis();
  // O encerramento por inatividade é feito dentro de ble.loop(); aqui só existe
  // um limite de segurança bem folgado para nunca cortar um pareamento em curso.
  const unsigned long limite = 30UL * 60UL * 1000UL;
  while (!ble.isProvisioned() && millis() - inicio < limite) {
    ble.loop();

    // Factory reset também no modo configuração: BOOT (GPIO0) ou botão
    // dedicado (GPIO9) por 10 s. Sem isso, um device já resetado ficava preso
    // no provisioning sem nenhuma forma de limpar a NVS de novo.
    if (botaoBoot.atingiu(BOTAO_RESET_MS) ||
        botaoProv.atingiu(BOTAO_RESET_MS)) {
      executarFactoryReset("modo provisioning");
    }
    delay(10);
  }
  // Em sucesso o próprio BLE chama ESP.restart(); aqui só cobrimos timeout.
  ESP.restart();
}

// ---------------------------------------------------------------------------
// Modo normal
// ---------------------------------------------------------------------------
/// Um upload de firmware novo começa do zero. Compara o MD5 do binário que está
/// rodando com o gravado na NVS: se mudou, apaga credenciais, config e Wi-Fi.
/// Assim a NVS nunca herda dados de um software anterior, mesmo quando a
/// gravação não usou "Erase All Flash".
void verificarFirmwareNovo() {
#if WIPE_NVS_ON_NEW_FIRMWARE
  const String atual = ESP.getSketchMD5();
  if (atual.isEmpty()) {
    Serial.println(F("[NVS] nao foi possivel calcular o MD5 do firmware"));
    return;
  }
  const String gravado = storage::loadFirmwareFingerprint();
  if (gravado == atual) return;

  Serial.println(F("[NVS] firmware novo detectado; apagando dados anteriores"));
  if (displayOk) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 20);
    display.println(F("FIRMWARE NOVO"));
    display.setCursor(0, 38);
    display.println(F("Limpando dados..."));
    display.display();
  }
  storage::factoryReset();
  storage::saveFirmwareFingerprint(atual);
  Serial.println(F("[NVS] dados anteriores apagados"));
#endif
}

void setupNormal() {
  cfg = storage::loadConfig();
  creds = storage::loadCredentials();
  sanearLimites();

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(creds.ssid.c_str(), creds.wifiPass.c_str());

  const unsigned long inicio = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - inicio < 15000UL) {
    delay(250);
  }

  if (WiFi.status() == WL_CONNECTED) {
    wifiWasConnected = true;
    Serial.println(F("[WiFi] conectado"));
    sincronizarRelogio();
    firebase.configure(creds);
    if (firebase.signIn()) {
      Serial.println(F("[Firebase] autenticado"));
      aplicarConfigSeNova();
      enviarEvento("boot", "Firmware iniciado");
    } else {
      Serial.println(F("[Firebase] falha no login inicial"));
    }
  } else {
    Serial.println(F("[WiFi] sem conexao no boot; seguindo offline"));
  }

  // Aguarda a primeira janela de medição antes de publicar.
  ultimoPublish = millis();
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(PINO_BOOT, INPUT_PULLUP);
  pinMode(PINO_BOTAO, INPUT_PULLUP);
  pinMode(PINO_BOMBA, OUTPUT);
  pinMode(PINO_VALVULA, OUTPUT);
  pinMode(PINO_TRIG, OUTPUT);
  pinMode(PINO_ECHO, INPUT);

  acionarRele(PINO_BOMBA, false);
  acionarRele(PINO_VALVULA, false);

  ledcAttach(PINO_BUZZER, BUZZER_FREQ_HZ, BUZZER_RES);
  somBuzzer(false);

  iniciarDisplay();

  if (!storage::begin()) {
    Serial.println(F("[NVS] erro; reiniciando em 5 s"));
    delay(5000);
    ESP.restart();
  }

  // Upload de firmware novo: limpa a NVS antes de ler qualquer dado antigo.
  verificarFirmwareNovo();

  // Botão dedicado (GPIO9) no boot: 3 s força o modo provisioning.
  const bool botaoProvBoot =
      botaoProvPressionado() && aguardarBotaoProv(BOTAO_PROV_MS);
  const bool forceFlag = storage::isForceProvisioning();

  if (!storage::isProvisioned() || forceFlag || botaoProvBoot) {
    modoProvisionamento(true);
    return;
  }

  setupNormal();
}

void loop() {
  if (!storage::isProvisioned()) {
    modoProvisionamento(false);
    return;
  }

  atualizarBuzzer();

  // BOOT (GPIO0) por 10 s: factory reset de emergência.
  if (botaoPressionado()) {
    desligarBomba("Botao BOOT pressionado");
    if (aguardarBotao(BOTAO_RESET_MS)) {
      Serial.println(F("[NVS] factory reset (BOOT)"));
      storage::factoryReset();
      delay(300);
      ESP.restart();
    }
  }

  // Botão dedicado: 3 s (soltar) = provisioning sem apagar; 10 s = factory reset.
  if (botaoProvPressionado()) {
    desligarBomba("Botao de provisioning pressionado");
    if (aguardarBotaoProv(BOTAO_PROV_MS)) {
      if (aguardarBotaoProv(BOTAO_RESET_MS - BOTAO_PROV_MS)) {
        Serial.println(F("[NVS] factory reset (botao)"));
        storage::factoryReset();
        delay(300);
        ESP.restart();
      } else {
        Serial.println(F("[NVS] provisioning forcado no proximo boot"));
        storage::setForceProvisioning(true);
        delay(200);
        ESP.restart();
      }
    }
  }

  manterWifi();

  const unsigned long agora = millis();

  if (agora - ultimaLeitura >= SENSOR_LEITURA_MS) {
    ultimaLeitura = agora;
    atualizarLeitura();
  }

  verificarComandos();
  controlarBomba();

  if (agora - ultimoPublish >=
      static_cast<unsigned long>(cfg.intervalSec) * 1000UL) {
    ultimoPublish = agora;
    publicarCiclo();
  }

  if (agora - ultimoDisplay >= SENSOR_DISPLAY_MS) {
    ultimoDisplay = agora;
    atualizarDisplay();
  }

  delay(10);
}
