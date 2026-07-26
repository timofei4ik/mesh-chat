// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html';
import 'dart:typed_data';

Future<bool> requestNotificationPermission() async {
  if (!Notification.supported) return false;
  if (Notification.permission == 'granted') return true;
  if (Notification.permission == 'denied') return false;
  final permission = await Notification.requestPermission();
  return permission == 'granted';
}

Future<void> showNotification({
  required String title,
  required String body,
  String? icon,
  Map<String, String>? target,
}) async {
  if (!Notification.supported) return;
  if (Notification.permission != 'granted') return;
  final notification = Notification(title, body: body, icon: icon);
  Timer(const Duration(seconds: 8), notification.close);
}

Map<String, String>? consumeInitialNotificationTarget() {
  final query = Uri.base.queryParameters;
  final target = <String, String>{
    'packet_type': query['notification_type'] ?? '',
    'source_node': query['source_node'] ?? '',
    'group_id': query['group_id'] ?? '',
    'call_id': query['call_id'] ?? '',
  };
  if (target.values.every((value) => value.isEmpty)) return null;
  window.history.replaceState(null, document.title, Uri.base.path);
  return target;
}

Future<void> cancelNotification(String tag) async {
  final serviceWorker = window.navigator.serviceWorker;
  if (serviceWorker == null) return;
  final registration = await serviceWorker.ready;
  final notifications = await registration.getNotifications({'tag': tag});
  for (final notification in notifications) {
    notification.close();
  }
}

Future<Map<String, dynamic>?> subscribeToPush(String vapidPublicKey) async {
  if (vapidPublicKey.trim().isEmpty) return null;
  final serviceWorker = window.navigator.serviceWorker;
  if (serviceWorker == null) return null;
  if (!await requestNotificationPermission()) return null;

  await serviceWorker.register('/push_service_worker.js');
  final registration = await serviceWorker.ready;
  final pushManager = registration.pushManager;
  if (pushManager == null) return null;

  final dynamic existingSubscription = await pushManager.getSubscription();
  final subscription = existingSubscription == null
      ? await pushManager.subscribe({
          'userVisibleOnly': true,
          'applicationServerKey': _urlBase64ToBytes(vapidPublicKey),
        })
      : existingSubscription as PushSubscription;

  return _subscriptionToJson(subscription);
}

Future<String?> unsubscribeFromPush() async {
  final serviceWorker = window.navigator.serviceWorker;
  if (serviceWorker == null) return null;
  final registration = await serviceWorker.ready;
  final subscription = await registration.pushManager?.getSubscription();
  final endpoint = subscription?.endpoint;
  await subscription?.unsubscribe();
  return endpoint;
}

String userAgent() => window.navigator.userAgent;

Map<String, dynamic> _subscriptionToJson(PushSubscription subscription) {
  return {
    'endpoint': subscription.endpoint,
    'expirationTime': subscription.expirationTime,
    'keys': {
      'p256dh': _bufferToBase64Url(subscription.getKey('p256dh')),
      'auth': _bufferToBase64Url(subscription.getKey('auth')),
    },
  };
}

Uint8List _urlBase64ToBytes(String value) {
  var normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  while (normalized.length % 4 != 0) {
    normalized += '=';
  }
  return base64Decode(normalized);
}

String _bufferToBase64Url(ByteBuffer? buffer) {
  if (buffer == null) return '';
  return base64UrlEncode(Uint8List.view(buffer)).replaceAll('=', '');
}
