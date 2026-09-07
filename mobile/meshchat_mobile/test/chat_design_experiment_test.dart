import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/pages/chat_page.dart';
import 'package:meshchat_mobile/src/pages/chats_page.dart';
import 'package:meshchat_mobile/src/widgets/chat_timeline_date.dart';
import 'package:meshchat_mobile/src/widgets/mesh_performance_scope.dart';

class _PreviewController extends AppController {
  @override
  void markRead(ChatThread thread) {}
  @override
  void setActiveThread(ChatThread? thread) {}
}

void main() {
  final audioChannels = <String>{};
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
      final font = FontLoader('PreviewSans')
        ..addFont(
          File(
            'C:/Windows/Fonts/segoeui.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await icons.load();
    }
  });
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      audioChannels.add(name);
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    audioChannels.add('xyz.luan/audioplayers');
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final name =
              'xyz.luan/audioplayers/events/${call.arguments['playerId']}';
          audioChannels.add(name);
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => null,
          );
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => null,
        );
  });
  tearDown(() {
    for (final name in audioChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    audioChannels.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          null,
        );
  });
  testWidgets('timeline date follows visible variable-height rows and fades', (
    tester,
  ) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTimelineDate(
            label: (date) => 'Day ${date.day}',
            child: ListView.builder(
              controller: scroll,
              itemCount: 30,
              itemBuilder: (_, index) => ChatDateAnchor(
                date: DateTime(2026, 9, index + 1),
                child: SizedBox(
                  height: index.isEven ? 120 : 180,
                  child: Text('Row $index'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    scroll.jumpTo(310);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Day 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Day 3'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  for (final size in [const Size(1100, 780), const Size(360, 800)]) {
    testWidgets('chat list shows drafts and typing at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final draft = ChatThread(
        profile: const Profile(nodeId: 'alex', displayName: 'Alex'),
        draft: 'See you tomorrow',
      );
      final typing = ChatThread(
        profile: const Profile(nodeId: 'jamie', displayName: 'Jamie'),
      );
      controller.threads[draft.storageKey] = draft;
      controller.threads[typing.storageKey] = typing;
      controller.typingUntil[typing.storageKey] = DateTime.now().add(
        const Duration(minutes: 1),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'PreviewSans',
              ),
            ),
            home: MeshPerformanceScope(
              lowEndDeviceMode: true,
              child: ChatsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Draft: See you tomorrow'), findsOneWidget);
      expect(find.text('typing...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory('build/design-review').createSync(recursive: true);
          File(
            'build/design-review/list-${size.width.toInt()}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
    testWidgets('chat experiment fits ${size.width} and opens attachments', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController()
        ..activeCall = ActiveCall(
          callId: 'preview-call',
          peer: const Profile(nodeId: 'friend', displayName: 'Alex'),
          status: CallStatus.active,
          incoming: false,
          collapsed: true,
          startedAt: DateTime.now().subtract(const Duration(seconds: 74)),
        );
      final thread = ChatThread(
        profile: const Profile(nodeId: 'friend', displayName: 'Weekend plans'),
        isGroup: true,
        groupId: 'preview',
        messages: [
          ChatMessage(
            id: 'original',
            senderNode: 'friend',
            receiverNode: '',
            senderName: 'Alex',
            text: 'Let us meet by the lake tomorrow.',
            createdAt: DateTime.now(),
          ),
          ChatMessage(
            id: 'reply',
            senderNode: 'friend',
            receiverNode: '',
            senderName: 'Jamie',
            text: 'Sounds good. I will bring coffee.',
            createdAt: DateTime.now(),
            replyToMessageId: 'original',
            replyToText: 'Let us meet by the lake tomorrow.',
          ),
          ChatMessage(
            id: 'voice',
            senderNode: 'friend',
            receiverNode: '',
            senderName: 'Alex',
            text: '',
            createdAt: DateTime.now(),
            kind: ChatMessageKind.file,
            fileName: 'Voice message.m4a',
            fileData: '0000',
            fileSize: 2,
            transcription: 'I will be there at ten. See you tomorrow!',
          ),
        ],
      );
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'PreviewSans',
              ),
            ),
            home: MeshPerformanceScope(
              lowEndDeviceMode: true,
              child: ChatPage(controller: controller, thread: thread),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('Alex'), findsWidgets);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(
        find.text('I will be there at ten. See you tomorrow!'),
        findsNothing,
      );
      await tester.tap(find.text('Transcript'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text('I will be there at ten. See you tomorrow!'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('build/design-review')
            ..createSync(recursive: true);
          File(
            '${directory.path}/chat-${size.width.toInt()}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byIcon(Icons.attach_file_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Poll or quiz'), findsOneWidget);
      expect(find.text('Location'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            'build/design-review/attachments-${size.width.toInt()}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
