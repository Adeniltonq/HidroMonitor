import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/house.dart';
import '../../services/house_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return HouseRequired(
      builder: (context) {
        final controller = context.watch<HouseController>();
        final house = controller.selectedHouse!;
        final auth = context.watch<AuthController>();
        final canManage = controller.canManageMembers;
        final isOwner = controller.role == MemberRole.owner;
        final repo = context.read<HouseRepository>();

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'Membros',
              subtitle: 'Quem pode ver os dados desta casa',
              child: StreamBuilder<List<HouseMember>>(
                stream: repo.watchMembers(house.id),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return ErrorState(
                      message: describeError(snapshot.error!),
                      compact: true,
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final members = snapshot.data!;
                  return Column(
                    children: [
                      for (final member in members)
                        _MemberTile(
                          member: member,
                          isFounder: member.uid == house.ownerUid,
                          isMe: member.uid == auth.user?.uid,
                          isOwner: isOwner,
                          isAdmin: controller.role == MemberRole.admin,
                          onRoleChange: (role) => _changeRole(
                            context,
                            repo,
                            house.id,
                            member,
                            role,
                          ),
                          onRemove: () => _remove(
                            context,
                            repo,
                            house.id,
                            member,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            if (canManage)
              _InvitesSection(house: house, isOwner: isOwner)
            else
              SectionCard(
                title: 'Convites',
                child: Text(
                  'Apenas proprietários e administradores podem criar convites. '
                  'Peça a um deles para incluir alguém nesta casa.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'O proprietário fundador da casa não pode ser removido nem '
              'rebaixado — isso garante que sempre exista um owner.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _changeRole(
    BuildContext context,
    HouseRepository repo,
    String houseId,
    HouseMember member,
    MemberRole role,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.updateMemberRole(
        houseId: houseId,
        memberId: member.uid,
        role: role,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('${member.name} agora é ${role.label}.')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  Future<void> _remove(
    BuildContext context,
    HouseRepository repo,
    String houseId,
    HouseMember member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover membro'),
        content: Text(
          'Remover ${member.name} da casa? A pessoa perde o acesso imediatamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.removeMember(houseId: houseId, memberId: member.uid);
      messenger.showSnackBar(const SnackBar(content: Text('Membro removido.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isFounder,
    required this.isMe,
    required this.isOwner,
    required this.isAdmin,
    required this.onRoleChange,
    required this.onRemove,
  });

  final HouseMember member;
  final bool isFounder;
  final bool isMe;
  final bool isOwner;
  final bool isAdmin;
  final ValueChanged<MemberRole> onRoleChange;
  final VoidCallback onRemove;

  bool get _canRemove =>
      !isFounder && !isMe && ((isOwner) || (isAdmin && member.role == MemberRole.viewer));

  bool get _canChangeRole =>
      isOwner && !isFounder && !isMe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(
              member.name.isEmpty
                  ? '?'
                  : member.name.characters.first.toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.name.isEmpty ? member.email : member.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Text('(você)', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
                Text(
                  '${member.email} · ${member.role.label}'
                  '${isFounder ? ' · fundador' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_canChangeRole || _canRemove)
            PopupMenuButton<String>(
              tooltip: 'Gerenciar membro',
              onSelected: (value) {
                if (value == 'remove') {
                  onRemove();
                  return;
                }
                final role = MemberRole.parse(value);
                onRoleChange(role);
              },
              itemBuilder: (context) => [
                if (_canChangeRole) ...[
                  if (member.role != MemberRole.admin)
                    const PopupMenuItem(
                      value: 'admin',
                      child: Text('Tornar administrador'),
                    ),
                  if (member.role != MemberRole.viewer)
                    const PopupMenuItem(
                      value: 'viewer',
                      child: Text('Tornar visualizador'),
                    ),
                ],
                if (_canRemove)
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remover da casa'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InvitesSection extends StatelessWidget {
  const _InvitesSection({required this.house, required this.isOwner});

  final House house;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<HouseRepository>();
    return SectionCard(
      title: 'Convites',
      subtitle: 'Quem tem o código pode entrar na casa',
      trailing: IconButton(
        tooltip: 'Criar convite',
        icon: const Icon(Icons.add_link),
        onPressed: () => _createInvite(context, repo),
      ),
      child: StreamBuilder<List<HouseInvite>>(
        stream: repo.watchInvites(house.id),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorState(
              message: describeError(snapshot.error!),
              compact: true,
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final invites = snapshot.data!;
          if (invites.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Nenhum convite criado.'),
            );
          }
          return Column(
            children: [
              for (final invite in invites)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    invite.isActive ? Icons.mark_email_unread_outlined : Icons.mark_email_read_outlined,
                    color: invite.isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  title: Text(
                    '${invite.code} · ${invite.role.label}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    invite.used
                        ? 'Usado'
                        : invite.isExpired
                            ? 'Expirado em ${Fmt.date(invite.expiresAt)}'
                            : 'Válido até ${Fmt.date(invite.expiresAt)}'
                            '${invite.emailOpcional != null ? ' · ${invite.emailOpcional}' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (invite.isActive)
                        IconButton(
                          tooltip: 'Compartilhar convite',
                          icon: const Icon(Icons.ios_share),
                          onPressed: () => SharePlus.instance.share(
                            ShareParams(text: _inviteText(house, invite)),
                          ),
                        ),
                      IconButton(
                        tooltip: 'Excluir convite',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            _deleteInvite(context, repo, house.id, invite.code),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteInvite(
    BuildContext context,
    HouseRepository repo,
    String houseId,
    String code,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.removeInvite(houseId, code);
      messenger.showSnackBar(const SnackBar(content: Text('Convite excluído.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  String _inviteText(House house, HouseInvite invite) =>
      'Convite HidroMonitor\n'
      'Casa: ${house.name}\n'
      'ID da casa: ${house.id}\n'
      'Código: ${invite.code}\n'
      'Papel: ${invite.role.label}\n'
      'Validade: ${Fmt.date(invite.expiresAt)}\n'
      'Abra o app em "Entrar com convite" e informe o ID e o código.';

  Future<void> _createInvite(BuildContext context, HouseRepository repo) async {
    final auth = context.read<AuthController>();
    final role = await showDialog<MemberRole>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Novo convite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Escolha o papel do convidado:'),
            const SizedBox(height: 12),
            for (final option in isOwner
                ? [MemberRole.admin, MemberRole.viewer]
                : [MemberRole.viewer])
              ListTile(
                leading: Icon(
                  option == MemberRole.admin
                      ? Icons.admin_panel_settings_outlined
                      : Icons.visibility_outlined,
                ),
                title: Text(option.label),
                onTap: () => Navigator.of(dialogContext).pop(option),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (role == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final code = await repo.createInvite(
        houseId: house.id,
        createdBy: auth.user?.uid ?? '',
        role: role,
      );
      if (!context.mounted) return;
      final invite = HouseInvite(
        code: code,
        role: role,
        createdBy: auth.user?.uid ?? '',
        used: false,
        expiresAt: DateTime.now().add(const Duration(days: 14)),
      );
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Convite criado'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                _inviteText(house, invite),
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Compartilhe apenas com a pessoa que deve entrar na casa.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: _inviteText(house, invite)),
                );
                messenger.showSnackBar(
                  const SnackBar(content: Text('Convite copiado.')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copiar'),
            ),
            FilledButton.icon(
              onPressed: () => SharePlus.instance.share(
                ShareParams(text: _inviteText(house, invite)),
              ),
              icon: const Icon(Icons.ios_share),
              label: const Text('Compartilhar'),
            ),
          ],
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}
