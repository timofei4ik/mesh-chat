import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/session.dart';

class SessionStore {
  static const _recentKey = 'recent_sessions';
  static const _maxRecent = 8;

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = _normalizeServerUrl(prefs.getString('server_url') ?? '');
    final login = (prefs.getString('login') ?? '').trim().toLowerCase();
    final password = prefs.getString('password') ?? '';
    if (serverUrl.isEmpty || login.isEmpty || password.isEmpty) return null;

    final nodeId = await _nodeIdFor(prefs, serverUrl, login);
    return Session(
      serverUrl: serverUrl,
      serverToken: prefs.getString('server_token') ?? '',
      login: login,
      password: password,
      publicUsername: prefs.getString('public_username') ?? login,
      nodeId: nodeId,
      identityRecovery: prefs.getString('identity_recovery') ?? '',
    );
  }

  Future<List<Session>> loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => _sessionFromJson(Map<String, dynamic>.from(item)))
          .whereType<Session>()
          .fold<List<Session>>([], (items, session) {
            final exists = items.any(
              (item) =>
                  _normalizeServerUrl(item.serverUrl) ==
                      _normalizeServerUrl(session.serverUrl) &&
                  item.login.toLowerCase() == session.login.toLowerCase(),
            );
            if (!exists) items.add(session);
            return items;
          })
          .toList();
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
    );

    await saveCurrent(session);
    await saveRecent(session);
    return session;
  }

  Future<void> saveCurrent(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', session.serverUrl);
    await prefs.setString('server_token', session.serverToken);
    await prefs.setString('login', session.login);
    await prefs.setString('password', session.password);
    await prefs.setString('public_username', session.publicUsername);
    await prefs.setString('node_id', session.nodeId);
    await prefs.setString('identity_recovery', session.identityRecovery);
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
    await prefs.setString(
      _recentKey,
      jsonEncode(next.map(_sessionToJson).toList()),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server_url');
    await prefs.remove('server_token');
    await prefs.remove('login');
    await prefs.remove('password');
    await prefs.remove('public_username');
    await prefs.remove('identity_recovery');
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
      'server_token': session.serverToken,
      'login': session.login,
      'password': session.password,
      'public_username': session.publicUsername,
      'node_id': session.nodeId,
      'identity_recovery': session.identityRecovery,
    };
  }

  Session? _sessionFromJson(Map<String, dynamic> json) {
    final serverUrl = _normalizeServerUrl(json['server_url']?.toString() ?? '');
    final login = (json['login']?.toString() ?? '').trim().toLowerCase();
    final password = json['password']?.toString() ?? '';
    final nodeId = json['node_id']?.toString() ?? '';
    if (serverUrl.isEmpty ||
        login.isEmpty ||
        password.isEmpty ||
        nodeId.isEmpty) {
      return null;
    }
    return Session(
      serverUrl: serverUrl,
      serverToken: json['server_token']?.toString() ?? '',
      login: login,
      password: password,
      publicUsername: json['public_username']?.toString() ?? login,
      nodeId: nodeId,
      identityRecovery: json['identity_recovery']?.toString() ?? '',
    );
  }
}
