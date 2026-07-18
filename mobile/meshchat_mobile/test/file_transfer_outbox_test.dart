import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/app_database_path.dart';
import 'package:meshchat_mobile/src/services/file_transfer_outbox_store.dart';
import 'package:meshchat_mobile/src/services/file_transfer_payload_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MemoryFileTransferPayloadStore extends FileTransferPayloadStore {
  final Map<String, Uint8List> payloads = <String, Uint8List>{};

  @override
  Future<String> write(
    String sessionKey,
    String transferId,
    Uint8List bytes,
  ) async {
    final reference = '$sessionKey|$transferId';
    payloads[reference] = Uint8List.fromList(bytes);
    return reference;
  }

  @override
  Future<Uint8List> readChunk(String reference, int offset, int length) async {
    final bytes = payloads[reference];
    if (bytes == null || offset < 0 || offset >= bytes.length || length <= 0) {
      return Uint8List(0);
    }
    final end = (offset + length).clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset, end));
  }

  @override
  Future<bool> exists(String reference) async =>
      payloads.containsKey(reference);

  @override
  Future<void> delete(String reference) async {
    payloads.remove(reference);
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDatabaseDirectoryOverrideForTesting =
        (await Directory.systemTemp.createTemp(
          'meshchat_file_outbox_test_',
        )).path;
  });

  test(
    'file payload and acknowledged chunks survive store recreation',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final session = Session(
        serverUrl: 'wss://file-outbox-$suffix.example/ws',
        serverToken: 'token',
        login: 'file-user-$suffix',
        password: 'password',
        publicUsername: 'file-user-$suffix',
        nodeId: 'node-$suffix',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(150000, (index) => (index * 17) % 251),
      );
      final databaseName = 'file_transfer_test_$suffix.db';
      final payloadStore = MemoryFileTransferPayloadStore();
      final writer = FileTransferOutboxStore(
        databaseName: databaseName,
        payloadStore: payloadStore,
      );
      final created = await writer.create(
        session,
        transferId: 'transfer-$suffix',
        operationId: 'file_transfer:file-$suffix',
        fileId: 'file-$suffix',
        destinationNode: 'peer-a',
        packet: {
          'type': 'file_chunk',
          'file_id': 'file-$suffix',
          'filename': 'payload.bin',
          'destination_node': 'peer-a',
        },
        bytes: bytes,
        chunkSize: 64 * 1024,
      );

      expect(created.totalChunks, 3);
      expect(created.sha256, hasLength(64));
      expect(await writer.readChunk(created, 0), bytes.sublist(0, 64 * 1024));
      expect(await writer.readChunk(created, 2), bytes.sublist(2 * 64 * 1024));

      await writer.acknowledge(session, created.transferId, const [0, 2]);
      final reader = FileTransferOutboxStore(
        databaseName: databaseName,
        payloadStore: payloadStore,
      );
      var restored = await reader.get(session, created.transferId);
      expect(restored, isNotNull);
      expect(restored!.acknowledgedChunks, {0, 2});
      expect(restored.progress, closeTo(2 / 3, 0.0001));
      expect(await reader.payloadExists(restored), isTrue);

      await reader.resetAcknowledgements(session, created.transferId);
      restored = await reader.get(session, created.transferId);
      expect(restored!.acknowledgedChunks, isEmpty);
      expect(restored.status, 'queued');

      await reader.deleteOperation(session, created.operationId);
      expect(await reader.load(session), isEmpty);
      expect(await reader.payloadExists(restored), isFalse);
    },
  );

  test(
    'fanout entries share one payload until the operation completes',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final session = Session(
        serverUrl: 'wss://group-file-$suffix.example/ws',
        serverToken: 'token',
        login: 'group-user-$suffix',
        password: 'password',
        publicUsername: 'group-user-$suffix',
        nodeId: 'node-$suffix',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(70000, (index) => index % 256),
      );
      final operationId = 'file_transfer:group-file-$suffix';
      final store = FileTransferOutboxStore(
        databaseName: 'group_file_transfer_test_$suffix.db',
        payloadStore: MemoryFileTransferPayloadStore(),
      );

      final first = await store.create(
        session,
        transferId: 'transfer-a-$suffix',
        operationId: operationId,
        fileId: 'group-file-$suffix',
        destinationNode: 'member-a',
        packet: {
          'type': 'file_chunk',
          'file_id': 'group-file-$suffix',
          'filename': 'group.bin',
          'destination_node': 'member-a',
        },
        bytes: bytes,
        chunkSize: 64 * 1024,
      );
      final second = await store.create(
        session,
        transferId: 'transfer-b-$suffix',
        operationId: operationId,
        fileId: 'group-file-$suffix',
        destinationNode: 'member-b',
        packet: {
          'type': 'file_chunk',
          'file_id': 'group-file-$suffix',
          'filename': 'group.bin',
          'destination_node': 'member-b',
        },
        bytes: bytes,
        chunkSize: 64 * 1024,
      );

      expect(first.payloadReference, second.payloadReference);
      await store.acknowledge(
        session,
        first.transferId,
        const <int>[],
        complete: true,
      );
      expect(await store.operationComplete(session, operationId), isFalse);
      expect(await store.payloadExists(first), isTrue);
      await store.acknowledge(
        session,
        second.transferId,
        const <int>[],
        complete: true,
      );
      expect(await store.operationComplete(session, operationId), isTrue);

      await store.deleteOperation(session, operationId);
      expect(await store.load(session), isEmpty);
      expect(await store.payloadExists(first), isFalse);
    },
  );

  test('deleting one fanout entry keeps the shared payload', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final session = Session(
      serverUrl: 'wss://fanout-delete-$suffix.example/ws',
      serverToken: 'token',
      login: 'fanout-user-$suffix',
      password: 'password',
      publicUsername: 'fanout-user-$suffix',
      nodeId: 'node-$suffix',
    );
    final bytes = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
    final operationId = 'file_transfer:fanout-delete-$suffix';
    final payloadStore = MemoryFileTransferPayloadStore();
    final store = FileTransferOutboxStore(
      databaseName: 'fanout_delete_test_$suffix.db',
      payloadStore: payloadStore,
    );

    Future<FileTransferOutboxEntry> create(String transferId, String peer) =>
        store.create(
          session,
          transferId: transferId,
          operationId: operationId,
          fileId: 'fanout-file-$suffix',
          destinationNode: peer,
          packet: {
            'type': 'file_chunk',
            'file_id': 'fanout-file-$suffix',
            'filename': 'shared.bin',
            'destination_node': peer,
          },
          bytes: bytes,
          chunkSize: 64 * 1024,
        );

    final first = await create('fanout-a-$suffix', 'peer-a');
    final second = await create('fanout-b-$suffix', 'peer-b');
    expect(first.payloadReference, second.payloadReference);

    await store.delete(session, first.transferId);
    expect(await store.get(session, first.transferId), isNull);
    expect(await store.get(session, second.transferId), isNotNull);
    expect(await store.payloadExists(second), isTrue);

    await store.delete(session, second.transferId);
    expect(await store.payloadExists(second), isFalse);
  });
}
