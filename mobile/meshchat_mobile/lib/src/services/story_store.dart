import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import '../models/story_item.dart';

class StoryStore {
  Future<Map<String, StoryItem>> load(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(session));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      final stories = <String, StoryItem>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final story = StoryItem.fromJson(Map<String, dynamic>.from(item));
        if (story.id.isEmpty || story.expired) continue;
        stories[story.id] = story;
      }
      return stories;
    } catch (_) {
      await prefs.remove(_key(session));
      return {};
    }
  }

  Future<void> save(Session? session, Iterable<StoryItem> stories) async {
    if (session == null) return;
    final active = stories.where((story) => !story.expired).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(session),
      jsonEncode(active.map((story) => story.toJson()).toList()),
    );
  }

  String _key(Session session) {
    return 'story_cache_${session.login}_${session.nodeId}';
  }
}
