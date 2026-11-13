import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/models/consumption.dart';
import 'package:hidromonitor/models/device.dart';
import 'package:hidromonitor/models/reading.dart';

TankConfig tank({List<VolumePoint> calibration = const []}) => TankConfig(
      format: TankFormat.livre,
      heightCm: 100,
      capacityL: 1000,
      sensorOffsetCm: 0,
      minRangeCm: 25,
      maxRangeCm: 150,
      calibration: calibration,
    );

void main() {
  test('sem tabela usa o cálculo linear pela capacidade', () {
    final t = tank();
    expect(t.volumeForPercent(0), 0);
    expect(t.volumeForPercent(50), 500);
    expect(t.volumeForPercent(100), 1000);
  });

  test('tabela manual interpola entre os pontos', () {
    final t = tank(calibration: const [
      VolumePoint(percent: 0, liters: 0),
      VolumePoint(percent: 50, liters: 400),
      VolumePoint(percent: 100, liters: 1000),
    ]);
    expect(t.volumeForPercent(0), 0);
    expect(t.volumeForPercent(25), closeTo(200, 1e-9));
    expect(t.volumeForPercent(50), closeTo(400, 1e-9));
    expect(t.volumeForPercent(75), closeTo(700, 1e-9));
    expect(t.volumeForPercent(100), closeTo(1000, 1e-9));
  });

  test('fora da faixa faz clamp nos extremos', () {
    final t = tank(calibration: const [
      VolumePoint(percent: 10, liters: 50),
      VolumePoint(percent: 90, liters: 950),
    ]);
    expect(t.volumeForPercent(-10), 50);
    expect(t.volumeForPercent(120), 950);
  });

  test('volumeForLevel usa a tabela (coluna d\'água)', () {
    final t = tank(calibration: const [
      VolumePoint(percent: 0, liters: 0),
      VolumePoint(percent: 100, liters: 800),
    ]);
    expect(t.volumeForLevel(50), closeTo(400, 1e-9));
  });

  test('consumo respeita a tabela manual', () {
    final readings = [
      Reading(
        id: 'a',
        distanceCm: 0,
        levelPercent: 100,
        levelCm: 100,
        volumeL: 1000,
        pumpOn: false,
        valveOpen: false,
        sensorOk: true,
        rssi: -60,
        ts: DateTime(2026, 10, 24, 10),
      ),
      Reading(
        id: 'b',
        distanceCm: 0,
        levelPercent: 50,
        levelCm: 50,
        volumeL: 500,
        pumpOn: false,
        valveOpen: false,
        sensorOk: true,
        rssi: -60,
        ts: DateTime(2026, 10, 24, 10, 1),
      ),
    ];
    final t = tank(calibration: const [
      VolumePoint(percent: 0, liters: 0),
      VolumePoint(percent: 50, liters: 300),
      VolumePoint(percent: 100, liters: 800),
    ]);
    final calculator = ConsumptionCalculator(
      reportIntervalSec: 60,
      volumeForPercent: t.volumeForPercent,
    );
    expect(calculator.byDay(readings)[DateTime(2026, 10, 24)], closeTo(500, 1e-9));
  });
}
