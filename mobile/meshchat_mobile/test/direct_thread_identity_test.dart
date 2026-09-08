import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/services/direct_thread_identity.dart';

Profile peer(String node, {String login = 'person'}) => Profile(
  nodeId: node,
  displayName: 'Same name',
  accountLogin: login,
  avatarData: 'same-avatar',
  publicUsername: 'same-public-name',
);
ChatMessage message(String id, int minute) => ChatMessage(
  id: id,
  senderNode: 'person',
  receiverNode: 'me',
  text: id,
  createdAt: DateTime.utc(2026, 9, 8, 12, minute),
);

void main() {
  test('an old device copy cannot restore a globally deleted message', () {
    final threads = {
      'old': ChatThread(
        profile: peer('old'),
        messages: [message('removed', 1)],
      ),
      'new': ChatThread(profile: peer('new'), messages: [message('kept', 2)]),
    };
    consolidateDirectThreads(threads, deletedMessageIds: {'removed'});
    expect(threads.values.single.messages.map((m) => m.id), ['kept']);
  });
  test('new device history is unioned, not selected by the last message', () {
    final old = ChatThread(
      profile: peer('old'),
      messages: [message('a', 1), message('b', 2)],
    );
    final recent = ChatThread(
      profile: peer('new'),
      messages: [message('c', 3)],
    );
    final threads = {'old': old, 'new': recent};
    consolidateDirectThreads(threads);
    expect(threads.length, 1);
    expect(threads.values.single, same(old));
    expect(old.messages.map((m) => m.id), ['a', 'b', 'c']);
    expect(findDirectAccountThread(threads.values, peer('new')), same(old));
    old.messages.add(message('d', 4));
    expect(recent.messages.last.id, 'd');
    final restored = ChatThread.fromJson(old.toJson());
    expect(restored.messages.map((m) => m.id), ['a', 'b', 'c', 'd']);
    expect(restored.profile.nodeAliases, containsAll(['old', 'new']));
  });
  test('identical names, usernames and avatars are not account identity', () {
    final threads = {
      'a': ChatThread(profile: peer('a', login: 'alice')),
      'b': ChatThread(profile: peer('b', login: 'bob')),
      'c': ChatThread(profile: peer('c', login: '')),
      'd': ChatThread(profile: peer('d', login: '')),
    };
    consolidateDirectThreads(threads);
    expect(threads.length, 4);
  });
  test('conflicting account identities are not merged through an alias', () {
    expect(
      sameDirectAccount(
        peer('a', login: 'alice'),
        peer('b', login: 'bob').copyWith(nodeAliases: ['a']),
      ),
      false,
    );
  });
  test('receipts and tombstones survive duplicate message reconciliation', () {
    final a = ChatThread(
      profile: peer('a'),
      messages: [
        message('receipt', 1).copyWith(pending: true),
        message('deleted', 2).copyWith(deleted: true),
      ],
    );
    final b = ChatThread(
      profile: peer('b'),
      messages: [
        message('receipt', 1).copyWith(read: true),
        message('deleted', 2),
      ],
    );
    mergeDirectHistory(a, b);
    expect(a.messages.length, 2);
    expect(a.messages.first.read, true);
    expect(a.messages.first.delivered, true);
    expect(a.messages.first.pending, false);
    expect(a.messages.last.deleted, true);
  });
  test('secret, Bluetooth, group and saved histories remain separate', () {
    final threads = {
      'normal': ChatThread(profile: peer('a')),
      'secret': ChatThread(profile: peer('a'), chatKind: 'secret'),
      'bluetooth': ChatThread(profile: peer('a'), chatKind: 'bluetooth'),
      'group': ChatThread(profile: peer('a'), isGroup: true),
      'saved': ChatThread(profile: peer('saved:me')),
    };
    consolidateDirectThreads(threads);
    expect(threads.length, 5);
  });
}
