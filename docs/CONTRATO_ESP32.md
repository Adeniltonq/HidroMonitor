# Contrato ESP32 ↔ Firebase ↔ App — HidroMonitor

Projeto Firebase: `monitor-de-caixa-d-agua`
Versão do contrato: **1.0** (outubro/2026)
Público-alvo: equipe que fará o **firmware do ESP32 depois**, usando **apenas
este documento** e o `docs/MODELO_DE_DADOS.md`.

> **Escopo:** aqui está a especificação completa do lado do dispositivo:
> autenticação, caminhos, campos, unidades, ciclo de publicação, controle
> autônomo de bomba/válvula, protocolo BLE de provisioning e recomendações.
>
> Este repositório agora inclui uma **implementação de referência** em
> `firmware/hidromonitor/` (ESP32-S3, 16 MB). Ela segue este contrato e serve de
> base para a equipe de firmware; o documento continua sendo a fonte de verdade.

---

## 1. Princípios

1. O **ESP32 é o único** que escreve telemetria (`readings`, `events`, `latest`,
   `lastSeen`).
2. O **app é o único** que escreve `config` (parâmetros) e `configLog`. O device
   **lê** a configuração, nunca a escreve.
3. Bomba e válvula são controladas **localmente**, de forma autônoma, a partir de
   `config.limits`. O app pode **enfileirar comandos manuais** em
   `devices/{deviceId}/commands`; quem executa é sempre o firmware, com as travas
   de segurança. Não há conexão direta app→ESP32.
4. O device se autentica com uma conta Firebase **exclusiva**. O UID dessa conta
   é o valor de `devices/{deviceId}.deviceUid` e é o que as Security Rules usam
   para autorizar escrita.
5. Segredos de Wi-Fi e a senha do device **nunca** entram no Firestore, em logs
   ou em relatórios de crash.

---

## 2. Identidade e autenticação

### 2.1 Credencial

No pareamento, o app cria uma conta Firebase (provedor E-mail/Senha) exclusiva do
device e envia por BLE:

| Campo | Exemplo | Observação |
| --- | --- | --- |
| `fbEmail` | `dev-demo-0001@devices.local` | E-mail da conta do device |
| `fbPass` | `H!xY...` | Senha (24+ caracteres aleatórios) |
| `houseId` | `casa-demo` | Casa no Firestore |
| `deviceId` | `dev-demo-0001` | Documento em `houses/{houseId}/devices` |
| `serial` | `HIDRO-A1B2` | Serial impresso na etiqueta |

O `deviceUid` do documento é o UID retornado na criação da conta. Após assinar
com `signInWithPassword`, o `localId` do ID token **deve** ser igual a
`deviceUid`; caso contrário, todas as escritas serão negadas.

### 2.2 Login via REST (Identity Toolkit)

Obtenha a **Web API Key** em Firebase Console → Project settings → General →
Web API Key.

```http
POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<WEB_API_KEY>
Content-Type: application/json

{ "email": "dev-demo-0001@devices.local", "password": "<fbPass>", "returnSecureToken": true }
```

Resposta (resumida): `idToken` (1 h), `refreshToken`, `localId` (= deviceUid).
Renove o token:

```http
POST https://securetoken.googleapis.com/v1/token?key=<WEB_API_KEY>
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=<refreshToken>
```

Use `Authorization: Bearer <idToken>` em todas as chamadas ao Firestore.

### 2.3 O que o device pode fazer (Security Rules)

| Operação | Permitido |
| --- | --- |
| `GET` no próprio `devices/{deviceId}` | ✅ (para ler `config`) |
| `PATCH` no próprio `devices/{deviceId}` | ✅ somente `latest`, `lastSeen`, `fwVersion` |
| `POST` em `.../readings` | ✅ |
| `POST` em `.../events` | ✅ |
| `GET`/`PATCH` em `.../commands` (próprio device) | ✅ (PATCH só status/executedAt/detail) |
| `POST` em `houses/{houseId}/alerts` | ✅ com `source='device'` e `deviceId` = o próprio |
| Escrita de `config`, `configLog`, `members`, `houses` | ❌ |
| `UPDATE`/`DELETE` de readings/events | ❌ |
| Leitura de outros devices/houses | ❌ |

