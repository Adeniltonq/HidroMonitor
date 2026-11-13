import 'package:cloud_firestore/cloud_firestore.dart';

import 'house.dart' show dateFrom;

enum CommandAction {
  pumpOn('pump_on', 'Ligar bomba', 'Liga a bomba em modo manual'),
  pumpOff('pump_off', 'Desligar bomba', 'Desliga a bomba imediatamente'),
  auto('auto', 'Voltar ao automático', 'Devolve o controle ao firmware');

  const CommandAction(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;

  static CommandAction parse(Object? value) {
    for (final action in CommandAction.values) {
      if (action.wire == value) return action;
    }
    return CommandAction.auto;
  }
}

enum CommandStatus {
  pending('pending', 'Pendente'),
  done('done', 'Executado'),
  rejected('rejected', 'Recusado');

  const CommandStatus(this.wire, this.label);

  final String wire;
  final String label;

  static CommandStatus parse(Object? value) => switch (value) {
        'done' => CommandStatus.done,
        'rejected' => CommandStatus.rejected,
        _ => CommandStatus.pending,
      };
}

class DeviceCommand {
  const DeviceCommand({
    required this.id,
    required this.action,
    required this.status,
    required this.createdByName,
    this.detail,
    this.createdAt,
    this.executedAt,
    this.expiresAt,
  });

  final String id;
  final CommandAction action;
  final CommandStatus status;
  final String createdByName;
  final String? detail;
  final DateTime? createdAt;
  final DateTime? executedAt;
  final DateTime? expiresAt;

  bool get isExpired =>
      status == CommandStatus.pending &&
      expiresAt != null &&
      expiresAt!.isBefore(DateTime.now());

  factory DeviceCommand.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return DeviceCommand(
      id: doc.id,
      action: CommandAction.parse(data['action']),
      status: CommandStatus.parse(data['status']),
      createdByName: (data['createdByName'] as String?) ?? '',
      detail: data['detail'] as String?,
      createdAt: dateFrom(data['createdAt']),
      executedAt: dateFrom(data['executedAt']),
      expiresAt: dateFrom(data['expiresAt']),
    );
  }
}
