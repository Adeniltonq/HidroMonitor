// ============================================================================
//  HidroMonitor — configuração de hardware e da nuvem
//  Placa alvo: ESP32 DevKit (ESP32-WROOM-32), core Arduino-ESP32 3.x
// ============================================================================
#pragma once

#include <Arduino.h>

// ---------------------------------------------------------------------------
// Versão e Firebase (projeto monitor-de-caixa-d-agua)
// ---------------------------------------------------------------------------
#define FW_VERSION            "1.0.0"
#define FIREBASE_PROJECT_ID   "monitor-de-caixa-d-agua"
#define FIREBASE_API_KEY      "AIzaSyDs_0r49iwMOMz5VEE_6NKazmU3945BrtQ"

// ---------------------------------------------------------------------------
// Upload / limpeza de dados antigos
// ---------------------------------------------------------------------------
// Cada upload de um binário diferente deve começar do zero. Na primeira vez
// que um firmware novo roda, a NVS é apagada (credenciais, config, Wi-Fi) e o
// device entra no modo provisioning. Defina 0 para preservar o pareamento
// entre atualizações.
#ifndef WIPE_NVS_ON_NEW_FIRMWARE
#define WIPE_NVS_ON_NEW_FIRMWARE 1
#endif

#define FIRESTORE_BASE \
  "https://firestore.googleapis.com/v1/projects/" FIREBASE_PROJECT_ID "/databases/(default)/documents"

// ---------------------------------------------------------------------------
// Pinos — EXATAMENTE como no seu sketch original (sem mudar fiação).
// No ESP32-S3 os GPIO 6 e 7 são livres (a flash do S3 usa outros pinos).
// ---------------------------------------------------------------------------
#define PINO_TRIG        12
#define PINO_ECHO        13
#define PINO_SDA          7
#define PINO_SCL          6
#define PINO_BOMBA       16
#define PINO_VALVULA     15
#define PINO_BUZZER       8

#define PINO_BOOT         0     // botão BOOT da placa (active LOW)
// Botão dedicado (ligar entre GPIO9 e GND; pull-up interno).
// Toque curto (3 s) = modo provisioning; segure 10 s = factory reset.
#define PINO_BOTAO        9
#define BOTAO_PROV_MS  3000UL
#define BOTAO_RESET_MS 10000UL

#define RELE_ATIVO_BAIXO  false // 2N2222 (NPN): HIGH liga o relé

// ---------------------------------------------------------------------------
// BLE — Nordic UART Service (igual ao app)
// ---------------------------------------------------------------------------
#define BLE_SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_RX_UUID       "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_TX_UUID       "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_MTU_ALVO      247
// Encerra a sessão após 5 min sem NENHUMA atividade (conexão/escrita), não
// depois de 5 min desde o boot — antes o device reiniciava no meio do pareamento.
#define BLE_SESSAO_MS     (5UL * 60UL * 1000UL)
// Repetição do handshake enquanto o app não envia o payload: rajada rápida no
// início (para a primeira conexão) e depois devagar (só para quem chegar tarde;
// o app pode pedir um hello a qualquer momento).
#define BLE_HELLO_INTERVAL_MS       1500UL
#define BLE_HELLO_INTERVAL_LONGO_MS 10000UL
#define BLE_HELLO_BURST              10
// Cliente conectado que não escreve nada por este tempo é derrubado: um celular
// "conectado" só pelo Bluetooth do sistema segura o enlace e o ESP32 para de
// anunciar, impedindo o app de encontrar o dispositivo.
// 60 s: alguns Androids demoram na descoberta de serviços/MTU antes da
// primeira escrita; 25 s era curto e derrubava o cliente no meio do pareamento.
#define BLE_CLIENTE_OCIOSO_MS 60000UL
#define BLE_WIFI_TIMEOUT_MS 4000UL                // 3 tentativas de 4 s (~12 s)
#define BLE_AUTH_TIMEOUT_MS 25000UL

