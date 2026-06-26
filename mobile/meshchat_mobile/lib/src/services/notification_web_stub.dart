Future<bool> requestNotificationPermission() async => false;

Future<void> showNotification({
  required String title,
  required String body,
  String? icon,
}) async {}

Future<Map<String, dynamic>?> subscribeToPush(String vapidPublicKey) async =>
    null;

Future<String?> unsubscribeFromPush() async => null;

String userAgent() => '';
