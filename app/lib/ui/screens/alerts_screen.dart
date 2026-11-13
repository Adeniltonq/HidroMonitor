import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/reading.dart';
import '../../services/device_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  bool _onlyPending = false;

  @override
  Widget build(BuildContext context) {
    return HouseRequired(
      builder: (context) {
        final houseId = context.watch<HouseController>().selectedHouse!.id;
        final repo = context.read<DeviceRepository>();
        final uid = context.read<AuthController>().user?.uid;
        return StreamBuilder<List<HouseAlert>>(
          stream: repo.watchAlerts(houseId: houseId, limit: 50),
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
            final all = snapshot.data!;
            final alerts =
                _onlyPending ? all.where((alert) => !alert.ack).toList() : all;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      FilterChip(
                        selected: _onlyPending,
                        label: const Text('Somente pendentes'),
                        onSelected: (value) =>
                            setState(() => _onlyPending = value),
                      ),
                      const Spacer(),
                      Text(
                        '${alerts.length} alerta(s)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: alerts.isEmpty
                      ? const EmptyState(
                          icon: Icons.check_circle_outline,
                          title: 'Nenhum alerta',
                          message: 'A caixa está dentro dos parâmetros configurados.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: alerts.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final alert = alerts[index];
                            return _AlertCard(
                              alert: alert,
                              canAck: uid != null && !alert.ack,
                              onAck: uid == null
                                  ? null
                                  : () => _ack(repo, houseId, alert, uid),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _ack(
    DeviceRepository repo,
    String houseId,
    HouseAlert alert,
    String uid,
  ) async {
    try {
      await repo.ackAlert(houseId: houseId, alertId: alert.id, uid: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alerta reconhecido.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.alert,
    required this.canAck,
    required this.onAck,
  });

  final HouseAlert alert;
  final bool canAck;
  final VoidCallback? onAck;

  Color _color(BuildContext context) {
    return switch (alert.severity) {
      AlertSeverity.crit => Colors.red.shade600,
      AlertSeverity.warn => Colors.amber.shade800,
      AlertSeverity.info => Colors.blue.shade600,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(context);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (alert.severity) {
                  AlertSeverity.crit => Icons.dangerous_outlined,
                  AlertSeverity.warn => Icons.warning_amber_rounded,
                  AlertSeverity.info => Icons.info_outline,
                },
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  alert.type.replaceAll('_', ' '),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              Text(
                alert.severity.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(alert.message),
          const SizedBox(height: 6),
          Text(
            '${Fmt.dateTime(alert.ts)} · ${Fmt.relative(alert.ts)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (alert.ack)
                Row(
                  children: [
                    Icon(Icons.done_all, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Reconhecido ${Fmt.relative(alert.ackTs)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                )
              else ...[
                Icon(Icons.pending_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Pendente',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                if (canAck)
                  FilledButton.tonalIcon(
                    onPressed: onAck,
                    icon: const Icon(Icons.done, size: 18),
                    label: const Text('Reconhecer'),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
