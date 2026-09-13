import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/notification_service.dart';

void main() {
  test('notification target survives payload round trip', () {
    const target = NotificationTarget(
      packetType: 'group_message',
      sourceNode: 'alice-phone',
      groupId: 'group-7',
      callId: 'call-1',
    );

    final restored = NotificationTarget.decode(target.encode());

    expect(restored, isNotNull);
    expect(restored!.packetType, 'group_message');
    expect(restored.sourceNode, 'alice-phone');
    expect(restored.groupId, 'group-7');
    expect(restored.callId, 'call-1');
  });

  test('native push field names map to an activation target', () {
    final target = NotificationTarget.fromMap({
      'type': 'call_offer',
      'source_node': 'alice-phone',
      'call_id': 'call-1',
    });

    expect(target.packetType, 'call_offer');
    expect(target.sourceNode, 'alice-phone');
    expect(target.callId, 'call-1');
    expect(target.isEmpty, isFalse);
  });

  test('invalid or navigation-free payload is ignored', () {
    expect(NotificationTarget.decode('{broken'), isNull);
    expect(NotificationTarget.decode('{"packet_type":"chat_message"}'), isNull);
    expect(NotificationTarget.decode('[]'), isNull);
  });
}
