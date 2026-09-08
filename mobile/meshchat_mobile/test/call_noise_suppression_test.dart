import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:meshchat_mobile/src/services/call_audio_constraints.dart';
import 'package:meshchat_mobile/src/services/call_noise_suppression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rtc = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final owners = <Object>[];
  final calls = <MethodCall>[];
  final rtcCalls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    WebRTC.initialized = false;
    calls.clear();
    rtcCalls.clear();
    messenger.setMockMethodCallHandler(rtc, (call) async {
      rtcCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(CallNoiseSuppression.channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() async {
    for (final owner in owners) {
      await CallNoiseSuppression.release(owner);
    }
    owners.clear();
    messenger.setMockMethodCallHandler(rtc, null);
    messenger.setMockMethodCallHandler(CallNoiseSuppression.channel, null);
    WebRTC.initialized = false;
    debugDefaultTargetPlatformOverride = null;
  });

  Object owner() {
    final o = Object();
    owners.add(o);
    return o;
  }

  test(
    'Android and iOS receive legacy constraints without losing desktop flags',
    () {
      final audio =
          callAudioConstraints(
                native: true,
                enhanced: true,
                hd: false,
                inputId: 'usb',
              )['audio']
              as Map;
      final optional = {
        for (final flag in audio['optional'] as List) ...(flag as Map),
      };
      expect(optional['googNoiseSuppression'], true);
      expect(optional['googEchoCancellation'], true);
      expect(optional['googHighpassFilter'], true);
      expect(audio['noiseSuppression'], true);
      expect(audio['deviceId'], {'exact': 'usb'});
      expect(audio['sampleRate'], {'ideal': 48000});
      expect(optional.containsKey('googAutoGainControl2'), false);
    },
  );

  test(
    'browser constraints use standard names and never require a device format',
    () {
      final audio =
          callAudioConstraints(native: false, enhanced: true, hd: true)['audio']
              as Map;
      expect(audio.keys.any((key) => key.toString().startsWith('goog')), false);
      expect(audio.containsKey('optional'), false);
      expect(audio.containsKey('latency'), false);
      expect(audio['echoCancellation'], true);
      expect(audio['channelCount'], {'ideal': 1});
    },
  );

  test('filter stays enabled until every group peer releases it', () async {
    final a = owner(), b = owner(), basic = owner();
    await CallNoiseSuppression.acquire(a, enhanced: true);
    await CallNoiseSuppression.acquire(b, enhanced: true);
    await CallNoiseSuppression.acquire(basic, enhanced: false);
    await CallNoiseSuppression.release(a);
    await CallNoiseSuppression.release(basic);
    expect(calls.last.arguments['enabled'], true);
    await CallNoiseSuppression.release(b);
    expect(calls.last.arguments['enabled'], false);
    expect(rtcCalls, hasLength(1));
    expect(rtcCalls.single.arguments['options']['audioSampleRate'], 48000);
  });

  test(
    'duplicate acquisition does not retain filter after call ends',
    () async {
      final a = owner();
      await CallNoiseSuppression.acquire(a, enhanced: true);
      await CallNoiseSuppression.acquire(a, enhanced: true);
      await CallNoiseSuppression.release(a);
      expect(calls.last.arguments['enabled'], false);
    },
  );

  test(
    'unsupported native filter does not prevent basic audio calls',
    () async {
      messenger.setMockMethodCallHandler(
        CallNoiseSuppression.channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      final a = owner();
      await CallNoiseSuppression.acquire(a, enhanced: true);
      await CallNoiseSuppression.release(a);
      expect(await CallNoiseSuppression.status(), {'supported': false});
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    test('$platform uses the native WebRTC capture filter', () async {
      debugDefaultTargetPlatformOverride = platform;
      final a = owner();
      await CallNoiseSuppression.acquire(a, enhanced: true);
      await CallNoiseSuppression.release(a);
      expect(calls, isEmpty);
      expect(rtcCalls.map((c) => c.method), [
        'initialize',
        'meshNoiseConfigure',
        'meshNoiseConfigure',
      ]);
      expect(rtcCalls[1].arguments['enabled'], true);
      expect(rtcCalls[2].arguments['enabled'], false);
    });
  }
  test('unsupported platforms retain stock WebRTC processing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final a = owner();
    await CallNoiseSuppression.acquire(a, enhanced: true);
    await CallNoiseSuppression.release(a);
    expect(rtcCalls, isEmpty);
    expect(await CallNoiseSuppression.status(), {'supported': false});
  });
}
