Future<bool> requestNotificationPermission() async => false;

Future<void> showNotification({
  required String title,
  required String body,
  String? icon,
  Map<String, String>? target,
}) async {}

Map<String, String>? consumeInitialNotificationTarget() => null;

Future<void> cancelNotification(String tag) async {}

Future<Map<String, dynamic>?> subscribeToPush(String vapidPublicKey) async =>
    null;

Future<String?> unsubscribeFromPush() async => null;

String userAgent() => '';
