import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
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
