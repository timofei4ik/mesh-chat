import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/utils/message_grouping.dart';
import 'package:meshchat_mobile/src/widgets/collection_message_surface.dart';

ChatMessage message(
  String sender,
  DateTime at, {
  ChatMessageKind kind = ChatMessageKind.text,
  bool deleted = false,
}) => ChatMessage(
  id: '$sender-$at',
  senderNode: sender,
  receiverNode: 'peer',
  text: 'Text',
  createdAt: at,
  kind: kind,
  deleted: deleted,
);

void main() {
  test('same sender text and voice/file messages form one visual group', () {
    final time = DateTime(2026, 9, 9, 12);
    final first = message('a', time);
    expect(
      messagesShareBubbleGroup(
        first,
        message(
          'a',
          time.add(const Duration(minutes: 1)),
          kind: ChatMessageKind.file,
        ),
      ),
      isTrue,
    );
    expect(messagesShareBubbleGroup(first, message('b', time)), isFalse);
    expect(
      messagesShareBubbleGroup(first, message('a', time, deleted: true)),
      isFalse,
    );
    expect(
      messagesShareBubbleGroup(
        first,
        message('a', time, kind: ChatMessageKind.sticker),
      ),
      isFalse,
    );
    expect(
      messagesShareBubbleGroup(
        first,
        message('a', time.add(const Duration(minutes: 6))),
      ),
      isFalse,
    );
    expect(messagesShareBubbleGroup(null, first), isFalse);
  });

  test('midnight and reversed ordering break grouping', () {
    final time = DateTime(2026, 9, 9, 23, 59);
    expect(
      messagesShareBubbleGroup(
        message('a', time),
        message('a', time.add(const Duration(minutes: 1))),
      ),
      isFalse,
    );
    expect(
      messagesShareBubbleGroup(
        message('a', time),
        message('a', time.subtract(const Duration(seconds: 1))),
      ),
      isFalse,
    );
  });

  test('tail occupies sender edge only on the final bubble', () {
    const rect = Rect.fromLTWH(0, 0, 240, 65);
    final finalIncoming = const CollectionBubbleBorder()
        .getOuterPath(rect)
        .getBounds();
    final groupedIncoming = const CollectionBubbleBorder(
      showTail: false,
    ).getOuterPath(rect).getBounds();
    expect(finalIncoming.left, 0);
    expect(groupedIncoming.left, 6);
    final finalOutgoing = const CollectionBubbleBorder(
      mine: true,
    ).getOuterPath(rect).getBounds();
    final groupedOutgoing = const CollectionBubbleBorder(
      mine: true,
      showTail: false,
    ).getOuterPath(rect).getBounds();
    expect(finalOutgoing.right, rect.right);
    expect(groupedOutgoing.right, rect.right - 6);
  });
}
