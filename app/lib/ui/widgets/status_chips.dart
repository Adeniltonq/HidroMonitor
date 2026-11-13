import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../models/reading.dart';

/// Chips refletem o estado informado pelo firmware (não são controles).
class DeviceStatusChips extends StatelessWidget {
  const DeviceStatusChips({super.key, required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final latest = device.latest;
    final stale = device.isStale();
    final chips = <Widget>[
      _StatusChip(
        icon: Icons.plumbing,
        label: latest == null
            ? 'Bomba —'
            : latest.pumpOn
                ? 'Bomba ligada'
                : 'Bomba desligada',
        color: latest == null
            ? Colors.blueGrey
            : latest.pumpOn
                ? Colors.green.shade600
                : Colors.blueGrey,
      ),
      _StatusChip(
        icon: Icons.water_damage_outlined,
        label: latest == null
            ? 'Válvula —'
            : latest.valveOpen
                ? 'Válvula aberta'
                : 'Válvula fechada',
        color: latest == null
            ? Colors.blueGrey
            : latest.valveOpen
                ? Colors.amber.shade800
                : Colors.blueGrey,
      ),
      if (latest != null && !latest.sensorOk)
        _StatusChip(
          icon: Icons.sensors_off,
          label: 'Falha no sensor',
          color: Colors.red.shade600,
        ),
      _StatusChip(
        icon: stale ? Icons.cloud_off : Icons.cloud_done,
        label: stale
            ? 'Sem conexão'
            : 'Online ${Fmt.relative(device.lastSeen)}',
        color: stale ? Colors.red.shade600 : Colors.green.shade600,
      ),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: chips,
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.9)
                  : color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class SeverityDot extends StatelessWidget {
  const SeverityDot({super.key, required this.severity});

  final AlertSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = switch (severity) {
      AlertSeverity.crit => Colors.red.shade600,
      AlertSeverity.warn => Colors.amber.shade800,
      AlertSeverity.info => Colors.blue.shade600,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
