import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/session.dart';
import 'session_secret_store.dart';

class SessionStore {
  SessionStore({SessionSecretStore? secretStore})
    : _secretStore = secretStore ?? PlatformSessionSecretStore();

  static const _recentKey = 'recent_sessions';
  static const _pendingAuthenticationKey = 'pending_authentication_v1';
  static const _maxRecent = 8;
  static const _secretPrefix = 'meshchat.session.v1';

  final SessionSecretStore _secretStore;

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = _normalizeServerUrl(prefs.getString('server_url') ?? '');
    final login = (prefs.getString('login') ?? '').trim().toLowerCase();
    if (serverUrl.isEmpty || login.isEmpty) return null;
    final secrets = await _readSecrets(
      serverUrl,
      login,
      legacyPassword: prefs.getString('password') ?? '',
      legacyServerToken: prefs.getString('server_token') ?? '',
      legacyIdentityRecovery: prefs.getString('identity_recovery') ?? '',
    );
    final password = secrets.password;
    if (password.isEmpty) return null;

    await _removeLegacyCurrentSecrets(prefs);

    final nodeId = await _nodeIdFor(prefs, serverUrl, login);
    return Session(
      serverUrl: serverUrl,
      serverToken: secrets.serverToken,
      login: login,
      password: password,
      publicUsername: prefs.getString('public_username') ?? login,
      nodeId: nodeId,
      email: prefs.getString('email') ?? '',
      identityRecovery: secrets.identityRecovery,
    );
  }

  Future<List<Session>> loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final sessions = <Session>[];
      var containedLegacySecrets = false;
      for (final item in decoded.whereType<Map>()) {
        final json = Map<String, dynamic>.from(item);
        containedLegacySecrets =
            containedLegacySecrets ||
            json.containsKey('password') ||
            json.containsKey('server_token') ||
            json.containsKey('identity_recovery');
        final session = await _sessionFromJson(json);
        if (session == null) continue;
        final exists = sessions.any(
          (existing) =>
              _normalizeServerUrl(existing.serverUrl) ==
                  _normalizeServerUrl(session.serverUrl) &&
              existing.login.toLowerCase() == session.login.toLowerCase(),
        );
        if (!exists) sessions.add(session);
      }
      if (containedLegacySecrets) {
        await prefs.setString(
          _recentKey,
          jsonEncode(sessions.map(_sessionToJson).toList()),
        );
      }
      return sessions;
    } catch (_) {
      await prefs.remove(_recentKey);
      return const [];
    }
  }

  Future<Session> save({
    required String serverUrl,
    required String serverToken,
    required String login,
    required String password,
    required String publicUsername,
    String email = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final normalizedLogin = login.trim().toLowerCase();
    final nodeId = await _nodeIdFor(
      prefs,
      normalizedServerUrl,
      normalizedLogin,
    );

    final session = Session(
      serverUrl: normalizedServerUrl,
      serverToken: serverToken,
      login: normalizedLogin,
      password: password,
      publicUsername: publicUsername,
      nodeId: nodeId,
      email: email.trim().toLowerCase(),
    );

    await saveCurrent(session);
    await saveRecent(session);
    return session;
  }

  Future<Session> prepare({
    required String serverUrl,
    required String serverToken,
    required String login,
    required String password,
    required String publicUsername,
    String email = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final normalizedLogin = login.trim().toLowerCase();
    return Session(
      serverUrl: normalizedServerUrl,
      serverToken: serverToken,
      login: normalizedLogin,
      password: password,
      publicUsername: publicUsername,
      nodeId: await _nodeIdFor(prefs, normalizedServerUrl, normalizedLogin),
      email: email.trim().toLowerCase(),
    );
  }

  Future<void> savePendingAuthentication(PendingAuthentication pending) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeSecrets(pending.session);
    await prefs.setString(
      _pendingAuthenticationKey,
      jsonEncode({
        ..._sessionToJson(pending.session),
        'challenge_id': pending.challengeId,
        'masked_email': pending.maskedEmail,
        'registration': pending.registration,
        'expires_at': pending.expiresAt.toUtc().toIso8601String(),
        'resend_at': pending.resendAt.toUtc().toIso8601String(),
      }),
    );
  }

  Future<PendingAuthentication?> loadPendingAuthentication() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingAuthenticationKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final session = await _sessionFromJson(json);
      final challengeId = json['challenge_id']?.toString() ?? '';
      final expiresAt = DateTime.tryParse(json['expires_at']?.toString() ?? '');
      final resendAt = DateTime.tryParse(json['resend_at']?.toString() ?? '');
      if (session == null ||
          challengeId.isEmpty ||
          expiresAt == null ||
          resendAt == null ||
          !expiresAt.isAfter(DateTime.now().toUtc())) {
        await clearPendingAuthentication();
        return null;
      }
      return PendingAuthentication(
        session: session,
        challengeId: challengeId,
        maskedEmail: json['masked_email']?.toString() ?? '',
        registration: json['registration'] == true,
        expiresAt: expiresAt,
        resendAt: resendAt,
      );
    } catch (_) {
      await clearPendingAuthentication();
      return null;
    }
  }

  Future<void> clearPendingAuthentication() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingAuthenticationKey);
  }

  Future<void> saveCurrent(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeSecrets(session);
    await prefs.setString('server_url', session.serverUrl);
    await prefs.setString('login', session.login);
    await prefs.setString('public_username', session.publicUsername);
    await prefs.setString('node_id', session.nodeId);
    await prefs.setString('email', session.email);
    await _removeLegacyCurrentSecrets(prefs);
    await prefs.setString(
      _nodeKey(session.serverUrl, session.login),
      session.nodeId,
    );
  }

  Future<void> saveRecent(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = await loadRecent();
    final filtered = recent
        .where(
          (item) =>
              _normalizeServerUrl(item.serverUrl) !=
                  _normalizeServerUrl(session.serverUrl) ||
              item.login.toLowerCase() != session.login.toLowerCase(),
        )
        .toList();
    final next = [session, ...filtered].take(_maxRecent).toList();
    await _writeSecrets(session);
    final retainedAccounts = next.map(_accountKeyForSession).toSet();
    for (final evicted in recent) {
      if (!retainedAccounts.contains(_accountKeyForSession(evicted))) {
        await _deleteSecrets(evicted.serverUrl, evicted.login);
      }
    }
    await prefs.setString(
      _recentKey,
      jsonEncode(next.map(_sessionToJson).toList()),
    );
  }

  Future<void> removeRecent(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = await loadRecent();
    final next = recent
        .where(
          (item) =>
              _normalizeServerUrl(item.serverUrl) !=
                  _normalizeServerUrl(session.serverUrl) ||
              item.login.toLowerCase() != session.login.toLowerCase(),
        )
        .toList();
    await _deleteSecrets(session.serverUrl, session.login);
    await prefs.setString(
      _recentKey,
      jsonEncode(next.map(_sessionToJson).toList()),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server_url');
    await prefs.remove('login');
    await prefs.remove('public_username');
    await _removeLegacyCurrentSecrets(prefs);
    await prefs.remove('email');
  }

  Future<void> updatePublicUsername(String publicUsername) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('public_username', publicUsername);
    final current = await load();
    if (current != null) {
      await saveRecent(current.copyWith(publicUsername: publicUsername));
    }
  }

  Future<String> _nodeIdFor(
    SharedPreferences prefs,
    String serverUrl,
    String login,
  ) async {
    final key = _nodeKey(serverUrl, login);
    var nodeId = prefs.getString(key) ?? '';
    if (nodeId.isEmpty) {
      final currentLogin = prefs.getString('login') ?? '';
      final legacyNodeId = prefs.getString('node_id') ?? '';
      if (currentLogin.toLowerCase() == login.toLowerCase() &&
          legacyNodeId.isNotEmpty) {
        nodeId = legacyNodeId;
      } else {
        nodeId = const Uuid().v4();
      }
      await prefs.setString(key, nodeId);
    }
    return nodeId;
  }

  String _nodeKey(String serverUrl, String login) {
    final raw =
        '${_normalizeServerUrl(serverUrl)}|${login.trim().toLowerCase()}';
    return 'node_id_${base64Url.encode(utf8.encode(raw))}';
  }

  String _normalizeServerUrl(String value) {
    var url = value.trim();
    while (url.endsWith('/') && url.length > 'wss://x'.length) {
      url = url.substring(0, url.length - 1);
    }
    return url.toLowerCase();
  }

  Map<String, dynamic> _sessionToJson(Session session) {
    return {
      'server_url': session.serverUrl,
      'login': session.login,
      'public_username': session.publicUsername,
      'node_id': session.nodeId,
      'email': session.email,
    };
  }

  Future<Session?> _sessionFromJson(Map<String, dynamic> json) async {
    final serverUrl = _normalizeServerUrl(json['server_url']?.toString() ?? '');
    final login = (json['login']?.toString() ?? '').trim().toLowerCase();
    final nodeId = json['node_id']?.toString() ?? '';
    if (serverUrl.isEmpty || login.isEmpty || nodeId.isEmpty) {
      return null;
    }
    final secrets = await _readSecrets(
      serverUrl,
      login,
      legacyPassword: json['password']?.toString() ?? '',
      legacyServerToken: json['server_token']?.toString() ?? '',
      legacyIdentityRecovery: json['identity_recovery']?.toString() ?? '',
    );
    if (secrets.password.isEmpty) return null;
    return Session(
      serverUrl: serverUrl,
      serverToken: secrets.serverToken,
      login: login,
      password: secrets.password,
      publicUsername: json['public_username']?.toString() ?? login,
      nodeId: nodeId,
      email: json['email']?.toString() ?? '',
      identityRecovery: secrets.identityRecovery,
    );
  }

  Future<_SessionSecrets> _readSecrets(
    String serverUrl,
    String login, {
    String legacyPassword = '',
    String legacyServerToken = '',
    String legacyIdentityRecovery = '',
  }) async {
    var password = await _secretStore.read(
      _secretKey(serverUrl, login, 'password'),
    );
    var serverToken = await _secretStore.read(
      _secretKey(serverUrl, login, 'server_token'),
    );
    var identityRecovery = await _secretStore.read(
      _secretKey(serverUrl, login, 'identity_recovery'),
    );

    if ((password ?? '').isEmpty && legacyPassword.isNotEmpty) {
      password = legacyPassword;
      await _secretStore.write(
        _secretKey(serverUrl, login, 'password'),
        legacyPassword,
      );
    }
    if ((serverToken ?? '').isEmpty && legacyServerToken.isNotEmpty) {
      serverToken = legacyServerToken;
      await _secretStore.write(
        _secretKey(serverUrl, login, 'server_token'),
        legacyServerToken,
      );
    }
    if ((identityRecovery ?? '').isEmpty && legacyIdentityRecovery.isNotEmpty) {
      identityRecovery = legacyIdentityRecovery;
      await _secretStore.write(
        _secretKey(serverUrl, login, 'identity_recovery'),
        legacyIdentityRecovery,
      );
    }

    return _SessionSecrets(
      password: password ?? '',
      serverToken: serverToken ?? '',
      identityRecovery: identityRecovery ?? '',
    );
  }

  Future<void> _writeSecrets(Session session) async {
    await _writeOrDelete(
      _secretKey(session.serverUrl, session.login, 'password'),
      session.password,
    );
    await _writeOrDelete(
      _secretKey(session.serverUrl, session.login, 'server_token'),
      session.serverToken,
    );
    await _writeOrDelete(
      _secretKey(session.serverUrl, session.login, 'identity_recovery'),
      session.identityRecovery,
    );
  }

  Future<void> _writeOrDelete(String key, String value) {
    return value.isEmpty
        ? _secretStore.delete(key)
        : _secretStore.write(key, value);
  }

  Future<void> _deleteSecrets(String serverUrl, String login) async {
    for (final name in const [
      'password',
      'server_token',
      'identity_recovery',
    ]) {
      await _secretStore.delete(_secretKey(serverUrl, login, name));
    }
  }

  Future<void> _removeLegacyCurrentSecrets(SharedPreferences prefs) async {
    await prefs.remove('password');
    await prefs.remove('server_token');
    await prefs.remove('identity_recovery');
  }

  String _secretKey(String serverUrl, String login, String name) {
    final account = base64Url.encode(
      utf8.encode(
        '${_normalizeServerUrl(serverUrl)}|${login.trim().toLowerCase()}',
      ),
    );
    return '$_secretPrefix.$account.$name';
  }

  String _accountKeyForSession(Session session) =>
      '${_normalizeServerUrl(session.serverUrl)}|${session.login.toLowerCase()}';
}

class _SessionSecrets {
  const _SessionSecrets({
    required this.password,
    required this.serverToken,
    required this.identityRecovery,
  });

  final String password;
  final String serverToken;
  final String identityRecovery;
}

class PendingAuthentication {
  const PendingAuthentication({
    required this.session,
    required this.challengeId,
    required this.maskedEmail,
    required this.registration,
    required this.expiresAt,
    required this.resendAt,
  });

  final Session session;
  final String challengeId;
  final String maskedEmail;
  final bool registration;
  final DateTime expiresAt;
  final DateTime resendAt;
}
