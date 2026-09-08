import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import 'call_models.dart';
import 'call_noise_suppression.dart';

class SfuCallService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  bool _muted;
  bool _ended = false;

  SfuCallService({
    bool initialMuted = false,
    this.enhancedNoiseSuppression = false,
  }) : _muted = initialMuted;
  final bool enhancedNoiseSuppression;

  void Function(CallConnectionPhase phase)? onConnectionStateChanged;
  void Function(CallQualitySnapshot quality)? onQualityChanged;
  void Function(String identity)? onParticipantConnected;
  void Function(String identity)? onParticipantDisconnected;
  void Function(String message)? onError;

  bool get connected => _room?.connectionState == ConnectionState.connected;

  Future<void> connect({
    required String url,
    required String token,
    required String encryptionKey,
  }) async {
    if (_ended) throw StateError('SFU service is closed');
    final encryption = await E2EEOptions.sharedKey(encryptionKey);
    if (_ended) return;
    await CallNoiseSuppression.acquire(
      this,
      enhanced: enhancedNoiseSuppression,
    );
    if (_ended) {
      await CallNoiseSuppression.release(this);
      return;
    }
    onConnectionStateChanged?.call(CallConnectionPhase.connecting);
    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        encryption: encryption,
        defaultAudioCaptureOptions: const AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          highPassFilter: true,
        ),
      ),
    );
    final listener = room.createListener()
      ..on<RoomReconnectingEvent>((_) {
        onConnectionStateChanged?.call(CallConnectionPhase.disconnected);
      })
      ..on<RoomResumingEvent>((_) {
        onConnectionStateChanged?.call(CallConnectionPhase.connecting);
      })
      ..on<RoomReconnectedEvent>((_) {
        onConnectionStateChanged?.call(CallConnectionPhase.connected);
      })
      ..on<ParticipantConnectedEvent>((event) {
        onParticipantConnected?.call(event.participant.identity);
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        onParticipantDisconnected?.call(event.participant.identity);
      })
      ..on<RoomDisconnectedEvent>((event) {
        if (!_ended) {
          onConnectionStateChanged?.call(CallConnectionPhase.failed);
          onError?.call('SFU disconnected: ${event.reason ?? 'unknown'}');
        }
      })
      ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
        if (event.participant != room.localParticipant) return;
        final level = switch (event.connectionQuality) {
          ConnectionQuality.excellent || ConnectionQuality.good => 3,
          ConnectionQuality.poor => 2,
          ConnectionQuality.lost => 1,
          _ => 0,
        };
        onQualityChanged?.call(
          CallQualitySnapshot(
            route: 'sfu',
            packetLossPercent: level == 1 ? 10 : (level == 2 ? 4 : 0),
          ),
        );
      })
      ..on<TrackE2EEStateEvent>((event) {
        if (event.state == E2EEState.kMissingKey ||
            event.state == E2EEState.kEncryptionFailed ||
            event.state == E2EEState.kDecryptionFailed ||
            event.state == E2EEState.kInternalError) {
          onError?.call('Group-call encryption failed: ${event.state.name}');
          onConnectionStateChanged?.call(CallConnectionPhase.failed);
        }
      });
    _room = room;
    _listener = listener;
    try {
      await room.prepareConnection(url, token);
      await room.connect(url, token);
      if (_ended || !identical(_room, room)) {
        await room.disconnect();
        return;
      }
      await room.localParticipant?.setMicrophoneEnabled(!_muted);
      if (_ended || !identical(_room, room)) return;
      // Participants already present do not emit a new join event.
      for (final participant in room.remoteParticipants.values) {
        onParticipantConnected?.call(participant.identity);
      }
      onConnectionStateChanged?.call(CallConnectionPhase.connected);
      onQualityChanged?.call(const CallQualitySnapshot(route: 'sfu'));
    } catch (_) {
      await CallNoiseSuppression.release(this);
      if (identical(_room, room)) {
        _room = null;
        _listener = null;
      }
      await listener.dispose();
      await room.dispose();
      onConnectionStateChanged?.call(CallConnectionPhase.failed);
      rethrow;
    }
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
  }

  Future<void> setSpeakerEnabled(bool enabled) async {
    await AudioManager.instance.setSpeakerOutputPreferred(enabled);
  }

  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    final room = _room;
    final listener = _listener;
    _room = null;
    _listener = null;
    try {
      if (room != null) {
        await room.disconnect().catchError((_) {});
        await room.dispose();
      }
    } finally {
      try {
        await listener?.dispose();
      } finally {
        await CallNoiseSuppression.release(this);
      }
    }
    onConnectionStateChanged?.call(CallConnectionPhase.closed);
  }
}
