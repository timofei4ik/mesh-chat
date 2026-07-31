import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const themes = [
    'cloud_camp',
    'moon_trail',
    'ember_night',
    'story_lanterns',
    'rainlight',
  ];

  test('Enchanted Gardens avatar frames decode', () async {
    for (final theme in themes) {
      final data = await rootBundle.load(
        'assets/profile_collections/campfire_trails/${theme}_frame.webp',
      );
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      expect(codec.frameCount, greaterThanOrEqualTo(1));
      if (codec.frameCount > 1) {
        expect(
          codec.repetitionCount,
          -1,
          reason: '$theme is no longer an infinite loop',
        );
      }
      codec.dispose();
    }
  });

  test('Enchanted Gardens animated banners decode and loop', () async {
    for (final theme in themes) {
      final data = await rootBundle.load(
        'assets/profile_collections/campfire_trails/${theme}_banner.webp',
      );
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      expect(codec.frameCount, greaterThan(1));
      expect(
        codec.repetitionCount,
        -1,
        reason: '$theme banner is no longer an infinite loop',
      );
      codec.dispose();
    }
  });

  test('Enchanted Gardens static previews decode', () async {
    for (final theme in themes) {
      for (final suffix in ['frame.png', 'banner_static.webp']) {
        final data = await rootBundle.load(
          'assets/profile_collections/campfire_trails/${theme}_$suffix',
        );
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        expect(codec.frameCount, 1);
        codec.dispose();
      }
    }
  });
}
