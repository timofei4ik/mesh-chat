import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../models/rich_message_document.dart';

class RichDraftSync {
  RichDraftSync({
    required this.request,
    required this.encrypt,
    required this.decrypt,
  });
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) request;
  final Future<String> Function(String) encrypt;
  final Future<String> Function(String) decrypt;
  static const chunkSize = 64 * 1024;

  Future<Map<String, dynamic>> decode(String raw) async => raw.isEmpty
      ? {}
      : Map<String, dynamic>.from(jsonDecode(await decrypt(raw)) as Map);

  Future<String> upload(
    RichMessageDocument? document,
    Future<Uint8List?> Function(String) read,
    String previous,
  ) async {
    if (document == null) return '';
    Map<String, dynamic> old = {};
    try {
      old = await decode(previous);
    } catch (_) {
      /* Rebuild damaged metadata. */
    }
    final files = <String, dynamic>{};
    for (final attachment in document.attachments) {
      final id = attachment['id'] as String;
      if (files.containsKey(id)) continue;
      if (old['files'] is Map && old['files'][id] != null) {
        files[id] = old['files'][id];
        continue;
      }
      final bytes = await read(id);
      if (bytes == null) throw StateError('Draft attachment is missing');
      final count = (bytes.length + chunkSize - 1) ~/ chunkSize;
      for (var index = 0; index < count; index++) {
        final end = ((index + 1) * chunkSize).clamp(0, bytes.length);
        final data = await encrypt(
          base64Encode(Uint8List.sublistView(bytes, index * chunkSize, end)),
        );
        await request({
          'type': 'draft_blob_put',
          'blob_id': id,
          'index': index,
          'data': data,
        });
      }
      files[id] = {
        'size': bytes.length,
        'chunks': count,
        'hash': base64Encode((await Sha256().hash(bytes)).bytes),
      };
    }
    return encrypt(jsonEncode({'document': document.encode(), 'files': files}));
  }

  Future<Uint8List?> download(String raw, String id) async {
    final manifest = await decode(raw);
    final item = (manifest['files'] as Map?)?[id];
    if (item is! Map) return null;
    final count = item['chunks'];
    final size = item['size'];
    if (count is! int ||
        count <= 0 ||
        count > 1024 ||
        size is! int ||
        size <= 0 ||
        size > 64 * 1024 * 1024 ||
        count != (size + chunkSize - 1) ~/ chunkSize) {
      throw const FormatException('Invalid draft attachment');
    }
    final bytes = BytesBuilder(copy: false);
    for (var index = 0; index < count; index++) {
      final response = await request({
        'type': 'draft_blob_get',
        'blob_id': id,
        'index': index,
      });
      final chunk = base64Decode(await decrypt(response['data'] as String));
      if (chunk.length > chunkSize) {
        throw const FormatException('Invalid draft chunk');
      }
      bytes.add(chunk);
    }
    final value = bytes.takeBytes();
    if (value.length != size ||
        base64Encode((await Sha256().hash(value)).bytes) != item['hash']) {
      throw const FormatException('Draft attachment checksum mismatch');
    }
    return value;
  }
}
