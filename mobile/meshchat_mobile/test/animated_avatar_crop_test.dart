import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/utils/animated_avatar_crop.dart';

void main() {
  test('animated avatar keeps source bytes and round-trips crop metadata', () {
    final source = Uint8List.fromList(<int>[71, 73, 70, 56, 57, 97, 1, 2, 3]);
    final data = encodeAnimatedAvatarData(
      source,
      scale: 1.375,
      translateX: -24.25,
      translateY: 7.5,
    );
    final crop = AnimatedAvatarCrop.tryParse(data);
    final encoded = data.substring(data.indexOf(',') + 1);

    expect(base64Decode(encoded), orderedEquals(source));
    expect(crop, isNotNull);
    expect(crop!.scale, 1.375);
    expect(crop.translateX, -24.25);
    expect(crop.translateY, 7.5);
  });

  test('malformed animated avatar crop is ignored safely', () {
    expect(
      AnimatedAvatarCrop.tryParse('data:image/gif;meshcrop=nope;base64,AA=='),
      isNull,
    );
    expect(
      AnimatedAvatarCrop.tryParse(
        'data:image/gif;meshcrop=99.0:0.0:0.0;base64,AA==',
      ),
      isNull,
    );
  });
}
