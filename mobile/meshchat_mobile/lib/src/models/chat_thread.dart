import 'chat_message.dart';
import 'profile.dart';

class ChatThread {
  ChatThread({
    required this.profile,
    List<ChatMessage>? messages,
    this.isGroup = false,
    this.isChannel = false,
    this.groupId = '',
    this.groupName = '',
    List<String>? members,
    this.ownerNode = '',
    List<String>? admins,
    this.groupKeyId = '',
    this.groupKeyData = '',
    List<String>? pinnedMessageIds,
    this.draft = '',
    this.archived = false,
    this.pinned = false,
    this.muted = false,
  }) : messages = messages ?? [],
       members = members ?? [],
       admins = admins ?? [],
       pinnedMessageIds = pinnedMessageIds ?? [];

  Profile profile;
  final List<ChatMessage> messages;
  final bool isGroup;
  bool isChannel;
  final String groupId;
  final String groupName;
  final List<String> members;
  final String ownerNode;
  final List<String> admins;
  String groupKeyId;
  String groupKeyData;
  final List<String> pinnedMessageIds;
  String draft;
  bool archived;
  bool pinned;
  bool muted;
  int unread = 0;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  List<ChatMessage> get pinnedMessages {
    final result = <ChatMessage>[];
    for (final id in pinnedMessageIds) {
      for (final message in messages) {
        if (message.id == id) {
          result.add(message);
          break;
        }
      }
    }
    return result;
  }

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    final profileRaw = json['profile'];
    final messagesRaw = json['messages'];
    final membersRaw = json['members'];
    final adminsRaw = json['admins'];
    final pinsRaw = json['pinned_message_ids'];
    final isGroup = json['is_group'] == true;
    final isChannel = json['is_channel'] == true;
    final groupId = json['group_id']?.toString() ?? '';
    final groupName = json['group_name']?.toString() ?? '';
    final thread = ChatThread(
      profile: Profile.fromJson(
        profileRaw is Map ? Map<String, dynamic>.from(profileRaw) : const {},
      ),
      messages: messagesRaw is List
          ? messagesRaw
                .whereType<Map>()
                .map(
                  (raw) => ChatMessage.fromJson(Map<String, dynamic>.from(raw)),
                )
                .where((message) => message.id.isNotEmpty)
                .toList()
          : const [],
      isGroup: isGroup,
      isChannel: isChannel,
      groupId: groupId,
      groupName: groupName,
      members: membersRaw is List
          ? membersRaw.map((value) => value.toString()).toList()
          : const [],
      ownerNode: json['owner_node']?.toString() ?? '',
      admins: adminsRaw is List
          ? adminsRaw.map((value) => value.toString()).toList()
          : const [],
      groupKeyId: json['group_key_id']?.toString() ?? '',
      groupKeyData: json['group_key_data']?.toString() ?? '',
      pinnedMessageIds: pinsRaw is List
          ? pinsRaw.map((value) => value.toString()).toList()
          : const [],
      draft: json['draft']?.toString() ?? '',
      archived: json['archived'] == true,
      pinned: json['pinned'] == true,
      muted: json['muted'] == true,
    );
    thread.unread = int.tryParse(json['unread']?.toString() ?? '') ?? 0;
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return thread;
  }

  Map<String, dynamic> toJson() {
    return {
      'profile': profile.toJson(),
      'messages': messages.map((message) => message.toJson()).toList(),
      'is_group': isGroup,
      'is_channel': isChannel,
      'group_id': groupId,
      'group_name': groupName,
      'members': members,
      'owner_node': ownerNode,
      'admins': admins,
      'group_key_id': groupKeyId,
      'group_key_data': groupKeyData,
      'pinned_message_ids': pinnedMessageIds,
      'draft': draft,
      'archived': archived,
      'pinned': pinned,
      'muted': muted,
      'unread': unread,
    };
  }
}
