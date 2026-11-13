import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/consumption.dart';
import '../../models/device.dart';
import '../../models/reading.dart';
import '../../services/device_repository.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';
import '../widgets/sparkline.dart';

class ConsumptionScreen extends StatefulWidget {
  const ConsumptionScreen({super.key});

  @override
  State<ConsumptionScreen> createState() => _ConsumptionScreenState();
}

class _ConsumptionScreenState extends State<ConsumptionScreen> {
  Future<_ConsumptionData>? _future;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  void _load() {
    setState(() => _future = _fetch());
  }

  Future<_ConsumptionData> _fetch() async {
    final controller = context.read<HouseController>();
    final houseId = controller.selectedHouse?.id;
    final device = controller.selectedDevice;
    if (houseId == null || device == null) {
      throw const AppException('Selecione uma casa com dispositivo.');
    }
    final readings = await context.read<DeviceRepository>().fetchReadingsForConsumption(
          houseId: houseId,
          deviceId: device.id,
          days: 7,
        );
    final calculator = ConsumptionCalculator(
      reportIntervalSec: device.config.reportIntervalSec,
      volumeForPercent: device.config.tank.volumeForPercent,
    );
    return _ConsumptionData(
      device: device,
      readings: readings,
      byDay: calculator.byDay(readings),
      calculator: calculator,
    );
  }

  @override
  Widget build(BuildContext context) {
    return HouseRequired(
      builder: (context) => FutureBuilder<_ConsumptionData>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
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
                  message: 'Não foi possível carregar o consumo.',
                );
              }
              final today = DateTime.now();
              final todayTotal = data.calculator.totalBetween(
                data.byDay,
                DateTime(today.year, today.month, today.day),
                today,
              );
              final weekTotal = data.calculator.totalBetween(
                data.byDay,
                today.subtract(const Duration(days: 6)),
                today,
              );
              final series = data.calculator.series(data.byDay, 7, now: today);
              final labels = series
                  .map((item) => DateFormat('dd/MM', 'pt_BR').format(item.day))
                  .toList();
              final values = series.map((item) => item.liters).toList();

              return RefreshIndicator(
                onRefresh: () async => _load(),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _TotalCard(
                            label: 'Hoje',
                            value: Fmt.liters(todayTotal),
                            icon: Icons.today,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _TotalCard(
                            label: 'Últimos 7 dias',
                            value: Fmt.liters(weekTotal),
                            icon: Icons.date_range,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Consumo diário',
                      subtitle:
                          'Média de ${Fmt.liters(weekTotal / 7)} por dia',
                      child: DailyConsumptionChart(
                        values: values,
                        labels: labels,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Como o consumo é calculado',
                      child: Text(
                        'Somamos as quedas de volume entre leituras consecutivas '
                        'com a bomba desligada e o sensor válido. Lacunas maiores '
                        'que ${data.calculator.maxGap.inMinutes} min '
                        '(5x o intervalo de ${data.device.config.reportIntervalSec}s) '
                        'são ignoradas para não superestimar o consumo. '
                        'Períodos com a bomba ligada não entram na conta.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Base de cálculo',
                      child: Column(
                        children: [
                          InfoTile(
                            label: 'Leituras analisadas',
                            value: '${data.readings.length}',
                            icon: Icons.list_alt,
                          ),
                          InfoTile(
                            label: 'Intervalo de publicação',
                            value: '${data.device.config.reportIntervalSec} s',
                            icon: Icons.timer_outlined,
                          ),
                          InfoTile(
                            label: 'Capacidade da caixa',
                            value: Fmt.liters(data.device.config.tank.capacityL),
                            icon: Icons.water_drop_outlined,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }
}

class _ConsumptionData {
  const _ConsumptionData({
    required this.device,
    required this.readings,
    required this.byDay,
    required this.calculator,
  });

  final Device device;
  final List<Reading> readings;
  final Map<DateTime, double> byDay;
  final ConsumptionCalculator calculator;
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
