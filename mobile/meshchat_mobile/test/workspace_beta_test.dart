import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
import 'package:meshchat_mobile/src/pages/rich_message_editor_page.dart';
import 'package:meshchat_mobile/src/services/rich_draft_store.dart';
import 'package:meshchat_mobile/src/widgets/mesh_workspace.dart';
import 'package:meshchat_mobile/src/widgets/mesh_attachment_tile.dart';
import 'package:meshchat_mobile/src/widgets/mesh_call_dock.dart';
import 'package:meshchat_mobile/src/widgets/message_bubble_picker.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  testWidgets('Escape closes modal first, then page, without leaving home', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) =>
            MeshDesktopNavigation(navigatorKey: navigator, child: child!),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    final pageContext = tester.element(find.byType(TextField));
    showDialog<void>(
      context: pageContext,
      builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('detail navigation closes only its own pane and returns result', (
    tester,
  ) async {
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: Text('Conversation')),
              MeshDetailPane(
                onClose: (value) => result = value,
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.pop(context, 'message-id'),
                    child: const Text('Return to message'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Return to message'));
    await tester.pump();
    expect(result, 'message-id');
    expect(find.text('Conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('call dock and attachment fit width $width with large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var muted = false;
      var captionsOpened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 700),
              textScaler: const TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: Column(
                children: [
                  MeshCallDock(
                    profile: const Profile(
                      nodeId: 'a',
                      displayName: 'A very long participant name',
                    ),
                    status: '12:30',
                    muted: false,
                    onExpand: () {},
                    onMute: () => muted = true,
                    onEnd: () {},
                    onCaptions: () => captionsOpened = true,
                    onParticipants: () {},
                  ),
                  const MeshAttachmentTile(
                    title: 'An unusually long attachment filename.pdf',
                    subtitle: '2.4 MB',
                    icon: Icons.description_outlined,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Mute'));
      expect(muted, isTrue);
      await tester.tap(find.byTooltip('Call details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Captions'));
      await tester.pumpAndSettle();
      expect(captionsOpened, isTrue);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('appearance saves previewed palette and collection together', (
    tester,
  ) async {
    String? savedTheme;
    String? savedStyle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubblePicker(
            profile: const Profile(nodeId: 'a', displayName: 'Alex'),
            onSave: (_, _) async => null,
            onSaveAppearance: (style, animated, theme) async {
              savedStyle = style;
              savedTheme = theme;
              return 'Offline';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Match profile collection'));
    await tester.pump();
    await tester.tap(find.byTooltip('emerald'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(savedStyle, 'auto');
    expect(savedTheme, 'emerald');
    expect(find.text('Offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('editor preview preserves document and restores editing', (
    tester,
  ) async {
    final draft = RichDraftStore('beta-preview');
    final initial = RichMessageDocument.fromText('Keep my draft');
    await tester.pumpWidget(
      MaterialApp(
        home: RichMessageEditorPage(
          initial: initial,
          drafts: draft,
          onSend: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Preview message'));
    await tester.pump();
    expect(find.byTooltip('Continue editing'), findsOneWidget);
    await tester.tap(find.byTooltip('Continue editing'));
    await tester.pump();
    expect(find.byTooltip('Preview message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
