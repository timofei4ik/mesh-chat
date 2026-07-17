import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
  test('Bluetooth chat survives cache serialization in its own namespace', () {
    const peer = Profile(
      nodeId: 'peer-node',
      displayName: 'Nearby peer',
      publicKey: 'peer-key',
    );
    final bluetooth = ChatThread(
      profile: peer,
      threadId: 'bluetooth:peer-node',
      chatKind: 'bluetooth',
      messages: [
        ChatMessage(
          id: 'ble-message',
          senderNode: 'me',
          receiverNode: 'peer-node',
          text: 'Direct over BLE',
          createdAt: DateTime.utc(2026, 7, 16),
        ),
      ],
    );

    final restored = ChatThread.fromJson(bluetooth.toJson());
    final normal = ChatThread(profile: peer);

    expect(restored.isBluetooth, isTrue);
    expect(restored.threadId, 'bluetooth:peer-node');
    expect(restored.storageKey, 'direct:bluetooth:peer-node');
    expect(restored.messages.single.text, 'Direct over BLE');
    expect(normal.storageKey, 'direct:normal:peer-node');
    expect(restored.storageKey, isNot(normal.storageKey));
  });
}
