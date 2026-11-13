import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/house.dart';
import '../services/data_export_service.dart';
import '../state/auth_controller.dart';
import '../state/house_controller.dart';
import 'widgets/theme_selector.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _destinations = [
    (path: '/inicio', label: 'Início', icon: Icons.dashboard_outlined),
    (path: '/historico', label: 'Histórico', icon: Icons.history),
    (path: '/consumo', label: 'Consumo', icon: Icons.insights_outlined),
    (path: '/analise', label: 'Análise', icon: Icons.analytics_outlined),
    (path: '/alertas', label: 'Alertas', icon: Icons.notifications_outlined),
  ];

  String _titleFor(String location) {
    return switch (location) {
      '/inicio' => 'HidroMonitor',
      '/nivel' => 'Nível da caixa',
      '/bomba' => 'Bomba e válvula',
      '/alertas' => 'Alertas',
      '/historico' => 'Histórico',
      '/consumo' => 'Consumo',
      '/analise' => 'Análise',
      '/conexao' => 'Conexão',
      '/config' => 'Configurações da caixa',
      '/diagnostico' => 'Diagnóstico',
      '/pareamento' => 'Adicionar dispositivo',
      '/membros' => 'Membros e convites',
      _ => 'HidroMonitor',
    };
  }

  int _indexFor(String location) {
    final index = _destinations.indexWhere((item) => item.path == location);
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final controller = context.watch<HouseController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleFor(location)),
        actions: [
          IconButton(
            tooltip: 'Exportar dados (CSV)',
            onPressed: () => _exportCachedData(context),
            icon: const Icon(Icons.download_outlined),
          ),
          if (controller.selectedHouse != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: const Icon(Icons.home_work_outlined, size: 18),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    controller.selectedHouse!.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onPressed: () => _openHouses(context),
              ),
            ),
        ],
      ),
      drawer: _AppDrawer(
        currentLocation: location,
        onExport: () => _exportCachedData(context),
      ),
      body: SafeArea(child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indexFor(location),
        onDestinationSelected: (index) {
          context.go(_destinations[index].path);
        },
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(
                destination.icon,
                color: theme.colorScheme.primary,
              ),
              label: destination.label,
            ),
        ],
      ),
    );
  }

  Future<void> _exportCachedData(BuildContext context) async {
    final auth = context.read<AuthController>();
    final houseController = context.read<HouseController>();
    final user = auth.user;
    if (user == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Exportar dados (CSV)'),
        content: const Text(
          'O ZIP será gerado a partir do cache offline do Firestore. '
          'Isso não gasta a cota de leitura, mas só inclui os dados que o '
          'app já baixou. Cada coleção vira um CSV, com um resumo e um '
          'manifesto para análise por IA.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final progress = ValueNotifier<String>('Preparando...');
    var loadingOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Exportando...'),
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (_, value, __) => Text(value),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) => loadingOpen = false);

    try {
      final result = await DataExportService().exportCached(
        uid: user.uid,
        houses: houseController.houses
            .map((house) => (id: house.id, name: house.name))
            .toList(growable: false),
        onProgress: (message) => progress.value = message,
      );

      if (!context.mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }

      if (!result.hasData) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Nada no cache'),
            content: Text(
              'Não há documentos do Firestore no cache deste aparelho para '
              'exportar. Abra o dashboard e o histórico com internet uma vez '
              'e tente de novo.\n\n'
              '${result.errors.take(3).join('\n')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              result.zipBytes,
              mimeType: 'application/zip',
              name: result.fileName,
            ),
          ],
          subject: 'HidroMonitor — dados exportados',
          text: 'Exportação do cache offline do HidroMonitor '
              '(${result.totalDocuments} documentos).',
        ),
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.totalDocuments} documentos exportados'
              '${result.errors.isEmpty ? '.' : ' (${result.errors.length} '
                  'coleção(ões) sem cache).'}',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        if (loadingOpen) {
          Navigator.of(context, rootNavigator: true).pop();
          loadingOpen = false;
        }
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Falha na exportação'),
            content: Text('$error'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  void _openHouses(BuildContext context) async {
    final controller = context.read<HouseController>();
    final selected = await showModalBottomSheet<House>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Text(
                      'Suas casas',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (controller.houses.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Nenhuma casa encontrada.'),
                ),
              for (final house in controller.houses)
                ListTile(
                  leading: Icon(
                    house.id == controller.selectedHouse?.id
                        ? Icons.check_circle
                        : Icons.home_outlined,
                    color: house.id == controller.selectedHouse?.id
                        ? Theme.of(sheetContext).colorScheme.primary
                        : null,
                  ),
                  title: Text(house.name),
                  onTap: () => Navigator.of(sheetContext).pop(house),
                ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Gerenciar casas'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.go('/casas');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      await controller.selectHouse(selected);
      if (context.mounted) context.go('/inicio');
    }
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.currentLocation,
    required this.onExport,
  });

  final String currentLocation;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final house = context.watch<HouseController>();
    final scheme = Theme.of(context).colorScheme;
    final destinations = <(String, IconData, String)>[
      ('/inicio', Icons.dashboard_outlined, 'Início'),
      ('/nivel', Icons.water_drop_outlined, 'Nível da caixa'),
      ('/bomba', Icons.plumbing, 'Bomba e válvula'),
      ('/alertas', Icons.notifications_outlined, 'Alertas'),
      ('/historico', Icons.history, 'Histórico'),
      ('/consumo', Icons.insights_outlined, 'Consumo'),
      ('/analise', Icons.analytics_outlined, 'Análise'),
      ('/conexao', Icons.wifi_tethering, 'Conexão'),
      ('/config', Icons.tune, 'Configurações da caixa'),
      ('/diagnostico', Icons.build_outlined, 'Diagnóstico'),
      ('/pareamento', Icons.bluetooth_searching, 'Adicionar dispositivo'),
      ('/membros', Icons.group_outlined, 'Membros e convites'),
      ('/casas', Icons.home_work_outlined, 'Minhas casas'),
    ];

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      auth.displayName.characters.first.toUpperCase(),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    auth.displayName,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    auth.email,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.home_work_outlined,
                          size: 14, color: scheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          house.selectedHouse == null
                              ? 'Sem casa selecionada'
                              : '${house.selectedHouse!.name} · ${house.role.label}',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Tema',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: ThemeSelector(),
            ),
            const Divider(),
            for (final destination in destinations)
              ListTile(
                leading: Icon(destination.$2),
                title: Text(destination.$3),
                selected: currentLocation == destination.$1,
                onTap: () {
                  Navigator.of(context).pop();
                  context.go(destination.$1);
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Exportar dados (CSV)'),
              subtitle: const Text('Do cache offline, sem gastar cota'),
              onTap: () {
                Navigator.of(context).pop();
                onExport();
              },
            ),
            ListTile(
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text('Sair', style: TextStyle(color: scheme.error)),
              onTap: () async {
                Navigator.of(context).pop();
                await context.read<AuthController>().signOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}
