import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/profile.dart';

typedef BlePacketHandler = Future<void> Function(Map<String, dynamic> packet);

enum BleSendResult { sent, queued }

class BlePeer {
  const BlePeer({
    required this.id,
    required this.name,
    this.nodeId = '',
    this.displayName = '',
    this.publicUsername = '',
    this.publicKey = '',
    this.rssi = 0,
    this.connected = false,
    this.lastSeen,
  });

  final String id;
  final String name;
  final String nodeId;
  final String displayName;
  final String publicUsername;
  final String publicKey;
  final int rssi;
  final bool connected;
  final DateTime? lastSeen;

  BlePeer copyWith({
    String? name,
    String? nodeId,
    String? displayName,
    String? publicUsername,
    String? publicKey,
    int? rssi,
    bool? connected,
    DateTime? lastSeen,
  }) {
    return BlePeer(
      id: id,
      name: name ?? this.name,
      nodeId: nodeId ?? this.nodeId,
      displayName: displayName ?? this.displayName,
      publicUsername: publicUsername ?? this.publicUsername,
      publicKey: publicKey ?? this.publicKey,
      rssi: rssi ?? this.rssi,
      connected: connected ?? this.connected,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class BleChatService extends ChangeNotifier {
  static const _peerTtl = Duration(seconds: 40);
  static const _mobileScanWindow = Duration(seconds: 12);
  static const _mobileScanPause = Duration(seconds: 8);
  static const _connectTimeout = Duration(seconds: 12);
  static const _gattTimeout = Duration(seconds: 10);
  static const _writeTimeout = Duration(seconds: 8);

  static final serviceUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000001',
  );
  static final infoUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000002',
  );
  static final inboxUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000003',
  );

  late final CentralManager _central = CentralManager();
  late final PeripheralManager _peripheral = PeripheralManager();
  final Map<String, _DiscoveredBlePeer> _discovered = {};
  final Map<String, _ConnectedBlePeer> _connected = {};
  final Map<String, _IncomingBlePacket> _incoming = {};
  final Set<String> _knownPeerIds = {};
  final Set<String> _pairingTargetNodeIds = {};
  final Set<String> _autoConnecting = {};
  final List<_QueuedBlePacket> _queue = [];
  final List<StreamSubscription> _subscriptions = [];
  Timer? _pruneTimer;
  Timer? _scanPauseTimer;
  Timer? _scanResumeTimer;
  String _queueOwnerNodeId = '';

  BlePacketHandler? onPacket;
  bool running = false;
  bool scanning = false;
  bool wideScanning = false;
  String status = 'Bluetooth stopped';

  bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;
  int get queuedCount => _queue.length;
  List<String> get pairingTargetNodeIds => _pairingTargetNodeIds.toList();

  List<BlePeer> get peers {
    final deduped = <String, BlePeer>{};
    for (final entry in _discovered.values) {
      final connected = _connected[entry.peer.id]?.peer;
      final peer = connected ?? entry.peer;
      final key = peer.nodeId.isEmpty ? peer.id : peer.nodeId;
      final previous = deduped[key];
      if (previous == null ||
          peer.connected ||
          (peer.lastSeen ?? DateTime(0)).isAfter(
            previous.lastSeen ?? DateTime(0),
          )) {
        deduped[key] = peer;
      }
    }
    final values = deduped.values.toList();
    values.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return values;
  }

  Future<void> start({
    required Profile profile,
    required String publicKey,
  }) async {
    if (!supported) {
      throw UnsupportedError('Bluetooth is not supported on this platform');
    }
    if (running) return;
    await _restoreQueue(profile.nodeId);
    _listen();
    _startPruneTimer();
    await _authorizeIfNeeded();
    try {
      await _startAdvertising(profile: profile, publicKey: publicKey);
    } catch (error) {
      if (!Platform.isWindows) rethrow;
      status = 'Bluetooth scan is running. Windows advertising failed: $error';
    }
    running = true;
    if (!status.startsWith('Bluetooth scan is running')) {
      status = 'Bluetooth nearby is running';
    }
    notifyListeners();
    await startScan();
  }

