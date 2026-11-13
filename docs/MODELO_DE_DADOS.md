# Modelo de dados — HidroMonitor

Projeto Firebase: `monitor-de-caixa-d-agua`
Banco: Firestore (modo nativo, database `(default)`)
Versão deste documento: 1.0 · outubro/2026

O app lê telemetria, grava parâmetros de configuração e pode **enfileirar
comandos manuais** em `devices/{deviceId}/commands`. Quem executa é sempre o
firmware do ESP32, aplicando as travas locais (tempo máximo, proteção a seco,
falha de sensor e caixa cheia). O modo padrão continua autônomo, por
`config.limits`.

---

## 1. Convenções

| Item | Convenção |
| --- | --- |
| Timestamps | `Timestamp` do Firestore (UTC). No app, convertidos para `DateTime` local. |
| IDs | `houseId`/`deviceId`: IDs automáticos (20 caracteres) ou slugs (`casa-demo`). `memberId` = UID do Firebase Auth. `inviteId` = código do convite. |
| E-mail | sempre minúsculo no convite; o e-mail do usuário vem do Firebase Auth. |
| Unidades | distância e coluna d'água em **cm**; volume em **litros**; nível em **%**; intervalo/tempos em **segundos**; RSSI em **dBm**. |
| Autoridades | Cliente só grava o que as rules permitem; toda validação é repetida no servidor. |

### 1.1 Campos auxiliares (desnormalizações deliberadas)

O modelo principal está exatamente como especificado. Dois campos extras são
necessários para funcionalidades que o Firestore não resolve por caminho:

| Documento | Campo | Por quê |
| --- | --- | --- |
| `members/{uid}` | `uid` | Permite listar as casas do usuário com `collectionGroup('members').where('uid','==',uid)`. O ID do documento é o UID, mas queries de collection group não filtram por `documentId()`. |
| `members/{uid}` | `inviteCode` (opcional) | Auditoria de qual convite originou o vínculo e validação do aceite pelas Security Rules (que não conseguem enumerar convites). |
| `invites/{code}` | `usedBy` | UID de quem aceitou o convite (gravado junto com `used: true`). |

---

## 2. Árvore de coleções

```
users/{uid}
houses/{houseId}
houses/{houseId}/members/{uid}
houses/{houseId}/invites/{code}
houses/{houseId}/alerts/{alertId}
houses/{houseId}/configLog/{logId}
houses/{houseId}/devices/{deviceId}
houses/{houseId}/devices/{deviceId}/readings/{readingId}
houses/{houseId}/devices/{deviceId}/events/{eventId}
houses/{houseId}/devices/{deviceId}/commands/{commandId}
```

---

## 3. Coleções e campos

### 3.1 `users/{uid}`

Perfil mínimo do usuário. Criado no cadastro e atualizável apenas pelo dono.

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `name` | string (1–80) | sim | Nome exibido. Único campo editável. |
| `email` | string | sim | E-mail da conta (imutável no doc). |
| `createdAt` | timestamp | sim | Igual a `request.time` na criação. |

```json
{
  "name": "Dona da Casa",
  "email": "owner@demo.br",
  "createdAt": "2026-10-21T12:00:00Z"
}
```

### 3.2 `houses/{houseId}`

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `name` | string (1–80) | sim | Nome da casa. Editável por owner/admin. |
| `ownerUid` | string | sim | UID do fundador. **Imutável** — protege o último owner. |
| `createdAt` | timestamp | sim | Criação. |

```json
{
  "name": "Casa Demo",
  "ownerUid": "1f2e...owner",
  "createdAt": "2026-10-21T12:00:00Z"
}
```

### 3.3 `houses/{houseId}/members/{uid}`

Vínculo usuário↔casa. O ID do documento é o UID.

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `role` | `'owner' \| 'admin' \| 'viewer'` | sim | Papel no isolamento multi-inquilino. |
| `name` | string (1–80) | sim | Nome no momento do ingresso. |
| `email` | string (1–160) | sim | E-mail no momento do ingresso. |
| `joinedAt` | timestamp | sim | Igual a `request.time`. |
| `uid` | string | sim | Desnormalização = ID (ver §1.1). |
| `inviteCode` | string | não | Código usado no aceite (auditoria). |

