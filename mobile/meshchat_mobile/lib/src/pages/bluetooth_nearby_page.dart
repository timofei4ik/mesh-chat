import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/ble_chat_service.dart';

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

  Future<void> connect(BlePeer peer) async {
    setState(() => busy = true);
    try {
      await widget.controller.ble.connect(peer);
    } catch (error) {
      if (mounted) _showSnack('Bluetooth connect failed: $error');
    }
    if (!mounted) return;
    setState(() => busy = false);
  }

  Future<void> send(BlePeer peer) async {
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(peer.displayName.isEmpty ? peer.name : peer.displayName),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Message over Bluetooth',
            prefixIcon: Icon(Icons.bluetooth),
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
    if (text == null || text.trim().isEmpty) return;
    setState(() => busy = true);
    final error = await widget.controller.sendBluetoothMessage(peer, text);
    if (!mounted) return;
    setState(() => busy = false);
    _showSnack(error ?? 'Sent over Bluetooth');
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
                      trailing: Switch(
                        value: service.running,
                        onChanged: busy
                            ? null
                            : (value) => value ? start() : stop(),
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
                        ? 'Wide scan is active. Non-MeshChat BLE devices may appear; Connect will filter them.'
                        : 'Text-only BLE MVP. Keep both apps open and nearby. Files and groups will be added after device tests.',
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
                            if (peer.publicUsername.isNotEmpty)
                              '@${peer.publicUsername}',
                            if (peer.nodeId.isNotEmpty) peer.nodeId,
                            'RSSI ${peer.rssi}',
                          ].join('\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: FilledButton.tonalIcon(
                          onPressed: busy
                              ? null
                              : () =>
                                    peer.connected ? send(peer) : connect(peer),
                          icon: Icon(
                            peer.connected
                                ? Icons.send_outlined
                                : Icons.link_outlined,
                          ),
                          label: Text(peer.connected ? 'Send' : 'Connect'),
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
}
