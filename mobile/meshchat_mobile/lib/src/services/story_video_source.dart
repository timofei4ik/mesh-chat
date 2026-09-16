import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:video_player/video_player.dart';

import 'story_video_source_web.dart'
    if (dart.library.io) 'story_video_source_io.dart'
    as platform;

class StoryVideoSource {
  StoryVideoSource(this.controller, this._cleanup);

  final VideoPlayerController controller;
  final Future<void> Function() _cleanup;
  bool _disposed = false;
  Completer<void>? _waitingForBuffer;

  static Future<StoryVideoSource> prepareEncoded(
    String data,
    String mime,
  ) async {
    // Native isolates keep a 30 MiB story's base64 decoding off the UI thread.
    final bytes = await compute(_decodeVideo, data);
    return prepare(bytes, mime);
  }

  static Future<StoryVideoSource> prepare(Uint8List bytes, String mime) async {
    final (controller, cleanup) = await platform.prepare(bytes, mime);
    return StoryVideoSource(controller, cleanup);
  }

  Future<void> initializeForPlayback() async {
    await controller.initialize().timeout(const Duration(seconds: 30));
    if (_disposed) throw StateError('Story video was closed');
    await controller.setLooping(true);
    final ready = Completer<void>();
    _waitingForBuffer = ready;
    void checkReady() {
      if (ready.isCompleted) return;
      final value = controller.value;
      if (_disposed || value.hasError) {
        ready.completeError(StateError('Unable to prepare story video'));
      } else if (value.isInitialized && !value.isBuffering) {
        ready.complete();
      }
    }

    controller.addListener(checkReady);
    try {
      checkReady();
      // The whole file/blob is local before initialization. Do not wait for a
      // buffered range: native local-file players need not report one.
      await ready.future.timeout(const Duration(seconds: 30));
    } finally {
      controller.removeListener(checkReady);
      _waitingForBuffer = null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final waiting = _waitingForBuffer;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(StateError('Story video was closed'));
    }
    try {
      await controller.dispose();
    } finally {
      await _cleanup();
    }
  }
}

Uint8List _decodeVideo(String data) {
  final separator = data.startsWith('data:') ? data.indexOf(',') : -1;
  return base64Decode(separator < 0 ? data : data.substring(separator + 1));
}
