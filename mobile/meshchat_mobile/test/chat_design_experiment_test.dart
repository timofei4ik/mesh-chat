import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/pages/chat_page.dart';
import 'package:meshchat_mobile/src/pages/chats_page.dart';
import 'package:meshchat_mobile/src/widgets/chat_timeline_date.dart';
import 'package:meshchat_mobile/src/widgets/mesh_performance_scope.dart';
import 'package:meshchat_mobile/src/widgets/mesh_workspace.dart';
import 'package:meshchat_mobile/src/widgets/mesh_home_background.dart';
import 'package:meshchat_mobile/src/widgets/profile_avatar.dart';

import 'package:meshchat_mobile/src/widgets/mesh_liquid_glass.dart';
import 'package:meshchat_mobile/src/services/platform_capabilities.dart';
import 'package:meshchat_mobile/src/utils/mesh_page_route.dart';

Future<void> waitForChatViewport(WidgetTester tester) async {
  final gate = find.byKey(const ValueKey('chat-initial-viewport'));
  for (var frame = 0; frame < 20; frame++) {
    if (gate.evaluate().isEmpty || tester.widget<Visibility>(gate).visible) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(tester.widget<Visibility>(gate).visible, isTrue);
}

Future<void> captureRevision(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  await waitForChatViewport(tester);
  if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] != '1') return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/design-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _PreviewController extends AppController {
  final sentGroupMessages = <String>[];
  List<CallCaptionLine> previewCaptions = [];
  @override
  List<CallCaptionLine> get callCaptionLines => previewCaptions;
  void refreshCaptions() => notifyListeners();

  @override
  void markRead(ChatThread thread) {}
  @override
  void setActiveThread(ChatThread? thread) {}

  @override
  Future<String?> sendGroupMessage(
    ChatThread group,
    String text, {
    ChatMessage? replyTo,
    ChatMessage? retryingMessage,
    String? richContent,
  }) async {
    sentGroupMessages.add(text);
    return 'preview-${sentGroupMessages.length}';
  }
}

