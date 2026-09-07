import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/widgets/collection_message_surface.dart';

const styles = [
  'nebula',
  'ocean',
  'sakura',
  'solar',
  'stardust',
  'ember',
  'sunset',
  'frost',
  'orbit',
  'camp_clouds',
  'camp_moon',
  'camp_ember',
  'camp_stories',
  'camp_rainlight',
  'remote_skybound_camp',
  'remote_moonlit_path',
  'remote_ember_vale',
  'remote_lantern_stories',
];

CollectionBubbleSkin skin(String style) => collectionBubbleSkin(
  Profile(
    nodeId: 'sender',
    displayName: 'Sender',
    meshProBadge: true,
    profileBackground: style,
  ),
)!;

Widget bubble(String style, String text, {Key? key}) =>
    CollectionMessageSurface(
      key: key,
      skin: skin(style),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 310),
      child: Text(text, style: const TextStyle(fontSize: 16, height: 1.35)),
    );

void main() {
  test(
    'explicit bubble style survives profile serialization independently',
    () {
      const profile = Profile(
        nodeId: 'sender',
        displayName: 'Sender',
        meshProBadge: true,
        profileBackground: 'sakura',
        messageBubbleStyle: 'ocean',
      );
      final restored = Profile.fromJson(
        profile.toJson(),
      ).copyWith(about: 'Changed');
      expect(restored.effectiveProfileBackground, 'sakura');
      expect(collectionBubbleSkin(restored)!.asset, endsWith('/ocean.png'));
      expect(
        collectionBubbleSkin(restored.copyWith(messageBubbleStyle: 'none')),
        isNull,
      );
      expect(
        collectionBubbleSkin(restored.copyWith(meshProBadge: false)),
        isNull,
      );
      expect(
        collectionBubbleSkin(
          restored.copyWith(messageBubbleStyle: 'auto'),
        )!.asset,
        endsWith('/sakura.png'),
      );
    },
  );
  testWidgets('tall media has no vertically stretched art in its middle', (
    tester,
  ) async {
    for (final style in styles) {
      const key = ValueKey('tall-media');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: key,
                child: CollectionMessageSurface(
                  skin: skin(style),
                  decoration: const BoxDecoration(),
                  padding: const EdgeInsets.all(12),
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: const SizedBox(width: 210, height: 240),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final offset =
            ((image.height ~/ 2) * image.width + image.width - 16) * 4;
        final color = skin(style).color.toARGB32();
        expect(bytes!.getUint8(offset), (color >> 16) & 255);
        expect(bytes.getUint8(offset + 1), (color >> 8) & 255);
        expect(bytes.getUint8(offset + 2), color & 255);
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('all collections use identical dimensions for the same text', (
    tester,
  ) async {
    Size? expected;
    for (final style in styles) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: bubble(style, 'Same message', key: const ValueKey('same')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byKey(const ValueKey('same')));
      expected ??= size;
      expect(size, expected);
      await tester.runAsync(() async {
        final bytes = await rootBundle.load(skin(style).asset);
        final codec = await ui.instantiateImageCodec(
          bytes.buffer.asUint8List(),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 600);
        expect(frame.image.height, 180);
        frame.image.dispose();
        codec.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });
  test('tail mirrors for outgoing messages without scaling corner radii', () {
    for (final size in [const Size(80, 40), const Size(300, 180)]) {
      final left = const CollectionBubbleBorder().getOuterPath(
        Offset.zero & size,
      );
      final right = const CollectionBubbleBorder(
        mine: true,
      ).getOuterPath(Offset.zero & size);
      for (double y = 1; y < size.height; y += 3) {
        for (double x = 1; x < size.width; x += 3) {
          expect(
            left.contains(Offset(x, y)),
            right.contains(Offset(size.width - x, y)),
          );
        }
      }
    }
  });
  test('sender entitlement and exact profile determine skin, not viewer', () {
    for (final style in styles) {
      expect(File(skin(style).asset).existsSync(), isTrue);
      expect(
        collectionBubbleSkin(
          Profile(
            nodeId: 'n',
            displayName: 'n',
            profileBackground: style,
            meshProBadge: false,
          ),
        ),
        isNull,
      );
    }
    expect(collectionBubbleSkin(null), isNull);
    expect(
      collectionBubbleSkin(
        const Profile(
          nodeId: 'n',
          displayName: 'n',
          meshProBadge: true,
          profileBackground: 'remote_unknown',
        ),
      ),
      isNull,
    );
  });

  testWidgets('short and tall messages retain the same fixed artwork size', (
    tester,
  ) async {
    for (final style in styles) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bubble(style, 'OK', key: const ValueKey('short')),
                bubble(
                  style,
                  List.filled(12, 'A longer message.').join(' '),
                  key: const ValueKey('long'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('short'))).width,
        lessThan(tester.getSize(find.byKey(const ValueKey('long'))).width),
      );
      final images = find.byType(Image);
      for (final image in tester.widgetList<Image>(images)) {
        expect(image.centerSlice, isNull);
        expect(image.width, 150);
        expect(image.height, 45);
        expect(image.image, isA<ExactAssetImage>());
        expect((image.image as ExactAssetImage).scale, 4);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow screen, large text and quotes fit', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 200,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final style in styles)
                      bubble(
                        style,
                        'Quoted message\nA longer reply that wraps.',
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('visual preview', (tester) async {
    if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] != '1') return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview');
      loader.addFont(
        File(
          'C:/Windows/Fonts/segoeui.ttf',
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    });
    await tester.binding.setSurfaceSize(const Size(740, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const boundary = ValueKey('preview');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Preview'),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            backgroundColor: const Color(0xFF10171F),
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final style in ['camp_clouds', 'remote_moonlit_path'])
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(style),
                          const SizedBox(height: 16),
                          for (final text in [
                            'ок',
                            'Давай встретимся в семь',
                            'Я немного задержусь. Давайте встретимся у входа в парк, а потом вместе дойдём до кафе.',
                            'Встретимся у входа\nХорошо, буду ждать там.',
                          ]) ...[
                            bubble(style, text),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final render = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundary),
    );
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-review/collection-bubbles.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
