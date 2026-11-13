import 'dart:math' as math;

import '../models/device.dart';
import '../models/reading.dart';

enum AnomalyLevel { info, warn, crit }

class ConsumptionAnomaly {
  const ConsumptionAnomaly({
    required this.level,
    required this.title,
    required this.description,
    this.when,
  });

  final AnomalyLevel level;
  final String title;
  final String description;
  final DateTime? when;
}

class AnalyticsDay {
  const AnalyticsDay({
    required this.day,
    required this.liters,
    required this.hasData,
  });

  final DateTime day;
  final double liters;
  final bool hasData;
}

class PumpOperationStats {
  const PumpOperationStats({
    required this.activations,
    required this.totalRuntime,
    required this.fillCycles,
    required this.averageDuration,
  });

  final int activations;
  final Duration totalRuntime;
  final int fillCycles;
  final Duration averageDuration;
}

class ConsumptionForecast {
  const ConsumptionForecast({
    required this.averageDaily,
    required this.hoursToEmpty,
    required this.emptyAt,
    required this.nextDays,
    required this.hasEstimate,
  });

  final double averageDaily;
  final double hoursToEmpty;
  final DateTime? emptyAt;
  final List<AnalyticsDay> nextDays;
  final bool hasEstimate;
}

class AnalyticsSnapshot {
  const AnalyticsSnapshot({
    required this.start,
    required this.end,
    required this.periodDays,
    required this.totalLiters,
    required this.previousLiters,
    required this.comparisonPercent,
    required this.dailyAverage,
    required this.daily,
    required this.hourlyAverage,
    required this.heatmap,
    required this.daysWithData,
    required this.maxDay,
    required this.minDay,
    required this.peakHourLabel,
    required this.peakWeekdayLabel,
    required this.levelReadings,
    required this.drainLitersPerHour,
    required this.fillLitersPerHour,
    required this.forecast,
    required this.anomalies,
    required this.pump,
    required this.boots,
  });

  final DateTime start;
  final DateTime end;
  final int periodDays;
  final double totalLiters;
  final double previousLiters;
  final double? comparisonPercent;
  final double dailyAverage;
  final List<AnalyticsDay> daily;
  final List<double> hourlyAverage;
  final List<List<double>> heatmap;
  final int daysWithData;
  final AnalyticsDay? maxDay;
  final AnalyticsDay? minDay;
  final String? peakHourLabel;
  final String? peakWeekdayLabel;
  final List<Reading> levelReadings;
  final double drainLitersPerHour;
  final double fillLitersPerHour;
  final ConsumptionForecast forecast;
  final List<ConsumptionAnomaly> anomalies;
  final PumpOperationStats pump;
  final int boots;
}

class AnalyticsCalculator {
  const AnalyticsCalculator();

