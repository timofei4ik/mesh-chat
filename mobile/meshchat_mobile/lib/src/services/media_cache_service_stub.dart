import 'dart:typed_data';

Future<Uint8List?> readMediaCache(
  String sessionKey,
  String mediaId,
  String expectedSha256,
) async => null;

Future<Uint8List> downloadMediaCache(
  String sessionKey,
  String mediaId,
  Uri url,
  String token,
  String expectedSha256,
  int expectedSize,
  void Function(double progress)? onProgress,
) {
  throw UnsupportedError('Native media cache is unavailable');
}

Future<void> clearMediaCache(String sessionKey) async {}
