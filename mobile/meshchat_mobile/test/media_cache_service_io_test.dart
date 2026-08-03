import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/media_cache_service_io.dart';

void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('meshchat_media_test_');
    mediaCacheDirectoryOverrideForTesting = cacheRoot.path;
  });

  tearDown(() async {
    mediaCacheDirectoryOverrideForTesting = null;
    if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
  });

  test('interrupted download resumes from its persisted byte offset', () async {
    final payload = _payload(320 * 1024);
    final digest = await _sha256(payload);
    final requestedRanges = <String?>[];
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestedRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      requestCount++;
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (requestCount == 1) {
        request.response.contentLength = payload.length;
        request.response.add(payload.sublist(0, 96 * 1024));
        try {
          await request.response.close();
        } on HttpException {
          // Closing before Content-Length bytes simulates a broken connection.
        }
        return;
      }
      final offset = _rangeOffset(requestedRanges.last);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $offset-${payload.length - 1}/${payload.length}',
      );
      request.response.add(payload.sublist(offset));
      await request.response.close();
    });

    final url = Uri.parse('http://127.0.0.1:${server.port}/media');
    await expectLater(
      downloadMediaCache(
        'session',
        'media',
        url,
        'token',
        digest,
        payload.length,
        null,
      ),
      throwsA(anything),
    );

    final partial = await _singlePartial(cacheRoot);
    final partialSize = await partial.length();
    expect(partialSize, greaterThan(0));
    expect(partialSize, lessThan(payload.length));

    final result = await downloadMediaCache(
      'session',
      'media',
      url,
      'token',
      digest,
      payload.length,
      null,
    );

    expect(result, payload);
    expect(requestedRanges, [null, 'bytes=$partialSize-']);
    expect(await partial.exists(), isFalse);
  });

  test(
    'invalid Content-Range discards partial bytes and retries safely',
    () async {
      final payload = _payload(192 * 1024);
      final digest = await _sha256(payload);
      final ranges = <String?>[];
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        requestCount++;
        request.response.headers.contentType = ContentType.binary;
        if (requestCount == 1) {
          request.response.contentLength = payload.length;
          request.response.add(payload.sublist(0, 48 * 1024));
          try {
            await request.response.close();
          } on HttpException {
            // Closing before Content-Length bytes simulates a broken connection.
          }
          return;
        }
        if (requestCount == 2) {
          final offset = _rangeOffset(range);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${offset + 1}-${payload.length - 1}/${payload.length}',
          );
          request.response.add(payload.sublist(offset + 1));
          await request.response.close();
          return;
        }
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });

      final url = Uri.parse('http://127.0.0.1:${server.port}/media');
      await expectLater(
        downloadMediaCache(
          'session',
          'media',
          url,
          'token',
          digest,
          payload.length,
          null,
        ),
        throwsA(anything),
      );
      final partialSize = await (await _singlePartial(cacheRoot)).length();

      final result = await downloadMediaCache(
        'session',
        'media',
        url,
        'token',
        digest,
        payload.length,
        null,
      );

      expect(result, payload);
      expect(ranges, [null, 'bytes=$partialSize-', null]);
    },
  );

  test(
    'corrupted partial bytes fail checksum and trigger a clean retry',
    () async {
      final payload = _payload(224 * 1024);
      final digest = await _sha256(payload);
      final ranges = <String?>[];
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        requestCount++;
        request.response.headers.contentType = ContentType.binary;
        if (requestCount == 1) {
          request.response.contentLength = payload.length;
          request.response.add(payload.sublist(0, 64 * 1024));
          try {
            await request.response.close();
          } on HttpException {
            // Closing before Content-Length bytes simulates a broken connection.
          }
          return;
        }
        if (range != null) {
          final offset = _rangeOffset(range);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $offset-${payload.length - 1}/${payload.length}',
          );
          request.response.add(payload.sublist(offset));
        } else {
          request.response.contentLength = payload.length;
          request.response.add(payload);
        }
        await request.response.close();
      });

      final url = Uri.parse('http://127.0.0.1:${server.port}/media');
      await expectLater(
        downloadMediaCache(
          'session',
          'media',
          url,
          'token',
          digest,
          payload.length,
          null,
        ),
        throwsA(anything),
      );
      final partial = await _singlePartial(cacheRoot);
      final partialSize = await partial.length();
      final corrupted = await partial.readAsBytes();
      corrupted[0] = (corrupted[0] + 1) % 256;
      await partial.writeAsBytes(corrupted, flush: true);

      final result = await downloadMediaCache(
        'session',
        'media',
        url,
        'token',
        digest,
        payload.length,
        null,
      );

      expect(result, payload);
      expect(ranges, [null, 'bytes=$partialSize-', null]);
    },
  );
}

Uint8List _payload(int length) => Uint8List.fromList(
  List<int>.generate(length, (index) => (index * 31 + 17) % 251),
);

Future<String> _sha256(Uint8List bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<File> _singlePartial(Directory root) async {
  final files = await root
      .list(recursive: true)
      .where((entity) => entity is File && entity.path.endsWith('.part'))
      .cast<File>()
      .toList();
  expect(files, hasLength(1));
  return files.single;
}

int _rangeOffset(String? range) =>
    int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range!)!.group(1)!);
