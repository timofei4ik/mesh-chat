import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/call_signal_buffer.dart';

Map<String, dynamic> signal(String type, {String peer = 'peer'}) => {
  'type': type,
  'call_id': 'call',
  'destination_node': peer,
  'packet_id': '$type:$peer',
};
void main() {
  test('reconnect preserves offer then ICE ordering', () {
    final buffer = CallSignalBuffer();
    buffer.add(signal('call_offer'));
    buffer.add(signal('call_ice'));
    buffer.flush((_) => false);
    final sent = <String>[];
    buffer.flush((p) {
      sent.add(p['type'] as String);
      return true;
    });
    expect(sent, ['call_offer', 'call_ice']);
    buffer.flush((_) => fail('already delivered'));
  });
  test('ending a call cancels queued setup and prevents late resurrection', () {
    final buffer = CallSignalBuffer();
    buffer.add(signal('call_offer'));
    buffer.add(signal('call_end'));
    buffer.add(signal('call_offer'));
    final sent = <String>[];
    buffer.flush((p) {
      sent.add(p['type'] as String);
      return true;
    });
    expect(sent, ['call_end']);
  });
  test('one group peer ending does not discard signals for another peer', () {
    final buffer = CallSignalBuffer();
    buffer.add(signal('call_offer', peer: 'a'));
    buffer.add(signal('call_offer', peer: 'b'));
    buffer.add(signal('call_end', peer: 'a'));
    final sent = <String>[];
    buffer.flush((p) {
      sent.add('${p['type']}:${p['destination_node']}');
      return true;
    });
    expect(sent, ['call_offer:b', 'call_end:a']);
  });
  test('expired invitations and signed-out packets never replay', () {
    var now = DateTime.utc(2026);
    final buffer = CallSignalBuffer(now: () => now);
    buffer.add(signal('call_offer'));
    now = now.add(const Duration(seconds: 11));
    buffer.flush((_) => fail('expired invitation'));
    buffer.add(signal('call_offer'));
    buffer.clear();
    buffer.flush((_) => fail('signed out'));
  });
  test('captions are not queued as delayed call control', () {
    expect(CallSignalBuffer.handles(signal('call_caption')), false);
    expect(CallSignalBuffer.handles(signal('call_caption_session')), false);
    expect(CallSignalBuffer.handles(signal('call_answer')), true);
  });
}
