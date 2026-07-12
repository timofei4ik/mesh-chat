import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';
import '../models/session.dart';

class OwnProfileStore {
  static const _prefix = 'own_profile_v1_';

  Future<Profile?> load(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(session));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final profile = Profile.fromJson(Map<String, dynamic>.from(decoded));
      if (profile.displayName.trim().isEmpty) return null;
      return _forSession(profile, session);
    } catch (_) {
      await prefs.remove(_key(session));
      return null;
    }
  }

  Future<void> save(Session session, Profile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(session),
      jsonEncode(_forSession(profile, session).toJson()),
    );
  }

  Future<void> remove(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(session));
  }

  Profile _forSession(Profile profile, Session session) {
    return profile.copyWith(
      nodeId: session.nodeId,
      accountLogin: session.login,
      nodeAliases: <String>{
        ...profile.nodeAliases,
        profile.nodeId,
        session.nodeId,
      }.where((value) => value.isNotEmpty).toList(),
      publicUsername: profile.publicUsername.trim().isEmpty
          ? session.publicUsername
          : null,
      online: false,
    );
  }

  String _key(Session session) {
    final server = session.serverUrl.trim().toLowerCase().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final account = session.login.trim().toLowerCase();
    final encoded = base64Url.encode(utf8.encode('$server|$account'));
    return '$_prefix$encoded';
  }
}
