import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/app_database_path.dart';
import 'package:meshchat_mobile/src/services/file_transfer_outbox_store.dart';
import 'package:meshchat_mobile/src/services/file_transfer_payload_store.dart';
import 'package:meshchat_mobile/src/services/mesh_socket.dart';
import 'package:meshchat_mobile/src/services/mutation_outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDatabaseDirectoryOverrideForTesting =
        (await Directory.systemTemp.createTemp(
          'meshchat_socket_resilience_test_',
        )).path;
  });

  test('reconnect delay grows with a bounded exponential backoff', () {
    expect(MeshSocket.reconnectDelayForAttempt(0), const Duration(seconds: 1));
    expect(MeshSocket.reconnectDelayForAttempt(1), const Duration(seconds: 2));
    expect(MeshSocket.reconnectDelayForAttempt(4), const Duration(seconds: 16));
    expect(MeshSocket.reconnectDelayForAttempt(8), const Duration(seconds: 20));
    expect(
      MeshSocket.reconnectDelayForAttempt(0, jitter: 0.1),
      const Duration(milliseconds: 750),
    );
    expect(
      MeshSocket.reconnectDelayForAttempt(8, jitter: 3),
      const Duration(seconds: 25),
    );
  });

  test('one malformed frame does not block following packets', () async {
    final server = await _LocalWebSocketServer.start((socket, packet) {
      if (packet['type'] != 'server_hello') return;
      socket.add('{not-json');
      socket.add(jsonEncode(_welcomePacket()));
    });
    addTearDown(server.close);

    final welcome = Completer<void>();
    final socket = MeshSocket();
    addTearDown(socket.close);
    await socket.connect(
      session: _session(server.url, 'malformed'),
      publicKey: 'public-key',
      profile: _profile('malformed'),
      onPacket: (packet) {
        if (packet['type'] == 'server_welcome' && !welcome.isCompleted) {
          welcome.complete();
        }
      },
      onStatus: (_) {},
    );

    await welcome.future.timeout(const Duration(seconds: 2));
    expect(socket.isConnected, isTrue);
  });

  test(
    'recovery hints coalesce and ACK only the persisted sync cursor',
    () async {
      var requests = 0;
      final acknowledged = Completer<void>();
      final client = MeshSocket();
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          expect(packet['supports_reliable_sync_v2'], isTrue);
          socket.add(jsonEncode(_welcomePacket()));
          for (var i = 0; i < 3; i++) {
            socket.add(
              jsonEncode({'type': 'reliable_sync_hint', 'cursor': 10}),
            );
          }
        } else if (packet['type'] == 'reliable_sync_request') {
          requests++;
          expect(packet['cursor'], 0);
          socket.add(
            jsonEncode({'type': 'server_sync_done', 'sync_cursor': 10}),
          );
          socket.add(jsonEncode({'type': 'reliable_sync_hint', 'cursor': 10}));
        } else if (packet['type'] == 'sync_v2_ack') {
          expect(packet['cursor'], 10);
          if (!acknowledged.isCompleted) acknowledged.complete();
        }
      });
      addTearDown(server.close);
      addTearDown(client.close);
      await client.connect(
        session: _session(server.url, 'recovery-hint'),
        publicKey: 'public-key',
        profile: _profile('recovery-hint'),
        onStatus: (_) {},
        onPacket: (packet) async {
          if (packet['type'] == 'server_sync_done') {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            client.updateSyncCursor(10);
          }
        },
      );
      await acknowledged.future.timeout(const Duration(seconds: 2));
      expect(requests, 1);
    },
  );

  test('failed checkpoint never acknowledges the hinted cursor', () async {
    var acknowledgements = 0;
    final handled = Completer<void>();
    final client = MeshSocket();
    final server = await _LocalWebSocketServer.start((socket, packet) {
      if (packet['type'] == 'server_hello') {
        socket.add(jsonEncode(_welcomePacket()));
        socket.add(jsonEncode({'type': 'reliable_sync_hint', 'cursor': 10}));
      } else if (packet['type'] == 'reliable_sync_request') {
        socket.add(jsonEncode({'type': 'server_sync_done', 'sync_cursor': 10}));
        socket.add(jsonEncode({'type': 'reliable_sync_hint', 'cursor': 10}));
      } else if (packet['type'] == 'sync_v2_ack') {
        acknowledgements++;
      }
    });
    addTearDown(server.close);
    addTearDown(client.close);
    await client.connect(
      session: _session(server.url, 'recovery-failure'),
      publicKey: 'public-key',
      profile: _profile('recovery-failure'),
      onStatus: (_) {},
      onPacket: (packet) {
        if (packet['type'] == 'server_sync_done') {
          handled.complete();
          throw StateError('checkpoint failed');
        }
      },
    );
    await handled.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(acknowledgements, 0);
  });

  test(
    'retained delivery is applied once and acknowledged on every retry',
    () async {
      final deliveryId = List.filled(64, 'a').join();
      var acknowledgements = 0;
      var applications = 0;
      final received = Completer<void>();
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          expect(packet['supports_reliable_delivery_v1'], isTrue);
          socket.add(jsonEncode(_welcomePacket()));
          for (var i = 0; i < 3; i++) {
            socket.add(
              jsonEncode({
                'type': 'chat_message',
                '_delivery_id': deliveryId,
                'message': 'delivery test',
              }),
            );
          }
        } else if (packet['type'] == 'reliable_delivery_ack') {
          expect(packet['delivery_id'], deliveryId);
          if (++acknowledgements == 3) received.complete();
        }
      });
      addTearDown(server.close);
      final socket = MeshSocket();
      addTearDown(socket.close);
      await socket.connect(
        session: _session(server.url, 'retained'),
        publicKey: 'public-key',
        profile: _profile('retained'),
        onPacket: (packet) {
          if (packet['type'] == 'chat_message') applications++;
        },
        onStatus: (_) {},
      );
      await received.future.timeout(const Duration(seconds: 2));
      expect(applications, 1);
    },
  );

  test(
    'failed packet application is not acknowledged and can be retried',
    () async {
      final deliveryId = List.filled(64, 'b').join();
      var attempts = 0;
      var acknowledgements = 0;
      final received = Completer<void>();
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          socket.add(jsonEncode(_welcomePacket()));
          for (var i = 0; i < 2; i++) {
            socket.add(
              jsonEncode({'type': 'chat_message', '_delivery_id': deliveryId}),
            );
          }
        } else if (packet['type'] == 'reliable_delivery_ack') {
          acknowledgements++;
          if (!received.isCompleted) received.complete();
        }
      });
      addTearDown(server.close);
      final socket = MeshSocket();
      addTearDown(socket.close);
      await socket.connect(
        session: _session(server.url, 'retained-failure'),
        publicKey: 'public-key',
        profile: _profile('retained-failure'),
        onPacket: (packet) {
          if (packet['type'] == 'chat_message' && ++attempts == 1) {
            throw StateError('storage unavailable');
          }
        },
        onStatus: (_) {},
      );
      await received.future.timeout(const Duration(seconds: 2));
      expect(attempts, 2);
      expect(acknowledgements, 1);
    },
  );

  test(
    'pending durable write cannot send through a different account',
    () async {
      final received = <Map<String, dynamic>>[];
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          socket.add(jsonEncode(_welcomePacket()));
        } else if (packet['type'] == 'chat_message') {
          received.add(packet);
        }
      });
      addTearDown(server.close);
      final gate = Completer<void>();
      final store = _DelayedMutationOutboxStore(gate.future);
      final socket = MeshSocket(outboxStore: store);
      addTearDown(socket.close);
      final first = _session(server.url, 'switch-first');
      final second = _session(server.url, 'switch-second');
      Future<void> connect(Session session) async {
        final welcome = Completer<void>();
        await socket.connect(
          session: session,
          publicKey: 'public-key',
          profile: _profile(session.login),
          onPacket: (packet) {
            if (packet['type'] == 'server_welcome') welcome.complete();
          },
          onStatus: (_) {},
        );
        await welcome.future.timeout(const Duration(seconds: 2));
      }

      await connect(first);
      socket.send(_chatPacket(first, 'old-account-message'));
      await store.started.future.timeout(const Duration(seconds: 2));
      await connect(second);
      gate.complete();
      await _waitUntilAsync(
        () async => (await store.load(first)).isNotEmpty,
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
      expect(await store.load(second), isEmpty);
      expect(
        (await store.load(first)).single.state,
        MutationOutboxState.queued,
      );
    },
  );

  test('a socket without welcome is closed and reconnected', () async {
    final server = await _LocalWebSocketServer.start((_, _) {});
    addTearDown(server.close);

    final statuses = <String>[];
    final socket = MeshSocket(
      welcomeTimeout: const Duration(milliseconds: 30),
      reconnectDelayFactory: (_) => const Duration(milliseconds: 10),
    );
    addTearDown(socket.close);
    await socket.connect(
      session: _session(server.url, 'timeout'),
      publicKey: 'public-key',
      profile: _profile('timeout'),
      onPacket: (_) {},
      onStatus: statuses.add,
    );

    await _waitUntil(
      () => server.connectionCount >= 2,
      timeout: const Duration(seconds: 2),
    );
    expect(statuses, contains('Connection timeout'));
    expect(statuses.where((status) => status == 'Connecting...').length, 2);
  });

  test(
    'disk write failure is visible and never sends an untracked message',
    () async {
      var messagePackets = 0;
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          socket.add(jsonEncode(_welcomePacket()));
        } else if (packet['type'] == 'chat_message') {
          messagePackets++;
        }
      });
      addTearDown(server.close);
      final socket = MeshSocket(outboxStore: _FailingMutationOutboxStore());
      addTearDown(socket.close);
      final session = _session(server.url, 'disk-full');
      final welcome = Completer<void>();
      final failure = Completer<Map<String, dynamic>>();
      await socket.connect(
        session: session,
        publicKey: 'public-key',
        profile: _profile('disk-full'),
        onPacket: (packet) {
          if (packet['type'] == 'server_welcome') welcome.complete();
          if (packet['type'] == 'mutation_ack') failure.complete(packet);
        },
        onStatus: (_) {},
      );
      await welcome.future.timeout(const Duration(seconds: 2));
      socket.send(_chatPacket(session, 'disk-full-message'));
      final result = await failure.future.timeout(const Duration(seconds: 2));
      expect(result['ok'], isFalse);
      expect(result['operation_complete'], isTrue);
      expect(result['reason'], 'local_outbox_unavailable');
      expect(messagePackets, 0);
    },
  );

  test('file upload window does not grow without acknowledgements', () async {
    var chunks = 0;
    final server = await _LocalWebSocketServer.start((socket, packet) {
      if (packet['type'] == 'server_hello') {
        socket.add(jsonEncode(_welcomePacket()));
      } else if (packet['type'] == 'file_chunk') {
        chunks++;
      }
    });
    addTearDown(server.close);
    final store = FileTransferOutboxStore(
      databaseName: 'file_window_test.db',
      payloadStore: _MemoryFileTransferPayloadStore(),
    );
    final socket = MeshSocket(fileTransferStore: store);
    addTearDown(socket.close);
    final session = _session(server.url, 'window');
    final welcome = Completer<void>();
    await socket.connect(
      session: session,
      publicKey: 'public-key',
      profile: _profile('window'),
      onPacket: (packet) {
        if (packet['type'] == 'server_welcome') welcome.complete();
      },
      onStatus: (_) {},
    );
    await welcome.future.timeout(const Duration(seconds: 2));
    await socket.queueFileTransfer(
      transferId: 'window-transfer',
      operationId: 'file_transfer:window-file',
      bytes: Uint8List(MeshSocket.fileTransferChunkBytes * 6),
      packet: {
        'type': 'file_chunk',
        'file_id': 'window-file',
        'source_node': session.nodeId,
        'destination_node': 'peer-node',
      },
    );
    await _waitUntil(() => chunks >= 4, timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await socket.flushFileTransfers();
    await socket.flushFileTransfers();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(chunks, 4);
  });

  test(
    'file read finishing after account switch cannot use the new socket',
    () async {
      var chunks = 0;
      final server = await _LocalWebSocketServer.start((socket, packet) {
        if (packet['type'] == 'server_hello') {
          socket.add(jsonEncode(_welcomePacket()));
        }
        if (packet['type'] == 'file_chunk') chunks++;
      });
      addTearDown(server.close);
      final payloads = _DelayedFileTransferPayloadStore();
      final store = FileTransferOutboxStore(
        databaseName: 'file_account_switch.db',
        payloadStore: payloads,
      );
      final socket = MeshSocket(fileTransferStore: store);
      addTearDown(socket.close);
      final first = _session(server.url, 'file-switch-first');
      final second = _session(server.url, 'file-switch-second');
      Future<void> connect(Session session) async {
        final welcome = Completer<void>();
        await socket.connect(
          session: session,
          publicKey: 'public-key',
          profile: _profile(session.login),
          onPacket: (packet) {
            if (packet['type'] == 'server_welcome') welcome.complete();
          },
          onStatus: (_) {},
        );
        await welcome.future.timeout(const Duration(seconds: 2));
      }

      await connect(first);
      final sending = socket.queueFileTransfer(
        transferId: 'old-transfer',
        operationId: 'file_transfer:old-file',
        bytes: Uint8List(1024),
        packet: {
          'type': 'file_chunk',
          'file_id': 'old-file',
          'source_node': first.nodeId,
          'destination_node': 'peer-node',
        },
      );
      await payloads.started.future.timeout(const Duration(seconds: 2));
      await connect(second);
      payloads.gate.complete();
      await sending.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(chunks, 0);
      expect(await store.load(second), isEmpty);
      expect((await store.load(first)).single.isComplete, isFalse);
    },
  );

  test(
    'accepted mutation is reconciled after restart without duplicate send',
    () async {
      final processed = <String>{};
      var messagePackets = 0;
      var hellos = 0;
      final server = await _LocalWebSocketServer.start((socket, packet) {
        switch (packet['type']) {
          case 'server_hello':
            hellos++;
            socket.add(jsonEncode(_welcomePacket(reconcile: hellos >= 2)));
          case 'chat_message':
            messagePackets++;
            processed.add(packet['outbox_id']?.toString() ?? '');
          case 'mutation_status_request':
            final ids = (packet['outbox_ids'] as List? ?? const [])
                .map((value) => value.toString())
                .where(processed.contains)
                .toList();
            socket.add(
              jsonEncode({
                'type': 'mutation_status_result',
                'request_id': packet['request_id'],
                'processed_outbox_ids': ids,
              }),
            );
        }
      });
      addTearDown(server.close);

      final session = _session(server.url, 'reconciled');
      final firstWelcome = Completer<void>();
      final first = MeshSocket();
      await first.connect(
        session: session,
        publicKey: 'public-key',
        profile: _profile('reconciled'),
        onPacket: (packet) {
          if (packet['type'] == 'server_welcome' && !firstWelcome.isCompleted) {
            firstWelcome.complete();
          }
        },
        onStatus: (_) {},
      );
      await firstWelcome.future.timeout(const Duration(seconds: 2));
      first.send(_chatPacket(session, 'reconciled-message'));
      await _waitUntil(
        () => messagePackets == 1,
        timeout: const Duration(seconds: 2),
      );
      await first.close();
      await _waitUntilAsync(
        () async => (await MutationOutboxStore().load(session)).isNotEmpty,
        timeout: const Duration(seconds: 2),
      );

      final reconciledAck = Completer<Map<String, dynamic>>();
      final second = MeshSocket();
      addTearDown(second.close);
      await second.connect(
        session: session,
        publicKey: 'public-key',
        profile: _profile('reconciled'),
        onPacket: (packet) {
          if (packet['type'] == 'mutation_ack' &&
              packet['reconciled'] == true &&
              !reconciledAck.isCompleted) {
            reconciledAck.complete(packet);
          }
        },
        onStatus: (_) {},
      );

      final ack = await reconciledAck.future.timeout(
        const Duration(seconds: 2),
      );
      expect(ack['operation_complete'], isTrue);
      expect(messagePackets, 1);
      expect(await MutationOutboxStore().load(session), isEmpty);
    },
  );

  test(
    'unknown mutation is replayed after restart and waits for ack',
    () async {
      var messagePackets = 0;
      var hellos = 0;
      final server = await _LocalWebSocketServer.start((socket, packet) {
        switch (packet['type']) {
          case 'server_hello':
            hellos++;
            socket.add(jsonEncode(_welcomePacket(reconcile: hellos >= 2)));
          case 'mutation_status_request':
            socket.add(
              jsonEncode({
                'type': 'mutation_status_result',
                'request_id': packet['request_id'],
                'processed_outbox_ids': const <String>[],
              }),
            );
          case 'chat_message':
            messagePackets++;
            if (messagePackets >= 2) {
              socket.add(
                jsonEncode({
                  'type': 'mutation_ack',
                  'ok': true,
                  'outbox_id': packet['outbox_id'],
                  'operation_id': packet['operation_id'],
                  'packet_type': packet['type'],
                  'packet_id': packet['packet_id'],
                }),
              );
            }
        }
      });
      addTearDown(server.close);

      final session = _session(server.url, 'replayed');
      final firstWelcome = Completer<void>();
      final first = MeshSocket();
      await first.connect(
        session: session,
        publicKey: 'public-key',
        profile: _profile('replayed'),
        onPacket: (packet) {
          if (packet['type'] == 'server_welcome' && !firstWelcome.isCompleted) {
            firstWelcome.complete();
          }
        },
        onStatus: (_) {},
      );
      await firstWelcome.future.timeout(const Duration(seconds: 2));
      first.send(_chatPacket(session, 'replayed-message'));
      await _waitUntil(
        () => messagePackets == 1,
        timeout: const Duration(seconds: 2),
      );
      await first.close();

      final replayedAck = Completer<Map<String, dynamic>>();
      final second = MeshSocket();
      addTearDown(second.close);
      await second.connect(
        session: session,
        publicKey: 'public-key',
        profile: _profile('replayed'),
        onPacket: (packet) {
          if (packet['type'] == 'mutation_ack' && !replayedAck.isCompleted) {
            replayedAck.complete(packet);
          }
        },
        onStatus: (_) {},
      );

      final ack = await replayedAck.future.timeout(const Duration(seconds: 2));
      expect(ack['operation_complete'], isTrue);
      expect(messagePackets, 2);
      expect(await MutationOutboxStore().load(session), isEmpty);
    },
  );

  test('lost ack is retried while the same connection stays open', () async {
    var messagePackets = 0;
    final server = await _LocalWebSocketServer.start((socket, packet) {
      switch (packet['type']) {
        case 'server_hello':
          socket.add(jsonEncode(_welcomePacket()));
        case 'chat_message':
          messagePackets++;
          if (messagePackets == 2) {
            socket.add(
              jsonEncode({
                'type': 'mutation_ack',
                'ok': true,
                'outbox_id': packet['outbox_id'],
                'operation_id': packet['operation_id'],
                'packet_type': packet['type'],
                'packet_id': packet['packet_id'],
              }),
            );
          }
      }
    });
    addTearDown(server.close);

    final session = _session(server.url, 'same-connection-retry');
    final welcome = Completer<void>();
    final ack = Completer<Map<String, dynamic>>();
    final socket = MeshSocket();
    addTearDown(socket.close);
    await socket.connect(
      session: session,
      publicKey: 'public-key',
      profile: _profile('same-connection-retry'),
      onPacket: (packet) {
        if (packet['type'] == 'server_welcome' && !welcome.isCompleted) {
          welcome.complete();
        }
        if (packet['type'] == 'mutation_ack' && !ack.isCompleted) {
          ack.complete(packet);
        }
      },
      onStatus: (_) {},
    );
    await welcome.future.timeout(const Duration(seconds: 2));
    socket.send(_chatPacket(session, 'same-connection-message'));

    final result = await ack.future.timeout(const Duration(seconds: 5));
    expect(result['operation_complete'], isTrue);
    expect(messagePackets, 2);
    expect(await MutationOutboxStore().load(session), isEmpty);
  });

  test('durable mutation is persisted before its socket write', () async {
    var messagePackets = 0;
    final server = await _LocalWebSocketServer.start((socket, packet) {
      switch (packet['type']) {
        case 'server_hello':
          socket.add(jsonEncode(_welcomePacket()));
        case 'chat_message':
          messagePackets++;
          socket.add(
            jsonEncode({
              'type': 'mutation_ack',
              'ok': true,
              'outbox_id': packet['outbox_id'],
              'operation_id': packet['operation_id'],
              'packet_type': packet['type'],
              'packet_id': packet['packet_id'],
            }),
          );
      }
    });
    addTearDown(server.close);

    final persistenceGate = Completer<void>();
    final store = _DelayedMutationOutboxStore(persistenceGate.future);
    final session = _session(server.url, 'persist-before-send');
    final welcome = Completer<void>();
    final ack = Completer<void>();
    final socket = MeshSocket(outboxStore: store);
    addTearDown(socket.close);
    await socket.connect(
      session: session,
      publicKey: 'public-key',
      profile: _profile('persist-before-send'),
      onPacket: (packet) {
        if (packet['type'] == 'server_welcome' && !welcome.isCompleted) {
          welcome.complete();
        }
        if (packet['type'] == 'mutation_ack' && !ack.isCompleted) {
          ack.complete();
        }
      },
      onStatus: (_) {},
    );
    await welcome.future.timeout(const Duration(seconds: 2));

    socket.send(_chatPacket(session, 'persist-before-send-message'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(messagePackets, 0);

    persistenceGate.complete();
    await ack.future.timeout(const Duration(seconds: 2));
    expect(messagePackets, 1);
    expect(await store.load(session), isEmpty);
  });

  test('file transfer resumes after disconnect before chunk ack', () async {
    var fileChunks = 0;
    final server = await _LocalWebSocketServer.start((socket, packet) {
      switch (packet['type']) {
        case 'server_hello':
          socket.add(jsonEncode(_welcomePacket()));
        case 'file_chunk':
          fileChunks++;
          if (fileChunks == 1) {
            unawaited(socket.close());
            return;
          }
          socket.add(
            jsonEncode({
              'type': 'file_chunk_ack',
              'ok': true,
              'transfer_id': packet['transfer_id'],
              'operation_id': packet['operation_id'],
              'file_id': packet['file_id'],
              'chunk_index': packet['chunk_index'],
              'complete': true,
            }),
          );
      }
    });
    addTearDown(server.close);

    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final session = _session(server.url, 'file-resume-$suffix');
    final payloadStore = _MemoryFileTransferPayloadStore();
    final fileStore = FileTransferOutboxStore(
      databaseName: 'socket_file_resume_$suffix.db',
      payloadStore: payloadStore,
    );
    final complete = Completer<void>();
    final welcome = Completer<void>();
    final socket = MeshSocket(
      fileTransferStore: fileStore,
      reconnectDelayFactory: (_) => const Duration(milliseconds: 10),
    );
    addTearDown(socket.close);
    await socket.connect(
      session: session,
      publicKey: 'public-key',
      profile: _profile('file-resume-$suffix'),
      onPacket: (packet) {
        if (packet['type'] == 'server_welcome' && !welcome.isCompleted) {
          welcome.complete();
        }
        if (packet['type'] == 'file_transfer_progress' &&
            packet['complete'] == true &&
            !complete.isCompleted) {
          complete.complete();
        }
      },
      onStatus: (_) {},
    );
    await welcome.future.timeout(const Duration(seconds: 2));

    await socket.queueFileTransfer(
      transferId: 'transfer-$suffix',
      operationId: 'file_transfer:file-$suffix',
      bytes: Uint8List.fromList(List<int>.generate(4096, (i) => i % 251)),
      packet: {
        'type': 'file_chunk',
        'file_id': 'file-$suffix',
        'filename': 'resume.bin',
        'source_node': session.nodeId,
        'destination_node': 'peer-node',
      },
    );

    await complete.future.timeout(const Duration(seconds: 3));
    expect(fileChunks, 2);
    await _waitUntilAsync(
      () async => (await fileStore.load(session)).isEmpty,
      timeout: const Duration(seconds: 2),
    );
    expect(await fileStore.load(session), isEmpty);
    expect(payloadStore.payloads, isEmpty);
  });
}

Map<String, dynamic> _welcomePacket({bool reconcile = false}) => {
  'type': 'server_welcome',
  'protocol_version': MeshSocket.protocolVersion,
  'min_protocol_version': MeshSocket.minProtocolVersion,
  'capabilities': {
    'mutation_ack': true,
    'mutation_reconcile': reconcile,
    'file_transfer_v2': true,
    'media_delivery_v2': true,
    'sync_v2_delta': true,
    'multi_device_state': true,
  },
};

Map<String, dynamic> _chatPacket(Session session, String messageId) => {
  'type': 'chat_message',
  'packet_id': messageId,
  'source_node': session.nodeId,
  'destination_node': 'peer-node',
  'message': 'ciphertext',
};

Session _session(String serverUrl, String suffix) => Session(
  serverUrl: serverUrl,
  serverToken: 'token',
  login: 'user-$suffix',
  password: 'password',
  publicUsername: 'user-$suffix',
  nodeId: 'node-$suffix',
);

Profile _profile(String suffix) => Profile(
  nodeId: 'node-$suffix',
  displayName: 'User $suffix',
  publicUsername: 'user-$suffix',
);

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitUntilAsync(
  Future<bool> Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _LocalWebSocketServer {
  _LocalWebSocketServer._(this._server, this._onPacket);

  final HttpServer _server;
  final void Function(WebSocket socket, Map<String, dynamic> packet) _onPacket;
  final List<WebSocket> _sockets = <WebSocket>[];
  late final StreamSubscription<HttpRequest> _subscription;

  int connectionCount = 0;
  String get url =>
      'ws://${InternetAddress.loopbackIPv4.address}:${_server.port}';

  static Future<_LocalWebSocketServer> start(
    void Function(WebSocket socket, Map<String, dynamic> packet) onPacket,
  ) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _LocalWebSocketServer._(http, onPacket);
    server._subscription = http.listen(server._handleRequest);
    return server;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    connectionCount++;
    _sockets.add(socket);
    socket.listen((raw) {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map) {
        _onPacket(socket, Map<String, dynamic>.from(decoded));
      }
    });
  }

  Future<void> close() async {
    await _subscription.cancel();
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

class _DelayedMutationOutboxStore extends MutationOutboxStore {
  _DelayedMutationOutboxStore(this.gate);

  final Future<void> gate;
  final started = Completer<void>();

  @override
  Future<void> put(Session session, MutationOutboxEntry entry) async {
    if (!started.isCompleted) started.complete();
    await gate;
    await super.put(session, entry);
  }
}

class _FailingMutationOutboxStore extends MutationOutboxStore {
  @override
  Future<void> put(Session session, MutationOutboxEntry entry) async {
    throw const FileSystemException('No space left');
  }
}

class _MemoryFileTransferPayloadStore extends FileTransferPayloadStore {
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

class _DelayedFileTransferPayloadStore extends _MemoryFileTransferPayloadStore {
  final started = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<Uint8List> readChunk(String reference, int offset, int length) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return super.readChunk(reference, offset, length);
  }
}
