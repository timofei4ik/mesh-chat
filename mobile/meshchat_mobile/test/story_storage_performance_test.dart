import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/models/story_item.dart';
import 'package:meshchat_mobile/src/services/file_transfer_payload_store.dart';
import 'package:meshchat_mobile/src/services/large_preference_value.dart';
import 'package:meshchat_mobile/src/services/story_preferences_migration_io.dart';
import 'package:meshchat_mobile/src/services/story_store.dart';
import 'package:meshchat_mobile/src/utils/sync_delta_digest.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryPayloads extends FileTransferPayloadStore {
  final data = <String, Uint8List>{};
  bool failWrites = false;
  @override
  Future<String> write(
    String sessionKey,
    String transferId,
    Uint8List bytes,
  ) async {
    if (failWrites) throw StateError('disk full');
    final reference = '$sessionKey:$transferId';
    data[reference] = bytes;
    return reference;
  }

  @override
  Future<Uint8List> readChunk(String reference, int offset, int length) async =>
      data[reference]!;
}

const _session = Session(
  serverUrl: 'wss://example.invalid',
  serverToken: '',
  login: 'test',
  password: '',
  publicUsername: '',
  nodeId: 'node',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    '30 MiB story stays outside preferences and does not block the event loop',
    () async {
      final payloads = _MemoryPayloads();
      final store = StoryStore(
        values: LargePreferenceValue(payloads: payloads, usePayloads: true),
      );
      final video = 'AAAA' * (StoryItem.maxVideoBase64Length ~/ 4);
      final story = StoryItem(
        id: 'video',
        ownerNode: 'node',
        ownerName: 'Test',
        createdAt: DateTime.now(),
        mediaType: StoryMediaType.video,
        videoData: video,
      );
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        await store.save(_session, [story]);
        await store.saveArchive(_session, [story]);
        expect(ticks, greaterThan(0));
      } finally {
        timer.cancel();
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('story_cache_test_node'), isNull);
      expect(prefs.getString('story_archive_test_node'), isNull);
      expect(
        jsonEncode({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }).length,
        lessThan(1024),
      );
      expect((await store.load(_session))['video']!.videoData, video);
      expect((await store.loadArchive(_session)).single.videoData, video);
      // Both writes are queued in invocation order, including updates to one file.
      final first = store.save(_session, [story.copyWith(text: 'first')]);
      final second = store.save(_session, [story.copyWith(text: 'second')]);
      await Future.wait([first, second]);
      expect((await store.load(_session))['video']!.text, 'second');
    },
  );

  test('failed legacy migration preserves readable history', () async {
    final story = StoryItem(
      id: 'legacy',
      ownerNode: 'node',
      ownerName: 'Test',
      createdAt: DateTime.now(),
    );
    final raw = jsonEncode([story.toJson()]);
    SharedPreferences.setMockInitialValues({'story_cache_test_node': raw});
    final payloads = _MemoryPayloads()..failWrites = true;
    final store = StoryStore(
      values: LargePreferenceValue(payloads: payloads, usePayloads: true),
    );
    expect((await store.load(_session)).keys, ['legacy']);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'story_cache_test_node',
      ),
      raw,
    );
  });

  test(
    'Windows startup migration preserves accounts and exact media with backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'meshchat_story_migration_test_',
      );
      addTearDown(() => root.delete(recursive: true));
      final active = jsonEncode([
        {'video_data': 'AAAA' * (1024 * 1024)},
      ]);
      final original = jsonEncode({
        'flutter.story_cache_one_node': active,
        'flutter.story_archive_two_node': '[{"id":"archived"}]',
        'flutter.story_hidden_one_node': ['hidden'],
        'flutter.setting': 'unchanged',
      });
      final file = File('${root.path}/shared_preferences.json');
      await file.writeAsString(original);
      expect(await compute(migrateStoryPreferencesDirectory, root.path), 2);
      final migrated = jsonDecode(await file.readAsString()) as Map;
      expect(await file.length(), lessThan(2048));
      expect(migrated['flutter.setting'], 'unchanged');
      expect(migrated['flutter.story_hidden_one_node'], ['hidden']);
      expect(
        await File(
          migrated['flutter.story_cache_one_node:blob'] as String,
        ).readAsString(),
        active,
      );
      expect(
        await File(
          migrated['flutter.story_archive_two_node:blob'] as String,
        ).readAsString(),
        '[{"id":"archived"}]',
      );
      expect(
        await File('${file.path}.before-story-migration').readAsString(),
        original,
      );
      expect(await compute(migrateStoryPreferencesDirectory, root.path), 0);
      // A partially completed earlier migration's valid blob is authoritative.
      migrated['flutter.story_cache_one_node'] = 'obsolete';
      await file.writeAsString(jsonEncode(migrated));
      expect(await compute(migrateStoryPreferencesDirectory, root.path), 1);
      final retried = jsonDecode(await file.readAsString()) as Map;
      expect(
        await File(
          retried['flutter.story_cache_one_node:blob'] as String,
        ).readAsString(),
        active,
      );
    },
  );

  test('delta digest retains canonical ordering and UTF-8 semantics', () async {
    final envelopes = <Map<String, dynamic>>[
      {
        'z': {'b': 2, 'a': 1},
        'a': ['\u041f\u0440\u0438\u0432\u0435\u0442', true, null],
      },
    ];
    final canonical = jsonEncode([
      {
        'a': ['\u041f\u0440\u0438\u0432\u0435\u0442', true, null],
        'z': {'a': 1, 'b': 2},
      },
    ]);
    final expected = (await Sha256().hash(
      utf8.encode(canonical),
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    expect(await syncDeltaDigest(envelopes), expected);
  });
}
