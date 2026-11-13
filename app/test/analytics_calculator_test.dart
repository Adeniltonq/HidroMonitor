import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/models/device.dart';
import 'package:hidromonitor/models/reading.dart';
import 'package:hidromonitor/services/analytics_calculator.dart';

DeviceConfig config() => const DeviceConfig(
      configVersion: 1,
      reportIntervalSec: 60,
      sensorWindowSec: 20,
      limits: LimitConfig(ligaCm: 80, desligaCm: 25),
      tank: TankConfig(
        format: TankFormat.livre,
        heightCm: 100,
        capacityL: 1000,
        sensorOffsetCm: 0,
        minRangeCm: 25,
        maxRangeCm: 150,
      ),
      alerts: AlertThresholds(
        lowLevelPercent: 20,
        offlineAfterSec: 180,
        sensorFailAfterSec: 180,
      ),
    );

Reading reading(
  DateTime ts,
  double percent, {
  bool pumpOn = false,
  bool sensorOk = true,
}) =>
    Reading(
      id: ts.toIso8601String(),
      distanceCm: 0,
      levelPercent: percent,
      levelCm: percent,
      volumeL: percent * 10,
      pumpOn: pumpOn,
      valveOpen: false,
      sensorOk: sensorOk,
      rssi: -60,
      ts: ts,
    );

void main() {
  test('consumo, médias, pico, bomba e previsão', () {
    final start = DateTime(2026, 10, 1);
    final end = DateTime(2026, 10, 2);
    final previousStart = DateTime(2026, 9, 30);
    final readings = [
      reading(previousStart.add(const Duration(hours: 23, minutes: 55)), 100),
      reading(previousStart.add(const Duration(hours: 23, minutes: 59)), 95),
      reading(start, 100),
      reading(start.add(const Duration(minutes: 5)), 90),
      reading(start.add(const Duration(minutes: 10)), 90, pumpOn: true),
      reading(start.add(const Duration(minutes: 15)), 95, pumpOn: true),
      reading(start.add(const Duration(minutes: 20)), 95),
      reading(start.add(const Duration(minutes: 25)), 85),
    ];

    final s = const AnalyticsCalculator().build(
      readings: readings,
      events: const [],
      config: config(),
      start: start,
      end: end,
      previousStart: previousStart,
      previousEnd: start,
      now: DateTime(2026, 10, 2, 1),
    );

    expect(s.totalLiters, closeTo(200, 1e-6));
    expect(s.previousLiters, closeTo(50, 1e-6));
    expect(s.comparisonPercent, closeTo(300, 1e-6));
    expect(s.dailyAverage, closeTo(200, 1e-6));
    expect(s.maxDay?.liters, closeTo(200, 1e-6));
    expect(s.minDay?.liters, closeTo(200, 1e-6));
    expect(s.peakHourLabel, '00h–01h');
    expect(s.hourlyAverage[0], closeTo(200, 1e-6));
    expect(s.pump.activations, 1);
    expect(s.pump.fillCycles, 1);
    expect(s.pump.totalRuntime, const Duration(minutes: 10));
    expect(s.drainLitersPerHour, closeTo(1200, 1e-6));
    expect(s.fillLitersPerHour, closeTo(600, 1e-6));
    expect(s.forecast.hasEstimate, isTrue);
    expect(s.forecast.hoursToEmpty, closeTo(102, 1e-6));
    // Consumo na madrugada (00h–05h) é sinalizado.
    expect(s.anomalies.any((a) => a.title == 'Consumo na madrugada'), isTrue);
  });

  test('três noites com consumo geram alerta de possível vazamento', () {
    final start = DateTime(2026, 10, 1);
    final end = DateTime(2026, 10, 4);
    final readings = <Reading>[];
    for (var day = 0; day < 3; day++) {
      final base = start.add(Duration(days: day));
      readings.add(reading(base.add(const Duration(hours: 2)), 100));
      readings.add(reading(base.add(const Duration(hours: 2, minutes: 5)), 97));
      readings.add(reading(base.add(const Duration(hours: 12)), 97));
    }

    final s = const AnalyticsCalculator().build(
      readings: readings,
      events: const [],
      config: config(),
      start: start,
      end: end,
      previousStart: start.subtract(const Duration(days: 3)),
      previousEnd: start,
      now: DateTime(2026, 10, 4, 1),
    );

    expect(s.totalLiters, closeTo(90, 1e-6));
    final leak = s.anomalies.where((a) => a.title == 'Possível vazamento');
    expect(leak.length, 1);
    expect(leak.first.level, AnomalyLevel.crit);
  });

  test('sem consumo não há previsão', () {
    final start = DateTime(2026, 10, 1);
    final end = DateTime(2026, 10, 2);
    final readings = [
      reading(start, 80),
      reading(start.add(const Duration(minutes: 5)), 80),
      reading(start.add(const Duration(minutes: 10)), 80),
    ];
    final s = const AnalyticsCalculator().build(
      readings: readings,
      events: const [],
      config: config(),
      start: start,
      end: end,
      previousStart: start.subtract(const Duration(days: 1)),
      previousEnd: start,
      now: end,
    );
    expect(s.forecast.hasEstimate, isFalse);
    expect(s.totalLiters, 0);
  });
}
