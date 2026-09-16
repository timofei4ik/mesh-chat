import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_message.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/meshpro_subscription.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/mesh_socket.dart';

class _Socket extends MeshSocket {
  bool ready = false;
  final packets = <String>[];
  @override
  bool get isConnecting => !ready;
  @override
  bool get isConnected => ready;
  @override
  bool get isReady => ready;
  @override
  bool get supportsAiCompose => true;
  @override
  void send(Map<String, dynamic> packet) {
    packets.add(packet['type'] as String);
    // Stop at the transport boundary: these tests never call an AI provider.
    throw StateError('test transport boundary');
  }

  @override
  Future<void> sendAiMediaRequest(
    Map<String, dynamic> packet, {
    required String hex,
    required String field,
    required int limit,
  }) async => send(packet);
}

class _Controller extends AppController {
  _Controller(_Socket socket) : super(socket: socket);
  bool switchAccount = false;
  @override
  Future<MeshProSubscription> refreshMeshProSubscription() async {
    session = session!.copyWith(
      login: switchAccount ? 'other' : session!.login,
      serverToken: 'renewed',
    );
    return meshProSubscription = const MeshProSubscription(
      active: true,
      status: 'active',
      planCode: 'meshpro',
      entitlements: MeshProEntitlements(
        schemaVersion: 1,
        catalogVersion: 'test',
        active: true,
        features: {
          'ai_text_rewrite': true,
          'ai_message_translation': true,
          'ai_chat_summary': true,
          'ai_call_summary': true,
          'ai_voice_transcription': true,
          'ai_image_ocr': true,
          'ai_smart_replies': true,
          'ai_person_memory': true,
        },
        limits: {},
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final message = ChatMessage(
    id: 'photo',
    senderNode: 'peer',
    receiverNode: 'me',
    text: 'Hello',
    createdAt: DateTime(2026, 9, 16),
    fileData: 'ff',
    fileName: 'photo.png',
  );
  final actions = <String, Future<Object?> Function(_Controller)>{
    'ai_text_rewrite_request': (c) =>
        c.rewriteTextWithAi(text: 'Hello', style: 'short'),
    'ai_message_translation_request': (c) =>
        c.translateMessageWithAi(text: 'Hello', targetLanguage: 'ru'),
    'ai_chat_summary_request': (c) => c.summarizeMessagesWithAi([message]),
    'ai_call_summary_request': (c) => c.summarizeCallNotesWithAi('Call notes'),
    'ai_voice_transcription_request': (c) => c.transcribeVoiceWithAi(message),
    'ai_image_ocr_request': (c) => c.extractImageTextWithAi(message),
    'ai_smart_replies_request': (c) => c.suggestRepliesWithAi([message]),
    'ai_person_memory_request': (c) => c.askPersonMemoryWithAi(
      thread: ChatThread(
        profile: const Profile(nodeId: 'peer', displayName: 'Peer'),
        messages: [message],
      ),
      question: 'What did we discuss?',
    ),
    for (final mode in [
      'search',
      'plan',
      'reply',
      'document',
      'style',
      'compose',
      'notes',
    ])
      'context:$mode': (c) =>
          c.runContextAiTool({'mode': mode, 'text': 'Hello'}),
  };
  for (final entry in actions.entries) {
    for (final switchAccount in [false, true]) {
      test(
        '${entry.key} waits for connection and guards account ($switchAccount)',
        () async {
          final socket = _Socket();
          final controller = _Controller(socket)
            ..switchAccount = switchAccount
            ..session = const Session(
              serverUrl: 'wss://example.test',
              serverToken: 'token',
              login: 'me',
              password: 'password',
              publicUsername: 'me',
              nodeId: 'me',
            );
          Object? failure;
          final pending = () async {
            try {
              await entry.value(controller);
            } catch (error) {
              failure = error;
            }
          }();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(socket.packets, isEmpty);
          socket.ready = true;
          await pending;
          expect(failure, isNotNull);
          if (switchAccount) {
            expect(socket.packets, isEmpty);
            expect(failure.toString(), contains('Account changed'));
          } else {
            expect(socket.packets, [
              entry.key.startsWith('context:')
                  ? 'ai_context_tool_request'
                  : entry.key,
            ]);
            expect(failure.toString(), isNot(contains('Account changed')));
          }
        },
      );
    }
  }

  test('OCR stops waiting after logout without sending the image', () async {
    final socket = _Socket();
    final controller = _Controller(socket)
      ..session = const Session(
        serverUrl: 'wss://example.test',
        serverToken: 'token',
        login: 'me',
        password: 'password',
        publicUsername: 'me',
        nodeId: 'me',
      );
    final result = expectLater(
      controller.extractImageTextWithAi(message),
      throwsA(
        isA<AiOcrException>().having((e) => e.code, 'code', 'session_changed'),
      ),
    );
    controller.session = null;
    await result;
    expect(socket.packets, isEmpty);
  });

  test(
    'OCR reconnect wait has a deadline and does not send while offline',
    () async {
      final socket = _Socket();
      final controller = _Controller(socket)
        ..session = const Session(
          serverUrl: 'wss://example.test',
          serverToken: 'token',
          login: 'me',
          password: 'password',
          publicUsername: 'me',
          nodeId: 'me',
        );
      await expectLater(
        controller.extractImageTextWithAi(message),
        throwsA(isA<AiOcrException>().having((e) => e.code, 'code', 'offline')),
      );
      expect(socket.packets, isEmpty);
    },
  );
}
