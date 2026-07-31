import '../models/chat_thread.dart';

class ReadStateReconciler {
  const ReadStateReconciler._();

  static void apply({
    required Iterable<ChatThread> threads,
    required Object? rawReceipts,
    required String currentLogin,
    required bool Function(String nodeId) isOwnNode,
  }) {
    final normalizedLogin = currentLogin.trim().toLowerCase();
    if (normalizedLogin.isEmpty) return;

    final readersByMessage = <String, Set<String>>{};
    if (rawReceipts is List) {
      for (final raw in rawReceipts) {
        if (raw is! Map) continue;
        final messageId = raw['message_id']?.toString().trim() ?? '';
        final readerLogin =
            raw['reader_login']?.toString().trim().toLowerCase() ?? '';
        if (messageId.isEmpty || readerLogin.isEmpty) continue;
        readersByMessage
            .putIfAbsent(messageId, () => <String>{})
            .add(readerLogin);
      }
    }

    for (final thread in threads) {
      var latestReadIncomingIndex = -1;
      for (var index = 0; index < thread.messages.length; index++) {
        final message = thread.messages[index];
        final sentByMe = isOwnNode(message.senderNode);
        final readers = readersByMessage[message.id];
        final receiptMarksRead = sentByMe
            ? readers?.any((reader) => reader != normalizedLogin) == true
            : readers?.contains(normalizedLogin) == true;
        if (receiptMarksRead && !message.read) {
          thread.messages[index] = message.copyWith(
            read: true,
            delivered: true,
            pending: false,
            failed: false,
          );
        }
        if (!sentByMe && thread.messages[index].read) {
          latestReadIncomingIndex = index;
        }
      }

      // Reading a later message implies that every earlier incoming message in
      // the same ordered thread was visible too. This repairs sparse receipts
      // left by older clients after a clean install or cache replacement.
      for (var index = 0; index < latestReadIncomingIndex; index++) {
        final message = thread.messages[index];
        if (isOwnNode(message.senderNode) || message.read) continue;
        thread.messages[index] = message.copyWith(read: true);
      }

      thread.unread = thread.messages
          .where((message) => !isOwnNode(message.senderNode) && !message.read)
          .length;
    }
  }
}
