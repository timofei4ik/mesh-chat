import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/app_settings.dart';
import '../services/chat_cache_store.dart';
import '../services/mesh_socket.dart';
import '../utils/mesh_page_route.dart';
import '../widgets/meshpro_gate.dart';
import '../widgets/profile_avatar.dart';
import 'bluetooth_nearby_page.dart';
import 'mesh_studio_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  void openStorage(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => StorageCachePage(controller: controller),
      ),
    );
  }

  void openAbout(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => AboutDiagnosticsPage(controller: controller),
      ),
    );
  }

  void openConnection(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => ConnectionStatusPage(controller: controller),
      ),
    );
  }

  void openActiveDevices(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => ActiveDevicesPage(controller: controller),
      ),
    );
  }

  void openBlockedUsers(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => BlockedUsersPage(controller: controller),
      ),
    );
  }

  void openSecurity(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(builder: (_) => SecurityPage(controller: controller)),
    );
  }

  void openBluetoothNearby(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => BluetoothNearbyPage(controller: controller),
      ),
    );
  }

  Future<void> openMeshStudio(BuildContext context) async {
    final allowed = await requireMeshPro(
      context,
      controller,
      featureId: 'profile_background',
      title: 'MeshStudio',
      description:
          'Create linked profile presets with live profile and message previews.',
    );
    if (!allowed || !context.mounted) return;
    await Navigator.push<bool>(
      context,
      meshPageRoute<bool>(
        builder: (_) => MeshStudioPage(controller: controller),
      ),
    );
  }

  Future<void> openMeshProPreferences(BuildContext context) async {
    final allowed = await requireMeshPro(
      context,
      controller,
      featureId: 'custom_quick_reactions',
      title: 'MeshPro calls & reactions',
      description:
          'Choose quick reactions and tune HD voice processing on every device.',
    );
    if (!allowed || !context.mounted) return;
    await Navigator.push<void>(
      context,
      meshPageRoute<void>(
        builder: (_) => MeshProPreferencesPage(controller: controller),
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
                leading: const Icon(
                  Icons.tune_rounded,
                  color: Color(0xFFA98BFF),
                ),
                title: const Text('MeshPro calls & reactions'),
                subtitle: const Text(
                  'Quick reactions, HD audio and noise suppression',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openMeshProPreferences(context),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFF8EDFFF),
                ),
                title: const Text('MeshStudio'),
                subtitle: Text(meshProRemainingLabel(controller)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openMeshStudio(context),
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
            _PrivacySettings(controller: controller),
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

class MeshProPreferencesPage extends StatefulWidget {
  const MeshProPreferencesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<MeshProPreferencesPage> createState() => _MeshProPreferencesPageState();
}

class _MeshProPreferencesPageState extends State<MeshProPreferencesPage> {
  late List<String> reactions;
  late bool hdAudio;
  late bool enhancedNoiseSuppression;
  bool saving = false;

  int get reactionLimit =>
      widget.controller.meshProSubscription.entitlements.limitFor(
        'quick_reactions',
      ) ??
      4;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.appSettings;
    reactions = [...settings.quickReactions];
    hdAudio = settings.meshProHdAudio;
    enhancedNoiseSuppression = settings.meshProEnhancedNoiseSuppression;
  }

  Future<void> editReaction(int? index) async {
    final input = TextEditingController(
      text: index == null ? '' : reactions[index],
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(index == null ? 'Add reaction' : 'Change reaction'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 16,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 34),
          decoration: const InputDecoration(
            hintText: 'Paste an emoji',
            helperText: 'One emoji or a short reaction',
          ),
        ),
        actions: [
          if (index != null)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Use'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!mounted || value == null) return;
    setState(() {
      if (index != null) reactions.removeAt(index);
      if (value.isNotEmpty && !reactions.contains(value)) {
        final insertAt = index == null
            ? reactions.length
            : index.clamp(0, reactions.length);
        reactions.insert(insertAt, value);
      }
    });
  }

  Future<void> save() async {
    if (saving) return;
    setState(() => saving = true);
    final error = await widget.controller.updateMeshProPreferences(
      quickReactions: reactions,
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
    );
    if (!mounted) return;
    setState(() => saving = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
    if (error == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls & reactions'),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : save,
            icon: saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick reactions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap a reaction to replace it. Long-press messages to use the set.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var index = 0; index < reactions.length; index++)
                        ActionChip(
                          avatar: Text(
                            reactions[index],
                            style: const TextStyle(fontSize: 20),
                          ),
                          label: Text('${index + 1}'),
                          onPressed: () => editReaction(index),
                        ),
                      if (reactions.length < reactionLimit)
                        ActionChip(
                          avatar: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add'),
                          onPressed: () => editReaction(null),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.graphic_eq_rounded),
                  title: const Text('HD call audio'),
                  subtitle: const Text(
                    '48 kHz Opus voice with a higher bitrate',
                  ),
                  value: hdAudio,
                  onChanged: (value) => setState(() => hdAudio = value),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.noise_control_off_rounded),
                  title: const Text('Enhanced noise suppression'),
                  subtitle: const Text(
                    'Typing-noise filtering and stronger echo processing',
                  ),
                  value: enhancedNoiseSuppression,
                  onChanged: (value) =>
                      setState(() => enhancedNoiseSuppression = value),
                ),
              ],
            ),
          ),
        ],
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

  Future<void> renameDevice(ActiveDevice device) async {
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'multi_device_plus',
      title: 'Device names',
      description: 'Give every signed-in device a recognizable name.',
    );
    if (!allowed || !mounted) return;
    final input = TextEditingController(
      text: device.deviceName.isNotEmpty
          ? device.deviceName
          : device.displayName,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 48,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    final error = await widget.controller.renameActiveDevice(device, name);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Device renamed')));
    if (error == null) refresh();
  }

  Future<void> revokeDevice(ActiveDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out this device?'),
        content: Text(
          '${device.deviceName.isNotEmpty ? device.deviceName : device.nodeId}\n\nIt will need the account password to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await widget.controller.revokeActiveDevice(device);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Device signed out')));
    if (error == null) refresh();
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
              final isCurrent = device.nodeId == widget.controller.myNodeId;
              return Card(
                child: ListTile(
                  leading: Icon(
                    device.online
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: device.online ? Colors.greenAccent : Colors.white38,
                  ),
                  title: Text(
                    device.deviceName.isNotEmpty
                        ? device.deviceName
                        : device.displayName.isEmpty
                        ? device.nodeId
                        : device.displayName,
                  ),
                  subtitle: Text(
                    '${isCurrent ? 'Current device · ' : ''}${device.revoked
                        ? 'Signed out'
                        : device.online
                        ? 'Online'
                        : 'Offline'}\n${device.appVersion.isEmpty ? 'unknown app' : device.appVersion}\n${device.nodeId}\nLast seen: ${device.lastSeen}',
                  ),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Device actions',
                    onSelected: (action) {
                      if (action == 'rename') {
                        renameDevice(device);
                      } else if (action == 'revoke') {
                        revokeDevice(device);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Rename'),
                        ),
                      ),
                      if (!isCurrent && !device.revoked)
                        const PopupMenuItem(
                          value: 'revoke',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.logout_rounded,
                              color: Colors.redAccent,
                            ),
                            title: Text(
                              'Sign out',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        ),
                    ],
                  ),
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
            title: const Text('Message send effects'),
            subtitle: const Text(
              'Play brief MeshPro effects on newly received messages',
            ),
            value: settings.messageEffectsEnabled,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(messageEffectsEnabled: value),
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

