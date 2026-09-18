import '../models/chat_message.dart';

enum MessageSearchKind { all, text, photo, video, audio, file, link }

class MessageSearchFilter {
  const MessageSearchFilter({
    this.query = '',
    this.sender,
    this.day,
    this.kind = MessageSearchKind.all,
  });
  final String query;
  final String? sender;
  final DateTime? day;
  final MessageSearchKind kind;

  bool matches(ChatMessage message) {
    if (message.deleted || (sender != null && sender != message.senderNode)) {
      return false;
    }
    final date = message.createdAt.toLocal();
    if (day != null &&
        (date.year != day!.year ||
            date.month != day!.month ||
            date.day != day!.day)) {
      return false;
    }
    final name = message.fileName.toLowerCase();
    bool extension(String pattern) => RegExp('\\.($pattern)\$').hasMatch(name);
    final photo = extension('png|jpe?g|gif|webp|bmp|heic');
    final video = extension('mp4|mov|webm|mkv|avi');
    final audio = extension('ogg|opus|mp3|m4a|wav|aac|flac');
    final matchesKind = switch (kind) {
      MessageSearchKind.all => true,
      MessageSearchKind.text => message.kind == ChatMessageKind.text,
      MessageSearchKind.photo => photo,
      MessageSearchKind.video => video,
      MessageSearchKind.audio => audio,
      MessageSearchKind.file =>
        message.kind == ChatMessageKind.file && !photo && !video && !audio,
      MessageSearchKind.link => RegExp(
        r'https?://',
        caseSensitive: false,
      ).hasMatch(message.text),
    };
    return matchesKind &&
        [
          message.text,
          message.fileName,
          message.replyToText,
          message.transcription,
          message.ocrText,
        ].join(' ').toLowerCase().contains(query.trim().toLowerCase());
  }
}
