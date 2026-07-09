class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderNode,
    required this.receiverNode,
    required this.text,
    required this.createdAt,
    this.kind = ChatMessageKind.text,
    this.fileName = '',
    this.fileData = '',
    this.fileSize = 0,
    this.replyToMessageId = '',
    this.replyToText = '',
    Map<String, int>? reactions,
    this.edited = false,
    this.deleted = false,
    this.pending = false,
    this.delivered = false,
    this.failed = false,
    this.progress = 0,
  }) : reactions = reactions ?? const {};

  final String id;
  final String senderNode;
  final String receiverNode;
  final String text;
  final DateTime createdAt;
  final ChatMessageKind kind;
  final String fileName;
  final String fileData;
  final int fileSize;
  final String replyToMessageId;
  final String replyToText;
  final Map<String, int> reactions;
  final bool edited;
  final bool deleted;
  final bool pending;
  final bool delivered;
  final bool failed;
  final double progress;

  ChatMessage copyWith({
    String? text,
    ChatMessageKind? kind,
    String? fileName,
    String? fileData,
    int? fileSize,
    bool? pending,
    bool? delivered,
    bool? failed,
    double? progress,
    Map<String, int>? reactions,
    bool? edited,
    bool? deleted,
  }) {
    return ChatMessage(
      id: id,
      senderNode: senderNode,
      receiverNode: receiverNode,
      text: text ?? this.text,
      createdAt: createdAt,
      kind: kind ?? this.kind,
      fileName: fileName ?? this.fileName,
      fileData: fileData ?? this.fileData,
      fileSize: fileSize ?? this.fileSize,
      replyToMessageId: replyToMessageId,
      replyToText: replyToText,
      reactions: reactions ?? this.reactions,
      edited: edited ?? this.edited,
      deleted: deleted ?? this.deleted,
      pending: pending ?? this.pending,
      delivered: delivered ?? this.delivered,
      failed: failed ?? this.failed,
      progress: progress ?? this.progress,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final fileName = json['file_name']?.toString() ?? '';
    final fileData = json['file_data']?.toString() ?? '';
    final rawKind = json['kind']?.toString() ?? '';
    final kind = rawKind.isEmpty && (fileName.isNotEmpty || fileData.isNotEmpty)
        ? ChatMessageKind.file
        : ChatMessageKind.fromName(rawKind);
    return ChatMessage(
      id: json['id']?.toString() ?? '',
      senderNode: json['sender_node']?.toString() ?? '',
      receiverNode: json['receiver_node']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      kind: kind,
      fileName: fileName,
      fileData: fileData,
      fileSize: int.tryParse(json['file_size']?.toString() ?? '') ?? 0,
      replyToMessageId: json['reply_to_message_id']?.toString() ?? '',
      replyToText: json['reply_to_text']?.toString() ?? '',
      reactions: _reactionsFromJson(json['reactions']),
      edited: json['edited'] == true,
      deleted: json['deleted'] == true,
      pending: json['pending'] == true,
      delivered: json['delivered'] == true,
      failed: json['failed'] == true,
      progress: double.tryParse(json['progress']?.toString() ?? '') ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_node': senderNode,
      'receiver_node': receiverNode,
      'text': text,
      'created_at': createdAt.toUtc().toIso8601String(),
      'kind': kind.name,
      'file_name': fileName,
      'file_data': fileData,
      'file_size': fileSize,
      'reply_to_message_id': replyToMessageId,
      'reply_to_text': replyToText,
      'reactions': reactions,
      'edited': edited,
      'deleted': deleted,
      'pending': pending,
      'delivered': delivered,
      'failed': failed,
      'progress': progress,
    };
  }

  static Map<String, int> _reactionsFromJson(dynamic raw) {
    if (raw is! Map) return const {};
    return raw.map(
      (key, value) =>
          MapEntry(key.toString(), int.tryParse(value.toString()) ?? 0),
    )..removeWhere((_, count) => count <= 0);
  }
}

enum ChatMessageKind {
  text,
  file,
  sticker;

  static ChatMessageKind fromName(String value) {
    return ChatMessageKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => ChatMessageKind.text,
    );
  }
}
