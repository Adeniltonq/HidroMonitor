import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../models/reading.dart';
import '../../services/csv_exporter.dart';
import '../../services/device_repository.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

enum _Period { day, week }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final List<Reading> _readings = [];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  _Period _period = _Period.day;
  bool _loading = false;
  bool _hasMore = true;
  bool _initialized = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  DateTime? get _since {
    final now = DateTime.now();
    return switch (_period) {
      _Period.day => DateTime(now.year, now.month, now.day),
      _Period.week => now.subtract(const Duration(days: 7)),
    };
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    final controller = context.read<HouseController>();
    final houseId = controller.selectedHouse?.id;
    final deviceId = controller.selectedDevice?.id;
    if (houseId == null || deviceId == null) return;

    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _readings.clear();
        _cursor = null;
        _hasMore = true;
      }
    });

    try {
      final page = await context.read<DeviceRepository>().fetchReadingsPage(
            houseId: houseId,
            deviceId: deviceId,
            since: _since,
            cursor: reset ? null : _cursor,
          );
      if (!mounted) return;
      setState(() {
        _readings.addAll(page.readings);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export() async {
    if (_readings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nada para exportar neste período.')),
      );
      return;
    }
    final houseName = context.read<HouseController>().selectedHouse?.name ?? 'Casa';
    try {
      await CsvExporter.shareReadings(
        readings: _readings,
        houseName: houseName,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao exportar: ${describeError(error)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return HouseRequired(
      builder: (context) {
        final device = context.watch<HouseController>().selectedDevice;
        if (device == null) {
          return const EmptyState(
            icon: Icons.sensors_off_outlined,
            title: 'Sem dispositivo',
            message: 'Pareie um dispositivo para ver o histórico.',
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  SegmentedButton<_Period>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: _Period.day, label: Text('Hoje')),
                      ButtonSegment(value: _Period.week, label: Text('7 dias')),
                    ],
                    selected: {_period},
                    onSelectionChanged: (value) {
                      setState(() => _period = value.first);
                      _load(reset: true);
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Exportar CSV',
                    onPressed: _export,
                    icon: const Icon(Icons.ios_share),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorState(
                  message: _error!,
                  compact: true,
                  onRetry: () => _load(reset: true),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _load(reset: true),
                child: _readings.isEmpty && !_loading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 80),
                          EmptyState(
                            icon: Icons.history,
                            title: 'Sem leituras no período',
                            message:
                                'Assim que o dispositivo publicar, as leituras aparecem aqui.',
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: _readings.length + 1,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          if (index == _readings.length) {
                            if (_loading) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            if (!_hasMore) {
                              return Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  'Fim do período.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: OutlinedButton.icon(
                                onPressed: () => _load(reset: false),
                                icon: const Icon(Icons.expand_more),
                                label: const Text('Carregar mais 50'),
                              ),
                            );
                          }
                          return _ReadingTile(
                            reading: _readings[index],
                            tank: device.config.tank,
                          );
                        },
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '${_readings.length} leitura(s) carregada(s) · '
                'ordem: mais recentes primeiro',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReadingTile extends StatelessWidget {
  const _ReadingTile({required this.reading, required this.tank});

  final Reading reading;
  final TankConfig tank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Fmt.time(reading.ts),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  Fmt.date(reading.ts),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Fmt.percent(reading.levelPercent)} · '
                  '${Fmt.liters(tank.volumeForPercent(reading.levelPercent))}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'distância ${Fmt.cm(reading.distanceCm)} · '
                  'coluna ${Fmt.cm(reading.levelCm)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Icon(
                reading.sensorOk ? Icons.check_circle_outline : Icons.error_outline,
                size: 18,
                color: reading.sensorOk ? scheme.outline : scheme.error,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.plumbing,
                    size: 14,
                    color: reading.pumpOn
                        ? Colors.green.shade600
                        : scheme.outlineVariant,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.water_damage_outlined,
                    size: 14,
                    color: reading.valveOpen
                        ? Colors.amber.shade800
                        : scheme.outlineVariant,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
