import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/app_database_path.dart';
import 'package:meshchat_mobile/src/services/mesh_socket.dart';
import 'package:meshchat_mobile/src/services/mutation_outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDatabaseDirectoryOverrideForTesting =
        (await Directory.systemTemp.createTemp(
          'meshchat_mutation_outbox_test_',
        )).path;
  });

  test('durable packets get stable logical and destination ids', () {
    final first = {
      'type': 'group_message',
      'packet_id': 'message-1',
      'group_message_id': 'message-1',
      'destination_node': 'member-a',
    };
    final second = {...first, 'destination_node': 'member-b'};

    expect(MeshSocket.isDurableMutationPacket(first), isTrue);
    expect(
      MeshSocket.operationIdForPacket(first),
      MeshSocket.operationIdForPacket(second),
    );
    expect(
      MeshSocket.outboxIdForPacket(first),
      isNot(MeshSocket.outboxIdForPacket(second)),
    );
    expect(
      MeshSocket.outboxIdForPacket(first),
      MeshSocket.outboxIdForPacket(Map<String, dynamic>.from(first)),
    );
  });

  test(
    'explicit operation id groups fanout with destination-specific acks',
    () {
      final first = {
        'type': 'group_update',
        'packet_id': 'packet-a',
        'operation_id': 'group_update:logical-action',
        'destination_node': 'member-a',
      };
      final second = {
        ...first,
        'packet_id': 'packet-b',
        'destination_node': 'member-b',
      };

      expect(
        MeshSocket.operationIdForPacket(first),
        MeshSocket.operationIdForPacket(second),
      );
      expect(
        MeshSocket.outboxIdForPacket(first),
        isNot(MeshSocket.outboxIdForPacket(second)),
      );
    },
  );

  test('transient and large chunk packets stay outside mutation outbox', () {
    for (final type in ['typing', 'call_offer', 'call_ice', 'file_chunk']) {
      expect(
        MeshSocket.isDurableMutationPacket({
          'type': type,
          'packet_id': 'packet-1',
        }),
        isFalse,
        reason: type,
      );
    }
  });

  test('outbox entry round-trips without changing the packet', () {
    final createdAt = DateTime.utc(2026, 7, 17, 12, 30);
    final entry = MutationOutboxEntry(
      outboxId: 'chat_message:message-1|peer-a|',
      operationId: 'chat_message:message-1',
      packet: const {
        'type': 'chat_message',
        'packet_id': 'message-1',
        'destination_node': 'peer-a',
        'message': 'ciphertext',
      },
      createdAt: createdAt,
      attempts: 2,
    );

    final restored = MutationOutboxEntry.fromJson(entry.toJson());
    expect(restored.outboxId, entry.outboxId);
    expect(restored.operationId, entry.operationId);
    expect(restored.packet, entry.packet);
    expect(restored.createdAt, createdAt);
    expect(restored.attempts, 2);
  });

  test(
    'native outbox persists attempts and removes acknowledged entries',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final session = Session(
        serverUrl: 'wss://outbox-$suffix.example/ws',
        serverToken: 'token',
        login: 'outbox-user-$suffix',
        password: 'password',
        publicUsername: 'outbox-user-$suffix',
        nodeId: 'node-$suffix',
      );
      final entry = MutationOutboxEntry(
        outboxId: 'chat_message:message-$suffix|peer-a|',
        operationId: 'chat_message:message-$suffix',
        packet: {
          'type': 'chat_message',
          'packet_id': 'message-$suffix',
          'destination_node': 'peer-a',
          'message': 'ciphertext',
        },
        createdAt: DateTime.now().toUtc(),
      );

      final writer = MutationOutboxStore();
      await writer.put(session, entry);

      final reader = MutationOutboxStore();
      var restored = await reader.load(session);
      expect(restored, hasLength(1));
      expect(restored.single.outboxId, entry.outboxId);
      expect(restored.single.packet, entry.packet);
      expect(await reader.hasOperation(session, entry.operationId), isTrue);

      await reader.markAttempt(session, entry.outboxId);
      restored = await MutationOutboxStore().load(session);
      expect(restored.single.attempts, 1);

      await reader.delete(session, entry.outboxId);
      expect(await MutationOutboxStore().load(session), isEmpty);
      expect(await reader.hasOperation(session, entry.operationId), isFalse);
    },
  );
}
