import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';

void main() {
  test('voice transcription survives message cache round trip', () {
    final message = ChatMessage(
      id: 'voice-1',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: '',
      createdAt: DateTime.utc(2026, 7, 15),
      kind: ChatMessageKind.file,
      fileName: 'voice_12s.m4a',
      fileData: '00ff',
      fileSize: 2,
      transcription: 'Test transcript',
      transcriptionLanguage: 'en',
      transcriptionDurationSeconds: 12.4,
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.transcription, 'Test transcript');
    expect(restored.transcriptionLanguage, 'en');
    expect(restored.transcriptionDurationSeconds, 12.4);
  });

  test('copyWith can attach transcription without changing file data', () {
    final message = ChatMessage(
      id: 'voice-2',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: '',
      createdAt: DateTime.utc(2026, 7, 15),
      kind: ChatMessageKind.file,
      fileName: 'voice.m4a',
      fileData: 'aabb',
      fileSize: 2,
    );

    final updated = message.copyWith(
      transcription: 'Привет',
      transcriptionLanguage: 'ru',
      transcriptionDurationSeconds: 2.1,
    );

    expect(updated.fileData, message.fileData);
    expect(updated.transcription, 'Привет');
    expect(updated.transcriptionLanguage, 'ru');
    expect(updated.transcriptionDurationSeconds, 2.1);
  });

  test('OCR result survives message cache round trip', () {
    final message = ChatMessage(
      id: 'image-1',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: '',
      createdAt: DateTime.utc(2026, 7, 15),
      kind: ChatMessageKind.file,
      fileName: 'document.jpg',
      fileData: '00ff',
      fileSize: 2,
      ocrText: 'Document text',
      ocrLanguage: 'english',
      ocrProcessed: true,
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.ocrText, 'Document text');
    expect(restored.ocrLanguage, 'english');
    expect(restored.ocrProcessed, isTrue);
  });

  test('copyWith can mark OCR with no readable text as processed', () {
    final message = ChatMessage(
      id: 'image-2',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: '',
      createdAt: DateTime.utc(2026, 7, 15),
      kind: ChatMessageKind.file,
      fileName: 'photo.png',
      fileData: 'aabb',
      fileSize: 2,
    );

    final updated = message.copyWith(ocrText: '', ocrProcessed: true);

    expect(updated.fileData, message.fileData);
    expect(updated.ocrText, isEmpty);
    expect(updated.ocrProcessed, isTrue);
  });

  test('MeshPro message effect survives cache and rejects unknown values', () {
    final message = ChatMessage(
      id: 'effect-1',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: 'Hello',
      createdAt: DateTime.utc(2026, 7, 16),
      messageEffect: 'orbit',
    );

    expect(ChatMessage.fromJson(message.toJson()).messageEffect, 'orbit');
    expect(
      ChatMessage.fromJson({
        ...message.toJson(),
        'message_effect': 'unsafe',
      }).messageEffect,
      'none',
    );
    expect(message.copyWith(messageEffect: 'ember').messageEffect, 'ember');
  });

  test('channel comment identity survives cache and delivery updates', () {
    final comment = ChatMessage(
      id: 'comment-1',
      senderNode: 'member',
      receiverNode: 'channel-1',
      text: 'Comment',
      createdAt: DateTime.utc(2026, 7, 16),
      replyToMessageId: 'post-1',
      replyToText: 'Post',
      isChannelComment: true,
      pending: true,
    );

    final restored = ChatMessage.fromJson(comment.toJson());
    final delivered = restored.copyWith(
      pending: false,
      delivered: true,
      failed: false,
    );

    expect(delivered.id, 'comment-1');
    expect(delivered.replyToMessageId, 'post-1');
    expect(delivered.replyToText, 'Post');
    expect(delivered.isChannelComment, isTrue);
    expect(delivered.pending, isFalse);
    expect(delivered.delivered, isTrue);
  });

  test('reaction account identities survive cache round trip', () {
    final message = ChatMessage(
      id: 'reaction-1',
      senderNode: 'sender',
      receiverNode: 'receiver',
      text: 'Hello',
      createdAt: DateTime.utc(2026, 7, 18),
      reactions: const {'heart': 1},
      reactionActors: const {
        'heart': ['login:alice'],
      },
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.reactions, const {'heart': 1});
    expect(restored.reactionActors, const {
      'heart': ['login:alice'],
    });
  });

  test('group sender and read receipt survive cache round trip', () {
    final message = ChatMessage(
      id: 'group-status-1',
      senderNode: 'node-alice',
      receiverNode: 'group-1',
      senderName: 'Alice',
      text: 'Hello without an embedded sender prefix',
      createdAt: DateTime.utc(2026, 7, 18),
      delivered: true,
      read: true,
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.senderName, 'Alice');
    expect(restored.text, 'Hello without an embedded sender prefix');
    expect(restored.delivered, isTrue);
    expect(restored.read, isTrue);
  });
}
