import 'dart:convert';
import 'session_secret_store.dart';

/// Account-scoped personal data stays in secure storage; never sent implicitly.
class AiPersonalStore {
  AiPersonalStore(String account, {SessionSecretStore? storage})
    : prefix = 'mesh.ai.v1.${base64Url.encode(utf8.encode(account))}',
      storage = storage ?? PlatformSessionSecretStore();
  final String prefix;
  final SessionSecretStore storage;
  static final _queues = <String, Future<void>>{};

  Future<List<Map<String, dynamic>>> update(
    String collection,
    List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) change,
  ) {
    final key = '$prefix.$collection';
    final operation = (_queues[key] ?? Future<void>.value()).then((_) async {
      final next = change(await read(collection));
      await write(collection, next);
      return next;
    });
    _queues[key] = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<List<Map<String, dynamic>>> read(String collection) async {
    final raw = await storage.read('$prefix.$collection');
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid saved AI data');
    return decoded
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> write(
    String collection,
    List<Map<String, dynamic>> items,
  ) async {
    if (items.length > (collection == 'presets' ? 20 : 50)) {
      throw StateError('Library is full');
    }
    await storage.write('$prefix.$collection', jsonEncode(items));
  }

  Future<void> clear() async {
    await _queues['$prefix.presets'];
    await _queues['$prefix.notes'];
    await storage.delete('$prefix.presets');
    await storage.delete('$prefix.notes');
  }
}
