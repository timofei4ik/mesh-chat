import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
import 'package:meshchat_mobile/src/services/audio_progress_store.dart';
import 'package:meshchat_mobile/src/services/message_search.dart';
import 'package:meshchat_mobile/src/services/rich_draft_store.dart';
import 'package:meshchat_mobile/src/services/rich_draft_sync.dart';
import 'package:meshchat_mobile/src/services/mesh_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  ChatMessage message({String file = '', bool deleted = false}) => ChatMessage(
    id: 'm',
    senderNode: 'alice',
    receiverNode: 'bob',
    text: 'Hello world',
    createdAt: DateTime(2026, 9, 18, 12),
    fileName: file,
    deleted: deleted,
    kind: file.isEmpty ? ChatMessageKind.text : ChatMessageKind.file,
    transcription: 'spoken words',
    silent: true,
  );

  test(
    'search combines sender, local date, kind and transcript; excludes deleted',
    () {
      expect(
        MessageSearchFilter(
          query: 'WORLD',
          sender: 'alice',
          day: DateTime(2026, 9, 18),
          kind: MessageSearchKind.photo,
        ).matches(message(file: 'x.JPG')),
        isTrue,
      );
      expect(
        const MessageSearchFilter(query: 'spoken').matches(message()),
        isTrue,
      );
      expect(
        const MessageSearchFilter(sender: 'bob').matches(message()),
        isFalse,
      );
      expect(
        MessageSearchFilter(day: DateTime(2026, 9, 19)).matches(message()),
        isFalse,
      );
      expect(
        const MessageSearchFilter().matches(message(deleted: true)),
        isFalse,
      );
    },
  );
  test('silent flag survives persistence and retries', () {
    expect(
      ChatMessage.fromJson(message().toJson()).copyWith(pending: true).silent,
      isTrue,
    );
  });
  test(
    'private encrypted draft chunk fits server bound and another identity cannot read it',
    () async {
      final crypto = MeshCrypto();
      await crypto.initialize('draft-test', 'test-password');
      final text = base64Encode(Uint8List(64 * 1024));
      final encrypted = await crypto.encryptPrivateText(text);
      expect(encrypted.length, lessThanOrEqualTo(192 * 1024));
      expect(await crypto.decryptText(encrypted), text);
      final other = MeshCrypto();
      await other.initialize('other', 'other-password');
      expect(await other.decryptText(encrypted), isNot(text));
    },
  );
  test(
    'audio position is isolated by account, ordered, and cleared on completion',
    () async {
      final store = AudioProgressStore('a', 'm');
      await Future.wait([
        store.save(const Duration(seconds: 5)),
        store.save(const Duration(seconds: 30)),
      ]);
      expect(
        await AudioProgressStore('a', 'm').load(),
        const Duration(seconds: 30),
      );
      expect(await AudioProgressStore('b', 'm').load(), Duration.zero);
      await store.save(Duration.zero);
      expect(await store.load(), Duration.zero);
    },
  );
  test('pending plain and rich draft metadata survives cache roundtrip', () {
    final thread = ChatThread(
      profile: const Profile(nodeId: 'b', displayName: 'B'),
      draft: 'text',
      richDraft: 'encrypted',
      draftOperation: 'pending',
    );
    final restored = ChatThread.fromJson(thread.toJson());
    expect(restored.richDraft, 'encrypted');
    expect(restored.draftOperation, 'pending');
  });
  test(
    'offline rich draft retains formatting and retries cloud save',
    () async {
      var online = false;
      final store = RichDraftStore(
        'a:b',
        onSaved: (_, _) async => online,
        loadRemote: () async => RichMessageDocument.fromText('old remote'),
      );
      final doc = RichMessageDocument.fromOps([
        {
          'insert': 'bold',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]);
      await store.save(doc);
      expect(await store.hasPendingSync, isTrue);
      expect((await store.load())!.encode(), doc.encode());
      online = true;
      await store.save(await store.load());
      expect(await store.hasPendingSync, isFalse);
      expect(store.cloudSynced, isTrue);
      await store.save(null);
    },
  );
  test('legacy local rich draft is not erased by empty cloud state', () async {
    final local = RichDraftStore('legacy-account:thread');
    final document = RichMessageDocument.fromText('Existing draft');
    await local.save(document);
    final cloud = RichDraftStore(
      'legacy-account:thread',
      onSaved: (_, _) async => true,
      loadRemote: () async => null,
    );
    expect(await cloud.hasPendingSync, isTrue);
    expect((await cloud.load())!.encode(), document.encode());
    await cloud.save(await cloud.load());
    expect(await cloud.hasPendingSync, isFalse);
  });
  test(
    'rich attachments use bounded chunks, survive reload and reject corruption',
    () async {
      final chunks = <String, String>{};
      final sync = RichDraftSync(
        encrypt: (value) async => base64Encode(utf8.encode(value)),
        decrypt: (value) async => utf8.decode(base64Decode(value)),
        request: (packet) async {
          final key = '${packet['blob_id']}:${packet['index']}';
          if (packet['type'] == 'draft_blob_put') {
            chunks[key] = packet['data'] as String;
            return {'ok': true};
          }
          return {'ok': true, 'data': chunks[key]};
        },
      );
      const id = '12345678-1234-1234-1234-123456789abc';
      final bytes = Uint8List.fromList(List.generate(150000, (i) => i % 251));
      final doc = RichMessageDocument.fromOps([
        {
          'insert': {
            'mesh': jsonEncode({
              'type': 'attachment',
              'id': id,
              'name': 'test.bin',
            }),
          },
        },
        {'insert': '\n'},
      ]);
      final raw = await sync.upload(doc, (_) async => bytes, '');
      expect(chunks.length, 3);
      expect(chunks.values.every((chunk) => chunk.length < 192 * 1024), isTrue);
      expect(await sync.download(raw, id), bytes);
      final second = await sync.upload(
        doc,
        (_) async => throw StateError('should reuse uploaded data'),
        raw,
      );
      expect(await sync.download(second, id), bytes);
      chunks['$id:1'] = base64Encode(utf8.encode(base64Encode([1, 2, 3])));
      await expectLater(sync.download(raw, id), throwsFormatException);
    },
  );
}
