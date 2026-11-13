import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'house.dart' show dateFrom;

enum TankFormat {
  cilindro,
  retangular,
  livre;

  static TankFormat parse(Object? value) => switch (value) {
        'cilindro' => TankFormat.cilindro,
        'retangular' => TankFormat.retangular,
        _ => TankFormat.livre,
      };

  String get label => switch (this) {
        TankFormat.cilindro => 'Cilindro',
        TankFormat.retangular => 'Retangular',
        TankFormat.livre => 'Livre (capacidade informada)',
      };
}

/// Ponto da tabela manual de volume: quantos litros existem em [percent]%.
class VolumePoint {
  const VolumePoint({required this.percent, required this.liters});

  final double percent;
  final double liters;

  factory VolumePoint.fromMap(Map<String, dynamic> data) => VolumePoint(
        percent: (data['percent'] as num?)?.toDouble() ?? 0,
        liters: (data['liters'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toMap() => {'percent': percent, 'liters': liters};

  VolumePoint copyWith({double? percent, double? liters}) => VolumePoint(
        percent: percent ?? this.percent,
        liters: liters ?? this.liters,
      );
}

/// Geometria da caixa. `capacityL` é a fonte de verdade para volume;
/// a geometria serve para conferência e para o cálculo de cm -> L.
///
/// Se [calibration] tiver 2+ pontos, o volume exibido é interpolado pela
/// tabela manual informada pelo usuário (litros por %), em vez de linear.
class TankConfig {
  const TankConfig({
    required this.format,
    required this.heightCm,
    required this.capacityL,
    required this.sensorOffsetCm,
    required this.minRangeCm,
    required this.maxRangeCm,
    this.diameterCm,
    this.lengthCm,
    this.widthCm,
    this.calibration = const <VolumePoint>[],
  });

  final TankFormat format;
  final double heightCm;
  final double capacityL;
  final double sensorOffsetCm;
  final double minRangeCm;
  final double maxRangeCm;
  final double? diameterCm;
  final double? lengthCm;
  final double? widthCm;
  final List<VolumePoint> calibration;

  bool get usesManualVolume => calibration.length >= 2;

  /// Litros para um percentual, interpolando a tabela manual (ou linear).
  double volumeForPercent(double percent) {
    final p = percent.clamp(0.0, 100.0);
    if (calibration.length < 2) {
      return capacityL * p / 100.0;
    }
    final points = [...calibration]
      ..sort((a, b) => a.percent.compareTo(b.percent));
    if (p <= points.first.percent) return points.first.liters;
    if (p >= points.last.percent) return points.last.liters;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (p >= a.percent && p <= b.percent) {
        final span = b.percent - a.percent;
        if (span <= 0) return b.liters;
        return a.liters +
            (b.liters - a.liters) * ((p - a.percent) / span);
      }
    }
    return capacityL * p / 100.0;
  }

  factory TankConfig.fromMap(Map<String, dynamic> data) => TankConfig(
        format: TankFormat.parse(data['format']),
        heightCm: (data['heightCm'] as num?)?.toDouble() ?? 100,
        capacityL: (data['capacityL'] as num?)?.toDouble() ?? 500,
        sensorOffsetCm: (data['sensorOffsetCm'] as num?)?.toDouble() ?? 0,
        minRangeCm: (data['minRangeCm'] as num?)?.toDouble() ?? 25,
        maxRangeCm: (data['maxRangeCm'] as num?)?.toDouble() ?? 150,
        diameterCm: (data['diameterCm'] as num?)?.toDouble(),
        lengthCm: (data['lengthCm'] as num?)?.toDouble(),
        widthCm: (data['widthCm'] as num?)?.toDouble(),
        calibration: ((data['calibration'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => VolumePoint.fromMap(item.cast<String, dynamic>()))
            .toList(growable: false),
      );

  Map<String, dynamic> toMap() => {
        'format': format.name,
        'heightCm': heightCm,
        'capacityL': capacityL,
        'sensorOffsetCm': sensorOffsetCm,
        'minRangeCm': minRangeCm,
        'maxRangeCm': maxRangeCm,
        if (format == TankFormat.cilindro) 'diameterCm': diameterCm,
        if (format == TankFormat.retangular) ...{
          'lengthCm': lengthCm,
          'widthCm': widthCm,
        },
        if (calibration.length >= 2)
          'calibration': calibration.map((p) => p.toMap()).toList(),
      };

  /// Litros correspondentes a uma coluna d'água de [levelCm] centímetros.
  double volumeForLevel(double levelCm) {
    if (levelCm <= 0 || heightCm <= 0) return 0;
    final fraction = (levelCm / heightCm).clamp(0.0, 1.0);
    return volumeForPercent(fraction * 100.0);
  }

  /// Capacidade geométrica calculada (para dica na UI de configuração).
  double? get geometricCapacityL {
    switch (format) {
      case TankFormat.cilindro:
        if (diameterCm == null) return null;
        final r = diameterCm! / 2;
        return math.pi * r * r * heightCm / 1000;
      case TankFormat.retangular:
        if (lengthCm == null || widthCm == null) return null;
        return lengthCm! * widthCm! * heightCm / 1000;
      case TankFormat.livre:
        return null;
    }
  }

  TankConfig copyWith({
    TankFormat? format,
    double? heightCm,
    double? capacityL,
    double? sensorOffsetCm,
    double? minRangeCm,
    double? maxRangeCm,
    double? diameterCm,
    double? lengthCm,
    double? widthCm,
    List<VolumePoint>? calibration,
  }) =>
      TankConfig(
        format: format ?? this.format,
        heightCm: heightCm ?? this.heightCm,
        capacityL: capacityL ?? this.capacityL,
        sensorOffsetCm: sensorOffsetCm ?? this.sensorOffsetCm,
        minRangeCm: minRangeCm ?? this.minRangeCm,
        maxRangeCm: maxRangeCm ?? this.maxRangeCm,
        diameterCm: diameterCm ?? this.diameterCm,
        lengthCm: lengthCm ?? this.lengthCm,
        widthCm: widthCm ?? this.widthCm,
        calibration: calibration ?? this.calibration,
      );
}

/// Limites autônomos do firmware. Comandos manuais usam a coleção commands,
/// separada da configuração, e continuam sujeitos às travas do firmware.
/// Unidade: cm medidos do sensor até a superfície da água.
class LimitConfig {
  const LimitConfig({required this.ligaCm, required this.desligaCm});

  final double ligaCm;
  final double desligaCm;

  factory LimitConfig.fromMap(Map<String, dynamic> data) => LimitConfig(
        ligaCm: (data['ligaCm'] as num?)?.toDouble() ?? 80,
        desligaCm: (data['desligaCm'] as num?)?.toDouble() ?? 25,
      );

  Map<String, dynamic> toMap() => {'ligaCm': ligaCm, 'desligaCm': desligaCm};

  LimitConfig copyWith({double? ligaCm, double? desligaCm}) => LimitConfig(
        ligaCm: ligaCm ?? this.ligaCm,
        desligaCm: desligaCm ?? this.desligaCm,
      );
}

class AlertThresholds {
  const AlertThresholds({
    required this.lowLevelPercent,
    required this.offlineAfterSec,
    required this.sensorFailAfterSec,
  });

  final int lowLevelPercent;
  final int offlineAfterSec;
  final int sensorFailAfterSec;

  factory AlertThresholds.fromMap(Map<String, dynamic> data) => AlertThresholds(
        lowLevelPercent: (data['lowLevelPercent'] as num?)?.toInt() ?? 20,
        offlineAfterSec: (data['offlineAfterSec'] as num?)?.toInt() ?? 180,
        sensorFailAfterSec:
            (data['sensorFailAfterSec'] as num?)?.toInt() ?? 180,
      );

  Map<String, dynamic> toMap() => {
        'lowLevelPercent': lowLevelPercent,
        'offlineAfterSec': offlineAfterSec,
        'sensorFailAfterSec': sensorFailAfterSec,
      };

  AlertThresholds copyWith({
    int? lowLevelPercent,
    int? offlineAfterSec,
    int? sensorFailAfterSec,
  }) =>
      AlertThresholds(
        lowLevelPercent: lowLevelPercent ?? this.lowLevelPercent,
        offlineAfterSec: offlineAfterSec ?? this.offlineAfterSec,
        sensorFailAfterSec: sensorFailAfterSec ?? this.sensorFailAfterSec,
      );
}

class DeviceConfig {
  const DeviceConfig({
    required this.configVersion,
    required this.reportIntervalSec,
    required this.limits,
    required this.tank,
    required this.alerts,
    this.sensorWindowSec = 20,
    this.updatedAt,
    this.updatedBy,
  });

  final int configVersion;
  final int reportIntervalSec;
  final int sensorWindowSec;
  final LimitConfig limits;
  final TankConfig tank;
  final AlertThresholds alerts;
  final DateTime? updatedAt;
  final String? updatedBy;

  /// Defaults de fábrica usados ao cadastrar um device novo.
  factory DeviceConfig.defaults({required String updatedBy, DateTime? updatedAt}) =>
      DeviceConfig(
        configVersion: 1,
        reportIntervalSec: 60,
        sensorWindowSec: 20,
        limits: const LimitConfig(ligaCm: 80, desligaCm: 25),
        tank: const TankConfig(
          format: TankFormat.livre,
          heightCm: 100,
          capacityL: 500,
          sensorOffsetCm: 0,
          minRangeCm: 25,
          maxRangeCm: 150,
        ),
        alerts: const AlertThresholds(
          lowLevelPercent: 20,
          offlineAfterSec: 180,
          sensorFailAfterSec: 180,
        ),
        updatedAt: updatedAt,
        updatedBy: updatedBy,
      );

  factory DeviceConfig.fromMap(Map<String, dynamic> data) => DeviceConfig(
        configVersion: (data['configVersion'] as num?)?.toInt() ?? 1,
        reportIntervalSec: (data['reportIntervalSec'] as num?)?.toInt() ?? 60,
        sensorWindowSec: (data['sensorWindowSec'] as num?)?.toInt() ?? 20,
        limits: LimitConfig.fromMap(
          (data['limits'] as Map?)?.cast<String, dynamic>() ??
              const {'ligaCm': 80, 'desligaCm': 25},
        ),
        tank: TankConfig.fromMap(
          (data['tank'] as Map?)?.cast<String, dynamic>() ??
              const {'format': 'livre', 'heightCm': 100, 'capacityL': 500},
        ),
        alerts: AlertThresholds.fromMap(
          (data['alerts'] as Map?)?.cast<String, dynamic>() ??
              const {'lowLevelPercent': 20, 'offlineAfterSec': 180, 'sensorFailAfterSec': 180},
        ),
        updatedAt: dateFrom(data['updatedAt']),
        updatedBy: data['updatedBy'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'configVersion': configVersion,
        'reportIntervalSec': reportIntervalSec,
        'sensorWindowSec': sensorWindowSec,
        'limits': limits.toMap(),
        'tank': tank.toMap(),
        'alerts': alerts.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': updatedBy,
      };

  DeviceConfig copyWith({
    int? configVersion,
    int? reportIntervalSec,
    int? sensorWindowSec,
    LimitConfig? limits,
    TankConfig? tank,
    AlertThresholds? alerts,
    String? updatedBy,
  }) =>
      DeviceConfig(
        configVersion: configVersion ?? this.configVersion,
        reportIntervalSec: reportIntervalSec ?? this.reportIntervalSec,
        sensorWindowSec: sensorWindowSec ?? this.sensorWindowSec,
        limits: limits ?? this.limits,
        tank: tank ?? this.tank,
        alerts: alerts ?? this.alerts,
        updatedAt: updatedAt,
        updatedBy: updatedBy ?? this.updatedBy,
      );
}

class DeviceLatest {
  const DeviceLatest({
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

  final double distanceCm;
  final double levelPercent;
  final double levelCm;
  final double volumeL;
  final bool pumpOn;
  final bool valveOpen;
  final bool sensorOk;
  final int rssi;
  final DateTime? ts;

  factory DeviceLatest.fromMap(Map<String, dynamic> data) => DeviceLatest(
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

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.serial,
    required this.deviceUid,
    required this.fwVersion,
    required this.config,
    this.latest,
    this.lastSeen,
    this.createdAt,
  });

  final String id;
  final String name;
  final String serial;
  final String deviceUid;
  final String fwVersion;
  final DeviceConfig config;
  final DeviceLatest? latest;
  final DateTime? lastSeen;
  final DateTime? createdAt;

  /// Stale = sem contato além do limiar configurado (default 3x intervalo).
  bool isStale({DateTime? now}) {
    if (lastSeen == null) return true;
    final reference = now ?? DateTime.now();
    final limit = Duration(seconds: config.alerts.offlineAfterSec);
    return reference.difference(lastSeen!) > limit;
  }

  bool isOnline({DateTime? now}) =>
      lastSeen != null && !isStale(now: now);

  factory Device.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final configMap = (data['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    final latestMap = (data['latest'] as Map?)?.cast<String, dynamic>();
    return Device(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Caixa',
      serial: (data['serial'] as String?) ?? '',
      deviceUid: (data['deviceUid'] as String?) ?? '',
      fwVersion: (data['fwVersion'] as String?) ?? '—',
      config: DeviceConfig.fromMap(configMap),
      latest: latestMap == null ? null : DeviceLatest.fromMap(latestMap),
      lastSeen: dateFrom(data['lastSeen']),
      createdAt: dateFrom(data['createdAt']),
    );
  }
}
