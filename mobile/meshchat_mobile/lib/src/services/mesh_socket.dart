import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/profile.dart';
import '../models/session.dart';
import 'file_transfer_outbox_store.dart';
import 'mutation_outbox_store.dart';

typedef PacketHandler = FutureOr<void> Function(Map<String, dynamic> packet);
typedef StatusHandler = void Function(String status);
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);
typedef ReconnectDelayFactory = Duration Function(int attempt);
typedef DeliveryTraceHandler =
    FutureOr<void> Function(Map<String, dynamic> trace);

class MeshSocket {
  static const protocolVersion = 5;
  static const minProtocolVersion = 5;
  static const appVersion = '1.0.94';

  MeshSocket({
    MutationOutboxStore? outboxStore,
    FileTransferOutboxStore? fileTransferStore,
    WebSocketChannelFactory? channelFactory,
    Random? reconnectRandom,
    this.welcomeTimeout = const Duration(seconds: 15),
    this.reconnectDelayFactory,
  }) : _outboxStore = outboxStore ?? MutationOutboxStore(),
       _fileTransferStore = fileTransferStore ?? FileTransferOutboxStore(),
       _channelFactory = channelFactory ?? WebSocketChannel.connect,
       _reconnectRandom = reconnectRandom ?? Random();

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
  final WebSocketChannelFactory _channelFactory;
  final Random _reconnectRandom;
  final Duration welcomeTimeout;
  final ReconnectDelayFactory? reconnectDelayFactory;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _welcomeTimer;
  bool _closed = false;
  bool _connected = false;
  bool _serverCapabilitiesKnown = false;
  bool _supportsMutationAck = false;
  bool _supportsMutationReconcile = false;
  bool _supportsFileTransferV2 = false;
  bool _supportsMediaDeliveryV2 = false;
  bool _supportsSyncV2Delta = false;
  bool _supportsSyncV2DeltaBatch = false;
  bool _supportsMultiDeviceState = false;
  String _lastIdentityRecovery = '';
  bool _flushingOutbox = false;
  bool _flushingFileOutbox = false;
  int _syncCursor = 0;
  Session? _session;
  PacketHandler? _packetHandler;
  DeliveryTraceHandler? _deliveryTraceHandler;
  Future<void> _packetSerial = Future<void>.value();
  Future<void> _outboxSerial = Future<void>.value();
  Future<void> _fileOutboxSerial = Future<void>.value();
  Future<void> _startupRecovery = Future<void>.value();
  final Map<String, Set<int>> _fileChunksInFlight = <String, Set<int>>{};
  Timer? _fileRetryTimer;
  Timer? _mutationRetryTimer;
  int _mutationRetryArm = 0;
  final Map<String, Completer<Set<String>>> _mutationStatusRequests = {};
  int _connectionGeneration = 0;
  int _reconnectAttempt = 0;
  String _deliverySessionKey = '';
  final Set<String> _processedDeliveries = <String>{};
  DateTime? _reliableSyncRequestedAt;

  bool get isConnected => _connected;
  bool get supportsMutationAck => _supportsMutationAck;
  bool get supportsMutationReconcile => _supportsMutationReconcile;
  bool get supportsFileTransferV2 => _supportsFileTransferV2;
  bool get supportsMediaDeliveryV2 => _supportsMediaDeliveryV2;
  bool get supportsSyncV2Delta => _supportsSyncV2Delta;
  bool get supportsSyncV2DeltaBatch => _supportsSyncV2DeltaBatch;
  bool get supportsMultiDeviceState => _supportsMultiDeviceState;
  String get lastIdentityRecovery => _lastIdentityRecovery;

  Future<MutationOutboxStats> mutationOutboxStats() async {
    final current = _session;
    if (current == null) return MutationOutboxStats.empty;
    late MutationOutboxStats result;
    await _serializeOutbox(() async {
      result = await _outboxStore.stats(current);
    });
    return result;
  }

