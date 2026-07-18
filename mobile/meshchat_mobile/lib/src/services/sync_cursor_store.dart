import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';

class SyncCursorStore {
  static const _prefix = 'sync_v2_cursor_';

  static int safeCursor({
    required int accountCursor,
    required int? cacheCursor,
  }) {
    if (accountCursor < 0 || cacheCursor == null || cacheCursor < 0) return 0;
    return accountCursor < cacheCursor ? accountCursor : cacheCursor;
  }

  Future<int> load(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(session)) ?? 0;
  }

  Future<void> save(Session session, int cursor) async {
    if (cursor < 0) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _key(session);
    final current = prefs.getInt(key) ?? 0;
    if (cursor > current) {
      await prefs.setInt(key, cursor);
    }
  }

  Future<void> clear(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(session));
  }

  String _key(Session session) {
    final identity =
        '${_normalizeUrl(session.serverUrl)}|'
        '${session.login.trim().toLowerCase()}';
    return '$_prefix${base64Url.encode(utf8.encode(identity))}';
  }

  String _normalizeUrl(String value) {
    var url = value.trim().toLowerCase();
    while (url.endsWith('/') && url.length > 'wss://x'.length) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
