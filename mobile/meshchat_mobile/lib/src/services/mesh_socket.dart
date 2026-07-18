import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/profile.dart';
import '../models/session.dart';
import 'file_transfer_outbox_store.dart';
import 'mutation_outbox_store.dart';

typedef PacketHandler = FutureOr<void> Function(Map<String, dynamic> packet);
typedef StatusHandler = void Function(String status);

class MeshSocket {
  static const protocolVersion = 5;
  static const minProtocolVersion = 5;
  static const appVersion = '1.0.24';

  MeshSocket({
    MutationOutboxStore? outboxStore,
    FileTransferOutboxStore? fileTransferStore,
  }) : _outboxStore = outboxStore ?? MutationOutboxStore(),
       _fileTransferStore = fileTransferStore ?? FileTransferOutboxStore();

  static const fileTransferChunkBytes = 64 * 1024;
  static const _fileTransferWindow = 4;

  static const _durableMutationTypes = <String>{
    'chat_message',
    'group_message',
    'message_edit',
    'group_message_edit',
    'message_delete',
    'group_message_delete',
    'chat_delete',
    'group_delete',
    'message_pin',
    'group_pin',
    'message_reaction',
    'group_reaction',
    'group_update',
    'group_member_leave',
    'story_update',
    'story_reaction',
    'story_delete',
    'sticker_library_update',
  };

  final MutationOutboxStore _outboxStore;
  final FileTransferOutboxStore _fileTransferStore;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _closed = false;
  bool _connected = false;
  bool _serverCapabilitiesKnown = false;
  bool _supportsMutationAck = false;
  bool _supportsFileTransferV2 = false;
  bool _supportsSyncV2Delta = false;
  String _lastIdentityRecovery = '';
  bool _flushingOutbox = false;
  bool _flushingFileOutbox = false;
  int _syncCursor = 0;
  Session? _session;
  PacketHandler? _packetHandler;
  Future<void> _packetSerial = Future<void>.value();
  Future<void> _outboxSerial = Future<void>.value();
  Future<void> _fileOutboxSerial = Future<void>.value();
  final Map<String, Set<int>> _fileChunksInFlight = <String, Set<int>>{};
  Timer? _fileRetryTimer;

  bool get isConnected => _connected;
  bool get supportsMutationAck => _supportsMutationAck;
  bool get supportsFileTransferV2 => _supportsFileTransferV2;
  bool get supportsSyncV2Delta => _supportsSyncV2Delta;
  String get lastIdentityRecovery => _lastIdentityRecovery;