class _RichPreviewController extends _PreviewController {
  @override
  Future<String?> sendGroupMessage(
    ChatThread group,
    String text, {
    ChatMessage? replyTo,
    ChatMessage? retryingMessage,
    String? richContent,
  }) async {
    sentGroupMessages.add(text);
    return null;
  }
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
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => switch (call.method) {
        'isLocationServiceEnabled' => true,
        'checkPermission' || 'requestPermission' => 2,
        'getCurrentPosition' => <String, Object>{
          'latitude': 60.03652,
          'longitude': 30.35266,
          'timestamp': DateTime(2026, 9, 10).millisecondsSinceEpoch,
          'accuracy': 4.0,
          'altitude': 0.0,
          'altitude_accuracy': 0.0,
          'heading': 0.0,
          'heading_accuracy': 0.0,
          'speed': 0.0,
          'speed_accuracy': 0.0,
        },
        _ => null,
      },
    );
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          null,
        );
  });

  testWidgets(
    'folder taps jump directly and rapid taps settle on the last folder',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MeshPerformanceScope(
            lowEndDeviceMode: true,
            child: ChatsPage(controller: controller),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final pages = tester.widget<PageView>(find.byType(PageView));
      await tester.tap(find.text('Channels'));
      await tester.pump();
      expect(pages.controller!.page, 3);
      await tester.tap(find.text('Personal'));
      await tester.pump();
      await tester.tap(find.text('Groups'));
      await tester.pump();
      expect(pages.controller!.page, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final count in [0, 3, 250]) {
    testWidgets('chat first visible frame starts at the bottom ($count)', (
      tester,
    ) async {
      final controller = _PreviewController();
      final thread = ChatThread(
        profile: const Profile(nodeId: 'friend', displayName: 'Alex'),
        messages: List.generate(
          count,
          (index) => ChatMessage(
            id: 'initial-$index',
            senderNode: 'friend',
            receiverNode: '',
            text:
                'Message $index ${List.filled(index % 7 + 1, "variable height text").join(" ")}',
            createdAt: DateTime(2026, 9, 16, 12, index),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MeshPerformanceScope(
            lowEndDeviceMode: true,
            child: ChatPage(controller: controller, thread: thread),
          ),
        ),
      );
      final gate = find.byKey(const ValueKey('chat-initial-viewport'));
      expect(tester.widget<Visibility>(gate).visible, isFalse);
      var revealed = false;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!tester.widget<Visibility>(gate).visible) continue;
        final list = tester.widget<ListView>(
          find.descendant(of: gate, matching: find.byType(ListView)),
        );
        expect(
          list.controller!.offset,
          closeTo(list.controller!.position.maxScrollExtent, 0.5),
        );
        revealed = true;
      }
      expect(revealed, isTrue);
      if (count == 250) {
        final listFinder = find.descendant(
          of: gate,
          matching: find.byType(ListView),
        );
        await tester.drag(listFinder, const Offset(0, 250));
        await tester.pump(const Duration(milliseconds: 300));
        final position = tester
            .widget<ListView>(listFinder)
            .controller!
            .position;
        expect(position.pixels, lessThan(position.maxScrollExtent - 100));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('long live captions wrap and keep the newest words visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController()
      ..activeCall = ActiveCall(
        callId: 'captions',
        peer: const Profile(nodeId: 'friend', displayName: 'Alex'),
        status: CallStatus.active,
        incoming: false,
        collapsed: false,
        startedAt: DateTime.now(),
      );
    void update(String ending) {
      controller.previewCaptions = [
        CallCaptionLine(
          id: 'continuous',
          sourceNode: 'friend',
          speaker: 'Alex',
          text: '${List.filled(60, "A long spoken phrase").join(" ")} $ending',
          isFinal: false,
          updatedAt: DateTime.now(),
        ),
      ];
    }

    update('LATEST');
    await tester.pumpWidget(
      MaterialApp(
        home: MeshPerformanceScope(
          lowEndDeviceMode: true,
          child: ChatPage(
            controller: controller,
            thread: ChatThread(
              profile: const Profile(nodeId: 'friend', displayName: 'Alex'),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final viewport = find.byKey(const ValueKey('call-caption-scroll'));
    expect(viewport, findsOneWidget);
    final text = find.descendant(
      of: viewport,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.textSpan?.toPlainText().contains('LATEST') ?? false),
      ),
    );
    expect(tester.widget<Text>(text).maxLines, isNull);
    expect(
      tester.getBottomLeft(text).dy,
      lessThanOrEqualTo(tester.getBottomLeft(viewport).dy + 1),
    );
    update('NEWEST WORDS');
    controller.refreshCaptions();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.descendant(
        of: viewport,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.textSpan?.toPlainText().endsWith('NEWEST WORDS') ?? false),
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('local deletion removes a message before persistence completes', (
    tester,
  ) async {
    final controller = _PreviewController();
    final message = ChatMessage(
      id: 'delete-now',
      senderNode: 'friend',
      receiverNode: '',
      text: 'Delete me',
      createdAt: DateTime(2026, 9, 10),
    );
    final thread = ChatThread(
      profile: const Profile(nodeId: 'friend', displayName: 'Friend'),
      messages: [message],
    );
    final deletion = controller.deleteMessageForMe(thread, message);
    expect(thread.messages, isEmpty);
    await deletion;
    await tester.pump(const Duration(milliseconds: 120));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('deleted_message_ids'), contains('delete-now'));
  });

  testWidgets('group location offers point and live-location paths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    final point =
        '::meshchat_meeting_v1::{"title":"Entrance","lat":60.03652,'
        '"lng":30.35266,"statuses":{"old":"✅"}}';
    final thread = ChatThread(
      profile: const Profile(nodeId: 'group', displayName: 'Friends'),
      isGroup: true,
      groupId: 'group',
      messages: [
        ChatMessage(
          id: 'point',
          senderNode: 'friend',
          receiverNode: '',
          text: point,
          createdAt: DateTime(2026, 9, 10),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MeshPerformanceScope(
          lowEndDeviceMode: true,
          child: ChatPage(controller: controller, thread: thread),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('I will come'), findsNothing);
    expect(find.text('Can not'), findsNothing);
    expect(find.text('Here'), findsNothing);

    Future<void> openLocation() async {
      await tester.tap(find.byIcon(Icons.attach_file_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Location'));
      await tester.pumpAndSettle();
      expect(find.text('Suggest meeting point'), findsOneWidget);
      expect(find.text('Share my location'), findsOneWidget);
    }

    await openLocation();
    await tester.tap(find.text('Suggest meeting point'));
    await tester.pumpAndSettle();
    final coordinateField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Coordinates or link',
    );
    await tester.enterText(coordinateField, '60.03652, 30.35266');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(
      controller.sentGroupMessages.single,
      startsWith('::meshchat_meeting_v1::'),
    );

    await openLocation();
    await tester.tap(find.text('Share my location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send once'));
    await tester.pumpAndSettle();
    expect(
      controller.sentGroupMessages.last,
      startsWith('::meshchat_location_v1::'),
    );
    expect(controller.sentGroupMessages.last, contains('60.03652'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('message editor survives same-account session refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _RichPreviewController()
      ..session = const Session(
        serverUrl: 'wss://meshchat.example/ws',
        serverToken: 'first-token',
        login: 'alice',
        password: 'secret',
        publicUsername: 'alice',
        nodeId: 'alice-phone',
      );
    final thread = ChatThread(
      profile: const Profile(nodeId: 'group', displayName: 'Friends'),
      isGroup: true,
      groupId: 'group',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MeshPerformanceScope(
          lowEndDeviceMode: true,
          child: ChatPage(controller: controller, thread: thread),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == 'Message',
      ),
      'Hello after refresh',
    );
    await tester.tap(find.byIcon(Icons.attach_file_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message editor'));
    await tester.pumpAndSettle();
    controller.session = controller.session!.copyWith(
      serverToken: 'refreshed-token',
      publicUsername: 'alice-new',
      email: 'alice@example.com',
    );
    controller.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(controller.sentGroupMessages, ['Hello after refresh']);
    expect(find.textContaining('Account changed'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets(
    'desktop workspace switches chats, keeps drafts and opens profile beside chat',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final alex = ChatThread(
        profile: const Profile(nodeId: 'alex', displayName: 'Alex'),
        messages: [
          ChatMessage(
            id: 'a',
            senderNode: 'alex',
            receiverNode: 'me',
            text: 'The updated layout is ready.',
            createdAt: DateTime(2026, 9, 16),
          ),
        ],
      );
      final jamie = ChatThread(
        profile: const Profile(nodeId: 'jamie', displayName: 'Jamie'),
      );
      controller.threads[alex.storageKey] = alex;
      controller.threads[jamie.storageKey] = jamie;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark().copyWith(
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
      expect(find.byType(MeshHomeBackground), findsNWidgets(2));
      await captureRevision(tester, boundary, 'desktop-empty-revision');
      await tester.tap(find.text('Alex').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MeshWorkspace), findsOneWidget);
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.text('Jamie'), findsOneWidget);
      final selection = tester.widget<Container>(
        find.byKey(ValueKey('chat-selection-${alex.storageKey}')),
      );
      final outline = selection.foregroundDecoration! as BoxDecoration;
      expect((outline.border! as Border).top.color, Colors.lightBlueAccent);
      expect((outline.border! as Border).top.width, 1.5);
      final unselected = tester.widget<Container>(
        find.byKey(ValueKey('chat-selection-${jamie.storageKey}')),
      );
      expect(
        ((unselected.foregroundDecoration! as BoxDecoration).border! as Border)
            .top
            .color,
        Colors.transparent,
      );
      final composer = find.descendant(
        of: find.byType(ChatPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(composer, 'A draft that stays here');
      await tester.tap(find.text('Jamie').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Alex').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('A draft that stays here'), findsOneWidget);
      await tester.tap(
        find
            .descendant(of: find.byType(ChatPage), matching: find.text('Alex'))
            .first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final transition = tester.widget<SizeTransition>(
        find
            .ancestor(
              of: find.byType(MeshDetailPane),
              matching: find.byType(SizeTransition),
            )
            .first,
      );
      expect(transition.sizeFactor.value, greaterThan(0));
      expect(transition.sizeFactor.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MeshDetailPane), findsOneWidget);
      final identity = find.byKey(const ValueKey('desktop-chat-identity'));
      expect(
        find.descendant(of: identity, matching: find.byType(ProfileAvatar)),
        findsOneWidget,
      );
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(identity));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await captureRevision(tester, boundary, 'desktop-hover-revision');
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/design-review/workspace-beta.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('Search messages'));
      await tester.pump(const Duration(milliseconds: 400));
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Search messages',
      );
      await tester.enterText(search, 'updated');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(MeshDetailPane), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(MeshDetailPane), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MeshDetailPane), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MeshDetailPane), findsNothing);
      expect(find.byType(ChatPage), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        2,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MeshWorkspace), findsNothing);
      expect(find.text('A draft that stays here'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ChatPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('wide $platform keeps the stable mobile layout', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final thread = ChatThread(
        profile: const Profile(nodeId: 'mobile', displayName: 'Mobile contact'),
      );
      controller.threads[thread.storageKey] = thread;
      await tester.pumpWidget(
        MaterialApp(
          home: MeshPerformanceScope(
            lowEndDeviceMode: true,
            child: ChatsPage(controller: controller),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MeshWorkspace), findsNothing);
      expect(find.byType(MeshHomeBackground), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.byTooltip('Personal'), findsNothing);
      await tester.tap(find.text('Mobile contact'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-identity')), findsNothing);
      expect(find.byType(MeshWorkspace), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      debugDefaultTargetPlatformOverride = null;
    });
  }

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

  testWidgets('iOS glass navigation keeps panels and selections on one canvas', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MeshPlatformScope(
          capabilities: const MeshPlatformCapabilities(iosMajorVersion: 26),
          // Inspect native configuration without creating UIKit views on Windows.
          child: MeshPerformanceScope(
            lowEndDeviceMode: true,
            child: ChatsPage(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final surfaces = tester.widgetList<MeshLiquidGlass>(
      find.byType(MeshLiquidGlass),
    );
    expect(
      surfaces.where((s) => s.forceFlutterSurface && !s.selected).length,
      2,
    );
    expect(
      surfaces.where((s) => s.selected && !s.forceFlutterSurface).length,
      2,
    );
    for (final label in ['Personal', 'Groups', 'Chats', 'Settings']) {
      final texts = tester.widgetList<Text>(find.text(label));
      expect(texts, isNotEmpty);
      for (final text in texts) {
        expect(text.style?.color?.computeLuminance(), greaterThan(0.5));
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'native selection stays mounted but offstage through return and cancel',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final owner = Object();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var creations = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') creations++;
        return null;
      });
      addTearDown(() {
        MeshRouteTransition.setActive(owner, false);
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      });
      Future<void> show(bool nativeAllowed) => tester.pumpWidget(
        MaterialApp(
          home: MeshPlatformScope(
            capabilities: const MeshPlatformCapabilities(iosMajorVersion: 26),
            child: MeshGlassCompositionScope(
              nativeAllowed: nativeAllowed,
              child: Column(
                children: [
                  for (final selected in [false, true])
                    MeshLiquidGlass.navigation(
                      selected: selected,
                      accent: Colors.lightBlueAccent,
                      child: const SizedBox(width: 200, height: 48),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await show(true);
      await tester.pump();
      final nativeState = tester.state(find.byType(UiKitView));
      expect(creations, 1);
      for (final transitioning in [true, false, true, false]) {
        MeshRouteTransition.setActive(owner, transitioning);
        await show(!transitioning);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byType(UiKitView),
          transitioning ? findsNothing : findsOneWidget,
        );
        expect(
          tester.state(find.byType(UiKitView, skipOffstage: false)),
          same(nativeState),
        );
        expect(creations, 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('covered iOS home renders all glass on Flutter canvas', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: MeshPlatformScope(
          capabilities: const MeshPlatformCapabilities(iosMajorVersion: 26),
          child: MeshGlassCompositionScope(
            nativeAllowed: false,
            child: Column(
              children: [
                for (final selected in [false, true])
                  MeshLiquidGlass(
                    selected: selected,
                    accent: Colors.cyan,
                    child: const SizedBox(
                      width: 200,
                      height: 48,
                      child: Text('Home label'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UiKitView), findsNothing);
    expect(find.text('Home label'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'swiping a chat row changes folders without pinning or archiving',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final personal = ChatThread(
        profile: const Profile(nodeId: 'peer', displayName: 'Personal friend'),
      );
      final group = ChatThread(
        profile: const Profile(nodeId: 'group', displayName: 'Study group'),
        isGroup: true,
        groupId: 'group',
      );
      controller.threads[personal.storageKey] = personal;
      controller.groups[group.groupId] = group;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MeshPerformanceScope(
            lowEndDeviceMode: true,
            child: ChatsPage(controller: controller),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.drag(
        find.text('Personal friend').first,
        const Offset(-310, 0),
      );
      await tester.pumpAndSettle();
      final pages = tester.widget<PageView>(find.byType(PageView));
      expect(pages.controller!.page, closeTo(1, 0.01));
      expect(personal.archived, isFalse);
      expect(personal.pinned, isFalse);
      await tester.drag(
        find.text('Personal friend').first,
        const Offset(310, 0),
      );
      await tester.pumpAndSettle();
      expect(pages.controller!.page, closeTo(0, 0.01));
      expect(personal.pinned, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  for (final size in [const Size(1100, 780), const Size(360, 800)]) {
    testWidgets('rich attachment stays inside its document at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final doc = RichMessageDocument.fromOps([
        {
          'insert': 'Weekend plans',
          'attributes': {'bold': true},
        },
        {'insert': '\nHere is the document for our trip.\n'},
        {
          'insert': {
            'mesh': jsonEncode({
              'type': 'attachment',
              'id': 'document-file',
              'name': 'agenda.pdf',
            }),
          },
        },
        {'insert': '\nLet me know what you think.\n'},
      ]);
      final thread = ChatThread(
        profile: const Profile(nodeId: 'friend', displayName: 'Alex'),
        messages: [
          ChatMessage(
            id: 'document-file',
            senderNode: 'friend',
            receiverNode: '',
            text: '',
            createdAt: DateTime(2026, 9, 9),
            kind: ChatMessageKind.file,
            fileName: 'agenda.pdf',
            fileData: '010203',
            fileSize: 3,
          ),
          ChatMessage(
            id: 'document-parent',
            senderNode: 'friend',
            receiverNode: '',
            text: doc.text,
            richContent: doc.encode(),
            createdAt: DateTime(2026, 9, 9),
          ),
        ],
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
              child: ChatPage(controller: controller, thread: thread),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('agenda.pdf'), findsOneWidget);
      await waitForChatViewport(tester);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/design-review').create(recursive: true);
          await File(
            'build/design-review/rich-${size.width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
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
      await waitForChatViewport(tester);
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
