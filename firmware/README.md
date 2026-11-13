# Firmware de referência — ESP32-S3

Implementação de referência do firmware do HidroMonitor, baseada no sketch
original do usuário (sensor AJ-SR04M + OLED SSD1306 + relés + buzzer) e no
contrato `docs/CONTRATO_ESP32.md`.

> **Hardware alvo:** ESP32-S3 Dev Module, **16 MB de flash** e **PSRAM OPI de
> 8 MB** (módulo N16R8), com a fiação original do sketch. O mesmo código compila
> para o ESP32 clássico.

## O que o firmware faz

- Provisioning por BLE (NUS) com as credenciais de Wi-Fi e Firebase do device.
- Persistência em NVS (credenciais, config, flag `provisioned`).
- Login no Firebase, publicação de `readings`, atualização de `latest`/`lastSeen`,
  leitura de `config` e escrita de `events`/`alerts`.
- Controle **local** de bomba/válvula (histerese por `ligaCm`/`desligaCm`,
  tempo máximo de bomba, proteção a seco, falha de sensor).
- OLED com nível, distância, bomba/válvula e status de conexão.
- Buzzer, factory reset por botão BOOT ou botão dedicado (também no modo
  provisioning).

O app não envia comandos de atuação.

## Pinagem (ESP32-S3)

| Função | GPIO S3 | Observação |
| --- | --- | --- |
| TRIG (sensor) | 12 | igual ao sketch original |
| ECHO (sensor) | 13 | use divisor se o sensor estiver em 5 V |
| SDA (OLED) | 7 | igual ao seu sketch original |
| SCL (OLED) | 6 | igual ao seu sketch original |
| Relé bomba | 16 | 2N2222 (HIGH liga) |
| Relé válvula | 15 | 2N2222 (HIGH liga) |
| Buzzer passivo | 8 | PWM via LEDC |
| Botão BOOT | 0 | factory reset (10 s) |
| Botão dedicado | 9 | 3 s no boot = provisioning; 10 s = factory reset |

> ** Nenhuma mudança de fiação:** mantivemos exatamente os pinos do seu sketch
> (SDA 7, SCL 6, TRIG 12, ECHO 13, bomba 16, válvula 15, buzzer 8).
>
> O ECHO do AJ-SR04M em 5 V não pode ir direto ao ESP32/S3: use divisor de
> tensão (1k/2k) ou alimente o sensor em 3,3 V.

## Bibliotecas

No Arduino IDE (Gerenciador de Bibliotecas):

- **ArduinoJson** (testado com 7.4.3)
- **Adafruit SSD1306** + **Adafruit GFX Library** (já instaladas no seu ambiente)

## Configuração da Arduino IDE (obrigatória)

Ferramentas → Placa → **ESP32S3 Dev Module**:

| Opção | Valor |
| --- | --- |
| Flash Size | **16MB (128Mb)** |
| PSRAM | **OPI PSRAM** (módulo N16R8; QSPI só se o módulo for R2) |
| Partition Scheme | **16M Flash (3MB APP/9.9MB FATFS)** |
| Upload Speed | 921600 (ou 460800 se falhar) |
| USB CDC On Boot | Enabled (se a placa usar USB nativo) |

Sem o partition scheme de 3 MB o sketch não cabe (usa ~1,36 MB, mas o default
de 1,2 MB é pequeno).

## Compilar (arduino-cli)

```bash
arduino-cli compile \
  --fqbn "esp32:esp32:esp32s3:FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB" \
  firmware/hidromonitor
```

No ESP32 clássico:

```bash
arduino-cli compile --fqbn "esp32:esp32:esp32:PartitionScheme=huge_app" firmware/hidromonitor
```

## Gravar (sempre com flash limpo)

O upload **apaga todo o flash antes de gravar** (`EraseFlash=all` → opção `-e`
do esptool). Isso remove firmware antigo, NVS, OTA e a partição FAT, para que
nenhum dado de uma gravação anterior sobreviva:

```bash
arduino-cli upload -p /dev/ttyACM0 \
  --fqbn "esp32:esp32:esp32s3:FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB,EraseFlash=all" \
  firmware/hidromonitor
```

(no Linux, ajuste a porta; no Windows, `COMx`).

Na Arduino IDE: **Ferramentas → Erase All Flash Before Sketch Upload →
Enabled** antes de clicar em Upload.

Além da gravação limpa, o próprio firmware protege contra NVS herdada: ele
guarda na NVS o MD5 do binário em execução e, no primeiro boot de um firmware
diferente, apaga credenciais/config/Wi-Fi e entra no modo provisioning. Para
preservar o pareamento entre atualizações, defina
`WIPE_NVS_ON_NEW_FIRMWARE 0` em `hidromonitor/config.h`.

## Primeiro uso

1. Ligue o ESP32 sem provisioning: ele entra no modo **PROVISIONAMENTO** e
   anuncia `HIDRO` por BLE.
2. No app: casa → **Parear dispositivo** → nome/serial + SSID/senha (2,4 GHz).
3. O app cria a conta Firebase do device, envia o payload, acompanha as etapas e
   confirma o `lastSeen` na nuvem.
4. O ESP32 grava na NVS, reinicia e passa a publicar telemetria no intervalo
   configurado (60 s por default).

Para forçar o modo provisioning depois de provisionado: segure o botão
dedicado (GPIO9) durante o boot por 3 s. Para **factory reset**: segure
**BOOT (GPIO0)** ou o botão dedicado por 10 s. O reset funciona também quando o
device **já está no modo configuração** (provisionamento): ele apaga a NVS,
apaga os **bonds BLE** (`ble_store_clear`), reinicia e volta a anunciar para um
novo pareamento.

> O reset apaga o vínculo do lado do ESP32. Se o Android ainda tiver o `HIDRO`
> “pareado” nas configurações de Bluetooth, use **Esquecer dispositivo** no
> celular também; essa memória é do telefone e o firmware não consegue apagá-la.

## Comportamento

- Não usa deep sleep (o OLED precisa ficar ligado); o ciclo é contínuo e publica
  a cada `reportIntervalSec` (15–3600 s).
- Se o Wi-Fi cair, o controle local continua e o firmware tenta reconectar a
  cada 15 s. Leituras feitas offline não são bufferizadas nesta versão (o
  contrato recomenda buffer NVS em produção).
- `configVersion` mais novo é aplicado após cada publicação; versão menor é
  ignorada.
- Alertas: `low_level`, `sensor_fail`, `pump_timeout`, `dry_run` (device).
- Eventos: `boot`, `pump_on/off`, `valve_open/close`, `wifi_drop/conn`,
  `invalid_reading`.
- TLS **valida o certificado** com as raízes da Google Trust Services (GTS R1–R4) embutidas em `certs.h`.
- Segredos (Wi-Fi/Firebase) nunca são impressos no Serial.

## Limitações conhecidas

- Publicação HTTP é síncrona (bloqueia o loop por alguns segundos a cada ciclo).
  Para produção, mover para uma task FreeRTOS.
- Sem OTA e sem buffer de leituras offline.
- O controle da válvula segue a política local do sketch original (abre junto da
  bomba por até 30 s); o app não a comanda.
