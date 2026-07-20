import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/app_database_path.dart';
import 'package:meshchat_mobile/src/services/chat_cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const session = Session(
  serverUrl: 'wss://cache-integrity.test/ws',
  serverToken: 'token',
  login: 'cache-integrity-user',
  password: 'password',
  publicUsername: 'cache_integrity',
  nodeId: 'cache-integrity-node',
);

ChatThread thread(String nodeId) => ChatThread(
  profile: Profile(nodeId: nodeId, displayName: nodeId),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory supportDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    supportDirectory = await Directory.systemTemp.createTemp(
      'meshchat-cache-integrity-',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDirectory.path,
    );
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ChatCacheStore().clear(session);
  });

  test(
    'checkpoint detects a corrupted local cache without touching outboxes',
    () async {
      final store = ChatCacheStore();
      await store.save(session, [thread('peer-a')]);
      await store.saveSyncCursor(session, 7);

      expect((await store.inspectIntegrity(session)).verified, isTrue);
      expect(await store.loadSyncCursor(session), 7);

      final db = await openDatabase(await appDatabasePath('meshchat_cache.db'));
      await db.rawUpdate(
        "UPDATE chat_threads SET payload='corrupted' WHERE thread_key='direct:normal:peer-a'",
      );

      final report = await store.inspectIntegrity(session);
      expect(report.hasCheckpoint, isTrue);
      expect(report.verified, isFalse);
      expect(await store.loadSyncCursor(session), isNull);
    },
  );

  test(
    'atomic cache save removes rows absent from the current state',
    () async {
      final store = ChatCacheStore();
      await store.save(session, [thread('peer-a'), thread('peer-b')]);
      await store.saveSyncCursor(session, 9);
      await store.save(session, [thread('peer-b')]);

      final profiles = <String, Profile>{};
      final threads = <String, ChatThread>{};
      final groups = <String, ChatThread>{};
      await store.load(session, profiles, threads, groups);

      expect(threads.keys, ['peer-b']);
      expect((await store.inspectIntegrity(session)).verified, isTrue);
      expect(await store.loadSyncCursor(session), 9);
    },
  );
}
