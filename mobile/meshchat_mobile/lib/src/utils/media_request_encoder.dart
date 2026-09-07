import 'dart:convert';
import 'dart:typed_data';

/// Pure worker entry point: neither the controller nor socket crosses isolates.
String encodeMediaRequest(Map<String, dynamic> input) {
  final hex = input['hex'] as String;
  final limit = input['limit'] as int;
  if (hex.isEmpty || hex.length.isOdd || hex.length > limit * 2) {
    throw const FormatException('Invalid media size');
  }
  final bytes = decodeMediaHex(hex);
  return jsonEncode({
    ...input['packet'] as Map<String, dynamic>,
    input['field'] as String: base64Encode(bytes),
  });
}

Uint8List decodeMediaHex(String hex) {
  if (hex.length.isOdd) throw const FormatException('Invalid media size');
  int nibble(int code) {
    if (code >= 48 && code <= 57) return code - 48;
    if (code >= 65 && code <= 70) return code - 55;
    if (code >= 97 && code <= 102) return code - 87;
    throw const FormatException('Invalid media encoding');
  }

  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] =
        (nibble(hex.codeUnitAt(i * 2)) << 4) |
        nibble(hex.codeUnitAt(i * 2 + 1));
  }
  return bytes;
}
