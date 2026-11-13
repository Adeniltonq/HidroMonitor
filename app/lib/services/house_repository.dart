import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/errors.dart';
import '../models/house.dart';
import 'firestore_cleanup.dart';

/// Casas, membros e convites. Toda escrita é validada também pelas rules.
class HouseRepository {
  HouseRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _houses =>
      _db.collection('houses');

  /// Lista as casas em que o usuário é membro.
  /// Usa collectionGroup('members') com o campo desnormalizado `uid`.
  Stream<List<House>> watchHousesForUser(String uid) {
    return _db
        .collectionGroup('members')
        .where('uid', isEqualTo: uid)
        .snapshots()
        .asyncMap((snapshot) async {
      // casa -> papel do usuário (para saber onde ele pode excluir)
      final roles = <String, MemberRole>{};
      for (final doc in snapshot.docs) {
        final houseRef = doc.reference.parent.parent;
        if (houseRef == null) continue;
        roles[houseRef.id] = MemberRole.parse(doc.data()['role']);
      }
      if (roles.isEmpty) return const <House>[];
      final docs = await Future.wait(
        roles.keys.map((id) => _houses.doc(id).get()),
      );
      final houses = docs
          .where((doc) => doc.exists && doc.data() != null)
          .map((doc) => House.fromDoc(doc, role: roles[doc.id] ?? MemberRole.viewer))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return houses;
    }).handleError((Object error) {
      throw AppException(describeError(error), cause: error);
    });
  }