  Future<void> connect({
    required Session session,
    required String publicKey,
    required Profile profile,
    required PacketHandler onPacket,
    required StatusHandler onStatus,
    String deviceName = '',
    bool reactivateDevice = false,
    int syncCursor = 0,
  }) async {
    _closed = false;
    _session = session;
    _packetHandler = onPacket;
    _syncCursor = syncCursor < 0 ? 0 : syncCursor;
    _serverCapabilitiesKnown = false;
    _supportsMutationAck = false;
    _supportsFileTransferV2 = false;
    _supportsSyncV2Delta = false;
    _fileChunksInFlight.clear();
    _fileRetryTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();

    onStatus('Connecting...');
    final channel = WebSocketChannel.connect(Uri.parse(session.serverUrl));
    _channel = channel;
    await channel.ready.timeout(const Duration(seconds: 10));
    _connected = true;

    channel.sink.add(
      jsonEncode(
        _helloPacket(
          session,
          publicKey,
          profile,
          deviceName: deviceName,
          reactivateDevice: reactivateDevice,
        ),
      ),
    );

    _subscription = channel.stream.listen(
      (raw) async {
        final previousPacket = _packetSerial;
        final currentPacket = Completer<void>();
        _packetSerial = currentPacket.future;
        await previousPacket;
        try {
          final decoded = jsonDecode(raw.toString());
          if (decoded is Map<String, dynamic>) {
            final packetType = decoded['type']?.toString() ?? '';
            if (packetType == 'server_welcome') {
              _lastIdentityRecovery =
                  decoded['encryption_recovery']?.toString() ?? '';
              final rawCapabilities = decoded['capabilities'];
              final capabilities = rawCapabilities is Map
                  ? Map<String, dynamic>.from(rawCapabilities)
                  : const <String, dynamic>{};
              _serverCapabilitiesKnown = true;
              _supportsMutationAck = capabilities['mutation_ack'] == true;
              _supportsFileTransferV2 =
                  capabilities['file_transfer_v2'] == true;
              _supportsSyncV2Delta = capabilities['sync_v2_delta'] == true;
            }
            if (packetType == 'file_chunk_ack') {
              await _serializeFileOutbox(() => _consumeFileChunkAck(decoded));
            } else if (packetType == 'mutation_ack') {
              await _consumeMutationAck(decoded, onPacket);
            } else {
              await onPacket(decoded);
            }
            final queueId = decoded['_offline_queue_id'];
            if (queueId != null) {
              try {
                channel.sink.add(
                  jsonEncode({
                    'type': 'offline_packet_ack',
                    'source_node': session.nodeId,
                    'queue_id': queueId,
                    'protocol_version': protocolVersion,
                  }),
                );
              } catch (_) {
                // The retained packet will be delivered again after reconnect.
              }
            }
            if (packetType == 'server_welcome') {
              await _flushOutbox();
              await _flushFileOutbox();
            }
          }
        } finally {
          if (!currentPacket.isCompleted) currentPacket.complete();
        }
      },
      onError: (Object error) {
        _connected = false;
        _serverCapabilitiesKnown = false;
        _supportsMutationAck = false;
        _supportsFileTransferV2 = false;
        _supportsSyncV2Delta = false;
        _fileChunksInFlight.clear();
        _fileRetryTimer?.cancel();
        onStatus('Connection error');
        _scheduleReconnect(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
        );
      },
      onDone: () {
        _connected = false;
        _serverCapabilitiesKnown = false;
        _supportsMutationAck = false;
        _supportsFileTransferV2 = false;
        _fileChunksInFlight.clear();
        _fileRetryTimer?.cancel();
        onStatus('Offline');
        _scheduleReconnect(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
        );
      },
      cancelOnError: false,
    );
  }

  Future<String?> check(Session session, String publicKey) async {
    final result = await diagnose(session, publicKey);
    return result.ok ? null : result.message;
  }

