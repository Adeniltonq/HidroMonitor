import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/errors.dart';
import '../models/device.dart';
import '../models/device_command.dart';
import '../models/reading.dart';
import 'firestore_cleanup.dart';

/// Resultado de uma consulta de intervalo (análise).
class ReadingRangeResult {
  const ReadingRangeResult({required this.readings, required this.truncated});

  final List<Reading> readings;
  final bool truncated;
}

/// Página de histórico (paginação por cursor de documento).
class ReadingPage {
  const ReadingPage({
    required this.readings,
    required this.cursor,
    required this.limit,
  });

  final List<Reading> readings;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final int limit;

  bool get hasMore => readings.length >= limit;
}

/// Acesso a devices, telemetria (somente leitura) e configuração.
///
/// O app NUNCA escreve em `latest`, `readings` ou `events`: essas escritas são
/// exclusivas do dispositivo autenticado (ver firestore.rules).
class DeviceRepository {
  DeviceRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _deviceRef(
          String houseId, String deviceId) =>
      _db.collection('houses').doc(houseId).collection('devices').doc(deviceId);

  /// Exclui o dispositivo e tudo que está dentro dele (leituras, eventos e
  /// comandos). Só o proprietário da casa pode fazer isso — a regra do
  /// Firestore (`isOwner`) é quem garante.
  Future<void> deleteDevice({
    required String houseId,
    required String deviceId,
    void Function(String label, int removidos)? onProgress,
  }) async {
    try {
      final ref = _deviceRef(houseId, deviceId);
      for (final sub in const ['readings', 'events', 'commands']) {
        await deleteCollectionDocs(
          ref.collection(sub),
          label: sub,
          onProgress: onProgress,
        );
      }
      await ref.delete();
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<List<Device>> watchDevices(String houseId) => _db
      .collection('houses')
      .doc(houseId)
      .collection('devices')
      .orderBy('createdAt')
      .snapshots()
      .map((snapshot) => snapshot.docs.map(Device.fromDoc).toList());

  /// Cria o documento do device após o pareamento BLE (config default).
  Future<String> createDevice({
    required String houseId,
    required String name,
    required String serial,
    required String deviceUid,
    required String byUid,
  }) async {
    try {
      final ref =
          _db.collection('houses').doc(houseId).collection('devices').doc();
      final config = DeviceConfig.defaults(
        updatedBy: byUid,
        updatedAt: DateTime.now(),
      );
      await ref.set({
        'name': name,
        'serial': serial,
        'deviceUid': deviceUid,
        'fwVersion': 'aguardando',
        'createdAt': FieldValue.serverTimestamp(),
        'config': config.toMap(),
      });
      return ref.id;
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchDeviceDoc(
          String houseId, String deviceId) =>
      _deviceRef(houseId, deviceId).snapshots();

  Stream<Device> watchDevice(String houseId, String deviceId) =>
      _deviceRef(houseId, deviceId).snapshots().map((doc) {
        if (!doc.exists) {
          throw const AppException('Dispositivo não encontrado.');
        }
        return Device.fromDoc(doc);
      });

  /// Leituras das últimas [hours] horas (ordem cronológica p/ gráficos).
  Stream<List<Reading>> watchReadings({
    required String houseId,
    required String deviceId,
    int hours = 24,
    int limit = 500,
  }) {
    final since = Timestamp.fromDate(
      DateTime.now().subtract(Duration(hours: hours)),
    );
    return _deviceRef(houseId, deviceId)
        .collection('readings')
        .where('ts', isGreaterThanOrEqualTo: since)
        .orderBy('ts', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          final readings = snapshot.docs.map(Reading.fromDoc).toList();
          return readings.reversed.toList(growable: false);
        });
  }

  /// Histórico paginado: 50 por página, orderBy ts desc, startAfter cursor.
  Future<ReadingPage> fetchReadingsPage({
    required String houseId,
    required String deviceId,
    int limit = 50,
    DocumentSnapshot<Map<String, dynamic>>? cursor,
    DateTime? since,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _deviceRef(houseId, deviceId)
          .collection('readings')
          .orderBy('ts', descending: true);
      if (since != null) {
        query = query.where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(since));
      }
      query = query.limit(limit);
      if (cursor != null) {
        query = query.startAfterDocument(cursor);
      }
      final snapshot = await query.get();
      return ReadingPage(
        readings: snapshot.docs.map(Reading.fromDoc).toList(),
        cursor: snapshot.docs.isEmpty ? cursor : snapshot.docs.last,
        limit: limit,
      );
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Leituras entre [from] e [to] para a aba Análise.
  ///
  /// Faz paginação no cliente para não estourar o limite de uma query.
  /// [truncated] indica que o limite de segurança foi atingido.
  Future<ReadingRangeResult> fetchReadingsRange({
    required String houseId,
    required String deviceId,
    required DateTime from,
    required DateTime to,
    int pageSize = 2000,
    int maxItems = 30000,
  }) async {
    try {
      final collected = <Reading>[];
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      var truncated = false;

      while (collected.length < maxItems) {
        Query<Map<String, dynamic>> query = _deviceRef(houseId, deviceId)
            .collection('readings')
            .where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
            .where('ts', isLessThanOrEqualTo: Timestamp.fromDate(to))
            .orderBy('ts', descending: true)
            .limit(pageSize);
        if (cursor != null) {
          query = query.startAfterDocument(cursor);
        }

        final snapshot = await query.get();
        collected.addAll(snapshot.docs.map(Reading.fromDoc));
        if (snapshot.docs.length < pageSize) break;
        cursor = snapshot.docs.last;
        if (collected.length >= maxItems) {
          truncated = true;
          break;
        }
      }

      collected.sort((a, b) {
        final at = a.ts;
        final bt = b.ts;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });

      return ReadingRangeResult(readings: collected, truncated: truncated);
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Eventos entre [from] e [to] (usado para reinícios na análise).
  Future<List<DeviceEvent>> fetchEventsRange({
    required String houseId,
    required String deviceId,
    required DateTime from,
    required DateTime to,
    int limit = 1000,
  }) async {
    try {
      final snapshot = await _deviceRef(houseId, deviceId)
          .collection('events')
          .where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
          .where('ts', isLessThanOrEqualTo: Timestamp.fromDate(to))
          .orderBy('ts', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs
          .map(DeviceEvent.fromDoc)
          .toList()
          .reversed
          .toList(growable: false);
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Leituras dos últimos [days] dias para o cálculo de consumo.
  Future<List<Reading>> fetchReadingsForConsumption({
    required String houseId,
    required String deviceId,
    int days = 7,
    int limit = 5000,
  }) async {
    try {
      final since = Timestamp.fromDate(
        DateTime.now().subtract(Duration(days: days)),
      );
      final snapshot = await _deviceRef(houseId, deviceId)
          .collection('readings')
          .where('ts', isGreaterThanOrEqualTo: since)
          .orderBy('ts', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs
          .map(Reading.fromDoc)
          .toList()
          .reversed
          .toList(growable: false);
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<List<DeviceCommand>> watchCommands({
    required String houseId,
    required String deviceId,
    int limit = 5,
  }) =>
      _deviceRef(houseId, deviceId)
          .collection('commands')
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snapshot) => snapshot.docs
              .map(DeviceCommand.fromDoc)
              .toList(growable: false));

  /// Enfileira um comando manual. O device executa e marca done/rejected.
  Future<void> sendCommand({
    required String houseId,
    required String deviceId,
    required CommandAction action,
    required String byUid,
    required String byName,
  }) async {
    try {
      await _deviceRef(houseId, deviceId).collection('commands').add({
        'action': action.wire,
        'status': CommandStatus.pending.wire,
        'createdBy': byUid,
        'createdByName': byName,
        'createdAt': FieldValue.serverTimestamp(),
        // comando expira em 2 min se o device estiver offline
        'expiresAt': Timestamp.fromDate(
          DateTime.now().add(const Duration(minutes: 2)),
        ),
      });
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<List<DeviceEvent>> watchEvents({
    required String houseId,
    required String deviceId,
    int limit = 80,
  }) =>
      _deviceRef(houseId, deviceId)
          .collection('events')
          .orderBy('ts', descending: true)
          .limit(limit)
          .snapshots()
          .map((snapshot) => snapshot.docs.map(DeviceEvent.fromDoc).toList());

  Stream<List<HouseAlert>> watchAlerts({
    required String houseId,
    int limit = 30,
  }) =>
      _db
          .collection('houses')
          .doc(houseId)
          .collection('alerts')
          .orderBy('ts', descending: true)
          .limit(limit)
          .snapshots()
          .map((snapshot) => snapshot.docs.map(HouseAlert.fromDoc).toList());

  Future<void> ackAlert({
    required String houseId,
    required String alertId,
    required String uid,
  }) async {
    try {
      await _db
          .collection('houses')
          .doc(houseId)
          .collection('alerts')
          .doc(alertId)
          .update({
        'ack': true,
        'ackBy': uid,
        'ackTs': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<List<ConfigLogEntry>> watchConfigLog({
    required String houseId,
    int limit = 20,
  }) =>
      _db
          .collection('houses')
          .doc(houseId)
          .collection('configLog')
          .orderBy('ts', descending: true)
          .limit(limit)
          .snapshots()
          .map((snapshot) => snapshot.docs.map(ConfigLogEntry.fromDoc).toList());

  /// Salva a configuração: valida, incrementa configVersion, grava configLog
  /// com old/new e faz tudo em um único batch (atômico).
  Future<void> saveConfig({
    required String houseId,
    required Device device,
    required DeviceConfig newConfig,
    required String byUid,
    required String byName,
  }) async {
    _validateConfig(newConfig, device.config);

    final incremented = newConfig.copyWith(
      configVersion: device.config.configVersion + 1,
      updatedBy: byUid,
    );

    final changes = _diffConfig(device.config, incremented);
    if (changes.isEmpty) {
      throw const AppException('Nenhuma alteração para salvar.');
    }

    final batch = _db.batch();
    batch.update(_deviceRef(houseId, device.id), {
      'config': incremented.toMap(),
    });
    batch.set(
      _db.collection('houses').doc(houseId).collection('configLog').doc(),
      {
        'ts': FieldValue.serverTimestamp(),
        'byUid': byUid,
        'byName': byName,
        'changes': changes,
      },
    );

    try {
      await batch.commit();
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Validação local espelhando as rules (mensagens antes de ir à rede).
  void _validateConfig(DeviceConfig newConfig, DeviceConfig oldConfig) {
    final interval = newConfig.reportIntervalSec;
    if (interval < 15 || interval > 3600) {
      throw const AppException('Intervalo deve estar entre 15 e 3600 segundos.');
    }
    if (newConfig.sensorWindowSec < 5 || newConfig.sensorWindowSec > 60) {
      throw const AppException(
        'A janela de medição deve ficar entre 5 e 60 segundos.',
      );
    }
    final tank = newConfig.tank;
    if (tank.heightCm <= 0) {
      throw const AppException('Altura da caixa deve ser maior que zero.');
    }
    if (tank.capacityL <= 0) {
      throw const AppException('Capacidade deve ser maior que zero.');
    }
    if (tank.minRangeCm < 0 || tank.maxRangeCm <= tank.minRangeCm) {
      throw const AppException(
        'Distância máxima deve ser maior que a distância mínima.',
      );
    }
    if (tank.sensorOffsetCm < 0) {
      throw const AppException('Offset do sensor não pode ser negativo.');
    }
    if (tank.format == TankFormat.cilindro && (tank.diameterCm ?? 0) <= 0) {
      throw const AppException('Informe o diâmetro da caixa cilíndrica.');
    }
    if (tank.format == TankFormat.retangular &&
        ((tank.lengthCm ?? 0) <= 0 || (tank.widthCm ?? 0) <= 0)) {
      throw const AppException('Informe comprimento e largura da caixa.');
    }
    final calibration = [...tank.calibration]
      ..sort((a, b) => a.percent.compareTo(b.percent));
    if (calibration.length == 1) {
      throw const AppException(
        'A tabela de litros precisa de ao menos dois pontos.',
      );
    }
    if (calibration.length >= 2) {
      if (calibration.first.percent > 0 || calibration.last.percent < 100) {
        throw const AppException(
          'A tabela de litros precisa ter pontos em 0% e 100%.',
        );
      }
      for (var i = 1; i < calibration.length; i++) {
        if (calibration[i].liters + 0.01 < calibration[i - 1].liters) {
          throw const AppException(
            'A quantidade em litros não pode diminuir quando o nível sobe.',
          );
        }
      }
    }

    final limits = newConfig.limits;
    if (limits.desligaCm < tank.minRangeCm) {
      throw AppException(
        'O desligamento (${limits.desligaCm.toStringAsFixed(0)} cm) não pode '
        'ser menor que a zona cega do sensor '
        '(${tank.minRangeCm.toStringAsFixed(0)} cm).',
      );
    }
    if (limits.ligaCm <= limits.desligaCm) {
      throw const AppException(
        'O limite de ligar deve ser maior que o de desligar '
        '(a distância cresce quando o nível cai).',
      );
    }
    if (limits.ligaCm > tank.maxRangeCm) {
      throw const AppException(
        'O limite de ligar não pode exceder a distância máxima do sensor.',
      );
    }
    if (newConfig.alerts.lowLevelPercent <= 0 ||
        newConfig.alerts.lowLevelPercent > 100) {
      throw const AppException('Limiar de nível baixo deve ficar entre 1% e 100%.');
    }
    if (newConfig.alerts.offlineAfterSec < 30) {
      throw const AppException('Tempo de offline deve ser de ao menos 30 s.');
    }
    if (newConfig.alerts.sensorFailAfterSec < 30) {
      throw const AppException('Tempo de falha do sensor deve ser de ao menos 30 s.');
    }
    // Guarda-corpo de auditoria: versão nunca retrocede.
    if (newConfig.configVersion != oldConfig.configVersion) {
      throw const AppException('configVersion é controlado pelo aplicativo.');
    }
  }

  /// Diff campo-a-campo para o configLog ({old, new} por caminho).
  Map<String, Map<String, dynamic>> _diffConfig(
    DeviceConfig oldConfig,
    DeviceConfig newConfig,
  ) {
    final changes = <String, Map<String, dynamic>>{};

    void compare(String path, Object? oldValue, Object? newValue) {
      final a = oldValue is num ? oldValue.toDouble() : oldValue;
      final b = newValue is num ? newValue.toDouble() : newValue;
      if (a != b) {
        changes[path] = {'old': oldValue, 'new': newValue};
      }
    }

    compare('config.configVersion', oldConfig.configVersion,
        newConfig.configVersion);
    compare('config.reportIntervalSec', oldConfig.reportIntervalSec,
        newConfig.reportIntervalSec);
    compare('config.sensorWindowSec', oldConfig.sensorWindowSec,
        newConfig.sensorWindowSec);
    compare('config.limits.ligaCm', oldConfig.limits.ligaCm,
        newConfig.limits.ligaCm);
    compare('config.limits.desligaCm', oldConfig.limits.desligaCm,
        newConfig.limits.desligaCm);
    compare('config.tank.format', oldConfig.tank.format.name,
        newConfig.tank.format.name);
    compare('config.tank.heightCm', oldConfig.tank.heightCm,
        newConfig.tank.heightCm);
    compare('config.tank.capacityL', oldConfig.tank.capacityL,
        newConfig.tank.capacityL);
    compare('config.tank.diameterCm', oldConfig.tank.diameterCm,
        newConfig.tank.diameterCm);
    compare('config.tank.lengthCm', oldConfig.tank.lengthCm,
        newConfig.tank.lengthCm);
    compare('config.tank.widthCm', oldConfig.tank.widthCm,
        newConfig.tank.widthCm);
    compare('config.tank.sensorOffsetCm', oldConfig.tank.sensorOffsetCm,
        newConfig.tank.sensorOffsetCm);
    compare('config.tank.minRangeCm', oldConfig.tank.minRangeCm,
        newConfig.tank.minRangeCm);
    compare('config.tank.maxRangeCm', oldConfig.tank.maxRangeCm,
        newConfig.tank.maxRangeCm);
    String calibrationKey(List<VolumePoint> points) => points
        .map((point) => '${point.percent}:${point.liters}')
        .join('|');
    compare(
      'config.tank.calibration',
      calibrationKey(oldConfig.tank.calibration),
      calibrationKey(newConfig.tank.calibration),
    );
    compare('config.alerts.lowLevelPercent',
        oldConfig.alerts.lowLevelPercent, newConfig.alerts.lowLevelPercent);
    compare('config.alerts.offlineAfterSec', oldConfig.alerts.offlineAfterSec,
        newConfig.alerts.offlineAfterSec);
    compare('config.alerts.sensorFailAfterSec',
        oldConfig.alerts.sensorFailAfterSec, newConfig.alerts.sensorFailAfterSec);

    return changes;
  }
}
