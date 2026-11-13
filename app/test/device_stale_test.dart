import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/models/device.dart';

Device buildDevice({
  required DateTime lastSeen,
  int offlineAfterSec = 180,
  String fwVersion = '1.0.0',
}) {
  return Device(
    id: 'dev-1',
    name: 'Caixa',
    serial: 'HIDRO-0001',
    deviceUid: 'uid-device',
    fwVersion: fwVersion,
    lastSeen: lastSeen,
    config: DeviceConfig(
      configVersion: 3,
      reportIntervalSec: 60,
      limits: const LimitConfig(ligaCm: 80, desligaCm: 25),
      tank: const TankConfig(
        format: TankFormat.livre,
        heightCm: 100,
        capacityL: 500,
        sensorOffsetCm: 0,
        minRangeCm: 25,
        maxRangeCm: 150,
      ),
      alerts: AlertThresholds(
        lowLevelPercent: 20,
        offlineAfterSec: offlineAfterSec,
        sensorFailAfterSec: 180,
      ),
    ),
  );
}

void main() {
  test('detecta stale quando now - lastSeen passa do limiar', () {
    final now = DateTime(2026, 10, 24, 12);
    final device = buildDevice(
      lastSeen: now.subtract(const Duration(seconds: 181)),
      offlineAfterSec: 180,
    );
    expect(device.isStale(now: now), isTrue);
    expect(device.isOnline(now: now), isFalse);
  });

  test('considera online dentro do limiar', () {
    final now = DateTime(2026, 10, 24, 12);
    final device = buildDevice(
      lastSeen: now.subtract(const Duration(seconds: 120)),
      offlineAfterSec: 180,
    );
    expect(device.isStale(now: now), isFalse);
    expect(device.isOnline(now: now), isTrue);
  });

  test('sem lastSeen é stale', () {
    final device = Device(
      id: 'dev-2',
      name: 'Caixa',
      serial: 'S',
      deviceUid: 'u',
      fwVersion: '1',
      config: DeviceConfig.defaults(updatedBy: 'owner'),
    );
    expect(device.isStale(), isTrue);
  });

  test('volume é proporcional à coluna d\'água', () {
    const tank = TankConfig(
      format: TankFormat.cilindro,
      heightCm: 100,
      capacityL: 1000,
      sensorOffsetCm: 0,
      minRangeCm: 25,
      maxRangeCm: 150,
      diameterCm: 100,
    );
    expect(tank.volumeForLevel(0), 0);
    expect(tank.volumeForLevel(50), 500);
    expect(tank.volumeForLevel(150), 1000); // clamp
  });
}
