import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/models/rich_message_document.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/services/direct_thread_identity.dart';
import 'package:meshchat_mobile/src/services/rich_draft_store.dart';
import 'package:meshchat_mobile/src/services/mesh_crypto.dart';
import 'package:meshchat_mobile/src/widgets/rich_message_view.dart';
import 'package:meshchat_mobile/src/pages/rich_message_editor_page.dart';

RichMessageDocument sample() => RichMessageDocument.fromOps([
  {
    'insert': 'Hello ',
    'attributes': {'bold': true},
  },
  {
    'insert': 'world',
    'attributes': {'italic': true, 'link': 'https://example.com'},
  },
  {'insert': '\nOne'},
  {
    'insert': '\n',
    'attributes': {'list': 'ordered'},
  },
  {
    'insert': {
      'mesh': jsonEncode({
        'type': 'table',
        'rows': [
          ['Name', 'Value'],
          ['A', '1'],
        ],
      }),
    },
  },
  {'insert': '\n'},
  {
    'insert': {
      'mesh': jsonEncode({'type': 'spoiler', 'text': 'hidden'}),
    },
  },
  {'insert': '\n'},
  {
    'insert': {'formula': r'x^2 + y^2'},
  },
  {'insert': '\n'},
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'sent tables fit short columns and scroll wide tables without changing stored content',
    (tester) async {
      for (final count in [3, 8]) {
        final doc = RichMessageDocument.fromOps([
          {
            'insert': {
              'mesh': jsonEncode({
                'type': 'table',
                'rows': [
                  List.generate(count, (i) => 'Col $i'),
                  List.generate(count, (i) => 'Value $i'),
                ],
              }),
            },
          },
          {'insert': '\n\n\n'},
        ]);
        final original = doc.encode();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  child: RichMessageView(key: ValueKey(count), document: doc),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tableWidth = tester.getSize(find.byType(Table)).width;
        expect(
          tableWidth,
          count == 3 ? lessThanOrEqualTo(280) : greaterThan(280),
        );
        final scrollbar = tester.widget<Scrollbar>(
          find.byType(Scrollbar).first,
        );
        expect(scrollbar.thumbVisibility, count == 8);
        if (count == 8) {
          await tester.drag(find.byType(Scrollbar).first, const Offset(-400, 0));
          await tester.pumpAndSettle();
          expect(scrollbar.controller!.offset, greaterThan(0));
        }
        final c = tester
            .widget<q.QuillEditor>(find.byType(q.QuillEditor))
            .controller;
        expect(c.document.toPlainText(), '\uFFFC\n');
        expect(doc.encode(), original);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'table at document start has a text caret and can move around paragraphs',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RichMessageEditorPage(
            initial: RichMessageDocument.fromOps([
              {
                'insert': {
                  'mesh': jsonEncode({
                    'type': 'table',
                    'rows': [
                      ['A', 'B'],
                    ],
                  }),
                },
              },
              {'insert': '\nAfter\n'},
            ]),
            drafts: RichDraftStore('table-caret'),
            onSend: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
      final c = surface.controller;
      c.updateSelection(
        const TextSelection.collapsed(offset: 0),
        q.ChangeSource.local,
      );
      await tester.pump();
      expect(c.selection.start, 2);
      expect(surface.focusNode.hasFocus, isTrue);
      await tester.tap(find.byTooltip('Write before block'));
      await tester.pumpAndSettle();
      expect(c.selection.start, 0);
      c.replaceText(0, 0, 'Before', const TextSelection.collapsed(offset: 6));
      await tester.pumpAndSettle();
      expect(c.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
      await tester.tap(find.byTooltip('Move block down'));
      await tester.pumpAndSettle();
      expect(c.document.toPlainText(), startsWith('Before\nAfter\n\uFFFC\n'));
      await tester.tap(find.byTooltip('Move block up'));
      await tester.pumpAndSettle();
      expect(c.document.toPlainText(), startsWith('Before\n\uFFFC\nAfter\n'));
      expect(
        RichMessageDocument.fromOps(c.document.toDelta().toJson()).encode(),
        contains('table'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'table removes chosen rows and columns and preserves remaining cells',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RichMessageEditorPage(
            initial: RichMessageDocument.fromText('Plan'),
            drafts: RichDraftStore('table-delete'),
            onSend: (_) async {},
            background: const ColoredBox(
              key: ValueKey('chat-wallpaper'),
              color: Colors.teal,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-wallpaper')), findsOneWidget);
      expect(find.text('Message editor'), findsOneWidget);
      await tester.tap(find.byTooltip('Table'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'A');
      await tester.enterText(find.byType(TextField).at(2), 'C');
      await tester.enterText(find.byType(TextField).at(6), 'G');
      await tester.enterText(find.byType(TextField).at(8), 'I');
      await tester.ensureVisible(find.byTooltip('Delete column 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete column 2'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Delete row 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete row 2'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((field) => field.controller!.text),
        ['A', 'C', 'G', 'I'],
      );
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller;
      final doc = RichMessageDocument.fromOps(
        controller.document.toDelta().toJson(),
      );
      final restored = RichMessageDocument.decode(doc.encode())!;
      final embed = restored.ops
          .map((op) => op['insert'])
          .whereType<Map>()
          .first;
      expect(jsonDecode(embed['mesh'] as String)['rows'], [
        ['A', 'C'],
        ['G', 'I'],
      ]);
      await tester.tap(find.byTooltip('Edit block'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete row 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete column 2'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Delete row 1',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Delete column 1',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        RichMessageDocument.fromOps(
          controller.document.toDelta().toJson(),
        ).encode(),
        doc.encode(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
    for (final width in [360.0, 1100.0]) {
      testWidgets('editor visual review $width', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          for (final entry in {
            'PreviewSans': 'C:/Windows/Fonts/segoeui.ttf',
            'Roboto': 'C:/Windows/Fonts/segoeui.ttf',
            'Ahem': 'C:/Windows/Fonts/segoeui.ttf',
            'MaterialIcons':
                'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(entry.value).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'PreviewSans',
                ),
              ),
              home: RichMessageEditorPage(
                initial: sample(),
                drafts: RichDraftStore('visual'),
                onSend: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final menu in [false, true]) {
          if (menu) {
            await tester.tap(find.byTooltip('Formatting'));
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/design-review/editor-${width.toInt()}-${menu ? 'menu' : 'main'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('caret survives typing, formatting menus and panel rebuilds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: RichMessageEditorPage(
          initial: RichMessageDocument.fromText('Hello world'),
          drafts: RichDraftStore('focus-regression'),
          onSend: (_) async => throw StateError('Offline'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    q.QuillEditor surface() =>
        tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final focus = surface().focusNode;
    final scroll = surface().scrollController;
    final controller = surface().controller;
    expect(focus.hasFocus, isTrue);
    controller.replaceText(5, 0, '!', const TextSelection.collapsed(offset: 6));
    await tester.pump();
    expect(identical(surface().focusNode, focus), isTrue);
    expect(identical(surface().scrollController, scroll), isTrue);
    expect(focus.hasFocus, isTrue);
    const selection = TextSelection(baseOffset: 0, extentOffset: 5);
    controller.updateSelection(selection, q.ChangeSource.local);
    await tester.pump();
    await tester.tap(find.byTooltip('Formatting'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bold'));
    await tester.pumpAndSettle();
    expect(controller.selection, selection);
    expect(focus.hasFocus, isTrue);
    await tester.tap(find.byTooltip('Formatting'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rich-menu-Bold')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 500));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(identical(surface().focusNode, focus), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  test(
    'account alias merge retains formatting but respects a plain-text edit',
    () {
      final rich = sample();
      final plain = ChatMessage(
        id: 'same',
        senderNode: 'a',
        receiverNode: 'b',
        text: rich.text,
        createdAt: DateTime(2026),
      );
      final formatted = plain.copyWith(richContent: rich.encode());
      final target = ChatThread(
        profile: const Profile(nodeId: 'a', displayName: 'A'),
        messages: [plain],
      );
      final alias = ChatThread(
        profile: const Profile(nodeId: 'a2', displayName: 'A'),
        messages: [formatted],
      );
      mergeDirectHistory(target, alias);
      expect(target.messages.single.richContent, rich.encode());
      final edited = ChatThread(
        profile: const Profile(nodeId: 'a3', displayName: 'A'),
        messages: [plain.copyWith(edited: true)],
      );
      mergeDirectHistory(target, edited);
      expect(target.messages.single.richContent, '');
    },
  );

  test(
    'versioned delta survives Quill, JSON cache and delivery flag changes',
    () {
      final doc = sample();
      final quill = q.Document.fromJson(doc.ops);
      expect(
        RichMessageDocument.fromOps(quill.toDelta().toJson()).encode(),
        doc.encode(),
      );
      final message = ChatMessage(
        id: 'one',
        senderNode: 'a',
        receiverNode: 'b',
        text: doc.text,
        richContent: doc.encode(),
        createdAt: DateTime(2026),
      );
      final restored = ChatMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())),
      );
      expect(restored.copyWith(delivered: true).richContent, doc.encode());
      expect(restored.copyWith(text: 'plain edit').richContent, '');
      expect(
        RichMessageDocument.decode(doc.encode(), expectedText: 'different'),
        isNull,
      );
    },
  );

  test(
    'rejects unsupported deltas and unsafe links with readable fallback',
    () {
      for (final url in [
        'javascript:alert(1)',
        'file:///secret',
        'https://user:pass@example.com',
        'data:text/html,x',
      ]) {
        expect(RichMessageDocument.safeLink(url), isNull);
      }
      for (final ops in [
        [
          {'retain': 1},
        ],
        [
          {
            'insert': {'image': 'https://tracker'},
          },
        ],
        [
          {
            'insert': 'bad\n',
            'attributes': {'font': 'unknown'},
          },
        ],
      ]) {
        expect(() => RichMessageDocument.fromOps(ops), throwsFormatException);
      }
      expect(RichMessageDocument.decode('{broken'), isNull);
    },
  );

  test(
    'external paste preserves supported styles and falls back for foreign blocks',
    () {
      final bold = [
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
      ];
      expect(RichMessageDocument.safePaste(bold), bold);
      final safe = RichMessageDocument.safePaste([
        {
          'insert': 'Text',
          'attributes': {'font': 'ForeignFont'},
        },
        {
          'insert': {'image': 'https://example.com/tracker.png'},
        },
      ]);
      expect(safe.single['insert'], 'Text[Media]');
      expect(
        RichMessageDocument.fromOps([
          ...safe,
          {'insert': '\n'},
        ]).text,
        'Text[Media]',
      );
    },
  );

  test(
    'direct sender, recipient and group encryption retain document',
    () async {
      final sender = MeshCrypto();
      final recipient = MeshCrypto();
      await sender.initialize('rich-sender', 'password');
      await recipient.initialize('rich-recipient', 'password');
      final doc = sample();
      final encrypted = await sender.encryptText(
        recipient.publicKey,
        doc.encode(),
      );
      expect(encrypted, isNot(contains('hidden')));
      for (final crypto in [sender, recipient]) {
        expect(
          RichMessageDocument.decode(
            await crypto.decryptText(encrypted),
          )!.encode(),
          doc.encode(),
        );
      }
      final key = sender.generateGroupKey();
      final group = await sender.encryptGroupText(key, doc.encode());
      expect(await recipient.decryptGroupText(key, group), doc.encode());
    },
  );

  test('draft writes ordered and scoped to account and chat', () async {
    final store = RichDraftStore('account-a/chat-a');
    final first = store.save(sample());
    final last = store.save(RichMessageDocument.fromText('latest'));
    await first;
    await last;
    expect((await store.load())!.text, 'latest');
    expect(await RichDraftStore('account-b/chat-a').load(), isNull);
    await store.save(null);
    expect(await store.load(), isNull);
  });

  testWidgets('rich document renders in a narrow bubble without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: RichMessageView(document: sample()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Spoiler'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);
    await tester.tap(find.text('Spoiler'));
    await tester.pumpAndSettle();
    expect(find.text('hidden'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media block can be removed and restored with undo', (
    tester,
  ) async {
    final document = RichMessageDocument.fromOps([
      {'insert': 'Plan\n'},
      {
        'insert': {
          'mesh': jsonEncode({
            'type': 'attachment',
            'id': 'file-one',
            'name': 'plan.pdf',
          }),
        },
      },
      {'insert': '\n'},
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: RichMessageEditorPage(
          initial: document,
          drafts: RichDraftStore('media-undo'),
          onSend: (_) async {},
          attachmentBuilder: (_, name) => Text(name),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Media'));
    await tester.pumpAndSettle();
    expect(find.text('Photo or video'), findsOneWidget);
    expect(find.text('Audio file'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    await tester.tapAt(const Offset(5, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove block'));
    await tester.pumpAndSettle();
    expect(find.text('plan.pdf'), findsNothing);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('plan.pdf'), findsOneWidget);
    final editor = tester
        .widget<q.QuillEditor>(find.byType(q.QuillEditor))
        .controller;
    expect(
      RichMessageDocument.fromOps(
        editor.document.toDelta().toJson(),
      ).attachments.single['id'],
      'file-one',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('editor keeps draft after failed send', (tester) async {
    final store = RichDraftStore('test-editor');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: RichMessageEditorPage(
          initial: sample(),
          drafts: store,
          onSend: (_) async => throw StateError('Offline test'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline test'), findsOneWidget);
    expect((await store.load())!.encode(), sample().encode());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'mobile toolbar applies formatting, previews a formula and sends a document',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final drafts = RichDraftStore('toolbar-editor');
      RichMessageDocument? sent;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => RichMessageEditorPage(
                      initial: RichMessageDocument.fromText('Hello world'),
                      drafts: drafts,
                      onSend: (document) async {
                        sent = document;
                      },
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller;
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5),
        q.ChangeSource.local,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Formatting'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bold'));
      await tester.pumpAndSettle();
      expect(controller.document.toDelta().toJson().first['attributes'], {
        'bold': true,
      });
      controller.updateSelection(
        TextSelection.collapsed(offset: controller.document.length - 1),
        q.ChangeSource.local,
      );
      await tester.ensureVisible(find.byTooltip('Formula'));
      await tester.tap(find.byTooltip('Formula'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), r'x^2');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!.text, contains('Hello world'));
      expect(sent!.text, contains(r'x^2'));
      expect(await drafts.load(), isNull);
      expect(find.text('Open editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
