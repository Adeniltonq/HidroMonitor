import 'package:flutter_test/flutter_test.dart';
import 'package:hidromonitor/models/reading.dart';
import 'package:hidromonitor/services/csv_exporter.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('pt_BR');
  });

  test('CSV tem cabeçalho pt-BR e separador ponto e vírgula', () {
    final csv = CsvExporter.buildCsv([
      Reading(
        id: 'r1',
        distanceCm: 42.5,
        levelPercent: 62.3,
        levelCm: 80,
        volumeL: 623.4,
        pumpOn: false,
        valveOpen: true,
        sensorOk: true,
        rssi: -61,
        ts: DateTime(2026, 10, 24, 9, 30),
      ),
    ]);
    final lines = csv.trim().split('\n');
    expect(
      lines.first,
      'data_hora;distancia_cm;nivel_percent;nivel_cm;volume_l;'
      'bomba;valvula;sensor_ok;rssi_dbm',
    );
    expect(lines[1], startsWith('2026-10-24 09:30:00;42,5;62,3;80,0;623,4;'));
    expect(lines[1], contains('desligada;aberta;ok;-61'));
  });

  test('CSV vazio ainda contém apenas o cabeçalho', () {
    final csv = CsvExporter.buildCsv(const []);
    expect(csv.trim().split('\n').length, 1);
  });
}
