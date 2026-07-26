import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _maximumCacheBytes = 512 * 1024 * 1024;

Future<Uint8List?> readMediaCache(
  String sessionKey,
  String mediaId,
  String expectedSha256,
) async {
  final target = await _cacheFile(sessionKey, mediaId);
  if (!await target.exists()) return null;
  final bytes = await target.readAsBytes();
  if (!await _matches(bytes, expectedSha256)) {
    await target.delete();
    return null;
  }
  await target.setLastModified(DateTime.now());
  return bytes;
}

Future<Uint8List> downloadMediaCache(
  String sessionKey,
  String mediaId,
  Uri url,
  String token,
  String expectedSha256,
  int expectedSize,
  void Function(double progress)? onProgress,
) async {
  final target = await _cacheFile(sessionKey, mediaId);
  final partial = File('${target.path}.part');
  await target.parent.create(recursive: true);
  var offset = await partial.exists() ? await partial.length() : 0;
  if (expectedSize > 0 && offset > expectedSize) {
    await partial.delete();
    offset = 0;
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    var request = await client.getUrl(url);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    var response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        expectedSize > 0 &&
        offset == expectedSize) {
      final completed = await partial.readAsBytes();
      return _finalize(
        target,
        partial,
        completed,
        expectedSha256,
        expectedSize,
      );
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException(
        'Media download failed (${response.statusCode})',
        uri: url,
      );
    }
    if (offset > 0 && response.statusCode == HttpStatus.ok) {
      await partial.delete();
      offset = 0;
    }
    final handle = await partial.open(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        await handle.writeFrom(chunk);
        received += chunk.length;
        if (expectedSize > 0) {
          onProgress?.call((received / expectedSize).clamp(0, 1));
        }
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
    final completed = await partial.readAsBytes();
    final result = await _finalize(
      target,
      partial,
      completed,
      expectedSha256,
      expectedSize,
    );
    onProgress?.call(1);
    await _trimCache(target.parent);
    return result;
  } finally {
    client.close(force: true);
  }
}

Future<void> clearMediaCache(String sessionKey) async {
  final directory = await _cacheDirectory(sessionKey);
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

Future<Uint8List> _finalize(
  File target,
  File partial,
  Uint8List bytes,
  String expectedSha256,
  int expectedSize,
) async {
  if (expectedSize > 0 && bytes.length != expectedSize) {
    throw const FormatException('Media size mismatch');
  }
  if (!await _matches(bytes, expectedSha256)) {
    if (await partial.exists()) await partial.delete();
    throw const FormatException('Media checksum mismatch');
  }
  if (await target.exists()) await target.delete();
  await partial.rename(target.path);
  return bytes;
}

Future<bool> _matches(Uint8List bytes, String expectedSha256) async {
  final expected = expectedSha256.trim().toLowerCase();
  if (expected.isEmpty) return true;
  final digest = await Sha256().hash(bytes);
  final actual = digest.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return actual == expected;
}

Future<File> _cacheFile(String sessionKey, String mediaId) async {
  final directory = await _cacheDirectory(sessionKey);
  final digest = await Sha256().hash(utf8.encode(mediaId));
  final name = digest.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return File(p.join(directory.path, '$name.bin'));
}

Future<Directory> _cacheDirectory(String sessionKey) async {
  final support = await getApplicationSupportDirectory();
  final digest = await Sha256().hash(utf8.encode(sessionKey));
  final namespace = base64Url.encode(digest.bytes).replaceAll('=', '');
  return Directory(p.join(support.path, 'meshchat_media_v2', namespace));
}

Future<void> _trimCache(Directory directory) async {
  if (!await directory.exists()) return;
  final files = await directory
      .list()
      .where((entity) => entity is File && !entity.path.endsWith('.part'))
      .cast<File>()
      .toList();
  var total = 0;
  final entries = <({File file, int size, DateTime modified})>[];
  for (final file in files) {
    final stat = await file.stat();
    total += stat.size;
    entries.add((file: file, size: stat.size, modified: stat.modified));
  }
  if (total <= _maximumCacheBytes) return;
  entries.sort((a, b) => a.modified.compareTo(b.modified));
  for (final entry in entries) {
    if (total <= _maximumCacheBytes) break;
    try {
      await entry.file.delete();
      total -= entry.size;
    } on FileSystemException {
      // A preview may still be reading this file; it can be trimmed later.
    }
  }
}
