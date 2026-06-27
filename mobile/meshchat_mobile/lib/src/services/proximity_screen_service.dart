import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ProximityScreenService {
  static const _channel = MethodChannel('meshchat/proximity_screen');

  bool _enabled = false;

  Future<void> setEnabled(bool enabled) async {
    if (kIsWeb || _enabled == enabled) return;
    _enabled = enabled;
    try {
      await _channel.invokeMethod<void>(enabled ? 'enable' : 'disable');
    } catch (_) {}
  }

  Future<void> dispose() => setEnabled(false);
}
