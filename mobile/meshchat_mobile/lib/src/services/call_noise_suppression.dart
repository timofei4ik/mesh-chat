import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The native capture processor is process-wide, including SFU and mesh peers.
/// Keep it alive until the last enhanced call releases its microphone.
class CallNoiseSuppression {
  static const channel = MethodChannel('meshchat/noise_suppression');
  static const _webrtcChannel = MethodChannel('FlutterWebRTC.Method');
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;
  static MethodChannel get _channel => _android ? channel : _webrtcChannel;
  static String _method(String name) => _android
      ? name
      : name == 'configure'
      ? 'meshNoiseConfigure'
      : 'meshNoiseStatus';
  static final _owners = <Object>{};
  static Future<void> _pending = Future.value();
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> acquire(Object owner, {required bool enhanced}) {
    if (!supported) return Future.value();
    return _serialize(() async {
      if (enhanced) {
        _owners.add(owner);
      } else {
        _owners.remove(owner);
      }
      try {
        await WebRTC.initialize(
          options: {
            'bypassVoiceProcessing': false,
            'androidUseHardwareAudioProcessing': false,
            'audioSampleRate': 48000,
          },
        );
        await _channel.invokeMethod<bool>(_method('configure'), {
          'enabled': _owners.isNotEmpty,
        });
      } on PlatformException catch (_) {
        // A missing filter must never prevent an ordinary WebRTC call.
      } on MissingPluginException catch (_) {}
    });
  }

  static Future<void> release(Object owner) {
    if (!supported) return Future.value();
    return _serialize(() async {
      if (!_owners.remove(owner)) return;
      try {
        await _channel.invokeMethod<bool>(_method('configure'), {
          'enabled': _owners.isNotEmpty,
        });
      } on PlatformException catch (_) {
      } on MissingPluginException catch (_) {}
    });
  }

  static Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  static Future<Map<String, dynamic>> status() async {
    if (!supported) return {'supported': false};
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
            _method('status'),
          ) ??
          {};
    } on PlatformException catch (_) {
      return {'supported': false};
    } on MissingPluginException catch (_) {
      return {'supported': false};
    }
  }
}