  Future<void> stop() async {
    _cancelScanDutyCycle();
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await stopScan();
    for (final entry in _connected.values.toList()) {
      await _central.disconnect(entry.peripheral).catchError((_) {});
    }
    _connected.clear();
    _discovered.clear();
    _incoming.clear();
    await _peripheral.stopAdvertising().catchError((_) {});
    await _peripheral.removeAllServices().catchError((_) {});
    running = false;
    status = 'Bluetooth stopped';
    notifyListeners();
  }

  Future<void> startScan() async {
    if (!supported || scanning) return;
    await _authorizeIfNeeded();
    _clearDisconnectedPeers();
    if (Platform.isWindows) {
      await _central.startDiscovery();
      wideScanning = true;
    } else {
      await _central.startDiscovery(serviceUUIDs: [serviceUuid]);
      wideScanning = false;
    }
    scanning = true;
    status = Platform.isWindows
        ? 'Windows wide scan: showing nearby BLE devices'
        : running
        ? 'Scanning for MeshChat devices'
        : 'Scanning';
    notifyListeners();
    _scheduleScanDutyCycle();
  }

  Future<void> startWideScan() async {
    if (!supported || scanning) return;
    await _authorizeIfNeeded();
    _clearDisconnectedPeers();
    await _central.startDiscovery();
    scanning = true;
    wideScanning = true;
    status = running ? 'Wide scan: showing nearby BLE devices' : 'Wide scan';
    notifyListeners();
  }

  void clearPeers() {
    _clearDisconnectedPeers();
    notifyListeners();
  }

  Future<void> refreshScan() async {
    final wasWide = wideScanning || Platform.isWindows;
    await stopScan();
    if (wasWide) {
      await startWideScan();
    } else {
      await startScan();
    }
  }

  void addPairingTarget(String nodeId) {
    final normalized = nodeId.trim();
    if (normalized.isEmpty) return;
    _pairingTargetNodeIds.add(normalized);
    status = 'Bluetooth pairing target added';
    notifyListeners();
    _tryPairingTargets();
  }

  Future<void> stopScan() async {
    _cancelScanDutyCycle();
    if (!scanning) return;
    await _central.stopDiscovery().catchError((_) {});
    scanning = false;
    wideScanning = false;
    status = running ? 'Bluetooth nearby is running' : 'Bluetooth stopped';
    notifyListeners();
  }

  void _scheduleScanDutyCycle() {
    if (Platform.isWindows || !running || !scanning) return;
    _scanPauseTimer?.cancel();
    _scanPauseTimer = Timer(_mobileScanWindow, () async {
      if (!running || !scanning) return;
      await _central.stopDiscovery().catchError((_) {});
      scanning = false;
      status = 'Bluetooth nearby is running';
      notifyListeners();
      _scanResumeTimer = Timer(_mobileScanPause, () {
        if (running && !scanning) unawaited(startScan());
      });
    });
  }

  void _cancelScanDutyCycle() {
    _scanPauseTimer?.cancel();
    _scanPauseTimer = null;
    _scanResumeTimer?.cancel();
    _scanResumeTimer = null;
  }

  Future<BlePeer> connect(BlePeer peer) async {
    return _connect(peer, automatic: false);
  }