```json
{
  "role": "admin",
  "name": "Administrador Demo",
  "email": "admin@demo.br",
  "joinedAt": "2026-10-21T12:00:00Z",
  "uid": "2a3b...admin"
}
```

### 3.4 `houses/{houseId}/invites/{code}`

Convite. O ID do documento é o código (8 caracteres, alfabeto sem ambíguos).
`get` exige conhecer o código exato; `list` só para owner/admin.

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `role` | `'admin' \| 'viewer'` | sim | Papel concedido (nunca `owner`). Admin só pode convidar `viewer`. |
| `emailOpcional` | string \| null | não | Restringe o aceite a esse e-mail. |
| `createdBy` | string | sim | UID de quem criou. |
| `createdAt` | timestamp | sim | Criação. |
| `expiresAt` | timestamp | sim | Expiração (padrão: +14 dias). |
| `used` | boolean | sim | `false` até o aceite. |
| `usedBy` | string | não | UID de quem aceitou. |

```json
{
  "role": "viewer",
  "emailOpcional": null,
  "createdBy": "1f2e...owner",
  "createdAt": "2026-10-24T15:00:00Z",
  "expiresAt": "2026-11-07T15:00:00Z",
  "used": false
}
```

> O aceite é um batch atômico: cria `members/{uid}` (com `inviteCode`) e marca
> `invites/{code}.used = true`, `usedBy = uid`.

### 3.5 `houses/{houseId}/devices/{deviceId}`

Documento central da caixa. Configuração escrita por owner/admin; telemetria
resumida escrita **apenas** pelo dispositivo autenticado.

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `name` | string (1–80) | sim | Nome amigável. |
| `serial` | string (1–64) | sim | Serial físico (ex.: `HIDRO-A1B2`). |
| `deviceUid` | string | sim | UID da conta Firebase exclusiva do ESP32. |
| `fwVersion` | string | sim | Versão do firmware. |
| `createdAt` | timestamp | sim | Cadastro (pareamento). |
| `lastSeen` | timestamp | não | Último contato autenticado do device. |
| `config` | map | sim | Ver §3.5.1. Nunca escrito pelo device. |
| `latest` | map | não | Última telemetria. Ver §3.5.2. Nunca escrito por humano/app. |

#### 3.5.1 `config`

| Campo | Tipo | Default | Regra |
| --- | --- | --- | --- |
| `configVersion` | int | 1 | Incrementa **exatamente +1** a cada alteração. |
| `reportIntervalSec` | int | 60 | 15 ≤ x ≤ 3600. |
| `sensorWindowSec` | int | 20 | Janela de medição: o ESP32 coleta amostras por 5–60 s e publica a média. |
| `limits.ligaCm` | number | 80 | Distância (sensor→água) em que a bomba **liga**. |
| `limits.desligaCm` | number | 25 | Distância em que a bomba **desliga** (caixa cheia/zona cega). |
| `tank.format` | `'cilindro' \| 'retangular' \| 'livre'` | `'livre'` | Geometria. |
| `tank.heightCm` | number > 0 | — | Altura interna útil. |
| `tank.diameterCm` | number > 0 | — | Obrigatório se `cilindro`. |
| `tank.lengthCm` / `tank.widthCm` | number > 0 | — | Obrigatórios se `retangular`. |
| `tank.capacityL` | number > 0 | — | Capacidade nominal (fonte de verdade do volume). |
| `tank.sensorOffsetCm` | number ≥ 0 | 0 | Distância do sensor ao topo interno da caixa. |
| `tank.minRangeCm` | number ≥ 0 | 25 | Zona cega do ultrassônico. |
| `tank.maxRangeCm` | number > minRange | 150 | Alcance máximo confiável. |
| `tank.calibration` | array<{percent, liters}> | não | Tabela manual de litros por %. Com 2+ pontos, o app interpola e usa esses valores no lugar de `capacityL` linear. Vazio/ausente = linear. |
| `alerts.lowLevelPercent` | int 0–100 | 20 | Limiar de nível baixo. |
| `alerts.offlineAfterSec` | int ≥ 30 | 3× intervalo | Limiar de "stale"/offline. |
| `alerts.sensorFailAfterSec` | int ≥ 30 | 180 | Tempo de falha do sensor para alerta. |
| `updatedAt` | timestamp | — | Igual a `request.time` no update. |
| `updatedBy` | string | — | UID do owner/admin que salvou. |