  Future<void> connect({
    required Session session,
    required String publicKey,
    required Profile profile,
    required PacketHandler onPacket,
    required StatusHandler onStatus,
    DeliveryTraceHandler? onDeliveryTrace,
    String deviceName = '',
    bool reactivateDevice = false,
    int syncCursor = 0,
  }) async {
    final generation = ++_connectionGeneration;
    _closed = false;
    _connected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    final deliverySessionKey = MutationOutboxStore.sessionKey(session);
    if (_deliverySessionKey != deliverySessionKey) {
      _processedDeliveries.clear();
      _deliverySessionKey = deliverySessionKey;
    }
    _session = session;
    _reliableSyncRequestedAt = null;
    _packetHandler = onPacket;
    _deliveryTraceHandler = onDeliveryTrace;
    _syncCursor = syncCursor < 0 ? 0 : syncCursor;
    _serverCapabilitiesKnown = false;
    _supportsMutationAck = false;
    _supportsMutationReconcile = false;
    _supportsFileTransferV2 = false;
    _supportsMediaDeliveryV2 = false;
    _supportsSyncV2Delta = false;
    _supportsSyncV2DeltaBatch = false;
    _supportsMultiDeviceState = false;
    _startupRecovery = Future<void>.value();
    _fileChunksInFlight.clear();
    _fileRetryTimer?.cancel();
    _mutationRetryTimer?.cancel();
    _mutationRetryArm++;
    _completeMutationStatusRequests();
    final previousSubscription = _subscription;
    final previousChannel = _channel;
    _subscription = null;
    _channel = null;
    await previousSubscription?.cancel();
    await previousChannel?.sink.close();
    if (!_isCurrentGeneration(generation)) return;
    _packetSerial = Future<void>.value();

    onStatus('Connecting...');
    final channel = _channelFactory(Uri.parse(session.serverUrl));
    _channel = channel;
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
    } catch (_) {
      if (_isCurrentConnection(generation, channel)) {
        _connected = false;
      }
      rethrow;
    }
    if (!_isCurrentConnection(generation, channel)) {
      await channel.sink.close();
      return;
    }
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
    _welcomeTimer = Timer(welcomeTimeout, () {
      if (!_isCurrentConnection(generation, channel) ||
          _serverCapabilitiesKnown) {
        return;
      }
      onStatus('Connection timeout');
      unawaited(channel.sink.close());
    });

