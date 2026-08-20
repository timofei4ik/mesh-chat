import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controllers/app_controller.dart';
import '../services/ble_chat_service.dart';
import '../utils/mesh_page_route.dart';
import '../widgets/mesh_settings_surface.dart';
import 'chat_page.dart';

class BluetoothNearbyPage extends StatefulWidget {
  const BluetoothNearbyPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<BluetoothNearbyPage> createState() => _BluetoothNearbyPageState();
}

class _BluetoothNearbyPageState extends State<BluetoothNearbyPage> {
  bool busy = false;

  Future<void> start() async {
    setState(() => busy = true);
    final error = await widget.controller.startBluetoothNearby();
    if (!mounted) return;
    setState(() => busy = false);
    if (error != null) _showSnack(error);
  }

  Future<void> stop() async {
    setState(() => busy = true);
    await widget.controller.stopBluetoothNearby();
    if (!mounted) return;
    setState(() => busy = false);
  }

  Future<void> scan() async {
    final service = widget.controller.ble;
    if (service.scanning) {
      await service.stopScan();
    } else {
      try {
        await service.startScan();
      } catch (error) {
        if (mounted) _showSnack('Bluetooth scan failed: $error');
      }
    }
  }

  Future<void> wideScan() async {
    final service = widget.controller.ble;
    if (service.scanning) {
      await service.stopScan();
    }
    try {
      await service.startWideScan();
    } catch (error) {
      if (mounted) _showSnack('Bluetooth wide scan failed: $error');
    }
  }

  Future<void> refreshScan() async {
    try {
      await widget.controller.ble.refreshScan();
    } catch (error) {
      if (mounted) _showSnack('Bluetooth refresh failed: $error');
    }
  }

  Future<void> disconnect(BlePeer peer) async {
    setState(() => busy = true);
    await widget.controller.ble.disconnect(peer);
    if (!mounted) return;
    setState(() => busy = false);
  }

