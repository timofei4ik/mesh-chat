import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/widgets/profile_avatar.dart';

void main() {
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
