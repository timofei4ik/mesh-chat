import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/widgets/message_reaction_button.dart';
import 'package:meshchat_mobile/src/widgets/profile_avatar.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('emoji and bitmap chips have equal height at scale $scale', (
      tester,
    ) async {
      final icons = <Widget>[
        const Text('\u{1F44C}', style: TextStyle(fontSize: 16, height: 2.2)),
        const Text('\u2764\uFE0F', style: TextStyle(fontSize: 16, height: 1.6)),
        Image.asset('assets/moose_reaction.png', width: 16, height: 16),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: Wrap(
                  children: [
                    for (var i = 0; i < icons.length; i++)
                      MessageReactionButton(
                        icon: icons[i],
                        reaction: '$i',
                        count: i == 1 ? 123 : 1,
                        selected: i == 0,
                        profiles: const [
                          Profile(nodeId: 'peer', displayName: 'Peer'),
                        ],
                        onPressed: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final chips = find.byType(MessageReactionButton);
      for (var i = 0; i < icons.length; i++) {
        expect(tester.getSize(chips.at(i)).height, 24);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final count in [1, 2, 3, 24]) {
    testWidgets('compact reaction with $count participants', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MessageReactionButton(
                icon: const Icon(Icons.favorite, size: 16),
                reaction: 'heart',
                count: count,
                selected: true,
                profiles: List.generate(
                  count,
                  (i) => Profile(nodeId: '$i', displayName: '$i'),
                ),
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      final chip = find.byType(MessageReactionButton);
      expect(tester.getSize(chip).height, lessThanOrEqualTo(26));
      if (count <= 2) {
        expect(find.byType(ProfileAvatar), findsNWidgets(count));
        expect(find.text('$count'), findsNothing);
        if (count == 2) {
          final avatars = tester
              .widgetList<ProfileAvatar>(find.byType(ProfileAvatar))
              .toList();
          // Stack paints the first reactor last, on top of the second one.
          expect(avatars.last.profile.nodeId, '0');
          final first = find.byWidgetPredicate(
            (w) => w is ProfileAvatar && w.profile.nodeId == '0',
          );
          final second = find.byWidgetPredicate(
            (w) => w is ProfileAvatar && w.profile.nodeId == '1',
          );
          expect(
            tester.getRect(first).overlaps(tester.getRect(second)),
            isTrue,
          );
        }
      } else {
        expect(find.byType(ProfileAvatar), findsNothing);
        expect(find.text('$count'), findsOneWidget);
      }
      await tester.tap(chip);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