---

## 3. Caminhos e campos

Base: `projects/monitor-de-caixa-d-agua/databases/(default)/documents`

```
houses/{houseId}                                            (leitura opcional)
houses/{houseId}/devices/{deviceId}                         (GET config; PATCH latest/lastSeen/fwVersion)
houses/{houseId}/devices/{deviceId}/readings/{autoId}       (POST)
houses/{houseId}/devices/{deviceId}/events/{autoId}         (POST)
houses/{houseId}/devices/{deviceId}/commands/{autoId}       (GET lista; PATCH status)
houses/{houseId}/alerts/{autoId}                            (POST)
```

Detalhes completos de campos e tipos: `docs/MODELO_DE_DADOS.md`. Resumo do que o
device escreve:

### 3.1 Reading

| Campo | Tipo | Faixa |
| --- | --- | --- |
| `distanceCm` | double | 0–2000 |
| `levelPercent` | double | 0–100 |
| `levelCm` | double | 0–2000 |
| `volumeL` | double | 0–1.000.000 |
| `pumpOn` | boolean | estado local da bomba |
| `valveOpen` | boolean | estado local da válvula |
| `sensorOk` | boolean | `false` se não houve eco válido |
| `rssi` | int | −150–0 |
| `ts` | timestamp | UTC |

### 3.2 Event

| Campo | Tipo | Enum |
| --- | --- | --- |
| `type` | string | `pump_on`, `pump_off`, `valve_open`, `valve_close`, `boot`, `wifi_drop`, `wifi_conn`, `invalid_reading`, `manual_on`, `manual_off`, `manual_auto` |
| `detail` | string ≤ 500 | texto livre |
| `ts` | timestamp | UTC |

### 3.3 Alerta

| Campo | Tipo | Obrigatório |
| --- | --- | --- |
| `type` | string ≤ 60 | sim (`low_level`, `sensor_fail`, ...) |
| `severity` | `info`/`warn`/`crit` | sim |
| `message` | string ≤ 500 | sim |
| `deviceId` | string | sim (o próprio) |
| `source` | `'device'` | sim |
| `ts` | timestamp | sim |
| `ack` | `false` | sim |
| `ackBy`/`ackTs` | null/ausente | — |

### 3.4 `latest` / `lastSeen`

`latest` tem a mesma estrutura de um reading. `lastSeen` é o instante do último
contato bem-sucedido (UTC). `fwVersion` é string livre.

---

## 4. Unidades e conversões

```
levelCm      = clamp(heightCm + sensorOffsetCm - distanceCm, 0, heightCm)
levelPercent = clamp(levelCm / heightCm * 100, 0, 100)
volumeL      = capacityL * levelPercent / 100
```

- `distanceCm` = sensor → superfície da água.
- `minRangeCm` = zona cega. Se `distanceCm < minRangeCm`, faça clamp em
  `minRangeCm` e trate como **caixa cheia** (nível 100%).
- `maxRangeCm` = alcance máximo. Acima dele, trate como vazio (0%).
- `desligaCm` (default 25) é o limite de **cheia** e deve ser ≥ `minRangeCm`.
- `ligaCm` é o limite de **nível baixo** e deve ser > `desligaCm`.
- `sensorOk=false`: publique `distanceCm = 0` e repita `levelCm/levelPercent/
  volumeL` da última leitura válida (não invente nível).

---

## 5. Ciclo exato de operação

A ordem abaixo é **obrigatória** (o app depende dela para o pareamento e o cache):

