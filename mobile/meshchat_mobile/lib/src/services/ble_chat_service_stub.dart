import 'package:flutter/foundation.dart';

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
}

class BleChatService extends ChangeNotifier {
  BlePacketHandler? onPacket;

  bool get supported => false;
  bool get running => false;
  bool get scanning => false;
  String get status => 'Bluetooth is not available in the web version';
  List<BlePeer> get peers => const [];

  Future<void> start({required Profile profile, required String publicKey}) {
    throw UnsupportedError('Bluetooth is not available in the web version');
  }

  Future<void> stop() async {}
  Future<void> startScan() async {}
  Future<void> stopScan() async {}

  Future<BlePeer> connect(BlePeer peer) {
    throw UnsupportedError('Bluetooth is not available in the web version');
  }

  Future<void> sendPacket(BlePeer peer, Map<String, dynamic> packet) {
    throw UnsupportedError('Bluetooth is not available in the web version');
  }
}
