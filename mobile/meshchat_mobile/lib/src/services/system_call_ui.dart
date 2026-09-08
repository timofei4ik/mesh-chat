import 'package:flutter/services.dart';

/// Opt-in bridge; enable only after authenticated call signaling and APNs setup.
class SystemCallUi {
  SystemCallUi({required this.onAction, this.enabled = false});

  final bool enabled;
  final Future<bool> Function(String action, String callId) onAction;
  static const channel = MethodChannel('meshchat/system_calls');

  void initialize() {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final id = args['callId']?.toString() ?? '';
      if (!{'answer', 'end', 'reset'}.contains(call.method)) return false;
      return onAction(call.method, id);
    });
  }

  Future<bool> reportIncoming(String callId, String name) async {
    if (!enabled) return false;
    return await channel.invokeMethod<bool>('incoming', {
          'callId': callId,
          'name': name,
        }) ??
        false;
  }

  Future<void> reportEnded(String callId) async {
    if (!enabled) return;
    await channel.invokeMethod<void>('ended', {'callId': callId});
  }

  void dispose() {
    if (enabled) channel.setMethodCallHandler(null);
  }
}
