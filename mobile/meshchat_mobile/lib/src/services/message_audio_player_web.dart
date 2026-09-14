import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'audio_playback_source.dart';

class MessageAudioPlayer {
  final AudioPlayer _player = AudioPlayer();
  PreparedAudioSource? _source;

  Stream<Duration> get onDurationChanged => _player.onDurationChanged;
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;
  Stream<void> get onPlayerComplete => _player.onPlayerComplete;

  Future<void> setSource({
    required Uint8List bytes,
    required String filename,
  }) async {
    final prepared = await prepareAudioPlaybackSource(
      bytes: bytes,
      filename: filename,
    );
    try {
      await _player.setSource(prepared.source);
      final previous = _source;
      _source = prepared;
      await previous?.dispose();
    } catch (_) {
      await prepared.dispose();
      rethrow;
    }
  }

  Future<void> resume() => _player.resume();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> release() async {
    final source = _source;
    _source = null;
    try {
      await _player.release();
    } finally {
      await source?.dispose();
    }
  }

  Future<void> dispose() async {
    final source = _source;
    _source = null;
    try {
      await _player.dispose();
    } finally {
      await source?.dispose();
    }
  }
}
