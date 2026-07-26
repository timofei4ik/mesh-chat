import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'android_push_service.dart';
import 'notification_web_stub.dart'
    if (dart.library.html) 'notification_web.dart'
    as web_notifications;

class NotificationTarget {
  const NotificationTarget({
    this.packetType = '',
    this.sourceNode = '',
    this.groupId = '',
    this.callId = '',
  });

  final String packetType;
  final String sourceNode;
  final String groupId;
  final String callId;

  bool get isEmpty => sourceNode.isEmpty && groupId.isEmpty && callId.isEmpty;

  Map<String, String> toMap() => {
    'packet_type': packetType,
    'source_node': sourceNode,
    'group_id': groupId,
    'call_id': callId,
  };

  String encode() => jsonEncode(toMap());

  factory NotificationTarget.fromMap(Map<dynamic, dynamic> raw) {
    return NotificationTarget(
      packetType:
          raw['packet_type']?.toString() ?? raw['type']?.toString() ?? '',
      sourceNode: raw['source_node']?.toString() ?? '',
      groupId: raw['group_id']?.toString() ?? '',
      callId: raw['call_id']?.toString() ?? '',
    );
  }

  static NotificationTarget? decode(String? payload) {
    if (payload == null || payload.trim().isEmpty) return null;
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map) return null;
      final target = NotificationTarget.fromMap(raw);
      return target.isEmpty ? null : target;
    } catch (_) {
      return null;
    }
  }
}

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final AndroidPushService _androidPush = AndroidPushService();
  ValueChanged<String>? onAndroidPushToken;
  ValueChanged<NotificationTarget>? onActivated;
  final Map<String, DateTime> _recentNotifications = {};
  final Map<String, int> _callNotificationIds = {};

  Future<void> refreshAndroidPushToken() async {
    await _androidPush.initialize(
      onTokenChanged: (token) => onAndroidPushToken?.call(token),
      onNotificationOpened: _activateFromMap,
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      final initial = web_notifications.consumeInitialNotificationTarget();
      if (initial != null) _activateFromMap(initial);
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

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    _initialized = true;
    await requestPermissions();
    await refreshAndroidPushToken();
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await const MethodChannel('meshchat/window').invokeMethod<void>('show');
    }
    final target = NotificationTarget.decode(response.payload);
    if (target != null) onActivated?.call(target);
  }

  void _activateFromMap(Map<dynamic, dynamic> raw) {
    final target = NotificationTarget.fromMap(raw);
    if (!target.isEmpty) onActivated?.call(target);
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
    String notificationKey = '',
    NotificationTarget target = const NotificationTarget(),
  }) async {
    if (!_initialized) await initialize();
    final key = notificationKey.trim().isEmpty
        ? 'message:${target.groupId}:${target.sourceNode}:$title:$body'
        : notificationKey.trim();
    if (_isRecentDuplicate(key)) return;
    final id = _stableNotificationId(key);
    if (kIsWeb) {
      await web_notifications.showNotification(
        title: title.trim().isEmpty ? 'MeshChat' : title.trim(),
        body: body.trim().isEmpty ? 'New message' : body.trim(),
        icon: 'icons/Icon-192.png',
        target: target.toMap(),
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
    const windows = WindowsNotificationDetails();
    const linux = LinuxNotificationDetails(defaultActionName: 'Open');
    final details = NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.show(
      id: id,
      title: title.trim().isEmpty ? 'MeshChat' : title.trim(),
      body: body.trim().isEmpty ? 'New message' : body.trim(),
      notificationDetails: details,
      payload: target.encode(),
    );
  }

  Future<void> showCall({
    required String title,
    required String body,
    bool sound = true,
    bool vibration = true,
    required String callId,
    NotificationTarget target = const NotificationTarget(),
  }) async {
    if (!_initialized) await initialize();
    final key = 'call:$callId';
    final id = _stableNotificationId(key, call: true);
    _callNotificationIds[callId] = id;
    if (_isRecentDuplicate(key)) return;
    if (kIsWeb) {
      await web_notifications.showNotification(
        title: title.trim().isEmpty ? 'MeshChat call' : title.trim(),
        body: body.trim().isEmpty ? 'Incoming call' : body.trim(),
        icon: 'icons/Icon-192.png',
        target: target.toMap(),
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
      id: id,
      title: title.trim().isEmpty ? 'MeshChat call' : title.trim(),
      body: body.trim().isEmpty ? 'Incoming call' : body.trim(),
      notificationDetails: details,
      payload: target.encode(),
    );
  }

  Future<void> cancelCall(String callId) async {
    if (callId.trim().isEmpty) return;
    final id =
        _callNotificationIds.remove(callId) ??
        _stableNotificationId('call:$callId', call: true);
    _recentNotifications.remove('call:$callId');
    if (kIsWeb) {
      await web_notifications.cancelNotification('call:$callId');
      return;
    }
    await _plugin.cancel(id: id);
  }

  bool _isRecentDuplicate(String key) {
    final now = DateTime.now();
    _recentNotifications.removeWhere(
      (_, time) => now.difference(time) > const Duration(minutes: 2),
    );
    final previous = _recentNotifications[key];
    _recentNotifications[key] = now;
    return previous != null &&
        now.difference(previous) < const Duration(seconds: 8);
  }

  int _stableNotificationId(String key, {bool call = false}) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    final value = hash % 90000000;
    return call ? 100000000 + value : value;
  }
}
