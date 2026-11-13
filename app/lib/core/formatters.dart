import 'package:intl/intl.dart';

/// Formatadores pt-BR usados em toda a UI. Centralizados para manter
/// consistência de unidades (cm, L, %, dBm) e datas.
class Fmt {
  Fmt._();

  static final DateFormat _date = DateFormat('dd/MM/yyyy', 'pt_BR');
  static final DateFormat _time = DateFormat('HH:mm', 'pt_BR');
  static final DateFormat _dateTime = DateFormat('dd/MM HH:mm', 'pt_BR');
  static final NumberFormat _liters = NumberFormat('#,##0', 'pt_BR');
  static final NumberFormat _decimal = NumberFormat('#,##0.0', 'pt_BR');

  static String date(DateTime? value) => value == null ? '—' : _date.format(value);
  static String time(DateTime? value) => value == null ? '—' : _time.format(value);
  static String dateTime(DateTime? value) => value == null ? '—' : _dateTime.format(value);

  static String liters(num? value) =>
      value == null ? '—' : '${_liters.format(value)} L';

  static String decimals(num? value, {String suffix = ''}) =>
      value == null ? '—' : '${_decimal.format(value)}$suffix';

  static String percent(num? value) =>
      value == null ? '—' : '${_decimal.format(value)}%';

  static String cm(num? value) => decimals(value, suffix: ' cm');

  static String rssi(int? value) => value == null ? '—' : '$value dBm';

  /// Qualidade legível do sinal Wi-Fi (para o build de usuário).
  static String signal(int? value) {
    if (value == null) return '—';
    if (value >= -60) return 'Bom';
    if (value >= -75) return 'Médio';
    return 'Fraco';
  }

  /// Tempo relativo curto em pt-BR ("agora", "há 3 min", "há 2 h", "há 4 d").
  static String relative(DateTime? value, {DateTime? now}) {
    if (value == null) return 'nunca';
    final reference = now ?? DateTime.now();
    final diff = reference.difference(value);
    if (diff.isNegative) return 'agora';
    if (diff.inSeconds < 45) return 'agora';
    if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'há ${diff.inHours} h';
    return 'há ${diff.inDays} d';
  }

  static String duration(Duration value) {
    if (value.inSeconds < 60) return '${value.inSeconds}s';
    if (value.inMinutes < 60) return '${value.inMinutes} min';
    return '${value.inHours} h ${value.inMinutes.remainder(60)} min';
  }
}