```
1. Acordar (timer do deep sleep ou boot)
2. Garantir Wi-Fi + token Firebase (renovar se expirar)
3. Medir o sensor pela janela de `config.sensorWindowSec` (média) e calcular nível/volume
4. Consultar commands pendentes e executar (com travas; §7.1)
5. Decidir bomba/válvula LOCALMENTE (histerese + proteções; §7)
6. POST reading
7. PATCH devices/{id}  → latest + lastSeen  (+ fwVersion se mudou)
8. GET  devices/{id}   → ler config.reportIntervalSec e config.configVersion
9. Se configVersion mudou: aplicar nova config e registrar (opcional) evento
10. Dormir por reportIntervalSec (15..3600)
```

Observações:

- **Não** inverta 6 e 7: o contrato lê a config **após** publicar, para que uma
  alteração feita durante o sono seja aplicada no próximo ciclo.
- Se qualquer passo remoto falhar, mantenha a leitura em buffer NVS e siga para
  o sono com backoff (§10).
- O controle da bomba (passo 4) não depende da nuvem: se o Wi-Fi cair, a
  autonomia continua.

### 5.1 Exemplos REST

Criar reading:

```http
POST https://firestore.googleapis.com/v1/projects/monitor-de-caixa-d-agua/databases/(default)/documents/houses/casa-demo/devices/dev-demo-0001/readings
Authorization: Bearer <idToken>
Content-Type: application/json

{
  "fields": {
    "distanceCm":   {"doubleValue": 88.5},
    "levelPercent": {"doubleValue": 46.5},
    "levelCm":      {"doubleValue": 60.5},
    "volumeL":      {"doubleValue": 465.4},
    "pumpOn":       {"booleanValue": false},
    "valveOpen":    {"booleanValue": false},
    "sensorOk":     {"booleanValue": true},
    "rssi":         {"integerValue": -58},
    "ts":           {"timestampValue": "2026-10-24T15:30:00Z"}
  }
}
```

Atualizar `latest` e `lastSeen` (updateMask garante o diff permitido):

```http
PATCH https://firestore.googleapis.com/v1/projects/monitor-de-caixa-d-agua/databases/(default)/documents/houses/casa-demo/devices/dev-demo-0001?updateMask.fieldPaths=latest&updateMask.fieldPaths=lastSeen
Authorization: Bearer <idToken>
Content-Type: application/json

{
  "fields": {
    "lastSeen": {"timestampValue": "2026-10-24T15:30:02Z"},
    "latest": {
      "mapValue": {
        "fields": {
          "distanceCm":   {"doubleValue": 88.5},
          "levelPercent": {"doubleValue": 46.5},
          "levelCm":      {"doubleValue": 60.5},
          "volumeL":      {"doubleValue": 465.4},
          "pumpOn":       {"booleanValue": false},
          "valveOpen":    {"booleanValue": false},
          "sensorOk":     {"booleanValue": true},
          "rssi":         {"integerValue": -58},
          "ts":           {"timestampValue": "2026-10-24T15:30:00Z"}
        }
      }
    }
  }
}
```

Ler a configuração:

```http
GET https://firestore.googleapis.com/v1/projects/monitor-de-caixa-d-agua/databases/(default)/documents/houses/casa-demo/devices/dev-demo-0001
Authorization: Bearer <idToken>
```

Criar evento:

```http
POST .../devices/dev-demo-0001/events
{ "fields": {
    "type":   {"stringValue": "pump_on"},
    "detail": {"stringValue": "Nível 24% — ligada pelo firmware"},
    "ts":     {"timestampValue": "2026-10-24T15:00:00Z"}
} }
```

Criar alerta:

```http
POST .../houses/casa-demo/alerts
{ "fields": {
    "type":      {"stringValue": "low_level"},
    "severity":  {"stringValue": "warn"},
    "message":   {"stringValue": "Nível abaixo de 20%"},
    "deviceId":  {"stringValue": "dev-demo-0001"},
    "source":    {"stringValue": "device"},
    "ack":       {"booleanValue": false},
    "ts":        {"timestampValue": "2026-10-24T15:00:00Z"}
} }
```

> Use HTTPS com verificação de certificado. O Firestore REST não aceita
> `serverTimestamp` em criação simples; por isso o device precisa de relógio
> confiável (NTP ou cabeçalho `Date` da resposta HTTPS).

