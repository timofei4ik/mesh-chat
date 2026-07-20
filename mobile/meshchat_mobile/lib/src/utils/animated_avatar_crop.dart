import 'dart:convert';
import 'dart:typed_data';

const animatedAvatarMaxBytes = 4 * 1024 * 1024;
const animatedAvatarCropViewport = 260.0;

class AnimatedAvatarCrop {
  const AnimatedAvatarCrop({
    required this.scale,
    required this.translateX,
    required this.translateY,
  });

  final double scale;
  final double translateX;
  final double translateY;

  static AnimatedAvatarCrop? tryParse(String dataUri) {
    final comma = dataUri.indexOf(',');
    if (comma <= 0) return null;
    final header = dataUri.substring(0, comma);
    final match = RegExp(r'(?:^|;)meshcrop=([^;]+)').firstMatch(header);
    final parts = match?.group(1)?.split(':');
    if (parts == null || parts.length != 3) return null;
    final scale = double.tryParse(parts[0]);
    final translateX = double.tryParse(parts[1]);
    final translateY = double.tryParse(parts[2]);
    if (scale == null || translateX == null || translateY == null) return null;
    if (!scale.isFinite ||
        !translateX.isFinite ||
        !translateY.isFinite ||
        scale < 1 ||
        scale > 4) {
      return null;
    }
    return AnimatedAvatarCrop(
      scale: scale,
      translateX: translateX,
      translateY: translateY,
    );
  }
}

/// Keeps every byte of the source GIF intact and stores only the visual crop
/// in the data URI header. Re-encoding animated GIFs can alter local palettes
/// and disposal rules, which causes color flashes between frames.
String encodeAnimatedAvatarData(
  Uint8List bytes, {
  required double scale,
  required double translateX,
  required double translateY,
}) {
  String number(double value) => value.toStringAsFixed(6);
  final crop = '${number(scale)}:${number(translateX)}:${number(translateY)}';
  return 'data:image/gif;meshcrop=$crop;base64,${base64Encode(bytes)}';
}
