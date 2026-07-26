import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _apiKey = String.fromEnvironment('MESH_FIREBASE_API_KEY');
const _appId = String.fromEnvironment('MESH_FIREBASE_APP_ID');
const _senderId = String.fromEnvironment('MESH_FIREBASE_MESSAGING_SENDER_ID');
const _projectId = String.fromEnvironment('MESH_FIREBASE_PROJECT_ID');
const _storageBucket = String.fromEnvironment('MESH_FIREBASE_STORAGE_BUCKET');

Future<void> initializeAndroidPushBackgroundHandling() async {}

class AndroidPushService {
  static const _channel = MethodChannel('meshchat/android_push');
  bool _handlerInstalled = false;

  Future<String?> initialize({
    ValueChanged<String>? onTokenChanged,
    ValueChanged<Map<dynamic, dynamic>>? onNotificationOpened,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      if (!_handlerInstalled) {
        _handlerInstalled = true;
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'notificationOpened' && call.arguments is Map) {
            onNotificationOpened?.call(call.arguments as Map);
          }
        });
      }
      final token = await _channel.invokeMethod<String>('initialize', {
        'apiKey': _apiKey,
        'appId': _appId,
        'senderId': _senderId,
        'projectId': _projectId,
        'storageBucket': _storageBucket,
      });
      if (token != null && token.isNotEmpty) onTokenChanged?.call(token);
      final initial = await _channel.invokeMapMethod<dynamic, dynamic>(
        'consumeNotificationLaunch',
      );
      if (initial != null && initial.isNotEmpty) {
        onNotificationOpened?.call(initial);
      }
      return token;
    } on PlatformException catch (error) {
      debugPrint('Android push is not configured: ${error.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
