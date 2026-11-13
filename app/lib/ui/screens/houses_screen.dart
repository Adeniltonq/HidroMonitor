import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../models/house.dart';
import '../../services/house_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class HousesScreen extends StatelessWidget {
  const HousesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<HouseController>();
    final auth = context.watch<AuthController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas casas'),
        actions: [
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AuthController>().signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await controller.refresh();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Olá, ${auth.displayName}',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Escolha uma casa, crie uma nova ou entre com um convite.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 20),
            if (controller.loadingHouses)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (controller.error != null)
              ErrorState(
                message: controller.error!,
                onRetry: controller.refresh,
              )
            else if (controller.houses.isEmpty)
              EmptyState(
                icon: Icons.home_work_outlined,
                title: 'Nenhuma casa ainda',
                message:
                    'Crie a primeira casa ou peça um convite a quem já usa o HidroMonitor.',
                actionLabel: 'Criar casa',
                onAction: () => _createHouse(context, auth),
              )
            else ...[
              ...controller.houses.map(
                (house) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _HouseTile(
                    house: house,
                    selected: house.id == controller.selectedHouse?.id,
                    onDelete: house.canDelete
                        ? () => _deleteHouse(context, house, auth)
                        : null,
                    onTap: () async {
                      await controller.selectHouse(house);
                      if (context.mounted) context.go('/inicio');
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _createHouse(context, auth),
              icon: const Icon(Icons.add_home_work_outlined),
              label: const Text('Criar casa'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _joinHouse(context, auth),
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Entrar com convite'),
            ),
            const SizedBox(height: 24),
            Text(
              'O app mostra as leituras, edita parâmetros e permite comando manual '
              'da bomba com confirmação e travas de segurança do dispositivo.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// Exclui a casa e tudo que está dentro dela (somente o proprietário).
  Future<void> _deleteHouse(
    BuildContext context,
    House house,
    AuthController auth,
  ) async {
    final uid = auth.user?.uid;
    if (uid == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir casa?'),
        content: Text(
          'A casa "${house.name}" será apagada COM todos os dispositivos, '
          'leituras, alertas e membros. Depois disso o dispositivo para de '
          'enviar dados e só volta pareando de novo.\n\n'
          'Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Excluir definitivamente'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final repo = context.read<HouseRepository>();
    final controller = context.read<HouseController>();
    final progress = ValueNotifier<String>('Apagando…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (context, value, _) => Text(value),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      await repo.deleteHouse(
        houseId: house.id,
        myUid: uid,
        onProgress: (label, removidos) {
          final nome = switch (label) {
            'readings' => 'leituras',
            'events' => 'eventos',
            'commands' => 'comandos',
            'devices' => 'dispositivos',
            'alerts' => 'alertas',
            'invites' => 'convites',
            'configLog' => 'histórico de configuração',
            _ => label,
          };
          progress.value = 'Apagando $nome… ($removidos)';
        },
      );
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();  // fecha o progresso
      await controller.refresh();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Casa "${house.name}" excluída.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      progress.dispose();
    }
  }

  Future<void> _createHouse(BuildContext context, AuthController auth) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Criar casa'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nome da casa',
              hintText: 'Ex.: Casa da praia',
            ),
            textCapitalization: TextCapitalization.words,
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Criar'),
            ),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty) return;
    if (!context.mounted) return;
    final user = auth.user;
    if (user == null) return;
    final repo = context.read<HouseRepository>();
    final controller = context.read<HouseController>();
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final id = await repo.createHouse(
        name: name.trim(),
        uid: user.uid,
        userName: auth.displayName,
        userEmail: auth.email,
      );
      final house = House(
        id: id,
        name: name.trim(),
        ownerUid: user.uid,
        createdAt: DateTime.now(),
      );
      await controller.selectHouse(house);
      router.go('/inicio');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  Future<void> _joinHouse(BuildContext context, AuthController auth) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) {
        final houseController = TextEditingController();
        final codeController = TextEditingController();
        final formKey = GlobalKey<FormState>();
        return AlertDialog(
          title: const Text('Entrar com convite'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Código do convite',
                    hintText: 'Ex.: DEMO2026',
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Informe o código.' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: houseController,
                  decoration: const InputDecoration(
                    labelText: 'Identificador da casa',
                    hintText: 'Ex.: casa-demo',
                    helperText: 'Vem junto com o código no texto do convite.',
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Informe a casa.' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext)
                      .pop((houseController.text, codeController.text));
                }
              },
              child: const Text('Entrar'),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    if (!context.mounted) return;
    final user = auth.user;
    if (user == null) return;
    final repo = context.read<HouseRepository>();
    final controller = context.read<HouseController>();
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final (houseId, code) = result;
      await repo.acceptInvite(
        houseId: houseId.trim(),
        code: code.trim(),
        uid: user.uid,
        name: auth.displayName,
        email: auth.email,
      );
      final house = await repo.watchHouse(houseId.trim()).first;
      await controller.selectHouse(house);
      router.go('/inicio');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

class _HouseTile extends StatelessWidget {
  const _HouseTile({
    required this.house,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final House house;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          selected ? Icons.check_circle : Icons.home_outlined,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          house.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('ID: ${house.id}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chevron_right),
            if (onDelete != null)
              PopupMenuButton<String>(
                tooltip: 'Opções da casa',
                onSelected: (value) {
                  if (value == 'delete') onDelete!();
                },
                itemBuilder: (menuContext) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_forever_outlined),
                      title: Text('Excluir casa'),
                    ),
                  ),
                ],
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
