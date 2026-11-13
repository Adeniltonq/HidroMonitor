import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../models/device_command.dart';
import '../../models/reading.dart';
import '../../services/device_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class PumpValveScreen extends StatelessWidget {
  const PumpValveScreen({super.key});

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
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  CacheBanner(visible: snapshot.data!.metadata.isFromCache),
                  Row(
                    children: [
                      Expanded(
                        child: _StateCard(
                          title: 'Bomba',
                          active: latest?.pumpOn == true,
                          activeLabel: 'Ligada',
                          inactiveLabel: 'Desligada',
                          icon: Icons.plumbing,
                          activeColor: Colors.green.shade600,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StateCard(
                          title: 'Válvula',
                          active: latest?.valveOpen == true,
                          activeLabel: 'Aberta',
                          inactiveLabel: 'Fechada',
                          icon: Icons.water_damage_outlined,
                          activeColor: Colors.amber.shade800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ManualControlCard(houseId: houseId, deviceId: deviceId),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Limites de funcionamento automático',
                    subtitle:
                        'Usados pelo dispositivo. O controle manual acima '
                        'envia comandos com validade e proteções.',
                    child: Column(
                      children: [
                        InfoTile(
                          icon: Icons.vertical_align_bottom,
                          label: 'Ligar quando a distância atingir',
                          value: Fmt.cm(device.config.limits.ligaCm),
                          caption: 'Água baixa (quanto maior a distância, menor o nível)',
                        ),
                        InfoTile(
                          icon: Icons.vertical_align_top,
                          label: 'Desligar quando a distância cair para',
                          value: Fmt.cm(device.config.limits.desligaCm),
                          caption:
                              'Padrão 25 cm (zona cega do ultrassônico / caixa cheia)',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _EventsTimeline(houseId: houseId, deviceId: deviceId),
                  const SizedBox(height: 12),
                  Text(
                    'O controle manual é exclusivo de proprietário/administrador. '
                    'O dispositivo mantém tempo máximo de bomba, proteção a seco, '
                    'falha de sensor e corte por caixa cheia.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
}

class _ManualControlCard extends StatelessWidget {
  const _ManualControlCard({
    required this.houseId,
    required this.deviceId,
  });

  final String houseId;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<HouseController>();
    final auth = context.watch<AuthController>();
    final repo = context.read<DeviceRepository>();
    final canControl = controller.canEditConfig;
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<DeviceCommand>>(
      stream: repo.watchCommands(houseId: houseId, deviceId: deviceId),
      builder: (context, snapshot) {
        final commands = snapshot.data ?? const <DeviceCommand>[];
        final last = commands.isEmpty ? null : commands.first;

        return SectionCard(
          title: 'Controle manual',
          subtitle:
              'Os comandos valem por 2 minutos e são executados pelo dispositivo em '
              'até ~10 s. As proteções continuam ativas.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!canControl)
                Text(
                  'Seu papel nesta casa é Visualizador. Pça a um '
                  'proprietário/administrador para acionar a bomba.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(150, 46),
                      ),
                      onPressed: () => _send(
                        context,
                        repo,
                        auth,
                        CommandAction.pumpOn,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Ligar bomba'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(150, 46),
                      ),
                      onPressed: () => _send(
                        context,
                        repo,
                        auth,
                        CommandAction.pumpOff,
                      ),
                      icon: const Icon(Icons.stop),
                      label: const Text('Desligar bomba'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _send(
                        context,
                        repo,
                        auth,
                        CommandAction.auto,
                      ),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset (auto)'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Ligar manualmente não ignora a segurança: o dispositivo '
                    'desliga em 10 min, se o sensor falhar, se a caixa encher '
                    'ou se detectar funcionamento a seco. "Reset (auto)" '
                    'devolve o controle aos limites ligaCm/desligaCm.',
                    style: TextStyle(
                      color: scheme.onTertiaryContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (last != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      last.status == CommandStatus.done
                          ? Icons.check_circle
                          : last.status == CommandStatus.rejected
                              ? Icons.error
                              : Icons.schedule,
                      size: 18,
                      color: last.status == CommandStatus.rejected
                          ? scheme.error
                          : scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Último comando: ${last.action.label} · '
                        '${last.isExpired ? 'expirado (device offline)' : last.status.label}'
                        '${last.detail != null && last.detail!.isNotEmpty ? ' — ${last.detail}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _send(
    BuildContext context,
    DeviceRepository repo,
    AuthController auth,
    CommandAction action,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(action.label),
        content: Text(
          switch (action) {
            CommandAction.pumpOn =>
              'Ligar a bomba manualmente? O dispositivo ainda desliga em 10 min, '
                  'se a caixa encher, se o sensor falhar ou em proteção a seco.',
            CommandAction.pumpOff =>
              'Desligar a bomba agora? A válvula também será fechada.',
            CommandAction.auto =>
              'Voltar ao controle automático? O dispositivo volta a ligar/desligar '
                  'pelos limites ligaCm/desligaCm.',
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action == CommandAction.pumpOff ? 'Desligar' : 'Confirmar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final uid = auth.user?.uid;
    if (uid == null) return;
    try {
      await repo.sendCommand(
        houseId: houseId,
        deviceId: deviceId,
        action: action,
        byUid: uid,
        byName: auth.displayName,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Comando enviado. O dispositivo aplica em até ~10 s.'),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.title,
    required this.active,
    required this.activeLabel,
    required this.inactiveLabel,
    required this.icon,
    required this.activeColor,
  });

  final String title;
  final bool active;
  final String activeLabel;
  final String inactiveLabel;
  final IconData icon;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? activeColor : scheme.outline;
    return SectionCard(
      child: Column(
        children: [
          Icon(icon, size: 36, color: color),
          const SizedBox(height: 8),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            active ? activeLabel : inactiveLabel,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'estado informado',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _EventsTimeline extends StatelessWidget {
  const _EventsTimeline({required this.houseId, required this.deviceId});

  final String houseId;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return StreamBuilder<List<DeviceEvent>>(
      stream: repo.watchEvents(houseId: houseId, deviceId: deviceId, limit: 80),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionCard(
            title: 'Linha do tempo',
            child: ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            ),
          );
        }
        final events = (snapshot.data ?? const <DeviceEvent>[])
            .where(
              (event) =>
                  event.type == DeviceEventType.pumpOn ||
                  event.type == DeviceEventType.pumpOff ||
                  event.type == DeviceEventType.valveClose ||
                  event.type == DeviceEventType.valveOpen,
            )
            .take(30)
            .toList();

        return SectionCard(
          title: 'Linha do tempo',
          subtitle: 'Acionamentos registrados pelo próprio dispositivo',
          child: events.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nenhum evento de bomba/válvula registrado.'),
                )
              : Column(
                  children: [
                    for (final event in events)
                      _EventRow(event: event),
                  ],
                ),
        );
      },
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final DeviceEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (event.type) {
      DeviceEventType.pumpOn => (Icons.play_circle_outline, Colors.green.shade600),
      DeviceEventType.pumpOff => (Icons.stop_circle_outlined, scheme.outline),
      DeviceEventType.valveOpen => (Icons.lock_open, Colors.amber.shade800),
      DeviceEventType.valveClose => (Icons.lock_outline, scheme.outline),
      DeviceEventType.manualOn => (Icons.touch_app, Colors.green.shade600),
      DeviceEventType.manualOff => (Icons.touch_app, Colors.red.shade600),
      DeviceEventType.manualAuto => (Icons.autorenew, scheme.primary),
      _ => (Icons.circle_outlined, scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.type.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
