import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/ble/provisioning_payload.dart';

ProvisioningPayload buildPayload() => ProvisioningPayload(
      provId: 'prov-1',
      ssid: 'MinhaCasa',
      wifiPassword: 'senha-wifi-secreta',
      fbEmail: 'dev-abc@devices.local',
      fbPassword: 'senha-firebase-secreta',
      houseId: 'casa-demo',
      deviceId: 'dev-1',
      serial: 'HIDRO-A1B2',
    );

void main() {
  test('JSON segue o contrato exato do provisioning', () {
    final json = buildPayload().toJson();
    expect(json.keys.toSet(), {
      'op',
      'provId',
      'ssid',
      'pass',
      'fbEmail',
      'fbPass',
      'houseId',
      'deviceId',
      'serial',
    });
    expect(json['op'], 'prov');
    expect(json['houseId'], 'casa-demo');
  });

  test('mensagem termina com newline (JSON lines)', () {
    final message = buildPayload().toMessage();
    expect(message.endsWith('\n'), isTrue);
    expect(jsonDecode(message), isA<Map<String, dynamic>>());
  });

  test('toString/redactedSummary nunca expõe segredos', () {
    final payload = buildPayload();
    expect(payload.toString(), isNot(contains('senha-wifi-secreta')));
    expect(payload.toString(), isNot(contains('senha-firebase-secreta')));
    expect(payload.redactedSummary(), contains('provId=prov-1'));
  });

  test('wipe zera os bytes em memória', () {
    final payload = buildPayload();
    final bytes = payload.encode();
    expect(bytes.any((byte) => byte != 0), isTrue);
    payload.wipe();
    expect(bytes.every((byte) => byte == 0), isTrue);
  });
}
