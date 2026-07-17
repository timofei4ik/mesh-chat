import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/widgets/profile_effect_background.dart';

void main() {
  test('profile effect pulse fades in and out at every object change', () {
    for (final boundary in <double>[0, 1 / 3, 2 / 3, 1]) {
      expect(profileEffectPulse(boundary), closeTo(0, 0.000001));
    }

    expect(profileEffectPulse(1 / 6), closeTo(1, 0.000001));
    expect(profileEffectPulse(0.01), lessThan(0.03));
    expect(profileEffectPulse((1 / 3) - 0.01), lessThan(0.03));
    expect(
      profileEffectPulse((1 / 3) - 0.03),
      greaterThan(profileEffectPulse((1 / 3) - 0.01)),
    );
  });
}
