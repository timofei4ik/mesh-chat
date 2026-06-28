import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/app_settings.dart';
import '../services/chat_cache_store.dart';
import '../services/mesh_socket.dart';
import '../widgets/profile_avatar.dart';
import 'bluetooth_nearby_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  void openStorage(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StorageCachePage(controller: controller),
      ),
    );
  }

  void openAbout(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AboutDiagnosticsPage(controller: controller),
      ),
    );
  }

  void openConnection(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConnectionStatusPage(controller: controller),
      ),
    );
  }

  void openActiveDevices(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ActiveDevicesPage(controller: controller),
      ),
    );
  }

  void openBlockedUsers(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BlockedUsersPage(controller: controller),
      ),
    );
  }

  void openSecurity(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SecurityPage(controller: controller)),
    );
  }

  void openBluetoothNearby(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BluetoothNearbyPage(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: const Color(0xFF07111E),
        cardTheme: CardThemeData(
          color: const Color(0xFF242D37).withValues(alpha: 0.76),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          margin: EdgeInsets.zero,
        ),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF07111E),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Settings'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(session?.login ?? 'No account'),
                subtitle: Text(session?.serverUrl ?? ''),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About / Diagnostics'),
                subtitle: const Text('Versions, protocol and server check'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openAbout(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.network_check),
                title: const Text('Connection'),
                subtitle: const Text(
                  'Server, protocol, login, sync and WebSocket',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openConnection(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Bluetooth Nearby'),
                subtitle: const Text('Text chat with nearby MeshChat devices'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openBluetoothNearby(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Storage / Cache'),
                subtitle: const Text(
                  'Local messages, media previews and drafts',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openStorage(context),
              ),
            ),
            const SizedBox(height: 12),
            _NotificationSettings(controller: controller),
            const SizedBox(height: 12),
            _ThemeSettings(controller: controller),
            const SizedBox(height: 12),
            _MediaSettings(controller: controller),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.block_outlined),
                title: const Text('Blocked users'),
                subtitle: Text(
                  controller.appSettings.blockedNodeIds.isEmpty
                      ? 'No blocked users'
                      : '${controller.appSettings.blockedNodeIds.length} blocked',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openBlockedUsers(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.devices_outlined),
                title: const Text('Active devices'),
                subtitle: const Text('Devices recently used with this account'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openActiveDevices(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.security_outlined),
                title: const Text('Security'),
                subtitle: const Text('Device ID, active devices and blocks'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openSecurity(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BlockedUsersPage extends StatelessWidget {
  const BlockedUsersPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final blocked = controller.appSettings.blockedNodeIds;
        return Scaffold(
          appBar: AppBar(title: const Text('Blocked users')),
          body: blocked.isEmpty
              ? const Center(child: Text('No blocked users'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: blocked.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final nodeId = blocked[index];
                    final profile = controller.profiles[nodeId];
                    return Card(
                      child: ListTile(
                        leading: profile == null
                            ? const CircleAvatar(child: Icon(Icons.person))
                            : ProfileAvatar(profile: profile),
                        title: Text(
                          profile?.displayName ??
                              (nodeId.length > 8
                                  ? nodeId.substring(0, 8)
                                  : nodeId),
                        ),
                        subtitle: Text(
                          profile?.publicUsername.isNotEmpty == true
                              ? '@${profile!.publicUsername}'
                              : nodeId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () => controller.toggleBlocked(nodeId),
                          child: const Text('Unblock'),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class AboutDiagnosticsPage extends StatefulWidget {
  const AboutDiagnosticsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<AboutDiagnosticsPage> createState() => _AboutDiagnosticsPageState();
}

class _AboutDiagnosticsPageState extends State<AboutDiagnosticsPage> {
  Future<ConnectionDiagnostics>? diagnosticsFuture;

  void runDiagnostics() {
    setState(() {
      diagnosticsFuture = widget.controller.diagnoseConnection();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.controller.session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('About / Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Run diagnostics',
            onPressed: runDiagnostics,
            icon: const Icon(Icons.network_check),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                const _InfoTile(
                  icon: Icons.apps_outlined,
                  title: 'Client',
                  value: MeshSocket.appVersion,
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.schema_outlined,
                  title: 'Protocol',
                  value: MeshSocket.protocolRange(),
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.dns_outlined,
                  title: 'Server',
                  value: session?.serverUrl ?? 'none',
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.person_outline,
                  title: 'Login',
                  value: session?.login ?? 'none',
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.alternate_email,
                  title: 'Username',
                  value: session?.publicUsername.isEmpty == false
                      ? '@${session!.publicUsername}'
                      : 'none',
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.fingerprint,
                  title: 'Node ID',
                  value: session?.nodeId ?? 'none',
                  selectable: true,
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.circle_outlined,
                  title: 'Current status',
                  value: widget.controller.status,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: runDiagnostics,
            icon: const Icon(Icons.network_check),
            label: const Text('Run server diagnostics'),
          ),
          const SizedBox(height: 12),
          if (diagnosticsFuture != null)
            FutureBuilder<ConnectionDiagnostics>(
              future: diagnosticsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                final result = snapshot.data;
                return Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          result?.ok == true
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: result?.ok == true
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                        title: Text(result?.message ?? 'No result'),
                        subtitle: Text(
                          'Latency: ${result?.latency.inMilliseconds ?? 0} ms',
                        ),
                      ),
                      const Divider(height: 1),
                      _InfoTile(
                        icon: Icons.cloud_outlined,
                        title: 'Server version',
                        value: result?.serverVersion ?? 'unknown',
                      ),
                      const Divider(height: 1),
                      _InfoTile(
                        icon: Icons.schema_outlined,
                        title: 'Server protocol',
                        value: result?.serverProtocolRange ?? '?',
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class StorageCachePage extends StatefulWidget {
  const StorageCachePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<StorageCachePage> createState() => _StorageCachePageState();
}

class ConnectionStatusPage extends StatefulWidget {
  const ConnectionStatusPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConnectionStatusPage> createState() => _ConnectionStatusPageState();
}

class _ConnectionStatusPageState extends State<ConnectionStatusPage> {
  Future<ConnectionDiagnostics>? diagnosticsFuture;

  void run() {
    setState(() {
      diagnosticsFuture = widget.controller.diagnoseConnection();
    });
  }

  @override
  void initState() {
    super.initState();
    diagnosticsFuture = widget.controller.diagnoseConnection();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection'),
        actions: [
          IconButton(
            tooltip: 'Check',
            onPressed: run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<ConnectionDiagnostics>(
        future: diagnosticsFuture,
        builder: (context, snapshot) {
          final result = snapshot.data;
          final waiting = snapshot.connectionState != ConnectionState.done;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _CheckTile(
                title: 'Server reachable',
                ok: waiting ? null : result?.ok,
                subtitle: waiting ? 'Checking...' : result?.message ?? '',
              ),
              _CheckTile(
                title: 'Protocol compatible',
                ok: waiting ? null : result?.ok,
                subtitle:
                    'Client ${MeshSocket.protocolRange()}, server ${result?.serverProtocolRange ?? '?'}',
              ),
              _CheckTile(
                title: 'Login accepted',
                ok: waiting ? null : result?.ok,
                subtitle: widget.controller.session?.login ?? 'No session',
              ),
              _CheckTile(
                title: 'Sync received',
                ok: widget.controller.lastSyncAt != null,
                subtitle: widget.controller.lastSyncAt == null
                    ? 'No sync yet'
                    : widget.controller.lastSyncAt!.toLocal().toString(),
              ),
              _CheckTile(
                title: 'WebSocket live',
                ok: widget.controller.websocketLive,
                subtitle: widget.controller.status,
              ),
              FilledButton.icon(
                onPressed: () async {
                  await widget.controller.forceResync();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Resync requested')),
                  );
                  run();
                },
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Force resync'),
              ),
              const SizedBox(height: 12),
              if (result != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.speed_outlined),
                    title: const Text('Latency'),
                    trailing: Text('${result.latency.inMilliseconds} ms'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class ActiveDevicesPage extends StatefulWidget {
  const ActiveDevicesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ActiveDevicesPage> createState() => _ActiveDevicesPageState();
}

class _ActiveDevicesPageState extends State<ActiveDevicesPage> {
  late Future<List<ActiveDevice>> devicesFuture;

  @override
  void initState() {
    super.initState();
    devicesFuture = widget.controller.loadActiveDevices();
  }

  void refresh() {
    setState(() {
      devicesFuture = widget.controller.loadActiveDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<ActiveDevice>>(
        future: devicesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final devices = snapshot.data ?? const [];
          if (devices.isEmpty) {
            return const Center(child: Text('No devices yet'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final device = devices[index];
              return Card(
                child: ListTile(
                  leading: Icon(
                    device.online
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: device.online ? Colors.greenAccent : Colors.white38,
                  ),
                  title: Text(
                    device.displayName.isEmpty
                        ? device.nodeId
                        : device.displayName,
                  ),
                  subtitle: Text(
                    '${device.appVersion.isEmpty ? 'unknown app' : device.appVersion}\n${device.nodeId}\nLast seen: ${device.lastSeen}',
                  ),
                  isThreeLine: true,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StorageCachePageState extends State<StorageCachePage> {
  late Future<CacheStats> statsFuture;

  @override
  void initState() {
    super.initState();
    statsFuture = widget.controller.cacheStats();
  }

  void refresh() {
    setState(() {
      statsFuture = widget.controller.cacheStats();
    });
  }

  Future<void> clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear local cache?'),
        content: const Text(
          'This removes cached chats on this device. The server account and server history are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.clearLocalCache();
    if (!mounted) return;
    refresh();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Local cache cleared')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage / Cache'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<CacheStats>(
        future: statsFuture,
        builder: (context, snapshot) {
          final stats = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Column(
                  children: [
                    _StatTile(
                      icon: Icons.sd_storage_outlined,
                      title: 'Cache size',
                      value: _formatBytes(stats?.bytes ?? 0),
                    ),
                    const Divider(height: 1),
                    _StatTile(
                      icon: Icons.chat_bubble_outline,
                      title: 'Cached chats',
                      value: '${stats?.threads ?? 0}',
                    ),
                    const Divider(height: 1),
                    _StatTile(
                      icon: Icons.message_outlined,
                      title: 'Cached messages',
                      value: '${stats?.messages ?? 0}',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text('Clear local cache'),
                  subtitle: const Text(
                    'The next login will sync history again',
                  ),
                  onTap: clearCache,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Text(value, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _NotificationSettings extends StatelessWidget {
  const _NotificationSettings({required this.controller});

  final AppController controller;

  void save(AppSettings settings) {
    controller.updateAppSettings(settings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = controller.appSettings;
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.notifications_outlined),
            title: Text('Notifications'),
          ),
          SwitchListTile(
            title: const Text('Enabled'),
            value: settings.notificationsEnabled,
            onChanged: (value) {
              if (value) {
                controller.requestNotificationPermissions();
              }
              save(settings.copyWith(notificationsEnabled: value));
            },
          ),
          SwitchListTile(
            title: const Text('Sound'),
            value: settings.notificationSound,
            onChanged: settings.notificationsEnabled
                ? (value) => save(settings.copyWith(notificationSound: value))
                : null,
          ),
          SwitchListTile(
            title: const Text('Vibration'),
            value: settings.notificationVibration,
            onChanged: settings.notificationsEnabled
                ? (value) =>
                      save(settings.copyWith(notificationVibration: value))
                : null,
          ),
          SwitchListTile(
            title: const Text('Message preview'),
            subtitle: const Text('Show message text in notifications'),
            value: settings.notificationPreview,
            onChanged: settings.notificationsEnabled
                ? (value) => save(settings.copyWith(notificationPreview: value))
                : null,
          ),
        ],
      ),
    );
  }
}

class _ThemeSettings extends StatelessWidget {
  const _ThemeSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.appSettings;
    const accents = [
      Color(0xFF42A5F5),
      Color(0xFF2EAD68),
      Color(0xFFE85D75),
      Color(0xFFFFB020),
      Color(0xFF9B6DFF),
    ];
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.palette_outlined),
            title: Text('Theme'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (value) => controller.updateAppSettings(
                  settings.copyWith(themeMode: value.first),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                const Text('Accent'),
                const Spacer(),
                for (final color in accents)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => controller.updateAppSettings(
                        settings.copyWith(accentColor: color),
                      ),
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: color,
                        child:
                            settings.accentColor.toARGB32() == color.toARGB32()
                            ? const Icon(Icons.check, size: 16)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaSettings extends StatelessWidget {
  const _MediaSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.appSettings;
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.photo_library_outlined),
            title: Text('Files and photos'),
          ),
          SwitchListTile(
            title: const Text('Data saver'),
            subtitle: const Text(
              'Skip heavy previews and reduce cache pressure',
            ),
            value: settings.dataSaver,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(dataSaver: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Reduced animations'),
            subtitle: const Text('Keep the glass UI, but pause glow effects'),
            value: settings.reducedAnimations,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(reducedAnimations: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Compress photos by default'),
            subtitle: const Text('Keeps original files when disabled'),
            value: settings.compressPhotos,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(compressPhotos: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Send files as original'),
            subtitle: const Text('Do not alter non-photo files'),
            value: settings.sendFilesOriginal,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(sendFilesOriginal: value),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({
    required this.title,
    required this.ok,
    required this.subtitle,
  });

  final String title;
  final bool? ok;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final icon = ok == null
        ? Icons.hourglass_empty
        : ok == true
        ? Icons.check_circle_outline
        : Icons.error_outline;
    final color = ok == null
        ? Colors.orangeAccent
        : ok == true
        ? Colors.greenAccent
        : Colors.redAccent;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}

class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Security'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Device node ID'),
              subtitle: Text(
                controller.myNodeId.isEmpty ? 'Missing' : controller.myNodeId,
              ),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: controller.myNodeId.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(
                          ClipboardData(text: controller.myNodeId),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Node ID copied')),
                        );
                      },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: const Text('Username'),
              subtitle: Text(
                session?.publicUsername.isNotEmpty == true
                    ? '@${session!.publicUsername}'
                    : 'Not set',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server'),
              subtitle: Text(session?.serverUrl ?? 'No session'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: const Text('Active devices'),
              subtitle: const Text('Open device list from Settings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ActiveDevicesPage(controller: controller),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('Blocked users'),
              subtitle: Text(
                controller.appSettings.blockedNodeIds.isEmpty
                    ? 'No blocked users'
                    : '${controller.appSettings.blockedNodeIds.length} blocked',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BlockedUsersPage(controller: controller),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: ListTile(
              leading: Icon(Icons.lock_outline_rounded),
              title: Text('Encryption'),
              subtitle: Text(
                'Text and media are encrypted before sending. Keep your account password private.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
    this.selectable = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      value,
      textAlign: TextAlign.end,
      overflow: TextOverflow.ellipsis,
      maxLines: 2,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
    );
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: SizedBox(
        width: 190,
        child: selectable
            ? SelectableText(
                value,
                textAlign: TextAlign.end,
                maxLines: 2,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              )
            : text,
      ),
    );
  }
}
