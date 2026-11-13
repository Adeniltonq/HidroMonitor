#!/usr/bin/env node
/**
 * export-db.js — exporta TODO o banco Firestore para formatos prontos para
 * análise por qualquer IA (JSON, JSONL e CSV).
 *
 * O dump é recursivo: percorre todas as coleções raiz e todas as subcoleções,
 * convertendo Timestamps para ISO-8601 (UTC), DocumentReferences para o caminho
 * do documento, GeoPoints para {latitude, longitude} e Bytes para base64.
 *
 * Saída (por padrão em <repo>/exports/firestore-<timestamp>/):
 *   firestore_full.json      — árvore completa aninhada (1 arquivo)
 *   firestore_documents.jsonl— 1 documento por linha, com caminho e ID
 *   csv/<caminho>.csv        — 1 CSV por coleção (campos aninhados em JSON)
 *   manifest.json            — contagens, caminhos e metadados da exportação
 *   resumo.md                — visão geral legível por humanos e por IA
 *
 * Uso:
 *   export FIREBASE_SERVICE_ACCOUNT=/caminho/serviceAccountKey.json
 *   cd backend && npm run export
 *
 * Opções (variáveis de ambiente):
 *   FIREBASE_SERVICE_ACCOUNT  caminho da service account (ou GOOGLE_APPLICATION_CREDENTIALS)
 *   FIREBASE_PROJECT_ID       sobrescreve o project_id da credencial
 *   EXPORT_DIR                diretório de saída (default: <repo>/exports/firestore-<timestamp>)
 *   EXPORT_COLLECTIONS        lista separada por vírgula de coleções raiz a exportar
 */
'use strict';

const fs = require('fs');
const path = require('path');
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

function repoRoot() {
  return path.resolve(__dirname, '..', '..');
}

function resolveCredentials() {
  const candidates = [
    process.env.FIREBASE_SERVICE_ACCOUNT,
    process.env.SEED_SERVICE_ACCOUNT,
    process.env.GOOGLE_APPLICATION_CREDENTIALS,
    // fallback prático: chave admin na raiz do repositório
    ...fs
      .readdirSync(repoRoot())
      .filter((f) => f.includes('firebase-adminsdk') && f.endsWith('.json'))
      .map((f) => path.join(repoRoot(), f)),
  ].filter(Boolean);

  for (const candidate of candidates) {
    const resolved = path.isAbsolute(candidate)
      ? candidate
      : path.resolve(process.cwd(), candidate);
    if (fs.existsSync(resolved)) {
      const json = JSON.parse(fs.readFileSync(resolved, 'utf8'));
      console.log(`Credencial: ${resolved}`);
      return {
        credential: admin.credential.cert(json),
        projectId: json.project_id,
      };
    }
  }

  console.log('Credencial: Application Default Credentials (gcloud)');
  return { credential: admin.credential.applicationDefault(), projectId: undefined };
}

const { credential, projectId } = resolveCredentials();
admin.initializeApp({
  credential,
  projectId: process.env.FIREBASE_PROJECT_ID || projectId,
});
const db = admin.firestore();

// ---------------------------------------------------------------------------
// Conversão de tipos do Firestore para JSON puro
// ---------------------------------------------------------------------------
function toPlain(value) {
  if (value === null || value === undefined) return value;
  if (value instanceof admin.firestore.Timestamp) {
    return value.toDate().toISOString();
  }
  if (value instanceof admin.firestore.GeoPoint) {
    return { latitude: value.latitude, longitude: value.longitude };
  }
  if (value instanceof admin.firestore.DocumentReference) {
    return { __ref: value.path };
  }
  if (Buffer.isBuffer(value)) {
    return { __bytes: value.toString('base64') };
  }
  if (Array.isArray(value)) {
    return value.map(toPlain);
  }
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = toPlain(v);
    return out;
  }
  // number, string, boolean
  return value;
}

// ---------------------------------------------------------------------------
// Travessia recursiva
// ---------------------------------------------------------------------------
const MAX_CONCURRENCY = 6;

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (true) {
      const index = next++;
      if (index >= items.length) return;
      results[index] = await fn(items[index], index);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => worker())
  );
  return results;
}

/**
 * @returns {{ tree: object, records: Array, collections: Array }}
 */
