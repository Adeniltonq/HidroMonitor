#!/usr/bin/env node
/**
 * seed-demo.js — popula a "Casa Demo" no Firestore para desenvolvimento do app.
 *
 * Regras:
 *  - Idempotente: documentos têm IDs fixos e as subcoleções de telemetria são
 *    apagadas e recriadas a cada execução.
 *  - A senha do usuário-dispositivo NUNCA vai para o Firestore: é gerada em
 *    memória, usada para autenticar o ESP32 no provisioning e impressa no fim.
 *  - Nenhuma leitura simula atuação vinda do app: o app é somente leitura de
 *    telemetria + configuração de parâmetros.
 *
 * Uso:
 *   export SEED_SERVICE_ACCOUNT=/caminho/serviceAccountKey.json
 *   cd backend && npm install && npm run seed
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const admin = require('firebase-admin');

// ---------------------------------------------------------------------------
// Configuração / credenciais
// ---------------------------------------------------------------------------
function loadEnvFile() {
  const envPath = path.join(__dirname, '..', '.env');
  if (!fs.existsSync(envPath)) return;
  for (const raw of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf('=');
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim().replace(/^["']|["']$/g, '');
    if (!process.env[key]) process.env[key] = value;
  }
}
loadEnvFile();

function resolveCredentials() {
  const fromEnv = process.env.SEED_SERVICE_ACCOUNT || process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (fromEnv) {
    const resolved = path.isAbsolute(fromEnv) ? fromEnv : path.resolve(process.cwd(), fromEnv);
    if (!fs.existsSync(resolved)) {
      throw new Error(`Arquivo de service account não encontrado: ${resolved}`);
    }
    const json = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    return { credential: admin.credential.cert(json), projectId: json.project_id };
  }
  // fallback: Application Default Credentials (gcloud auth application-default login)
  return { credential: admin.credential.applicationDefault(), projectId: undefined };
}

const { credential, projectId } = resolveCredentials();
admin.initializeApp({
  credential,
  projectId: process.env.FIREBASE_PROJECT_ID || projectId,
});

const db = admin.firestore();
const auth = admin.auth();
const FieldValue = admin.firestore.FieldValue;

// ---------------------------------------------------------------------------
// Constantes do cenário
// ---------------------------------------------------------------------------
const HOUSE_ID = 'casa-demo';
const DEVICE_ID = 'dev-demo-0001';
const DEVICE_EMAIL = 'dev-demo-0001@devices.local';
const DEMO_PASSWORD = 'Demo@12345';
const STEP_SECONDS = 300; // 5 min
const DAYS = 3;
const TANK = {
  format: 'cilindro',
  heightCm: 130,
  diameterCm: 100,
  capacityL: 1000,
  sensorOffsetCm: 20,
  minRangeCm: 25,
  maxRangeCm: 150,
  // Tabela manual de litros por % (exemplo; o app interpola entre os pontos)
  calibration: [
    { percent: 0, liters: 0 },
    { percent: 20, liters: 180 },
    { percent: 50, liters: 500 },
    { percent: 80, liters: 820 },
    { percent: 100, liters: 1000 },
  ],
};

const MEMBERS = [
  { email: 'owner@demo.br', name: 'Dona da Casa', role: 'owner' },
  { email: 'admin@demo.br', name: 'Administrador Demo', role: 'admin' },
  { email: 'viewer@demo.br', name: 'Visitante Demo', role: 'viewer' },
];

// PRNG determinístico para a curva ser reproduzível.
function mulberry32(seed) {
  let a = seed >>> 0;
  return function random() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(20261024);
const jitter = (spread) => (rnd() * 2 - 1) * spread;
const round = (v, d = 1) => Math.round(v * 10 ** d) / 10 ** d;

// ---------------------------------------------------------------------------
// Helpers de escrita
// ---------------------------------------------------------------------------
async function deleteCollection(collectionRef, batchSize = 400) {
  let total = 0;
  for (;;) {
    const snap = await collectionRef.limit(batchSize).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    total += snap.size;
    if (snap.size < batchSize) break;
  }
  return total;
}

async function commitInChunks(operations, chunkSize = 400) {
  for (let i = 0; i < operations.length; i += chunkSize) {
    const batch = db.batch();
    operations.slice(i, i + chunkSize).forEach((op) => op(batch));
    await batch.commit();
  }
}

async function ensureUser(email, password, displayName) {
  try {
    const existing = await auth.getUserByEmail(email);
    // Usuários demo já nascem com e-mail verificado (não passam pelo gate).
    await auth.updateUser(existing.uid, {
      password,
      displayName,
      disabled: false,
      emailVerified: true,
    });
    return existing.uid;
  } catch (error) {
    if (error.code !== 'auth/user-not-found') throw error;
    const created = await auth.createUser({
      email,
      password,
      displayName,
      emailVerified: true,
    });
    return created.uid;
  }
}

// ---------------------------------------------------------------------------
// Simulação da caixa
// ---------------------------------------------------------------------------
/**
 * Gera a série de leituras dos últimos 3 dias.
 * Unidades: distanceCm/levelCm em cm; volumeL em litros; levelPercent 0..100.
 */
