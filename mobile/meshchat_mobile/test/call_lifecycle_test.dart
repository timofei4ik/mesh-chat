import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/services/call_models.dart';

void main() {
  group('call lifecycle', () {
    test('supports ringing through connected to ended', () {
      expect(
        isValidCallTransition(CallStatus.ringing, CallStatus.connecting),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.connecting, CallStatus.active),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.active, CallStatus.ended),
        isTrue,
      );
    });

    test('supports reconnect and rejects resurrection after end', () {
      expect(
        isValidCallTransition(CallStatus.active, CallStatus.connecting),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.ended, CallStatus.active),
        isFalse,
      );
    });
  });

  group('call quality', () {
    test('rates direct healthy audio as excellent', () {
      const quality = CallQualitySnapshot(
        roundTripTimeMs: 45,
        jitterMs: 8,
        packetLossPercent: 0.2,
        route: 'direct',
      );
      expect(quality.qualityLevel, 3);
    });

    test('rates high loss TURN audio as poor', () {
      const quality = CallQualitySnapshot(
        roundTripTimeMs: 510,
        jitterMs: 110,
        packetLossPercent: 12,
        route: 'turn',
      );
      expect(quality.qualityLevel, 1);
    });
  });
}
