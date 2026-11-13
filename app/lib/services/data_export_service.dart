import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Resultado da exportação do cache offline do Firestore.
class DataExportResult {
  const DataExportResult({
    required this.zipBytes,
    required this.fileName,
    required this.counts,
    required this.errors,
    required this.exportedAt,
  });

  final Uint8List zipBytes;
  final String fileName;
  final Map<String, int> counts;
  final List<String> errors;
  final DateTime exportedAt;

  int get totalDocuments =>
      counts.values.fold<int>(0, (total, value) => total + value);

  bool get hasData => totalDocuments > 0;
}

/// Exporta o que já está no cache offline do Firestore para CSV.
///
/// Importante: usa sempre `Source.cache`, então **não consome a cota de
/// leitura** do Firestore. O preço é que só saem os documentos que o app já
/// tinha baixado antes (dashboards, históricos abertos, etc.).
class DataExportService {
  DataExportService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<DataExportResult> exportCached({
    required String uid,
    required List<({String id, String name})> houses,
    void Function(String message)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final files = <String, String>{};
    final counts = <String, int>{};
    final errors = <String>[];

    void progress(String message) => onProgress?.call(message);

    // ---------------------------------------------------------------------
    // Casas: usa a lista do controller e completa com o cache se necessário.
    // ---------------------------------------------------------------------
    progress('Lendo casas...');
    final houseMap = <String, ({String id, String name})>{
      for (final house in houses) house.id: house,
    };

    if (houseMap.isEmpty) {
      final memberDocs = await _cachedQuery(
        _db.collectionGroup('members').where('uid', isEqualTo: uid),
        'members (casas do usuário)',
        errors,
      );
      for (final doc in memberDocs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
        final parent = doc.reference.parent.parent;
        if (parent != null && !houseMap.containsKey(parent.id)) {
          houseMap[parent.id] = (id: parent.id, name: parent.id);
        }
      }
    }

    final houseRows = <Map<String, String>>[];
    for (final entry in houseMap.values) {
      final doc = await _cachedDoc(
        _db.collection('houses').doc(entry.id),
        'houses/${entry.id}',
        errors,
      );
      final row = <String, String>{
        '_house_id': entry.id,
        '_house_name': entry.name,
      };
      if (doc != null && doc.exists) {
        row['_id'] = doc.id;
        row['_path'] = doc.reference.path;
        _flattenInto(row, '', doc.data() ?? const <String, dynamic>{});
      } else {
        row['_id'] = entry.id;
        row['_path'] = 'houses/${entry.id}';
        row['name'] = entry.name;
      }
      houseRows.add(row);
    }
    _addCsv(files, counts, 'houses.csv', houseRows);

    // ---------------------------------------------------------------------
    // Usuário logado.
    // ---------------------------------------------------------------------
    progress('Lendo usuário...');
    final userDoc = await _cachedDoc(
      _db.collection('users').doc(uid),
      'users/$uid',
      errors,
    );
    if (userDoc != null && userDoc.exists) {
      final row = <String, String>{
        '_id': userDoc.id,
        '_path': userDoc.reference.path,
      };
      _flattenInto(row, '', userDoc.data() ?? const <String, dynamic>{});
      _addCsv(files, counts, 'users.csv', [row]);
    } else {
      counts['users.csv'] = 0;
    }

    // ---------------------------------------------------------------------
    // Subcoleções de cada casa + dispositivos.
    // ---------------------------------------------------------------------
    for (final house in houseMap.values) {
      final houseRef = _db.collection('houses').doc(house.id);
      final prefix = 'houses/${house.id}';

      for (final collectionName in const [
        'members',
        'invites',
        'alerts',
        'configLog',
      ]) {
        progress('Lendo ${house.name} · $collectionName...');
        await _exportQuery(
          files: files,
          counts: counts,
          errors: errors,
          path: '$prefix/$collectionName.csv',
          query: houseRef.collection(collectionName),
          label: '$prefix/$collectionName',
          extra: {
            '_house_id': house.id,
            '_house_name': house.name,
          },
        );
      }

      progress('Lendo ${house.name} · dispositivos...');
      final devices = await _cachedQuery(
        houseRef.collection('devices'),
        '$prefix/devices',
        errors,
      );
      final deviceRows = <Map<String, String>>[];
      for (final doc in devices ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
        final data = doc.data();
        deviceRows.add({
          '_id': doc.id,
          '_path': doc.reference.path,
          '_house_id': house.id,
          '_house_name': house.name,
          ..._flatten(data),
        });
      }
      _addCsv(files, counts, '$prefix/devices.csv', deviceRows);

      for (final doc in devices ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
        final data = doc.data();
        final deviceName = (data['name'] as String?) ?? doc.id;
        final devicePrefix = '$prefix/devices/${doc.id}';

        for (final collectionName in const ['readings', 'events', 'commands']) {
          progress('Lendo ${house.name} · $deviceName · $collectionName...');
          await _exportQuery(
            files: files,
            counts: counts,
            errors: errors,
            path: '$devicePrefix/$collectionName.csv',
            query: doc.reference.collection(collectionName),
            label: '$devicePrefix/$collectionName',
            extra: {
              '_house_id': house.id,
              '_house_name': house.name,
              '_device_id': doc.id,
              '_device_name': deviceName,
            },
          );
        }
      }
    }

    // ---------------------------------------------------------------------
    // README + manifest para qualquer IA entender o pacote.
    // ---------------------------------------------------------------------
    final manifest = <String, dynamic>{
      'project': 'monitor-de-caixa-d-agua',
      'source': 'firestore_offline_cache',
      'exportedAt': startedAt.toUtc().toIso8601String(),
      'uid': uid,
      'houses': houseMap.values
          .map((house) => {'id': house.id, 'name': house.name})
          .toList(),
      'counts': counts,
      'totalDocuments': counts.values.fold<int>(0, (a, b) => a + b),
      'errors': errors,
    };

    files['manifest.json'] =
        const JsonEncoder.withIndent('  ').convert(manifest);
    files['README.md'] = _buildReadme(
      exportedAt: startedAt,
      counts: counts,
      errors: errors,
    );

    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final zipBytes = ZipEncoder().encodeBytes(archive);
    final stamp = _stamp(startedAt);

    return DataExportResult(
      zipBytes: zipBytes,
      fileName: 'hidromonitor_dados_$stamp.zip',
      counts: counts,
      errors: errors,
      exportedAt: startedAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers de leitura do cache
  // ---------------------------------------------------------------------------

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>?> _cachedQuery(
    Query<Map<String, dynamic>> query,
    String label,
    List<String> errors,
  ) async {
    try {
      final snapshot = await query.get(const GetOptions(source: Source.cache));
      return snapshot.docs;
    } on FirebaseException catch (error) {
      errors.add('$label: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      errors.add('$label: $error');
      return null;
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _cachedDoc(
    DocumentReference<Map<String, dynamic>> ref,
    String label,
    List<String> errors,
  ) async {
    try {
      return await ref.get(const GetOptions(source: Source.cache));
    } on FirebaseException catch (error) {
      errors.add('$label: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      errors.add('$label: $error');
      return null;
    }
  }

  Future<void> _exportQuery({
    required Map<String, String> files,
    required Map<String, int> counts,
    required List<String> errors,
    required String path,
    required Query<Map<String, dynamic>> query,
    required String label,
    required Map<String, String> extra,
  }) async {
    final docs = await _cachedQuery(query, label, errors);
    if (docs == null) {
      counts[path] = 0;
      return;
    }
    final rows = <Map<String, String>>[];
    for (final doc in docs) {
      rows.add({
        '_id': doc.id,
        '_path': doc.reference.path,
        ...extra,
        ..._flatten(doc.data()),
      });
    }
    _addCsv(files, counts, path, rows);
  }

  // ---------------------------------------------------------------------------
  // CSV
  // ---------------------------------------------------------------------------

  void _addCsv(
    Map<String, String> files,
    Map<String, int> counts,
    String path,
    List<Map<String, String>> rows,
  ) {
    counts[path] = rows.length;
    if (rows.isEmpty) return;
    files[path] = _toCsv(rows);
  }

  String _toCsv(List<Map<String, String>> rows) {
    final keys = <String>{'_id', '_path'};
    for (final row in rows) {
      keys.addAll(row.keys);
    }
    final leading = <String>[
      '_id',
      '_path',
      '_house_id',
      '_house_name',
      '_device_id',
      '_device_name',
    ].where(keys.contains).toList();
    final others = keys
        .where((key) => !leading.contains(key))
        .toList()
      ..sort();
    final columns = [...leading, ...others];

    final buffer = StringBuffer()
      ..writeln(columns.map(_escapeCsv).join(','));
    for (final row in rows) {
      buffer.writeln(
        columns.map((column) => _escapeCsv(row[column] ?? '')).join(','),
      );
    }
    return buffer.toString();
  }

  Map<String, String> _flatten(Map<String, dynamic> data) {
    final result = <String, String>{};
    _flattenInto(result, '', data);
    return result;
  }

  void _flattenInto(
    Map<String, String> out,
    String prefix,
    Map<String, dynamic> data,
  ) {
    for (final entry in data.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      final value = entry.value;
      if (value is Map) {
        _flattenInto(out, key, value.cast<String, dynamic>());
      } else if (value is List) {
        out[key] = jsonEncode(_plain(value));
      } else {
        out[key] = _plain(value)?.toString() ?? '';
      }
    }
  }

  Object? _plain(Object? value) {
    if (value == null) return null;
    if (value is Timestamp) {
      return value.toDate().toUtc().toIso8601String();
    }
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is GeoPoint) {
      return {'latitude': value.latitude, 'longitude': value.longitude};
    }
    if (value is DocumentReference) return value.path;
    if (value is Blob) return base64Encode(value.bytes);
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _plain(item)),
      );
    }
    if (value is List) return value.map(_plain).toList();
    return value;
  }

  String _escapeCsv(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  // ---------------------------------------------------------------------------
  // Texto auxiliar
  // ---------------------------------------------------------------------------

  String _stamp(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}${two(date.month)}${two(date.day)}_'
        '${two(date.hour)}${two(date.minute)}';
  }

  String _buildReadme({
    required DateTime exportedAt,
    required Map<String, int> counts,
    required List<String> errors,
  }) {
    final buffer = StringBuffer()
      ..writeln('# Exportação HidroMonitor (cache offline)')
      ..writeln()
      ..writeln('Gerado em: ${exportedAt.toUtc().toIso8601String()}')
      ..writeln()
      ..writeln(
          'Fonte: cache offline do Firestore no aparelho. Nenhuma leitura '
          'foi feita no servidor; por isso o arquivo não consome a cota do '
          'Firestore e pode não conter documentos que o app nunca baixou.')
      ..writeln()
      ..writeln('## Arquivos')
      ..writeln();
    for (final entry in counts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      buffer.writeln('- `${entry.key}` — ${entry.value} documento(s)');
    }
    buffer
      ..writeln()
      ..writeln('## Formato dos CSVs')
      ..writeln()
      ..writeln('- Separador: vírgula (`,`), campos com vírgula/aspas/quebra de '
          'linha entre aspas.')
      ..writeln('- Timestamps: ISO-8601 em UTC.')
      ..writeln('- Mapas aninhados viram colunas com ponto, por exemplo '
          '`config.limits.ligaCm`.')
      ..writeln('- Listas e objetos dentro de listas ficam como JSON na célula.')
      ..writeln('- `_id` é o ID do documento no Firestore e `_path` é o caminho '
          'completo.')
      ..writeln('- `_house_id`, `_house_name`, `_device_id` e `_device_name` '
          'aparecem quando o arquivo é de uma subcoleção.')
      ..writeln();

    if (errors.isNotEmpty) {
      buffer
        ..writeln('## Coleções sem dados no cache')
        ..writeln();
      for (final error in errors) {
        buffer.writeln('- $error');
      }
      buffer.writeln();
    }

    buffer
      ..writeln('## Dica de análise')
      ..writeln()
      ..writeln('- `readings.csv` é a série histórica de telemetria.')
      ..writeln('- `devices.csv` traz a configuração atual e a última leitura '
          '(`latest`).')
      ..writeln('- `alerts.csv`, `events.csv` e `configLog.csv` são os eventos '
          'e a auditoria.')
      ..writeln('- Consumo estimado: somar quedas de `volumeL` entre leituras '
          'consecutivas com `sensorOk=true` e `pumpOn=false`.');
    return buffer.toString();
  }
}
