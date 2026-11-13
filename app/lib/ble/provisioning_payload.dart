import 'dart:convert';
import 'dart:typed_data';

/// Payload enviado ao ESP32 durante o pareamento.
///
/// SEGURANÇA: ssid, senha do Wi-Fi e senha do usuário Firebase do device
/// existem apenas em memória durante a janela de pareamento. Nunca são
/// gravados no Firestore, em logs ou em relatórios de crash.
class ProvisioningPayload {
  ProvisioningPayload({
    required this.provId,
    required this.ssid,
    required this.wifiPassword,
    required this.fbEmail,
    required this.fbPassword,
    required this.houseId,
    required this.deviceId,
    required this.serial,
  });

  final String provId;
  final String ssid;
  final String wifiPassword;
  final String fbEmail;
  final String fbPassword;
  final String houseId;
  final String deviceId;
  final String serial;

  Uint8List? _encoded;

  Map<String, dynamic> toJson() => {
        'op': 'prov',
        'provId': provId,
        'ssid': ssid,
        'pass': wifiPassword,
        'fbEmail': fbEmail,
        'fbPass': fbPassword,
        'houseId': houseId,
        'deviceId': deviceId,
        'serial': serial,
      };

  /// Mensagem pronta para o codec: JSON compacto + '\n'.
  String toMessage() => '${jsonEncode(toJson())}\n';

  /// Bytes UTF-8 da mensagem. Mantidos para o codec e apagados em [wipe].
  Uint8List encode() {
    final bytes = Uint8List.fromList(utf8.encode(toMessage()));
    _encoded = bytes;
    return bytes;
  }

  /// Zera os bytes em memória após o envio (best effort: Strings em Dart são
  /// imutáveis, por isso não guardamos cópias adicionais).
  void wipe() {
    final bytes = _encoded;
    if (bytes != null) {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = 0;
      }
      _encoded = null;
    }
  }

  /// Representação segura para diagnóstico — nunca inclui segredos.
  String redactedSummary() =>
      'provId=$provId device=$deviceId house=$houseId ssid=${_mask(ssid)}';

  static String _mask(String value) {
    if (value.isEmpty) return '';
    if (value.length <= 2) return '**';
    return '${value[0]}***${value[value.length - 1]}';
  }

  @override
  String toString() => redactedSummary();
}
