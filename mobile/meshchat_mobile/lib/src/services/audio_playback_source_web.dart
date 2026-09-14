import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

Future<(Source, Future<void> Function(), String?)> prepareAudioPlaybackSource({
  required Uint8List bytes,
  required String extension,
  required String mimeType,
}) async {
  return (BytesSource(bytes, mimeType: mimeType), () async {}, null);
}
