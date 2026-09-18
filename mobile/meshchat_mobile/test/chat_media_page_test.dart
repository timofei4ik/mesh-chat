import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/pages/chat_media_page.dart';

void main() {
  ChatMessage file(String id, String name) => ChatMessage(
    id: id,
    senderNode: 'a',
    receiverNode: 'b',
    text: '',
    createdAt: DateTime.utc(2026, 9, 16, 12),
    kind: ChatMessageKind.file,
    fileName: name,
    fileSize: 1024,
  );

  testWidgets(
    'shared media search and source callback keep the desktop panel route',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      final thread = ChatThread(
        profile: const Profile(nodeId: 'a', displayName: 'Alice'),
        messages: [file('one', 'notes.pdf'), file('two', 'other.pdf')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatMediaPage(
            thread: thread,
            onOpenMessage: (id) => selected = id,
          ),
        ),
      );
      await tester.tap(find.text('Files 2'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'notes');
      await tester.pumpAndSettle();
      expect(find.text('notes.pdf'), findsOneWidget);
      expect(find.text('other.pdf'), findsNothing);
      await tester.tap(find.byTooltip('Go to message'));
      await tester.pumpAndSettle();
      expect(selected, 'one');
      expect(find.byType(ChatMediaPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shared content separates photos videos voice and music', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final thread = ChatThread(
      profile: const Profile(nodeId: 'a', displayName: 'Alice'),
      messages: [
        file('photo', 'photo.jpg'),
        file('video', 'clip.mp4'),
        file('voice', 'voice_123.m4a'),
        file('music', 'song.m4a'),
        file('document', 'notes.pdf'),
        ChatMessage(
          id: 'link',
          senderNode: 'a',
          receiverNode: 'b',
          text: 'https://meshchat-losa.ru/help',
          createdAt: DateTime.utc(2026, 9, 16, 12),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ChatMediaPage(thread: thread),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Photos 1'), findsOneWidget);
    expect(find.text('Videos 1'), findsOneWidget);
    expect(find.text('Voice 1'), findsOneWidget);
    expect(find.text('Music 1'), findsOneWidget);
    expect(find.text('Files 1'), findsOneWidget);
    expect(find.text('Links 1'), findsOneWidget);
  });
}
