class Session {
  const Session({
    required this.serverUrl,
    required this.serverToken,
    required this.login,
    required this.password,
    required this.publicUsername,
    required this.nodeId,
    this.email = '',
    this.identityRecovery = '',
  });

  final String serverUrl;
  final String serverToken;
  final String login;
  final String password;
  final String publicUsername;
  final String nodeId;
  final String email;
  final String identityRecovery;

  bool isSameAccountAs(Session? other) {
    if (other == null) return false;
    return _normalizeServerUrl(serverUrl) ==
            _normalizeServerUrl(other.serverUrl) &&
        login.trim().toLowerCase() == other.login.trim().toLowerCase();
  }

  static String _normalizeServerUrl(String value) {
    var normalized = value.trim().toLowerCase();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  Session copyWith({
    String? serverUrl,
    String? serverToken,
    String? login,
    String? password,
    String? publicUsername,
    String? nodeId,
    String? email,
    String? identityRecovery,
  }) {
    return Session(
      serverUrl: serverUrl ?? this.serverUrl,
      serverToken: serverToken ?? this.serverToken,
      login: login ?? this.login,
      password: password ?? this.password,
      publicUsername: publicUsername ?? this.publicUsername,
      nodeId: nodeId ?? this.nodeId,
      email: email ?? this.email,
      identityRecovery: identityRecovery ?? this.identityRecovery,
    );
  }
}
