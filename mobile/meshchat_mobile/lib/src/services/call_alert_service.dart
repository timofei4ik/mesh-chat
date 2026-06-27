import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';

class CallAlertService {
  AudioPlayer? _player;
  Timer? _vibrationTimer;
  String _activeCallId = '';

  Future<void> sync(AppController controller) async {
    final call = controller.activeCall;
    final shouldAlert =
        call != null && call.incoming && call.status == CallStatus.ringing;
    if (!shouldAlert) {
      await stop();
      return;
    }
    if (_activeCallId == call.callId) return;
    await stop();
    _activeCallId = call.callId;
    if (controller.appSettings.notificationSound) {
      await _startSound();
    }
    if (controller.appSettings.notificationVibration) {
      _startVibration();
    }
  }

  Future<void> stop() async {
    _activeCallId = '';
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
    await _player?.stop().catchError((_) {});
  }

  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
    _player = null;
  }

  Future<void> _startSound() async {
    final player = _player ??= AudioPlayer();
    await player.setReleaseMode(ReleaseMode.loop).catchError((_) {});
    await player
        .play(BytesSource(_incomingRingtoneWav()), volume: 0.42)
        .catchError((_) {});
  }

  void _startVibration() {
    HapticFeedback.vibrate();
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      HapticFeedback.vibrate();
    });
  }

  Uint8List _incomingRingtoneWav() {
    const sampleRate = 22050;
    const seconds = 2.6;
    final samples = (sampleRate * seconds).round();
    final dataBytes = samples * 2;
    final bytes = Uint8List(44 + dataBytes);
    final data = ByteData.sublistView(bytes);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, 36 + dataBytes, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final local = t % seconds;
      final inTone =
          local < 0.36 ||
          (local > 0.56 && local < 0.92) ||
          (local > 1.22 && local < 1.58);
      var sample = 0.0;
      if (inTone) {
        final toneT = local < 0.36
            ? local
            : local < 0.92
            ? local - 0.56
            : local - 1.22;
        final attack = (toneT / 0.07).clamp(0.0, 1.0);
        final release = ((0.34 - toneT) / 0.12).clamp(0.0, 1.0);
        final envelope = math.sin(math.pi * math.min(attack, release) / 2);
        final base = math.sin(2 * math.pi * 587.33 * t);
        final harmony = math.sin(2 * math.pi * 783.99 * t) * 0.28;
        sample = (base + harmony) * 0.18 * envelope;
      }
      data.setInt16(44 + i * 2, (sample * 32767).round(), Endian.little);
    }
    return bytes;
  }
}