  Future<BlePeer> _connect(BlePeer peer, {required bool automatic}) async {
    final discovered = _discovered[peer.id];
    if (discovered == null) return peer;
    final existing = _connected[peer.id];
    if (existing != null) return existing.peer;

    try {
      status = automatic
          ? 'Auto-connecting to ${peer.name}'
          : 'Connecting to ${peer.name}';
      notifyListeners();
      await _central.connect(discovered.peripheral).timeout(_connectTimeout);
      if (Platform.isAndroid) {
        await _central
            .requestMTU(discovered.peripheral, mtu: 512)
            .catchError((_) => 0);
      }
      final services = await _central
          .discoverGATT(discovered.peripheral)
          .timeout(_gattTimeout);
      GATTCharacteristic? infoCharacteristic;
      GATTCharacteristic? inboxCharacteristic;
      for (final service in services) {
        if (service.uuid != serviceUuid) continue;
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == infoUuid) {
            infoCharacteristic = characteristic;
          }
          if (characteristic.uuid == inboxUuid) {
            inboxCharacteristic = characteristic;
          }
        }
      }
      if (infoCharacteristic == null || inboxCharacteristic == null) {
        throw StateError('This is not a MeshChat Bluetooth device');
      }
      final raw = await _central
          .readCharacteristic(discovered.peripheral, infoCharacteristic)
          .timeout(_gattTimeout);
      final updated = _peerFromInfo(peer, raw).copyWith(connected: true);
      if (updated.nodeId.isEmpty || updated.publicKey.isEmpty) {
        throw StateError('MeshChat Bluetooth handshake is incomplete');
      }
      _connected[peer.id] = _ConnectedBlePeer(
        peripheral: discovered.peripheral,
        inbox: inboxCharacteristic,
        peer: updated,
      );
      _discovered[peer.id] = _DiscoveredBlePeer(
        peripheral: discovered.peripheral,
        peer: updated,
      );
      _knownPeerIds.add(peer.id);
      if (_pairingTargetNodeIds.remove(updated.nodeId)) {
        _knownPeerIds.add(peer.id);
      }
      _removeDuplicateNodePeers(updated);
      status = 'Connected to ${updated.displayNameOrName}';
      notifyListeners();
      unawaited(_flushQueueFor(peer.id));
      return updated;
    } catch (error) {
      _connected.remove(peer.id);
      await _central.disconnect(discovered.peripheral).catchError((_) {});
      if (!automatic) {
        status = 'Bluetooth connect failed: $error';
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> disconnect(BlePeer peer) async {
    final connected = _connected.remove(peer.id);
    if (connected != null) {
      await _central.disconnect(connected.peripheral).catchError((_) {});
      _discovered[peer.id] = _DiscoveredBlePeer(
        peripheral: connected.peripheral,
        peer: connected.peer.copyWith(connected: false),
      );
      status = 'Disconnected from ${connected.peer.displayNameOrName}';
      notifyListeners();
    }
  }

  Future<BleSendResult> sendPacket(
    BlePeer peer,
    Map<String, dynamic> packet,
  ) async {
    var connected = _connected[peer.id];
    if (connected == null) {
      try {
        final resolved = await connect(peer);
        connected = _connected[resolved.id];
      } catch (error) {
        if (peer.nodeId.isEmpty) rethrow;
        _queuePacket(peer, packet);
        _pairingTargetNodeIds.add(peer.nodeId);
        status =
            'Bluetooth send queued until ${peer.displayNameOrName} returns';
        notifyListeners();
        return BleSendResult.queued;
      }
    }
    if (connected == null) {
      throw StateError('Bluetooth peer is not connected');
    }
    try {
      await _sendPacketToConnected(connected, packet);
      return BleSendResult.sent;
    } catch (error) {
      _queuePacket(connected.peer, packet);
      _connected.remove(peer.id);
      _discovered[peer.id] = _DiscoveredBlePeer(
        peripheral: connected.peripheral,
        peer: connected.peer.copyWith(connected: false),
      );
      status = 'Bluetooth send queued: $error';
      notifyListeners();
      return BleSendResult.queued;
    }
  }

  Future<BleSendResult> sendPacketToNode(
    String nodeId,
    Map<String, dynamic> packet,
  ) async {
    final normalized = nodeId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Bluetooth node is empty');
    }
    for (final connected in _connected.values) {
      if (connected.peer.nodeId == normalized) {
        return sendPacket(connected.peer, packet);
      }
    }
    _queuePacket(BlePeer(id: '', name: 'MeshChat', nodeId: normalized), packet);
    _pairingTargetNodeIds.add(normalized);
    _tryPairingTargets();
    return BleSendResult.queued;
  }

  Future<void> _sendPacketToConnected(
    _ConnectedBlePeer connected,
    Map<String, dynamic> packet,
  ) async {
    final bytes = utf8.encode(jsonEncode(packet));
    final encoded = base64Encode(bytes);
    final packetId = const Uuid().v4();
    final maxWrite = await _central
        .getMaximumWriteLength(
          connected.peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        )
        .catchError((_) => 180);
    final chunkSize = max(40, min(160, maxWrite - 96));
    final total = (encoded.length / chunkSize).ceil();
    try {
      for (var index = 0; index < total; index++) {
        final start = index * chunkSize;
        final end = min(encoded.length, start + chunkSize);
        final frame = utf8.encode(
          jsonEncode({
            'v': 1,
            'id': packetId,
            'i': index,
            'n': total,
            'd': encoded.substring(start, end),
          }),
        );
        await _central
            .writeCharacteristic(
              connected.peripheral,
              connected.inbox,
              value: Uint8List.fromList(frame),
              type: GATTCharacteristicWriteType.withResponse,
            )
            .timeout(_writeTimeout);
      }
      status = 'Bluetooth message sent to ${connected.peer.displayNameOrName}';
      notifyListeners();
    } catch (error) {
      status = 'Bluetooth send failed: $error';
      notifyListeners();
      rethrow;
    }
  }

  void _queuePacket(BlePeer peer, Map<String, dynamic> packet) {
    final dedupeKey = _queuedPacketKey(packet);
    if (dedupeKey.isNotEmpty) {
      _queue.removeWhere(
        (item) =>
            item.nodeId == peer.nodeId &&
            _queuedPacketKey(item.packet) == dedupeKey,
      );
    }
    _queue.add(_QueuedBlePacket(peer.id, peer.nodeId, packet));
    if (_queue.length > 256) {
      _queue.removeRange(0, _queue.length - 256);
    }
    unawaited(_persistQueue());
  }

  String _queuedPacketKey(Map<String, dynamic> packet) {
    final type = packet['type']?.toString() ?? '';
    final fileId = packet['file_id']?.toString() ?? '';
    if (fileId.isNotEmpty) {
      final chunkIndex = packet['chunk_index']?.toString() ?? '';
      return '$type:file:$fileId:$chunkIndex';
    }
    final messageId =
        packet['message_id']?.toString() ??
        packet['group_message_id']?.toString() ??
        packet['packet_id']?.toString() ??
        '';
    return messageId.isEmpty ? '' : '$type:message:$messageId';
  }

  Future<void> _flushQueueFor(String peerId) async {
    final connected = _connected[peerId];
    if (connected == null || _queue.isEmpty) return;
    final pending = _queue
        .where(
          (item) =>
              item.peerId == peerId ||
              (item.nodeId.isNotEmpty && item.nodeId == connected.peer.nodeId),
        )
        .toList();
    if (pending.isEmpty) return;
    for (final item in pending) {
      try {
        await _sendPacketToConnected(connected, item.packet);
        _queue.remove(item);
        await _persistQueue();
      } catch (_) {
        break;
      }
    }
    notifyListeners();
  }

  Future<void> _restoreQueue(String ownerNodeId) async {
    final normalized = ownerNodeId.trim();
    if (_queueOwnerNodeId == normalized) return;
    _queueOwnerNodeId = normalized;
    _queue.clear();
    _pairingTargetNodeIds.clear();
    if (normalized.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey(normalized));
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded.whereType<Map>()) {
        final queued = _QueuedBlePacket.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (queued.nodeId.isEmpty || queued.packet.isEmpty) continue;
        _queue.add(queued);
        _pairingTargetNodeIds.add(queued.nodeId);
      }
    } catch (_) {
      await prefs.remove(_queueKey(normalized));
    }
  }

  Future<void> _persistQueue() async {
    final owner = _queueOwnerNodeId;
    if (owner.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _queueKey(owner);
      if (_queue.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode(_queue.map((item) => item.toJson()).toList()),
      );
    } catch (error) {
      status = 'Bluetooth queue remains in memory: $error';
      notifyListeners();
    }
  }

  Future<void> cancelQueuedMessage(String messageId) async {
    final normalized = messageId.trim();
    if (normalized.isEmpty) return;
    _queue.removeWhere(
      (item) =>
          item.packet['packet_id']?.toString() == normalized ||
          item.packet['message_id']?.toString() == normalized ||
          item.packet['file_id']?.toString() == normalized,
    );
    await _persistQueue();
    notifyListeners();
  }

  Future<void> clearQueuedPackets() async {
    if (_queue.isEmpty) return;
    _queue.clear();
    _pairingTargetNodeIds.clear();
    await _persistQueue();
    notifyListeners();
  }

  String _queueKey(String ownerNodeId) => 'meshchat_ble_queue:$ownerNodeId';

  void _listen() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.add(
      _central.discovered.listen((event) {
        final id = event.peripheral.uuid.toString();
        final name = _safeAdvertisementName(event.advertisement) ?? 'MeshChat';
        if (!wideScanning && !_advertisesMeshChat(event.advertisement)) {
          return;
        }
        final existing = _discovered[id]?.peer;
        _discovered[id] = _DiscoveredBlePeer(
          peripheral: event.peripheral,
          peer: (existing ?? BlePeer(id: id, name: name)).copyWith(
            name: name,
            rssi: event.rssi,
            lastSeen: DateTime.now(),
          ),
          lastSeen: DateTime.now(),
        );
        _autoConnectIfKnown(id);
        _autoConnectIfPairingTarget(id);
        notifyListeners();
      }),
    );
    _subscriptions.add(
      _central.connectionStateChanged.listen((event) {
        final id = event.peripheral.uuid.toString();
        if (event.state != ConnectionState.connected) {
          final existing = _discovered[id]?.peer;
          if (existing != null) {
            _discovered[id] = _DiscoveredBlePeer(
              peripheral: event.peripheral,
              peer: existing.copyWith(connected: false),
              lastSeen: DateTime.now(),
            );
          }
          _connected.remove(id);
          notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      _peripheral.characteristicWriteRequested.listen((event) async {
        if (event.characteristic.uuid != inboxUuid) return;
        await _peripheral.respondWriteRequest(event.request);
        await _handleIncomingFrame(
          event.central.uuid.toString(),
          event.request.value,
        );
      }),
    );
  }

  Future<void> _startAdvertising({
    required Profile profile,
    required String publicKey,
  }) async {
    await _peripheral.removeAllServices().catchError((_) {});
    final info = GATTCharacteristic.immutable(
      uuid: infoUuid,
      value: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'app': 'MeshChat',
            'ble_protocol': 1,
            'node_id': profile.nodeId,
            'display_name': profile.displayName,
            'public_username': profile.publicUsername,
            'about': profile.about,
            'avatar_data': '',
            'encryption_public_key': publicKey,
          }),
        ),
      ),
      descriptors: [],
    );
    final inbox = GATTCharacteristic.mutable(
      uuid: inboxUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    await _peripheral.addService(
      GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [info, inbox],
      ),
    );
    await _peripheral.startAdvertising(
      Advertisement(
        name: Platform.isWindows ? null : 'MeshChat ${profile.displayName}',
        serviceUUIDs: Platform.isWindows ? [] : [serviceUuid],
        serviceData: Platform.isWindows
            ? {
                serviceUuid: Uint8List.fromList([1]),
              }
            : const {},
      ),
    );
  }

  Future<void> _authorizeIfNeeded() async {
    if (Platform.isAndroid) {
      await _central.authorize().catchError((_) => false);
      await _peripheral.authorize().catchError((_) => false);
    }
  }

  Future<void> _handleIncomingFrame(String peerId, Uint8List value) async {
    try {
      final raw = jsonDecode(utf8.decode(value));
      if (raw is! Map) return;
      final id = raw['id']?.toString() ?? '';
      final index = int.tryParse(raw['i']?.toString() ?? '');
      final total = int.tryParse(raw['n']?.toString() ?? '');
      final data = raw['d']?.toString() ?? '';
      if (id.isEmpty ||
          index == null ||
          total == null ||
          total <= 0 ||
          total > 512 ||
          index < 0 ||
          index >= total ||
          data.isEmpty) {
        return;
      }
      if (_incoming.length >= 24 && !_incoming.containsKey('$peerId:$id')) {
        _incoming.remove(_incoming.keys.first);
      }
      final incoming = _incoming.putIfAbsent(
        '$peerId:$id',
        () => _IncomingBlePacket(total),
      );
      if (incoming.total != total) {
        _incoming.remove('$peerId:$id');
        return;
      }
      incoming.chunks[index] = data;
      if (incoming.chunks.length < incoming.total) return;
      _incoming.remove('$peerId:$id');
      final encoded = List<String>.generate(
        incoming.total,
        (chunkIndex) => incoming.chunks[chunkIndex] ?? '',
      ).join();
      final packet = jsonDecode(utf8.decode(base64Decode(encoded)));
      if (packet is Map) {
        await onPacket?.call(Map<String, dynamic>.from(packet));
      }
    } catch (error) {
      status = 'Ignored invalid Bluetooth frame: $error';
      notifyListeners();
    }
  }

  BlePeer _peerFromInfo(BlePeer base, Uint8List raw) {
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map) return base;
      return base.copyWith(
        nodeId: decoded['node_id']?.toString() ?? '',
        displayName: decoded['display_name']?.toString() ?? '',
        publicUsername: decoded['public_username']?.toString() ?? '',
        publicKey: decoded['encryption_public_key']?.toString() ?? '',
      );
    } catch (_) {
      return base;
    }
  }

  String? _safeAdvertisementName(Advertisement advertisement) {
    try {
      return advertisement.name;
    } catch (_) {
      return null;
    }
  }

  bool _advertisesMeshChat(Advertisement advertisement) {
    try {
      if (advertisement.serviceUUIDs.contains(serviceUuid)) return true;
    } catch (_) {}
    try {
      if (advertisement.serviceData.containsKey(serviceUuid)) return true;
    } catch (_) {}
    return false;
  }

  void _startPruneTimer() {
    _pruneTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pruneStalePeers(),
    );
  }

  void _pruneStalePeers() {
    if (_discovered.isEmpty) return;
    final now = DateTime.now();
    var removed = false;
    _discovered.removeWhere((id, entry) {
      if (_connected.containsKey(id)) return false;
      final stale = now.difference(entry.lastSeen) > _peerTtl;
      removed = removed || stale;
      return stale;
    });
    if (removed) notifyListeners();
  }

  void _clearDisconnectedPeers() {
    _discovered.removeWhere((id, _) => !_connected.containsKey(id));
  }

  void _removeDuplicateNodePeers(BlePeer peer) {
    if (peer.nodeId.isEmpty) return;
    _discovered.removeWhere((id, entry) {
      if (id == peer.id) return false;
      return entry.peer.nodeId == peer.nodeId;
    });
  }

  void _autoConnectIfKnown(String id) {
    if (!_knownPeerIds.contains(id) ||
        _connected.containsKey(id) ||
        _autoConnecting.contains(id)) {
      return;
    }
    final peer = _discovered[id]?.peer;
    if (peer == null) return;
    _autoConnecting.add(id);
    unawaited(
      _connect(
        peer,
        automatic: true,
      ).catchError((_) => peer).whenComplete(() => _autoConnecting.remove(id)),
    );
  }

  void _autoConnectIfPairingTarget(String id) {
    if (_pairingTargetNodeIds.isEmpty ||
        _connected.containsKey(id) ||
        _autoConnecting.contains(id)) {
      return;
    }
    final peer = _discovered[id]?.peer;
    if (peer == null) return;
    _autoConnecting.add(id);
    unawaited(
      _connect(peer, automatic: true)
          .then((connected) {
            if (_pairingTargetNodeIds.remove(connected.nodeId)) {
              status = 'Bluetooth paired with ${connected.displayNameOrName}';
              notifyListeners();
            }
            return connected;
          })
          .catchError((_) => peer)
          .whenComplete(() => _autoConnecting.remove(id)),
    );
  }

  void _tryPairingTargets() {
    for (final id in _discovered.keys.toList()) {
      _autoConnectIfPairingTarget(id);
    }
  }

  @override
  void dispose() {
    _cancelScanDutyCycle();
    _pruneTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    stop();
    super.dispose();
  }
}

