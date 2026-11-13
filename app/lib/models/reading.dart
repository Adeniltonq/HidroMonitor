import 'package:cloud_firestore/cloud_firestore.dart';

import 'house.dart' show dateFrom;

/// Uma leitura de telemetria publicada pelo ESP32 (imutável para o app).
class Reading {
  const Reading({
    required this.id,
    required this.distanceCm,
    required this.levelPercent,
    required this.levelCm,
    required this.volumeL,
    required this.pumpOn,
    required this.valveOpen,
    required this.sensorOk,
    required this.rssi,
    this.ts,
  });

  final String id;
  final double distanceCm;
  final double levelPercent;
  final double levelCm;
  final double volumeL;
  final bool pumpOn;
  final bool valveOpen;
  final bool sensorOk;
  final int rssi;
  final DateTime? ts;

  factory Reading.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return Reading(
      id: doc.id,
      distanceCm: (data['distanceCm'] as num?)?.toDouble() ?? 0,
      levelPercent: (data['levelPercent'] as num?)?.toDouble() ?? 0,
      levelCm: (data['levelCm'] as num?)?.toDouble() ?? 0,
      volumeL: (data['volumeL'] as num?)?.toDouble() ?? 0,
      pumpOn: data['pumpOn'] == true,
      valveOpen: data['valveOpen'] == true,
      sensorOk: data['sensorOk'] != false,
      rssi: (data['rssi'] as num?)?.toInt() ?? 0,
      ts: dateFrom(data['ts']),
    );
  }
}

enum DeviceEventType {
  pumpOn('pump_on', 'Bomba ligada'),
  pumpOff('pump_off', 'Bomba desligada'),
  valveOpen('valve_open', 'Válvula aberta'),
  valveClose('valve_close', 'Válvula fechada'),
  boot('boot', 'Reinício'),
  wifiDrop('wifi_drop', 'Wi-Fi caiu'),
  wifiConn('wifi_conn', 'Wi-Fi reconectado'),
  invalidReading('invalid_reading', 'Leitura inválida'),
  manualOn('manual_on', 'Bomba ligada manualmente'),
  manualOff('manual_off', 'Bomba desligada manualmente'),
  manualAuto('manual_auto', 'Controle automático restaurado');

  const DeviceEventType(this.wire, this.label);

  final String wire;
  final String label;

  static DeviceEventType parse(Object? value) {
    for (final type in DeviceEventType.values) {
      if (type.wire == value) return type;
    }
    return DeviceEventType.invalidReading;
  }
}

class DeviceEvent {
  const DeviceEvent({
    required this.id,
    required this.type,
    required this.detail,
    this.ts,
  });

  final String id;
  final DeviceEventType type;
  final String detail;
  final DateTime? ts;

  factory DeviceEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return DeviceEvent(
      id: doc.id,
      type: DeviceEventType.parse(data['type']),
      detail: (data['detail'] as String?) ?? '',
      ts: dateFrom(data['ts']),
    );
  }
}

enum AlertSeverity {
  info('info', 'Informativo'),
  warn('warn', 'Atenção'),
  crit('crit', 'Crítico');

  const AlertSeverity(this.wire, this.label);

  final String wire;
  final String label;

  static AlertSeverity parse(Object? value) => switch (value) {
        'crit' => AlertSeverity.crit,
        'warn' => AlertSeverity.warn,
        _ => AlertSeverity.info,
      };
}

class HouseAlert {
  const HouseAlert({
    required this.id,
    required this.type,
    required this.severity,
    required this.message,
    required this.deviceId,
    required this.source,
    required this.ack,
    this.ackBy,
    this.ts,
    this.ackTs,
  });

  final String id;
  final String type;
  final AlertSeverity severity;
  final String message;
  final String deviceId;
  final String source;
  final bool ack;
  final String? ackBy;
  final DateTime? ts;
  final DateTime? ackTs;

  factory HouseAlert.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return HouseAlert(
      id: doc.id,
      type: (data['type'] as String?) ?? 'generic',
      severity: AlertSeverity.parse(data['severity']),
      message: (data['message'] as String?) ?? '',
      deviceId: (data['deviceId'] as String?) ?? '',
      source: (data['source'] as String?) ?? 'device',
      ack: data['ack'] == true,
      ackBy: data['ackBy'] as String?,
      ts: dateFrom(data['ts']),
      ackTs: dateFrom(data['ackTs']),
    );
  }
}

class ConfigChange {
  const ConfigChange({this.oldValue, this.newValue});

  final Object? oldValue;
  final Object? newValue;

  factory ConfigChange.fromMap(Map<String, dynamic> data) =>
      ConfigChange(oldValue: data['old'], newValue: data['new']);
}

class ConfigLogEntry {
  const ConfigLogEntry({
    required this.id,
    required this.byUid,
    required this.byName,
    required this.changes,
    this.ts,
  });

  final String id;
  final String byUid;
  final String byName;
  final Map<String, ConfigChange> changes;
  final DateTime? ts;

  factory ConfigLogEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final rawChanges = (data['changes'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ConfigLogEntry(
      id: doc.id,
      byUid: (data['byUid'] as String?) ?? '',
      byName: (data['byName'] as String?) ?? '',
      ts: dateFrom(data['ts']),
      changes: rawChanges.map(
        (key, value) => MapEntry(
          key,
          ConfigChange.fromMap((value as Map?)?.cast<String, dynamic>() ?? const {}),
        ),
      ),
    );
  }
}
