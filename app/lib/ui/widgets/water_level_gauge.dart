import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/formatters.dart';

/// Medidor vertical animado (CustomPainter) da caixa d'água.
class WaterLevelGauge extends StatelessWidget {
  const WaterLevelGauge({
    super.key,
    required this.percent,
    this.volumeL,
    this.levelCm,
    this.tankHeightCm,
    this.height = 240,
    this.showCaption = true,
  });

  final double percent;
  final double? volumeL;
  final double? levelCm;
  final double? tankHeightCm;
  final double height;
  final bool showCaption;

  Color _colorFor(ColorScheme scheme) {
    if (percent <= 20) return Colors.red.shade600;
    if (percent <= 50) return Colors.amber.shade700;
    return scheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = percent.clamp(0.0, 100.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) {
        final waterColor = _colorFor(scheme);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: height,
              width: double.infinity,
              child: CustomPaint(
                painter: _TankPainter(
                  percent: animated,
                  waterColor: waterColor,
                  shellColor: scheme.outline,
                  surfaceColor: scheme.surfaceContainerHighest,
                  textColor: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (showCaption) ...[
              const SizedBox(height: 10),
              Text(
                '${animated.toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: waterColor,
                    ),
              ),
              const SizedBox(height: 2),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 14,
                children: [
                  Text(
                    volumeL == null ? '—' : Fmt.liters(volumeL),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    levelCm == null
                        ? '—'
                        : '${Fmt.cm(levelCm)} de ${Fmt.cm(tankHeightCm)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TankPainter extends CustomPainter {
  _TankPainter({
    required this.percent,
    required this.waterColor,
    required this.shellColor,
    required this.surfaceColor,
    required this.textColor,
  });

  final double percent;
  final Color waterColor;
  final Color shellColor;
  final Color surfaceColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    const margin = 18.0;
    final rect = Rect.fromLTWH(
      margin,
      margin,
      size.width - margin * 2,
      size.height - margin * 2,
    );
    final tank = RRect.fromRectAndRadius(rect, const Radius.circular(26));

    // Fundo interno
    canvas.drawRRect(tank, Paint()..color = surfaceColor.withValues(alpha: 0.5));

    // Água (clip no tanque)
    canvas.save();
    canvas.clipRRect(tank);
    final waterHeight = rect.height * (percent / 100).clamp(0.0, 1.0);
    final waterTop = rect.bottom - waterHeight;
    if (waterHeight > 0) {
      final wave = Path()
        ..moveTo(rect.left, waterTop + 6);
      final amplitude = math.min(6.0, waterHeight / 6);
      for (double x = rect.left; x <= rect.right; x += 2) {
        final y = waterTop + math.sin((x / rect.width) * math.pi * 4) * amplitude;
        wave.lineTo(x, y);
      }
      wave
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
      canvas.drawPath(
        wave,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              waterColor.withValues(alpha: 0.55),
              waterColor.withValues(alpha: 0.85),
            ],
          ).createShader(rect),
      );
    }
    canvas.restore();

    // Contorno e marcas de 25%
    canvas.drawRRect(
      tank,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = shellColor.withValues(alpha: 0.7),
    );
    final tickPaint = Paint()
      ..color = textColor.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = rect.top + rect.height * (i / 4);
      canvas.drawLine(
        Offset(rect.left + 8, y),
        Offset(rect.left + 26, y),
        tickPaint,
      );
      canvas.drawLine(
        Offset(rect.right - 26, y),
        Offset(rect.right - 8, y),
        tickPaint,
      );
    }

    // Tampa do sensor
    final sensor = Paint()
      ..color = textColor.withValues(alpha: 0.6)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(rect.center.dx - 14, rect.top - 8),
      Offset(rect.center.dx + 14, rect.top - 8),
      sensor,
    );
    canvas.drawLine(
      Offset(rect.center.dx, rect.top - 8),
      Offset(rect.center.dx, rect.top + 6),
      sensor,
    );
  }

  @override
  bool shouldRepaint(covariant _TankPainter oldDelegate) =>
      oldDelegate.percent != percent ||
      oldDelegate.waterColor != waterColor ||
      oldDelegate.surfaceColor != surfaceColor;
}
