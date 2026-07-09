import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import '../models/sticker_pack.dart';

class StickerStore {
  Future<StickerLibrary> load(Session? session) async {
    if (session == null) return const StickerLibrary();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(session));
    if (raw == null || raw.isEmpty) return const StickerLibrary();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const StickerLibrary();
      return StickerLibrary.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const StickerLibrary();
    }
  }

  Future<void> save(Session? session, StickerLibrary library) async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(session), jsonEncode(library.toJson()));
  }

  String _key(Session session) => 'meshchat_stickers_${session.login}';
}
