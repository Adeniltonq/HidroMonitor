import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'state/auth_controller.dart';
import 'ui/app_shell.dart';
import 'ui/screens/alerts_screen.dart';
import 'ui/screens/analytics_screen.dart';
import 'ui/screens/connection_screen.dart';
import 'ui/screens/consumption_screen.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/screens/diagnostics_screen.dart';
import 'ui/screens/history_screen.dart';
import 'ui/screens/houses_screen.dart';
import 'ui/screens/level_screen.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/members_screen.dart';
import 'ui/screens/pairing_screen.dart';
import 'ui/screens/pump_valve_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/verify_email_screen.dart';

GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    initialLocation: '/inicio',
    refreshListenable: auth,
    redirect: (context, state) {
      final signedIn = auth.isSignedIn;
      final loggingIn = state.matchedLocation == '/login';
      final verifying = state.matchedLocation == '/verificar-email';

      if (!signedIn) return loggingIn ? null : '/login';
      // Conta criada com e-mail/senha só libera o app após confirmar o e-mail.
      if (!auth.emailVerified) return verifying ? null : '/verificar-email';
      if (loggingIn || verifying) return '/casas';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/casas',
        builder: (context, state) => const HousesScreen(),
      ),
      GoRoute(
        path: '/verificar-email',
        builder: (context, state) => const VerifyEmailScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/inicio',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/nivel',
            builder: (context, state) => const LevelScreen(),
          ),
          GoRoute(
            path: '/bomba',
            builder: (context, state) => const PumpValveScreen(),
          ),
          GoRoute(
            path: '/alertas',
            builder: (context, state) => const AlertsScreen(),
          ),
          GoRoute(
            path: '/historico',
            builder: (context, state) => const HistoryScreen(),
          ),
          GoRoute(
            path: '/consumo',
            builder: (context, state) => const ConsumptionScreen(),
          ),
          GoRoute(
            path: '/analise',
            builder: (context, state) => const AnalyticsScreen(),
          ),
          GoRoute(
            path: '/conexao',
            builder: (context, state) => const ConnectionScreen(),
          ),
          GoRoute(
            path: '/config',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/diagnostico',
            builder: (context, state) => const DiagnosticsScreen(),
          ),
          GoRoute(
            path: '/pareamento',
            builder: (context, state) => const PairingScreen(),
          ),
          GoRoute(
            path: '/membros',
            builder: (context, state) => const MembersScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => _NotFoundScreen(location: state.uri.toString()),
  );
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Text('Tela não encontrada: $location'),
      ),
    );
  }
}
