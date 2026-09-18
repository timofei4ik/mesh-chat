import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import 'audio_playback_source.dart';

class MessageAudioPlayer {
  static MessageAudioPlayer? _active;
  final _durationController = StreamController<Duration>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _completeController = StreamController<void>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Player? _player;
  PreparedAudioSource? _source;
  bool _disposed = false;

  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;
  Stream<bool> get onPlayingChanged => _playingController.stream;
  Future<Duration?> getDuration() async => _player?.state.duration;

  Player _ensurePlayer() {
    if (_disposed) throw StateError('Audio player has been disposed');
    final existing = _player;
    if (existing != null) return existing;
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _subscriptions.addAll([
      player.stream.duration.listen(_durationController.add),
      player.stream.position.listen(_positionController.add),
      player.stream.playing.listen(_playingController.add),
      player.stream.completed.where((completed) => completed).listen((_) {
        _completeController.add(null);
      }),
    ]);
    return player;
  }

  Future<void> setSource({
    required Uint8List bytes,
    required String filename,
  }) async {
    final prepared = await prepareAudioPlaybackSource(
      bytes: bytes,
      filename: filename,
    );
    if (_disposed) {
      await prepared.dispose();
      throw StateError('Audio player has been disposed');
    }
    final path = prepared.devicePath;
    if (path == null || path.isEmpty) {
      await prepared.dispose();
      throw StateError('Native audio source has no file path');
    }
    try {
      await _ensurePlayer().open(Media(path), play: false);
      final previous = _source;
      _source = prepared;
      await previous?.dispose();
    } catch (_) {
      await prepared.dispose();
      rethrow;
    }
  }

  Future<void> resume() async {
    if (_active != this) await _active?.pause();
    _active = this;
    await _ensurePlayer().play();
  }

  Future<void> setRate(double rate) => _ensurePlayer().setRate(rate);

  Future<void> pause() async {
    final player = _player;
    if (player != null) await player.pause();
  }

  Future<void> stop() async {
    final player = _player;
    if (player != null) await player.stop();
  }

  Future<void> seek(Duration position) async {
    final player = _player;
    if (player != null) await player.seek(position);
  }

  Future<void> release() async {
    final source = _source;
    _source = null;
    try {
      await stop();
    } finally {
      await source?.dispose();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_active == this) _active = null;
    final player = _player;
    final source = _source;
    _player = null;
    _source = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await player?.dispose();
    } finally {
      await source?.dispose();
      await _durationController.close();
      await _positionController.close();
      await _completeController.close();
      await _playingController.close();
    }
  }
}