---

## 6. `configVersion` — semântica

- Inteiro incrementado **exatamente +1** pelo app a cada alteração de `config`.
- O device guarda em NVS a última versão aplicada (`cfgVer`).
- Ao ler a config:
  - `configVersion == cfgVer` → nada a fazer;
  - `configVersion > cfgVer` → aplicar **todos** os campos, atualizar `cfgVer` e
    usar o novo `reportIntervalSec` no próximo sono;
  - `configVersion < cfgVer` → ignorar (proteção contra dado antigo/cache).
- Não compare campos individualmente para decidir: use a versão.
- O intervalo deve ser validado no firmware (`15 ≤ x ≤ 3600`; fora da faixa,
  usar 60).

---

## 7. Controle de bomba e válvula

O firmware implementa a política. Recomendação de referência:

```
se sensorOk == false:
    bomba = OFF (fail-safe) e alerta sensor_fail (respeitando rate limit)
senão:
    se bomba == OFF e distanceCm >= ligaCm:   bomba = ON   (nível baixo)
    se bomba == ON  e distanceCm <= desligaCm: bomba = OFF  (caixa cheia)
```

- Histerese garantida por `ligaCm > desligaCm`.
- **Tempo máximo de corrida** (ex.: 8 min): desligar e gerar alerta
  `pump_timeout`/`crit`.
- **Proteção a seco:** se a bomba estiver ligada e o nível não subir ao menos
  `Δ` cm em `T` segundos, desligar e alertar.
- **Nunca** acionar a bomba com `sensorOk=false`.
- Válvula: política independente (ex.: irrigação por horário), nunca dependente
  da nuvem.
- Registre `pump_on`/`pump_off`/`valve_open`/`valve_close` como `events`.

Esses limites vêm de `config.limits`. Além do modo automático, existe **controle
manual por comandos** (§7.1), sempre executado pelo firmware com as mesmas
travas.

### 7.1 Comandos manuais (app → Firestore → device)

Caminho: `houses/{houseId}/devices/{deviceId}/commands/{commandId}`

O app (owner/admin) cria:

```json
{
  "action": "pump_on",
  "status": "pending",
  "createdBy": "<uid>",
  "createdByName": "Dona da Casa",
  "createdAt": "<agora>",
  "expiresAt": "<agora + 2 min>"
}
```

`action` ∈ `pump_on` | `pump_off` | `auto`.

O device, a cada **~10 s** (e após o boot), consulta:

```
GET .../devices/{deviceId}/commands?pageSize=3&orderBy=createdAt%20desc
Authorization: Bearer <idToken>
```

Pega o primeiro `status == "pending"` com `expiresAt` no futuro, executa e faz:

```
PATCH .../commands/{id}?updateMask.fieldPaths=status&updateMask.fieldPaths=executedAt&updateMask.fieldPaths=detail
{ "fields": {
    "status": {"stringValue": "done"},
    "executedAt": {"timestampValue": "<agora>"},
    "detail": {"stringValue": "Bomba ligada manualmente"}
} }
```

Semântica:

| action | Efeito no firmware |
| --- | --- |
| `pump_on` | Liga a bomba em modo manual, **se** houver leitura válida e a caixa não estiver cheia. |
| `pump_off` | Desliga a bomba (e fecha a válvula) e mantém override manual até `auto`/reset. |
| `auto` | Limpa o override e volta à histerese `ligaCm`/`desligaCm`. |

Travas que valem também no manual:
- desliga após **10 min** de corrida;
- desliga por **proteção a seco** (nível não sobe);
- desliga por **falha de sensor**;
- desliga ao atingir **caixa cheia** (`desligaCm`);
- `pump_on` é **recusado** (`rejected`) se o sensor estiver inválido ou a caixa cheia;
- o modo manual **não persiste** em reboot: sobe em automático e bomba desligada.

O app não escreve `config` nem `latest` ao enviar comando. O device só pode
atualizar `status`, `executedAt` e `detail` do comando.

---

## 8. Alertas e eventos