  Future<ConnectionDiagnostics> diagnose(
    Session session,
    String publicKey,
  ) async {
    _lastIdentityRecovery = '';
    final channel = WebSocketChannel.connect(Uri.parse(session.serverUrl));
    final startedAt = DateTime.now();
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({
          ..._helloPacket(session, publicKey, null),
          'node_id': 'login-check-${session.login}',
          'auth_check': true,
        }),
      );
      final raw = await channel.stream.first.timeout(
        const Duration(seconds: 10),
      );
      final latency = DateTime.now().difference(startedAt);
      final packet = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (packet['type'] == 'server_error') {
        final message = packet['code'] == 'incompatible_protocol'
            ? protocolError(packet)
            : packet['message']?.toString() ??
                  packet['reason']?.toString() ??
                  'Server error';
        return ConnectionDiagnostics(
          ok: false,
          message: message,
          latency: latency,
          serverVersion: packet['server_version']?.toString() ?? 'unknown',
          serverProtocolRange: serverProtocolRange(packet),
        );
      }
      if (packet['type'] != 'server_welcome') {
        return ConnectionDiagnostics(
          ok: false,
          message: 'Unexpected server response',
          latency: latency,
        );
      }
      _lastIdentityRecovery = packet['encryption_recovery']?.toString() ?? '';
      if (!isProtocolCompatible(packet)) {
        return ConnectionDiagnostics(
          ok: false,
          message: protocolError(packet),
          latency: latency,
          serverVersion: packet['server_version']?.toString() ?? 'unknown',
          serverProtocolRange: serverProtocolRange(packet),
        );
      }
      return ConnectionDiagnostics(
        ok: true,
        message: 'Connection OK',
        latency: latency,
        serverVersion: packet['server_version']?.toString() ?? 'unknown',
        serverProtocolRange: serverProtocolRange(packet),
      );
    } catch (error) {
      return ConnectionDiagnostics(
        ok: false,
        message: 'Could not connect: $error',
        latency: DateTime.now().difference(startedAt),
      );
    } finally {
      await channel.sink.close();
    }
  }

  void send(Map<String, dynamic> packet) {
    if (isDurableMutationPacket(packet) && _session != null) {
      unawaited(_queueMutation(packet));
      return;
    }
    _sendRaw(packet);
  }

  Future<void> queueFileTransfer({
    required Map<String, dynamic> packet,
    required Uint8List bytes,
    required String transferId,
    required String operationId,
    bool deferSend = false,
  }) async {
    final current = _session;
    final fileId = packet['file_id']?.toString().trim() ?? '';
    final destination = packet['destination_node']?.toString().trim() ?? '';
    if (current == null ||
        fileId.isEmpty ||
        destination.isEmpty ||
        transferId.isEmpty ||
        operationId.isEmpty ||
        bytes.isEmpty) {
      throw ArgumentError('Invalid file transfer');
    }
    await _serializeFileOutbox(() async {
      await _fileTransferStore.create(
        current,
        transferId: transferId,
        operationId: operationId,
        fileId: fileId,
        destinationNode: destination,
        packet: {
          ...packet,
          'operation_id': operationId,
          'transfer_id': transferId,
        },
        bytes: bytes,
        chunkSize: fileTransferChunkBytes,
      );
    });
    await _emitFileProgress(
      fileId: fileId,
      operationId: operationId,
      progress: 0,
    );
    if (!deferSend) await _flushFileOutbox();
  }

  Future<void> flushFileTransfers() => _flushFileOutbox();

  Future<void> cancelFileTransfer(String fileId) async {
    final current = _session;
    if (current == null || fileId.isEmpty) return;
    await _serializeFileOutbox(() async {
      final entries = (await _fileTransferStore.load(
        current,
      )).where((entry) => entry.fileId == fileId).toList();
      for (final entry in entries) {
        if (_connected && _supportsFileTransferV2) {
          _sendRaw({
            'type': 'file_transfer_cancel',
            'protocol_version': protocolVersion,
            'source_node': current.nodeId,
            'destination_node': 'SERVER',
            'transfer_id': entry.transferId,
            'file_id': entry.fileId,
            'operation_id': entry.operationId,
          });
        }
        _fileChunksInFlight.remove(entry.transferId);
        await _fileTransferStore.delete(current, entry.transferId);
      }
    });
  }

  Future<void> retryFileTransfer(String fileId) async {
    final current = _session;
    if (current == null || fileId.isEmpty) return;
    await _serializeFileOutbox(() async {
      final entries = (await _fileTransferStore.load(
        current,
      )).where((entry) => entry.fileId == fileId).toList();
      for (final entry in entries) {
        await _fileTransferStore.resetAcknowledgements(
          current,
          entry.transferId,
        );
        _fileChunksInFlight.remove(entry.transferId);
      }
    });
    await _flushFileOutbox();
  }

  Future<bool> hasQueuedFileTransfer(String fileId) async {
    final current = _session;
    if (current == null || fileId.isEmpty) return false;
    return (await _fileTransferStore.load(
      current,
    )).any((entry) => entry.fileId == fileId && !entry.isComplete);
  }

  Future<void> _flushFileOutbox() async {
    final current = _session;
    if (current == null || !_connected || !_serverCapabilitiesKnown) return;
    if (_flushingFileOutbox) return;
    _flushingFileOutbox = true;
    try {
      final entries = await _fileTransferStore.load(current);
      for (final entry in entries) {
        if (!_connected || entry.isComplete || entry.isFailed) continue;
        if (!await _fileTransferStore.payloadExists(entry)) {
          await _fileTransferStore.markFailed(
            current,
            entry.transferId,
            'source_file_missing',
          );
          await _emitFileProgress(
            fileId: entry.fileId,
            operationId: entry.operationId,
            progress: entry.progress,
            failed: true,
            reason: 'source_file_missing',
          );
          continue;
        }
        if (!_supportsFileTransferV2) {
          await _sendLegacyFileTransfer(current, entry);
          continue;
        }
        final inFlight = _fileChunksInFlight.putIfAbsent(
          entry.transferId,
          () => <int>{},
        );
        final candidates = <int>[];
        for (var index = 0; index < entry.totalChunks; index++) {
          if (entry.acknowledgedChunks.contains(index) ||
              inFlight.contains(index)) {
            continue;
          }
          candidates.add(index);
          if (candidates.length + inFlight.length >= _fileTransferWindow) {
            break;
          }
        }
        if (candidates.isEmpty) continue;
        for (final index in candidates) {
          if (!_connected) break;
          final sent = await _sendFileTransferChunk(entry, index, v2: true);
          if (!sent) {
            await _fileTransferStore.markFailed(
              current,
              entry.transferId,
              'source_file_unreadable',
            );
            await _emitFileProgress(
              fileId: entry.fileId,
              operationId: entry.operationId,
              progress: entry.progress,
              failed: true,
              reason: 'source_file_unreadable',
            );
            break;
          }
          inFlight.add(index);
        }
        await _fileTransferStore.markAttempt(current, entry.transferId);
      }
      if (_supportsFileTransferV2 &&
          entries.any((entry) => !entry.isComplete && !entry.isFailed)) {
        _scheduleFileRetry();
      }
    } catch (_) {
      _scheduleFileRetry();
    } finally {
      _flushingFileOutbox = false;
    }
  }

  Future<void> _sendLegacyFileTransfer(
    Session current,
    FileTransferOutboxEntry entry,
  ) async {
    for (var index = 0; index < entry.totalChunks; index++) {
      if (!_connected) return;
      if (!await _sendFileTransferChunk(entry, index, v2: false)) {
        await _fileTransferStore.markFailed(
          current,
          entry.transferId,
          'source_file_unreadable',
        );
        return;
      }
      await _emitFileProgress(
        fileId: entry.fileId,
        operationId: entry.operationId,
        progress: (index + 1) / entry.totalChunks,
      );
    }
    await _fileTransferStore.acknowledge(
      current,
      entry.transferId,
      const <int>[],
      complete: true,
    );
    final operationComplete = await _fileTransferStore.operationComplete(
      current,
      entry.operationId,
    );
    await _emitFileProgress(
      fileId: entry.fileId,
      operationId: entry.operationId,
      progress: 1,
      complete: operationComplete,
    );
    if (operationComplete) {
      await _fileTransferStore.deleteOperation(current, entry.operationId);
    }
  }

  Future<bool> _sendFileTransferChunk(
    FileTransferOutboxEntry entry,
    int index, {
    required bool v2,
  }) async {
    final bytes = await _fileTransferStore.readChunk(entry, index);
    if (bytes.isEmpty) return false;
    _sendRaw({
      ...entry.packet,
      'type': 'file_chunk',
      'packet_id': '${entry.transferId}:$index',
      'transfer_id': entry.transferId,
      'operation_id': entry.operationId,
      'chunk_index': index,
      'total_chunks': entry.totalChunks,
      'data': _hexEncode(bytes),
      if (v2) ...{
        'file_transfer_v2': true,
        'file_sha256': entry.sha256,
        'file_size': entry.sizeBytes,
        'chunk_size_bytes': entry.chunkSize,
      },
    });
    return true;
  }

  Future<void> _consumeFileChunkAck(Map<String, dynamic> packet) async {
    final current = _session;
    final handler = _packetHandler;
    final transferId = packet['transfer_id']?.toString() ?? '';
    if (current == null || transferId.isEmpty) {
      if (handler != null) await handler(packet);
      return;
    }
    final entry = await _fileTransferStore.get(current, transferId);
    if (entry == null) return;
    final ok = packet['ok'] != false;
    final retryable = packet['retryable'] == true;
    final reset = packet['reset'] == true;
    final reason = packet['reason']?.toString() ?? '';
    if (!ok) {
      _fileChunksInFlight.remove(transferId);
      if (reset) {
        await _fileTransferStore.resetAcknowledgements(current, transferId);
      } else if (!retryable) {
        await _fileTransferStore.markFailed(current, transferId, reason);
      }
      await _emitFileProgress(
        fileId: entry.fileId,
        operationId: entry.operationId,
        progress: reset ? 0 : entry.progress,
        failed: !retryable,
        reason: reason,
      );
      if (retryable) _scheduleFileRetry();
      return;
    }

    final acknowledged = _acknowledgedIndexes(packet, entry.totalChunks);
    final complete = packet['complete'] == true;
    await _fileTransferStore.acknowledge(
      current,
      transferId,
      acknowledged,
      complete: complete,
    );
    final inFlight = _fileChunksInFlight[transferId];
    inFlight?.removeAll(acknowledged);
    if (complete) _fileChunksInFlight.remove(transferId);
    final progress = await _fileTransferStore.operationProgress(
      current,
      entry.operationId,
    );
    final operationComplete = await _fileTransferStore.operationComplete(
      current,
      entry.operationId,
    );
    await _emitFileProgress(
      fileId: entry.fileId,
      operationId: entry.operationId,
      progress: progress,
      complete: operationComplete,
    );
    if (operationComplete) {
      await _fileTransferStore.deleteOperation(current, entry.operationId);
      final hasPendingTransfer = (await _fileTransferStore.load(
        current,
        includeComplete: false,
      )).any((candidate) => !candidate.isFailed);
      if (hasPendingTransfer) {
        await _flushFileOutbox();
      } else {
        _fileRetryTimer?.cancel();
      }
    } else {
      await _flushFileOutbox();
    }
  }

  Set<int> _acknowledgedIndexes(Map<String, dynamic> packet, int totalChunks) {
    final result = <int>{};
    final chunkIndex = _asInt(packet['chunk_index']);
    if (chunkIndex != null && chunkIndex >= 0 && chunkIndex < totalChunks) {
      result.add(chunkIndex);
    }
    final ranges = packet['received_ranges'];
    if (ranges is List) {
      for (final rawRange in ranges) {
        if (rawRange is! List || rawRange.length < 2) continue;
        final start = _asInt(rawRange[0]);
        final end = _asInt(rawRange[1]);
        if (start == null || end == null || end < start) continue;
        for (var index = start; index <= end && index < totalChunks; index++) {
          if (index >= 0) result.add(index);
        }
      }
    }
    return result;
  }

  Future<void> _emitFileProgress({
    required String fileId,
    required String operationId,
    required double progress,
    bool complete = false,
    bool failed = false,
    String reason = '',
  }) async {
    final handler = _packetHandler;
    if (handler == null) return;
    await handler({
      'type': 'file_transfer_progress',
      'file_id': fileId,
      'operation_id': operationId,
      'progress': progress.clamp(0.0, 1.0),
      'complete': complete,
      'failed': failed,
      if (reason.isNotEmpty) 'reason': reason,
    });
  }

  void _scheduleFileRetry() {
    if (_closed || !_connected) return;
    _fileRetryTimer?.cancel();
    _fileRetryTimer = Timer(const Duration(seconds: 4), () {
      _fileChunksInFlight.clear();
      unawaited(_flushFileOutbox());
    });
  }

  Future<void> _serializeFileOutbox(Future<void> Function() action) {
    final result = _fileOutboxSerial.then((_) => action());
    _fileOutboxSerial = result.catchError((Object _) {});
    return result;
  }

  static String _hexEncode(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static bool isDurableMutationPacket(Map<String, dynamic> packet) =>
      _durableMutationTypes.contains(packet['type']?.toString() ?? '');

  static String operationIdForPacket(Map<String, dynamic> packet) {
    final explicit = packet['operation_id']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final packetType = packet['type']?.toString().trim() ?? '';
    final primaryId =
        [
              packet['packet_id'],
              packet['group_message_id'],
              packet['message_id'],
              packet['story_id'],
              packet['group_id'],
            ]
            .map((value) => value?.toString().trim() ?? '')
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (packetType.isEmpty || primaryId.isEmpty) return '';
    return '$packetType:$primaryId';
  }

  static String outboxIdForPacket(Map<String, dynamic> packet) {
    final explicit = packet['outbox_id']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final operationId = operationIdForPacket(packet);
    if (operationId.isEmpty) return '';
    final destination = packet['destination_node']?.toString().trim() ?? '';
    final chunk = packet['chunk_index']?.toString().trim() ?? '';
    return '$operationId|$destination|$chunk';
  }

  Future<void> _queueMutation(Map<String, dynamic> originalPacket) async {
    final current = _session;
    if (current == null) {
      _sendRaw(originalPacket);
      return;
    }
    final packet = Map<String, dynamic>.from(originalPacket);
    final operationId = operationIdForPacket(packet);
    final outboxId = outboxIdForPacket(packet);
    if (operationId.isEmpty || outboxId.isEmpty) {
      _sendRaw(packet);
      return;
    }
    packet['operation_id'] = operationId;
    packet['outbox_id'] = outboxId;
    final entry = MutationOutboxEntry(
      outboxId: outboxId,
      operationId: operationId,
      packet: packet,
      createdAt: DateTime.now().toUtc(),
    );
    try {
      await _serializeOutbox(() async {
        await _outboxStore.put(current, entry);
        if (!_connected || !_serverCapabilitiesKnown) return;
        _sendRaw(packet);
        if (_supportsMutationAck) {
          await _outboxStore.markAttempt(current, outboxId);
        } else {
          await _outboxStore.delete(current, outboxId);
        }
      });
    } catch (_) {
      // Storage failure must not turn a user action into an app-level crash.
      try {
        if (_connected) _sendRaw(packet);
      } catch (_) {}
    }
  }

  Future<void> _flushOutbox() async {
    final current = _session;
    if (current == null || !_connected || !_serverCapabilitiesKnown) return;
    if (_flushingOutbox) return;
    _flushingOutbox = true;
    try {
      await _serializeOutbox(() async {
        final entries = await _outboxStore.load(current);
        for (final entry in entries) {
          if (!_connected) break;
          _sendRaw(entry.packet);
          if (_supportsMutationAck) {
            await _outboxStore.markAttempt(current, entry.outboxId);
          } else {
            await _outboxStore.delete(current, entry.outboxId);
          }
        }
      });
    } catch (_) {
      // Entries remain persisted and will be retried on the next reconnect.
    } finally {
      _flushingOutbox = false;
    }
  }

  Future<void> _consumeMutationAck(
    Map<String, dynamic> packet,
    PacketHandler onPacket,
  ) async {
    final current = _session;
    final outboxId = packet['outbox_id']?.toString() ?? '';
    final operationId = packet['operation_id']?.toString() ?? '';
    var operationComplete = true;
    if (current != null && outboxId.isNotEmpty) {
      try {
        await _serializeOutbox(() async {
          await _outboxStore.delete(current, outboxId);
          operationComplete = !await _outboxStore.hasOperation(
            current,
            operationId,
          );
        });
      } catch (_) {
        operationComplete = false;
      }
    }
    await onPacket({...packet, 'operation_complete': operationComplete});
  }

  Future<void> _serializeOutbox(Future<void> Function() action) {
    final result = _outboxSerial.then((_) => action());
    _outboxSerial = result.catchError((Object _) {});
    return result;
  }

  void _sendRaw(Map<String, dynamic> packet) {
    _channel?.sink.add(jsonEncode(packet));
  }

  Map<String, dynamic> _helloPacket(
    Session session,
    String publicKey,
    Profile? profile, {
    String deviceName = '',
    bool reactivateDevice = false,
  }) {
    final displayName = profile?.displayName.trim().isNotEmpty == true
        ? profile!.displayName
        : session.login;
    return {
      'type': 'server_hello',
      'node_id': session.nodeId,
      'username': session.login,
      'server_token': session.serverToken,
      'login': session.login,
      'password': session.password,
      'display_name': displayName,
      'public_username': session.publicUsername,
      'about': profile?.about,
      'avatar_data': profile?.avatarData,
      'encryption_public_key': publicKey,
      'app_version': appVersion,
      'device_name': deviceName,
      'reactivate_device': reactivateDevice,
      'supports_sticker_library_chunks': true,
      'supports_sync_v2': true,
      'supports_sync_v2_delta': true,
      'sync_cursor': _syncCursor,
      'supports_offline_packet_ack': true,
      'supports_mutation_ack': true,
      'supports_file_transfer_v2': true,
      'supports_account_live_fanout': true,
      'protocol_version': protocolVersion,
      'min_protocol_version': minProtocolVersion,
    };
  }

  static bool isProtocolCompatible(Map<String, dynamic> packet) {
    final serverProtocol = _asInt(packet['protocol_version']);
    final serverMinProtocol = _asInt(
      packet['min_protocol_version'] ?? packet['protocol_min_version'],
    );
    if (serverProtocol == null) return true;
    final serverMin = serverMinProtocol ?? serverProtocol;
    return serverMin <= protocolVersion && serverProtocol >= minProtocolVersion;
  }

  static String protocolRange() {
    return '$minProtocolVersion..$protocolVersion';
  }

  static String serverProtocolRange(Map<String, dynamic> packet) {
    final serverProtocol = packet['protocol_version']?.toString() ?? '?';
    final serverMin =
        packet['min_protocol_version']?.toString() ??
        packet['protocol_min_version']?.toString() ??
        serverProtocol;
    return '$serverMin..$serverProtocol';
  }

  static String protocolError(Map<String, dynamic> packet) {
    return 'Incompatible protocol: client ${protocolRange()}, server ${serverProtocolRange(packet)}. Update MeshChat.';
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void updateSyncCursor(int cursor) {
    if (cursor > _syncCursor) {
      _syncCursor = cursor;
    }
  }

  void _scheduleReconnect(
    Session session,
    String publicKey,
    Profile profile,
    PacketHandler onPacket,
    StatusHandler onStatus,
    String deviceName,
  ) {
    if (_closed || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      connect(
        session: session,
        publicKey: publicKey,
        profile: profile,
        onPacket: onPacket,
        onStatus: onStatus,
        deviceName: deviceName,
        reactivateDevice: false,
        syncCursor: _syncCursor,
      ).catchError((_) {
        _scheduleReconnect(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
        );
      });
    });
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _connected = false;
    _serverCapabilitiesKnown = false;
    _supportsMutationAck = false;
    _supportsFileTransferV2 = false;
    _fileChunksInFlight.clear();
    _fileRetryTimer?.cancel();
    _session = null;
    _packetHandler = null;
  }
}

class ConnectionDiagnostics {
  const ConnectionDiagnostics({
    required this.ok,
    required this.message,
    required this.latency,
    this.serverVersion = 'unknown',
    this.serverProtocolRange = '?',
  });

  final bool ok;
  final String message;
  final Duration latency;
  final String serverVersion;
  final String serverProtocolRange;
}
