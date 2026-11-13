import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'services/auth_repository.dart';
import 'services/device_repository.dart';
import 'services/house_repository.dart';
import 'state/auth_controller.dart';
import 'state/house_controller.dart';
import 'state/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Dados de formatação pt-BR (números, datas e meses).
  await initializeDateFormatting('pt_BR');

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Persistência offline do Firestore (padrão no Android, explicitada aqui).
  // Deve ser configurada antes da primeira operação em Firestore.
  try {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  } on Exception {
    // Se já houver operação iniciada, mantém os defaults do plugin.
  }

  runApp(const HidroMonitorBootstrap());
}

class HidroMonitorBootstrap extends StatelessWidget {
  const HidroMonitorBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthRepository>(create: (_) => AuthRepository()),
        Provider<HouseRepository>(create: (_) => HouseRepository()),
        Provider<DeviceRepository>(create: (_) => DeviceRepository()),
        ChangeNotifierProvider<AuthController>(
          create: (context) => AuthController(context.read<AuthRepository>()),
        ),
        ChangeNotifierProvider<ThemeController>(
          create: (_) => ThemeController(),
        ),
        ChangeNotifierProxyProvider<AuthController, HouseController>(
          create: (context) => HouseController(
            houseRepository: context.read<HouseRepository>(),
            deviceRepository: context.read<DeviceRepository>(),
          ),
          update: (context, auth, previous) {
            final controller = previous ??
                HouseController(
                  houseRepository: context.read<HouseRepository>(),
                  deviceRepository: context.read<DeviceRepository>(),
                );
            // Evita notificar durante o build do provider.
            scheduleMicrotask(() => controller.updateAuth(auth.user));
            return controller;
          },
        ),
      ],
      child: const HidroMonitorApp(),
    );
  }
}
