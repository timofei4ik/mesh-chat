import 'dart:typed_data';

import 'media_cache_service_stub.dart'
    if (dart.library.io) 'media_cache_service_io.dart'
    as platform;

class MediaCacheService {
  Future<Uint8List?> read({
    required String sessionKey,
    required String mediaId,
    String expectedSha256 = '',
  }) => platform.readMediaCache(
    sessionKey,
    mediaId,
    expectedSha256,
  );

  Future<Uint8List> download({
    required String sessionKey,
    required String mediaId,
    required Uri url,
    required String token,
    String expectedSha256 = '',
    int expectedSize = 0,
    void Function(double progress)? onProgress,
  }) => platform.downloadMediaCache(
    sessionKey,
    mediaId,
    url,
    token,
    expectedSha256,
    expectedSize,
    onProgress,
  );

  Future<void> clear(String sessionKey) =>
      platform.clearMediaCache(sessionKey);
}
