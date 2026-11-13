import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../widgets/common.dart';
import '../widgets/status_chips.dart';
import '../widgets/water_level_gauge.dart';

class LevelScreen extends StatelessWidget {
  const LevelScreen({super.key});

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
              final latest = device.latest;
              return RefreshIndicator(
                onRefresh: () async =>
                    Future<void>.delayed(const Duration(milliseconds: 600)),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    CacheBanner(visible: snapshot.data!.metadata.isFromCache),
                    SectionCard(
                      title: 'Medição',
                      subtitle: 'Distância do sensor até a superfície da água',
                      child: latest == null
                          ? const SizedBox(
                              height: 300,
                              child: Center(
                                child: Text('Aguardando leituras…'),
                              ),
                            )
                          : Column(
                              children: [
                                WaterLevelGauge(
                                  percent: latest.levelPercent,
                                  volumeL: device.config.tank
                                      .volumeForPercent(latest.levelPercent),
                                  levelCm: latest.levelCm,
                                  tankHeightCm: device.config.tank.heightCm,
                                  height: 260,
                                ),
                                const SizedBox(height: 12),
                                DeviceStatusChips(device: device),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    if (latest != null)
                      SectionCard(
                        title: 'Detalhes da leitura',
                        child: Column(
                          children: [
                            InfoTile(
                              icon: Icons.straighten,
                              label: 'Distância (sensor → água)',
                              value: Fmt.cm(latest.distanceCm),
                              caption:
                                  'Zona cega: ${Fmt.cm(device.config.tank.minRangeCm)} · '
                                  'máx. ${Fmt.cm(device.config.tank.maxRangeCm)}',
                            ),
                            InfoTile(
                              icon: Icons.height,
                              label: 'Coluna d\'água',
                              value: Fmt.cm(latest.levelCm),
                              caption:
                                  'Altura da caixa: ${Fmt.cm(device.config.tank.heightCm)}',
                            ),
                            InfoTile(
                              icon: Icons.water_drop_outlined,
                              label: 'Volume estimado',
                              value: Fmt.liters(device.config.tank
                                  .volumeForPercent(latest.levelPercent)),
                              caption: device.config.tank.usesManualVolume
                                  ? 'Tabela manual de litros por %'
                                  : 'Capacidade: ${Fmt.liters(device.config.tank.capacityL)}',
                            ),
                            InfoTile(
                              icon: Icons.percent,
                              label: 'Nível',
                              value: Fmt.percent(latest.levelPercent),
                            ),
                            InfoTile(
                              icon: Icons.schedule,
                              label: 'Leitura',
                              value: Fmt.dateTime(latest.ts),
                              caption: Fmt.relative(latest.ts),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    SectionCard(
                      title: 'Geometria configurada',
                      child: Column(
                        children: [
                          InfoTile(
                            label: 'Formato',
                            value: device.config.tank.format.label,
                            icon: Icons.category_outlined,
                          ),
                          if (device.config.tank.format == TankFormat.cilindro)
                            InfoTile(
                              label: 'Diâmetro',
                              value: Fmt.cm(device.config.tank.diameterCm),
                              icon: Icons.circle_outlined,
                            ),
                          if (device.config.tank.format == TankFormat.retangular) ...[
                            InfoTile(
                              label: 'Comprimento',
                              value: Fmt.cm(device.config.tank.lengthCm),
                              icon: Icons.straighten,
                            ),
                            InfoTile(
                              label: 'Largura',
                              value: Fmt.cm(device.config.tank.widthCm),
                              icon: Icons.straighten,
                            ),
                          ],
                          InfoTile(
                            label: 'Offset do sensor',
                            value: Fmt.cm(device.config.tank.sensorOffsetCm),
                            icon: Icons.tune,
                          ),
                        ],
                      ),
                    ),
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