Validações server-side: `desligaCm >= tank.minRangeCm`, `ligaCm > desligaCm`,
`ligaCm <= maxRangeCm`, `capacityL > 0`, `heightCm > 0`, `maxRangeCm >
minRangeCm`, geometria obrigatória conforme o formato, faixas de intervalo e
limiares. `configVersion` só pode ser `resource.configVersion + 1`.

#### 3.5.2 `latest`

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `distanceCm` | number 0–2000 | Sensor → superfície da água. |
| `levelPercent` | number 0–100 | Nível relativo. |
| `levelCm` | number 0–2000 | Coluna d'água desde o fundo. |
| `volumeL` | number ≥ 0 | Volume derivado. |
| `pumpOn` | boolean | Estado **informado** pelo firmware (não comandado pelo app). |
| `valveOpen` | boolean | Estado informado. |
| `sensorOk` | boolean | `false` quando não houve eco válido. |
| `rssi` | int −150–0 | Sinal Wi-Fi. |
| `ts` | timestamp | Momento da leitura. |

```json
{
  "name": "Caixa do telhado",
  "serial": "HIDRO-DEMO-0001",
  "deviceUid": "uDEVICE123",
  "fwVersion": "0.9.0",
  "createdAt": "2026-10-21T12:00:00Z",
  "lastSeen": "2026-10-24T15:30:00Z",
  "config": {
    "configVersion": 4,
    "reportIntervalSec": 60,
    "limits": { "ligaCm": 100, "desligaCm": 25 },
    "tank": {
      "format": "cilindro",
      "heightCm": 130,
      "diameterCm": 100,
      "capacityL": 1000,
      "sensorOffsetCm": 20,
      "minRangeCm": 25,
      "maxRangeCm": 150
    },
    "tank": {
      "format": "cilindro",
      "heightCm": 130,
      "diameterCm": 100,
      "capacityL": 1000,
      "sensorOffsetCm": 20,
      "minRangeCm": 25,
      "maxRangeCm": 150,
      "calibration": [
        { "percent": 0, "liters": 0 },
        { "percent": 20, "liters": 180 },
        { "percent": 50, "liters": 500 },
        { "percent": 80, "liters": 820 },
        { "percent": 100, "liters": 1000 }
      ]
    },
    "alerts": {
      "lowLevelPercent": 20,
      "offlineAfterSec": 180,
      "sensorFailAfterSec": 180
    },
    "updatedAt": "2026-10-24T14:00:00Z",
    "updatedBy": "1f2e...owner"
  },
  "latest": {
    "distanceCm": 88.5,
    "levelPercent": 46.5,
    "levelCm": 60.5,
    "volumeL": 465.4,
    "pumpOn": false,
    "valveOpen": false,
    "sensorOk": true,
    "rssi": -58,
    "ts": "2026-10-24T15:30:00Z"
  }
}
```

### 3.6 `houses/{houseId}/devices/{deviceId}/readings/{id}`

Série histórica imutável. `create` só pelo device autenticado; `update`/`delete`
negados.

| Campo | Tipo |
| --- | --- |
| `distanceCm` | number 0–2000 |
| `levelPercent` | number 0–100 |
| `levelCm` | number 0–2000 |
| `volumeL` | number ≥ 0 |
| `pumpOn` | boolean |
| `valveOpen` | boolean |
| `sensorOk` | boolean |
| `rssi` | int −150–0 |
| `ts` | timestamp |

```json
{
  "distanceCm": 88.5,
  "levelPercent": 46.5,
  "levelCm": 60.5,
  "volumeL": 465.4,
  "pumpOn": false,
  "valveOpen": false,
  "sensorOk": true,
  "rssi": -58,
  "ts": "2026-10-24T15:30:00Z"
}
```

