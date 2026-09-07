import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/utils/media_request_encoder.dart';

void main() {
  test('media encoding preserves exact bytes and request metadata', () async {
    final raw = await compute(encodeMediaRequest, {
      'hex': '00017f80aAFF',
      'field': 'audio_base64',
      'limit': 6,
      'packet': {'type': 'ai_voice_transcription_request', 'request_id': 'id'},
    });
    final packet = jsonDecode(raw) as Map;
    expect(packet['request_id'], 'id');
    expect(base64Decode(packet['audio_base64'] as String), [
      0,
      1,
      127,
      128,
      170,
      255,
    ]);
  });
  test('reject malformed or oversized media before sending', () {
    for (final hex in ['', '0', 'xx', '000000']) {
      expect(
        () => encodeMediaRequest({
          'hex': hex,
          'field': 'image_base64',
          'limit': 2,
          'packet': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    }
  });
  test('large media preparation leaves main event loop responsive', () async {
    final hex = 'ab' * (8 * 1024 * 1024);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      final result = await compute(encodeMediaRequest, {
        'hex': hex,
        'field': 'audio_base64',
        'limit': 8 * 1024 * 1024,
        'packet': <String, dynamic>{},
      });
      expect(result.length, greaterThan(8 * 1024 * 1024));
      expect(ticks, greaterThan(0));
    } finally {
      timer.cancel();
    }
  });
}
