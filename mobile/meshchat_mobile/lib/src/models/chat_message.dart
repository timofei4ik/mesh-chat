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
    this.transcription = '',
    this.transcriptionLanguage = '',
    this.transcriptionDurationSeconds = 0,
    this.ocrText = '',
    this.ocrLanguage = '',
    this.ocrProcessed = false,
    this.replyToMessageId = '',
    this.replyToText = '',
    this.isChannelComment = false,
    this.messageEffect = 'none',
    Map<String, int>? reactions,
    Map<String, List<String>>? reactionActors,
    this.edited = false,
    this.deleted = false,
    this.pending = false,
    this.delivered = false,
    this.failed = false,
    this.progress = 0,
  }) : reactions = reactions ?? const {},
       reactionActors = reactionActors ?? const {};

  final String id;
  final String senderNode;
  final String receiverNode;
  final String text;
  final DateTime createdAt;
  final ChatMessageKind kind;
  final String fileName;
  final String fileData;
  final int fileSize;
  final String transcription;
  final String transcriptionLanguage;
  final double transcriptionDurationSeconds;
  final String ocrText;
  final String ocrLanguage;
  final bool ocrProcessed;
  final String replyToMessageId;
  final String replyToText;
  final bool isChannelComment;
  final String messageEffect;
  final Map<String, int> reactions;
  final Map<String, List<String>> reactionActors;
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
    String? transcription,
    String? transcriptionLanguage,
    double? transcriptionDurationSeconds,
    String? ocrText,
    String? ocrLanguage,
    bool? ocrProcessed,
    String? replyToMessageId,
    String? replyToText,
    bool? isChannelComment,
    String? messageEffect,
    bool? pending,
    bool? delivered,
    bool? failed,
    double? progress,
    Map<String, int>? reactions,
    Map<String, List<String>>? reactionActors,
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
      transcription: transcription ?? this.transcription,
      transcriptionLanguage:
          transcriptionLanguage ?? this.transcriptionLanguage,
      transcriptionDurationSeconds:
          transcriptionDurationSeconds ?? this.transcriptionDurationSeconds,
      ocrText: ocrText ?? this.ocrText,
      ocrLanguage: ocrLanguage ?? this.ocrLanguage,
      ocrProcessed: ocrProcessed ?? this.ocrProcessed,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToText: replyToText ?? this.replyToText,
      isChannelComment: isChannelComment ?? this.isChannelComment,
      messageEffect: _normalizeMessageEffect(
        messageEffect ?? this.messageEffect,
      ),
      reactions: reactions ?? this.reactions,
      reactionActors: reactionActors ?? this.reactionActors,
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
      transcription: json['transcription']?.toString() ?? '',
      transcriptionLanguage: json['transcription_language']?.toString() ?? '',
      transcriptionDurationSeconds:
          double.tryParse(
            json['transcription_duration_seconds']?.toString() ?? '',
          ) ??
          0,
      ocrText: json['ocr_text']?.toString() ?? '',
      ocrLanguage: json['ocr_language']?.toString() ?? '',
      ocrProcessed: json['ocr_processed'] == true,
      replyToMessageId: json['reply_to_message_id']?.toString() ?? '',
      replyToText: json['reply_to_text']?.toString() ?? '',
      isChannelComment: json['is_channel_comment'] == true,
      messageEffect: _normalizeMessageEffect(
        json['message_effect']?.toString() ?? 'none',
      ),
      reactions: _reactionsFromJson(json['reactions']),
      reactionActors: _reactionActorsFromJson(json['reaction_actors']),
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
      'transcription': transcription,
      'transcription_language': transcriptionLanguage,
      'transcription_duration_seconds': transcriptionDurationSeconds,
      'ocr_text': ocrText,
      'ocr_language': ocrLanguage,
      'ocr_processed': ocrProcessed,
      'reply_to_message_id': replyToMessageId,
      'reply_to_text': replyToText,
      'is_channel_comment': isChannelComment,
      'message_effect': messageEffect,
      'reactions': reactions,
      'reaction_actors': reactionActors,
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

  static Map<String, List<String>> _reactionActorsFromJson(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      if (entry.value is! List) continue;
      final actors = (entry.value as List)
          .map((value) => value.toString().trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (actors.isNotEmpty) result[entry.key.toString()] = actors;
    }
    return result;
  }

  static String _normalizeMessageEffect(String value) {
    const allowed = <String>{
      'none',
      'stardust',
      'ember',
      'sunset',
      'frost',
      'orbit',
    };
    final normalized = value.trim().toLowerCase();
    return allowed.contains(normalized) ? normalized : 'none';
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
