import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/errors.dart';
import 'ble_provisioning_codec.dart';
import 'provisioning_payload.dart';

enum ProvisioningPhase {
  idle,
  scanning,
  connecting,
  sending,
  awaitingStage,
  confirmingCloud,
  success,
  error,
}

/// Etapa em que o erro ocorreu — usada para mensagens de diagnóstico.
enum ProvisioningStage {
  none,
  permissions,
  bluetooth,
  scan,
  connect,
  hello,
  payload,
  wifi,
  firebase,
  cloud,
}

class ProvisioningStatus {
  const ProvisioningStatus({
    required this.phase,
    this.stage = ProvisioningStage.none,
    this.message = '',
    this.progress = 0,
    this.errorCode,
    this.canRetry = false,
  });

  final ProvisioningPhase phase;
  final ProvisioningStage stage;
  final String message;
  final double progress;
  final String? errorCode;
  final bool canRetry;

  bool get isBusy =>
      phase == ProvisioningPhase.scanning ||
      phase == ProvisioningPhase.connecting ||
      phase == ProvisioningPhase.sending ||
      phase == ProvisioningPhase.awaitingStage ||
      phase == ProvisioningPhase.confirmingCloud;

  bool get isSuccess => phase == ProvisioningPhase.success;
  bool get isError => phase == ProvisioningPhase.error;

  ProvisioningStatus copyWith({
    ProvisioningPhase? phase,
    ProvisioningStage? stage,
    String? message,
    double? progress,
    String? errorCode,
    bool? canRetry,
  }) =>
      ProvisioningStatus(
        phase: phase ?? this.phase,
        stage: stage ?? this.stage,
        message: message ?? this.message,
        progress: progress ?? this.progress,
        errorCode: errorCode ?? this.errorCode,
        canRetry: canRetry ?? this.canRetry,
      );
}

/// Falha em uma etapa específica do pareamento (vira `ProvisioningStatus`).
class _StageFailure implements Exception {
  const _StageFailure(this.stage, this.code, this.message);

  final ProvisioningStage stage;
  final String code;
  final String message;
}

/// Máquina de estados do pareamento BLE (Nordic UART Service).
///
/// Fluxo: scan → connect (MTU 247) → hello → envio fragmentado com ack/retry →
/// espera das etapas (wifi/firebase/ready) → confirmação na nuvem (lastSeen).
class BleProvisioningService {
  BleProvisioningService({BleProvisioningCodec? codec})
      : _codec = codec ?? const BleProvisioningCodec();

  static const String nusServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String nusRxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String nusTxUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

  static final Guid _serviceGuid = Guid(nusServiceUuid);
  static final Guid _rxGuid = Guid(nusRxUuid);
  static final Guid _txGuid = Guid(nusTxUuid);

  final BleProvisioningCodec _codec;
  final _statusController =
      StreamController<ProvisioningStatus>.broadcast();

  /// Nome anunciado pelo dispositivo encontrado — usado em mensagens de
  /// diagnóstico (ex.: `HIDRO-08B5`).
  String _deviceName = '';

  ProvisioningStatus _status =
      const ProvisioningStatus(phase: ProvisioningPhase.idle);
  ProvisioningStatus get status => _status;
  Stream<ProvisioningStatus> get statusStream => _statusController.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _sessionTimer;
  Timer? _stageTimer;

  final Map<int, Completer<void>> _acks = {};
  Completer<int> _hello = Completer<int>();
  Completer<void> _ready = Completer<void>();
  final List<int> _rxBytes = <int>[];

  bool _finished = false;

