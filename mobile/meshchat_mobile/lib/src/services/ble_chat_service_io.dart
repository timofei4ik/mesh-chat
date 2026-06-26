import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/profile.dart';

typedef BlePacketHandler = Future<void> Function(Map<String, dynamic> packet);

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
  });

  final String id;
  final String name;
  final String nodeId;
  final String displayName;
  final String publicUsername;
  final String publicKey;
  final int rssi;
  final bool connected;

  BlePeer copyWith({
    String? name,
    String? nodeId,
    String? displayName,
    String? publicUsername,
    String? publicKey,
    int? rssi,
    bool? connected,
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
    );
  }
}

class BleChatService extends ChangeNotifier {
  static const _peerTtl = Duration(seconds: 18);

  static final serviceUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000001',
  );
  static final infoUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000002',
  );
  static final inboxUuid = UUID.fromString(
    '6d657368-6368-6174-8000-000000000003',
  );

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();
  final Map<String, _DiscoveredBlePeer> _discovered = {};
  final Map<String, _ConnectedBlePeer> _connected = {};
  final Map<String, _IncomingBlePacket> _incoming = {};
  final List<StreamSubscription> _subscriptions = [];
  Timer? _pruneTimer;

  BlePacketHandler? onPacket;
  bool running = false;
  bool scanning = false;
  bool wideScanning = false;
  String status = 'Bluetooth stopped';

  bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  List<BlePeer> get peers {
    final values = _discovered.values.map((entry) {
      final connected = _connected[entry.peer.id]?.peer;
      return connected ?? entry.peer;
    }).toList();
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

  Future<void> stopScan() async {
    if (!scanning) return;
    await _central.stopDiscovery().catchError((_) {});
    scanning = false;
    wideScanning = false;
    status = running ? 'Bluetooth nearby is running' : 'Bluetooth stopped';
    notifyListeners();
  }

  Future<BlePeer> connect(BlePeer peer) async {
    final discovered = _discovered[peer.id];
    if (discovered == null) return peer;
    final existing = _connected[peer.id];
    if (existing != null) return existing.peer;

    status = 'Connecting to ${peer.name}';
    notifyListeners();
    await _central.connect(discovered.peripheral);
    if (Platform.isAndroid) {
      await _central
          .requestMTU(discovered.peripheral, mtu: 512)
          .catchError((_) => 0);
    }
    final services = await _central.discoverGATT(discovered.peripheral);
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
    if (inboxCharacteristic == null) {
      throw StateError('MeshChat BLE inbox characteristic was not found');
    }
    var updated = peer.copyWith(connected: true);
    if (infoCharacteristic != null) {
      final raw = await _central.readCharacteristic(
        discovered.peripheral,
        infoCharacteristic,
      );
      updated = _peerFromInfo(peer, raw).copyWith(connected: true);
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
    status = 'Connected to ${updated.displayNameOrName}';
    notifyListeners();
    return updated;
  }

  Future<void> sendPacket(BlePeer peer, Map<String, dynamic> packet) async {
    final connected =
        _connected[peer.id] ?? _connected[(await connect(peer)).id];
    if (connected == null) {
      throw StateError('Bluetooth peer is not connected');
    }
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
      await _central.writeCharacteristic(
        connected.peripheral,
        connected.inbox,
        value: Uint8List.fromList(frame),
        type: GATTCharacteristicWriteType.withResponse,
      );
    }
  }

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
          ),
          lastSeen: DateTime.now(),
        );
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
    final raw = jsonDecode(utf8.decode(value));
    if (raw is! Map) return;
    final id = raw['id']?.toString() ?? '';
    final index = int.tryParse(raw['i']?.toString() ?? '');
    final total = int.tryParse(raw['n']?.toString() ?? '');
    final data = raw['d']?.toString() ?? '';
    if (id.isEmpty || index == null || total == null || data.isEmpty) return;
    final incoming = _incoming.putIfAbsent(
      '$peerId:$id',
      () => _IncomingBlePacket(total),
    );
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

  @override
  void dispose() {
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
