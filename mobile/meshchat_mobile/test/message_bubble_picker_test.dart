import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/widgets/message_bubble_picker.dart';

void main() {
  testWidgets('picker screenshot', (tester) async {
    if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] != '1') return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview');
      loader.addFont(
        File(
          'C:/Windows/Fonts/segoeui.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    await tester.binding.setSurfaceSize(const Size(390, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const key = ValueKey('picker-preview');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Preview'),
        ),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MessageBubblePicker(
                profile: const Profile(
                  nodeId: 'a',
                  displayName: 'A',
                  meshProBadge: true,
                  profileBackground: 'sakura',
                ),
                onSave: (_, _) async => null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      final context = tester.element(find.byType(MessageBubblePicker));
      for (final name in ['sakura', 'nebula', 'ocean']) {
        await precacheImage(AssetImage('assets/message_bubbles/$name.png', package: null), context);
        await precacheImage(ExactAssetImage('assets/message_bubbles/$name.png', scale: 4), context);
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final render = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-review/bubble-picker.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
  testWidgets('picker previews, saves selected style and retains errors', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: MessageBubblePicker(
            profile: const Profile(
              nodeId: 'a',
              displayName: 'A',
              meshProBadge: true,
              profileBackground: 'sakura',
            ),
            onSave: (value, animated) async {
              saved = value;
              return 'Server unavailable';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ocean'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(saved, 'ocean');
    expect(find.text('Server unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Lantern Stories'), 240);
    await tester.tap(find.text('Lantern Stories'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(saved, 'remote_lantern_stories');
    expect(tester.takeException(), isNull);
  });
}
