import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? dateFrom(Object? value) => value is Timestamp ? value.toDate() : null;

/// Papéis suportados. O app nunca promove ninguém a um papel acima do seu.
enum MemberRole {
  owner,
  admin,
  viewer;

  static MemberRole parse(Object? value) {
    switch (value) {
      case 'owner':
        return MemberRole.owner;
      case 'admin':
        return MemberRole.admin;
      default:
        return MemberRole.viewer;
    }
  }

  String get wire => name;

  String get label => switch (this) {
        MemberRole.owner => 'Proprietário',
        MemberRole.admin => 'Administrador',
        MemberRole.viewer => 'Visualizador',
      };

  bool get canEditConfig => this == MemberRole.owner || this == MemberRole.admin;
  bool get canManageMembers => canEditConfig;
  bool get canDelete => this == MemberRole.owner;
}

class House {
  const House({
    required this.id,
    required this.name,
    required this.ownerUid,
    this.createdAt,
    this.role = MemberRole.viewer,
  });

  final String id;
  final String name;
  final String ownerUid;
  final DateTime? createdAt;

  /// Papel do usuário logado nesta casa (preenchido pela listagem).
  final MemberRole role;

  bool get canDelete => role.canDelete;

  factory House.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc, {
    MemberRole role = MemberRole.viewer,
  }) {
    final data = doc.data() ?? const <String, dynamic>{};
    return House(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Casa sem nome',
      ownerUid: (data['ownerUid'] as String?) ?? '',
      createdAt: dateFrom(data['createdAt']),
      role: role,
    );
  }
}

class HouseMember {
  const HouseMember({
    required this.uid,
    required this.role,
    required this.name,
    required this.email,
    this.joinedAt,
  });

  final String uid;
  final MemberRole role;
  final String name;
  final String email;
  final DateTime? joinedAt;

  factory HouseMember.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return HouseMember(
      uid: doc.id,
      role: MemberRole.parse(data['role']),
      name: (data['name'] as String?) ?? '',
      email: (data['email'] as String?) ?? '',
      joinedAt: dateFrom(data['joinedAt']),
    );
  }
}

class HouseInvite {
  const HouseInvite({
    required this.code,
    required this.role,
    required this.createdBy,
    required this.used,
    this.emailOpcional,
    this.createdAt,
    this.expiresAt,
  });

  final String code;
  final MemberRole role;
  final String createdBy;
  final bool used;
  final String? emailOpcional;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  bool get isActive => !used && !isExpired;

  factory HouseInvite.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return HouseInvite(
      code: doc.id,
      role: MemberRole.parse(data['role']),
      createdBy: (data['createdBy'] as String?) ?? '',
      used: data['used'] == true,
      emailOpcional: data['emailOpcional'] as String?,
      createdAt: dateFrom(data['createdAt']),
      expiresAt: dateFrom(data['expiresAt']),
    );
  }
}
