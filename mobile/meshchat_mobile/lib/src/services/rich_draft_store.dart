import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'file_transfer_payload_store.dart';
import '../models/rich_message_document.dart';

class RichDraftStore {
  RichDraftStore(String accountAndThread)
    : key =
          'mesh_rich_draft_v1:${base64Url.encode(utf8.encode(accountAndThread))}';
  final String key;
  Future<void> _writes = Future.value();
  final _payloads = FileTransferPayloadStore();
  String get _filesKey => '$key:files';

  Future<Map<String, dynamic>> _files() async {
    final raw = (await SharedPreferences.getInstance()).getString(_filesKey);
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<Map<String, dynamic>> stage(String name, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
      throw StateError('Choose a non-empty file up to 64 MB.');
    }
    final files = await _files();
    final total = files.values.fold<int>(
      0,
      (sum, entry) => sum + (entry['size'] as int),
    );
    if (files.length >= 16 || total + bytes.length > 128 * 1024 * 1024) {
      throw StateError(
        'This draft already contains 16 files or 128 MB of media.',
      );
    }
    final id = const Uuid().v4();
    final reference = await _payloads.write(key, 'rich-$id', bytes);
    files[id] = {'reference': reference, 'size': bytes.length};
    if (!await (await SharedPreferences.getInstance()).setString(
      _filesKey,
      jsonEncode(files),
    )) {
      await _payloads.delete(reference);
      throw StateError('Could not save attachment');
    }
    return {'type': 'attachment', 'id': id, 'name': name};
  }

  Future<Uint8List?> readAttachment(String id) async {
    final item = (await _files())[id];
    if (item == null) return null;
    final bytes = await _payloads.readChunk(
      item['reference'] as String,
      0,
      item['size'] as int,
    );
    if (bytes.length != item['size']) {
      throw StateError(
        'Draft attachment is missing. Remove it and attach the file again.',
      );
    }
    return bytes;
  }

  Future<RichMessageDocument?> load() async {
    await _writes;
    return RichMessageDocument.decode(
      (await SharedPreferences.getInstance()).getString(key) ?? '',
    );
  }

  Future<void> save(RichMessageDocument? document) {
    final raw = document?.encode();
    final write = _writes.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final ok = raw == null
          ? await prefs.remove(key)
          : await prefs.setString(key, raw);
      if (!ok) throw StateError('Could not save rich draft');
      if (raw == null) {
        for (final item in (await _files()).values) {
          await _payloads.delete(item['reference'] as String);
        }
        await prefs.remove(_filesKey);
      }
    });
    _writes = write;
    return write;
  }
}