### 3.7 `houses/{houseId}/devices/{deviceId}/events/{id}`

Linha do tempo do dispositivo. `type` ∈ `pump_on`, `pump_off`, `valve_open`,
`valve_close`, `boot`, `wifi_drop`, `wifi_conn`, `invalid_reading`,
`manual_on`, `manual_off`, `manual_auto`.

| Campo | Tipo |
| --- | --- |
| `type` | string (enum acima) |
| `detail` | string ≤ 500 |
| `ts` | timestamp |

```json
{ "type": "pump_on", "detail": "Nível 24% — ligada pelo firmware", "ts": "2026-10-24T15:00:00Z" }
```

### 3.8 `houses/{houseId}/alerts/{alertId}`

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `type` | string (1–60) | Ex.: `low_level`, `sensor_fail`, `offline`, `config_changed`. |
| `severity` | `'info' \| 'warn' \| 'crit'` | |
| `message` | string ≤ 500 | Texto exibido. |
| `deviceId` | string | Device relacionado. |
| `source` | `'device' \| 'app'` | Origem. |
| `ts` | timestamp | Igual a `request.time`. |
| `ack` | boolean | `false` na criação. |
| `ackBy` | string \| null | UID do membro que reconheceu. |
| `ackTs` | timestamp \| null | Momento do reconhecimento. |

```json
{
  "type": "low_level",
  "severity": "warn",
  "message": "Nível da caixa abaixo de 20%. Bomba acionada automaticamente.",
  "deviceId": "dev-demo-0001",
  "source": "device",
  "ts": "2026-10-23T02:05:00Z",
  "ack": false,
  "ackBy": null,
  "ackTs": null
}
```

`ack` é o único update permitido, por qualquer membro (inclusive viewer):
`ack: true`, `ackBy = uid`, `ackTs = request.time`. Delete: owner/admin.

### 3.9 `houses/{houseId}/configLog/{logId}`

Auditoria imutável de configuração.

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `ts` | timestamp | Igual a `request.time`. |
| `byUid` | string | Quem salvou. |
| `byName` | string | Nome de exibição. |
| `changes` | map<caminho, {old, new}> | No máximo 50 entradas. |

```json
{
  "ts": "2026-10-24T14:00:00Z",
  "byUid": "1f2e...owner",
  "byName": "Dona da Casa",
  "changes": {
    "config.configVersion": { "old": 3, "new": 4 },
    "config.reportIntervalSec": { "old": 60, "new": 120 },
    "config.limits.desligaCm": { "old": 25, "new": 30 }
  }
}
```

O app grava `device.config` e `configLog` no **mesmo batch** (atômico), com
`configVersion` incrementado. `update`/`delete` são negados.

### 3.10 `houses/{houseId}/devices/{deviceId}/commands/{commandId}`

Pedido de controle manual. O app **enfileira**; o ESP32 consulta, executa e
marca o resultado. O comando expira se o device estiver offline.

| Campo | Tipo | Obrigatório | Descrição |
| --- | --- | --- | --- |
| `action` | `'pump_on' \| 'pump_off' \| 'auto'` | sim | Ação desejada. |
| `status` | `'pending' \| 'done' \| 'rejected'` | sim | `pending` na criação; device atualiza. |
| `createdBy` | string | sim | UID do owner/admin. |
| `createdByName` | string (1–80) | sim | Nome exibido no app. |
| `createdAt` | timestamp | sim | Igual a `request.time`. |
| `expiresAt` | timestamp | sim | Validade (o app usa +2 min). |
| `executedAt` | timestamp | não | Preenchido pelo device. |
| `detail` | string ≤ 300 | não | Motivo de recusa ou detalhe da execução. |

```json
{
  "action": "pump_on",
  "status": "pending",
  "createdBy": "1f2e...owner",
  "createdByName": "Dona da Casa",
  "createdAt": "2026-10-24T18:00:00Z",
  "expiresAt": "2026-10-24T18:02:00Z"
}
```

Regras: create só owner/admin (nunca viewer); leitura por membros e pelo device;
update só pelo device e somente `status`/`executedAt`/`detail`; delete
owner/admin. O comando não altera `config` nem `configVersion`.

