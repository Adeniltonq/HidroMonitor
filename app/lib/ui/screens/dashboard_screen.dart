import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/consumption.dart';
import '../../models/device.dart';
import '../../models/reading.dart';
import '../../services/device_repository.dart';
import '../widgets/common.dart';
import '../widgets/sparkline.dart';
import '../widgets/status_chips.dart';
import '../widgets/water_level_gauge.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return HouseRequired(
      builder: (context) => DeviceRequired(
        builder: (context, houseId, deviceId) {
          final repo = context.read<DeviceRepository>();
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: repo.watchDeviceDoc(houseId, deviceId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorState(
                  message: describeError(snapshot.error!),
                  onRetry: () => GoRouter.of(context).refresh(),
                );
              }
              if (!snapshot.hasData) return const DashboardSkeleton();
              final doc = snapshot.data!;
              if (!doc.exists) {
                return const EmptyState(
                  icon: Icons.sensors_off_outlined,
                  title: 'Dispositivo não encontrado',
                  message: 'Refaça o pareamento para cadastrar a caixa.',
                );
              }
              final device = Device.fromDoc(doc);
              final cached = doc.metadata.isFromCache;

              return RefreshIndicator(
                onRefresh: () async {
                  // Os streams do Firestore já entregam atualizações; aqui só
                  // damos feedback tátil ao usuário.
                  await Future<void>.delayed(const Duration(milliseconds: 700));
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    CacheBanner(visible: cached),
                    _GaugeCard(device: device),
                    const SizedBox(height: 12),
                    _ConnectionStrip(device: device),
                    const SizedBox(height: 12),
                    _Readings24h(houseId: houseId, deviceId: deviceId, device: device),
                    const SizedBox(height: 12),
                    _AlertsPreview(houseId: houseId),
                    const SizedBox(height: 12),
                    const _QuickActions(),
                    const SizedBox(height: 12),
                    Text(
                      'Leitura, configuração e comandos manuais com confirmação. As '
                      'proteções continuam no próprio dispositivo.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final latest = device.latest;
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        children: [
          SectionCard(
            padding: EdgeInsets.zero,
            child: latest == null
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Aguardando a primeira leitura do dispositivo…'),
                  )
                : WaterLevelGauge(
                    percent: latest.levelPercent,
                    volumeL: device.config.tank
                      .volumeForPercent(latest.levelPercent),
                    levelCm: latest.levelCm,
                    tankHeightCm: device.config.tank.heightCm,
                  ),
          ),
          const SizedBox(height: 14),
          DeviceStatusChips(device: device),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stale = device.isStale();
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            stale ? Icons.cloud_off : Icons.cloud_done_outlined,
            color: stale ? scheme.error : Colors.green.shade600,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stale ? 'Sem contato com o dispositivo' : 'Conectado à nuvem',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Último contato ${Fmt.relative(device.lastSeen)} · '
                  'intervalo ${device.config.reportIntervalSec}s',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Detalhes da conexão',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => context.go('/conexao'),
          ),
        ],
      ),
    );
  }
}

class _Readings24h extends StatelessWidget {
  const _Readings24h({
    required this.houseId,
    required this.deviceId,
    required this.device,
  });

  final String houseId;
  final String deviceId;
  final Device device;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<Reading>>(
      stream: repo.watchReadings(
        houseId: houseId,
        deviceId: deviceId,
        hours: 24,
        limit: 500,
      ),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Nível nas últimas 24 h',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final readings = snapshot.data ?? const <Reading>[];
        final valid = readings.where((r) => r.sensorOk).toList();
        final spots = <FlSpot>[];
        if (valid.isNotEmpty) {
          final start = valid.first.ts ?? DateTime.now();
          for (final reading in valid) {
            final ts = reading.ts;
            if (ts == null) continue;
            spots.add(
              FlSpot(
                ts.difference(start).inMinutes / 60,
                reading.levelPercent,
              ),
            );
          }
        }
        final calculator = ConsumptionCalculator(
          reportIntervalSec: device.config.reportIntervalSec,
          volumeForPercent: device.config.tank.volumeForPercent,
        );
        final today = DateTime.now();
        final todayTotal = calculator.totalBetween(
          calculator.byDay(readings),
          DateTime(today.year, today.month, today.day),
          today,
        );

        return SectionCard(
          title: 'Nível nas últimas 24 h',
          subtitle: snapshot.connectionState == ConnectionState.waiting
              ? 'Carregando…'
              : '${valid.length} leituras válidas',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LevelSparkline(spots: spots),
              const Divider(),
              Row(
                children: [
                  const Icon(Icons.local_drink_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Consumo estimado hoje',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    Fmt.liters(todayTotal),
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
      },
    );
  }
}

class _AlertsPreview extends StatelessWidget {
  const _AlertsPreview({required this.houseId});

  final String houseId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<HouseAlert>>(
      stream: repo.watchAlerts(houseId: houseId, limit: 4),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Últimos alertas',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final alerts = snapshot.data ?? const <HouseAlert>[];
        final pending = alerts.where((alert) => !alert.ack).length;
        return SectionCard(
          title: 'Últimos alertas',
          subtitle: pending > 0 ? '$pending pendente(s) de reconhecimento' : null,
          trailing: TextButton(
            onPressed: () => context.go('/alertas'),
            child: const Text('Ver todos'),
          ),
          child: alerts.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nenhum alerta registrado. Tudo em ordem.'),
                )
              : Column(
                  children: [
                    for (final alert in alerts.take(3))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: SeverityDot(severity: alert.severity),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    alert.message,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${Fmt.relative(alert.ts)} · '
                                    '${alert.ack ? 'reconhecido' : 'pendente'}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
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
      },
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final actions = <(IconData, String, String)>[
      (Icons.water_drop_outlined, 'Nível', '/nivel'),
      (Icons.plumbing, 'Bomba', '/bomba'),
      (Icons.history, 'Histórico', '/historico'),
      (Icons.insights_outlined, 'Consumo', '/consumo'),
      (Icons.wifi_tethering, 'Conexão', '/conexao'),
      (Icons.tune, 'Configurar', '/config'),
      (Icons.build_outlined, 'Diagnóstico', '/diagnostico'),
      (Icons.group_outlined, 'Membros', '/membros'),
    ];
    return SectionCard(
      title: 'Atalhos',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final action in actions)
            ActionChip(
              avatar: Icon(action.$1, size: 18),
              label: Text(action.$2),
              onPressed: () => context.go(action.$3),
            ),
        ],
      ),
    );
  }
}
