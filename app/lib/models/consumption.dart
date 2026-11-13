import 'reading.dart';

/// Consumo estimado a partir das quedas de volume entre leituras consecutivas.
///
/// Regras (definidas no contrato):
///  - soma apenas quedas (delta < 0);
///  - ignora leituras com `sensorOk == false`;
///  - ignora o trecho quando a bomba estava ligada (reposição);
///  - ignora lacunas maiores que 5x o intervalo de publicação configurado.
class ConsumptionCalculator {
  const ConsumptionCalculator({
    required this.reportIntervalSec,
    this.volumeForPercent,
  });

  final int reportIntervalSec;

  /// Resolve litros a partir do nível (%). Quando informado, usa a tabela
  /// manual de calibração da caixa; caso contrário usa o volumeL da leitura.
  final double Function(double percent)? volumeForPercent;

  double _volume(Reading reading) =>
      volumeForPercent?.call(reading.levelPercent) ?? reading.volumeL;

  /// Limite de lacuna aceitável entre duas leituras consecutivas.
  Duration get maxGap => Duration(seconds: reportIntervalSec * 5);

  /// Mapa dia (00:00 local) -> litros consumidos.
  Map<DateTime, double> byDay(List<Reading> readings) {
    final sorted = [...readings]..sort((a, b) {
        final at = a.ts;
        final bt = b.ts;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });

    final result = <DateTime, double>{};
    for (var i = 1; i < sorted.length; i++) {
      final previous = sorted[i - 1];
      final current = sorted[i];

      if (!previous.sensorOk || !current.sensorOk) continue;
      if (previous.pumpOn || current.pumpOn) continue;

      final previousTs = previous.ts;
      final currentTs = current.ts;
      if (previousTs == null || currentTs == null) continue;
      if (currentTs.difference(previousTs) > maxGap) continue;

      final delta = _volume(previous) - _volume(current);
      if (delta <= 0) continue;

      final day = DateTime(currentTs.year, currentTs.month, currentTs.day);
      result[day] = (result[day] ?? 0) + delta;
    }
    return result;
  }

  /// Soma do período informado (inclusive).
  double totalBetween(
    Map<DateTime, double> byDay,
    DateTime start,
    DateTime end,
  ) {
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    var total = 0.0;
    byDay.forEach((day, liters) {
      if (!day.isBefore(startDay) && !day.isAfter(endDay)) total += liters;
    });
    return total;
  }

  List<DailyConsumption> series(Map<DateTime, double> byDay, int days,
      {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    return List.generate(days, (index) {
      final day = today.subtract(Duration(days: days - 1 - index));
      return DailyConsumption(day: day, liters: byDay[day] ?? 0);
    });
  }
}

class DailyConsumption {
  const DailyConsumption({required this.day, required this.liters});

  final DateTime day;
  final double liters;
}