extension on BlePeer {
  String get displayNameOrName => displayName.isNotEmpty ? displayName : name;
}

class _DiscoveredBlePeer {
  _DiscoveredBlePeer({
    required this.peripheral,
    required this.peer,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final Peripheral peripheral;
  final BlePeer peer;
  final DateTime lastSeen;
}

class _ConnectedBlePeer {
  const _ConnectedBlePeer({
    required this.peripheral,
    required this.inbox,
    required this.peer,
  });

  final Peripheral peripheral;
  final GATTCharacteristic inbox;
  final BlePeer peer;
}

class _IncomingBlePacket {
  _IncomingBlePacket(this.total);

  final int total;
  final Map<int, String> chunks = {};
}

class _QueuedBlePacket {
  const _QueuedBlePacket(this.peerId, this.nodeId, this.packet);

  final String peerId;
  final String nodeId;
  final Map<String, dynamic> packet;

  factory _QueuedBlePacket.fromJson(Map<String, dynamic> json) {
    final rawPacket = json['packet'];
    return _QueuedBlePacket(
      json['peer_id']?.toString() ?? '',
      json['node_id']?.toString() ?? '',
      rawPacket is Map ? Map<String, dynamic>.from(rawPacket) : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'peer_id': peerId,
    'node_id': nodeId,
    'packet': packet,
  };
}