async function exportCollection(colRef, prefixPath) {
  const snap = await colRef.get();
  const tree = {};
  const records = [];
  const collections = [];

  await mapLimit(snap.docs, MAX_CONCURRENCY, async (doc) => {
    const docPath = `${prefixPath}/${doc.id}`;
    const data = toPlain(doc.data());
    const node = {
      _id: doc.id,
      _path: docPath,
      _createTime: doc.createTime ? doc.createTime.toDate().toISOString() : null,
      _updateTime: doc.updateTime ? doc.updateTime.toDate().toISOString() : null,
      ...data,
    };

    records.push({ path: docPath, id: doc.id, data: node });

    // Subcoleções (recursivo)
    const subCols = await doc.ref.listCollections();
    if (subCols.length > 0) {
      node._subcollections = {};
      for (const sub of subCols) {
        const subPath = `${docPath}/${sub.id}`;
        const subResult = await exportCollection(sub, subPath);
        node._subcollections[sub.id] = subResult.tree;
        records.push(...subResult.records);
        collections.push(...subResult.collections);
      }
    }

    tree[doc.id] = node;
  });

  // Ordena por caminho para saída determinística
  records.sort((a, b) => a.path.localeCompare(b.path));

  collections.unshift({
    path: prefixPath,
    docCount: snap.size,
  });

  return { tree, records, collections };
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------
function flattenForCsv(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function csvEscape(value) {
  const s = String(value ?? '');
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

function writeCsv(filePath, records) {
  if (records.length === 0) return;
  const fieldSet = new Set(['_id', '_path', '_createTime', '_updateTime']);
  for (const r of records) {
    for (const key of Object.keys(r.data)) fieldSet.add(key);
  }
  const fields = [...fieldSet];
  const lines = [fields.map(csvEscape).join(',')];
  for (const r of records) {
    lines.push(fields.map((f) => csvEscape(flattenForCsv(r.data[f]))).join(','));
  }
  fs.writeFileSync(filePath, `${lines.join('\n')}\n`, 'utf8');
}

// ---------------------------------------------------------------------------
// Resumo para IA
// ---------------------------------------------------------------------------
function collectFieldTypes(records) {
  const types = {};
  for (const r of records) {
    for (const [key, value] of Object.entries(r.data)) {
      if (key.startsWith('_')) continue;
      const type = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
      if (!types[key]) types[key] = new Set();
      types[key].add(type);
    }
  }
  const out = {};
  for (const key of Object.keys(types).sort()) out[key] = [...types[key]].sort();
  return out;
}

function buildSummary({ collections, records, projectId: pid, outDir, startedAt }) {
  const byCollection = new Map();
  for (const c of collections) {
    byCollection.set(c.path, { path: c.path, docCount: c.docCount, records: [] });
  }
  for (const r of records) {
    const parent = r.path.split('/').slice(0, -1).join('/');
    if (!byCollection.has(parent)) {
      byCollection.set(parent, { path: parent, docCount: 0, records: [] });
    }
    byCollection.get(parent).records.push(r);
  }

  const totalDocs = [...byCollection.values()].reduce((acc, c) => acc + c.docCount, 0);

  const lines = [];
  lines.push('# Exportação completa do Firestore — HidroMonitor');
  lines.push('');
  lines.push(`- Projeto: \`${pid}\``);
  lines.push(`- Exportado em: ${new Date().toISOString()}`);
  lines.push(`- Início: ${startedAt.toISOString()}`);
  lines.push(`- Coleções: ${byCollection.size}`);
  lines.push(`- Documentos: ${totalDocs}`);
  lines.push('');
  lines.push('## Arquivos');
  lines.push('');
  lines.push('- `firestore_full.json` — árvore completa aninhada (melhor para leitura integral).');
  lines.push('- `firestore_documents.jsonl` — 1 documento por linha, com `path` e `id` (melhor para filtros/pandas).');
  lines.push('- `csv/<caminho>.csv` — uma planilha por coleção; mapas/listas ficam como JSON dentro da célula.');
  lines.push('- `manifest.json` — metadados e contagens por coleção.');
  lines.push('');
  lines.push('## Coleções e campos');
  lines.push('');
  lines.push('| Coleção | Documentos | Campos (tipo) |');
  lines.push('| --- | ---: | --- |');

  const sorted = [...byCollection.values()].sort((a, b) => a.path.localeCompare(b.path));
  for (const c of sorted) {
    const types = collectFieldTypes(c.records);
    const fieldDesc = Object.entries(types)
      .map(([k, t]) => `${k} (${t.join('|')})`)
      .join(', ');
    lines.push(`| \`${c.path}\` | ${c.docCount} | ${fieldDesc || '—'} |`);
  }

  lines.push('');
  lines.push('## Intervalo temporal (campo `ts`)');
  lines.push('');
  const timestamps = records
    .map((r) => r.data.ts)
    .filter((v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v))
    .sort();
  if (timestamps.length > 0) {
    lines.push(`- Mais antigo: ${timestamps[0]}`);
    lines.push(`- Mais recente: ${timestamps[timestamps.length - 1]}`);
    lines.push(`- Registros com ts: ${timestamps.length}`);
  } else {
    lines.push('- Nenhum campo `ts` encontrado.');
  }

  lines.push('');
  lines.push('## Dicas de análise');
  lines.push('');
  lines.push('- Timestamps estão em ISO-8601 UTC (ex.: `2026-10-24T15:30:00.000Z`).');
  lines.push('- `readings` é a série histórica; `devices/{id}` tem `latest` (última leitura) e `config`.');
  lines.push('- Referências entre documentos aparecem como `{ "__ref": "caminho/do/doc" }`.');
  lines.push('- Campos aninhados (`config`, `limits`, `tank`, `latest`) viram JSON nas células CSV.');
  lines.push('- Consumo estimado: somar quedas de `volumeL` entre leituras consecutivas com `sensorOk=true` e `pumpOn=false` (ver `docs/MODELO_DE_DADOS.md`).');
  lines.push('');

  return { text: lines.join('\n'), totalDocs };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const startedAt = new Date();
  const stamp = startedAt.toISOString().replace(/[:.]/g, '-');
  const outDir =
    process.env.EXPORT_DIR ||
    path.join(repoRoot(), 'exports', `firestore-${stamp}`);

  const only = (process.env.EXPORT_COLLECTIONS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  fs.mkdirSync(path.join(outDir, 'csv'), { recursive: true });

  console.log(`Projeto: ${process.env.FIREBASE_PROJECT_ID || projectId}`);
  console.log(`Saída:   ${outDir}`);

  let rootCollections = await db.listCollections();
  if (only.length > 0) {
    rootCollections = rootCollections.filter((c) => only.includes(c.id));
  }
  rootCollections.sort((a, b) => a.id.localeCompare(b.id));

  console.log(
    `Coleções raiz: ${rootCollections.map((c) => c.id).join(', ') || '(nenhuma)'}`
  );

  const fullTree = {};
  const allRecords = [];
  const allCollections = [];

  for (const col of rootCollections) {
    console.log(`Exportando ${col.id}...`);
    const result = await exportCollection(col, col.id);
    fullTree[col.id] = result.tree;
    allRecords.push(...result.records);
    allCollections.push(...result.collections);
  }

  // JSON completo
  fs.writeFileSync(
    path.join(outDir, 'firestore_full.json'),
    JSON.stringify(
      {
        projectId: process.env.FIREBASE_PROJECT_ID || projectId,
        exportedAt: new Date().toISOString(),
        collections: fullTree,
      },
      null,
      2
    ),
    'utf8'
  );

  // JSONL
  const jsonl = allRecords.map((r) => JSON.stringify(r)).join('\n');
  fs.writeFileSync(
    path.join(outDir, 'firestore_documents.jsonl'),
    jsonl ? `${jsonl}\n` : '',
    'utf8'
  );

  // CSVs por coleção
  const byCollection = new Map();
  for (const r of allRecords) {
    const parent = r.path.split('/').slice(0, -1).join('/');
    if (!byCollection.has(parent)) byCollection.set(parent, []);
    byCollection.get(parent).push(r);
  }
  for (const [colPath, records] of byCollection) {
    const fileName = `${colPath.replace(/\//g, '__')}.csv`;
    writeCsv(path.join(outDir, 'csv', fileName), records);
  }

  // Manifest
  const summary = buildSummary({
    collections: allCollections,
    records: allRecords,
    projectId: process.env.FIREBASE_PROJECT_ID || projectId,
    outDir,
    startedAt,
  });

  const manifest = {
    projectId: process.env.FIREBASE_PROJECT_ID || projectId,
    exportedAt: new Date().toISOString(),
    startedAt: startedAt.toISOString(),
    durationMs: Date.now() - startedAt.getTime(),
    outputDir: outDir,
    collections: allCollections.sort((a, b) => a.path.localeCompare(b.path)),
    totalDocuments: summary.totalDocs,
    files: {
      fullJson: 'firestore_full.json',
      jsonl: 'firestore_documents.jsonl',
      csvDir: 'csv/',
      summary: 'resumo.md',
    },
  };
  fs.writeFileSync(
    path.join(outDir, 'manifest.json'),
    JSON.stringify(manifest, null, 2),
    'utf8'
  );
  fs.writeFileSync(path.join(outDir, 'resumo.md'), summary.text, 'utf8');

  console.log('');
  console.log(`Pronto: ${summary.totalDocs} documentos, ${allCollections.length} coleções.`);
  console.log(`Resumo: ${path.join(outDir, 'resumo.md')}`);
  console.log(`JSON:   ${path.join(outDir, 'firestore_full.json')}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('Falha na exportação:', err);
    process.exit(1);
  });
