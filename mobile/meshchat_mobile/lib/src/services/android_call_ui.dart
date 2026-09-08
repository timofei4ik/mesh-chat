import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

class AndroidCallAction {
  AndroidCallAction(Map<dynamic, dynamic> raw)
    : callId = raw['call_id']?.toString() ?? '',
      action = raw['action']?.toString() ?? '',
      expiresAt = (raw['expires_at'] as num?)?.toInt() ?? 0;

  final String callId;
  final String action;
  final int expiresAt;

  bool get expired => expiresAt <= DateTime.now().millisecondsSinceEpoch;
  bool matches(String? id) =>
      !expired &&
      callId.isNotEmpty &&
      callId == id &&
      const {'answer', 'decline', 'end'}.contains(action);
}

/// Actions remain on Android until the authenticated signaling call is ready.
class AndroidCallUi {
  static const _channel = MethodChannel('meshchat/android_calls');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> isBackgroundEngine() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('background') ?? false;
    } on MissingPluginException catch (_) {
      return false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  Future<void> clear() async {
    presented.clear();
    await _send('clear', 'all');
  }

  Future<void> configure({
    required bool enabled,
    required bool sound,
    required bool vibration,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('preferences', {
        'enabled': enabled,
        'sound': sound,
        'vibration': vibration,
      });
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  Future<bool> Function(AndroidCallAction)? onAction;
  final Set<String> presented = {};
  bool _draining = false;
  bool _again = false;
  bool _initialized = false;

  Future<void> initialize() async {
    if (!supported) return;
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'actionsAvailable') await drain();
    });
    await drain();
  }

  void dispose() {
    onAction = null;
    if (_initialized) _channel.setMethodCallHandler(null);
    _initialized = false;
  }

  Future<void> drain() async {
    if (!supported) return;
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    try {
      do {
        _again = false;
        final raw = await _channel.invokeListMethod<dynamic>('actions') ?? [];
        for (final item in raw.whereType<Map>()) {
          final action = AndroidCallAction(item);
          if (action.expired) {
            await end(action.callId);
          } else if (await onAction?.call(action) == true) {
            await _channel.invokeMethod<void>('ack', {
              'call_id': action.callId,
              'action': action.action,
            });
          }
        }
      } while (_again);
    } on PlatformException catch (_) {
      // Notification fallback remains available on unsupported Android builds.
    } on MissingPluginException catch (_) {
    } finally {
      _draining = false;
    }
  }

  Future<bool> show(Map<String, String> payload) async {
    if (!supported) return false;
    try {
      final shown =
          await _channel.invokeMethod<bool>('incoming', payload) ?? false;
      if (shown) presented.add(payload['call_id']!);
      return shown;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  Future<void> end(String id) async {
    presented.remove(id);
    await _send('ended', id);
  }

  Future<void> answered(String id) => _send('answered', id);

  Future<void> connected(String id) async {
    if (!supported) return;
    try {
      await FlutterCallkitIncoming.setCallConnected(id);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  Future<void> _send(String method, String id) async {
    if (!supported || id.isEmpty) return;
    try {
      await _channel.invokeMethod<void>(method, {'call_id': id});
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  static Future<void> requestLockScreenPermission() async {
    if (!supported) return;
    await FlutterCallkitIncoming.requestFullIntentPermission();
  }
}