    _subscription = channel.stream.listen(
      (raw) async {
        if (!_isCurrentConnection(generation, channel)) return;
        final previousPacket = _packetSerial;
        final currentPacket = Completer<void>();
        _packetSerial = currentPacket.future;
        await previousPacket;
        if (!_isCurrentConnection(generation, channel)) {
          if (!currentPacket.isCompleted) currentPacket.complete();
          return;
        }
        try {
          final decoded = jsonDecode(raw.toString());
          if (decoded is Map<String, dynamic>) {
            final packetType = decoded['type']?.toString() ?? '';
            if (packetType == 'reliable_sync_hint') {
              final target = decoded['cursor'];
              if (target is! int || target <= 0) return;
              if (_syncCursor >= target) {
                channel.sink.add(
                  jsonEncode({
                    'type': 'sync_v2_ack',
                    'cursor': _syncCursor,
                    'source_node': session.nodeId,
                    'protocol_version': protocolVersion,
                  }),
                );
              } else {
                final requested = _reliableSyncRequestedAt;
                final now = DateTime.now();
                if (requested == null ||
                    now.difference(requested).inSeconds >= 30) {
                  _reliableSyncRequestedAt = now;
                  channel.sink.add(
                    jsonEncode({
                      'type': 'reliable_sync_request',
                      'cursor': _syncCursor,
                      'source_node': session.nodeId,
                      'protocol_version': protocolVersion,
                    }),
                  );
                }
              }
              return;
            }
            if (packetType == 'server_sync_delta_begin' ||
                packetType == 'server_sync') {
              _reliableSyncRequestedAt = DateTime.now();
            }
            final rawDeliveryId = decoded['_delivery_id'];
            final deliveryId =
                rawDeliveryId is String &&
                    RegExp(r'^[a-f0-9]{64}$').hasMatch(rawDeliveryId) &&
                    (packetType == 'chat_message' ||
                        packetType == 'group_message')
                ? rawDeliveryId
                : null;
            if (deliveryId != null &&
                _processedDeliveries.contains(deliveryId)) {
              channel.sink.add(
                jsonEncode({
                  'type': 'reliable_delivery_ack',
                  'delivery_id': deliveryId,
                  'source_node': session.nodeId,
                  'protocol_version': protocolVersion,
                }),
              );
              return;
            }
            if (packetType == 'server_welcome') {
              _welcomeTimer?.cancel();
              _welcomeTimer = null;
              _reconnectAttempt = 0;
              _lastIdentityRecovery =
                  decoded['encryption_recovery']?.toString() ?? '';
              final rawCapabilities = decoded['capabilities'];
              final capabilities = rawCapabilities is Map
                  ? Map<String, dynamic>.from(rawCapabilities)
                  : const <String, dynamic>{};
              _serverCapabilitiesKnown = true;
              _supportsMutationAck = capabilities['mutation_ack'] == true;
              _supportsMutationReconcile =
                  capabilities['mutation_reconcile'] == true;
              _supportsFileTransferV2 =
                  capabilities['file_transfer_v2'] == true;
              _supportsMediaDeliveryV2 =
                  capabilities['media_delivery_v2'] == true;
              _supportsSyncV2Delta = capabilities['sync_v2_delta'] == true;
              _supportsSyncV2DeltaBatch =
                  capabilities['sync_v2_delta_batch'] == true;
              _supportsMultiDeviceState =
                  capabilities['multi_device_state'] == true;
            }
            if (packetType == 'file_chunk_ack') {
              await _serializeFileOutbox(() async {
                if (_isCurrentGeneration(generation)) {
                  await _consumeFileChunkAck(decoded, generation);
                }
              });
            } else if (packetType == 'mutation_ack') {
              await _consumeMutationAck(decoded, onPacket, generation);
            } else if (packetType == 'mutation_status_result') {
              _consumeMutationStatusResult(decoded);
            } else {
              await onPacket(decoded);
            }
            if (!_isCurrentConnection(generation, channel)) return;
            if (packetType == 'server_sync_done') {
              _reliableSyncRequestedAt = null;
            }
            if (deliveryId != null) {
              _processedDeliveries.add(deliveryId);
              if (_processedDeliveries.length > 4096) {
                _processedDeliveries.remove(_processedDeliveries.first);
              }
              channel.sink.add(
                jsonEncode({
                  'type': 'reliable_delivery_ack',
                  'delivery_id': deliveryId,
                  'source_node': session.nodeId,
                  'protocol_version': protocolVersion,
                }),
              );
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
              _startupRecovery = () async {
                try {
                  await _recoverMutationOutbox(generation);
                  if (_isCurrentConnection(generation, channel)) {
                    await _flushFileOutbox();
                  }
                } catch (error) {
                  debugPrint('MeshSocket outbox recovery failed: $error');
                  if (_isCurrentConnection(generation, channel)) {
                    _scheduleMutationRetry();
                    _scheduleFileRetry();
                  }
                }
              }();
            }
          }
        } catch (error, stackTrace) {
          debugPrint('MeshSocket packet handling failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        } finally {
          if (!currentPacket.isCompleted) currentPacket.complete();
        }
      },
      onError: (Object error) {
        _handleConnectionLoss(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
          generation: generation,
          channel: channel,
          status: 'Connection error',
        );
      },
      onDone: () {
        _handleConnectionLoss(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
          generation: generation,
          channel: channel,
          status: 'Offline',
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
    String publicKey, {
    String emailChallengeId = '',
    String emailCode = '',
    bool registerIfMissing = false,
  }) async {
    _lastIdentityRecovery = '';
    final channel = WebSocketChannel.connect(Uri.parse(session.serverUrl));
    final startedAt = DateTime.now();
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({
          ..._helloPacket(
            session,
            publicKey,
            null,
            emailChallengeId: emailChallengeId,
            emailCode: emailCode,
            registerIfMissing: registerIfMissing,
          ),
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
          code: packet['code']?.toString() ?? '',
          data: packet,
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
        data: packet,
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

  Future<ConnectionDiagnostics> requestPasswordReset({
    required String serverUrl,
    required String serverToken,
    required String login,
    required String nodeId,
  }) {
    return _authAction(
      serverUrl: serverUrl,
      packet: {
        'type': 'server_hello',
        'auth_action': 'password_reset_request',
        'server_token': serverToken,
        'login': login,
        'node_id': nodeId,
        'protocol_version': protocolVersion,
        'min_protocol_version': minProtocolVersion,
      },
    );
  }

  Future<ConnectionDiagnostics> confirmPasswordReset({
    required String serverUrl,
    required String serverToken,
    required String login,
    required String nodeId,
    required String challengeId,
    required String code,
    required String newPassword,
    required String encryptionRecovery,
    required String encryptionPublicKey,
  }) {
    return _authAction(
      serverUrl: serverUrl,
      packet: {
        'type': 'server_hello',
        'auth_action': 'password_reset_confirm',
        'server_token': serverToken,
        'login': login,
        'node_id': nodeId,
        'challenge_id': challengeId,
        'code': code,
        'new_password': newPassword,
        'encryption_recovery': encryptionRecovery,
        'encryption_public_key': encryptionPublicKey,
        'protocol_version': protocolVersion,
        'min_protocol_version': minProtocolVersion,
      },
    );
  }

  Future<ConnectionDiagnostics> _authAction({
    required String serverUrl,
    required Map<String, dynamic> packet,
  }) async {
    final channel = WebSocketChannel.connect(Uri.parse(serverUrl));
    final startedAt = DateTime.now();
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(jsonEncode(packet));
      final raw = await channel.stream.first.timeout(
        const Duration(seconds: 20),
      );
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final ok = decoded['ok'] == true;
      return ConnectionDiagnostics(
        ok: ok,
        message: ok
            ? 'OK'
            : _passwordResetError(decoded['code']?.toString() ?? ''),
        latency: DateTime.now().difference(startedAt),
        code: decoded['code']?.toString() ?? '',
        data: decoded,
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

  static String _passwordResetError(String code) {
    return switch (code) {
      'account_recovery_unavailable' =>
        'No verified recovery email is linked to this account',
      'retry_after' => 'Wait before requesting another email',
      'invalid_code' => 'The verification code is incorrect',
      'code_expired' => 'The verification code expired',
      'too_many_attempts' => 'Too many incorrect code attempts',
      'password_too_short' => 'Use at least 8 characters',
      'password_too_long' => 'Password is too long',
      _ => 'Could not reset the password',
    };
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
    await _trace(
      operationId: operationId,
      packetId: fileId,
      stage: 'persisted',
      detail: 'file_transfer',
    );
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
    final generation = _connectionGeneration;
    if (current == null || !_connected || !_serverCapabilitiesKnown) return;
    if (_flushingFileOutbox) return;
    _flushingFileOutbox = true;
    try {
      final entries = await _fileTransferStore.load(current);
      for (final entry in entries) {
        if (!_isCurrentGeneration(generation)) break;
        if (!_connected || entry.isComplete || entry.isFailed) continue;
        final payloadExists = await _fileTransferStore.payloadExists(entry);
        if (!_isCurrentGeneration(generation)) break;
        if (!payloadExists) {
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
          await _sendLegacyFileTransfer(current, entry, generation);
          continue;
        }
        final inFlight = _fileChunksInFlight.putIfAbsent(
          entry.transferId,
          () => <int>{},
        );
        if (inFlight.length >= _fileTransferWindow) continue;
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
          if (!_isCurrentGeneration(generation) || !_connected) break;
          final sent = await _sendFileTransferChunk(
            entry,
            index,
            generation,
            v2: true,
          );
          if (!_isCurrentGeneration(generation)) break;
          if (sent == null) {
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
          if (!sent) break;
          inFlight.add(index);
        }
        await _fileTransferStore.markAttempt(current, entry.transferId);
      }
      if (_isCurrentGeneration(generation) &&
          _supportsFileTransferV2 &&
          entries.any((entry) => !entry.isComplete && !entry.isFailed)) {
        _scheduleFileRetry();
      }
    } catch (_) {
      if (_isCurrentGeneration(generation)) _scheduleFileRetry();
    } finally {
      _flushingFileOutbox = false;
      if (generation != _connectionGeneration && !_closed && _connected) {
        unawaited(_flushFileOutbox());
      }
    }
  }

  Future<void> _sendLegacyFileTransfer(
    Session current,
    FileTransferOutboxEntry entry,
    int generation,
  ) async {
    for (var index = 0; index < entry.totalChunks; index++) {
      if (!_isCurrentGeneration(generation) || !_connected) return;
      final sent = await _sendFileTransferChunk(
        entry,
        index,
        generation,
        v2: false,
      );
      if (!_isCurrentGeneration(generation)) return;
      if (sent == null) {
        await _fileTransferStore.markFailed(
          current,
          entry.transferId,
          'source_file_unreadable',
        );
        return;
      }
      if (!sent) return;
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

  Future<bool?> _sendFileTransferChunk(
    FileTransferOutboxEntry entry,
    int index,
    int generation, {
    required bool v2,
  }) async {
    final bytes = await _fileTransferStore.readChunk(entry, index);
    if (!_isCurrentGeneration(generation)) return false;
    if (bytes.isEmpty) return null;
    return _sendRaw({
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
  }

  Future<void> _consumeFileChunkAck(
    Map<String, dynamic> packet,
    int generation,
  ) async {
    final current = _session;
    final handler = _packetHandler;
    final transferId = packet['transfer_id']?.toString() ?? '';
    if (current == null || transferId.isEmpty) {
      if (handler != null) await handler(packet);
      return;
    }
    final entry = await _fileTransferStore.get(current, transferId);
    if (entry == null || !_isCurrentGeneration(generation)) return;
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
      if (!retryable) {
        await _trace(
          operationId: entry.operationId,
          packetId: entry.fileId,
          stage: 'failed',
          detail: reason,
        );
      }
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
    if (!_isCurrentGeneration(generation)) return;
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
    if (!_isCurrentGeneration(generation)) return;
    await _emitFileProgress(
      fileId: entry.fileId,
      operationId: entry.operationId,
      progress: progress,
      complete: operationComplete,
    );
    if (operationComplete) {
      await _trace(
        operationId: entry.operationId,
        packetId: entry.fileId,
        stage: 'server_committed',
        detail: 'file_transfer',
      );
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
    final generation = _connectionGeneration;
    try {
      await _startupRecovery;
    } catch (_) {
      // Recovery failures leave durable rows queued for the normal retry path.
    }
    if (current == null) {
      return;
    }
    final packet = Map<String, dynamic>.from(originalPacket);
    final operationId = operationIdForPacket(packet);
    final outboxId = outboxIdForPacket(packet);
    if (operationId.isEmpty || outboxId.isEmpty) {
      if (_isCurrentGeneration(generation)) _sendRaw(packet);
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
    var persisted = false;
    try {
      await _serializeOutbox(() async {
        // Persist before exposing the mutation to the network. If the process
        // dies after the socket write but before this row exists, a missing
        // ACK would otherwise leave nothing to reconcile or replay.
        await _outboxStore.put(current, entry);
        persisted = true;
        await _trace(
          operationId: operationId,
          packetId: packet['packet_id']?.toString() ?? '',
          stage: 'persisted',
          detail: packet['type']?.toString() ?? '',
        );
        if (_isCurrentGeneration(generation) &&
            _connected &&
            _serverCapabilitiesKnown) {
          await _sendOutboxEntry(current, entry, generation);
        }
      });
      _scheduleMutationRetry();
    } catch (error) {
      debugPrint('Could not persist mutation $operationId: $error');
      if (!_isCurrentGeneration(generation)) return;
      if (persisted) {
        _scheduleMutationRetry();
        return;
      }
      // Without a durable row, a lost network ACK cannot be recovered.
      // Expose the failure so the user can free space and explicitly retry.
      try {
        await _packetHandler?.call({
          'type': 'mutation_ack',
          'ok': false,
          'operation_complete': true,
          'operation_id': operationId,
          'outbox_id': outboxId,
          'packet_id':
              packet['packet_id'] ??
              packet['group_message_id'] ??
              packet['message_id'] ??
              '',
          'packet_type': packet['type'],
          'reason': 'local_outbox_unavailable',
        });
      } catch (failure) {
        debugPrint('Could not report outbox failure: $failure');
      }
    }
  }

  Future<void> _recoverMutationOutbox(int generation) async {
    final current = _session;
    if (current == null || !_isCurrentGeneration(generation)) return;

    late List<MutationOutboxEntry> entries;
    try {
      await _serializeOutbox(() async {
        entries = await _outboxStore.load(current);
      });
    } catch (_) {
      return;
    }
    if (entries.isEmpty || !_isCurrentGeneration(generation)) return;
    if (!_supportsMutationReconcile) {
      await _flushOutbox(force: true);
      return;
    }

    final requestId =
        'mutation-status-${DateTime.now().microsecondsSinceEpoch}-'
        '${_reconnectRandom.nextInt(1 << 31)}';
    final completer = Completer<Set<String>>();
    _mutationStatusRequests[requestId] = completer;
    final sent = _sendRaw({
      'type': 'mutation_status_request',
      'request_id': requestId,
      'source_node': current.nodeId,
      'outbox_ids': entries.map((entry) => entry.outboxId).toList(),
      'protocol_version': protocolVersion,
    });
    Set<String> processed = const <String>{};
    try {
      if (sent) {
        processed = await completer.future.timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      // A full replay is safe because the server deduplicates outbox ids.
    } finally {
      _mutationStatusRequests.remove(requestId);
    }
    if (!_isCurrentGeneration(generation)) return;

    for (final entry in entries) {
      if (!_isCurrentGeneration(generation)) return;
      if (!processed.contains(entry.outboxId)) continue;
      await _consumeReconciledMutation(current, entry, generation);
    }
    await _flushOutbox(force: true);
  }

  Future<void> _flushOutbox({bool force = false}) async {
    final current = _session;
    final generation = _connectionGeneration;
    if (current == null || !_connected || !_serverCapabilitiesKnown) return;
    if (_flushingOutbox) return;
    _flushingOutbox = true;
    try {
      await _serializeOutbox(() async {
        final entries = await _outboxStore.load(current);
        final now = DateTime.now().toUtc();
        for (final entry in entries) {
          if (!_isCurrentGeneration(generation) || !_connected) break;
          if (!force && !_mutationRetryDue(entry, now)) continue;
          await _sendOutboxEntry(current, entry, generation);
        }
      });
    } catch (_) {
      // Entries remain persisted and will be retried on the next reconnect.
    } finally {
      _flushingOutbox = false;
      _scheduleMutationRetry();
      if (generation != _connectionGeneration && !_closed && _connected) {
        unawaited(_flushOutbox());
      }
    }
  }

  Future<void> _sendOutboxEntry(
    Session current,
    MutationOutboxEntry entry,
    int generation,
  ) async {
    if (!_isCurrentGeneration(generation) || !_serverCapabilitiesKnown) return;
    if (!_sendRaw(entry.packet)) {
      await _outboxStore.markQueued(
        current,
        entry.outboxId,
        error: 'socket_unavailable',
      );
      return;
    }
    if (_supportsMutationAck) {
      await _outboxStore.markSent(current, entry.outboxId);
    } else {
      await _outboxStore.delete(current, entry.outboxId);
    }
    await _trace(
      operationId: entry.operationId,
      packetId: entry.packet['packet_id']?.toString() ?? '',
      stage: 'sent',
      detail: entry.packet['type']?.toString() ?? '',
    );
  }

  static bool _mutationRetryDue(MutationOutboxEntry entry, DateTime now) {
    if (entry.state == MutationOutboxState.queued ||
        entry.lastAttemptAt == null) {
      return true;
    }
    return !now.isBefore(
      entry.lastAttemptAt!.add(mutationRetryDelayForAttempts(entry.attempts)),
    );
  }

  void _scheduleMutationRetry() {
    _mutationRetryTimer?.cancel();
    final arm = ++_mutationRetryArm;
    if (_closed || !_connected || !_supportsMutationAck) return;
    final current = _session;
    final generation = _connectionGeneration;
    if (current == null) return;
    unawaited(() async {
      late List<MutationOutboxEntry> entries;
      try {
        await _serializeOutbox(() async {
          entries = await _outboxStore.load(current);
        });
      } catch (_) {
        return;
      }
      if (arm != _mutationRetryArm ||
          entries.isEmpty ||
          !_isCurrentGeneration(generation) ||
          !_connected) {
        return;
      }
      _mutationRetryTimer = Timer(const Duration(seconds: 2), () {
        if (arm != _mutationRetryArm) return;
        unawaited(_flushOutbox());
      });
    }());
  }

  void _consumeMutationStatusResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _mutationStatusRequests[requestId];
    if (completer == null || completer.isCompleted) return;
    final rawIds = packet['processed_outbox_ids'];
    final processed = rawIds is List
        ? rawIds
              .map((value) => value?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .toSet()
        : <String>{};
    completer.complete(processed);
  }

  Future<void> _consumeReconciledMutation(
    Session current,
    MutationOutboxEntry entry,
    int generation,
  ) async {
    var operationComplete = false;
    await _serializeOutbox(() async {
      await _outboxStore.delete(current, entry.outboxId);
      operationComplete = !await _outboxStore.hasOperation(
        current,
        entry.operationId,
      );
    });
    if (!_isCurrentGeneration(generation)) return;
    final handler = _packetHandler;
    if (handler == null) return;
    await _trace(
      operationId: entry.operationId,
      packetId: entry.packet['packet_id']?.toString() ?? '',
      stage: 'server_committed',
      detail: 'reconciled',
    );
    await handler({
      'type': 'mutation_ack',
      'ok': true,
      'duplicate': true,
      'reconciled': true,
      'outbox_id': entry.outboxId,
      'operation_id': entry.operationId,
      'packet_type': entry.packet['type'],
      'packet_id':
          entry.packet['packet_id'] ??
          entry.packet['group_message_id'] ??
          entry.packet['message_id'] ??
          entry.packet['story_id'] ??
          '',
      'operation_complete': operationComplete,
    });
  }

  Future<void> _consumeMutationAck(
    Map<String, dynamic> packet,
    PacketHandler onPacket,
    int generation,
  ) async {
    final current = _session;
    final outboxId = packet['outbox_id']?.toString() ?? '';
    // The server emits this only after persistence. Complete the local durable
    // cleanup before exposing the acknowledgement so an immediate restart
    // cannot replay an operation that the server has already committed.
    if (current != null && outboxId.isNotEmpty) {
      await _serializeOutbox(() async {
        await _outboxStore.delete(current, outboxId);
      });
    }
    if (!_isCurrentGeneration(generation)) return;
    await _trace(
      operationId: packet['operation_id']?.toString() ?? '',
      packetId: packet['packet_id']?.toString() ?? '',
      stage: packet['ok'] == false ? 'failed' : 'server_committed',
      detail: packet['packet_type']?.toString() ?? '',
    );
    await onPacket({...packet, 'operation_complete': true});
    _scheduleMutationRetry();
  }

  Future<void> _serializeOutbox(Future<void> Function() action) {
    final result = _outboxSerial.then((_) => action());
    _outboxSerial = result.catchError((Object _) {});
    return result;
  }

  bool _sendRaw(Map<String, dynamic> packet) {
    final channel = _channel;
    if (_closed || !_connected || channel == null) return false;
    try {
      channel.sink.add(jsonEncode(packet));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _trace({
    required String operationId,
    required String packetId,
    required String stage,
    String detail = '',
  }) async {
    final handler = _deliveryTraceHandler;
    if (handler == null || operationId.isEmpty) return;
    try {
      await handler({
        'operation_id': operationId,
        'packet_id': packetId,
        'stage': stage,
        'detail': detail,
        'time': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Delivery diagnostics must never block or fail message transport.
    }
  }

  Map<String, dynamic> _helloPacket(
    Session session,
    String publicKey,
    Profile? profile, {
    String deviceName = '',
    bool reactivateDevice = false,
    String emailChallengeId = '',
    String emailCode = '',
    bool registerIfMissing = false,
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
      'email': session.email,
      'supports_email_2fa': true,
      'register_if_missing': registerIfMissing,
      if (emailChallengeId.isNotEmpty) 'email_challenge_id': emailChallengeId,
      if (emailCode.isNotEmpty) 'email_code': emailCode,
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
      'supports_sync_v2_delta_batch': true,
      'sync_cursor': _syncCursor,
      'supports_offline_packet_ack': true,
      'supports_reliable_delivery_v1': true,
      'supports_reliable_sync_v2': true,
      'supports_mutation_ack': true,
      'supports_mutation_reconcile': true,
      'supports_file_transfer_v2': true,
      'supports_media_delivery_v2': !kIsWeb,
      'supports_account_live_fanout': true,
      'supports_multi_device_state': true,
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

  static Duration reconnectDelayForAttempt(int attempt, {double jitter = 1}) {
    final safeAttempt = attempt.clamp(0, 5);
    final baseSeconds = min(20, 1 << safeAttempt);
    final safeJitter = jitter.clamp(0.75, 1.25);
    return Duration(
      milliseconds: max(250, (baseSeconds * 1000 * safeJitter).round()),
    );
  }

  static Duration mutationRetryDelayForAttempts(int attempts) {
    final exponent = (attempts - 1).clamp(0, 4);
    return Duration(seconds: min(30, 2 << exponent));
  }

  bool _isCurrentGeneration(int generation) =>
      !_closed && generation == _connectionGeneration;

  bool _isCurrentConnection(int generation, WebSocketChannel channel) =>
      _isCurrentGeneration(generation) && identical(channel, _channel);

  void _handleConnectionLoss(
    Session session,
    String publicKey,
    Profile profile,
    PacketHandler onPacket,
    StatusHandler onStatus,
    String deviceName, {
    required int generation,
    required WebSocketChannel channel,
    required String status,
  }) {
    if (!_isCurrentConnection(generation, channel)) return;
    _connected = false;
    _serverCapabilitiesKnown = false;
    _supportsMutationAck = false;
    _supportsMutationReconcile = false;
    _supportsFileTransferV2 = false;
    _supportsMediaDeliveryV2 = false;
    _supportsSyncV2Delta = false;
    _supportsSyncV2DeltaBatch = false;
    _supportsMultiDeviceState = false;
    _fileChunksInFlight.clear();
    _fileRetryTimer?.cancel();
    _mutationRetryTimer?.cancel();
    _mutationRetryArm++;
    _completeMutationStatusRequests();
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    onStatus(status);
    _scheduleReconnect(
      session,
      publicKey,
      profile,
      onPacket,
      onStatus,
      deviceName,
      generation: generation,
    );
  }

  void _scheduleReconnect(
    Session session,
    String publicKey,
    Profile profile,
    PacketHandler onPacket,
    StatusHandler onStatus,
    String deviceName, {
    required int generation,
  }) {
    if (!_isCurrentGeneration(generation) ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    final attempt = _reconnectAttempt++;
    final delay =
        reconnectDelayFactory?.call(attempt) ??
        reconnectDelayForAttempt(
          attempt,
          jitter: 0.85 + (_reconnectRandom.nextDouble() * 0.30),
        );
    _reconnectTimer = Timer(delay, () {
      if (!_isCurrentGeneration(generation)) return;
      final reconnectGeneration = _connectionGeneration + 1;
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
        if (!_isCurrentGeneration(reconnectGeneration)) return;
        _scheduleReconnect(
          session,
          publicKey,
          profile,
          onPacket,
          onStatus,
          deviceName,
          generation: reconnectGeneration,
        );
      });
    });
  }

  Future<void> close() async {
    _closed = true;
    _connectionGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    _connected = false;
    _serverCapabilitiesKnown = false;
    _supportsMutationAck = false;
    _supportsMutationReconcile = false;
    _supportsFileTransferV2 = false;
    _supportsMediaDeliveryV2 = false;
    _supportsSyncV2Delta = false;
    _supportsSyncV2DeltaBatch = false;
    _supportsMultiDeviceState = false;
    _fileChunksInFlight.clear();
    _fileRetryTimer?.cancel();
    _mutationRetryTimer?.cancel();
    _mutationRetryArm++;
    _completeMutationStatusRequests();
    _session = null;
    _packetHandler = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _completeMutationStatusRequests() {
    for (final completer in _mutationStatusRequests.values) {
      if (!completer.isCompleted) completer.complete(const <String>{});
    }
    _mutationStatusRequests.clear();
  }
}

class ConnectionDiagnostics {
  const ConnectionDiagnostics({
    required this.ok,
    required this.message,
    required this.latency,
    this.serverVersion = 'unknown',
    this.serverProtocolRange = '?',
    this.code = '',
    this.data = const <String, dynamic>{},
  });

  final bool ok;
  final String message;
  final Duration latency;
  final String serverVersion;
  final String serverProtocolRange;
  final String code;
  final Map<String, dynamic> data;
}
