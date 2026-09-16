import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_win/video_player_win.dart';

bool _registered = false;

Future<(VideoPlayerController, Future<void> Function())> prepare(
  Uint8List bytes,
  String mime,
) async {
  if (Platform.isWindows && !_registered) {
    WindowsVideoPlayer.registerWith();
    _registered = true;
  }
  final root = await getTemporaryDirectory();
  final directory = await root.createTemp('meshchat_story_');
  final extension = switch (mime) {
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    'video/x-m4v' => 'm4v',
    _ => 'mp4',
  };
  try {
    final file = File('${directory.path}/video.$extension');
    await file.writeAsBytes(bytes, flush: true);
    return (
      VideoPlayerController.file(file),
      () async {
        if (await directory.exists()) await directory.delete(recursive: true);
      },
    );
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}
