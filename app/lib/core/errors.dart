import 'package:firebase_auth/firebase_auth.dart';

/// Erro de domínio com mensagem já em pt-BR para exibir na UI.
class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Converte erros do Firebase/BLE em mensagens acionáveis em pt-BR.
String describeError(Object error) {
  if (error is AppException) return error.message;

  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
        return 'E-mail inválido.';
      case 'user-disabled':
        return 'Esta conta foi desativada.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'E-mail ou senha incorretos.';
      case 'email-already-in-use':
        return 'Este e-mail já está cadastrado.';
      case 'weak-password':
        return 'Senha fraca: use ao menos 6 caracteres.';
      case 'too-many-requests':
        return 'Muitas tentativas. Aguarde alguns minutos e tente novamente.';
      case 'operation-not-allowed':
        return 'Login por e-mail/senha desativado no Firebase Auth. '
            'Ative o provedor no console.';
      case 'network-request-failed':
        return 'Sem conexão com a internet.';
      case 'requires-recent-login':
        return 'Faça login novamente para concluir esta ação.';
      default:
        return 'Falha de autenticação (${error.code}).';
    }
  }

  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'Sem permissão para esta operação. '
            'Verifique seu papel na casa.';
      case 'unavailable':
        return 'Sem conexão com o Firestore. Os dados em cache continuam visíveis.';
      case 'failed-precondition':
        return 'Consulta inválida ou índice ausente no Firestore.';
      case 'not-found':
        return 'Registro não encontrado.';
      case 'deadline-exceeded':
        return 'O servidor demorou demais para responder. Tente novamente.';
      case 'resource-exhausted':
        return 'Limite de uso do Firestore atingido. Tente mais tarde.';
      default:
        return 'Erro do Firestore (${error.code}).';
    }
  }

  return 'Ocorreu um erro inesperado. Tente novamente.';
}
