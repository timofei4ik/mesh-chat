import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';
import 'chat_page.dart';
import 'edit_profile_page.dart';
import 'global_search_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';

class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key, required this.controller});

  final AppController controller;

  Future<void> findUser(BuildContext context) async {
    final input = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Find user'),
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
            child: const Text('Find'),
          ),
        ],
      ),
    );
    input.dispose();
    if (username == null || username.trim().isEmpty || !context.mounted) return;

    final profile = await controller.lookupUsername(username);
    if (!context.mounted) return;
    if (profile == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('User not found')));
      return;
    }
    openChat(context, profile);
  }

  Future<void> createGroup(BuildContext context) async {
    final nameInput = TextEditingController();
    final membersInput = TextEditingController();
    final result = await showDialog<({String name, String members})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameInput,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.group_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: membersInput,
              decoration: const InputDecoration(
                labelText: 'Members',
                hintText: '@user1, @user2',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              name: nameInput.text,
              members: membersInput.text,
            )),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameInput.dispose();
    membersInput.dispose();
    if (result == null || result.name.trim().isEmpty || !context.mounted) {
      return;
    }

    final usernames = result.members
        .split(RegExp(r'[\s,;]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (usernames.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add at least one member')));
      return;
    }

    final members = <Profile>[];
    final missing = <String>[];
    for (final username in usernames) {
      final profile = await controller.lookupUsername(username);
      if (profile == null) {
        missing.add(username);
      } else {
        members.add(profile);
      }
    }
    if (!context.mounted) return;
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not found: ${missing.join(', ')}')),
      );
      return;
    }

    final group = await controller.createGroup(
      name: result.name,
      members: members,
    );
    if (!context.mounted) return;
    if (group == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not create group')));
      return;
    }
    openThread(context, group);
  }

  void openChat(BuildContext context, Profile profile) {
    final thread =
        controller.threads[profile.nodeId] ?? ChatThread(profile: profile);
    controller.threads[profile.nodeId] = thread;
    openThread(context, thread);
  }

  void openThread(BuildContext context, ChatThread thread) {
    controller.markRead(thread);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(controller: controller, thread: thread),
      ),
    );
  }

  void openProfile(BuildContext context, Profile profile) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfilePage(profile: profile)),
    );
  }

  void editOwnProfile(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfilePage(controller: controller),
      ),
    );
  }

  void openSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsPage(controller: controller)),
    );
  }

  void openGlobalSearch(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GlobalSearchPage(controller: controller),
      ),
    );
  }

  Future<void> showThreadMenu(BuildContext context, ChatThread thread) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                thread.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(thread.pinned ? 'Unpin chat' : 'Pin chat'),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            ListTile(
              leading: Icon(
                thread.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              title: Text(thread.archived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(context, 'archive'),
            ),
            ListTile(
              leading: Icon(
                thread.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(thread.muted ? 'Unmute' : 'Mute'),
              onTap: () => Navigator.pop(context, 'mute'),
            ),
            if (!thread.isGroup)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Profile'),
                onTap: () => Navigator.pop(context, 'profile'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'pin') controller.toggleThreadPin(thread);
    if (action == 'archive') controller.toggleThreadArchive(thread);
    if (action == 'mute') controller.toggleThreadMute(thread);
    if (action == 'profile') openProfile(context, thread.profile);
  }

  void openArchived(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _ArchivedChatsPage(controller: controller, parent: this),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset('assets/app_icon.png', width: 34, height: 34),
            const SizedBox(width: 10),
            const Text('MeshChat'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search chats',
            onPressed: () => openGlobalSearch(context),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Find by username',
            onPressed: () => findUser(context),
            icon: const Icon(Icons.person_search_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'profile') editOwnProfile(context);
              if (value == 'group') createGroup(context);
              if (value == 'settings') openSettings(context);
              if (value == 'logout') controller.logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'profile',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.account_circle_outlined),
                  title: Text('Profile'),
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.group_add_outlined),
                  title: Text('Create group'),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout),
                  title: Text('Logout'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final threads = controller.sortedThreads;
          final archivedCount = controller.archivedThreads.length;
          final status = controller.status.toLowerCase();
          final online = status.contains('online') || status.contains('сети');
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: const Color(0xFF20242B),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        controller.status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '@${controller.session?.publicUsername ?? ''}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: threads.isEmpty && archivedCount == 0
                    ? const Center(
                        child: Text(
                          'Find someone by @username',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: threads.length + (archivedCount > 0 ? 1 : 0),
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 76),
                        itemBuilder: (context, index) {
                          if (archivedCount > 0 && index == 0) {
                            return ListTile(
                              leading: const Icon(Icons.archive_outlined),
                              title: const Text('Archive'),
                              subtitle: Text('$archivedCount chats'),
                              onTap: () => openArchived(context),
                            );
                          }
                          final threadIndex =
                              index - (archivedCount > 0 ? 1 : 0);
                          final thread = threads[threadIndex];
                          final last = thread.lastMessage;
                          return ListTile(
                            minTileHeight: 72,
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ProfileAvatar(profile: thread.profile),
                                if (thread.isGroup)
                                  const Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: CircleAvatar(
                                      radius: 9,
                                      backgroundColor: Color(0xFF20242B),
                                      child: Icon(Icons.group, size: 12),
                                    ),
                                  ),
                              ],
                            ),
                            title: Row(
                              children: [
                                if (thread.pinned) ...[
                                  const Icon(Icons.push_pin, size: 14),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    thread.profile.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (last != null)
                                  Text(
                                    _time(last.createdAt),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white38,
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              thread.draft.isNotEmpty
                                  ? 'Draft: ${thread.draft}'
                                  : _previewText(
                                      last,
                                      thread.profile.publicUsername,
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: thread.unread > 0
                                ? Container(
                                    constraints: const BoxConstraints(
                                      minWidth: 22,
                                      minHeight: 22,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      thread.unread > 99
                                          ? '99+'
                                          : '${thread.unread}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  )
                                : thread.muted
                                ? const Icon(
                                    Icons.notifications_off_outlined,
                                    size: 18,
                                    color: Colors.white38,
                                  )
                                : thread.isGroup
                                ? null
                                : thread.profile.online
                                ? const Icon(
                                    Icons.circle,
                                    size: 10,
                                    color: Colors.greenAccent,
                                  )
                                : null,
                            onTap: () => openThread(context, thread),
                            onLongPress: () => showThreadMenu(context, thread),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => findUser(context),
        tooltip: 'New chat',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  static String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _previewText(ChatMessage? message, String username) {
    if (message == null) return username.isEmpty ? '' : '@$username';
    if (message.kind == ChatMessageKind.file) {
      return _isImageName(message.fileName)
          ? 'Photo'
          : 'File: ${message.fileName.isEmpty ? 'unnamed' : message.fileName}';
    }
    return message.text;
  }

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }
}

class _ArchivedChatsPage extends StatelessWidget {
  const _ArchivedChatsPage({required this.controller, required this.parent});

  final AppController controller;
  final ChatsPage parent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Archive')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final threads = controller.archivedThreads;
          if (threads.isEmpty) {
            return const Center(child: Text('Archive is empty'));
          }
          return ListView.separated(
            itemCount: threads.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
            itemBuilder: (context, index) {
              final thread = threads[index];
              final last = thread.lastMessage;
              return ListTile(
                minTileHeight: 72,
                leading: ProfileAvatar(profile: thread.profile),
                title: Text(
                  thread.profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  ChatsPage._previewText(last, thread.profile.publicUsername),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Unarchive',
                  icon: const Icon(Icons.unarchive_outlined),
                  onPressed: () => controller.toggleThreadArchive(thread),
                ),
                onTap: () => parent.openThread(context, thread),
                onLongPress: () => parent.showThreadMenu(context, thread),
              );
            },
          );
        },
      ),
    );
  }
}
