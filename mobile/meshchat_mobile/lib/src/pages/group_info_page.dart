import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';
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

  Future<void> toggleAdmin(BuildContext context, Profile profile) async {
    final error = await controller.toggleGroupAdmin(thread, profile.nodeId);
    if (!context.mounted) return;
    _showSnack(context, error ?? 'Role updated');
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
                    setDialogState(() {
                      avatarData = base64Encode(bytes);
                    });
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
          appBar: AppBar(
            title: const Text('Group info'),
            actions: [
              if (isOwner)
                IconButton(
                  tooltip: 'Edit group',
                  onPressed: () => editGroupProfile(context),
                  icon: const Icon(Icons.edit_outlined),
                ),
              if (isOwner)
                IconButton(
                  tooltip: 'Add member',
                  onPressed: () => addMember(context),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Center(child: ProfileAvatar(profile: thread.profile, radius: 56)),
              const SizedBox(height: 18),
              Text(
                thread.profile.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${members.length} members',
                textAlign: TextAlign.center,
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
              if (isOwner) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => addMember(context),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add member'),
                ),
              ],
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF20242B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Roles',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 6),
                    Text('Owner: can add/remove members and admins.'),
                    Text('Admin: marked in the member list.'),
                    Text('Member: can read and send messages.'),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Members',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF20242B),
                      borderRadius: BorderRadius.circular(8),
                    ),
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
