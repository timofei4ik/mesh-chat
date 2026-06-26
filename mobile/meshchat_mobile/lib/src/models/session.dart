class Session {
  const Session({
    required this.serverUrl,
    required this.serverToken,
    required this.login,
    required this.password,
    required this.publicUsername,
    required this.nodeId,
  });

  final String serverUrl;
  final String serverToken;
  final String login;
  final String password;
  final String publicUsername;
  final String nodeId;

  Session copyWith({
    String? serverUrl,
    String? serverToken,
    String? login,
    String? password,
    String? publicUsername,
    String? nodeId,
  }) {
    return Session(
      serverUrl: serverUrl ?? this.serverUrl,
      serverToken: serverToken ?? this.serverToken,
      login: login ?? this.login,
      password: password ?? this.password,
      publicUsername: publicUsername ?? this.publicUsername,
      nodeId: nodeId ?? this.nodeId,
    );
  }
}
