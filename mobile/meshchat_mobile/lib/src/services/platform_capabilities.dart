import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class MeshPlatformCapabilities {
  const MeshPlatformCapabilities({
    this.iosMajorVersion = 0,
    this.reduceTransparency = false,
  });

  static const standard = MeshPlatformCapabilities();
  static const _channel = MethodChannel('meshchat/platform_style');

  final int iosMajorVersion;
  final bool reduceTransparency;

  bool get liquidGlassEnabled => supportsLiquidGlass(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    iosMajorVersion: iosMajorVersion,
    reduceTransparency: reduceTransparency,
  );

  static bool supportsLiquidGlass({
    required bool isWeb,
    required TargetPlatform platform,
    required int iosMajorVersion,
    required bool reduceTransparency,
  }) {
    return !isWeb &&
        platform == TargetPlatform.iOS &&
        iosMajorVersion >= 26 &&
        !reduceTransparency;
  }

  static Future<MeshPlatformCapabilities> detect() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return standard;
    }
    try {
      final values = await _channel.invokeMapMethod<String, Object?>(
        'getVisualCapabilities',
      );
      return MeshPlatformCapabilities(
        iosMajorVersion: (values?['iosMajorVersion'] as num?)?.toInt() ?? 0,
        reduceTransparency: values?['reduceTransparency'] as bool? ?? false,
      );
    } on PlatformException {
      return standard;
    } on MissingPluginException {
      return standard;
    }
  }
}