---

## 4. Unidades, fórmulas e semântica

```
levelCm      = heightCm + sensorOffsetCm - distanceCm      (clamp 0..heightCm)
levelPercent = levelCm / heightCm * 100                     (clamp 0..100)
volumeL      = capacityL * levelPercent / 100        (sem calibração)
volumeL      = interpolação de tank.calibration      (com 2+ pontos)
```

A tabela `tank.calibration` é preenchida manualmente no app (tela
**Configurações da caixa → Mostrar em litros**). Cada ponto informa quantos
litros existem em determinado `percent` (0–100). O app interpola linearmente
entre pontos e usa o resultado no medidor, no histórico e no cálculo de consumo;
os pontos devem ser crescentes em percent e em litros, com 0% e 100% presentes.

- `distanceCm` é a distância do **sensor** até a superfície da água. Quanto maior,
  menor o nível.
- `minRangeCm` é a zona cega: abaixo dela o eco não é confiável. O firmware deve
  tratar distâncias menores como **caixa cheia** (clamp em `minRangeCm`).
- `desligaCm` é o limite inferior de distância (= cheia) e deve ser ≥
  `minRangeCm`. Default 25 cm.
- `ligaCm` é o limite superior (= nível baixo) e deve ser > `desligaCm`.
- `sensorOk=false` indica ausência de eco válido; nesse caso o firmware mantém
  `levelCm`/`levelPercent`/`volumeL` da última leitura válida e publica
  `distanceCm = 0`, para que o app não interprete o valor como medição real.

---

## 5. Matriz de permissões

Legenda: ✅ permitido, ❌ negado, 🔸 restrito (ver observação).

| Recurso | Ação | owner | admin | viewer | device (uid = deviceUid) |
| --- | --- | --- | --- | --- | --- |
| `users/{uid}` | read/update (name) | ✅ (próprio) | ✅ (próprio) | ✅ (próprio) | ❌ |
| `houses` | read | ✅ | ✅ | ✅ | ❌ |
| `houses` | create | ✅ (ownerUid = próprio uid) | ✅ | ✅ | ❌ |
| `houses` | update (name) | ✅ | ✅ | ❌ | ❌ |
| `members` | read | ✅ | ✅ | ✅ | ❌ |
| `members` | create | ✅ governance | 🔸 só `viewer` | 🔸 auto-ingresso por convite | ❌ |
| `members` | update | ✅ exceto fundador | 🔸 só viewer, sem mudar papel | ❌ | ❌ |
| `members` | delete | ✅ exceto fundador | 🔸 só viewer | ❌ | ❌ |
| `invites` | get (com código) | ✅ | ✅ | ✅ | ❌ |
| `invites` | list/create/delete | ✅ | 🔸 cria só viewer | ❌ | ❌ |
| `invites` | aceitar | ✅ | ✅ | ✅ | ❌ |
| `devices` | read | ✅ | ✅ | ✅ | 🔸 só o próprio doc |
| `devices` | create/delete | ✅ | ✅ | ❌ | ❌ |
| `devices` | update telemetria (`latest`,`lastSeen`,`fwVersion`) | ❌ | ❌ | ❌ | ✅ |
| `devices` | update config | ✅ | ✅ | ❌ | ❌ |
| `readings` | read | ✅ | ✅ | ✅ | ❌ (lê só o device doc) |
| `readings` | create | ❌ | ❌ | ❌ | ✅ |
| `readings` | update/delete | ❌ | ❌ | ❌ | ❌ |
| `events` | idem readings | | | | ✅ create |
| `alerts` | read | ✅ | ✅ | ✅ | ❌ |
| `alerts` | create | 🔸 `source='app'` | 🔸 `source='app'` | 🔸 `source='app'` | ✅ `source='device'` |
| `alerts` | ack | ✅ | ✅ | ✅ | ❌ |
| `alerts` | delete | ✅ | ✅ | ❌ | ❌ |
| `configLog` | read | ✅ | ✅ | ✅ | ❌ |
| `configLog` | create | ✅ | ✅ | ❌ | ❌ |
| `configLog` | update/delete | ❌ | ❌ | ❌ | ❌ |
| `commands` | read | ✅ | ✅ | ✅ | ✅ (próprio device) |
| `commands` | create | ✅ | ✅ | ❌ | ❌ |
| `commands` | update (status/executedAt/detail) | ❌ | ❌ | ❌ | ✅ |
| `commands` | delete | ✅ | ✅ | ❌ | ❌ |

