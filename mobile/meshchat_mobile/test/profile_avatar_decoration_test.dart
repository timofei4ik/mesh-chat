import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/widgets/profile_avatar.dart';

void main() {
  testWidgets('raster frame alignment preview', (tester) async {
    const styles = [
      'camp_clouds',
      'camp_moon',
      'camp_ember',
      'camp_stories',
      'camp_rainlight',
    ];
    const boundary = ValueKey('frame-preview');
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            backgroundColor: const Color(0xFF18242C),
            body: Center(
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  for (final style in styles)
                    ProfileAvatar(
                      profile: Profile(
                        nodeId: style,
                        displayName: 'M',
                        avatarDecoration: style,
                      ),
                      radius: 60,
                      animateDecoration: false,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.environment['MESH_DESIGN_SCREENSHOTS'] == '1') {
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundary),
      );
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/design-review/avatar-frames.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  const decorations = <String>[
    'none',
    'stardust',
    'ember',
    'sunset_clouds',
    'neon_orbit',
    'frost_bloom',
  ];

  testWidgets('all avatar decorations render at compact and profile sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF07111E),
          body: Center(child: _DecorationPreview()),
        ),
      ),
    );

    expect(find.byType(ProfileAvatar), findsNWidgets(decorations.length * 2));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 650));
    expect(tester.takeException(), isNull);
  });
}

class _DecorationPreview extends StatelessWidget {
  const _DecorationPreview();

  @override
  Widget build(BuildContext context) {
    const decorations = <String>[
      'none',
      'stardust',
      'ember',
      'sunset_clouds',
      'neon_orbit',
      'frost_bloom',
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final decoration in decorations) ...[
          ProfileAvatar(
            profile: Profile(
              nodeId: 'compact-$decoration',
              displayName: 'M',
              avatarDecoration: decoration,
            ),
            radius: 24,
          ),
          ProfileAvatar(
            profile: Profile(
              nodeId: 'large-$decoration',
              displayName: 'M',
              avatarDecoration: decoration,
            ),
            radius: 54,
          ),
        ],
      ],
    );
  }
}