- Crie `low_level` quando `levelPercent < alerts.lowLevelPercent`.
- Crie `sensor_fail` após `alerts.sensorFailAfterSec` sem eco válido.
- `offline` **não** é gerado pelo device (quem detecta é o app, por `lastSeen`).
- Rate limit sugerido: no máximo 1 alerta do mesmo `type` por hora, exceto se a
  condição mudar de severidade.
- `invalid_reading` é evento (não alerta) para cada leitura descartada; agrupe
  rajadas para não inundar o Firestore (ex.: 1 evento por minuto).

---

## 9. Medição do sensor ultrassônico

- **Janela de medição**: colete amostras continuamente por
  `config.sensorWindowSec` (padrão **20 s**, configurável no app entre 5 e 60 s)
  e publique a **média aritmética** das distâncias válidas. Ex.: 1 amostra a cada
  200 ms → ~100 amostras por janela.
- Descarte ecos sem resposta e valores absurdos (> 500 cm); faça o clamp da média
  em `[minRangeCm, maxRangeCm]` antes de calcular nível/volume.
- Se nenhuma amostra válida na janela, `sensorOk=false` (mantendo o último nível
  válido). Se persistir por `sensorFailAfterSec`, gere `sensor_fail`.
- Compense `sensorOffsetCm` conforme §4.
- Calibre `heightCm` e `capacityL` na tela de configuração do app.

---

## 10. Resiliência, NVS e relógio

- **Buffer NVS** em anel para leituras não publicadas (ex.: 288 registros = 24 h
  a cada 5 min). Ao reconectar, publique em ordem e limpe o buffer.
- **Backoff** exponencial em falhas de rede/Firebase: 5 s, 15 s, 1 min, 5 min
  (máx. 5 min), com jitter.
- Ao acordar sem Wi-Fi: tente 3 vezes em 20 s; se falhar, durma e tente no
  próximo ciclo (mantendo o controle local ativo).
- **NTP** no boot + re-sync diário; se indisponível, use o header `Date` da
  resposta HTTPS. Nunca publique `ts` sem relógio válido.
- **Watchdog** de hardware; tratar brownout; TLS com validação de certificado.
- Renove o `idToken` antes de expirar (1 h). Guarde `refreshToken` em NVS
  (nunca a senha).
- Evite gravar NVS a cada ciclo (desgaste): persista apenas config/credenciais e
  o buffer quando necessário.

---

## 11. Provisioning BLE — especificação completa (lado periférico)

### 11.1 Modo de provisioning

- Entrar no modo somente se:
  - **primeiro boot** (flag `provisioned` ausente na NVS), ou
  - **botão físico** mantido durante o boot (ex.: 3 s).
- **Nunca** entrar no modo provisioning depois de `ready`.
- Anunciar por no máximo **5 minutos** sem atividade; depois desligar o rádio e
  reiniciar em modo normal (se provisionado) ou dormir (se não).
- Sair do modo após receber e confirmar `ready`.

### 11.2 Advertising

- Nome: **`HIDRO`** (fixo, sem números). É curto de propósito: precisa caber no
  **pacote de advertisement principal junto com o UUID de 128 bits** do NUS
  (3 flags + 18 UUID + 7 nome = 28 de 31 bytes). Com `HIDRO-XXXX` o nome
  transbordava para o scan response e celulares que não mesclam os dois
  pacotes **não encontravam o dispositivo**.
- Incluir o UUID do serviço NUS no advertisement.
- Intervalo de advertisement rápido (**100 ms**) durante o provisioning.
- O MAC do dispositivo vai no `hello` (`mac`), para o app identificar qual
  `HIDRO` é qual quando houver mais de um por perto.
- Conectável, um cliente por vez.

### 11.3 GATT (Nordic UART Service)

| Papel | UUID | Propriedade |
| --- | --- | --- |
| Serviço | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | — |
| RX (app → device) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | Write (com resposta) |
| TX (device → app) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | Notify |

