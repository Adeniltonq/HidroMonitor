import 'package:cloud_firestore/cloud_firestore.dart';

/// Apaga todos os documentos de uma coleção em lotes.
///
/// O Firestore não tem "delete recursivo" no cliente: para excluir uma casa ou
/// um dispositivo é preciso varrer cada subcoleção. Usamos lotes de 400 para
/// ficar abaixo do limite de 500 operações por batch.
Future<int> deleteCollectionDocs(
  CollectionReference<Map<String, dynamic>> collection, {
  String label = '',
  void Function(String label, int removidos)? onProgress,
}) async {
  var removidos = 0;
  while (true) {
    final snapshot = await collection.limit(400).get();
    if (snapshot.docs.isEmpty) break;

    final batch = collection.firestore.batch();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();

    removidos += snapshot.docs.length;
    onProgress?.call(label, removidos);
    if (snapshot.docs.length < 400) break;
  }
  return removidos;
}
