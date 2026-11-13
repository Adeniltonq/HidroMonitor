# HidroMonitor — app Flutter (Android)

Aplicativo de leitura de telemetria e configuração de parâmetros de uma caixa
d'água monitorada por ESP32. **Não há controle de bomba/válvula**: o firmware
decide sozinho, com base nos limites configurados.

## Abrir no Android Studio

1. Android Studio → **Open** → selecione a pasta `app/` deste repositório.
2. Aguarde o `pub get` (ou rode `flutter pub get` no terminal).
3. Confirme o SDK em `android/local.properties` (`flutter.sdk=...`).
4. Selecione um emulador/celular Android (API 24+) e rode.

O projeto já contém:
- `lib/firebase_options.dart` e `android/app/google-services.json` gerados para
  o projeto `monitor-de-caixa-d-agua` (package `br.app.hidromonitor`);
- `google-services` aplicado no Gradle;
- permissões BLE no `AndroidManifest.xml`;
- ícones e splash gerados (`flutter_launcher_icons` / `flutter_native_splash`);
- fonte Inter offline em `assets/fonts/`.

### Regerar a configuração do Firebase (se necessário)

```bash
cd app
flutterfire configure --project=monitor-de-caixa-d-agua --platforms=android --yes
```

> Se o package `br.app.hidromonitor` já existir no projeto, o comando apenas
> reutiliza o app existente.

## Rodar

```bash
flutter pub get
flutter devices          # confirme o aparelho
flutter run              # debug
```

Celular físico: ative Depuração USB e autorize o computador. O emulador Android
não tem Bluetooth real — o wizard BLE precisa de aparelho físico para o teste
final (o restante do app funciona no emulador).

## Build

```bash
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release
```

Saídas:

| Artefato | Caminho |
| --- | --- |
| APK debug | `build/app/outputs/flutter-apk/app-debug.apk` |
| APK release universal | `build/app/outputs/flutter-apk/app-release.apk` |
| APK release arm64 (recomendado) | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |
| APK release arm32 | `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk` |
| App Bundle | `build/app/outputs/bundle/release/app-release.aab` |

O APK é assinado com `android/key.properties` (`CN=HidroMonitor`). Se o celular
já tiver uma versão antiga assinada com outra chave, desinstale antes:

```bash
adb uninstall br.app.hidromonitor
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Requisito de sistema: Android 7.0+ (funciona no 12; `minSdk 24`,
`targetSdk 36`).

Sem `key.properties`, o build release usa a **assinatura debug** (funciona para
teste, não para publicar).

### Assinatura release

1. Gere a keystore:

```bash
keytool -genkey -v -keystore ~/hidromonitor-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias hidromonitor
```

2. Copie `android/key.properties.example` para `android/key.properties`
   (gitignored) e preencha:

```properties
storePassword=...
keyPassword=...
keyAlias=hidromonitor
storeFile=/home/SEU_USUARIO/hidromonitor-release.jks
```

3. Rode `flutter build appbundle --release`.

> Guarde a keystore e as senhas fora do repositório. Sem ela não é possível
> publicar atualizações do mesmo app.

## Configuração e dados

- Projeto: `monitor-de-caixa-d-agua`
- Firestore com **persistência offline** habilitada; quando um snapshot vem do
  cache, o app mostra o banner "Exibindo dados em cache".
- Login/cadastro por e-mail/senha (Firebase Auth). O provedor precisa estar
  ativo no console.
- Seed demo: veja o README da raiz. Usuários: `owner@demo.br`,
  `admin@demo.br` e `viewer@demo.br`, senha `Demo@12345`.
- Convite demo: casa `casa-demo`, código `DEMO2026`.

## Funcionalidades

- Dashboard em tempo real (`latest` + alertas), medidor vertical animado em
  `CustomPainter`, sparkline de 24 h, consumo do dia.
- Nível, bomba/válvula (estado + timeline + **controle manual com travas**), alertas com ack, histórico
  paginado (50, `limit/startAfter`, `orderBy ts desc`) com filtro e CSV,
  consumo diário/semanal, conexão/stale/RSSI, diagnóstico e configLog.
- Temas **Branco** e **Preto** (menu lateral e login), paleta azul-água/verde.
- Tabela manual de litros por nível (%) com interpolação (medidor, histórico e
  consumo), além do cálculo linear por capacidade.
- Configuração da caixa com validação, confirmação de segurança,
  `configVersion + 1` e `configLog` no mesmo batch.
- Membros e convites (owner/admin; fundador protegido).
- Pareamento BLE do ESP32 (ver abaixo).

## Provisionamento BLE

- Serviço NUS `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (RX `...0002`, TX `...0003`).
- Scan por nome `HIDRO-<4 hex do MAC>` ou pelo serviço; conexão com MTU 247.
- Payload JSON fragmentado em chunks de `MTU-3`, header `[seq][flags]`, ack por
  chunk, retry 3x com backoff 300 ms, checksum CRC16-CCITT.
- Etapas: `wifi_connecting`, `wifi_ok`/`wifi_fail`, `fb_ok`/`fb_fail`, `ready`.
- Confirmação final: aguarda até 60 s o `lastSeen` do device atualizar.
- Fallback manual: JSON + QR (com aviso de segredo).

Permissões declaradas: `BLUETOOTH_SCAN` (com `neverForLocation`),
`BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (maxSdk 30), `INTERNET` e
`uses-feature bluetooth_le`. O app pede justificativa em pt-BR antes do scan.

> Segurança: SSID, senha do Wi-Fi e senha do Firebase do device ficam apenas em
> memória durante o wizard. Não são gravados no Firestore, em logs ou no estado
> global após o envio.

## Testes e análise

```bash
flutter analyze      # sem issues
flutter test         # codec BLE, consumo, stale, CSV, payload
```

## Ícones e splash

Configurados no `pubspec.yaml`. Para regerar depois de trocar as imagens em
`assets/icon/`:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## Observações

- `flutter_blue_plus` v2 requer licença explícita no `connect()`. O app usa
  `License.nonprofit`; para uso comercial, troque para `License.commercial`
  (licença paga do pacote).
- O app é Android-only (minSdk 24).
