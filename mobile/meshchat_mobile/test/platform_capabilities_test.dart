import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/platform_capabilities.dart';

void main() {
  group('MeshPlatformCapabilities.supportsLiquidGlass', () {
    test('enables native glass on iOS 26', () {
      expect(
        MeshPlatformCapabilities.supportsLiquidGlass(
          isWeb: false,
          platform: TargetPlatform.iOS,
          iosMajorVersion: 26,
          reduceTransparency: false,
        ),
        isTrue,
      );
    });

    test('keeps the fallback on iOS 25', () {
      expect(
        MeshPlatformCapabilities.supportsLiquidGlass(
          isWeb: false,
          platform: TargetPlatform.iOS,
          iosMajorVersion: 25,
          reduceTransparency: false,
        ),
        isFalse,
      );
    });

    test('honors Reduce Transparency', () {
      expect(
        MeshPlatformCapabilities.supportsLiquidGlass(
          isWeb: false,
          platform: TargetPlatform.iOS,
          iosMajorVersion: 26,
          reduceTransparency: true,
        ),
        isFalse,
      );
    });

    test('does not enable the iOS view on other platforms', () {
      for (final platform in TargetPlatform.values.where(
        (platform) => platform != TargetPlatform.iOS,
      )) {
        expect(
          MeshPlatformCapabilities.supportsLiquidGlass(
            isWeb: false,
            platform: platform,
            iosMajorVersion: 26,
            reduceTransparency: false,
          ),
          isFalse,
        );
      }
    });

    test('does not enable platform views on web', () {
      expect(
        MeshPlatformCapabilities.supportsLiquidGlass(
          isWeb: true,
          platform: TargetPlatform.iOS,
          iosMajorVersion: 26,
          reduceTransparency: false,
        ),
        isFalse,
      );
    });
  });
}
