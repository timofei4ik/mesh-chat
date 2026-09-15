import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/media_stream_impl.dart';
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart';
import 'package:flutter_webrtc/src/native/mediadevices_impl.dart';
import 'package:flutter_webrtc/src/native/utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rtc = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    WebRTC.initialized = false;
    messenger.setMockMethodCallHandler(rtc, (call) async {
      if (call.method == 'getUserMedia') {
        return {
          'streamId': 'microphone',
          'audioTracks': [
            {
              'id': 'audio',
              'label': 'Microphone',
              'kind': 'audio',
              'enabled': 1,
            },
          ],
          'videoTracks': [],
        };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(rtc, null);
    WebRTC.initialized = false;
  });

  test('microphone capture accepts an iOS numeric enabled flag', () async {
    final stream = await MediaDeviceNative.instance.getUserMedia({
      'audio': true,
      'video': false,
    });
    expect(stream.getAudioTracks().single.enabled, isTrue);
  });

  test('incoming tracks accept numeric and Android boolean flags', () {
    final numericOff = MediaStreamTrackNative.fromMap({
      'id': 'off',
      'label': 'Audio',
      'kind': 'audio',
      'enabled': 0,
    }, 'peer');
    final booleanOn = MediaStreamTrackNative.fromMap({
      'id': 'on',
      'label': 'Audio',
      'kind': 'audio',
      'enabled': true,
    }, 'peer');
    expect(numericOff.enabled, isFalse);
    expect(booleanOn.enabled, isTrue);

    final remote = MediaStreamNative.fromMap({
      'streamId': 'remote',
      'ownerTag': 'peer',
      'audioTracks': [
        {'id': 'audio', 'label': 'Audio', 'kind': 'audio', 'enabled': 1},
      ],
      'videoTracks': [],
    });
    expect(remote.getAudioTracks().single.enabled, isTrue);
  });
}
