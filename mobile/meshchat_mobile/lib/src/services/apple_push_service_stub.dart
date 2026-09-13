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
  Future<void> initialize({
    required void Function(ApplePushToken token) onTokenChanged,
    required void Function(Map<dynamic, dynamic> payload) onNotificationOpened,
  }) async {}
}
