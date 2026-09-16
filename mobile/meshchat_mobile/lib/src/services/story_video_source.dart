import 'dart:typed_data';

import 'package:video_player/video_player.dart';

import 'story_video_source_web.dart'
    if (dart.library.io) 'story_video_source_io.dart'
    as platform;

class StoryVideoSource {
  StoryVideoSource(this.controller, this._cleanup);

  final VideoPlayerController controller;
  final Future<void> Function() _cleanup;
  bool _disposed = false;

  static Future<StoryVideoSource> prepare(Uint8List bytes, String mime) async {
    final (controller, cleanup) = await platform.prepare(bytes, mime);
    return StoryVideoSource(controller, cleanup);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await controller.dispose();
    } finally {
      await _cleanup();
    }
  }
}