// ---------------------------------------------------------------------------
// Comportamento local (segurança — o app NÃO comanda nada)
// ---------------------------------------------------------------------------
#define MAX_PUMP_RUNTIME_MS   (10UL * 60UL * 1000UL)  // 10 min
// Tempo mínimo ligada/desligada nas transições POR NÍVEL: evita o relé bater
// (a água que a bomba joga/respinga no sensor faz ele ler "cheio" por instantes).
// As proteções (falha de sensor, tempo máximo, a seco, comando manual) ignoram.
#ifndef PUMP_MIN_ON_MS
#define PUMP_MIN_ON_MS        (20UL * 1000UL)
#endif
// Proteção a seco: durante a bomba ligada, a coluna d'água tem que subir pelo
// menos DRY_RUN_GANHO_CM dentro de DRY_RUN_JANELA_MS; senão desliga (falta de
// água / bomba perdendo escorva). Verificado a cada DRY_RUN_PASSO_MS.
#ifndef DRY_RUN_JANELA_MS
#define DRY_RUN_JANELA_MS     (5UL * 60UL * 1000UL)
#endif
#ifndef DRY_RUN_PASSO_MS
#define DRY_RUN_PASSO_MS      (30UL * 1000UL)
#endif
#ifndef DRY_RUN_GANHO_CM
#define DRY_RUN_GANHO_CM      1.0f
#endif
// Depois de desligar por proteção a seco, só tenta encher de novo após este
// tempo. Evita ficar ligando a cada 30 s e rodando a seco por mais 5 min.
#ifndef DRY_RUN_BLOQUEIO_MS
#define DRY_RUN_BLOQUEIO_MS   (30UL * 60UL * 1000UL)  // 30 min
#endif
#ifndef PUMP_MIN_OFF_MS
#define PUMP_MIN_OFF_MS       (30UL * 1000UL)
#endif
// Comando manual do app vale por este tempo; depois o controle automatico
// volta sozinho (antes o "desligar" do app travava a bomba para sempre).
#define MANUAL_TIMEOUT_MS     (15UL * 60UL * 1000UL)  // 15 min
#define VALVULA_TEMPO_MAX_MS  (30UL * 1000UL)         // válvula junto da bomba
#define SENSOR_LEITURA_MS        50UL    // tick do acumulador
#define SENSOR_SAMPLE_PERIOD_MS 200UL    // 1 amostra a cada 200 ms
#define DEFAULT_SENSOR_WINDOW_S 20       // configurável no app (5..60 s)
// Liga/desliga da bomba usa só as últimas amostras cruas (mediana), sem
// esperar a janela de publicação — ~0,8 s com 4 amostras de 200 ms.
#define CONTROLE_AMOSTRAS        4
#define CONTROLE_TIMEOUT_MS   3000UL     // sem amostra válida por 3 s: não decide
// Salto maior que isso entre leituras é eco espúrio (o nível de uma caixa não
// muda 20 cm em 200 ms). Só é aceito depois de 3 leituras seguidas no novo
// patamar — protege o relé de ligar/desligar por causa de um eco perdido.
#define CONTROLE_SALTO_MAX_CM   20.0f
#define CONTROLE_SALTO_CONFIRMA 5
#define SENSOR_DISPLAY_MS       250UL  // OLED: 4 atualizações/s (valor do caminho rápido)
#define SENSOR_TIMEOUT_MS      5000UL
#define WIFI_RETRY_MS         (15UL * 1000UL)
#define COMMAND_POLL_MS       (10UL * 1000UL)   // consulta comandos do app
#define CLOUD_RETRY_MIN_MS    (60UL * 1000UL)

#define BUZZER_FREQ_HZ   2700
#define BUZZER_RES       8
#define BUZZER_DUTY      128

// Zona cega / alcance usados enquanto nenhuma config chegou da nuvem
#define DEFAULT_INTERVAL_S     60
#define DEFAULT_LIGA_CM        80.0f
#define DEFAULT_DESLIGA_CM     25.0f
#define DEFAULT_MIN_RANGE_CM   25.0f
#define DEFAULT_MAX_RANGE_CM  150.0f
#define DEFAULT_HEIGHT_CM     100.0f
#define DEFAULT_CAPACITY_L    500.0f
#define DEFAULT_OFFSET_CM       0.0f
#define DEFAULT_LOW_PCT        20
#define DEFAULT_OFFLINE_S     180UL
#define DEFAULT_SENSOR_FAIL_S 180UL