  /// Exclui a casa inteira: dispositivos (com leituras/eventos/comandos),
  /// alertas, convites, log de configuração, membros e, por último, o
  /// documento da casa e o vínculo do proprietário.
  ///
  /// Só o proprietário consegue (regras do Firestore). A ordem importa: o
  /// vínculo do dono é apagado depois da casa porque a regra exige que a casa
  /// já não exista nesse momento.
  Future<void> deleteHouse({
    required String houseId,
    required String myUid,
    void Function(String label, int removidos)? onProgress,
  }) async {
    try {
      final houseRef = _houses.doc(houseId);

      final devices = await houseRef.collection('devices').get();
      for (final device in devices.docs) {
        for (final sub in const ['readings', 'events', 'commands']) {
          await deleteCollectionDocs(
            device.reference.collection(sub),
            label: sub,
            onProgress: onProgress,
          );
        }
        await device.reference.delete();
      }
      onProgress?.call('devices', devices.docs.length);

      for (final sub in const ['alerts', 'invites', 'configLog']) {
        await deleteCollectionDocs(
          houseRef.collection(sub),
          label: sub,
          onProgress: onProgress,
        );
      }

      final members = await houseRef.collection('members').get();
      for (final member in members.docs) {
        if (member.id == myUid) continue;  // o dono sai por último
        await member.reference.delete();
      }

      await houseRef.delete();
      await houseRef.collection('members').doc(myUid).delete();
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Stream<House> watchHouse(String houseId) => _houses.doc(houseId).snapshots().map(
        (doc) {
          if (!doc.exists) {
            throw const AppException('Casa não encontrada ou acesso removido.');
          }
          return House.fromDoc(doc);
        },
      );

  Stream<HouseMember?> watchMembership(String houseId, String uid) => _houses
      .doc(houseId)
      .collection('members')
      .doc(uid)
      .snapshots()
      .map((doc) => doc.exists ? HouseMember.fromDoc(doc) : null);

  Stream<List<HouseMember>> watchMembers(String houseId) => _houses
      .doc(houseId)
      .collection('members')
      .orderBy('joinedAt')
      .snapshots()
      .map((snapshot) => snapshot.docs.map(HouseMember.fromDoc).toList());

  /// Cria a casa + o vínculo do criador como owner no mesmo batch.
  Future<String> createHouse({
    required String name,
    required String uid,
    required String userName,
    required String userEmail,
  }) async {
    final houseRef = _houses.doc();
    final batch = _db.batch();
    batch.set(houseRef, {
      'name': name.trim(),
      'ownerUid': uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(houseRef.collection('members').doc(uid), {
      'role': 'owner',
      'name': userName,
      'email': userEmail,
      'joinedAt': FieldValue.serverTimestamp(),
      'uid': uid,
    });
    try {
      await batch.commit();
      return houseRef.id;
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> renameHouse(String houseId, String name) async {
    try {
      await _houses.doc(houseId).update({'name': name.trim()});
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  // -------------------------------------------------------------------------
  // Convites
  // -------------------------------------------------------------------------

  Stream<List<HouseInvite>> watchInvites(String houseId) => _houses
      .doc(houseId)
      .collection('invites')
      .snapshots()
      .map((snapshot) => snapshot.docs.map(HouseInvite.fromDoc).toList());

  Future<HouseInvite> getInvite(String houseId, String code) async {
    try {
      final doc = await _houses
          .doc(houseId)
          .collection('invites')
          .doc(code.trim().toUpperCase())
          .get();
      if (!doc.exists) {
        throw const AppException('Convite não encontrado. Confira o código.');
      }
      return HouseInvite.fromDoc(doc);
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<String> createInvite({
    required String houseId,
    required String createdBy,
    required MemberRole role,
    String? emailOpcional,
    int validDays = 14,
  }) async {
    final code = _generateCode();
    final now = DateTime.now();
    try {
      await _houses.doc(houseId).collection('invites').doc(code).set({
        'role': role.wire,
        'emailOpcional': (emailOpcional == null || emailOpcional.trim().isEmpty)
            ? null
            : emailOpcional.trim().toLowerCase(),
        'createdBy': createdBy,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(now.add(Duration(days: validDays))),
        'used': false,
      });
      return code;
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Aceite: cria members/{uid} e marca o convite como usado (batch atômico).
  Future<String> acceptInvite({
    required String houseId,
    required String code,
    required String uid,
    required String name,
    required String email,
  }) async {
    try {
      final inviteRef =
          _houses.doc(houseId).collection('invites').doc(code.trim().toUpperCase());
      final inviteDoc = await inviteRef.get();
      if (!inviteDoc.exists) {
        throw const AppException('Convite não encontrado.');
      }
      final invite = HouseInvite.fromDoc(inviteDoc);
      if (invite.used) throw const AppException('Este convite já foi utilizado.');
      if (invite.isExpired) throw const AppException('Este convite expirou.');
      if (invite.emailOpcional != null &&
          invite.emailOpcional!.isNotEmpty &&
          invite.emailOpcional!.toLowerCase() != email.toLowerCase()) {
        throw const AppException('Este convite é destinado a outro e-mail.');
      }

      final batch = _db.batch();
      batch.set(_houses.doc(houseId).collection('members').doc(uid), {
        'role': invite.role.wire,
        'name': name,
        'email': email,
        'joinedAt': FieldValue.serverTimestamp(),
        'uid': uid,
        // campo de auditoria: comprova qual convite originou o vínculo
        'inviteCode': invite.code,
      });
      batch.update(inviteRef, {
        'used': true,
        'usedBy': uid,
      });
      await batch.commit();
      return houseId;
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> removeInvite(String houseId, String code) async {
    try {
      await _houses
          .doc(houseId)
          .collection('invites')
          .doc(code.trim().toUpperCase())
          .delete();
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> updateMemberRole({
    required String houseId,
    required String memberId,
    required MemberRole role,
  }) async {
    try {
      await _houses
          .doc(houseId)
          .collection('members')
          .doc(memberId)
          .update({'role': role.wire});
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> removeMember({
    required String houseId,
    required String memberId,
  }) async {
    try {
      await _houses.doc(houseId).collection('members').doc(memberId).delete();
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  String _generateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(8, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }
}