function buildSeries(now) {
  const readings = [];
  const events = [];
  const alerts = [];

  const steps = Math.floor((DAYS * 86400) / STEP_SECONDS);
  const startMs = now.getTime() - steps * STEP_SECONDS * 1000;

  // 65% da capacidade = ponto de partida confortável
  let levelCm = TANK.heightCm * 0.65;
  let pumpOn = false;
  let valveOpen = false;
  let sensorFailRemaining = 0;
  let sensorFailDone = false;
  let wifiDropDone = false;
  let lowAlertDone = false;
  let pumpStartedAt = null;

  events.push({
    type: 'boot',
    detail: 'Reinício após queda de energia',
    ts: new Date(startMs - 90 * 1000),
  });

  for (let i = 0; i < steps; i += 1) {
    const ts = new Date(startMs + i * STEP_SECONDS * 1000);
    const hour = ts.getHours() + ts.getMinutes() / 60;

    // Falha de sensor única: 3 leituras inválidas no 2º dia às ~10h
    if (!sensorFailDone && i > steps * 0.62 && hour >= 10 && hour < 10.26) {
      sensorFailRemaining = 3;
      sensorFailDone = true;
      events.push({
        type: 'invalid_reading',
        detail: 'Eco inválido do ultrassônico (superfície instável)',
        ts,
      });
      alerts.push({
        id: 'alerta-sensor-falha',
        type: 'sensor_fail',
        severity: 'crit',
        message: 'Sensor ultrassônico sem leitura válida por mais de 180 s.',
        ts: new Date(ts.getTime() + 180 * 1000),
        ack: true,
        ackDelayMin: 12,
      });
    }

    // Consumo: maior de manhã e à noite (banho/cozinha), quase nulo de madrugada
    const morning = Math.exp(-((hour - 7.5) ** 2) / 2.2);
    const evening = Math.exp(-((hour - 19) ** 2) / 3.0);
    const midday = Math.exp(-((hour - 12.5) ** 2) / 4.0);
    const base = 0.0009;
    const consumePct =
      base + 0.0022 * morning + 0.0026 * evening + 0.0007 * midday;
    // Em litros, via fração do nível
    levelCm -= TANK.heightCm * consumePct * (0.85 + rnd() * 0.3);
    if (levelCm < 0) levelCm = 0;

    // Regra autônoma do firmware (simulada aqui apenas para gerar histórico):
    // liga quando o nível cai abaixo de 25% e desliga acima de 98%.
    const levelPctNow = (levelCm / TANK.heightCm) * 100;
    if (!pumpOn && levelPctNow <= 25) {
      pumpOn = true;
      pumpStartedAt = ts;
      events.push({
        type: 'pump_on',
        detail: `Nível em ${round(levelPctNow)}% — bomba ligada pelo firmware`,
        ts,
      });
      if (!lowAlertDone) {
        lowAlertDone = true;
        alerts.push({
          id: 'alerta-nivel-baixo',
          type: 'low_level',
          severity: 'warn',
          message: 'Nível da caixa abaixo de 20%. Bomba acionada automaticamente.',
          ts,
          ack: false,
        });
      }
    }
    if (pumpOn) {
      levelCm += TANK.heightCm * 0.0075; // vazão de reposição
      if (levelCm >= TANK.heightCm * 0.98) {
        levelCm = TANK.heightCm * 0.98;
        pumpOn = false;
        events.push({
          type: 'pump_off',
          detail: `Caixa cheia (${round((levelCm / TANK.heightCm) * 100)}%) — bomba desligada`,
          ts,
        });
      }
      // Proteção: bomba não pode rodar mais de 8 min seguidos na simulação
      if (pumpStartedAt && ts - pumpStartedAt > 8 * 60 * 1000 && levelCm < TANK.heightCm * 0.9) {
        pumpOn = false;
        events.push({
          type: 'pump_off',
          detail: 'Tempo máximo de corrida atingido — proteção a seco',
          ts,
        });
      }
    }

    // Válvula de jardim: 18h15–18h45
    const shouldOpenValve = hour >= 18.25 && hour < 18.75;
    if (shouldOpenValve !== valveOpen) {
      valveOpen = shouldOpenValve;
      events.push({
        type: valveOpen ? 'valve_open' : 'valve_close',
        detail: 'Válvula de irrigação do jardim',
        ts,
      });
    }
    if (valveOpen) {
      levelCm -= TANK.heightCm * 0.0012;
      if (levelCm < 0) levelCm = 0;
    }

    // Queda de Wi-Fi única
    if (!wifiDropDone && i > steps * 0.35 && hour >= 3 && hour < 3.1) {
      wifiDropDone = true;
      events.push({
        type: 'wifi_drop',
        detail: 'Rede Wi-Fi indisponível (timeout de associação)',
        ts,
      });
      events.push({
        type: 'wifi_conn',
        detail: 'Wi-Fi restabelecido após 95 s',
        ts: new Date(ts.getTime() + 95 * 1000),
      });
      alerts.push({
        id: 'alerta-offline',
        type: 'offline',
        severity: 'info',
        message: 'Dispositivo ficou offline por 95 s.',
        ts: new Date(ts.getTime() + 95 * 1000),
        ack: true,
        ackDelayMin: 30,
      });
    }

    // Sensores inválidos: publica leitura marcada, sem inventar nível
    if (sensorFailRemaining > 0) {
      sensorFailRemaining -= 1;
      // Falha de sensor: repete a última leitura válida e zera a distância,
      // conforme docs/CONTRATO_ESP32.md (§4).
      const lastPct = Math.max(0, Math.min(100, (levelCm / TANK.heightCm) * 100));
      readings.push({
        distanceCm: 0,
        levelPercent: round(lastPct),
        levelCm: round(levelCm),
        volumeL: round((lastPct / 100) * TANK.capacityL),
        pumpOn,
        valveOpen,
        sensorOk: false,
        rssi: Math.round(-72 + jitter(8)),
        ts,
      });
      continue;
    }

    const levelPercent = Math.max(0, Math.min(100, (levelCm / TANK.heightCm) * 100));
    const volumeL = (levelPercent / 100) * TANK.capacityL;
    const distanceCm = TANK.heightCm + TANK.sensorOffsetCm - levelCm;

    readings.push({
      distanceCm: round(distanceCm) + round(jitter(0.4), 1),
      levelPercent: round(levelPercent),
      levelCm: round(levelCm),
      volumeL: round(volumeL),
      pumpOn,
      valveOpen,
      sensorOk: true,
      rssi: Math.round(-57 + jitter(9)),
      ts,
    });
  }

  return { readings, events, alerts };
}

