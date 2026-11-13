import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/reading.dart';

/// Exportação CSV do histórico. Separador ';' e decimais com vírgula para
/// abrir corretamente no Excel/LibreOffice em pt-BR.
class CsvExporter {
  CsvExporter._();

  static final DateFormat _dateTime = DateFormat('yyyy-MM-dd HH:mm:ss', 'pt_BR');

  static String buildCsv(List<Reading> readings) {
    final buffer = StringBuffer()
      ..writeln(
        'data_hora;distancia_cm;nivel_percent;nivel_cm;volume_l;'
        'bomba;valvula;sensor_ok;rssi_dbm',
      );
    for (final reading in readings) {
      final ts = reading.ts;
      buffer.writeln([
        ts == null ? '' : _dateTime.format(ts),
        _number(reading.distanceCm),
        _number(reading.levelPercent),
        _number(reading.levelCm),
        _number(reading.volumeL),
        reading.pumpOn ? 'ligada' : 'desligada',
        reading.valveOpen ? 'aberta' : 'fechada',
        reading.sensorOk ? 'ok' : 'falha',
        reading.rssi.toString(),
      ].join(';'));
    }
    return buffer.toString();
  }

  static String _number(double value) =>
      value.toStringAsFixed(1).replaceAll('.', ',');

  /// Compartilha o CSV pelo share sheet do Android.
  static Future<void> shareReadings({
    required List<Reading> readings,
    required String houseName,
  }) async {
    final csv = buildCsv(readings);
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(csv)),
      mimeType: 'text/csv',
      name: 'hidromonitor_$stamp.csv',
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [file],
        subject: 'Histórico HidroMonitor — $houseName',
        text: 'Histórico de leituras exportado pelo HidroMonitor.',
      ),
    );
  }
}
