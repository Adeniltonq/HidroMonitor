# HidroMonitor 💧

Sistema de **monitoramento e automação de caixa d'água**: um **ESP32-S3** mede o
nível, controla localmente a bomba/válvula e envia a telemetria para o
**Firebase**. Um **app Android em Flutter** mostra tudo em tempo real e permite
configurar o sistema.

> **ESP32 mede e controla → Firebase armazena → app Flutter visualiza e configura.**

---

## Funcionalidades

- **Nível em tempo real** — leitura por sensor ultrassônico (AJ-SR04M),
  indicador de nível, tendência (enchendo/esvaziando/estável), sparkline e gauge.
- **Histórico e consumo** — leituras por período, cálculo de consumo e
  exportação em **CSV**.
- **Detecção de dispositivo offline** — aviso quando os dados estão
  desatualizados.
- **Automação da bomba** — controle **local no ESP32** por histerese
  (`ligaCm`/`desligaCm`), com proteções: tempo máximo de acionamento, proteção a
  seco, falha de sensor e caixa cheia. Se a internet cair, a bomba para do mesmo
  jeito.
- **Multiusuário** — várias casas, com papéis `owner` / `admin` / `viewer` e
  convites por código. Cada casa é isolada pelas regras do Firestore.
- **Provisionamento por BLE** — o app envia Wi-Fi (2,4 GHz) e credenciais do
  device ao ESP32 por Bluetooth, sem servidor de setup.
- **Diagnóstico** — status do dispositivo, versão de firmware, última
  comunicação e eventos.

---

## Stack

| Camada | Tecnologia |
| --- | --- |
| App | Flutter (Material 3), Provider, go_router, fl_chart, flutter_blue_plus |
| Backend | Firebase Auth + Firestore (regras e índices), scripts Node (firebase-admin) |
| Firmware | ESP32-S3, Arduino core 3.3.12, ArduinoJson, BLE (NUS), Firebase REST |
| Alvo | Android (minSdk 24) |

---

## Estrutura

```
.
├── app/                      # app Flutter (Android)
│   ├── lib/                  # ble/, core/, models/, services/, state/, ui/
│   └── test/                 # testes (codec BLE, consumo, CSV, payload...)
├── backend/
│   ├── firestore.rules       # regras de segurança
│   ├── firestore.indexes.json
│   └── scripts/              # seed-demo.js, export-db.js
├── firmware/
│   ├── hidromonitor/         # sketch ESP32-S3
│   └── flash.sh              # compila e grava via arduino-cli
├── docs/
│   ├── MODELO_DE_DADOS.md    # coleções, campos e regras
│   └── CONTRATO_ESP32.md     # protocolo app ↔ ESP32 ↔ nuvem
└── firebase.json / .firebaserc
```

---

## Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) (stable) + Android SDK
- [Node.js](https://nodejs.org) 20+
- [Firebase CLI](https://firebase.google.com/docs/cli) (`npm i -g firebase-tools`)
- Seu próprio projeto Firebase (troque o ID em `.firebaserc` e gere a configuração
  do app com `flutterfire configure`)
- Para o firmware: `arduino-cli` (ou Arduino IDE) com suporte a ESP32-S3

---

## Configuração

### 1. Firebase

Ative o **Authentication → E-mail/Senha** no Console e faça o deploy das regras:

```bash
firebase login
firebase use --add                     # seleciona seu projeto
firebase deploy --only firestore:rules,firestore:indexes
```

### 2. App

O app precisa apontar para **seu** projeto Firebase. Gere a configuração:

```bash
cd app
flutterfire configure --platforms=android --yes
flutter pub get
```

### 3. Dados de demonstração (opcional)

```bash
cd backend
npm install
npm run seed
```

O seed é idempotente e cria três usuários com senha `Demo@12345`:

| Usuário | Papel |
| --- | --- |
| `owner@demo.br` | owner |
| `admin@demo.br` | admin |
| `viewer@demo.br` | viewer |

Além de uma casa `casa-demo`, um device de exemplo, 3 dias de leituras, eventos,
alertas, config inicial e o convite `DEMO2026`.

### 4. Firmware

```bash
firmware/flash.sh          # requer arduino-cli e a placa conectada
```

Detalhes de pinagem, compilação e opções: [`firmware/README.md`](firmware/README.md).

---

## Como usar

### Rodar o app em modo debug

```bash
cd app
flutter run                # emulador ou celular Android conectado
```
### Gerar o APK

```bash
cd app
flutter build apk --debug              # para testes
flutter build apk --release
flutter build appbundle --release      # para a Play Store
```

APKs gerados ficam em `app/build/app/outputs/flutter-apk/` (`app-arm64-v8a-release.apk`
é o recomendado para celulares modernos).

Instalar via cabo:

```bash
adb install -r app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Ou copie o APK para o celular e permita instalar de fontes desconhecidas.

### Parear o ESP32 (BLE)

1. Faça login no app e escolha a casa.
2. Toque em **Parear dispositivo**.
3. Informe nome, serial e SSID/senha do Wi-Fi **2,4 GHz**.
4. O app cria o device no Firebase e envia as credenciais ao ESP32 por BLE.
5. Quando o ESP32 publicar a primeira leitura, o app confirma o pareamento.

Protocolo completo: [`docs/CONTRATO_ESP32.md`](docs/CONTRATO_ESP32.md).

---

## Testes e validação

```bash
cd app && flutter analyze && flutter test
cd backend && npm run seed          # idempotente
```

---

## Licença

Uso privado. Se for publicar/distribuir o código, adicione um arquivo `LICENSE`
com a licença desejada (ex.: MIT).
