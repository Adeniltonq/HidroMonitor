import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/ble/ble_provisioning_codec.dart';

const codec = BleProvisioningCodec();

String buildMessage({String ssid = 'Casa Ação', int mtu = 247}) {
  final payload = {
    'op': 'prov',
    'provId': 'abc123',
    'ssid': ssid,
    'pass': 'senha-super-secreta',
    'fbEmail': 'dev-abc@devices.local',
    'fbPass': 'firebase-secret',
    'houseId': 'casa-demo',
    'deviceId': 'dev-1',
    'serial': 'HIDRO-A1B2',
  };
  expect(mtu, greaterThanOrEqualTo(23));
  return '${jsonEncode(payload)}\n';
}

void main() {
  group('BleProvisioningCodec.fragment/reassemble', () {
    test('ida e volta com MTU 247 preserva a mensagem', () {
      final message = buildMessage();
      final frames = codec.fragment(message, mtu: 247);

      expect(frames.length, greaterThan(1));
      expect(frames.last.isChecksum, isTrue);
      expect(frames.last.data.length, 2);
      expect(frames.first.seq, 0);
      expect(frames[frames.length - 2].isLast, isTrue);
      expect(codec.reassemble(frames), message);
    });

    test('ida e volta com MTU mínimo (23) e UTF-8 multibyte', () {
      final message = buildMessage(ssid: 'Rede Ação Ção');
      final frames = codec.fragment(message, mtu: 23);
      expect(frames.first.data.length, lessThanOrEqualTo(18));
      expect(codec.reassemble(frames), message);
    });

    test('cada frame cabe no ATT MTU (MTU - 3)', () {
      for (final mtu in [23, 60, 247]) {
        final frames = codec.fragment(buildMessage(), mtu: mtu);
        for (final frame in frames) {
          expect(
            frame.toBytes().length,
            lessThanOrEqualTo(mtu - 3),
            reason: 'MTU $mtu, frame seq ${frame.seq}',
          );
        }
      }
    });

    test('mensagem exatamente do tamanho do chunk', () {
      // JSON válido com exatamente 18 bytes (chunk do MTU 23: 23 - 3 - 2).
      final message = '{"aa":11,"bb":22}\n';
      expect(utf8.encode(message).length, 18);
      final frames = codec.fragment(message, mtu: 23);
      expect(frames.first.isLast, isTrue);
      expect(codec.reassemble(frames), message);
    });

    test('rejeita mensagem vazia', () {
      expect(() => codec.fragment('', mtu: 247), throwsArgumentError);
    });

    test('rejeita mensagem sem delimitador final', () {
      expect(() => codec.fragment('{"op":"prov"}', mtu: 247), throwsArgumentError);
    });

    test('rejeita mensagem acima do limite', () {
      final message = '${'a' * (BleProvisioningCodec.maxMessageBytes)}\n';
      expect(() => codec.fragment(message, mtu: 247), throwsArgumentError);
    });
  });

  group('checksum', () {
    test('CRC16-CCITT-FALSE vetor conhecido', () {
      expect(BleProvisioningCodec.checksum(utf8.encode('123456789')), 0x29B1);
    });

    test('detecta payload corrompido', () {
      final frames = codec.fragment(buildMessage(), mtu: 247);
      final corrupted = [
        BleFrame(
          seq: frames.first.seq,
          flags: frames.first.flags,
          data: [...frames.first.data]..[0] ^= 0xFF,
        ),
        ...frames.skip(1),
      ];
      expect(
        () => codec.reassemble(corrupted),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejeita frame de checksum ausente', () {
      final frames = codec.fragment(buildMessage(), mtu: 247);
      expect(
        () => codec.reassemble(frames.sublist(0, frames.length - 1)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejeita checksum com valor errado', () {
      final frames = codec.fragment(buildMessage(), mtu: 247);
      final last = frames.last;
      final broken = [
        ...frames.sublist(0, frames.length - 1),
        BleFrame(
          seq: last.seq,
          flags: last.flags,
          data: [last.data[0] ^ 0xFF, last.data[1]],
        ),
      ];
      expect(
        () => codec.reassemble(broken),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ordem e enquadramento', () {
    test('rejeita sequência fora de ordem', () {
      final frames = codec.fragment(buildMessage(), mtu: 60);
      final swapped = [...frames];
      final tmp = swapped[0];
      swapped[0] = BleFrame(seq: tmp.seq, flags: tmp.flags, data: frames[1].data);
      swapped[1] = BleFrame(seq: frames[1].seq, flags: frames[1].flags, data: tmp.data);
      expect(
        () => codec.reassemble(swapped),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejeita ausência do flag de último frame', () {
      final frames = codec.fragment(buildMessage(), mtu: 247);
      final altered = [
        for (var i = 0; i < frames.length - 1; i++)
          BleFrame(
            seq: frames[i].seq,
            flags: 0,
            data: frames[i].data,
          ),
        frames.last,
      ];
      expect(
        () => codec.reassemble(altered),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejeita JSON inválido mesmo com checksum correto', () {
      final message = 'nao e json\n';
      final frames = codec.fragment(message, mtu: 23);
      expect(
        () => codec.reassemble(frames),
        throwsA(isA<FormatException>()),
      );
    });

    test('frames vazios são rejeitados', () {
      expect(
        () => codec.reassemble(const []),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BleFrame', () {
    test('serializa e desserializa header de 2 bytes', () {
      final frame = BleFrame(seq: 7, flags: 1, data: [10, 20, 30]);
      final bytes = frame.toBytes();
      expect(bytes, [7, 1, 10, 20, 30]);
      final decoded = BleFrame.fromBytes(bytes);
      expect(decoded.seq, 7);
      expect(decoded.flags, 1);
      expect(decoded.data, [10, 20, 30]);
    });

    test('rejeita bytes menores que o header', () {
      expect(() => BleFrame.fromBytes([1]), throwsFormatException);
    });
  });
}