  Future<void> sendFile(BlePeer peer) async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    if (bytes.length > AppController.maxBluetoothFileBytes) {
      _showSnack('Bluetooth files are limited to 512 KB');
      return;
    }
    final caption = await _askCaption(file.name);
    if (caption == null) return;
    setState(() => busy = true);
    final error = await widget.controller.sendBluetoothFile(
      peer,
      file.name,
      bytes,
      caption: caption,
    );
    if (!mounted) return;
    setState(() => busy = false);
    _showSnack(error ?? 'File sent over Bluetooth');
  }

  Future<String?> _askCaption(String filename) async {
    final input = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(filename),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Caption',
            prefixIcon: Icon(Icons.notes_outlined),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    input.dispose();
    return result;
  }

  Future<void> showPairQr() async {
    final profile = widget.controller.ownProfile;
    final data = jsonEncode({
      'app': 'MeshChat',
      'pair_protocol': 1,
      'node_id': profile.nodeId,
      'display_name': profile.displayName,
      'public_username': profile.publicUsername,
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bluetooth pair code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              profile.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (profile.publicUsername.isNotEmpty)
              Text('@${profile.publicUsername}'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: data));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> scanPairQr() async {
    final raw = await Navigator.push<String>(
      context,
      meshSettingsPageRoute<String>(
        builder: (_) =>
            const MeshSettingsSurface(child: _BluetoothQrScannerPage()),
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['app'] != 'MeshChat') {
        _showSnack('This is not a MeshChat pairing QR');
        return;
      }
      final nodeId = decoded['node_id']?.toString() ?? '';
      if (nodeId.isEmpty) {
        _showSnack('Pairing QR does not contain node id');
        return;
      }
      widget.controller.ble.addPairingTarget(nodeId);
      if (!widget.controller.ble.running) {
        await start();
      } else if (!widget.controller.ble.scanning) {
        await widget.controller.ble.startScan();
      }
      _showSnack('Bluetooth pairing target added');
    } catch (error) {
      _showSnack('Could not read pairing QR: $error');
    }
  }

  Future<void> openPeerChat(BlePeer peer) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final thread = await widget.controller.connectBluetoothThread(peer);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ChatPage(controller: widget.controller, thread: thread),
        ),
      );
    } catch (error) {
      if (mounted) _showSnack('Bluetooth connect failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.controller.ble;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Bluetooth Nearby'),
            actions: [
              IconButton(
                tooltip: 'Clear stale devices',
                onPressed: busy ? null : service.clearPeers,
                icon: const Icon(Icons.clear_all),
              ),
              IconButton(
                tooltip: 'Refresh scan',
                onPressed: busy || !service.running ? null : refreshScan,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Pair QR',
                onPressed: busy ? null : showPairQr,
                icon: const Icon(Icons.qr_code_2),
              ),
              if (!kIsWeb)
                IconButton(
                  tooltip: 'Scan QR',
                  onPressed: busy ? null : scanPairQr,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              IconButton(
                tooltip: 'Wide scan',
                onPressed: busy ? null : wideScan,
                icon: const Icon(Icons.travel_explore_outlined),
              ),
              IconButton(
                tooltip: service.scanning ? 'Stop scan' : 'Scan',
                onPressed: busy ? null : scan,
                icon: Icon(
                  service.scanning
                      ? Icons.bluetooth_searching
                      : Icons.radar_outlined,
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        service.running
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth_disabled,
                        color: service.running
                            ? Colors.lightBlueAccent
                            : Colors.white54,
                      ),
                      title: Text(
                        service.running ? 'Bluetooth enabled' : 'Bluetooth off',
                      ),
                      subtitle: Text(service.status),
                      isThreeLine: service.queuedCount > 0,
                      titleTextStyle: Theme.of(context).textTheme.titleMedium,
                      trailing: Switch(
                        value: service.running,
                        onChanged: busy
                            ? null
                            : (value) => value ? start() : stop(),
                      ),
                    ),
                    if (service.queuedCount > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Chip(
                            avatar: const Icon(Icons.schedule_send, size: 18),
                            label: Text('${service.queuedCount} queued'),
                          ),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Mode'),
                  subtitle: Text(
                    service.wideScanning
                        ? 'Wide scan is active. It helps Windows see iPhone, but unrelated BLE devices can appear.'
                        : 'Nearby text chat over Bluetooth. Keep both apps open, Bluetooth enabled, and devices close.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (service.peers.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('No MeshChat devices found')),
                  ),
                )
              else
                ...service.peers.map(
                  (peer) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                          peer.connected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth,
                          color: peer.connected
                              ? Colors.lightBlueAccent
                              : Colors.white60,
                        ),
                        title: Text(
                          peer.displayName.isEmpty
                              ? peer.name
                              : peer.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            peer.connected ? 'Connected' : _lastSeenText(peer),
                            if (peer.publicUsername.isNotEmpty)
                              '@${peer.publicUsername}',
                            if (peer.nodeId.isNotEmpty) peer.nodeId,
                            'RSSI ${peer.rssi}',
                          ].join('\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            Icon(_signalIcon(peer.rssi), color: Colors.white54),
                            FilledButton.tonalIcon(
                              onPressed: busy ? null : () => openPeerChat(peer),
                              icon: Icon(
                                peer.connected
                                    ? Icons.send_outlined
                                    : Icons.link_outlined,
                              ),
                              label: Text(peer.connected ? 'Chat' : 'Connect'),
                            ),
                            if (peer.connected)
                              IconButton(
                                tooltip: 'Send file',
                                onPressed: busy ? null : () => sendFile(peer),
                                icon: const Icon(Icons.attach_file),
                              ),
                            if (peer.connected)
                              IconButton(
                                tooltip: 'Disconnect',
                                onPressed: busy ? null : () => disconnect(peer),
                                icon: const Icon(Icons.link_off),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -60) return Icons.network_wifi_3_bar;
    if (rssi >= -75) return Icons.network_wifi_2_bar;
    return Icons.network_wifi_1_bar;
  }

  String _lastSeenText(BlePeer peer) {
    final lastSeen = peer.lastSeen;
    if (lastSeen == null) return 'Seen recently';
    final seconds = DateTime.now().difference(lastSeen).inSeconds;
    if (seconds < 4) return 'Seen now';
    return 'Seen ${seconds}s ago';
  }
}

class _BluetoothQrScannerPage extends StatefulWidget {
  const _BluetoothQrScannerPage();

  @override
  State<_BluetoothQrScannerPage> createState() =>
      _BluetoothQrScannerPageState();
}

class _BluetoothQrScannerPageState extends State<_BluetoothQrScannerPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Bluetooth QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (done) return;
          final raw = capture.barcodes
              .map((barcode) => barcode.rawValue)
              .whereType<String>()
              .firstOrNull;
          if (raw == null || raw.isEmpty) return;
          done = true;
          Navigator.pop(context, raw);
        },
      ),
    );
  }
}
