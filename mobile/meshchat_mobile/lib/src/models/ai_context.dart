import 'dart:convert';
import 'chat_message.dart';

const aiContextFeatures = {
  'search': 'ai_person_memory',
  'plan': 'ai_chat_summary',
  'reply': 'ai_smart_replies',
  'document': 'ai_person_memory',
  'style': 'ai_text_rewrite',
  'notes': 'ai_call_summary',
};

String aiMessageText(ChatMessage message) => [
  message.text,
  if (message.fileName.isNotEmpty) '[Attachment: ${message.fileName}]',
  if (message.transcription.isNotEmpty) '[Transcript] ${message.transcription}',
  if (message.ocrText.isNotEmpty) '[OCR] ${message.ocrText}',
].where((text) => text.trim().isNotEmpty).join('\n');

List<Map<String, dynamic>> aiMessageSources(
  List<ChatMessage> messages, {
  String? targetId,
}) => [
  for (final message in messages)
    if (!message.deleted && aiMessageText(message).isNotEmpty)
      {
        'id': message.id,
        'sender': message.senderName.isEmpty
            ? message.senderNode
            : message.senderName,
        'date': message.createdAt.toUtc().toIso8601String(),
        'text': aiMessageText(message),
        'target': message.id == targetId,
      },
];

class AiContextResult {
  AiContextResult(this.data);
  factory AiContextResult.decode(String value) =>
      AiContextResult(Map<String, dynamic>.from(jsonDecode(value) as Map));
  final Map<String, dynamic> data;
  String get answer => data['answer']?.toString() ?? '';
  List<String> get sourceIds =>
      (data['source_ids'] as List? ?? []).whereType<String>().toList();
  List<String> get replies =>
      (data['replies'] as List? ?? []).whereType<String>().toList();
  List<Map<String, dynamic>> get items => (data['items'] as List? ?? [])
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  List<Map<String, dynamic>> get sources => (data['sources'] as List? ?? [])
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
}