// ---------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------
async function main() {
  const now = new Date();
  console.log(`Projeto: ${process.env.FIREBASE_PROJECT_ID || projectId || '(ADC)'}`);
  console.log('Limpando telemetria anterior…');

  const deviceRef = db.doc(`houses/${HOUSE_ID}/devices/${DEVICE_ID}`);
  const removed = {
    readings: await deleteCollection(deviceRef.collection('readings')),
    events: await deleteCollection(deviceRef.collection('events')),
    alerts: await deleteCollection(db.collection(`houses/${HOUSE_ID}/alerts`)),
    configLog: await deleteCollection(db.collection(`houses/${HOUSE_ID}/configLog`)),
    invites: await deleteCollection(db.collection(`houses/${HOUSE_ID}/invites`)),
  };
  console.log(
    `  removidos: readings=${removed.readings} events=${removed.events} ` +
      `alerts=${removed.alerts} configLog=${removed.configLog} invites=${removed.invites}`,
  );

  // --- usuários demo -------------------------------------------------------
  const ownerUid = await ensureUser(
    'owner@demo.br', DEMO_PASSWORD, MEMBERS[0].name,
  );
  const memberUids = { [MEMBERS[0].email]: ownerUid };
  for (const member of MEMBERS.slice(1)) {
    memberUids[member.email] = await ensureUser(member.email, DEMO_PASSWORD, member.name);
  }

  // --- usuário-dispositivo (credencial usada no provisioning BLE) ----------
  const devicePassword = `Hidro!${crypto.randomBytes(12).toString('base64url')}`;
  const deviceUid = await ensureUser(DEVICE_EMAIL, devicePassword, 'ESP32 Casa Demo');

  // --- casa + membros ------------------------------------------------------
  const createdAt = admin.firestore.Timestamp.fromMillis(now.getTime() - DAYS * 86400000);
  await db.doc(`houses/${HOUSE_ID}`).set({
    name: 'Casa Demo',
    createdAt,
    ownerUid,
  });

  const memberOps = MEMBERS.map((member) =>
    db.doc(`houses/${HOUSE_ID}/members/${memberUids[member.email]}`).set({
      role: member.role,
      name: member.name,
      email: member.email,
      joinedAt: createdAt,
      uid: memberUids[member.email], // desnormalização para listar casas via collectionGroup
    }),
  );
  await Promise.all(memberOps);

  await db.doc(`users/${ownerUid}`).set({
    name: MEMBERS[0].name,
    email: MEMBERS[0].email,
    createdAt,
  }, { merge: true });

  // Convite de demonstração (leitura de convite exige conhecer o código)
  await db.doc(`houses/${HOUSE_ID}/invites/DEMO2026`).set({
    role: 'viewer',
    createdBy: ownerUid,
    createdAt,
    expiresAt: admin.firestore.Timestamp.fromMillis(now.getTime() + 30 * 86400000),
    used: false,
  });

  // --- device + config -----------------------------------------------------
  const config = {
    configVersion: 1,
    reportIntervalSec: 60,
    sensorWindowSec: 20,
    limits: { ligaCm: 100, desligaCm: 25 },
    tank: TANK,
    alerts: { lowLevelPercent: 20, offlineAfterSec: 180, sensorFailAfterSec: 180 },
    updatedAt: createdAt,
    updatedBy: ownerUid,
  };

  // --- série temporal ------------------------------------------------------
  const { readings, events, alerts } = buildSeries(now);
  const last = readings[readings.length - 1];

  await deviceRef.set({
    name: 'Caixa do telhado',
    serial: 'HIDRO-DEMO-0001',
    deviceUid,
    fwVersion: '0.9.0-demo',
    createdAt,
    lastSeen: admin.firestore.Timestamp.fromDate(now),
    config,
    latest: {
      distanceCm: last.distanceCm,
      levelPercent: last.levelPercent,
      levelCm: last.levelCm,
      volumeL: last.volumeL,
      pumpOn: last.pumpOn,
      valveOpen: last.valveOpen,
      sensorOk: last.sensorOk,
      rssi: last.rssi,
      ts: admin.firestore.Timestamp.fromDate(last.ts),
    },
  });

  console.log(`Gravando ${readings.length} leituras, ${events.length} eventos, ${alerts.length} alertas…`);

  const readingOps = readings.map((reading, index) => (batch) =>
    batch.set(deviceRef.collection('readings').doc(`r-${String(index).padStart(5, '0')}`), {
      ...reading,
      ts: admin.firestore.Timestamp.fromDate(reading.ts),
    }));
  await commitInChunks(readingOps);

  const eventOps = events.map((event, index) => (batch) => {
    const plain = { type: event.type, detail: event.detail, ts: admin.firestore.Timestamp.fromDate(event.ts) };
    if (event.type.startsWith('pump')) {
      plain.detail = `${event.detail} (leitura simulada)`;
    }
    return batch.set(deviceRef.collection('events').doc(`e-${String(index).padStart(4, '0')}`), plain);
  });
  await commitInChunks(eventOps);

  const alertOps = alerts.map((alert) => (batch) => {
    const doc = {
      type: alert.type,
      severity: alert.severity,
      message: alert.message,
      deviceId: DEVICE_ID,
      source: 'device',
      ts: admin.firestore.Timestamp.fromDate(alert.ts),
      ack: alert.ack === true,
      ackBy: alert.ack ? ownerUid : null,
      ackTs: alert.ack
        ? admin.firestore.Timestamp.fromMillis(alert.ts.getTime() + (alert.ackDelayMin || 10) * 60000)
        : null,
    };
    return batch.set(db.collection(`houses/${HOUSE_ID}/alerts`).doc(alert.id), doc);
  });
  await commitInChunks(alertOps);

  await db.collection(`houses/${HOUSE_ID}/configLog`).doc('log-inicial').set({
    ts: createdAt,
    byUid: ownerUid,
    byName: MEMBERS[0].name,
    changes: {
      'config.configVersion': { old: 0, new: 1 },
      'config.reportIntervalSec': { old: null, new: 60 },
      'config.limits.desligaCm': { old: null, new: 25 },
      'config.limits.ligaCm': { old: null, new: 100 },
      'config.tank.capacityL': { old: null, new: TANK.capacityL },
    },
  });

  // Arquivo local (gitignored) só para reimpressão em runs futuros.
  fs.writeFileSync(
    path.join(__dirname, '..', '.seed-device-credentials.json'),
    JSON.stringify({ email: DEVICE_EMAIL, uid: deviceUid, password: devicePassword, projectId: process.env.FIREBASE_PROJECT_ID || projectId }, null, 2),
  );

  const percentAtual = last.levelPercent;
  console.log('\n================ SEED CONCLUÍDO ================');
  console.log(`Casa:            ${HOUSE_ID} (Casa Demo)`);
  console.log(`Device:          houses/${HOUSE_ID}/devices/${DEVICE_ID}`);
  console.log(`Leituras:        ${readings.length} (3 dias a cada 5 min)`);
  console.log(`Nível atual:     ${percentAtual}% (${last.volumeL} L)`);
  console.log('\nUsuários demo (senha: ' + DEMO_PASSWORD + '):');
  MEMBERS.forEach((m) => console.log(`  ${m.email.padEnd(18)} ${m.role}`));
  console.log('\nCredencial do dispositivo (usar no wizard BLE, NÃO fica no Firestore):');
  console.log(`  e-mail: ${DEVICE_EMAIL}`);
  console.log(`  senha:  ${devicePassword}`);
  console.log('\nConvite demo: código DEMO2026 (viewer, 30 dias)');
  console.log('Lembre-se de ativar o provedor E-mail/Senha no console Auth.');
  console.log('================================================\n');
}

main().catch((error) => {
  console.error('\nFalha no seed:', error);
  process.exitCode = 1;
});
