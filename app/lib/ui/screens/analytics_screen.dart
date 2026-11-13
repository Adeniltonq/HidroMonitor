import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../services/analytics_calculator.dart';
import '../../services/device_repository.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  int _days = 7;
  Future<_AnalyticsData>? _future;
  bool _initialized = false;
  String? _deviceId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _load();
    }
  }

  void _load() {
    setState(() => _future = _fetch(_days));
  }

  Future<_AnalyticsData> _fetch(int days) async {
    final controller = context.read<HouseController>();
    final houseId = controller.selectedHouse?.id;
    final device = controller.selectedDevice;
    if (houseId == null || device == null) {
      throw const AppException('Selecione uma casa com dispositivo.');
    }
    _deviceId = device.id;

    final now = DateTime.now();
    final start = now.subtract(Duration(days: days));
    final previousStart = start.subtract(Duration(days: days));
    final repo = context.read<DeviceRepository>();

    final readingsResult = await repo.fetchReadingsRange(
      houseId: houseId,
      deviceId: device.id,
      from: previousStart,
      to: now,
    );
    final events = await repo.fetchEventsRange(
      houseId: houseId,
      deviceId: device.id,
      from: previousStart,
      to: now,
    );

    final snapshot = const AnalyticsCalculator().build(
      readings: readingsResult.readings,
      events: events,
      config: device.config,
      start: start,
      end: now,
      previousStart: previousStart,
      previousEnd: start,
      now: now,
    );

    return _AnalyticsData(
      snapshot: snapshot,
      truncated: readingsResult.truncated,
      readingCount: readingsResult.readings.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<HouseController>();
    final device = controller.selectedDevice;
    if (controller.selectedHouse == null) {
      return EmptyState(
        icon: Icons.home_work_outlined,
        title: 'Nenhuma casa selecionada',
        message: 'Selecione uma casa para ver a análise.',
        actionLabel: 'Gerenciar casas',
        onAction: () => context.go('/casas'),
      );
    }
    if (device == null) {
      return const EmptyState(
        icon: Icons.sensors_off_outlined,
        title: 'Sem dispositivo',
        message: 'Adicione um dispositivo para ver a análise de consumo.',
      );
    }

    if (_deviceId != device.id) {
      _deviceId = device.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    return FutureBuilder<_AnalyticsData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting ||
            _future == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: describeError(snapshot.error!),
            onRetry: _load,
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const EmptyState(
            icon: Icons.insights_outlined,
            title: 'Sem dados',
            message: 'Ainda não há leituras suficientes para a análise.',
          );
        }
        final s = data.snapshot;
        if (s.levelReadings.isEmpty) {
          return const EmptyState(
            icon: Icons.insights_outlined,
            title: 'Sem leituras no período',
            message: 'Assim que o dispositivo enviar leituras, a análise aparece aqui.',
          );
        }

        return RefreshIndicator(
          onRefresh: () async => _load(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('24 h')),
                  ButtonSegment(value: 7, label: Text('7 dias')),
                  ButtonSegment(value: 30, label: Text('30 dias')),
                ],
                selected: {_days},
                onSelectionChanged: (value) {
                  setState(() => _days = value.first);
                  _load();
                },
              ),
              const SizedBox(height: 12),
              if (data.truncated)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Muitas leituras no período: a análise usa as '
                    '${data.readingCount} mais recentes.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              _SummaryGrid(snapshot: s),
              const SizedBox(height: 12),
              _ForecastCard(snapshot: s, device: device),
              const SizedBox(height: 12),
              _DailyChartCard(snapshot: s),
              const SizedBox(height: 12),
              _HourlyChartCard(snapshot: s),
              const SizedBox(height: 12),
              _LevelChartCard(snapshot: s, tank: device.config.tank),
              const SizedBox(height: 12),
              _HeatmapCard(snapshot: s),
              const SizedBox(height: 12),
              _PatternsCard(snapshot: s),
              const SizedBox(height: 12),
              _NextDaysCard(snapshot: s),
              const SizedBox(height: 12),
              _AnomaliesCard(anomalies: s.anomalies),
              const SizedBox(height: 12),
              _SystemCard(snapshot: s),
              const SizedBox(height: 8),
              Text(
                'Análise baseada em ${s.daysWithData} dia(s) com leituras. '
                'Valores estimados a partir do nível e do volume calibrado.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}

class _AnalyticsData {
  const _AnalyticsData({
    required this.snapshot,
    required this.truncated,
    required this.readingCount,
  });

  final AnalyticsSnapshot snapshot;
  final bool truncated;
  final int readingCount;
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  String _percent() {
    final c = snapshot.comparisonPercent;
    if (c == null) return '—';
    final signal = c >= 0 ? '+' : '';
    return '$signal${c.toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final comparison = snapshot.comparisonPercent;
    final comparisonColor = comparison == null
        ? scheme.onSurfaceVariant
        : comparison > 0
            ? Colors.red.shade600
            : Colors.green.shade600;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.water_drop_outlined,
                label: 'Consumo no período',
                value: Fmt.liters(snapshot.totalLiters),
                caption: '${snapshot.daysWithData} dia(s) com dados',
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.trending_up,
                label: 'Média diária',
                value: Fmt.liters(snapshot.dailyAverage),
                caption: 'litros por dia',
                color: Colors.teal.shade600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.compare_arrows,
                label: 'Período anterior',
                value: _percent(),
                caption: Fmt.liters(snapshot.previousLiters),
                color: comparisonColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.arrow_downward,
                label: 'Maior / menor dia',
                value: snapshot.maxDay == null
                    ? '—'
                    : Fmt.liters(snapshot.maxDay!.liters),
                caption: snapshot.minDay == null
                    ? '—'
                    : 'mínimo ${Fmt.liters(snapshot.minDay!.liters)}',
                color: Colors.orange.shade700,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final String caption;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(caption, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

String _autonomy(double hours) {
  if (hours <= 0) return '—';
  if (hours >= 48) {
    return '${(hours / 24).floor()} d ${(hours % 24).round()} h';
  }
  return '${hours.round()} h';
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.snapshot, required this.device});

  final AnalyticsSnapshot snapshot;
  final Device device;

  @override
  Widget build(BuildContext context) {
    final f = snapshot.forecast;
    final current = snapshot.levelReadings.isEmpty
        ? null
        : snapshot.levelReadings.last;
    final currentVolume = current == null
        ? 0.0
        : device.config.tank.volumeForPercent(current.levelPercent);
    final scheme = Theme.of(context).colorScheme;

    return SectionCard(
      title: 'Previsão e autonomia',
      subtitle: 'Estimativa pela média dos últimos dias com leitura',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.battery_charging_full,
                  label: 'Autonomia estimada',
                  value: f.hasEstimate ? _autonomy(f.hoursToEmpty) : '—',
                  caption: f.hasEstimate ? 'até esvaziar' : 'sem consumo recente',
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  icon: Icons.event,
                  label: 'Previsão de vazio',
                  value: f.emptyAt == null ? '—' : Fmt.dateTime(f.emptyAt),
                  caption: f.hasEstimate
                      ? 'média ${Fmt.liters(f.averageDaily)}/dia'
                      : 'aguardando dados',
                  color: Colors.indigo.shade400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.water_drop_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Volume atual estimado',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Text(
                Fmt.liters(currentVolume),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarsChart extends StatelessWidget {
  const _BarsChart({
    required this.values,
    required this.labels,
    this.labelStep = 1,
    this.height = 180,
    this.color,
  });

  final List<double> values;
  final List<String> labels;
  final int labelStep;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('Sem dados no período')),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final barColor = color ?? scheme.primary;
    final maxValue = values.reduce(math.max);
    final maxY = maxValue <= 0 ? 10.0 : maxValue * 1.2;

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          minY: 0,
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxY / 3,
            getDrawingHorizontalLine: (_) => FlLine(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= labels.length) {
                    return const SizedBox.shrink();
                  }
                  if (index % labelStep != 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      labels[index],
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                  BarTooltipItem(
                '${rod.toY.toStringAsFixed(1)} L',
                TextStyle(color: scheme.onInverseSurface),
              ),
            ),
          ),
          barGroups: List.generate(values.length, (index) {
            return BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: values[index],
                  width: values.length > 20 ? 8 : 16,
                  borderRadius: BorderRadius.circular(4),
                  color: index == _maxIndex(values)
                      ? Colors.teal.shade600
                      : barColor,
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  int _maxIndex(List<double> list) {
    var index = 0;
    for (var i = 1; i < list.length; i++) {
      if (list[i] > list[index]) index = i;
    }
    return index;
  }
}

class _DailyChartCard extends StatelessWidget {
  const _DailyChartCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final daily = snapshot.daily;
    final labels = daily
        .map((d) => DateFormat('dd/MM', 'pt_BR').format(d.day))
        .toList();
    final values = daily.map((d) => d.liters).toList();
    final step = math.max(1, (daily.length / 6).ceil());
    return SectionCard(
      title: 'Consumo por dia',
      subtitle: 'Total em litros por dia (${snapshot.periodDays} dia(s))',
      child: _BarsChart(
        values: values,
        labels: labels,
        labelStep: step,
        height: 190,
      ),
    );
  }
}

class _HourlyChartCard extends StatelessWidget {
  const _HourlyChartCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final labels = List.generate(24, (h) => '${h}h');
    return SectionCard(
      title: 'Consumo por hora',
      subtitle: 'Média por hora do dia, considerando os dias com leitura',
      child: _BarsChart(
        values: snapshot.hourlyAverage,
        labels: labels,
        labelStep: 3,
        height: 180,
        color: Colors.cyan.shade600,
      ),
    );
  }
}

class _LevelChartCard extends StatefulWidget {
  const _LevelChartCard({required this.snapshot, required this.tank});

  final AnalyticsSnapshot snapshot;
  final TankConfig tank;

  @override
  State<_LevelChartCard> createState() => _LevelChartCardState();
}

class _LevelChartCardState extends State<_LevelChartCard> {
  bool _showLiters = false;

  @override
  Widget build(BuildContext context) {
    final readings = widget.snapshot.levelReadings;
    if (readings.isEmpty) {
      return const SectionCard(
        title: 'Evolução do nível',
        child: Text('Sem leituras no período.'),
      );
    }
    final start = readings.first.ts ?? DateTime.now();
    final step = math.max(1, (readings.length / 300).ceil());
    final spots = <FlSpot>[];
    for (var i = 0; i < readings.length; i += step) {
      final reading = readings[i];
      final ts = reading.ts;
      if (ts == null) continue;
      final x = ts.difference(start).inMinutes / 60.0;
      final y = _showLiters
          ? widget.tank.volumeForPercent(reading.levelPercent)
          : reading.levelPercent;
      spots.add(FlSpot(x, y));
    }
    final scheme = Theme.of(context).colorScheme;
    final maxX = spots.isEmpty ? 1.0 : math.max(1.0, spots.last.x);
    final maxY = _showLiters
        ? math.max(10.0, widget.tank.capacityL * 1.05)
        : 100.0;

    return SectionCard(
      title: 'Evolução do nível',
      subtitle: 'Nível (%) ou volume calibrado (L) ao longo do período',
      trailing: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('%')),
          ButtonSegment(value: true, label: Text('L')),
        ],
        selected: {_showLiters},
        onSelectionChanged: (value) {
          setState(() => _showLiters = value.first);
        },
      ),
      child: SizedBox(
        height: 200,
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX: maxX,
            minY: 0,
            maxY: maxY,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: maxY / 4,
              getDrawingHorizontalLine: (_) => FlLine(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
                strokeWidth: 1,
              ),
            ),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots
                    .map(
                      (spot) => LineTooltipItem(
                        _showLiters
                            ? '${spot.y.toStringAsFixed(0)} L'
                            : '${spot.y.toStringAsFixed(0)}%',
                        TextStyle(color: scheme.onInverseSurface),
                      ),
                    )
                    .toList(),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.15,
                barWidth: 2.5,
                color: scheme.primary,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: scheme.primary.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Mapa de calor',
      subtitle: 'Litros por dia da semana e hora (toque para detalhes)',
      child: _Heatmap(matrix: snapshot.heatmap),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.matrix});

  final List<List<double>> matrix;

  static const _weekdays = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var maxValue = 0.0;
    for (final row in matrix) {
      for (final value in row) {
        if (value > maxValue) maxValue = value;
      }
    }
    if (maxValue <= 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Ainda não há consumo suficiente para o mapa de calor.'),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidth = 32.0;
        final cellWidth = (constraints.maxWidth - labelWidth) / 24;
        return Column(
          children: [
            for (var weekday = 0; weekday < 7; weekday++)
              Row(
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      _weekdays[weekday],
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (var hour = 0; hour < 24; hour++)
                    GestureDetector(
                      onTap: () => _showCell(context, weekday, hour),
                      child: Container(
                        width: cellWidth,
                        height: 22,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(
                            alpha: 0.08 +
                                0.8 *
                                    (matrix[weekday][hour] / maxValue)
                                        .clamp(0.0, 1.0),
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 32),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('00h', style: TextStyle(fontSize: 9)),
                      Text('06h', style: TextStyle(fontSize: 9)),
                      Text('12h', style: TextStyle(fontSize: 9)),
                      Text('18h', style: TextStyle(fontSize: 9)),
                      Text('23h', style: TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _showCell(BuildContext context, int weekday, int hour) {
    final value = matrix[weekday][hour];
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${_weekdays[weekday]} · ${hour.toString().padLeft(2, '0')}h'),
        content: Text(
          'Consumo médio: ${Fmt.liters(value)}\n'
          'Média calculada sobre os dias com leitura nesse horário.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}

class _PatternsCard extends StatelessWidget {
  const _PatternsCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final topHours = [...snapshot.hourlyAverage.asMap().entries]
      ..sort((a, b) => b.value.compareTo(a.value));
    final hours = topHours
        .where((entry) => entry.value > 0)
        .take(3)
        .map((entry) => '${entry.key.toString().padLeft(2, '0')}h')
        .join(', ');

    return SectionCard(
      title: 'Padrões de consumo',
      child: Column(
        children: [
          InfoTile(
            label: 'Horário de pico',
            value: snapshot.peakHourLabel ?? '—',
            icon: Icons.schedule,
          ),
          InfoTile(
            label: 'Dia da semana de maior consumo',
            value: snapshot.peakWeekdayLabel ?? '—',
            icon: Icons.calendar_today_outlined,
          ),
          InfoTile(
            label: 'Horários com mais consumo',
            value: hours.isEmpty ? '—' : hours,
            icon: Icons.bar_chart,
          ),
          if (snapshot.peakHourLabel != null && snapshot.peakWeekdayLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Padrão recorrente: pico por volta de ${snapshot.peakHourLabel}. '
                'O dia de maior consumo é ${snapshot.peakWeekdayLabel}.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _NextDaysCard extends StatelessWidget {
  const _NextDaysCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final next = snapshot.forecast.nextDays;
    if (!snapshot.forecast.hasEstimate) {
      return const SectionCard(
        title: 'Próximos 7 dias',
        child: Text(
          'Ainda não há consumo recente suficiente para projetar os próximos dias.',
        ),
      );
    }
    final labels = next
        .map((d) => DateFormat('EEE', 'pt_BR').format(d.day))
        .toList();
    return SectionCard(
      title: 'Próximos 7 dias',
      subtitle:
          'Projeção pela média recente (${Fmt.liters(snapshot.forecast.averageDaily)}/dia)',
      child: _BarsChart(
        values: next.map((d) => d.liters).toList(),
        labels: labels,
        height: 170,
        color: Colors.indigo.shade400,
      ),
    );
  }
}

class _AnomaliesCard extends StatelessWidget {
  const _AnomaliesCard({required this.anomalies});

  final List<ConsumptionAnomaly> anomalies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Anomalias',
      subtitle: 'Consumo fora do padrão, vazamentos e madrugada',
      child: anomalies.isEmpty
          ? Row(
              children: [
                Icon(Icons.check_circle_outline, color: Colors.green.shade600),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Nenhuma anomalia detectada no período.'),
                ),
              ],
            )
          : Column(
              children: [
                for (final anomaly in anomalies)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          switch (anomaly.level) {
                            AnomalyLevel.crit => Icons.dangerous_outlined,
                            AnomalyLevel.warn => Icons.warning_amber,
                            AnomalyLevel.info => Icons.info_outline,
                          },
                          size: 20,
                          color: switch (anomaly.level) {
                            AnomalyLevel.crit => scheme.error,
                            AnomalyLevel.warn => Colors.amber.shade700,
                            AnomalyLevel.info => scheme.primary,
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                anomaly.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                anomaly.description,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SystemCard extends StatelessWidget {
  const _SystemCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final pump = snapshot.pump;
    return SectionCard(
      title: 'Funcionamento do sistema',
      subtitle: 'Operação da bomba no período',
      child: Column(
        children: [
          InfoTile(
            label: 'Acionamentos da bomba',
            value: pump.activations.toString(),
            icon: Icons.play_circle_outline,
          ),
          InfoTile(
            label: 'Tempo total de funcionamento',
            value: Fmt.duration(pump.totalRuntime),
            icon: Icons.timer_outlined,
          ),
          InfoTile(
            label: 'Ciclos de abastecimento',
            value: pump.fillCycles.toString(),
            icon: Icons.loop,
          ),
          InfoTile(
            label: 'Duração média',
            value: pump.fillCycles == 0
                ? '—'
                : Fmt.duration(pump.averageDuration),
            icon: Icons.timelapse,
          ),
          InfoTile(
            label: 'Velocidade de esvaziamento',
            value: snapshot.drainLitersPerHour > 0
                ? Fmt.decimals(snapshot.drainLitersPerHour, suffix: ' L/h')
                : '—',
            icon: Icons.arrow_downward,
          ),
          InfoTile(
            label: 'Velocidade de enchimento',
            value: snapshot.fillLitersPerHour > 0
                ? Fmt.decimals(snapshot.fillLitersPerHour, suffix: ' L/h')
                : '—',
            icon: Icons.arrow_upward,
          ),
          InfoTile(
            label: 'Reinícios do sistema',
            value: snapshot.boots.toString(),
            icon: Icons.restart_alt,
          ),
        ],
      ),
    );
  }
}
