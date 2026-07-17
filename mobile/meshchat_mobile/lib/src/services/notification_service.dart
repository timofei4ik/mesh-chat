import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'android_push_service.dart';
import 'notification_web_stub.dart'
    if (dart.library.html) 'notification_web.dart'
    as web_notifications;

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 1;
  final AndroidPushService _androidPush = AndroidPushService();
  ValueChanged<String>? onAndroidPushToken;

  Future<void> refreshAndroidPushToken() async {
    await _androidPush.initialize(
      onTokenChanged: (token) => onAndroidPushToken?.call(token),
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      return;
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    const windows = WindowsInitializationSettings(
      appName: 'MeshChat',
      appUserModelId: 'MeshChat.Mobile',
      guid: '9d5be2d2-2f4a-43de-a52d-51d9423b5f71',
    );
    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(settings: settings);
    _initialized = true;
    await requestPermissions();
    await refreshAndroidPushToken();
  }

  Future<void> requestPermissions() async {
    if (kIsWeb) {
      await web_notifications.requestNotificationPermission();
      return;
    }
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<Map<String, dynamic>?> subscribeToPush(String vapidPublicKey) async {
    if (!kIsWeb) return null;
    return web_notifications.subscribeToPush(vapidPublicKey);
  }

  Future<String?> unsubscribeFromPush() async {
    if (!kIsWeb) return null;
    return web_notifications.unsubscribeFromPush();
  }

  String webUserAgent() => kIsWeb ? web_notifications.userAgent() : '';

  Future<void> showMessage({
    required String title,
    required String body,
    bool sound = true,
    bool vibration = true,
  }) async {
    if (!_initialized) await initialize();
    if (kIsWeb) {
      await web_notifications.showNotification(
        title: title.trim().isEmpty ? 'MeshChat' : title.trim(),
        body: body.trim().isEmpty ? 'New message' : body.trim(),
        icon: 'icons/Icon-192.png',
      );
      return;
    }

    final android = AndroidNotificationDetails(
      'meshchat_messages',
      'Messages',
      channelDescription: 'New MeshChat messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      playSound: sound,
      enableVibration: vibration,
    );
    final darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: sound,
    );
    final details = NotificationDetails(android: android, iOS: darwin);

    await _plugin.show(
      id: _nextId++,
      title: title.trim().isEmpty ? 'MeshChat' : title.trim(),
      body: body.trim().isEmpty ? 'New message' : body.trim(),
      notificationDetails: details,
    );
  }

  Future<void> showCall({
    required String title,
    required String body,
    bool sound = true,
    bool vibration = true,
  }) async {
    if (!_initialized) await initialize();
    if (kIsWeb) {
      await web_notifications.showNotification(
        title: title.trim().isEmpty ? 'MeshChat call' : title.trim(),
        body: body.trim().isEmpty ? 'Incoming call' : body.trim(),
        icon: 'icons/Icon-192.png',
      );
      return;
    }

    final android = AndroidNotificationDetails(
      'meshchat_calls',
      'Calls',
      channelDescription: 'Incoming MeshChat calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      playSound: sound,
      enableVibration: vibration,
      ongoing: true,
      autoCancel: true,
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
    );
    final darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: sound,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const windows = WindowsNotificationDetails();
    final details = NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
      windows: windows,
    );

    await _plugin.show(
      id: 100000 + _nextId++,
      title: title.trim().isEmpty ? 'MeshChat call' : title.trim(),
      body: body.trim().isEmpty ? 'Incoming call' : body.trim(),
      notificationDetails: details,
    );
  }
}
