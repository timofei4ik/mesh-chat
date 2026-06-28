import 'dart:convert';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';
import 'chat_media_page.dart';
import 'profile_page.dart';

class GroupInfoPage extends StatelessWidget {
  const GroupInfoPage({
    super.key,
    required this.controller,
    required this.thread,
  });

  final AppController controller;
  final ChatThread thread;

  Future<void> addMember(BuildContext context) async {
    final input = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add member'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '@username',
            prefixIcon: Icon(Icons.alternate_email),
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
            child: const Text('Add'),
          ),
        ],
      ),
    );
    input.dispose();
    if (username == null || username.trim().isEmpty || !context.mounted) {
      return;
    }

    final profile = await controller.lookupUsername(username);
    if (!context.mounted) return;
    if (profile == null) {
      _showSnack(context, 'User not found');
      return;
    }
    if (thread.members.contains(profile.nodeId)) {
      _showSnack(context, 'Already in group');
      return;
    }

    final error = await controller.updateGroupMembers(thread, [
      ...thread.members,
      profile.nodeId,
    ], rotateKey: true);
    if (!context.mounted) return;
    _showSnack(context, error ?? 'Member added');
  }

  Future<void> removeMember(BuildContext context, Profile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text(profile.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final error = await controller.updateGroupMembers(
      thread,
      thread.members.where((nodeId) => nodeId != profile.nodeId).toList(),
      rotateKey: true,
    );
    if (!context.mounted) return;
    _showSnack(context, error ?? 'Member removed');
  }

  void openProfile(BuildContext context, Profile profile) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfilePage(profile: profile)),
    );
  }

  void openMedia(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatMediaPage(thread: thread)),
    );
  }

  Future<void> toggleAdmin(BuildContext context, Profile profile) async {
    final error = await controller.toggleGroupAdmin(thread, profile.nodeId);
    if (!context.mounted) return;
    _showSnack(context, error ?? 'Role updated');
  }

  Future<void> startGroupCall(BuildContext context) async {
    final error = await controller.startGroupCall(thread);
    if (!context.mounted) return;
    if (error != null) _showSnack(context, error);
  }

  Future<void> editGroupProfile(BuildContext context) async {
    var avatarData = thread.profile.avatarData;
    final nameInput = TextEditingController(text: thread.profile.displayName);
    final aboutInput = TextEditingController(text: thread.profile.about);
    final error = await showDialog<String?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit group'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () async {
                    final picked = await FilePicker.platform.pickFiles(
                      type: FileType.image,
                      withData: true,
                    );
                    final bytes = picked?.files.single.bytes;
                    if (bytes == null) return;
                    setDialogState(() => avatarData = base64Encode(bytes));
                  },
                  child: ProfileAvatar(
                    profile: thread.profile.copyWith(avatarData: avatarData),
                    radius: 46,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameInput,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: aboutInput,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final result = await controller.updateGroupProfile(
                  thread,
                  name: nameInput.text,
                  about: aboutInput.text,
                  avatarData: avatarData,
                );
                if (context.mounted) Navigator.pop(context, result ?? '');
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameInput.dispose();
    aboutInput.dispose();
    if (!context.mounted || error == null) return;
    _showSnack(context, error.isEmpty ? 'Group updated' : error);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final members = thread.members
            .where((nodeId) => nodeId.isNotEmpty)
            .toSet()
            .toList();
        members.sort((a, b) {
          final aName = _profileFor(a).displayName.toLowerCase();
          final bName = _profileFor(b).displayName.toLowerCase();
          return aName.compareTo(bName);
        });
        final isOwner =
            thread.ownerNode.isEmpty || thread.ownerNode == controller.myNodeId;

        return Scaffold(
          backgroundColor: const Color(0xFF07111E),
          appBar: AppBar(
            backgroundColor: const Color(0xFF07111E),
            title: const Text('Group info'),
            actions: [
              IconButton(
                tooltip: 'Edit group',
                onPressed: isOwner ? () => editGroupProfile(context) : null,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 34),
            children: [
              _GroupGlassSurface(
                radius: 30,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
                  child: Column(
                    children: [
                      ProfileAvatar(profile: thread.profile, radius: 68),
                      const SizedBox(height: 16),
                      Text(
                        thread.profile.displayName,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${members.length} members',
                        style: const TextStyle(color: Colors.white60),
                      ),
                      if (thread.profile.about.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          thread.profile.about,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _GroupActionButton(
                            icon: Icons.call_outlined,
                            label: 'Call',
                            onTap: () => startGroupCall(context),
                          ),
                          _GroupActionButton(
                            icon: Icons.perm_media_outlined,
                            label: 'Media',
                            onTap: () => openMedia(context),
                          ),
                          _GroupActionButton(
                            icon: Icons.person_add_alt_1_outlined,
                            label: 'Add',
                            onTap: isOwner ? () => addMember(context) : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _GroupGlassSurface(
                radius: 22,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Roles',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      SizedBox(height: 8),
                      Text('Owner: can add/remove members and admins.'),
                      Text('Admin: marked in the member list.'),
                      Text('Member: can read and send messages.'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'Members',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 10),
              if (members.isEmpty)
                const Text(
                  'Member list is not loaded yet',
                  style: TextStyle(color: Colors.white54),
                )
              else
                ...members.map((nodeId) {
                  final profile = _profileFor(nodeId);
                  final role = _roleFor(nodeId);
                  final canRemove =
                      isOwner &&
                      nodeId != controller.myNodeId &&
                      nodeId != thread.ownerNode;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _GroupGlassSurface(
                      radius: 20,
                      child: ListTile(
                        leading: ProfileAvatar(profile: profile),
                        title: Text(
                          nodeId == controller.myNodeId
                              ? '${profile.displayName} (you)'
                              : profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (profile.publicUsername.isNotEmpty)
                              '@${profile.publicUsername}',
                            if (role.isNotEmpty) role,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (profile.online)
                              const Icon(
                                Icons.circle,
                                size: 10,
                                color: Colors.greenAccent,
                              ),
                            if (canRemove)
                              IconButton(
                                tooltip: thread.admins.contains(nodeId)
                                    ? 'Demote'
                                    : 'Promote',
                                onPressed: () => toggleAdmin(context, profile),
                                icon: Icon(
                                  thread.admins.contains(nodeId)
                                      ? Icons.admin_panel_settings
                                      : Icons.admin_panel_settings_outlined,
                                ),
                              ),
                            if (canRemove)
                              IconButton(
                                tooltip: 'Remove from group',
                                onPressed: () => removeMember(context, profile),
                                icon: const Icon(Icons.person_remove_outlined),
                              ),
                          ],
                        ),
                        onTap: nodeId == controller.myNodeId
                            ? null
                            : () => openProfile(context, profile),
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Profile _profileFor(String nodeId) {
    return controller.profiles[nodeId] ??
        Profile(nodeId: nodeId, displayName: nodeId.substring(0, 8));
  }

  String _roleFor(String nodeId) {
    if (nodeId == thread.ownerNode) return 'owner';
    if (thread.admins.contains(nodeId)) return 'admin';
    return '';
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _GroupActionButton extends StatelessWidget {
  const _GroupActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Material(
              color: Colors.white.withValues(
                alpha: onTap == null ? 0.05 : 0.10,
              ),
              child: InkWell(
                onTap: onTap,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Icon(
                    icon,
                    color: onTap == null
                        ? Colors.white30
                        : Colors.lightBlueAccent,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: onTap == null ? Colors.white30 : Colors.white70,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _GroupGlassSurface extends StatelessWidget {
  const _GroupGlassSurface({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xAA182634),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.11)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
