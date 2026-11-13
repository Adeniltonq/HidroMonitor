import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/theme_controller.dart';

/// Seletor dos temas Branco, Preto e Sistema (persistido).
class ThemeSelector extends StatelessWidget {
  const ThemeSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final mode = controller.mode;

    final options = <(ThemeMode, String, IconData)>[
      (ThemeMode.system, 'Sistema', Icons.brightness_auto),
      (ThemeMode.light, 'Branco', Icons.light_mode),
      (ThemeMode.dark, 'Preto', Icons.dark_mode),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          ChoiceChip(
            showCheckmark: false,
            avatar: Icon(
              option.$3,
              size: 18,
              color: mode == option.$1
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            label: Text(option.$2),
            selected: mode == option.$1,
            onSelected: (_) => controller.setMode(option.$1),
          ),
      ],
    );
  }
}
