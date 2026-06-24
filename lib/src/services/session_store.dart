import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/session.dart';

class SessionStore {
  static const _recentKey = 'recent_sessions';
  static const _maxRecent = 8;

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('server_url') ?? '';
    final login = prefs.getString('login') ?? '';
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
    final normalizedLogin = login.trim().toLowerCase();
    final nodeId = await _nodeIdFor(prefs, serverUrl, normalizedLogin);

    final session = Session(
      serverUrl: serverUrl,
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
              item.serverUrl != session.serverUrl ||
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
              item.serverUrl != session.serverUrl ||
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
        '${serverUrl.trim().toLowerCase()}|${login.trim().toLowerCase()}';
    return 'node_id_${base64Url.encode(utf8.encode(raw))}';
  }

  Map<String, dynamic> _sessionToJson(Session session) {
    return {
      'server_url': session.serverUrl,
      'server_token': session.serverToken,
      'login': session.login,
      'password': session.password,
      'public_username': session.publicUsername,
      'node_id': session.nodeId,
    };
  }

  Session? _sessionFromJson(Map<String, dynamic> json) {
    final serverUrl = json['server_url']?.toString() ?? '';
    final login = json['login']?.toString() ?? '';
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
    );
  }
}