- Após conectar, o app solicita MTU 247. O device deve informar o **MTU
  efetivamente negociado** (`onMtuChanged`) no `hello` — não o valor pedido.
- O device envia `hello` em até 2 s:

```json
{"op":"hello","ver":1,"mtu":247,"name":"HIDRO","mac":"44:BD:8D:75:08:B5"}
```

(uma linha JSON + `\n`).

- Enquanto o app não enviar nenhum frame de dados, o device **repete o `hello`
  a cada 1,5 s** (sem limite de tentativas). Isso cobre o caso em que o celular
  só assina as notificações depois de terminar a descoberta de serviços.
- O app pode pedir o handshake a qualquer momento com um frame sem payload com
  `flags = 0x04` (ver 11.4); o device responde `hello` imediatamente.

### 11.4 Enquadramento (camada de transporte)

Cada escrita no RX é um frame:

```
byte 0: seq   (0..255, incrementa e dá a volta)
byte 1: flags (bit0 = último frame de dados; bit1 = frame de checksum;
               bit2 = pedido de hello — frame sem payload, não consome seq)
bytes 2..N: payload
```

- Tamanho do chunk de dados = `MTU - 3` (ex.: 244 bytes com MTU 247).
- A mensagem é o JSON UTF-8 **terminado em `\n`** (JSON lines), fragmentado.
- O frame de dados final tem `flags & 0x01`.
- Em seguida o app envia **um frame de checksum**: `flags = 0x02`, payload de 2
  bytes big-endian com **CRC16/CCITT-FALSE** (poly `0x1021`, init `0xFFFF`) de
  todos os bytes da mensagem (incluindo o `\n`). Exemplo: CRC de `"123456789"`
  é `0x29B1`.

### 11.5 Ack e retry

- O device responde **cada frame** (inclusive o de checksum) com:

```json
{"op":"ack","seq":<seq do frame>}
```

- O app aguarda até 3 s por ack e reenvia o frame até **3 vezes**, com backoff de
  300 ms × tentativa.
- Se o payload final estiver inválido (seq, checksum, UTF-8, JSON ou campos), o
  device pode responder com o erro opcional abaixo e encerrar a sessão:

```json
{"op":"error","stage":"provisioning","code":"checksum"}
```

Códigos: `seq`, `checksum`, `utf8`, `json`, `fields`, `nvs`.

### 11.6 Payload de provisioning

```json
{
  "op": "prov",
  "provId": "abc123def456",
  "ssid": "MinhaCasa",
  "pass": "senha-do-wifi",
  "fbEmail": "dev-demo-0001@devices.local",
  "fbPass": "senha-do-device",
  "houseId": "casa-demo",
  "deviceId": "dev-demo-0001",
  "serial": "HIDRO-A1B2"
}
```

- Valide `op == "prov"`, presença de todos os campos e limites de tamanho.
- Grave em NVS **somente após** validar checksum/JSON (idealmente criptografado
  com chave no eFuse, se disponível).
- **Nunca** logue `pass` nem `fbPass`; não inclua em crash dumps.

### 11.7 Etapas notificadas

Após validar o payload, o device envia (uma linha JSON cada):

```json
{"op":"stage","s":"wifi_connecting"}
{"op":"stage","s":"wifi_ok"}
{"op":"stage","s":"fb_ok"}
{"op":"stage","s":"ready"}
```

Falhas:

```json
{"op":"stage","s":"wifi_fail","code":"auth"}
{"op":"stage","s":"fb_fail","code":"auth"}
```

Códigos de `wifi_fail`: `auth` (senha), `signal` (sinal fraco), `not_found`
(SSID), `timeout`. Códigos de `fb_fail`: `auth`, `network`, `config`.

- Wi-Fi: até **3 tentativas internas** antes de notificar `wifi_fail` (limite de
  20 s no total para o app).
- Firebase: login + primeira escrita/lastSeen em até **15 s**; senão `fb_fail`.

### 11.8 Timeouts e encerramento

