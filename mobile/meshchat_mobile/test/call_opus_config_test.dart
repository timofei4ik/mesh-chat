import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/call_opus_config.dart';

void main() {
  const sdp =
      'v=0\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=rtpmap:111 opus/48000/2\r\n'
      'a=fmtp:111 minptime=20\r\n';

  test('standard calls enable loss recovery and bounded Opus bitrate', () {
    final configured = configureCallOpusSdp(sdp, hd: false);
    expect(configured, contains('useinbandfec=1'));
    expect(configured, contains('usedtx=1'));
    expect(configured, contains('maxaveragebitrate=40000'));
    expect(RegExp('minptime=').allMatches(configured), hasLength(1));
  });

  test('HD calls use the larger bitrate and configuration is idempotent', () {
    final configured = configureCallOpusSdp(sdp, hd: true);
    expect(configured, contains('maxaveragebitrate=96000'));
    expect(configureCallOpusSdp(configured, hd: true), configured);
  });

  test('reconnect backoff becomes bounded', () {
    expect(callReconnectDelay(1), const Duration(seconds: 1));
    expect(callReconnectDelay(2), const Duration(seconds: 3));
    expect(callReconnectDelay(3), const Duration(seconds: 7));
    expect(callReconnectDelay(20), const Duration(seconds: 10));
  });

  test('audio bitrate reacts to network quality without starving Opus', () {
    expect(
      recommendedCallBitrateBps(
        packetLossPercent: 0,
        jitterMs: 8,
        roundTripTimeMs: 40,
        hd: true,
      ),
      96000,
    );
    expect(
      recommendedCallBitrateBps(
        packetLossPercent: 4,
        jitterMs: 20,
        roundTripTimeMs: 80,
        hd: true,
      ),
      48000,
    );
    expect(
      recommendedCallBitrateBps(
        packetLossPercent: 14,
        jitterMs: 130,
        roundTripTimeMs: 700,
        hd: false,
      ),
      20000,
    );
  });
}
