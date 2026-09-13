import 'dart:io';

import 'package:flutter/services.dart';

const applePushBuildEnabled = bool.fromEnvironment('MESH_ENABLE_APPLE_PUSH');

class ApplePushToken {
  const ApplePushToken({
    required this.token,
    required this.kind,
    required this.environment,
  });

  final String token;
  final String kind;
  final String environment;
}

class ApplePushService {
  static const _channel = MethodChannel('meshchat/apple_push');
  bool _initialized = false;

  Future<void> initialize({
    required void Function(ApplePushToken token) onTokenChanged,
    required void Function(Map<dynamic, dynamic> payload) onNotificationOpened,
  }) async {
    if (_initialized || !Platform.isIOS || !applePushBuildEnabled) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      if (arguments is! Map) return;
      if (call.method == 'token') {
        final token = ApplePushToken(
          token: arguments['token']?.toString() ?? '',
          kind: arguments['kind']?.toString() ?? 'alert',
          environment: arguments['environment']?.toString() ?? 'production',
        );
        if (token.token.isNotEmpty) onTokenChanged(token);
      } else if (call.method == 'notificationOpened') {
        onNotificationOpened(arguments);
      }
    });
    try {
      await _channel.invokeMethod<void>('initialize', {'enableVoip': true});
    } on PlatformException {
      _initialized = false;
    }
  }
}
