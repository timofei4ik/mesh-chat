import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
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

  test('checkpoint commits threads, digest, and cursor together', () async {
    final store = ChatCacheStore();
    await store.saveCheckpoint(session, [thread('peer-a')], 11);

    final profiles = <String, Profile>{};
    final threads = <String, ChatThread>{};
    final groups = <String, ChatThread>{};
    await store.load(session, profiles, threads, groups);

    expect(threads.keys, ['peer-a']);
    expect(await store.loadSyncCursor(session), 11);
    expect((await store.inspectIntegrity(session)).verified, isTrue);
  });

  test(
    'large rich history is chunked without losing formatting or queued messages',
    () async {
      final store = ChatCacheStore();
      final chat = thread('rich-peer');
      final rich = RichMessageDocument.fromText('message ' * 6500);
      chat.messages.addAll(
        List.generate(
          35,
          (index) => ChatMessage(
            id: 'rich-$index',
            senderNode: session.nodeId,
            receiverNode: 'rich-peer',
            text: rich.text,
            richContent: rich.encode(),
            pending: index == 0,
            createdAt: DateTime(2026).add(Duration(seconds: index)),
          ),
        ),
      );
      await store.saveCheckpoint(session, [chat], 21);
      final profiles = <String, Profile>{};
      final threads = <String, ChatThread>{};
      await store.load(session, profiles, threads, {});
      expect(threads['rich-peer']!.messages.length, 35);
      expect(threads['rich-peer']!.messages.first.pending, isTrue);
      expect(
        threads['rich-peer']!.messages.every(
          (message) => message.richContent == rich.encode(),
        ),
        isTrue,
      );
      expect(await store.loadSyncCursor(session), 21);
      expect((await store.inspectIntegrity(session)).verified, isTrue);
      expect((await store.stats(session)).threads, 1);
      await store.deleteThread(session, chat);
      threads.clear();
      await store.load(session, profiles, threads, {});
      expect(threads, isEmpty);
      await store.saveCheckpoint(session, [chat], 21);
      chat.messages.removeRange(1, chat.messages.length);
      await store.saveCheckpoint(session, [chat], 22);
      threads.clear();
      await store.load(session, profiles, threads, {});
      expect(threads['rich-peer']!.messages.length, 1);
    },
  );

  test(
    'rich file metadata is retained beyond the normal history trim boundary',
    () async {
      final store = ChatCacheStore();
      final chat = thread('rich-boundary');
      chat.messages.add(
        ChatMessage(
          id: 'old-file',
          senderNode: 'owner',
          receiverNode: 'rich-boundary',
          text: '',
          kind: ChatMessageKind.file,
          fileName: 'plan.pdf',
          mediaId: 'media-id',
          fileSize: 1024,
          createdAt: DateTime(2026),
        ),
      );
      for (var i = 0; i < 505; i++) {
        chat.messages.add(
          ChatMessage(
            id: 'text-$i',
            senderNode: 'owner',
            receiverNode: 'rich-boundary',
            text: 'Text $i',
            createdAt: DateTime(2026).add(Duration(seconds: i + 1)),
          ),
        );
      }
      final doc = RichMessageDocument.fromOps([
        {
          'insert': {
            'mesh': jsonEncode({
              'type': 'attachment',
              'id': 'old-file',
              'name': 'plan.pdf',
            }),
          },
        },
        {'insert': '\n'},
      ]);
      chat.messages.add(
        ChatMessage(
          id: 'rich-parent',
          senderNode: 'owner',
          receiverNode: 'rich-boundary',
          text: doc.text,
          richContent: doc.encode(),
          createdAt: DateTime(2026).add(const Duration(minutes: 10)),
        ),
      );
      await store.saveCheckpoint(session, [chat], 30);
      final restored = <String, ChatThread>{};
      await store.load(session, {}, restored, {});
      expect(restored['rich-boundary']!.messages.first.id, 'old-file');
      expect(restored['rich-boundary']!.messages.first.mediaId, 'media-id');
      expect(
        restored['rich-boundary']!.messages.last.richContent,
        doc.encode(),
      );
      expect((await store.inspectIntegrity(session)).verified, isTrue);
    },
  );

  test('failed checkpoint rolls back both cache and cursor', () async {
    final store = ChatCacheStore();
    await store.saveCheckpoint(session, [thread('peer-a')], 7);
    final db = await openDatabase(await appDatabasePath('meshchat_cache.db'));
    await db.execute('''
      CREATE TRIGGER fail_test_checkpoint
      BEFORE INSERT ON chat_threads
      WHEN NEW.thread_key='direct:normal:peer-fail'
      BEGIN
        SELECT RAISE(ABORT, 'checkpoint test failure');
      END
      ''');

    try {
      await expectLater(
        store.saveCheckpoint(session, [thread('peer-fail')], 12),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      await db.execute('DROP TRIGGER IF EXISTS fail_test_checkpoint');
    }

    final profiles = <String, Profile>{};
    final threads = <String, ChatThread>{};
    final groups = <String, ChatThread>{};
    await store.load(session, profiles, threads, groups);

    expect(threads.keys, ['peer-a']);
    expect(await store.loadSyncCursor(session), 7);
    expect((await store.inspectIntegrity(session)).verified, isTrue);
  });
}
