import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../models/device.dart';
import '../../models/house.dart';
import '../../services/device_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/house_controller.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<HouseController>();
    return HouseRequired(
      builder: (context) => DeviceRequired(
        builder: (context, houseId, deviceId) {
          final repo = context.read<DeviceRepository>();
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: repo.watchDeviceDoc(houseId, deviceId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorState(
                  message: describeError(snapshot.error!),
                  onRetry: () => GoRouter.of(context).refresh(),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final device = Device.fromDoc(snapshot.data!);
              if (!controller.canEditConfig) {
                return _ReadOnlyConfig(device: device);
              }
              return _SettingsForm(
                key: ValueKey('${device.id}-${device.config.configVersion}'),
                houseId: houseId,
                device: device,
              );
            },
          );
        },
      ),
    );
  }
}

class _ReadOnlyConfig extends StatelessWidget {
  const _ReadOnlyConfig({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final config = device.config;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Somente leitura',
          child: Text(
            'Seu papel nesta casa é Visualizador. Você pode acompanhar os dados, '
            'mas não alterar parâmetros. Peça a um administrador para mudar seu papel.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Configuração atual',
          child: Column(
            children: [
              InfoTile(
                label: 'Intervalo de publicação',
                value: '${config.reportIntervalSec} s',
                icon: Icons.timer_outlined,
              ),
              InfoTile(
                label: 'Liga (distância)',
                value: Fmt.cm(config.limits.ligaCm),
                icon: Icons.vertical_align_bottom,
              ),
              InfoTile(
                label: 'Desliga (distância)',
                value: Fmt.cm(config.limits.desligaCm),
                icon: Icons.vertical_align_top,
              ),
              InfoTile(
                label: 'Altura da caixa',
                value: Fmt.cm(config.tank.heightCm),
                icon: Icons.height,
              ),
              InfoTile(
                label: 'Capacidade',
                value: Fmt.liters(config.tank.capacityL),
                icon: Icons.water_drop_outlined,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsForm extends StatefulWidget {
  const _SettingsForm({
    super.key,
    required this.houseId,
    required this.device,
  });

  final String houseId;
  final Device device;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  final _formKey = GlobalKey<FormState>();
  late TankFormat _format;
  late final TextEditingController _height;
  late final TextEditingController _diameter;
  late final TextEditingController _length;
  late final TextEditingController _width;
  late final TextEditingController _capacity;
  late final TextEditingController _sensorOffset;
  late final TextEditingController _minRange;
  late final TextEditingController _maxRange;
  late final TextEditingController _liga;
  late final TextEditingController _desliga;
  late final TextEditingController _interval;
  late final TextEditingController _sensorWindow;
  late final TextEditingController _lowLevel;
  late final TextEditingController _offlineAfter;
  late final TextEditingController _sensorFailAfter;
  late bool _manualVolume;
  late List<VolumePoint> _volumePoints;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final config = widget.device.config;
    _format = config.tank.format;
    _height = _txt(config.tank.heightCm);
    _diameter = _txt(config.tank.diameterCm ?? 100);
    _length = _txt(config.tank.lengthCm ?? 100);
    _width = _txt(config.tank.widthCm ?? 100);
    _capacity = _txt(config.tank.capacityL);
    _sensorOffset = _txt(config.tank.sensorOffsetCm);
    _minRange = _txt(config.tank.minRangeCm);
    _maxRange = _txt(config.tank.maxRangeCm);
    _liga = _txt(config.limits.ligaCm);
    _desliga = _txt(config.limits.desligaCm);
    _interval = _txt(config.reportIntervalSec.toDouble());
    _sensorWindow = _txt(config.sensorWindowSec.toDouble());
    _lowLevel = _txt(config.alerts.lowLevelPercent.toDouble());
    _offlineAfter = _txt(config.alerts.offlineAfterSec.toDouble());
    _sensorFailAfter = _txt(config.alerts.sensorFailAfterSec.toDouble());
    _manualVolume = config.tank.calibration.length >= 2;
    _volumePoints = config.tank.calibration.isNotEmpty
        ? [...config.tank.calibration]
        : _linearPoints(config.tank.capacityL);
  }

  TextEditingController _txt(num value) => TextEditingController(
        text: value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toString(),
      );

  @override
  void dispose() {
    for (final controller in [
      _height,
      _diameter,
      _length,
      _width,
      _capacity,
      _sensorOffset,
      _minRange,
      _maxRange,
      _liga,
      _desliga,
      _interval,
      _sensorWindow,
      _lowLevel,
      _offlineAfter,
      _sensorFailAfter,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Texto auxiliar com o nível (%) equivalente a uma distância em cm.
  String _nivelEquivalente(TextEditingController controller, String qual) {
    final altura = _value(_height);
    final offset = _value(_sensorOffset);
    final distancia = _value(controller);
    if (altura <= 0 || distancia <= 0) return '—';
    final coluna = (altura + offset - distancia).clamp(0.0, altura);
    final pct = (coluna / altura * 100);
    final acao = qual == 'liga' ? 'liga' : 'desliga';
    return '$acao ≈ ${pct.toStringAsFixed(0)}% de nível '
        '(${altura.toStringAsFixed(0)} cm de caixa)';
  }

  double _value(TextEditingController controller) =>
      double.tryParse(controller.text.replaceAll(',', '.')) ?? 0;

  List<VolumePoint> _sortedPoints() {
    final points = [..._volumePoints]
      ..sort((a, b) => a.percent.compareTo(b.percent));
    return points;
  }

  List<VolumePoint> _linearPoints(double capacity, {int step = 10}) {
    final points = <VolumePoint>[];
    for (var percent = 0; percent <= 100; percent += step) {
      points.add(
        VolumePoint(
          percent: percent.toDouble(),
          liters: capacity * percent / 100.0,
        ),
      );
    }
    if (points.last.percent < 100) {
      points.add(VolumePoint(percent: 100, liters: capacity));
    }
    return points;
  }

  String? _validateVolume() {
    if (!_manualVolume) return null;
    final points = _sortedPoints();
    if (points.length < 2) {
      return 'Informe ao menos dois pontos (0% e 100%).';
    }
    if (points.first.percent > 0 || points.last.percent < 100) {
      return 'A tabela precisa ter pontos em 0% e 100%.';
    }
    for (var i = 1; i < points.length; i++) {
      if (points[i].liters + 0.01 < points[i - 1].liters) {
        return 'Os litros não podem diminuir quando o nível sobe '
            '(${Fmt.percent(points[i - 1].percent)} → '
            '${Fmt.percent(points[i].percent)}).';
      }
    }
    return null;
  }

  Future<void> _editVolumePoint([VolumePoint? initial]) async {
    final percentController = TextEditingController(
      text: initial == null ? '' : initial.percent.toString(),
    );
    final litersController = TextEditingController(
      text: initial == null ? '' : initial.liters.toString(),
    );
    final result = await showDialog<VolumePoint>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initial == null ? 'Adicionar ponto' : 'Editar ponto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: percentController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Nível (%)',
                hintText: 'Ex.: 50',
                suffixText: '%',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: litersController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Quantidade de água (litros)',
                hintText: 'Ex.: 480',
                suffixText: 'L',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Informe o volume real medido/estimado naquele nível.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final percent = double.tryParse(
                percentController.text.replaceAll(',', '.'),
              );
              final liters = double.tryParse(
                litersController.text.replaceAll(',', '.'),
              );
              if (percent == null ||
                  liters == null ||
                  percent < 0 ||
                  percent > 100 ||
                  liters < 0) {
                return;
              }
              Navigator.of(dialogContext).pop(
                VolumePoint(percent: percent, liters: liters),
              );
            },
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (initial != null) {
        _volumePoints.remove(initial);
      }
      _volumePoints.removeWhere(
        (point) => (point.percent - result.percent).abs() < 0.001,
      );
      _volumePoints.add(result);
      _volumePoints.sort((a, b) => a.percent.compareTo(b.percent));
    });
  }

  Future<void> _autoFillVolume() async {
    final step = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Preencher automaticamente'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(1),
            child: const Text('A cada 1% (101 pontos, mais preciso)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(5),
            child: const Text('A cada 5% (21 pontos)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(10),
            child: const Text('A cada 10% (11 pontos)'),
          ),
        ],
      ),
    );
    if (step == null || !mounted) return;
    setState(() {
      _volumePoints = _linearPoints(_value(_capacity), step: step);
    });
  }

  /// Impede limites que nunca seriam atingidos (ex.: ligar em 80 cm numa caixa
  /// de 80 cm de altura — a bomba jamais ligaria).
  String? _validateLimits() {
    final altura = _value(_height);
    final liga = _value(_liga);
    final desliga = _value(_desliga);
    final minRange = _value(_minRange);
    if (altura <= 0) return 'Informe a altura da caixa.';
    if (liga >= altura) {
      return 'O "ligar" (${liga.toStringAsFixed(0)} cm) precisa ser menor que a '
          'altura da caixa (${altura.toStringAsFixed(0)} cm). Com esse valor a '
          'bomba nunca ligaria.';
    }
    if (desliga < minRange) {
      return 'O "desligar" (${desliga.toStringAsFixed(0)} cm) deve ser maior ou '
          'igual à distância mínima do sensor '
          '(${minRange.toStringAsFixed(0)} cm).';
    }
    if (liga <= desliga) {
      return 'O "ligar" deve ser maior que o "desligar" '
          '(histerese).';
    }
    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final limitsError = _validateLimits();
    if (limitsError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(limitsError)));
      return;
    }
    final volumeError = _validateVolume();
    if (volumeError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(volumeError)));
      return;
    }
    final config = widget.device.config;
    final updated = config.copyWith(
      reportIntervalSec: _value(_interval).round(),
      sensorWindowSec: _value(_sensorWindow).round(),
      limits: LimitConfig(
        ligaCm: _value(_liga),
        desligaCm: _value(_desliga),
      ),
      tank: config.tank.copyWith(
        format: _format,
        heightCm: _value(_height),
        capacityL: _value(_capacity),
        sensorOffsetCm: _value(_sensorOffset),
        minRangeCm: _value(_minRange),
        maxRangeCm: _value(_maxRange),
        diameterCm: _value(_diameter),
        lengthCm: _value(_length),
        widthCm: _value(_width),
        calibration:
            _manualVolume ? _sortedPoints() : const <VolumePoint>[],
      ),
      alerts: AlertThresholds(
        lowLevelPercent: _value(_lowLevel).round(),
        offlineAfterSec: _value(_offlineAfter).round(),
        sensorFailAfterSec: _value(_sensorFailAfter).round(),
      ),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirmar alteração'),
        content: const Text(
          'Os novos parâmetros serão gravados e lidos pelo dispositivo no próximo '
          'ciclo. Este salvamento altera só parâmetros: não aciona a bomba agora. '
          'O controle manual fica na tela Bomba e válvula.\n\n'
          'Revise os limites com cuidado — valores incoerentes podem deixar a '
          'caixa sem reposição. A alteração será registrada no histórico de '
          'configuração (configLog) com o valor anterior e o novo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Gravar configuração'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await context.read<DeviceRepository>().saveConfig(
            houseId: widget.houseId,
            device: widget.device,
            newConfig: updated,
            byUid: auth.user?.uid ?? '',
            byName: auth.displayName,
          );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Configuração salva (versão ${config.configVersion + 1}).',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.device.config;
    final scheme = Theme.of(context).colorScheme;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Estes parâmetros são lidos pelo dispositivo. O app não aciona '
                    'bomba nem válvula automaticamente.',
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Geometria da caixa',
            subtitle: 'Base para converter distância em litros',
            child: Column(
              children: [
                DropdownButtonFormField<TankFormat>(
                  initialValue: _format,
                  decoration: const InputDecoration(labelText: 'Formato'),
                  items: [
                    for (final format in TankFormat.values)
                      DropdownMenuItem(
                        value: format,
                        child: Text(format.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _format = value);
                  },
                ),
                const SizedBox(height: 12),
                _field(_height, 'Altura interna (cm)', suffix: 'cm'),
                if (_format == TankFormat.cilindro) ...[
                  const SizedBox(height: 12),
                  _field(_diameter, 'Diâmetro (cm)', suffix: 'cm'),
                ],
                if (_format == TankFormat.retangular) ...[
                  const SizedBox(height: 12),
                  _field(_length, 'Comprimento (cm)', suffix: 'cm'),
                  const SizedBox(height: 12),
                  _field(_width, 'Largura (cm)', suffix: 'cm'),
                ],
                const SizedBox(height: 12),
                _field(_capacity, 'Capacidade (litros)', suffix: 'L'),
                const SizedBox(height: 12),
                _field(
                  _sensorOffset,
                  'Offset do sensor (cm)',
                  suffix: 'cm',
                  helper: 'Distância do sensor até o topo da caixa',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _minRange,
                        'Distância mín. (cm)',
                        suffix: 'cm',
                        helper: 'Zona cega — default 25',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        _maxRange,
                        'Distância máx. (cm)',
                        suffix: 'cm',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _volumeSection(context),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Limites de acionamento (autônomos)',
            subtitle: 'Distância do sensor até a água',
            child: Column(
              children: [
                _field(
                  _liga,
                  'Ligar quando a distância for ≥ (cm)',
                  suffix: 'cm',
                  helper: _nivelEquivalente(_liga, 'liga'),
                ),
                const SizedBox(height: 12),
                _field(
                  _desliga,
                  'Desligar quando a distância for ≤ (cm)',
                  suffix: 'cm',
                  helper: _nivelEquivalente(_desliga, 'desliga'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Distância é do sensor até a água: quanto maior, mais vazia '
                  'a caixa. O "ligar" deve ser menor que a altura da caixa '
                  '(senão nunca é atingido) e maior que o "desligar".',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Publicação e alertas',
            child: Column(
              children: [
                _field(
                  _interval,
                  'Intervalo de publicação (s)',
                  suffix: 's',
                  helper: 'Entre 15 e 3600 — o dispositivo lê a cada ciclo',
                ),
                const SizedBox(height: 12),
                _field(
                  _sensorWindow,
                  'Janela de medição (s)',
                  suffix: 's',
                  helper:
                      'Tempo de coleta antes da média (5–60; padrão 20). '
                      'O dispositivo publica a média das amostras.',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _lowLevel,
                        'Nível baixo (%)',
                        suffix: '%',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        _offlineAfter,
                        'Offline após (s)',
                        suffix: 's',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(
                  _sensorFailAfter,
                  'Falha do sensor após (s)',
                  suffix: 's',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Versão das configurações',
            child: Column(
              children: [
                InfoTile(
                  label: 'Versão atual',
                  value: '${config.configVersion}',
                  icon: Icons.numbers,
                ),
                InfoTile(
                  label: 'Última atualização',
                  value: Fmt.dateTime(config.updatedAt),
                  icon: Icons.schedule,
                ),
                InfoTile(
                  label: 'Atualizado por',
                  value: config.updatedBy ?? '—',
                  icon: Icons.person_outline,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Salvando…' : 'Salvar configuração'),
          ),
          const SizedBox(height: 24),
          _dangerZone(context),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Exclusão definitiva do dispositivo (somente proprietário da casa).
  Widget _dangerZone(BuildContext context) {
    final role = context.watch<HouseController>().role;
    if (role != MemberRole.owner) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Zona de risco',
      subtitle: 'Ações irreversíveis',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Excluir o dispositivo apaga também todas as leituras, eventos e '
            'comandos dele. O ESP32 para de enviar dados e só volta pareando '
            'novamente.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.error,
              side: BorderSide(color: scheme.error),
            ),
            onPressed: () => _deleteDevice(context),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Excluir dispositivo'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteDevice(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir dispositivo?'),
        content: Text(
          'O dispositivo "${widget.device.name}" e TODO o histórico dele serão '
          'apagados. Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Excluir definitivamente'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final repo = context.read<DeviceRepository>();
    final progress = ValueNotifier<String>('Apagando…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (context, value, _) => Text(value),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      await repo.deleteDevice(
        houseId: widget.houseId,
        deviceId: widget.device.id,
        onProgress: (label, removidos) {
          final nome = switch (label) {
            'readings' => 'leituras',
            'events' => 'eventos',
            'commands' => 'comandos',
            _ => label,
          };
          progress.value = 'Apagando $nome… ($removidos)';
        },
      );
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await context.read<HouseController>().refresh();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dispositivo "${widget.device.name}" excluído.')),
      );
      context.go('/inicio');
    } catch (error) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      progress.dispose();
    }
  }

  Widget _volumeSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Mostrar em litros',
      subtitle:
          'Informe manualmente quantos litros existem em cada nível. O app '
          'interpola entre os pontos.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _manualVolume,
            title: const Text('Usar tabela manual de litros'),
            subtitle: Text(
              _manualVolume
                  ? '${_volumePoints.length} ponto(s) — interpolação entre eles'
                  : 'Volume linear pela capacidade informada',
            ),
            onChanged: (value) {
              setState(() {
                _manualVolume = value;
                if (value && _volumePoints.length < 2) {
                  _volumePoints = _linearPoints(_value(_capacity));
                }
              });
            },
          ),
          if (_manualVolume) ...[
            const Divider(),
            for (final point in _sortedPoints())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                onTap: () => _editVolumePoint(point),
                leading: Icon(
                  Icons.water_drop_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                title: Text('${Fmt.percent(point.percent)} do nível'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(Fmt.liters(point.liters)),
                    IconButton(
                      tooltip: 'Remover ponto',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(
                        () => _volumePoints.remove(point),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _editVolumePoint,
                  icon: const Icon(Icons.add),
                  label: const Text('Adicionar ponto'),
                ),
                TextButton.icon(
                  onPressed: _autoFillVolume,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Preencher automático'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Toque em um ponto para editar. Use 0%, 25%, 50%, 75% e 100% ou '
              'preencha a cada 1% para informar litros exatos por nível.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? suffix,
    String? helper,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        helperText: helper,
        helperMaxLines: 2,
      ),
      validator: (value) {
        final parsed = double.tryParse((value ?? '').replaceAll(',', '.'));
        if (parsed == null || parsed < 0) return 'Informe um número válido.';
        return null;
      },
    );
  }
}
