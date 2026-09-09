import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
import 'package:meshchat_mobile/src/services/rich_draft_store.dart';
import 'package:meshchat_mobile/src/utils/media_request_encoder.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';

class AttachmentController extends AppController {
  int transfers = 0;
  String? forwardedRich;
  @override
  Future<String?> sendFile(
    Profile recipient,
    String filename,
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
    ChatThread? threadOverride,
    ChatMessageKind kind = ChatMessageKind.file,
    ChatMessage? retryingMessage,
  }) async {
    transfers++;
    final thread = threadOverride ?? ensureSavedMessagesThread();
    thread.messages.add(retryingMessage!.copyWith(delivered: true));
    return null;
  }

  @override
  Future<void> sendMessage(
    Profile recipient,
    String text, {
    ChatMessage? replyTo,
    ChatThread? threadOverride,
    ChatMessage? retryingMessage,
    String? messageId,
    bool businessAutoReply = false,
    String? richContent,
  }) async {
    forwardedRich = richContent;
  }
}

RichMessageDocument attachmentDocument(String id) =>
    RichMessageDocument.fromOps([
      {'insert': 'Before\n'},
      {
        'insert': {
          'mesh': jsonEncode({
            'type': 'attachment',
            'id': id,
            'name': 'photo.png',
          }),
        },
      },
      {'insert': '\nAfter\n'},
    ]);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('rich-attachments-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });

  test('draft media survives reopening and is isolated by account', () async {
    final store = RichDraftStore('alice/server/chat');
    final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 256));
    final embed = await store.stage('photo.png', bytes);
    final id = embed['id'] as String;
    await store.save(attachmentDocument(id));
    final reopened = RichDraftStore('alice/server/chat');
    expect((await reopened.load())!.attachments.single['id'], id);
    expect(await reopened.readAttachment(id), bytes);
    expect(await RichDraftStore('bob/server/chat').readAttachment(id), isNull);
    expect((await reopened.load())!.encode(), isNot(contains(directory.path)));
    await reopened.save(null);
    expect(await reopened.readAttachment(id), isNull);
    expect(await reopened.load(), isNull);
    expect(
      await directory.list(recursive: true).where((f) => f is File).length,
      0,
    );
  });

  test(
    'missing local bytes fail explicitly without discarding draft',
    () async {
      final store = RichDraftStore('missing');
      final item = await store.stage(
        'photo.png',
        Uint8List.fromList([1, 2, 3]),
      );
      final id = item['id'] as String;
      await store.save(attachmentDocument(id));
      for (final file
          in await directory
              .list(recursive: true)
              .where((f) => f is File)
              .toList()) {
        await file.delete();
      }
      await expectLater(store.readAttachment(id), throwsStateError);
      expect((await store.load())!.attachments.single['id'], id);
    },
  );

  test(
    'forwarding rewrites only file identities and keeps readable fallback',
    () {
      final doc = attachmentDocument('original-id');
      final forwarded = doc.replaceAttachmentIds({'original-id': 'new-id'});
      expect(forwarded.text, doc.text);
      expect(forwarded.attachments.single['id'], 'new-id');
      expect(doc.attachments.single['id'], 'original-id');
      expect(
        RichMessageDocument.decode(
          forwarded.encode(),
          expectedText: doc.text,
        )!.encode(),
        forwarded.encode(),
      );
      expect(() => attachmentDocument('../private'), throwsFormatException);
      expect(() => attachmentDocument(''), throwsFormatException);
    },
  );

  test(
    'media worker encodes all byte values without losing leading zeroes',
    () {
      final bytes = Uint8List.fromList(List.generate(256, (i) => i));
      expect(decodeMediaHex(encodeMediaHex(bytes)), bytes);
      expect(
        encodeMediaHex(Uint8List.fromList([0, 1, 15, 16, 255])),
        '00010f10ff',
      );
    },
  );

  test(
    'retry reuses durable attachment identity and forwarding copies media',
    () async {
      final controller = AttachmentController()
        ..session = const Session(
          serverUrl: 'wss://test',
          serverToken: '',
          login: 'alice',
          password: '',
          publicUsername: 'alice',
          nodeId: 'alice-node',
        );
      final thread = controller.ensureSavedMessagesThread();
      final doc = attachmentDocument('stable-id');
      await controller.prepareRichAttachments(
        thread,
        doc,
        (_) async => Uint8List.fromList([1, 2, 3]),
      );
      expect(controller.transfers, 1);
      await controller.prepareRichAttachments(
        thread,
        doc,
        (_) async => throw StateError('Should not read again'),
      );
      expect(controller.transfers, 1);
      final parent = ChatMessage(
        id: 'parent',
        senderNode: controller.myNodeId,
        receiverNode: thread.profile.nodeId,
        text: doc.text,
        richContent: doc.encode(),
        createdAt: DateTime(2026),
      );
      thread.messages.add(parent);
      expect(await controller.forwardMessage(parent, thread), isNull);
      expect(controller.transfers, 2);
      final forwarded = RichMessageDocument.decode(controller.forwardedRich!)!;
      expect(forwarded.attachments.single['id'], isNot('stable-id'));
      expect(forwarded.text, doc.text);
      expect(
        thread.messages
            .where((m) => m.kind == ChatMessageKind.file)
            .last
            .fileData,
        '010203',
      );
    },
  );

  test('missing attachment prevents all transfers in preflight', () async {
    final controller = AttachmentController()
      ..session = const Session(
        serverUrl: 'wss://test',
        serverToken: '',
        login: 'alice',
        password: '',
        publicUsername: 'alice',
        nodeId: 'alice-node',
      );
    await expectLater(
      controller.prepareRichAttachments(
        controller.ensureSavedMessagesThread(),
        attachmentDocument('missing'),
        (_) async => null,
      ),
      throwsStateError,
    );
    expect(controller.transfers, 0);
  });
}
