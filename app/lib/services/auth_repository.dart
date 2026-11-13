import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/errors.dart';

/// Autenticação do usuário final. O device (ESP32) usa uma instância
/// secundária do Firebase, isolada em `BleProvisioningService`.
class AuthRepository {
  AuthRepository({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  static const MethodChannel _configChannel =
      MethodChannel('hidromonitor/config');
  static bool _googleInitialized = false;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  String? get uid => _auth.currentUser?.uid;

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<UserCredential> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AppException('Não foi possível criar a conta.');
      }
      await user.updateDisplayName(name.trim());
      // Perfil espelha o usuário; regra permite create apenas do próprio uid.
      await _db.collection('users').doc(user.uid).set({
        'name': name.trim(),
        'email': email.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      // Confirmação de posse do e-mail (não bloqueia o cadastro se falhar).
      try {
        await user.sendEmailVerification();
      } on FirebaseAuthException {
        // a tela de verificação permite reenviar
      }
      return credential;
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  /// Login/criação de conta com Google **nativo** (sem navegador).
  ///
  /// O Web Client ID é lido do recurso `default_web_client_id` gerado pelo
  /// google-services.json (só existe depois de ativar o provedor Google no
  /// Firebase Console e regerar o arquivo).
  Future<UserCredential> signInWithGoogle() async {
    String? webClientId;
    try {
      webClientId =
          await _configChannel.invokeMethod<String>('getWebClientId');
    } on PlatformException {
      webClientId = null;
    } on MissingPluginException {
      webClientId = null;
    }

    if (webClientId == null || webClientId.isEmpty) {
      throw const AppException(
        'Login Google ainda não configurado. Ative o provedor Google em '
        'Firebase Console → Authentication → Sign-in method e regenere o '
        'google-services.json (flutterfire configure).',
      );
    }

    try {
      final google = GoogleSignIn.instance;
      if (!_googleInitialized) {
        await google.initialize(serverClientId: webClientId);
        _googleInitialized = true;
      }
      final account = await google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AppException(
          'O Google não retornou um ID token. Verifique o Web Client ID e a '
          'SHA-1 do app no Firebase Console.',
        );
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final userCredential = await _auth.signInWithCredential(credential);
      await _ensureProfile(userCredential.user);
      return userCredential;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const AppException('Login com Google cancelado.');
      }
      throw AppException(
        'Falha no Google Sign-In (${error.code.name}). '
        'Confira provedor Google, SHA-1 e google-services.json.',
        cause: error,
      );
    } on FirebaseAuthException catch (error) {
      switch (error.code) {
        case 'operation-not-allowed':
          throw const AppException(
            'Login com Google desativado. Ative o provedor Google no '
            'Firebase Console (Authentication → Sign-in method).',
          );
        case 'account-exists-with-different-credential':
          throw const AppException(
            'Já existe uma conta com este e-mail usando outro método. '
            'Entre com e-mail/senha.',
          );
        default:
          throw AppException(describeError(error), cause: error);
      }
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> _ensureProfile(User? user) async {
    if (user == null) return;
    try {
      final ref = _db.collection('users').doc(user.uid);
      final doc = await ref.get();
      if (doc.exists) return;
      final name = (user.displayName ?? '').trim();
      await ref.set({
        'name': name.isNotEmpty
            ? name
            : (user.email?.split('@').first ?? 'Usuário'),
        'email': user.email ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) throw const AppException('Sessão expirada.');
    if (user.emailVerified) return;
    try {
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> reloadUser() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await user.reload();
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> updateName(String name) async {
    final user = _auth.currentUser;
    if (user == null) throw const AppException('Sessão expirada.');
    try {
      await user.updateDisplayName(name.trim());
      await _db.collection('users').doc(user.uid).update({'name': name.trim()});
    } on FirebaseException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on FirebaseAuthException catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }
}