  AnalyticsSnapshot build({
    required List<Reading> readings,
    required List<DeviceEvent> events,
    required DeviceConfig config,
    required DateTime start,
    required DateTime end,
    required DateTime previousStart,
    required DateTime previousEnd,
    required DateTime now,
  }) {
    final sorted = [...readings]
      ..sort((a, b) => (a.ts ?? now).compareTo(b.ts ?? now));
    final tank = config.tank;
    double volumeOf(Reading r) => tank.volumeForPercent(r.levelPercent);

    final periodReadings = <Reading>[];
    final daysWithData = <DateTime>{};
    final daily = <DateTime, double>{};
    final hourly = List<double>.filled(24, 0);
    final heat = List.generate(7, (_) => List<double>.filled(24, 0));
    final night = <DateTime, double>{};

    bool qualifies(Reading previous, Reading current) {
      if (!previous.sensorOk || !current.sensorOk) return false;
      if (previous.pumpOn || current.pumpOn) return false;
      final a = previous.ts;
      final b = current.ts;
      if (a == null || b == null) return false;
      final gap = b.difference(a);
      if (gap > Duration(seconds: config.reportIntervalSec * 5)) return false;
      return b.isAfter(a);
    }

    double previousTotal = 0;
    for (final reading in sorted) {
      final ts = reading.ts;
      if (ts == null) continue;
      if (!ts.isBefore(start) && !ts.isAfter(end)) {
        periodReadings.add(reading);
        daysWithData.add(_day(ts));
      }
    }

    for (var i = 1; i < sorted.length; i++) {
      final previous = sorted[i - 1];
      final current = sorted[i];
      final ts = current.ts;
      final previousTs = previous.ts;
      if (ts == null || previousTs == null) continue;

      final delta = volumeOf(previous) - volumeOf(current);
      final gapHours = ts.difference(previousTs).inSeconds / 3600.0;
      if (gapHours <= 0 || gapHours > config.reportIntervalSec * 5 / 3600.0) {
        continue;
      }

      if (qualifies(previous, current) && delta > 0) {
        if (!ts.isBefore(start) && !ts.isAfter(end)) {
          final day = _day(ts);
          daily[day] = (daily[day] ?? 0) + delta;
          hourly[ts.hour] += delta;
          heat[ts.weekday - 1][ts.hour] += delta;
          if (ts.hour <= 4) {
            night[day] = (night[day] ?? 0) + delta;
          }
        } else if (!ts.isBefore(previousStart) && ts.isBefore(previousEnd)) {
          previousTotal += delta;
        }
      }
    }

    final dailyList = <AnalyticsDay>[];
    var cursor = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    while (!cursor.isAfter(endDay)) {
      dailyList.add(
        AnalyticsDay(
          day: cursor,
          liters: daily[cursor] ?? 0,
          hasData: daysWithData.contains(cursor),
        ),
      );
      cursor = cursor.add(const Duration(days: 1));
    }

    final dataDays = dailyList.where((d) => d.hasData).toList();
    final total = daily.values.fold<double>(0, (a, b) => a + b);
    final average = dataDays.isEmpty ? 0.0 : total / dataDays.length;

    AnalyticsDay? maxDay;
    AnalyticsDay? minDay;
    for (final day in dataDays) {
      if (maxDay == null || day.liters > maxDay.liters) maxDay = day;
      if (minDay == null || day.liters < minDay.liters) minDay = day;
    }

    final weekdayDays = <int, int>{};
    for (final day in daysWithData) {
      weekdayDays[day.weekday] = (weekdayDays[day.weekday] ?? 0) + 1;
    }
    final heatmap = List.generate(7, (weekday) {
      final count = weekdayDays[weekday + 1] ?? 0;
      return List.generate(24, (hour) {
        if (count == 0) return 0.0;
        return heat[weekday][hour] / count;
      });
    });

    final hourlyAverage = dataDays.isEmpty
        ? List<double>.filled(24, 0)
        : hourly.map((value) => value / dataDays.length).toList();

    var peakHour = 0;
    for (var h = 1; h < 24; h++) {
      if (hourlyAverage[h] > hourlyAverage[peakHour]) peakHour = h;
    }
    final hasConsumption = total > 0.001;
    final peakHourLabel =
        hasConsumption ? '${peakHour.toString().padLeft(2, '0')}h–${(peakHour + 1).toString().padLeft(2, '0')}h' : null;

    var peakWeekday = 0;
    final weekdayTotals = List<double>.filled(7, 0);
    for (var w = 0; w < 7; w++) {
      final count = weekdayDays[w + 1] ?? 0;
      if (count == 0) continue;
      weekdayTotals[w] = heatmap[w].fold<double>(0, (a, b) => a + b);
    }
    for (var w = 1; w < 7; w++) {
      if (weekdayTotals[w] > weekdayTotals[peakWeekday]) peakWeekday = w;
    }
    const weekdayNames = [
      'segunda',
      'terça',
      'quarta',
      'quinta',
      'sexta',
      'sábado',
      'domingo',
    ];
    final peakWeekdayLabel = hasConsumption ? weekdayNames[peakWeekday] : null;

    // Velocidades médias (L/h) com base nas variações válidas.
    var drainLiters = 0.0;
    var drainHours = 0.0;
    var fillLiters = 0.0;
    var fillHours = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      final previous = sorted[i - 1];
      final current = sorted[i];
      final ts = current.ts;
      final previousTs = previous.ts;
      if (ts == null || previousTs == null) continue;
      if (ts.isBefore(start) || ts.isAfter(end)) continue;
      if (!previous.sensorOk || !current.sensorOk) continue;
      final gapHours = ts.difference(previousTs).inSeconds / 3600.0;
      if (gapHours <= 0 || gapHours > config.reportIntervalSec * 5 / 3600.0) {
        continue;
      }
      final delta = volumeOf(current) - volumeOf(previous);
      if (current.pumpOn && delta > 0) {
        fillLiters += delta;
        fillHours += gapHours;
      } else if (!previous.pumpOn && !current.pumpOn && delta < 0) {
        drainLiters += -delta;
        drainHours += gapHours;
      }
    }

    // Operação da bomba a partir das transições das leituras.
    var pumpActivations = 0;
    var cycles = 0;
    var runtimeSeconds = 0;
    DateTime? pumpStarted;
    for (final reading in periodReadings) {
      final ts = reading.ts;
      if (ts == null) continue;
      if (reading.pumpOn && pumpStarted == null) {
        pumpStarted = ts;
        pumpActivations++;
      } else if (!reading.pumpOn && pumpStarted != null) {
        runtimeSeconds += ts.difference(pumpStarted).inSeconds;
        cycles++;
        pumpStarted = null;
      }
    }
    if (pumpStarted != null && periodReadings.isNotEmpty) {
      final last = periodReadings.last.ts;
      if (last != null) {
        runtimeSeconds += last.difference(pumpStarted).inSeconds;
        cycles++;
      }
    }

