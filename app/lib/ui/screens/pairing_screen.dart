import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../ble/ble_provisioning_service.dart';
import '../../ble/provisioning_payload.dart';
import '../../core/app_config.dart';
import '../../core/errors.dart';
import '../../firebase_options.dart';
import '../../services/device_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

/// Wizard de provisionamento do ESP32 via BLE (Nordic UART Service).
///
/// SEGURANÇA: SSID, senha do Wi-Fi e senha da conta Firebase do device só
/// existem em memória durante esta tela. Não são persistidos, logados nem
/// enviados ao Firestore.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController(text: 'Caixa d\'água');
  final _serialController = TextEditingController();
  final _ssidController = TextEditingController();
  final _wifiPassController = TextEditingController();

  late final BleProvisioningService _service;
  StreamSubscription<ProvisioningStatus>? _statusSubscription;

  ProvisioningStatus _status =
      const ProvisioningStatus(phase: ProvisioningPhase.idle);
  ProvisioningPayload? _payload;
  String? _deviceId;
  String? _deviceUid;
  bool _preparing = false;
  bool _obscure = true;
  bool _showSecrets = false;
  String? _error;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _service = BleProvisioningService();
    _statusSubscription = _service.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      if (status.isSuccess) _clearSecrets();
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _service.dispose();
    _payload?.wipe();
    _payload = null;
    _nameController.dispose();
    _serialController.dispose();
    _ssidController.dispose();
    _wifiPassController.dispose();
    super.dispose();
  }

  bool get _busy => _preparing || _status.isBusy;

  void _clearSecrets() {
    _payload?.wipe();
    _payload = null;
    _ssidController.clear();
    _wifiPassController.clear();
    _showSecrets = false;
  }

  Future<bool> _confirmPermissions() async {
    if (!Platform.isAndroid) return true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Permissão de Bluetooth'),
        content: const Text(
          'Para encontrar e configurar o dispositivo, o HidroMonitor precisa usar o '
          'Bluetooth do celular. Os dados de Wi-Fi são enviados diretamente ao '
          'dispositivo por Bluetooth e não são gravados no aplicativo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Agora não'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Permitir'),
          ),
        ],
      ),
    );
    if (accepted != true) return false;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final granted = statuses.values
        .every((status) => status.isGranted || status.isLimited);
    if (granted) {
      // Android 11 ou inferior: varrer BLE exige permissão de LOCALIZAÇÃO
      // (ACCESS_FINE_LOCATION com maxSdkVersion=30). No Android 12+ o pedido
      // é inócuo — a permissão não está no manifest e o sistema nega na hora.
      final location = await Permission.locationWhenInUse.status;
      if (location.isDenied) {
        await Permission.locationWhenInUse.request();
      }
      return true;
    }

    final permanentlyDenied =
        statuses.values.any((status) => status.isPermanentlyDenied);
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Bluetooth bloqueado'),
        content: Text(
          permanentlyDenied
              ? 'As permissões foram negadas permanentemente. Abra as '
                  'configurações do aplicativo e libere "Dispositivos próximos".'
              : 'Sem a permissão de Bluetooth não é possível adicionar o dispositivo.',
        ),
        actions: [
          if (permanentlyDenied)
            FilledButton(
              onPressed: () {
                openAppSettings();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Abrir configurações'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<({String uid, String email, String password})>
      _prepareDeviceCredential() async {
    const appName = 'device-provisioning';
    final existing =
        Firebase.apps.where((app) => app.name == appName).toList();
    final app = existing.isNotEmpty
        ? existing.first
        : await Firebase.initializeApp(
            name: appName,
            options: DefaultFirebaseOptions.currentPlatform,
          );
    final auth = FirebaseAuth.instanceFor(app: app);

    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    String token(int length) => List.generate(
          length,
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();

    final email = 'dev-${token(8)}@devices.local';
    final password = 'H!${token(24)}';
    final credential = await auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final uid = credential.user?.uid;
    await auth.signOut();
    if (uid == null) {
      throw const AppException('Não foi possível criar a credencial do device.');
    }
    return (uid: uid, email: email, password: password);
  }

  Future<void> _start({bool retry = false}) async {
    if (_busy) return;
    if (!retry) {
      FocusScope.of(context).unfocus();
      if (!(_formKey.currentState?.validate() ?? false)) return;
      if (!await _confirmPermissions()) return;
      if (!mounted) return;
    }

    final controller = context.read<HouseController>();
    final auth = context.read<AuthController>();
    final repo = context.read<DeviceRepository>();
    final house = controller.selectedHouse;
    final user = auth.user;
    if (house == null || user == null) {
      setState(() => _error = 'Selecione uma casa antes de adicionar o dispositivo.');
      return;
    }
    if (!controller.canEditConfig) {
      setState(() => _error =
          'Seu papel nesta casa não permite cadastrar dispositivos.');
      return;
    }

    setState(() {
      _preparing = true;
      _error = null;
    });

    try {
      if (_deviceId == null || _deviceUid == null) {
        final credential = await _prepareDeviceCredential();
        _deviceUid = credential.uid;
        _deviceId = await repo.createDevice(
          houseId: house.id,
          name: _nameController.text.trim(),
          serial: _serialController.text.trim(),
          deviceUid: credential.uid,
          byUid: user.uid,
        );
        _payload = ProvisioningPayload(
          provId: _randomProvId(),
          ssid: _ssidController.text.trim(),
          wifiPassword: _wifiPassController.text,
          fbEmail: credential.email,
          fbPassword: credential.password,
          houseId: house.id,
          deviceId: _deviceId!,
          serial: _serialController.text.trim(),
        );
      }

      _startedAt = DateTime.now();
      await _service.retry();
      final success = await _service.provision(
        payload: _payload!,
        confirmCloud: () => _confirmCloud(house.id, _deviceId!),
      );
      if (success) {
        if (!mounted) return;
        setState(_clearSecrets);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  String _randomProvId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      12,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  /// Confirma o primeiro contato autenticado do device na nuvem (até 60 s).
  Future<bool> _confirmCloud(String houseId, String deviceId) async {
    final since = _startedAt ?? DateTime.now();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('houses')
            .doc(houseId)
            .collection('devices')
            .doc(deviceId)
            .get(const GetOptions(source: Source.server));
        final data = snapshot.data();
        final lastSeen = data?['lastSeen'];
        final fwVersion = data?['fwVersion'];
        final seen = lastSeen is Timestamp && lastSeen.toDate().isAfter(since);
        // O firmware também grava fwVersion neste primeiro contato; serve de
        // confirmação quando o relógio do device está alguns segundos atrás.
        final firmwareTouched =
            fwVersion is String && fwVersion.isNotEmpty && fwVersion != 'aguardando';
        if (seen || firmwareTouched) return true;
      } on FirebaseException {
        // sem rede no momento: segue tentando até o prazo
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<HouseController>();
    if (controller.selectedHouse == null) {
      return const EmptyState(
        icon: Icons.home_work_outlined,
        title: 'Selecione uma casa',
        message: 'É preciso uma casa para cadastrar o dispositivo.',
      );
    }
    if (!controller.canEditConfig) {
      return const EmptyState(
        icon: Icons.lock_outline,
        title: 'Sem permissão',
        message:
            'Apenas proprietários e administradores podem adicionar dispositivos.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_status.isSuccess)
          _SuccessCard(
            onDone: () => context.go('/inicio'),
            deviceName: _nameController.text.trim(),
          )
        else ...[
          SectionCard(
            title: 'Adicionar dispositivo',
            subtitle: 'Ligue o dispositivo perto de você, no modo de configuração '
                'inicial (mensagem no OLED). Não precisa parear antes nas '
                'configurações de Bluetooth do celular: o app conecta sozinho '
                'ao "HIDRO".',
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _nameController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Nome da caixa',
                      prefixIcon: Icon(Icons.sensors),
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Informe um nome.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _serialController,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Número do dispositivo',
                      prefixIcon: Icon(Icons.qr_code),
                      helperText: 'Ex.: CAIXA-01 (etiqueta do dispositivo)',
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Informe o serial.'
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Rede Wi-Fi (2,4 GHz)',
            subtitle: 'Enviada somente ao dispositivo, por Bluetooth.',
            child: Column(
              children: [
                TextFormField(
                  controller: _ssidController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Nome da rede (SSID)',
                    prefixIcon: Icon(Icons.wifi),
                  ),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Informe o SSID.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _wifiPassController,
                  enabled: !_busy,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Senha do Wi-Fi',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Mostrar' : 'Ocultar',
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (value) => (value ?? '').isEmpty
                      ? 'Informe a senha do Wi-Fi.'
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  'A senha não é salva no Firestore, em logs ou no histórico. '
                  'Ela existe apenas nesta tela até o envio.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _start(),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bluetooth_searching),
            label: Text(_busy ? 'Configurando…' : 'Iniciar configuração'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_status.phase != ProvisioningPhase.idle) ...[
            const SizedBox(height: 16),
            _ProgressCard(status: _status, prepared: _deviceId != null),
          ],
          if (_status.isError) ...[
            const SizedBox(height: 12),
            _ErrorCard(
              status: _status,
              onRetry: () => _start(retry: true),
            ),
          ],
          if (kShowTechnicalTools) ...[
            const SizedBox(height: 16),
            _ManualFallback(
              payload: _payload,
              showSecrets: _showSecrets,
              onToggleSecrets: () =>
                  setState(() => _showSecrets = !_showSecrets),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'O app encontra o dispositivo, envia os dados com segurança e '
            'confirma a conexão na nuvem. Mantenha o celular próximo durante '
            'a configuração.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.status, required this.prepared});

  final ProvisioningStatus status;
  final bool prepared;

  @override
  Widget build(BuildContext context) {
    final success = status.phase == ProvisioningPhase.success;
    final steps = <(String, bool)>[
      ('Criar credencial e cadastro do device', prepared),
      (
        'Procurar e conectar ao dispositivo',
        success || status.phase.index >= 3,
      ),
      (
        'Enviar dados de configuração',
        success || status.phase.index >= 4,
      ),
      (
        'Wi-Fi e Firebase no dispositivo',
        success || status.phase.index >= 5,
      ),
      ('Confirmar conexão na nuvem', success),
    ];
    return SectionCard(
      title: 'Progresso',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    step.$2 ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18,
                    color: step.$2
                        ? Colors.green.shade600
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(step.$1)),
                ],
              ),
            ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: status.progress.clamp(0.0, 1.0)),
          const SizedBox(height: 8),
          Text(
            status.message.isEmpty ? 'Aguardando…' : status.message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.status, required this.onRetry});

  final ProvisioningStatus status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(
        children: [
          Icon(Icons.error_outline, color: scheme.error, size: 32),
          const SizedBox(height: 8),
          Text(
            status.message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
          if (status.errorCode != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Código: ${status.errorCode} · etapa: ${status.stage.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar novamente'),
          ),
        ],
      ),
    );
  }
}

class _ManualFallback extends StatelessWidget {
  const _ManualFallback({
    required this.payload,
    required this.showSecrets,
    required this.onToggleSecrets,
  });

  final ProvisioningPayload? payload;
  final bool showSecrets;
  final VoidCallback onToggleSecrets;

  @override
  Widget build(BuildContext context) {
    if (payload == null) return const SizedBox.shrink();
    final json = const JsonEncoder.withIndent('  ').convert(payload!.toJson());
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Alternativa manual',
      subtitle: 'Uso apenas por suporte, se o Bluetooth falhar.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'O conteúdo abaixo contém a senha do Wi-Fi e a credencial do '
              'dispositivo. Não compartilhe, não tire print e o utilize apenas '
              'durante o pareamento.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Exibir segredos e QR code'),
            value: showSecrets,
            onChanged: (_) => onToggleSecrets(),
          ),
          if (showSecrets) ...[
            Center(
              child: QrImageView(
                data: json,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: json));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('JSON copiado — apague a área de transferência '
                        'depois do uso.'),
                  ),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copiar JSON'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({required this.onDone, required this.deviceName});

  final VoidCallback onDone;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        children: [
          Icon(Icons.check_circle, size: 64, color: Colors.green.shade600),
          const SizedBox(height: 12),
          Text(
            'Dispositivo adicionado!',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '$deviceName já está conectado e começou a enviar leituras. '
            'O dispositivo conclui a configuração sozinho.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.dashboard_outlined),
            label: const Text('Ir para o início'),
          ),
        ],
      ),
    );
  }
}
