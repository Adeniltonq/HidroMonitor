import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../models/reading.dart';
import '../../services/device_repository.dart';
import '../widgets/common.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

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
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final device = Device.fromDoc(snapshot.data!);
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  CacheBanner(visible: snapshot.data!.metadata.isFromCache),
                  SectionCard(
                    title: 'Saúde do dispositivo',
                    child: Column(
                      children: [
                        InfoTile(
                          icon: Icons.memory,
                          label: 'Software do dispositivo',
                          value: device.fwVersion,
                        ),
                        InfoTile(
                          icon: Icons.numbers,
                          label: 'Versão das configurações',
                          value: '${device.config.configVersion}',
                          caption: 'Atualizada a cada mudança de parâmetros',
                        ),
                        InfoTile(
                          icon: Icons.schedule,
                          label: 'Último contato',
                          value: Fmt.dateTime(device.lastSeen),
                          caption: Fmt.relative(device.lastSeen),
                        ),
                        InfoTile(
                          icon: Icons.sensors,
                          label: 'Sensor',
                          value: device.latest == null
                              ? 'sem leitura'
                              : device.latest!.sensorOk
                                  ? 'operando'
                                  : 'com falha',
                        ),
                        InfoTile(
                          icon: Icons.wifi,
                          label: 'Sinal Wi-Fi',
                          value: Fmt.signal(device.latest?.rssi),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _EventStats(houseId: houseId, deviceId: deviceId),
                  const SizedBox(height: 12),
                  _EventList(houseId: houseId, deviceId: deviceId),
                  const SizedBox(height: 12),
                  _ConfigLogList(houseId: houseId),
                  const SizedBox(height: 24),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _EventStats extends StatelessWidget {
  const _EventStats({required this.houseId, required this.deviceId});

  final String houseId;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<DeviceEvent>>(
      stream: repo.watchEvents(houseId: houseId, deviceId: deviceId, limit: 100),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Indicadores',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final events = snapshot.data ?? const <DeviceEvent>[];
        int count(DeviceEventType type) =>
            events.where((event) => event.type == type).length;
        final boots = count(DeviceEventType.boot);
        final wifiDrops = count(DeviceEventType.wifiDrop);
        final invalid = count(DeviceEventType.invalidReading);
        final lastBoot = events
            .where((event) => event.type == DeviceEventType.boot)
            .map((event) => event.ts)
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

        return SectionCard(
          title: 'Indicadores (últimos 100 eventos)',
          child: Column(
            children: [
              InfoTile(
                icon: Icons.restart_alt,
                label: 'Reinícios',
                value: '$boots',
                caption: lastBoot == null
                    ? 'Nenhum reinício registrado'
                    : 'Último em ${Fmt.dateTime(lastBoot)}',
              ),
              InfoTile(
                icon: Icons.wifi_off,
                label: 'Quedas de Wi-Fi',
                value: '$wifiDrops',
              ),
              InfoTile(
                icon: Icons.error_outline,
                label: 'Leituras inválidas',
                value: '$invalid',
                caption: 'Leituras inválidas do sensor',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({required this.houseId, required this.deviceId});

  final String houseId;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<DeviceEvent>>(
      stream: repo.watchEvents(houseId: houseId, deviceId: deviceId, limit: 100),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Eventos de diagnóstico',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final events = (snapshot.data ?? const <DeviceEvent>[])
            .where(
              (event) =>
                  event.type == DeviceEventType.boot ||
                  event.type == DeviceEventType.wifiConn ||
                  event.type == DeviceEventType.wifiDrop ||
                  event.type == DeviceEventType.invalidReading,
            )
            .take(25)
            .toList();
        return SectionCard(
          title: 'Eventos de diagnóstico',
          child: events.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nenhum evento registrado.'),
                )
              : Column(
                  children: [
                    for (final event in events)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              switch (event.type) {
                                DeviceEventType.boot => Icons.restart_alt,
                                DeviceEventType.wifiDrop => Icons.wifi_off,
                                DeviceEventType.wifiConn => Icons.wifi,
                                _ => Icons.warning_amber,
                              },
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(event.type.label),
                                  if (event.detail.isNotEmpty)
                                    Text(
                                      event.detail,
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              Fmt.dateTime(event.ts),
                              style: Theme.of(context).textTheme.bodySmall,
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

class _ConfigLogList extends StatelessWidget {
  const _ConfigLogList({required this.houseId});

  final String houseId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<ConfigLogEntry>>(
      stream: repo.watchConfigLog(houseId: houseId, limit: 10),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Histórico de configuração',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final entries = snapshot.data ?? const <ConfigLogEntry>[];
        return SectionCard(
          title: 'Histórico de configuração',
          subtitle: 'Toda alteração gera uma nova versão e mantém o histórico',
          child: entries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nenhuma alteração registrada.'),
                )
              : Column(
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${entry.byName} · ${Fmt.dateTime(entry.ts)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${entry.changes.length} campo(s)',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            for (final change in entry.changes.entries)
                              Text(
                                '${change.key}: ${change.value.oldValue} → '
                                '${change.value.newValue}',
                                style: Theme.of(context).textTheme.bodySmall,
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
