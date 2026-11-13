import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../services/auth_repository.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._repository) {
    _subscription = _repository.authStateChanges.listen((user) {
      _user = user;
      _initializing = false;
      notifyListeners();
    });
  }

  final AuthRepository _repository;
  StreamSubscription<User?>? _subscription;

  User? _user;
  bool _initializing = true;
  bool _busy = false;
  String? _error;

  User? get user => _user;
  bool get isInitializing => _initializing;
  bool get isSignedIn => _user != null;
  bool get isBusy => _busy;
  String? get error => _error;
  bool get emailVerified => _user?.emailVerified ?? false;

  String get displayName {
    final name = _user?.displayName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    final email = _user?.email;
    if (email != null && email.contains('@')) return email.split('@').first;
    return 'Usuário';
  }

  String get email => _user?.email ?? '';

  Future<bool> signIn({required String email, required String password}) async {
    _setBusy(true);
    try {
      await _repository.signIn(email: email, password: password);
      return true;
    } catch (error) {
      _error = describeError(error);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<bool> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    _setBusy(true);
    try {
      await _repository.signUp(name: name, email: email, password: password);
      return true;
    } catch (error) {
      _error = describeError(error);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<bool> signInWithGoogle() async {
    _setBusy(true);
    try {
      await _repository.signInWithGoogle();
      return true;
    } catch (error) {
      _error = describeError(error);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> sendVerificationEmail() async {
    try {
      await _repository.sendEmailVerification();
    } catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> reloadUser() async {
    try {
      await _repository.reloadUser();
      _user = _repository.currentUser;
      notifyListeners();
    } catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> updateName(String name) async {
    try {
      await _repository.updateName(name);
    } catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      await _repository.sendPasswordReset(email);
    } catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  Future<void> signOut() async {
    try {
      await _repository.signOut();
    } catch (error) {
      throw AppException(describeError(error), cause: error);
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void _setBusy(bool value) {
    _busy = value;
    if (value) _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