  /// Executa o wizard completo. [confirmCloud] deve consultar o Firestore e
  /// retornar true quando `lastSeen` do device for atualizado pelo ESP32.
  Future<bool> provision({
    required ProvisioningPayload payload,
    required Future<bool> Function() confirmCloud,
  }) async {
    if (_status.isBusy) {
      throw const AppException('Já existe um pareamento em andamento.');
    }
    _finished = false;
    _hello = Completer<int>();
    _ready = Completer<void>();
    _rxBytes.clear();
    _emit(
      const ProvisioningStatus(
        phase: ProvisioningPhase.scanning,
        message: 'Procurando o dispositivo "HIDRO"…',
        progress: 0.1,
      ),
    );

    // Sessão BLE inteira limitada a 5 minutos.
    _sessionTimer?.cancel();
    _sessionTimer = Timer(const Duration(minutes: 5), () {
      if (!_finished) {
        _fail(
          ProvisioningStage.bluetooth,
          'session_timeout',
          'Sessão de pareamento expirou (5 min). Repita o processo.',
          retry: true,
        );
      }
    });

    try {
      await _ensureBluetooth();
      final candidates = await _scan();
      await _connectAny(candidates);
      final mtu = await _awaitHello(_device!);

      _emit(
        const ProvisioningStatus(
          phase: ProvisioningPhase.sending,
          message: 'Enviando dados de configuração…',
          progress: 0.45,
        ),
      );
      await _sendPayload(payload, mtu);

      _emit(
        const ProvisioningStatus(
          phase: ProvisioningPhase.awaitingStage,
          message: 'Aguardando o dispositivo conectar ao Wi-Fi…',
          progress: 0.65,
          stage: ProvisioningStage.wifi,
        ),
      );
      await _awaitStages();

      _emit(
        const ProvisioningStatus(
          phase: ProvisioningPhase.confirmingCloud,
          message: 'Confirmando o primeiro contato na nuvem…',
          progress: 0.9,
          stage: ProvisioningStage.cloud,
        ),
      );
      final confirmed = await confirmCloud();
      if (!confirmed) {
        _fail(
          ProvisioningStage.cloud,
          'cloud_timeout',
          'O dispositivo não apareceu no Firestore em até 60 s. '
              'Verifique o Wi-Fi e tente novamente.',
          retry: true,
        );
        return false;
      }

      _finished = true;
      payload.wipe();
      _emit(
        const ProvisioningStatus(
          phase: ProvisioningPhase.success,
          message: 'Dispositivo pareado e enviando telemetria!',
          progress: 1,
        ),
      );
      return true;
    } catch (error) {
      if (!_finished) {
        if (error is _StageFailure) {
          _fail(error.stage, error.code, error.message, retry: true);
        } else {
          final message =
              error is AppException ? error.message : describeError(error);
          final stage = _status.stage;
          _fail(
            stage == ProvisioningStage.none
                ? ProvisioningStage.bluetooth
                : stage,
            'ble_error',
            message,
            retry: true,
          );
        }
      }
      return false;
    } finally {
      await _cleanup(disconnect: true);
    }
  }

  /// Permite repetir o envio enquanto o device segue conectado.
  Future<void> retry() async {
    await _cleanup(disconnect: true);
    _status = const ProvisioningStatus(phase: ProvisioningPhase.idle);
    _emit(_status);
  }

  Future<void> dispose() async {
    await _cleanup(disconnect: true);
    await _statusController.close();
  }

  // ---------------------------------------------------------------------------
  // Etapas
  // ---------------------------------------------------------------------------

