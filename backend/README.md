# Backend — Rules, índices e seed

## Rules e índices

```bash
firebase deploy --only firestore:rules,firestore:indexes --project=monitor-de-caixa-d-agua
```

Arquivos:

- `firestore.rules` — política multi-inquilino, validação de tipos/faixas,
  separação device × membro, configLog imutável.
- `firestore.indexes.json` — `ts` ASC/DESC para `readings`, `events`, `alerts`,
  `configLog` e `uid` (COLLECTION_GROUP) para `members`.

## Seed

Pré-requisito: Authentication inicializado no console, provedor E-mail/Senha
ativo.

```bash
cd backend
npm install
export SEED_SERVICE_ACCOUNT=/caminho/serviceAccountKey.json`
npm run seed
```

Ou crie `.env` a partir de `.env.example`.

O script é idempotente: apaga e recria apenas as subcoleções de telemetria,
convites e configLog, e faz upsert de usuários/casa/membros/device.

Saída importante:

- senha demo dos membros: `Demo@12345`;
- senha aleatória do device (`dev-demo-0001@devices.local`), impressa no
  terminal e salva em `.seed-device-credentials.json` (gitignored). Ela **não**
  é gravada no Firestore.

## Verificações rápidas

```bash
firebase firestore:databases:list --project=monitor-de-caixa-d-agua
firebase deploy --only firestore:rules --project=monitor-de-caixa-d-agua
```
