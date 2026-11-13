import 'dart:convert';
import 'dart:math' as math;

/// Frame do enquadramento BLE (camada de transporte, não de aplicação).
///
/// Layout no ar: `[seq:1][flags:1][payload:(MTU-5)]`.
/// O ATT Write Request gasta 3 bytes (opcode + handle) e o frame gasta mais 2
/// (seq + flags), então o payload útil é `MTU - 5`.
/// flags:
///   bit 0 (0x01) — último frame de dados da mensagem;
///   bit 1 (0x02) — frame de checksum (payload = CRC16 big-endian, 2 bytes);
///   bit 2 (0x04) — pedido de handshake (payload vazio; o device responde
///                  com `hello` imediatamente).
class BleFrame {
  const BleFrame({
    required this.seq,
    required this.flags,
    required this.data,
  });

  final int seq;
  final int flags;
  final List<int> data;

  bool get isLast => (flags & BleProvisioningCodec.flagLast) != 0;
  bool get isChecksum => (flags & BleProvisioningCodec.flagChecksum) != 0;

  List<int> toBytes() => [seq, flags, ...data];

  static BleFrame fromBytes(List<int> bytes) {
    if (bytes.length < 2) {
      throw const FormatException('Frame BLE truncado (sem header).');
    }
    return BleFrame(
      seq: bytes[0],
      flags: bytes[1],
      data: bytes.sublist(2),
    );
  }
}

/// Codec puro (sem dependência de Flutter/BLE) do protocolo de provisioning.
///
/// Responsabilidades:
///  - fragmentar a mensagem JSON (UTF-8, terminada em '\n') em frames;
///  - remontar frames validando sequência, último frame e checksum;
///  - validar o JSON e calcular CRC16-CCITT do payload.
///
/// A classe é testada sem hardware em `test/ble_provisioning_codec_test.dart`.
class BleProvisioningCodec {
  const BleProvisioningCodec();

  static const int flagLast = 0x01;
  static const int flagChecksum = 0x02;
  static const int flagHelloRequest = 0x04;
  static const int headerSize = 2;

  /// Limite defensivo para não aceitar mensagens absurdas do periférico.
  static const int maxMessageBytes = 8192;

  /// Tamanho do chunk de DADOS para um MTU negociado.
  ///
  /// O ATT Write Request usa 3 bytes (opcode + handle) e o frame usa mais 2
  /// bytes (seq + flags). Portanto: `MTU - 3 - headerSize` = `MTU - 5`.
  /// Antes era `MTU - 3`, e o frame resultante ficava 2 bytes maior que o
  /// permitido pelo Android — o `writeCharacteristic` falhava e o app mostrava
  /// `chunk_failed`.
  static int chunkSizeForMtu(int mtu) => math.max(1, mtu - 3 - headerSize);

  /// CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF), retorna 16 bits.
  static int checksum(List<int> bytes) {
    var crc = 0xFFFF;
    for (final byte in bytes) {
      crc ^= (byte & 0xFF) << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc & 0xFFFF;
  }

  /// Fragmenta [message] (JSON já serializado, terminado em '\n').
  ///
  /// Retorna os frames de dados seguidos de um frame de checksum.
  List<BleFrame> fragment(String message, {required int mtu}) {
    if (message.isEmpty) {
      throw ArgumentError('Mensagem de provisioning vazia.');
    }
    if (!message.endsWith('\n')) {
      throw ArgumentError("A mensagem deve terminar com '\\n'.");
    }
    final bytes = utf8.encode(message);
    if (bytes.length > maxMessageBytes) {
      throw ArgumentError(
        'Mensagem de provisioning excede $maxMessageBytes bytes.',
      );
    }

    final chunkSize = chunkSizeForMtu(mtu);
    final frames = <BleFrame>[];
    var seq = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, bytes.length);
      final isLast = end >= bytes.length;
      frames.add(
        BleFrame(
          seq: seq,
          flags: isLast ? flagLast : 0,
          data: bytes.sublist(offset, end),
        ),
      );
      seq = (seq + 1) & 0xFF;
    }

    final crc = checksum(bytes);
    frames.add(
      BleFrame(
        seq: seq,
        flags: flagChecksum,
        data: [crc >> 8, crc & 0xFF],
      ),
    );
    return frames;
  }

  /// Remonta e valida a mensagem a partir dos frames recebidos.
  String reassemble(List<BleFrame> frames) {
    if (frames.isEmpty) {
      throw const FormatException('Nenhum frame recebido.');
    }
    if (!frames.last.isChecksum) {
      throw const FormatException('Frame de checksum ausente.');
    }

    final dataFrames = frames.sublist(0, frames.length - 1);
    final checksumFrame = frames.last;
    if (checksumFrame.data.length != 2) {
      throw const FormatException('Frame de checksum inválido.');
    }

    final buffer = <int>[];
    var expectedSeq = frames.first.seq;
    var sawLast = false;

    for (var i = 0; i < dataFrames.length; i++) {
      final frame = dataFrames[i];
      if (frame.isChecksum) {
        throw const FormatException('Checksum no meio da mensagem.');
      }
      if (frame.seq != (expectedSeq & 0xFF)) {
        throw FormatException(
          'Sequência fora de ordem (esperado ${expectedSeq & 0xFF}, '
          'recebido ${frame.seq}).',
        );
      }
      if (sawLast) {
        throw const FormatException('Dados após o último frame.');
      }
      buffer.addAll(frame.data);
      if (buffer.length > maxMessageBytes) {
        throw const FormatException('Mensagem maior que o limite permitido.');
      }
      if (frame.isLast) sawLast = true;
      expectedSeq = (expectedSeq + 1) & 0xFF;
    }

    if (!sawLast) {
      throw const FormatException('Último frame de dados não recebido.');
    }
    if (checksumFrame.seq != (expectedSeq & 0xFF)) {
      throw FormatException(
        'Sequência do checksum incorreta (esperado ${expectedSeq & 0xFF}).',
      );
    }

    final expectedCrc = (checksumFrame.data[0] << 8) | checksumFrame.data[1];
    final actualCrc = checksum(buffer);
    if (expectedCrc != actualCrc) {
      throw const FormatException('Checksum não confere (payload corrompido).');
    }

    late final String message;
    try {
      message = utf8.decode(buffer);
    } on FormatException {
      throw const FormatException('Payload não é UTF-8 válido.');
    }

    if (!message.endsWith('\n')) {
      throw const FormatException("Mensagem sem delimitador final '\\n'.");
    }

    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('JSON de provisioning deve ser um objeto.');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('JSON de provisioning inválido.');
    }

    return message;
  }
}
