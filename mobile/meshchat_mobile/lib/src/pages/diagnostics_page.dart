import 'dart:ui';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/chat_cache_store.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late Future<CacheStats> statsFuture;

  @override
  void initState() {
    super.initState();
    statsFuture = widget.controller.cacheStats();
  }

  Future<void> refresh() async {
    await widget.controller.handleAppResumed();
    if (!mounted) return;
    setState(() => statsFuture = widget.controller.cacheStats());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      appBar: AppBar(
        title: const Text('Diagnostics'),
        backgroundColor: Colors.transparent,
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final session = controller.session;
          final call = controller.activeCall;
          final ble = controller.ble;
          final connectedBle = ble.peers.where((peer) => peer.connected).length;
          return RefreshIndicator(
            color: Colors.lightBlueAccent,
            backgroundColor: const Color(0xFF111B2A),
            onRefresh: refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
              children: [
                _DiagCard(
                  title: 'Server',
                  children: [
                    _DiagRow(
                      label: 'Address',
                      value: session?.serverUrl ?? 'No session',
                      ok: session != null,
                    ),
                    _DiagRow(
                      label: 'WebSocket',
                      value: controller.websocketLive
                          ? 'Alive'
                          : 'Disconnected',
                      ok: controller.websocketLive,
                    ),
                    _DiagRow(
                      label: 'Status',
                      value: controller.status,
                      ok: controller.status.toLowerCase().contains('online'),
                    ),
                    _DiagRow(
                      label: 'Last sync',
                      value: controller.lastSyncAt == null
                          ? 'Not received'
                          : _formatDate(controller.lastSyncAt!),
                      ok: controller.lastSyncAt != null,
                    ),
                  ],
                ),
                _DiagCard(
                  title: 'Account',
                  children: [
                    _DiagRow(
                      label: 'Login',
                      value: session?.login ?? 'No session',
                      ok: session != null,
                    ),
                    _DiagRow(
                      label: 'Username',
                      value: session?.publicUsername.isNotEmpty == true
                          ? '@${session!.publicUsername}'
                          : 'Not set',
                      ok: session?.publicUsername.isNotEmpty == true,
                    ),
                    _DiagRow(
                      label: 'Node ID',
                      value: controller.myNodeId.isEmpty
                          ? 'Missing'
                          : controller.myNodeId,
                      ok: controller.myNodeId.isNotEmpty,
                    ),
                  ],
                ),
                _DiagCard(
                  title: 'Data',
                  children: [
                    _DiagRow(
                      label: 'Chats',
                      value:
                          '${controller.sortedThreads.length} visible, ${controller.archivedThreads.length} archived',
                      ok: true,
                    ),
                    _DiagRow(
                      label: 'Groups',
                      value: '${controller.groups.length}',
                      ok: true,
                    ),
                    FutureBuilder<CacheStats>(
                      future: statsFuture,
                      builder: (context, snapshot) {
                        final stats = snapshot.data;
                        return Column(
                          children: [
                            _DiagRow(
                              label: 'Cached threads',
                              value: stats == null
                                  ? 'Loading'
                                  : '${stats.threads}',
                              ok: stats != null,
                            ),
                            _DiagRow(
                              label: 'Cached messages',
                              value: stats == null
                                  ? 'Loading'
                                  : '${stats.messages}',
                              ok: stats != null,
                            ),
                            _DiagRow(
                              label: 'Cache size',
                              value: stats == null
                                  ? 'Loading'
                                  : _formatBytes(stats.bytes),
                              ok: stats != null,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
                _DiagCard(
                  title: 'Bluetooth',
                  children: [
                    _DiagRow(
                      label: 'State',
                      value: ble.running ? 'Running' : 'Stopped',
                      ok: ble.running,
                    ),
                    _DiagRow(
                      label: 'Nearby',
                      value: '${ble.peers.length}',
                      ok: ble.peers.isNotEmpty,
                    ),
                    _DiagRow(
                      label: 'Connected',
                      value: '$connectedBle',
                      ok: connectedBle > 0,
                    ),
                    _DiagRow(label: 'Details', value: ble.status, ok: true),
                  ],
                ),
                _DiagCard(
                  title: 'Calls',
                  children: [
                    _DiagRow(
                      label: 'Current call',
                      value: call == null ? 'None' : call.peer.displayName,
                      ok: call != null,
                    ),
                    _DiagRow(
                      label: 'State',
                      value: call == null ? 'Idle' : call.status.name,
                      ok: call?.status == CallStatus.active,
                    ),
                    _DiagRow(
                      label: 'Quality',
                      value: controller.callQualityLabel.isEmpty
                          ? 'No call'
                          : controller.callQualityLabel,
                      ok: call?.quality == 2,
                    ),
                    _DiagRow(
                      label: 'Participants',
                      value: controller.callParticipantsLabel.isEmpty
                          ? 'No group call'
                          : controller.callParticipantsLabel,
                      ok: true,
                    ),
                  ],
                ),
                _DiagCard(
                  title: 'Recent events',
                  children: controller.diagnostics.isEmpty
                      ? const [
                          _DiagRow(
                            label: 'Log',
                            value: 'No events yet',
                            ok: true,
                          ),
                        ]
                      : [
                          for (final event in controller.diagnostics.take(12))
                            _DiagRow(
                              label: event.area,
                              value:
                                  '${_formatDate(event.time)}  ${event.message}',
                              ok: true,
                            ),
                        ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Run quick check'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    final s = value.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _DiagCard extends StatelessWidget {
  const _DiagCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.075),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({required this.label, required this.value, required this.ok});

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.greenAccent : Colors.orangeAccent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 10),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
