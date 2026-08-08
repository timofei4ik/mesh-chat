DateTime parseMessageCreatedAt(
  Map<String, dynamic> json, {
  required DateTime fallback,
}) {
  for (final key in const [
    'created_at',
    'createdAt',
    'timestamp',
    'sent_at',
    'sentAt',
    'server_timestamp',
    'sync_event_created_at',
    'time',
    'date',
  ]) {
    final value = json[key];
    if (value == null) continue;
    if (value is num) {
      var milliseconds = value.toDouble();
      if (milliseconds.abs() < 100000000000) milliseconds *= 1000;
      if (milliseconds.isFinite) {
        return DateTime.fromMillisecondsSinceEpoch(
          milliseconds.round(),
          isUtc: true,
        );
      }
      continue;
    }

    final raw = value.toString().trim();
    if (raw.isEmpty) continue;
    final numeric = num.tryParse(raw);
    if (numeric != null) {
      var milliseconds = numeric.toDouble();
      if (milliseconds.abs() < 100000000000) milliseconds *= 1000;
      if (milliseconds.isFinite) {
        return DateTime.fromMillisecondsSinceEpoch(
          milliseconds.round(),
          isUtc: true,
        );
      }
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) continue;
    final hasExplicitZone =
        raw.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(raw);
    if (raw.contains(' ') && !raw.contains('T') && !hasExplicitZone) {
      return DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
        parsed.microsecond,
      );
    }
    return parsed;
  }
  return fallback;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderNode,
    required this.receiverNode,
    required this.text,
    required this.createdAt,
    this.senderName = '',
    this.kind = ChatMessageKind.text,
    this.fileName = '',
    this.fileData = '',
    this.fileSize = 0,
    this.mediaId = '',
    this.mediaSha256 = '',
    this.mediaKeyId = '',
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
    this.read = false,
    this.failed = false,
    this.progress = 0,
  }) : reactions = reactions ?? const {},
       reactionActors = reactionActors ?? const {};

  final String id;
  final String senderNode;
  final String receiverNode;
  final String text;
  final DateTime createdAt;
  final String senderName;
  final ChatMessageKind kind;
  final String fileName;
  final String fileData;
  final int fileSize;
  final String mediaId;
  final String mediaSha256;
  final String mediaKeyId;
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
  final bool read;
  final bool failed;
  final double progress;

  ChatMessage copyWith({
    String? text,
    String? senderName,
    ChatMessageKind? kind,
    String? fileName,
    String? fileData,
    int? fileSize,
    String? mediaId,
    String? mediaSha256,
    String? mediaKeyId,
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
    bool? read,
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
      senderName: senderName ?? this.senderName,
      createdAt: createdAt,
      kind: kind ?? this.kind,
      fileName: fileName ?? this.fileName,
      fileData: fileData ?? this.fileData,
      fileSize: fileSize ?? this.fileSize,
      mediaId: mediaId ?? this.mediaId,
      mediaSha256: mediaSha256 ?? this.mediaSha256,
      mediaKeyId: mediaKeyId ?? this.mediaKeyId,
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
      read: read ?? this.read,
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
      senderName: json['sender_name']?.toString() ?? '',
      createdAt: parseMessageCreatedAt(
        json,
        fallback: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
      kind: kind,
      fileName: fileName,
      fileData: fileData,
      fileSize: int.tryParse(json['file_size']?.toString() ?? '') ?? 0,
      mediaId: json['media_id']?.toString() ?? '',
      mediaSha256: json['media_sha256']?.toString() ?? '',
      mediaKeyId: json['media_key_id']?.toString() ?? '',
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
      read: json['read'] == true,
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
      'sender_name': senderName,
      'created_at': createdAt.toUtc().toIso8601String(),
      'kind': kind.name,
      'file_name': fileName,
      'file_data': fileData,
      'file_size': fileSize,
      'media_id': mediaId,
      'media_sha256': mediaSha256,
      'media_key_id': mediaKeyId,
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
      'read': read,
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