Observações:

- O **fundador** (`houses.ownerUid`) não pode ser removido nem rebaixado; o próprio
  owner também não pode se rebaixar. Isso garante ao menos um owner sempre.
- Convites nunca concedem `owner`; admin só cria convite `viewer`.
- O device só altera `latest`, `lastSeen` e `fwVersion` (diff verificado nas rules).
- O app nunca escreve `latest`, `readings` nem `events`.

---

## 6. Fluxos

### 6.1 Alteração de configuração (configVersion + configLog)

1. Owner/admin abre **Configurações da caixa**; o formulário é preenchido com a
   config atual.
2. Validação local: intervalo 15–3600, `desligaCm ≥ minRangeCm`,
   `ligaCm > desligaCm`, capacidade > 0, geometria coerente.
3. Diálogo de confirmação com aviso de segurança (o app não aciona nada).
4. Um único batch:
   - `devices/{id}` ← `config` com `configVersion = anterior + 1`,
     `updatedAt = serverTimestamp`, `updatedBy = uid`;
   - `configLog/{auto}` ← `{ts, byUid, byName, changes}` com `old`/`new`.
5. O ESP32 lê `config.reportIntervalSec` e `configVersion` ao fim de cada ciclo e
   aplica o novo intervalo no próximo sono.

### 6.2 Pareamento BLE

1. App cria uma conta Firebase exclusiva do device em uma **instância secundária**
   (`Firebase.initializeApp(name: 'device-provisioning')`), sem deslogar o usuário.
2. App cria `devices/{deviceId}` com config default (`configVersion: 1`,
   `reportIntervalSec: 60`, `desligaCm: 25`) e `deviceUid = uid` da conta do device.
3. App envia via BLE (NUS) `ssid`, `pass`, `fbEmail`, `fbPass`, `houseId`,
   `deviceId`, `serial` — ver `CONTRATO_ESP32.md`.
4. O ESP32 conecta no Wi-Fi, autentica no Firebase com a credencial recebida e
   publica a primeira telemetria.
5. App aguarda até 60 s um `lastSeen` posterior ao início do pareamento; só então
   mostra sucesso. O ESP32 sai do modo provisioning ao receber/emitir `ready`.
6. Nenhum segredo é gravado no Firestore. `ssid`, senha do Wi-Fi e `fbPass`
   existem apenas em memória durante o wizard.

### 6.3 Convites

1. Owner (admin/viewer) ou admin (viewer) cria o convite; o app gera um código de
   8 caracteres e grava `invites/{code}`.
2. O app compartilha um texto com **ID da casa + código** (o convite é
   subcoleção, então o ID é necessário).
3. O convidado autentica, informa ID + código e o app:
   - lê o convite (`get` exige conhecer o código);
   - valida `used`, `expiresAt` e `emailOpcional`;
   - cria `members/{uid}` e marca `used/usedBy` no mesmo batch.
4. A partir daí o convite aparece como usado e não pode ser reutilizado.

### 6.4 Alertas e reconhecimento

- Device cria `alerts` com `source='device'`, `ack=false`.
- O app lista por `ts desc`, mostra severidade e permite **Reconhecer**.
- O ack é idempotente por regra: só `false → true`, com `ackBy = uid` e
  `ackTs = request.time`. O alerta continua no histórico.

### 6.5 Consumo (estimativa)

O app soma quedas de `volumeL` entre leituras consecutivas quando:

- `sensorOk` verdadeiro nas duas leituras;
- `pumpOn` falso nas duas (evita contar reposição);
- intervalo entre leituras ≤ 5 × `reportIntervalSec` (evita superestimar em
  lacunas);
- a diferença é negativa (queda).

O resultado é agrupado por dia local (00:00) e usado nas telas **Consumo** e no
cartão do dashboard.

