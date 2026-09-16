import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> migrateStoryPreferences() async {
  if (!Platform.isWindows) return;
  try {
    final directory = await getApplicationSupportDirectory();
    await compute(migrateStoryPreferencesDirectory, directory.path);
  } catch (error) {
    // A failed migration must never prevent opening an existing account.
    debugPrint('Story preferences migration failed: ${error.runtimeType}');
  }
}

/// Runs before the preferences plugin caches its synchronous Windows JSON file.
Future<int> migrateStoryPreferencesDirectory(String directory) async {
  final file = File('$directory/shared_preferences.json');
  if (!await file.exists()) return 0;
  final values = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final keys = values.keys
      .where(
        (key) =>
            (key.startsWith('flutter.story_cache_') ||
                key.startsWith('flutter.story_archive_')) &&
            !key.endsWith(':blob') &&
            values[key] is String,
      )
      .toList();
  if (keys.isEmpty) return 0;
  final blobs = Directory('$directory/meshchat_story_migration');
  await blobs.create(recursive: true);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  for (final key in keys) {
    final existing = values['$key:blob'];
    if (existing is String && await File(existing).exists()) {
      values.remove(key);
      continue;
    }
    // Preserve all accounts and the exact legacy JSON, including expired stories.
    final digest = await Sha256().hash(utf8.encode(key));
    final name = base64Url.encode(digest.bytes).replaceAll('=', '');
    final target = File('${blobs.path}/$name-$stamp.bin');
    await target.writeAsString(values[key] as String, flush: true);
    values['$key:blob'] = target.path;
    values.remove(key);
  }
  final backup = File('${file.path}.before-story-migration');
  if (!await backup.exists()) await file.copy(backup.path);
  final temporary = File('${file.path}.story-migration.tmp');
  await temporary.writeAsString(jsonEncode(values), flush: true);
  await temporary.rename(file.path);
  return keys.length;
}
