import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/services/read_state_reconciler.dart';

void main() {
  ChatThread threadWith(List<ChatMessage> messages) => ChatThread(
    profile: const Profile(nodeId: 'bob-node', displayName: 'Bob'),
    messages: messages,
  );

  ChatMessage message(String id, String sender, {bool read = false}) =>
      ChatMessage(
        id: id,
        senderNode: sender,
        receiverNode: sender == 'me' ? 'bob-node' : 'me',
        text: id,
        createdAt: DateTime.utc(2026, 1, 1, 0, int.parse(id.substring(1))),
        read: read,
      );

  test('a later receipt repairs earlier sparse incoming receipts', () {
    final thread = threadWith([
      message('m1', 'bob-node'),
      message('m2', 'bob-node'),
      message('m3', 'bob-node'),
    ]);

    ReadStateReconciler.apply(
      threads: [thread],
      rawReceipts: [
        {'message_id': 'm2', 'reader_login': 'alice'},
      ],
      currentLogin: 'alice',
      isOwnNode: (node) => node == 'me',
    );

    expect(thread.messages.map((message) => message.read), [true, true, false]);
    expect(thread.unread, 1);
  });

  test('cached read state also acts as a local watermark', () {
    final thread = threadWith([
      message('m1', 'bob-node'),
      message('m2', 'bob-node', read: true),
      message('m3', 'bob-node'),
    ]);

    ReadStateReconciler.apply(
      threads: [thread],
      rawReceipts: const [],
      currentLogin: 'alice',
      isOwnNode: (node) => node == 'me',
    );

    expect(thread.messages.map((message) => message.read), [true, true, false]);
    expect(thread.unread, 1);
  });

  test('another reader only marks messages sent by this account', () {
    final thread = threadWith([message('m1', 'me'), message('m2', 'bob-node')]);

    ReadStateReconciler.apply(
      threads: [thread],
      rawReceipts: [
        {'message_id': 'm1', 'reader_login': 'bob'},
        {'message_id': 'm2', 'reader_login': 'bob'},
      ],
      currentLogin: 'alice',
      isOwnNode: (node) => node == 'me',
    );

    expect(thread.messages[0].read, isTrue);
    expect(thread.messages[1].read, isFalse);
    expect(thread.unread, 1);
  });
}
