import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/models/consumption.dart';
import 'package:hidromonitor/models/reading.dart';

Reading reading({
  required DateTime ts,
  required double volume,
  bool pumpOn = false,
  bool sensorOk = true,
}) {
  return Reading(
    id: ts.toIso8601String(),
    distanceCm: 0,
    levelPercent: 0,
    levelCm: 0,
    volumeL: volume,
    pumpOn: pumpOn,
    valveOpen: false,
    sensorOk: sensorOk,
    rssi: -60,
    ts: ts,
  );
}

void main() {
  const calculator = ConsumptionCalculator(reportIntervalSec: 60);

  test('soma quedas com bomba desligada e sensor válido', () {
    final base = DateTime(2026, 10, 24, 10);
    final readings = [
      reading(ts: base, volume: 500),
      reading(ts: base.add(const Duration(minutes: 1)), volume: 480),
      reading(ts: base.add(const Duration(minutes: 2)), volume: 470),
    ];
    final byDay = calculator.byDay(readings);
    expect(byDay[DateTime(2026, 10, 24)], closeTo(30, 1e-9));
  });

  test('ignora trechos com bomba ligada (reposição)', () {
    final base = DateTime(2026, 10, 24, 10);
    final readings = [
      reading(ts: base, volume: 400),
      reading(ts: base.add(const Duration(minutes: 1)), volume: 350),
      reading(
        ts: base.add(const Duration(minutes: 2)),
        volume: 380,
        pumpOn: true,
      ),
      reading(ts: base.add(const Duration(minutes: 3)), volume: 500),
    ];
    final byDay = calculator.byDay(readings);
    // apenas 400 -> 350 entra na conta (50 L)
    expect(byDay[DateTime(2026, 10, 24)], closeTo(50, 1e-9));
  });

  test('ignora leituras com sensor inválido', () {
    final base = DateTime(2026, 10, 24, 10);
    final readings = [
      reading(ts: base, volume: 400),
      reading(ts: base.add(const Duration(minutes: 1)), volume: 390),
      reading(
        ts: base.add(const Duration(minutes: 2)),
        volume: 300,
        sensorOk: false,
      ),
      reading(ts: base.add(const Duration(minutes: 3)), volume: 380),
    ];
    final byDay = calculator.byDay(readings);
    // 400 -> 390 conta (10 L); pares envolvendo a leitura inválida não contam.
    expect(byDay[DateTime(2026, 10, 24)], closeTo(10, 1e-9));
  });

  test('ignora lacunas maiores que 5x o intervalo', () {
    final base = DateTime(2026, 10, 24, 10);
    final readings = [
      reading(ts: base, volume: 400),
      reading(
        ts: base.add(const Duration(minutes: 6)),
        volume: 300,
      ),
    ];
    expect(calculator.byDay(readings), isEmpty);
    expect(calculator.maxGap, const Duration(minutes: 5));
  });

  test('agrupa por dia local e ignora volumes crescentes', () {
    final day1 = DateTime(2026, 10, 23, 23, 58);
    final day2 = DateTime(2026, 10, 24, 0, 1);
    final readings = [
      reading(ts: day1, volume: 500),
      reading(ts: day1.add(const Duration(minutes: 1)), volume: 480),
      reading(ts: day2, volume: 470),
      reading(ts: day2.add(const Duration(minutes: 1)), volume: 460),
    ];
    final byDay = calculator.byDay(readings);
    expect(byDay[DateTime(2026, 10, 23)], closeTo(20, 1e-9));
    expect(byDay[DateTime(2026, 10, 24)], closeTo(20, 1e-9));
  });

  test('totalBetween é inclusivo nos extremos', () {
    final byDay = {
      DateTime(2026, 10, 20): 100.0,
      DateTime(2026, 10, 22): 50.0,
      DateTime(2026, 10, 24): 25.0,
    };
    expect(
      calculator.totalBetween(
        byDay,
        DateTime(2026, 10, 20, 18),
        DateTime(2026, 10, 22, 6),
      ),
      150,
    );
  });
}