    // Previsão: média dos últimos 3 dias com dados.
    final recent = dataDays.length <= 3
        ? dataDays
        : dataDays.sublist(dataDays.length - 3);
    final recentAverage = recent.isEmpty
        ? 0.0
        : recent.fold<double>(0, (a, b) => a + b.liters) / recent.length;
    final currentReading = periodReadings.isNotEmpty
        ? periodReadings.last
        : (sorted.isNotEmpty ? sorted.last : null);
    final currentVolume =
        currentReading == null ? 0.0 : tank.volumeForPercent(currentReading.levelPercent);
    final hasEstimate = recentAverage > 0.001 && currentVolume > 0;
    final hoursToEmpty =
        hasEstimate ? (currentVolume / (recentAverage / 24.0)) : 0.0;
    final emptyAt = hasEstimate
        ? now.add(Duration(minutes: (hoursToEmpty * 60).round()))
        : null;
    final nextDays = <AnalyticsDay>[];
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 1; i <= 7; i++) {
      nextDays.add(
        AnalyticsDay(
          day: today.add(Duration(days: i)),
          liters: recentAverage,
          hasData: false,
        ),
      );
    }
    final forecast = ConsumptionForecast(
      averageDaily: recentAverage,
      hoursToEmpty: hoursToEmpty,
      emptyAt: emptyAt,
      nextDays: nextDays,
      hasEstimate: hasEstimate,
    );

    // Anomalias.
    final anomalies = <ConsumptionAnomaly>[];
    if (dataDays.length >= 3 && average > 0) {
      final mean = average;
      final variance = dataDays
              .map((d) => math.pow(d.liters - mean, 2).toDouble())
              .fold<double>(0, (a, b) => a + b) /
          dataDays.length;
      final std = math.sqrt(variance);
      for (final day in dataDays) {
        if (day.liters > mean + 2 * std && day.liters > mean * 1.3) {
          anomalies.add(
            ConsumptionAnomaly(
              level: AnomalyLevel.warn,
              title: 'Consumo fora do padrão',
              description:
                  '${day.liters.toStringAsFixed(0)} L em ${_date(day.day)} — '
                  'bem acima da média de ${mean.toStringAsFixed(0)} L.',
              when: day.day,
            ),
          );
        } else if (mean > 10 && day.liters < mean * 0.2) {
          anomalies.add(
            ConsumptionAnomaly(
              level: AnomalyLevel.info,
              title: 'Consumo muito baixo',
              description:
                  'Apenas ${day.liters.toStringAsFixed(0)} L em ${_date(day.day)}. '
                  'Pode ser ausência de uso ou falha de leitura.',
              when: day.day,
            ),
          );
        }
      }
    }

    var suspiciousNights = 0;
    night.forEach((day, liters) {
      final dayTotal = daily[day] ?? 0;
      if (_isSuspiciousNight(liters, dayTotal)) {
        suspiciousNights++;
        anomalies.add(
          ConsumptionAnomaly(
            level: AnomalyLevel.warn,
            title: 'Consumo na madrugada',
            description:
                '${liters.toStringAsFixed(1)} L entre 00h e 05h em ${_date(day)} '
                '(sem bomba ligada).',
            when: day,
          ),
        );
      }
    });
    if (suspiciousNights >= 3) {
      anomalies.add(
        ConsumptionAnomaly(
          level: AnomalyLevel.crit,
          title: 'Possível vazamento',
          description:
              'Consumo noturno recorrente em $suspiciousNights dias. '
              'Verifique vasos sanitários, torneiras e conexões.',
        ),
      );
    }

    anomalies.sort((a, b) => a.level.index.compareTo(b.level.index));

    final boots = events
        .where((e) => e.type == DeviceEventType.boot)
        .where((e) => e.ts != null && !e.ts!.isBefore(start) && !e.ts!.isAfter(end))
        .length;

    return AnalyticsSnapshot(
      start: start,
      end: end,
      periodDays: end.difference(start).inDays,
      totalLiters: total,
      previousLiters: previousTotal,
      comparisonPercent:
          previousTotal > 0.001 ? (total - previousTotal) / previousTotal * 100 : null,
      dailyAverage: average,
      daily: dailyList,
      hourlyAverage: hourlyAverage,
      heatmap: heatmap,
      daysWithData: dataDays.length,
      maxDay: maxDay,
      minDay: minDay,
      peakHourLabel: peakHourLabel,
      peakWeekdayLabel: peakWeekdayLabel,
      levelReadings: periodReadings,
      drainLitersPerHour:
          drainHours > 0 ? drainLiters / drainHours : 0,
      fillLitersPerHour: fillHours > 0 ? fillLiters / fillHours : 0,
      forecast: forecast,
      anomalies: anomalies,
      pump: PumpOperationStats(
        activations: pumpActivations,
        totalRuntime: Duration(seconds: runtimeSeconds),
        fillCycles: cycles,
        averageDuration:
            cycles > 0 ? Duration(seconds: runtimeSeconds ~/ cycles) : Duration.zero,
      ),
      boots: boots,
    );
  }

  bool _isSuspiciousNight(double night, double dayTotal) {
    return night >= 8 && dayTotal >= 20 && (night / dayTotal) >= 0.25;
  }

  DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);

  String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}';
}
