import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';

bool sameDirectAccount(Profile a, Profile b) {
  final left = a.accountLogin.trim().toLowerCase();
  final right = b.accountLogin.trim().toLowerCase();
  if (left.isNotEmpty && right.isNotEmpty) return left == right;
  final nodes = {a.nodeId, ...a.nodeAliases}..remove('');
  return {b.nodeId, ...b.nodeAliases}.any(nodes.contains);
}

bool isOrdinaryDirectThread(ChatThread thread) =>
    !thread.isGroup &&
    thread.chatKind == 'normal' &&
    !thread.profile.nodeId.startsWith('saved:');

ChatThread? findDirectAccountThread(
  Iterable<ChatThread> threads,
  Profile profile,
) {
  for (final thread in threads) {
    if (isOrdinaryDirectThread(thread) &&
        sameDirectAccount(thread.profile, profile)) {
      return thread;
    }
  }
  return null;
}

void mergeDirectHistory(
  ChatThread target,
  ChatThread other, {
  Set<String> deletedMessageIds = const {},
}) {
  if (identical(target, other)) return;
  final messages = <String, ChatMessage>{
    for (final m in target.messages) m.id: m,
  };
  for (final incoming in other.messages) {
    final old = messages[incoming.id];
    if (old == null) {
      messages[incoming.id] = incoming;
      continue;
    }
    // Deletion and receipt acknowledgements must never move backwards.
    final preferred = incoming.deleted || (!old.edited && incoming.edited)
        ? incoming
        : old;
    final delivered =
        old.delivered || incoming.delivered || old.read || incoming.read;
    messages[incoming.id] = preferred.copyWith(
      deleted: old.deleted || incoming.deleted,
      edited: old.edited || incoming.edited,
      read: old.read || incoming.read,
      delivered: delivered,
      pending: !delivered && old.pending && incoming.pending,
      failed: !delivered && preferred.failed,
      fileData: preferred.fileData.isNotEmpty
          ? preferred.fileData
          : (old.fileData.isNotEmpty ? old.fileData : incoming.fileData),
    );
  }
  target.messages
    ..clear()
    ..addAll(
      messages.values.where(
        (message) => !deletedMessageIds.contains(message.id),
      ),
    )
    ..sort((a, b) {
      final time = a.createdAt.compareTo(b.createdAt);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
  // An already-open route may still hold the old thread object.
  other.messages = target.messages;
  target.profile = target.profile.copyWith(
    accountLogin: target.profile.accountLogin.isNotEmpty
        ? target.profile.accountLogin
        : other.profile.accountLogin,
    nodeAliases: {
      target.profile.nodeId,
      other.profile.nodeId,
      ...target.profile.nodeAliases,
      ...other.profile.nodeAliases,
    }.where((n) => n.isNotEmpty).toList(),
  );
  target.pinned = target.pinned || other.pinned;
  target.muted = target.muted || other.muted;
  if (target.draft.isEmpty) target.draft = other.draft;
  target.unread = target.unread > other.unread ? target.unread : other.unread;
  target.pinnedMessageIds.addAll(
    other.pinnedMessageIds.where((id) => !target.pinnedMessageIds.contains(id)),
  );
}

void consolidateDirectThreads(
  Map<String, ChatThread> threads, {
  Set<String> deletedMessageIds = const {},
}) {
  final identities = <String, ChatThread>{};
  for (final entry in threads.entries.toList()) {
    final thread = entry.value;
    if (!isOrdinaryDirectThread(thread)) continue;
    if (deletedMessageIds.isNotEmpty) {
      thread.messages.removeWhere(
        (message) => deletedMessageIds.contains(message.id),
      );
    }
    final login = thread.profile.accountLogin.trim().toLowerCase();
    final keys = [
      if (login.isNotEmpty) 'account:$login',
      for (final node in {thread.profile.nodeId, ...thread.profile.nodeAliases})
        if (node.isNotEmpty) 'node:$node',
    ];
    ChatThread? existing;
    for (final key in keys) {
      final candidate = identities[key];
      if (candidate != null &&
          sameDirectAccount(candidate.profile, thread.profile)) {
        existing = candidate;
        break;
      }
    }
    if (existing == null) {
      for (final key in keys) {
        identities[key] = thread;
      }
    } else if (!identical(existing, thread)) {
      mergeDirectHistory(
        existing,
        thread,
        deletedMessageIds: deletedMessageIds,
      );
      threads.remove(entry.key);
      for (final key in keys) {
        identities[key] = existing;
      }
    }
  }
}
