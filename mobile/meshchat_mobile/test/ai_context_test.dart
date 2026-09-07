import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/ai_context.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/pages/ai_context_page.dart';
import 'package:meshchat_mobile/src/services/ai_personal_store.dart';
import 'package:meshchat_mobile/src/services/session_secret_store.dart';

class MemorySecrets implements SessionSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class TestAiController implements AppController {
  @override
  Session? session = const Session(
    serverUrl: 'wss://test',
    serverToken: '',
    login: 'one',
    password: '',
    publicUsername: '',
    nodeId: 'a',
  );
  Map<String, dynamic>? sent;
  Completer<AiContextResult>? pending;
  @override
  ChatMessage? messageInThread(ChatThread thread, String id) =>
      thread.messages.where((m) => m.id == id).firstOrNull;
  @override
  Future<AiContextResult> runContextAiTool(
    Map<String, dynamic> payload, {
    String attachmentHex = '',
  }) async {
    sent = payload;
    return pending == null
        ? AiContextResult({
            'answer': 'Plan',
            'items': [
              {
                'text': 'Call tomorrow',
                'source_ids': ['1'],
              },
            ],
            'replies': ['Agreed'],
            'sources': payload['sources'],
          })
        : await pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'concurrent note updates preserve both edits and account clear removes them',
    () async {
      final storage = MemorySecrets();
      final store = AiPersonalStore('concurrent|alice', storage: storage);
      final first = store.update(
        'notes',
        (entries) => [
          ...entries,
          {'id': '1'},
        ],
      );
      final second = store.update(
        'notes',
        (entries) => [
          ...entries,
          {'id': '2'},
        ],
      );
      await first;
      await second;
      expect((await store.read('notes')).map((entry) => entry['id']), [
        '1',
        '2',
      ]);
      await store.clear();
      expect(await store.read('notes'), isEmpty);
    },
  );

  test(
    'notes and writing examples are persisted separately for each account',
    () async {
      final secretStore = MemorySecrets();
      final first = AiPersonalStore('server|alice', storage: secretStore);
      final other = AiPersonalStore('server|bob', storage: secretStore);
      await first.write('notes', [
        {'id': '1', 'title': 'Call', 'text': 'Decision'},
      ]);
      await first.write('presets', [
        {'id': '2', 'text': 'Friendly', 'examples': 'Hello'},
      ]);
      expect(await other.read('notes'), isEmpty);
      expect(
        (await AiPersonalStore(
          'server|alice',
          storage: secretStore,
        ).read('notes')).single['text'],
        'Decision',
      );
      expect((await first.read('presets')).single['examples'], 'Hello');
    },
  );

  testWidgets(
    'context is sent only after consent, drafts and reminders are explicit',
    (tester) async {
      final controller = TestAiController();
      final messages = [
        for (var i = 1; i <= 2; i++)
          ChatMessage(
            id: '$i',
            senderNode: 'a',
            receiverNode: 'b',
            text: 'Meeting $i',
            createdAt: DateTime(2026),
          ),
      ];
      final thread = ChatThread(
        profile: const Profile(nodeId: 'b', displayName: 'B'),
      )..messages.addAll(messages);
      var reminders = 0;
      var drafts = 0;
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AiContextPage(
            controller: controller,
            thread: thread,
            mode: 'plan',
            messages: messages,
            onSource: (_) {},
            onDraft: (_) => drafts++,
            onReminder: (_) async {
              reminders++;
            },
          ),
        ),
      );
      expect(controller.sent, isNull);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pump();
      await tester.ensureVisible(find.text('Send selected context'));
      await tester.tap(find.text('Send selected context'));
      await tester.pumpAndSettle();
      expect((controller.sent!['sources'] as List).length, 1);
      expect(reminders, 0);
      expect(drafts, 0);
      await tester.ensureVisible(find.byTooltip('Review reminder'));
      await tester.tap(find.byTooltip('Review reminder'));
      expect(reminders, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late results are hidden after an account switch', (
    tester,
  ) async {
    final controller = TestAiController()
      ..pending = Completer<AiContextResult>();
    final message = ChatMessage(
      id: '1',
      senderNode: 'a',
      receiverNode: 'b',
      text: 'Private',
      createdAt: DateTime(2026),
    );
    final thread = ChatThread(
      profile: const Profile(nodeId: 'b', displayName: 'B'),
    )..messages.add(message);
    await tester.pumpWidget(
      MaterialApp(
        home: AiContextPage(
          controller: controller,
          thread: thread,
          mode: 'plan',
          messages: [message],
          onSource: (_) {},
          onDraft: (_) {},
          onReminder: (_) async {},
        ),
      ),
    );
    await tester.ensureVisible(find.text('Send selected context'));
    await tester.tap(find.text('Send selected context'));
    await tester.pump();
    controller.session = null;
    controller.pending!.complete(AiContextResult({'answer': 'SECRET RESULT'}));
    await tester.pumpAndSettle();
    expect(find.text('SECRET RESULT'), findsNothing);
  });
}