  Future<void> _ensureBluetooth() async {
    if (!await FlutterBluePlus.isSupported) {
      _fail(
        ProvisioningStage.bluetooth,
        'ble_unsupported',
        'Este aparelho não suporta Bluetooth LE.',
      );
      throw const AppException('Bluetooth LE indisponível neste aparelho.');
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      _emit(
        _status.copyWith(
          message: 'Ative o Bluetooth para continuar.',
          stage: ProvisioningStage.bluetooth,
        ),
      );
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        _fail(
          ProvisioningStage.bluetooth,
          'bt_off',
          'Bluetooth desligado. Ative nas configurações do aparelho.',
          retry: true,
        );
        throw const AppException('Bluetooth desligado.');
      }
    }
  }

  /// Varre o ambiente e devolve até 3 candidatos, do sinal mais forte para o
  /// mais fraco. Vários candidatos permitem tentar outra conexão quando o
  /// Android falha na primeira (erro GATT 133 é comum).
  Future<List<BluetoothDevice>> _scan() async {
    final found = <String, ScanResult>{};
    await FlutterBluePlus.stopScan();

    _scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final result in results) {
          if (!_matchesDevice(result)) continue;
          found[result.device.remoteId.str] = result;
        }
      },
      onError: (Object error) {
        // erro de scan (adaptador desligado, permissão): falha explícita
        if (!_finished && found.isEmpty) {
          _fail(
            ProvisioningStage.scan,
            'scan_error',
            'Falha ao procurar dispositivos: ${describeError(error)}',
            retry: true,
          );
        }
      },
    );

    try {
      // 1ª varredura: 6 s (ou menos, se já achou e já temos 1,5 s de amostras)
      await _startScan();
      await _collect(found,
          max: const Duration(seconds: 6), min: const Duration(seconds: 2));

      // 2ª varredura: alguns celulares só entregam resultados a partir da
      // segunda tentativa (adaptador acordando, cache do Android).
      if (found.isEmpty) {
        _emit(
          _status.copyWith(
            message: 'Procurando o dispositivo "HIDRO"… (2ª tentativa)',
          ),
        );
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
        await _startScan();
        await _collect(found,
            max: const Duration(seconds: 8), min: const Duration(seconds: 2));
      }

      if (found.isEmpty) {
        throw const _StageFailure(
          ProvisioningStage.scan,
          'device_not_found',
          'Nenhum dispositivo "HIDRO" encontrado. Confira se ele está no modo '
              'de configuração (mensagem no OLED), se o Bluetooth está ligado e '
              'se está a menos de 1 m do celular. Se o "HIDRO" aparece como '
              'conectado/pareado nas configurações de Bluetooth do celular, '
              'toque em Desconectar (ou Esquecer) e tente de novo.',
        );
      }

      final sorted = found.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      _deviceName = _nameOf(sorted.first);
      final candidates =
          sorted.take(3).map((r) => r.device).toList(growable: false);
      return candidates;
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {
        // ignora falha ao parar o scan
      }
      await _scanSub?.cancel();
      _scanSub = null;
    }
  }

  Future<void> _startScan() => FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 12),
        androidScanMode: AndroidScanMode.lowLatency,
      );

  /// Espera até [max] acumulando resultados; sai antes se já houver resultado
  /// e tiver passado [min] (para pegar o anúncio com sinal mais forte).
  Future<void> _collect(
    Map<String, ScanResult> found, {
    required Duration max,
    required Duration min,
  }) async {
    final start = DateTime.now();
    final deadline = start.add(max);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final elapsed = DateTime.now().difference(start);
      if (found.isNotEmpty && elapsed >= min) return;
    }
  }

  String _nameOf(ScanResult result) {
    final advName = result.advertisementData.advName;
    if (advName.isNotEmpty) return advName;
    return result.device.platformName;
  }

  /// Aceita o dispositivo pelo nome (qualquer variação que contenha "HIDRO",
  /// inclusive o antigo HIDRO-XXXX) **ou** pelo UUID do serviço NUS.
  bool _matchesDevice(ScanResult result) {
    final name = _nameOf(result).toUpperCase();
    final matchesName = name.contains('HIDRO');
    final matchesService = result.advertisementData.serviceUuids
        .any((g) => g.str.toLowerCase() == nusServiceUuid.toLowerCase());
    return matchesName || matchesService;
  }

  /// Tenta conectar no melhor candidato; se o Android recusar, tenta o próximo.
  Future<void> _connectAny(List<BluetoothDevice> candidates) async {
    _StageFailure? lastError;
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final label = _deviceName.isEmpty ? 'dispositivo' : _deviceName;
      final suffix = candidates.length > 1
          ? ' (${index + 1}/${candidates.length})'
          : '';
      _emit(
        ProvisioningStatus(
          phase: ProvisioningPhase.connecting,
          stage: ProvisioningStage.connect,
          message: 'Conectando a $label$suffix…',
          progress: 0.25,
        ),
      );
      try {
        // Conecta SEM pedir MTU. Antes o `connect(mtu: 247)` juntava as duas
        // operações: se o Android recusasse o MTU, o app tratava como falha de
        // conexão (`connect_failed`) mesmo com o enlace funcionando.
        await _connectWithRetry(candidate);
      } catch (error) {
        // O celular pode já ter conectado o device pelo Bluetooth do sistema
        // (ou por uma tentativa anterior): nesse caso a exceção do `connect`
        // não significa que o enlace está fora do ar — segue se estiver vivo.
        if (!candidate.isConnected) {
          lastError = _StageFailure(
            ProvisioningStage.connect,
            'connect_failed',
            'Não foi possível conectar ao dispositivo: ${describeError(error)}',
          );
          await _safeDisconnect(candidate);
          continue;
        }
      }

      // MTU é opcional: se o Android recusar, seguimos com o MTU padrão.
      // O chunk do payload usa o menor MTU entre o real e o informado.
      try {
        await candidate.requestMtu(247, timeout: 8);
      } catch (_) {
        // segue com o MTU que o Android entregar
      }

      try {
        _device = candidate;
        await _discoverChannels(candidate);
        return;
      } on _StageFailure catch (error) {
        lastError = error;
      } catch (error) {
        lastError = _StageFailure(
          ProvisioningStage.connect,
          'connect_failed',
          'Não foi possível conectar ao dispositivo: ${describeError(error)}',
        );
      }
      await _safeDisconnect(candidate);
    }
    throw lastError ??
        const _StageFailure(
          ProvisioningStage.connect,
          'connect_failed',
          'Não foi possível conectar ao dispositivo. Se ele aparece como '
              'conectado nas configurações de Bluetooth do celular, desconecte '
              '(ou esqueça) e tente novamente.',
        );
  }

  /// Conecta com uma segunda tentativa. O Android costuma falhar na primeira
  /// conexão com GATT 133 quando o device acabou de sair do scan; uma pausa
  /// curta e uma nova tentativa resolvem na maioria dos aparelhos.
  Future<void> _connectWithRetry(BluetoothDevice device) async {
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 20),
      );
      return;
    } catch (_) {
      if (device.isConnected) return;
    }
    await _safeDisconnect(device);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 20),
    );
  }

  Future<void> _safeDisconnect(BluetoothDevice device) async {
    await _connectionSub?.cancel();
    _connectionSub = null;
    _rx = null;
    _tx = null;
    try {
      if (device.isConnected) await device.disconnect();
    } catch (_) {
      // já desconectado
    }
  }

  Future<void> _discoverChannels(BluetoothDevice device) async {
    _connectionSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !_finished) {
        _fail(
          ProvisioningStage.connect,
          'disconnected',
          'O dispositivo desconectou durante o pareamento.',
          retry: true,
        );
      }
    });

    final services = await device.discoverServices();
    BluetoothService? nus;
    for (final service in services) {
      if (service.uuid == _serviceGuid) {
        nus = service;
        break;
      }
    }
    if (nus == null) {
      throw const _StageFailure(
        ProvisioningStage.connect,
        'nus_missing',
        'Este dispositivo não expõe o serviço de pareamento. '
            'Atualize o firmware do ESP32.',
      );
    }

    for (final characteristic in nus.characteristics) {
      if (characteristic.uuid == _rxGuid) _rx = characteristic;
      if (characteristic.uuid == _txGuid) _tx = characteristic;
    }
    if (_rx == null || _tx == null) {
      throw const _StageFailure(
        ProvisioningStage.connect,
        'chars_missing',
        'O serviço de pareamento do dispositivo está incompleto. '
            'Atualize o firmware do ESP32.',
      );
    }

    await _tx!.setNotifyValue(true);
    _notifySub = _tx!.onValueReceived.listen(_handleNotification);
  }

  /// Pede o handshake explicitamente (frame vazio com a flag 0x04).
  ///
  /// Sem isso o pareamento dependia do `hello` periódico do firmware chegar
  /// depois de a assinatura das notificações estar pronta; se a descoberta de
  /// serviços do celular demorasse, todos os hellos eram perdidos.
  Future<void> _requestHello() async {
    if (_rx == null) return;
    try {
      await _rx!.write(
        const [0, BleProvisioningCodec.flagHelloRequest],
        withoutResponse: false,
      );
    } catch (_) {
      // se falhar, ainda resta a repetição periódica do firmware
    }
  }

  Future<int> _awaitHello(BluetoothDevice device) async {
    var attempts = 0;
    while (attempts < 3) {
      try {
        await _requestHello();
        final reported =
            await _hello.future.timeout(const Duration(seconds: 5));
        // Usa SEMPRE o menor valor entre o que o device anunciou e o MTU real
        // do enlace. Antes, quando o Android não negociava MTU e `mtuNow` ficava
        // em 23, o app usava 247 e enviava blocos de 244 bytes que o stack
        // recusava — resultado: "falha ao enviar dados".
        final enlace = device.mtuNow;
        final effective = math.min(enlace, reported);
        return effective.clamp(23, 247);
      } on TimeoutException {
        attempts++;
      }
    }
    throw const _StageFailure(
      ProvisioningStage.hello,
      'hello_timeout',
      'O dispositivo não respondeu ao handshake BLE. '
          'Confirme que ele está no modo de configuração (mensagem no OLED) '
          'e tente de novo.',
    );
  }

  /// Envia a mensagem fragmentada, com ack por chunk e retry 3x (backoff 300 ms).
  Future<void> _sendPayload(ProvisioningPayload payload, int mtu) async {
    final frames = _codec.fragment(payload.toMessage(), mtu: mtu);
    final total = frames.length;
    for (var index = 0; index < total; index++) {
      final frame = frames[index];
      await _sendFrame(frame);
      _emit(
        _status.copyWith(
          progress: 0.45 + (0.2 * (index + 1) / total),
          message: 'Enviando… ${index + 1}/$total',
        ),
      );
    }
  }

  Future<void> _sendFrame(BleFrame frame) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_finished) {
        // o device já respondeu com `error` (checksum/seq/fields/nvs)
        throw const AppException('Pareamento recusado pelo dispositivo.');
      }
      try {
        final completer = Completer<void>();
        _acks[frame.seq] = completer;
        await _rx!.write(frame.toBytes(), withoutResponse: false);
        await completer.future.timeout(const Duration(seconds: 3));
        _acks.remove(frame.seq);
        return;
      } on TimeoutException catch (error) {
        lastError = error;
        // ack não chegou — tenta novamente após o backoff
      } catch (error) {
        lastError = error;
        // erro de escrita BLE — tenta novamente após o backoff
      }
      _acks.remove(frame.seq);
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
    final detalhe = lastError == null ? 'sem resposta do dispositivo' :
        describeError(lastError);
    throw _StageFailure(
      ProvisioningStage.payload,
      'chunk_failed',
      'Falha ao enviar dados para o dispositivo ($detalhe). '
          'Mantenha o celular próximo e tente novamente.',
    );
  }

  Future<void> _awaitStages() async {
    try {
      await _ready.future.timeout(const Duration(seconds: 90));
      if (_status.isError) {
        throw AppException(_status.message);
      }
    } on TimeoutException {
      throw const _StageFailure(
        ProvisioningStage.wifi,
        'stage_timeout',
        'O dispositivo não confirmou as etapas a tempo. '
            'Verifique a rede Wi-Fi (2,4 GHz) e tente novamente.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Notificações do periférico (JSON lines)
  // ---------------------------------------------------------------------------

  void _handleNotification(List<int> value) {
    // Acumula BYTES e só decodifica linhas completas: decodificar por
    // notificação corrompia caracteres UTF-8 partidos entre pacotes
    // (acontece com MTU baixo, ex. 23).
    _rxBytes.addAll(value);
    var newline = _rxBytes.indexOf(0x0A);
    while (newline >= 0) {
      final lineBytes = _rxBytes.sublist(0, newline);
      _rxBytes.removeRange(0, newline + 1);
      final line = utf8.decode(lineBytes, allowMalformed: true).trim();
      if (line.isNotEmpty) _handleLine(line);
      newline = _rxBytes.indexOf(0x0A);
    }
  }

  void _handleLine(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final op = decoded['op'];
    switch (op) {
      case 'hello':
        final mtu = (decoded['mtu'] as num?)?.toInt() ?? 247;
        if (!_hello.isCompleted) {
          _hello.complete(mtu.clamp(23, 247));
        }
        break;
      case 'ack':
        final seq = (decoded['seq'] as num?)?.toInt();
        if (seq != null) {
          final completer = _acks[seq];
          if (completer != null && !completer.isCompleted) completer.complete();
        }
        break;
      case 'stage':
        _handleStage(decoded);
        break;
      case 'error':
        final code = (decoded['code'] as String?) ?? 'device_error';
        _fail(
          ProvisioningStage.payload,
          code,
          _deviceErrorMessage(code),
          retry: true,
        );
        break;
      default:
        break;
    }
  }

  void _handleStage(Map<String, dynamic> message) {
    final stage = message['s'] as String?;
    final code = message['code'] as String?;
    switch (stage) {
      case 'wifi_connecting':
        _emit(
          _status.copyWith(
            stage: ProvisioningStage.wifi,
            message: 'Conectando ao Wi-Fi…',
            progress: 0.68,
          ),
        );
        _startStageTimer(
          const Duration(seconds: 25),
          ProvisioningStage.wifi,
          'wifi_timeout',
          'O dispositivo não conseguiu conectar ao Wi-Fi em 25 s.',
        );
        break;
      case 'wifi_ok':
        _stageTimer?.cancel();
        _emit(
          _status.copyWith(
            stage: ProvisioningStage.firebase,
            message: 'Wi-Fi conectado. Autenticando no Firebase…',
            progress: 0.76,
          ),
        );
        _startStageTimer(
          const Duration(seconds: 30),
          ProvisioningStage.firebase,
          'fb_timeout',
          'Timeout ao autenticar no Firebase em 30 s.',
        );
        break;
      case 'wifi_fail':
        _stageTimer?.cancel();
        _fail(
          ProvisioningStage.wifi,
          code ?? 'wifi_fail',
          _wifiFailureMessage(code),
          retry: true,
        );
        break;
      case 'fb_ok':
        _stageTimer?.cancel();
        _emit(
          _status.copyWith(
            stage: ProvisioningStage.firebase,
            message: 'Firebase autenticado. Finalizando…',
            progress: 0.85,
          ),
        );
        break;
      case 'fb_fail':
        _stageTimer?.cancel();
        _fail(
          ProvisioningStage.firebase,
          code ?? 'fb_fail',
          'Falha ao autenticar no Firebase. '
              'Verifique se o login e-mail/senha está ativo no console.',
          retry: true,
        );
        break;
      case 'ready':
        _stageTimer?.cancel();
        if (!_ready.isCompleted) _ready.complete();
        break;
      default:
        break;
    }
  }

  /// Traduz os códigos de `{"op":"error"}` do firmware.
  String _deviceErrorMessage(String code) {
    switch (code) {
      case 'checksum':
        return 'Falha de integridade no envio (CRC16). '
            'Mantenha o celular próximo e tente novamente.';
      case 'seq':
        return 'A comunicação Bluetooth perdeu a ordem dos pacotes. '
            'Tente novamente.';
      case 'json':
      case 'fields':
        return 'O dispositivo recusou os dados de configuração. '
            'Confira SSID/senha do Wi-Fi e tente novamente.';
      case 'nvs':
        return 'O dispositivo não conseguiu gravar as configurações '
            'na memória interna.';
      default:
        return 'O dispositivo recusou o payload (código $code).';
    }
  }

  String _wifiFailureMessage(String? code) {
    switch (code) {
      case 'auth':
        return 'Senha do Wi-Fi incorreta. Confira e tente novamente.';
      case 'signal':
        return 'Sinal de Wi-Fi fraco. Aproxime o dispositivo do roteador.';
      case 'not_found':
        return 'Rede Wi-Fi não encontrada. Confira o nome (SSID).';
      default:
        return 'Não foi possível conectar ao Wi-Fi. '
            'Confira SSID e senha (2,4 GHz).';
    }
  }

  void _startStageTimer(
    Duration duration,
    ProvisioningStage stage,
    String code,
    String message,
  ) {
    _stageTimer?.cancel();
    _stageTimer = Timer(duration, () {
      if (!_finished && !_ready.isCompleted) {
        _fail(stage, code, message, retry: true);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Estado / limpeza
  // ---------------------------------------------------------------------------

  void _emit(ProvisioningStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  void _fail(
    ProvisioningStage stage,
    String code,
    String message, {
    bool retry = false,
  }) {
    if (_finished) return;
    _finished = true;
    _stageTimer?.cancel();
    if (!_ready.isCompleted) _ready.complete();
    _emit(
      ProvisioningStatus(
        phase: ProvisioningPhase.error,
        stage: stage,
        message: message,
        errorCode: code,
        canRetry: retry,
        progress: _status.progress,
      ),
    );
  }

  Future<void> _cleanup({required bool disconnect}) async {
    _sessionTimer?.cancel();
    _stageTimer?.cancel();
    _rxBytes.clear();
    await _notifySub?.cancel();
    await _scanSub?.cancel();
    await _connectionSub?.cancel();
    _notifySub = null;
    _scanSub = null;
    _connectionSub = null;

    for (final completer in _acks.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AppException('Conexão encerrada antes do ack.'),
        );
      }
    }
    _acks.clear();

    if (disconnect) {
      try {
        await _device?.disconnect();
      } catch (_) {
        // dispositivo já desconectado — nada a fazer
      }
    }
    _device = null;
    _rx = null;
    _tx = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // adaptador desligado ou já parado — não é erro fatal
    }
  }
}
