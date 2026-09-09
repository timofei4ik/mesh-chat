import '../models/chat_message.dart';

/// Visual grouping only. Messages keep independent identities and actions.
bool messagesShareBubbleGroup(ChatMessage? previous, ChatMessage? next) {
  if (previous == null ||
      next == null ||
      previous.deleted ||
      next.deleted ||
      previous.senderNode.isEmpty ||
      previous.senderNode != next.senderNode ||
      previous.kind == ChatMessageKind.sticker ||
      next.kind == ChatMessageKind.sticker) {
    return false;
  }
  final before = previous.createdAt.toLocal();
  final after = next.createdAt.toLocal();
  final gap = after.difference(before);
  if (before.year != after.year ||
      before.month != after.month ||
      before.day != after.day ||
      gap.isNegative ||
      gap > const Duration(minutes: 5)) {
    return false;
  }
  // Calls and structured service records are separate timeline events.
  bool service(ChatMessage message) =>
      message.text.startsWith('Call ') ||
      message.text.startsWith('Group call ') ||
      message.text.startsWith('MCPOLL1:');
  return !service(previous) && !service(next);
}