class _PrivacySettings extends StatelessWidget {
  const _PrivacySettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.appSettings;
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.lock_outline_rounded),
            title: Text('Privacy'),
            subtitle: Text('Online, profile, calls and group invites'),
          ),
          SwitchListTile(
            title: const Text('Show online'),
            subtitle: const Text('Hide your active status where possible'),
            value: settings.showOnline,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(showOnline: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Show avatar'),
            subtitle: const Text('Keep profile photo private when disabled'),
            value: settings.showAvatar,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(showAvatar: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Show about'),
            subtitle: const Text('Hide profile description when disabled'),
            value: settings.showAbout,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(showAbout: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Allow calls'),
            subtitle: const Text('Decline incoming calls automatically'),
            value: settings.allowCalls,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(allowCalls: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Allow group invites'),
            subtitle: const Text('Ignore new group/channel invites'),
            value: settings.allowGroupInvites,
            onChanged: (value) => controller.updateAppSettings(
              settings.copyWith(allowGroupInvites: value),
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

  Future<void> _confirmAccountDeletion(BuildContext context) async {
    final passwordController = TextEditingController();
    String? validationError;
    var busy = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete account permanently?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Messages, files, stories, devices and profile data will be removed from the server. Groups and channels you own will also be deleted. This cannot be undone.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                autofocus: true,
                obscureText: true,
                enabled: !busy,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Current password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  errorText: validationError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() {
                        busy = true;
                        validationError = null;
                      });
                      final error = await controller.deleteAccount(
                        passwordController.text,
                      );
                      if (!dialogContext.mounted) return;
                      if (error != null) {
                        setDialogState(() {
                          busy = false;
                          validationError = error;
                        });
                        return;
                      }
                      Navigator.pop(dialogContext);
                    },
              icon: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete permanently'),
            ),
          ],
        ),
      ),
    );
    passwordController.dispose();
  }

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
              leading: const Icon(Icons.mark_email_read_outlined),
              title: const Text('Two-factor email'),
              subtitle: Text(
                session?.email.isNotEmpty == true
                    ? session!.email
                    : 'Verified on the server',
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
                meshPageRoute<void>(
                  builder: (_) => ActiveDevicesPage(controller: controller),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('Change password'),
              subtitle: const Text(
                'Use this signed-in device and preserve encrypted history',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: session == null
                  ? null
                  : () => Navigator.push(
                      context,
                      meshPageRoute<void>(
                        builder: (_) =>
                            ChangePasswordPage(controller: controller),
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
                meshPageRoute<void>(
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
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete account',
                style: TextStyle(color: Colors.redAccent),
              ),
              subtitle: const Text('Permanently remove server data'),
              onTap: session == null
                  ? null
                  : () => _confirmAccountDeletion(context),
            ),
          ),
        ],
      ),
    );
  }
}

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final newPassword = TextEditingController();
  final confirmation = TextEditingController();
  bool obscureNew = true;
  bool obscureConfirmation = true;
  bool saving = false;
  String? validationError;

  @override
  void dispose() {
    newPassword.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (saving) return;
    final password = newPassword.text;
    if (password.length < 8) {
      setState(() => validationError = 'Use at least 8 characters');
      return;
    }
    if (password != confirmation.text) {
      setState(() => validationError = 'Passwords do not match');
      return;
    }
    setState(() {
      saving = true;
      validationError = null;
    });
    final result = await widget.controller.changePassword(password);
    if (!mounted) return;
    if (result != null) {
      setState(() {
        saving = false;
        validationError = result;
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password changed. Encrypted history was preserved.'),
      ),
    );
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Change password'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: ListTile(
              leading: Icon(Icons.enhanced_encryption_outlined),
              title: Text('Encrypted history stays available'),
              subtitle: Text(
                'This authorized device securely transfers your existing '
                'encryption identity to the new password. The old password '
                'is never displayed or sent as recovery data.',
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: newPassword,
            obscureText: obscureNew,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'New password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: obscureNew ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => obscureNew = !obscureNew),
                icon: Icon(
                  obscureNew
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: confirmation,
            obscureText: obscureConfirmation,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
              labelText: 'Confirm new password',
              prefixIcon: const Icon(Icons.lock_reset_rounded),
              suffixIcon: IconButton(
                tooltip: obscureConfirmation
                    ? 'Show password'
                    : 'Hide password',
                onPressed: () =>
                    setState(() => obscureConfirmation = !obscureConfirmation),
                icon: Icon(
                  obscureConfirmation
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          if (validationError != null) ...[
            const SizedBox(height: 12),
            Text(
              validationError!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: saving ? null : submit,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(saving ? 'Changing password...' : 'Change password'),
          ),
          const SizedBox(height: 12),
          Text(
            'Other signed-in devices will ask for the new password.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white60),
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