| Etapa | Timeout |
| --- | --- |
| Inatividade da sessão BLE (reinicia o device) | 5 min |
| Wi-Fi | 25 s no app (device tenta 3× de 4 s) |
| Firebase | 30 s |
| Auto-desligamento do advertising | 5 min sem cliente |

> O timeout da sessão conta **inatividade** (última conexão ou escrita), não o
> tempo desde o boot — o device não pode reiniciar no meio de um pareamento.

- Após `ready`: desconectar BLE, parar advertising, marcar NVS
  `provisioned = true` e reiniciar no modo normal.
- Em `wifi_fail`/`fb_fail`/erro de payload: manter o modo provisioning ativo até
  o timeout de 5 min, permitindo retry pelo app.

### 11.9 Factory reset

- Botão físico mantido por **10 s** em operação normal: apagar NVS (credenciais,
  config, flag `provisioned`, buffer), reiniciar e entrar no modo provisioning.
- Não existe factory reset remoto.

---

## 12. Recomendações de firmware

1. **Arquitetura**: tarefa de sensor + tarefa de rede + watchdog; deep sleep entre
   ciclos com `reportIntervalSec` (se o Wi-Fi demorar, considere light sleep).
2. **Medição**: mediana de 5 amostras; descarte outliers; valide faixa.
3. **Autonomia**: controle de bomba/válvula em RAM, com estado persistido em NVS
   para sobreviver a reset (retomar estado seguro: bombas desligadas no boot).
4. **Segurança elétrica**: relé com optoacoplador, snubber, fusível; nunca ligar
   bomba com sensor inválido; tempo máximo de corrida; proteção a seco.
5. **Rede**: TLS verificado, backoff com jitter, reuso de conexão HTTP quando
   possível, limite de payload.
6. **NVS**: buffer em anel, gravação apenas do necessário, verificação de
   integridade (CRC).
7. **Relógio**: NTP no boot; fallback pelo `Date` HTTPS; publicar sempre UTC.
8. **Observabilidade**: eventos de boot/wifi/invalid_reading; não logar segredos.
9. **Atualização**: OTA assinada (opcional, fora do escopo deste contrato).
10. **Conformidade**: o firmware não deve conhecer nenhuma rota de comando; não há
    como o app ligar/desligar a bomba.

---

## 13. Checklist de aceite do firmware

- [ ] Anuncia `HIDRO-XXXX` e expõe o NUS com RX/TX corretos.
- [ ] Envia `hello` com MTU efetivo após conectar.
- [ ] Remonta frames com seq, flag de último e CRC16; responde `ack` por frame.
- [ ] Persiste credenciais em NVS e nunca as loga.
- [ ] Notifica `wifi_connecting` → `wifi_ok`/`wifi_fail` (≤ 20 s).
- [ ] Notifica `fb_ok`/`fb_fail` (≤ 15 s) e `ready`.
- [ ] Sai do provisioning e para o advertising após `ready`.
- [ ] Autentica no Firebase e escreve com o UID == `deviceUid`.
- [ ] Publica reading, atualiza `latest`/`lastSeen`, lê `config`, dorme.
- [ ] Aplica `configVersion` e `reportIntervalSec` no ciclo seguinte.
- [ ] Controla bomba/válvula localmente com histerese e proteções.
- [ ] Bufferiza leituras offline e faz backoff.
- [ ] Factory reset por botão limpa NVS.

---

## 14. Glossário rápido

| Termo | Significado |
| --- | --- |
| `distanceCm` | distância do sensor até a água |
| `levelCm` | altura da coluna d'água (fundo → superfície) |
| `ligaCm` | distância em que a bomba liga (nível baixo) |
| `desligaCm` | distância em que a bomba desliga (cheia) |
| `configVersion` | versão monotônica da configuração |
| `stale` | `now - lastSeen > offlineAfterSec` |
| NUS | Nordic UART Service |
| MTU | Maximum Transmission Unit negociada no BLE |

---

**Fim do contrato.** A implementação de referência está em
`firmware/hidromonitor/`; qualquer firmware alternativo deve seguir este
documento e o modelo de dados.
