import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/app_config.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../widgets/common.dart';

class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key});

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
              final stale = device.isStale();
              final scheme = Theme.of(context).colorScheme;
              final statusColor = stale ? scheme.error : Colors.green.shade600;

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  CacheBanner(visible: snapshot.data!.metadata.isFromCache),
                  SectionCard(
                    child: Column(
                      children: [
                        Icon(
                          stale ? Icons.cloud_off : Icons.cloud_done,
                          size: 44,
                          color: statusColor,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          stale ? 'Offline / dados desatualizados' : 'Online',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Último contato ${Fmt.relative(device.lastSeen)} '
                          '(${Fmt.dateTime(device.lastSeen)})',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (stale) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Considerado stale quando o último contato passa de '
                            '${device.config.alerts.offlineAfterSec}s. '
                            'Verifique a energia e a conexão Wi-Fi do dispositivo.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Conexão',
                    child: Column(
                      children: [
                        InfoTile(
                          icon: Icons.wifi,
                          label: 'Sinal Wi-Fi',
                          value: Fmt.signal(device.latest?.rssi),
                          caption: 'Sinal mais forte perto do roteador',
                        ),
                        InfoTile(
                          icon: Icons.memory,
                          label: 'Versão do dispositivo',
                          value: device.fwVersion,
                        ),
                        InfoTile(
                          icon: Icons.timer_outlined,
                          label: 'Intervalo de publicação',
                          value: '${device.config.reportIntervalSec} s',
                        ),
                        InfoTile(
                          icon: Icons.watch_later_outlined,
                          label: 'Limiar de offline',
                          value: '${device.config.alerts.offlineAfterSec} s',
                          caption: 'Default: 3x o intervalo de publicação',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Dispositivo',
                    child: Column(
                      children: [
                        InfoTile(
                          label: 'Nome',
                          value: device.name,
                          icon: Icons.sensors,
                        ),
                        InfoTile(
                          label: 'Número do dispositivo',
                          value: device.serial.isEmpty ? '—' : device.serial,
                          icon: Icons.qr_code,
                        ),
                        if (kShowTechnicalTools) ...[
                          InfoTile(
                            label: 'ID do documento',
                            value: device.id,
                            icon: Icons.tag,
                          ),
                          InfoTile(
                            label: 'UID do dispositivo',
                            value: _maskUid(device.deviceUid),
                            icon: Icons.key_outlined,
                          ),
                        ],
                        InfoTile(
                          label: 'Versão das configurações',
                          value: '${device.config.configVersion}',
                          icon: Icons.numbers,
                        ),
                        InfoTile(
                          label: 'Última leitura',
                          value: Fmt.dateTime(device.latest?.ts),
                          icon: Icons.schedule,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'O dispositivo envia as leituras com segurança. O app só lê esses dados.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  String _maskUid(String uid) {
    if (uid.length <= 8) return uid;
    return '${uid.substring(0, 4)}…${uid.substring(uid.length - 4)}';
  }
}
