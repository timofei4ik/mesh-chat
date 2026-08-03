import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _maximumCacheBytes = 512 * 1024 * 1024;
const _partialMaxAge = Duration(days: 7);
const _maximumIntegrityAttempts = 2;

String? mediaCacheDirectoryOverrideForTesting;

Future<Uint8List?> readMediaCache(
  String sessionKey,
  String mediaId,
  String expectedSha256,
) async {
  final target = await _cacheFile(sessionKey, mediaId);
  if (!await target.exists()) return null;
  if (!await _fileMatches(target, expectedSha256)) {
    await target.delete();
    return null;
  }
  await target.setLastModified(DateTime.now());
  return target.readAsBytes();
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
  await _removeStalePartials(target.parent, except: partial);

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    for (var attempt = 0; attempt < _maximumIntegrityAttempts; attempt++) {
      try {
        final result = await _downloadAttempt(
          client: client,
          target: target,
          partial: partial,
          url: url,
          token: token,
          expectedSha256: expectedSha256,
          expectedSize: expectedSize,
          onProgress: onProgress,
        );
        onProgress?.call(1);
        await _trimCache(target.parent);
        return result;
      } on _RestartMediaDownload {
        await _deleteIfExists(partial);
        if (attempt + 1 >= _maximumIntegrityAttempts) rethrow;
      } on FormatException {
        await _deleteIfExists(partial);
        if (attempt + 1 >= _maximumIntegrityAttempts) rethrow;
      }
    }
    throw const FormatException('Media integrity verification failed');
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _downloadAttempt({
  required HttpClient client,
  required File target,
  required File partial,
  required Uri url,
  required String token,
  required String expectedSha256,
  required int expectedSize,
  required void Function(double progress)? onProgress,
}) async {
  var offset = await partial.exists() ? await partial.length() : 0;
  if (expectedSize > 0 && offset > expectedSize) {
    await partial.delete();
    offset = 0;
  }
  if (offset > 0 && expectedSize > 0) {
    onProgress?.call((offset / expectedSize).clamp(0, 1));
  }

  final request = await client.getUrl(url);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  if (offset > 0) {
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
  }
  final response = await request.close().timeout(const Duration(seconds: 30));

  if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
    await response.drain<void>();
    if (expectedSize > 0 && offset == expectedSize) {
      return _finalizeFile(target, partial, expectedSha256, expectedSize);
    }
    throw const _RestartMediaDownload('Server rejected resume offset');
  }
  if (response.statusCode != HttpStatus.ok &&
      response.statusCode != HttpStatus.partialContent) {
    await response.drain<void>();
    throw HttpException(
      'Media download failed (${response.statusCode})',
      uri: url,
    );
  }

  var writeOffset = offset;
  var totalSize = expectedSize;
  if (response.statusCode == HttpStatus.partialContent) {
    final range = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (range == null || range.start != offset) {
      await response.drain<void>();
      throw const _RestartMediaDownload('Invalid resume response range');
    }
    if (range.total != null) {
      if (expectedSize > 0 && range.total != expectedSize) {
        await response.drain<void>();
        throw const _RestartMediaDownload('Media size changed during resume');
      }
      totalSize = range.total!;
    }
  } else if (offset > 0) {
    // Some proxies ignore Range. A complete 200 response is still usable, but
    // it must replace the partial bytes instead of being appended to them.
    writeOffset = 0;
  }
  if (totalSize <= 0 && response.contentLength >= 0) {
    totalSize = writeOffset + response.contentLength;
  }

  final handle = await partial.open(
    mode: writeOffset > 0 ? FileMode.append : FileMode.write,
  );
  var received = writeOffset;
  try {
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (totalSize > 0 && received + chunk.length > totalSize) {
        throw const _RestartMediaDownload('Media response exceeded its size');
      }
      await handle.writeFrom(chunk);
      received += chunk.length;
      if (totalSize > 0) {
        onProgress?.call((received / totalSize).clamp(0, 1));
      }
    }
    await handle.flush();
  } finally {
    await handle.close();
  }
  return _finalizeFile(
    target,
    partial,
    expectedSha256,
    expectedSize > 0 ? expectedSize : totalSize,
  );
}

Future<void> clearMediaCache(String sessionKey) async {
  final directory = await _cacheDirectory(sessionKey);
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

Future<Uint8List> _finalizeFile(
  File target,
  File partial,
  String expectedSha256,
  int expectedSize,
) async {
  if (!await partial.exists()) {
    throw const FormatException('Partial media file is missing');
  }
  final size = await partial.length();
  if (expectedSize > 0 && size != expectedSize) {
    throw const FormatException('Media size mismatch');
  }
  if (!await _fileMatches(partial, expectedSha256)) {
    throw const FormatException('Media checksum mismatch');
  }
  await _deleteIfExists(target);
  await partial.rename(target.path);
  return target.readAsBytes();
}

Future<bool> _fileMatches(File file, String expectedSha256) async {
  final expected = expectedSha256.trim().toLowerCase();
  if (expected.isEmpty) return true;
  final sink = Sha256().toSync().newHashSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  final digest = await sink.hash();
  final actual = digest.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return actual == expected;
}

({int start, int end, int? total})? _parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final totalRaw = match.group(3)!;
  final total = totalRaw == '*' ? null : int.tryParse(totalRaw);
  if (start == null || end == null || end < start) return null;
  if (total != null && (total <= 0 || end >= total)) return null;
  return (start: start, end: end, total: total);
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
  final override = mediaCacheDirectoryOverrideForTesting;
  final support = override == null
      ? await getApplicationSupportDirectory()
      : Directory(override);
  final digest = await Sha256().hash(utf8.encode(sessionKey));
  final namespace = base64Url.encode(digest.bytes).replaceAll('=', '');
  return Directory(p.join(support.path, 'meshchat_media_v2', namespace));
}

Future<void> _removeStalePartials(Directory directory, {File? except}) async {
  if (!await directory.exists()) return;
  final cutoff = DateTime.now().subtract(_partialMaxAge);
  await for (final entity in directory.list()) {
    if (entity is! File || !entity.path.endsWith('.part')) continue;
    if (except != null && p.equals(entity.path, except.path)) continue;
    try {
      if ((await entity.stat()).modified.isBefore(cutoff)) {
        await entity.delete();
      }
    } on FileSystemException {
      // A concurrent download owns this file and will clean it up later.
    }
  }
}

Future<void> _trimCache(Directory directory) async {
  if (!await directory.exists()) return;
  await _removeStalePartials(directory);
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

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) await file.delete();
}

class _RestartMediaDownload implements Exception {
  const _RestartMediaDownload(this.reason);

  final String reason;

  @override
  String toString() => 'RestartMediaDownload: $reason';
}
