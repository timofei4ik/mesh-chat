import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

Future<(Source, Future<void> Function(), String?)> prepareAudioPlaybackSource({
  required Uint8List bytes,
  required String extension,
  required String mimeType,
}) async {
  final temporaryDirectory = await getTemporaryDirectory();
  final audioDirectory = Directory(
    p.join(temporaryDirectory.path, 'meshchat_audio'),
  );
  await audioDirectory.create(recursive: true);
  final file = File(
    p.join(audioDirectory.path, '${const Uuid().v4()}$extension'),
  );
  await file.writeAsBytes(bytes, flush: true);
  return (
    DeviceFileSource(file.path, mimeType: mimeType),
    () async {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // The OS can briefly retain the decoder handle after player disposal.
      }
    },
    file.path,
  );
}