### 6.6 Stale / offline / cache

- `stale` = `now - lastSeen > config.alerts.offlineAfterSec` (default 3× o
  intervalo). A tela **Conexão** e os chips do dashboard refletem isso.
- Quando o snapshot do Firestore vem do cache local, a UI mostra o banner
  **"Exibindo dados em cache"**.

### 6.7 Controle manual (comandos)

1. Owner/admin toca em **Ligar bomba**, **Desligar bomba** ou **Reset (auto)** na
   tela **Bomba e válvula** e confirma o diálogo de segurança.
2. O app cria `commands/{id}` com `status='pending'` e `expiresAt = now + 2 min`.
   Viewer não consegue criar.
3. O ESP32 consulta `commands?orderBy=createdAt desc` a cada ~10 s, autenticado
   como device, e pega o comando pendente mais recente ainda válido.
4. O device executa **localmente** e atualiza `status` para `done`/`rejected`
   com `executedAt` e `detail`.
5. O app ouve a coleção em tempo real e mostra o resultado.
6. Se o device estiver offline além de `expiresAt`, o comando não é executado
   (o app mostra "expirado").

Travas do firmware, mesmo no modo manual: tempo máximo de bomba (10 min),
proteção a seco, falha de sensor e corte por `desligaCm` (caixa cheia). O modo
manual **não** sobrevive a reboot: o device sobe em automático com bomba
desligada. `auto`/reset limpa o override.

---

## 7. Índices

Definidos em `backend/firestore.indexes.json`:

| Collection group | Campo | Ordem | Escopo |
| --- | --- | --- | --- |
| `readings` | `ts` | ASC + DESC | COLLECTION |
| `events` | `ts` | ASC + DESC | COLLECTION |
| `alerts` | `ts` | ASC + DESC | COLLECTION |
| `configLog` | `ts` | ASC + DESC | COLLECTION |
| `commands` | `createdAt` | ASC + DESC | COLLECTION |
| `members` | `uid` | ASC | COLLECTION_GROUP |

Consultas usadas: histórico `orderBy('ts', desc).limit(50)` com `startAfter`;
eventos/alertas/configLog `orderBy('ts', desc)`; listagem de casas via
`collectionGroup('members').where('uid','==',uid)`.

---

## 8. Defaults e limites

| Parâmetro | Default | Faixa |
| --- | --- | --- |
| `reportIntervalSec` | 60 | 15–3600 |
| `limits.desligaCm` | 25 | ≥ `minRangeCm` |
| `limits.ligaCm` | 80 | > `desligaCm` e ≤ `maxRangeCm` |
| `tank.minRangeCm` | 25 | ≥ 0 |
| `tank.maxRangeCm` | 150 | > `minRangeCm` |
| `alerts.lowLevelPercent` | 20 | 1–100 |
| `alerts.offlineAfterSec` | 180 (3×60) | ≥ 30 |
| `alerts.sensorFailAfterSec` | 180 | ≥ 30 |
| `configVersion` | 1 | inteiro ≥ 1, sempre +1 |
| `sensorWindowSec` | 20 | 5–60 s |

---

## 9. Estrutura do seed (demo)

`backend/scripts/seed-demo.js` (idempotente):

- Casa `casa-demo` ("Casa Demo"), fundador `owner@demo.br`.
- Membros: `owner@demo.br` (owner), `admin@demo.br` (admin), `viewer@demo.br`
  (viewer) — senha `Demo@12345`.
- Device `dev-demo-0001` com credencial própria em `dev-demo-0001@devices.local`
  (senha aleatória impressa na execução, nunca gravada no Firestore).
- Config: intervalo 60 s, `desligaCm` 25, `ligaCm` 100, caixa cilíndrica 130 cm ×
  100 cm de diâmetro, 1000 L.
- 3 dias de leituras a cada 5 min (864), com consumo diurno, ciclos de bomba,
  3 leituras inválidas, boot, queda/retorno de Wi-Fi, 3 alertas (low_level
  pendente, sensor_fail e offline reconhecidos) e `configLog` inicial.
- Convite `DEMO2026` (viewer, 30 dias, não usado).
