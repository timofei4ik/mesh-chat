import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 1;

  Future<void> initialize() async {
    if (kIsWeb || _initialized) return;

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
  }

  Future<void> requestPermissions() async {
    if (kIsWeb) return;
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

  Future<void> showMessage({
    required String title,
    required String body,
    bool sound = true,
    bool vibration = true,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) await initialize();

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
}
