import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import '../models/session.dart';
import '../models/story_item.dart';
import 'large_preference_value.dart';
import '../utils/background_json.dart';

class StoryStore {
  StoryStore({LargePreferenceValue? values})
    : _values = values ?? LargePreferenceValue(usePayloads: true);

  final LargePreferenceValue _values;
  Future<void> _pendingWrite = Future.value();

  Future<void> _write(String key, List<Map<String, dynamic>> stories) {
    final result = _pendingWrite.then((_) async {
      final encoded = await encodeBackgroundJson(stories);
      final prefs = await SharedPreferences.getInstance();
      await _values.write(prefs, key, encoded);
    });
    _pendingWrite = result.catchError((Object _) {});
    return result;
  }

  Future<Map<String, StoryItem>> load(Session session) async {
    await _pendingWrite;
    final prefs = await SharedPreferences.getInstance();
    final raw = await _values.read(prefs, _key(session));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = await decodeBackgroundJson(raw);
      if (decoded is! List) return {};
      final stories = <String, StoryItem>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final story = StoryItem.fromJson(Map<String, dynamic>.from(item));
        if (story.id.isEmpty || story.expired) continue;
        stories[story.id] = story;
      }
      await _migrateLegacy(prefs, _key(session), stories.values);
      return stories;
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Session? session, Iterable<StoryItem> stories) async {
    if (session == null) return;
    final active = stories.where((story) => !story.expired).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _write(_key(session), active.map((story) => story.toJson()).toList());
  }

  Future<List<StoryItem>> loadArchive(Session session) async {
    await _pendingWrite;
    final prefs = await SharedPreferences.getInstance();
    final raw = await _values.read(prefs, _archiveKey(session));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = await decodeBackgroundJson(raw);
      if (decoded is! List) return const [];
      final stories = <StoryItem>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final story = StoryItem.fromJson(Map<String, dynamic>.from(item));
        if (story.id.isEmpty) continue;
        stories.add(story);
      }
      stories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _migrateLegacy(prefs, _archiveKey(session), stories);
      return stories;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _migrateLegacy(
    SharedPreferences prefs,
    String key,
    Iterable<StoryItem> stories,
  ) async {
    if (!prefs.containsKey(key)) return;
    try {
      await _write(key, stories.map((story) => story.toJson()).toList());
    } catch (error) {
      debugPrint('Story cache migration deferred: ${error.runtimeType}');
    }
  }

  Future<void> saveArchive(
    Session? session,
    Iterable<StoryItem> stories,
  ) async {
    if (session == null) return;
    final archived = stories.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _write(
      _archiveKey(session),
      archived.map((story) => story.toJson()).toList(),
    );
  }

  Future<Set<String>> loadHiddenOwners(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_hiddenKey(session))?.toSet() ?? {};
  }

  Future<void> saveHiddenOwners(Session? session, Set<String> nodeIds) async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey(session), nodeIds.toList()..sort());
  }

  String _key(Session session) {
    return 'story_cache_${session.login}_${session.nodeId}';
  }

  String _archiveKey(Session session) {
    return 'story_archive_${session.login}_${session.nodeId}';
  }

  String _hiddenKey(Session session) {
    return 'story_hidden_${session.login}_${session.nodeId}';
  }
}
