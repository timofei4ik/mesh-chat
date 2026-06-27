import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../services/call_alert_service.dart';
import '../widgets/profile_avatar.dart';
import 'bluetooth_nearby_page.dart';
import 'chat_page.dart';
import 'diagnostics_page.dart';
import 'edit_profile_page.dart';
import 'global_search_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';

enum _HomeFilter { all, personal, groups, bluetooth }

enum _HomeTab { chats, settings, bluetooth }

class _ActionSheetGlass extends StatelessWidget {
  const _ActionSheetGlass({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: _edgeGlassGradient(
                base: const Color(0xFF26313B),
                alpha: 0.86,
                edgeBoost: 0.05,
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key, required this.controller});

  final AppController controller;

  Future<void> startNew(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ActionSheetGlass(
        children: [
          ListTile(
            leading: const Icon(Icons.alternate_email_rounded),
            title: const Text('Add user by username'),
            subtitle: const Text('Find a person and open chat'),
            onTap: () => Navigator.pop(context, 'user'),
          ),
          ListTile(
            leading: const Icon(Icons.group_add_outlined),
            title: const Text('Create group'),
            subtitle: const Text('Start a group chat'),
            onTap: () => Navigator.pop(context, 'group'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'user') {
      await findUser(context);
    } else if (action == 'group') {
      await createGroup(context);
    }
  }

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

  void openDiagnostics(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DiagnosticsPage(controller: controller),
      ),
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
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete locally',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete for everyone',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () => Navigator.pop(context, 'delete_all'),
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
    if (action == 'delete' || action == 'delete_all') {
      final forEveryone = action == 'delete_all';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(forEveryone ? 'Delete for everyone?' : 'Delete chat?'),
          content: Text(
            forEveryone
                ? 'This will ask other devices in this chat to remove the chat too.'
                : 'Messages in this chat will be removed only on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        if (forEveryone) {
          await controller.deleteThreadForEveryone(thread);
        } else {
          await controller.deleteThread(thread);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(forEveryone ? 'Delete sent' : 'Chat deleted'),
            ),
          );
        }
      }
    }
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
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (DateTime.now().microsecondsSinceEpoch >= 0) {
            return _HomeShell(parent: this, controller: controller);
          }
          final threads = controller.sortedThreads;
          final archivedCount = controller.archivedThreads.length;
          final status = controller.status.toLowerCase();
          final online = status.contains('online') || status.contains('сети');
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: _HomeGlassSurface(
                  accent: online ? Colors.greenAccent : Colors.orangeAccent,
                  radius: 18,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
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
                            boxShadow: [
                              BoxShadow(
                                color:
                                    (online
                                            ? Colors.greenAccent
                                            : Colors.orangeAccent)
                                        .withValues(alpha: 0.42),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            controller.status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70),
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
                ),
              ),
              _HomeCallBanner(controller: controller),
              _BluetoothChatsStrip(
                controller: controller,
                onOpen: () => openBluetoothNearby(context),
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
      floatingActionButton: const SizedBox.shrink(),
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

class _HomeShell extends StatefulWidget {
  const _HomeShell({required this.parent, required this.controller});

  final ChatsPage parent;
  final AppController controller;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  _HomeFilter filter = _HomeFilter.all;
  _HomeTab tab = _HomeTab.chats;
  double tabDirection = 1;
  double filterDirection = 1;
  final callAlert = CallAlertService();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(syncCallAlert);
    syncCallAlert();
  }

  @override
  void dispose() {
    widget.controller.removeListener(syncCallAlert);
    unawaited(callAlert.dispose());
    super.dispose();
  }

  void syncCallAlert() {
    unawaited(callAlert.sync(widget.controller));
  }

  int _tabIndex(_HomeTab value) => switch (value) {
    _HomeTab.chats => 0,
    _HomeTab.settings => 1,
    _HomeTab.bluetooth => 2,
  };

  int _filterIndex(_HomeFilter value) => switch (value) {
    _HomeFilter.all => 0,
    _HomeFilter.personal => 1,
    _HomeFilter.groups => 2,
    _HomeFilter.bluetooth => 3,
  };

  void selectTab(_HomeTab value) {
    if (value == tab) return;
    setState(() {
      tabDirection = _tabIndex(value) > _tabIndex(tab) ? 1 : -1;
      tab = value;
    });
  }

  void selectFilter(_HomeFilter value) {
    if (value == filter) return;
    setState(() {
      filterDirection = _filterIndex(value) > _filterIndex(filter) ? 1 : -1;
      filter = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final allThreads = controller.sortedThreads;
    final threads = switch (filter) {
      _HomeFilter.all => allThreads,
      _HomeFilter.personal =>
        allThreads.where((thread) => !thread.isGroup).toList(),
      _HomeFilter.groups =>
        allThreads.where((thread) => thread.isGroup).toList(),
      _HomeFilter.bluetooth =>
        allThreads
            .where((thread) => thread.profile.online && !thread.isGroup)
            .toList(),
    };
    final archivedCount = controller.archivedThreads.length;

    return Stack(
      children: [
        const Positioned.fill(child: _HomeLiquidBackground()),
        SafeArea(
          child: Column(
            children: [
              _HomeHeader(
                controller: controller,
                onBluetooth: () => selectTab(_HomeTab.bluetooth),
                onNewChat: () => widget.parent.startNew(context),
                onSearch: () => widget.parent.openGlobalSearch(context),
              ),
              _HomeCallBanner(controller: controller),
              if (tab == _HomeTab.chats)
                _HomeFilterBar(
                  selected: filter,
                  onChanged: selectFilter,
                  onSettings: () => selectTab(_HomeTab.settings),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  layoutBuilder: (currentChild, previousChildren) => ClipRect(
                    child: Stack(
                      alignment: Alignment.topCenter,
                      children: [?currentChild],
                    ),
                  ),
                  transitionBuilder: (child, animation) =>
                      _DirectionalPageSlide(
                        animation: animation,
                        direction: tabDirection,
                        child: child,
                      ),
                  child: _HomeTabBody(
                    key: ValueKey(tab),
                    tab: tab,
                    filter: filter,
                    filterDirection: filterDirection,
                    threads: threads,
                    archivedCount: archivedCount,
                    controller: controller,
                    parent: widget.parent,
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 14,
          child: _HomeBottomBar(
            selected: tab,
            onChats: () => selectTab(_HomeTab.chats),
            onSettings: () => selectTab(_HomeTab.settings),
            onBluetooth: () => selectTab(_HomeTab.bluetooth),
          ),
        ),
      ],
    );
  }
}

class _HomeTabBody extends StatelessWidget {
  const _HomeTabBody({
    super.key,
    required this.tab,
    required this.filter,
    required this.filterDirection,
    required this.threads,
    required this.archivedCount,
    required this.controller,
    required this.parent,
  });

  final _HomeTab tab;
  final _HomeFilter filter;
  final double filterDirection;
  final List<ChatThread> threads;
  final int archivedCount;
  final AppController controller;
  final ChatsPage parent;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      _HomeTab.settings => _InlineSettingsPanel(
        controller: controller,
        onProfile: () => parent.editOwnProfile(context),
        onGroup: () => parent.createGroup(context),
        onSettings: () => parent.openSettings(context),
        onDiagnostics: () => parent.openDiagnostics(context),
        onLogout: controller.logout,
      ),
      _HomeTab.bluetooth => _InlineBluetoothPanel(
        controller: controller,
        onOpenDetails: () => parent.openBluetoothNearby(context),
      ),
      _HomeTab.chats => AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        layoutBuilder: (currentChild, previousChildren) => ClipRect(
          child: Stack(
            alignment: Alignment.topCenter,
            children: [?currentChild],
          ),
        ),
        transitionBuilder: (child, animation) => _DirectionalPageSlide(
          animation: animation,
          direction: filterDirection,
          child: child,
        ),
        child: threads.isEmpty && archivedCount == 0
            ? RefreshIndicator(
                key: ValueKey('empty-$filter'),
                color: Colors.lightBlueAccent,
                backgroundColor: const Color(0xFF111B2A),
                onRefresh: controller.handleAppResumed,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 92, 24, 140),
                  children: [
                    _HomeEmptyState(
                      filter: filter,
                      onNewChat: () => parent.startNew(context),
                      onBluetooth: () => parent.openBluetoothNearby(context),
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                key: ValueKey(filter),
                color: Colors.lightBlueAccent,
                backgroundColor: const Color(0xFF111B2A),
                onRefresh: controller.handleAppResumed,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 110),
                  itemCount:
                      threads.length +
                      (archivedCount > 0 && filter == _HomeFilter.all ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (archivedCount > 0 &&
                        filter == _HomeFilter.all &&
                        index == 0) {
                      return _AnimatedChatEntrance(
                        index: index,
                        child: _ArchiveGlassTile(
                          count: archivedCount,
                          onTap: () => parent.openArchived(context),
                        ),
                      );
                    }
                    final threadIndex =
                        index -
                        (archivedCount > 0 && filter == _HomeFilter.all
                            ? 1
                            : 0);
                    final thread = threads[threadIndex];
                    return _DismissibleChatTile(
                      key: ValueKey(
                        'dismiss-${thread.isGroup ? thread.groupId : thread.profile.nodeId}',
                      ),
                      thread: thread,
                      controller: controller,
                      child: _AnimatedChatEntrance(
                        key: ValueKey(
                          'chat-${thread.isGroup ? thread.groupId : thread.profile.nodeId}',
                        ),
                        index: index,
                        child: _ChatGlassTile(
                          thread: thread,
                          onTap: () => parent.openThread(context, thread),
                          onLongPress: () =>
                              parent.showThreadMenu(context, thread),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    };
  }
}

class _AnimatedChatEntrance extends StatelessWidget {
  const _AnimatedChatEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 240 + math.min(index, 5) * 35),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _DismissibleChatTile extends StatelessWidget {
  const _DismissibleChatTile({
    super.key,
    required this.thread,
    required this.controller,
    required this.child,
  });

  final ChatThread thread;
  final AppController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(
        'swipe-${thread.isGroup ? thread.groupId : thread.profile.nodeId}',
      ),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          controller.toggleThreadPin(thread);
          _showSwipeSnack(
            context,
            thread.pinned ? 'Chat pinned' : 'Chat unpinned',
          );
        } else {
          controller.toggleThreadArchive(thread);
          _showSwipeSnack(
            context,
            thread.archived ? 'Chat archived' : 'Chat unarchived',
          );
        }
        return false;
      },
      background: _SwipeActionBackground(
        alignment: Alignment.centerLeft,
        icon: thread.pinned ? Icons.push_pin_outlined : Icons.push_pin,
        label: thread.pinned ? 'Unpin' : 'Pin',
        color: Colors.lightBlueAccent,
      ),
      secondaryBackground: _SwipeActionBackground(
        alignment: Alignment.centerRight,
        icon: thread.archived
            ? Icons.unarchive_outlined
            : Icons.archive_outlined,
        label: thread.archived ? 'Unarchive' : 'Archive',
        color: Colors.purpleAccent,
      ),
      child: child,
    );
  }

  void _showSwipeSnack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _SwipeActionBackground extends StatelessWidget {
  const _SwipeActionBackground({
    required this.alignment,
    required this.icon,
    required this.label,
    required this.color,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final left = alignment == Alignment.centerLeft;
    final actionColor = Color.alphaBlend(
      color.withValues(alpha: 0.34),
      const Color(0xFF132333),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: actionColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: EdgeInsets.only(left: left ? 22 : 0, right: left ? 0 : 22),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: actionColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeEmptyState extends StatelessWidget {
  const _HomeEmptyState({
    required this.filter,
    required this.onNewChat,
    required this.onBluetooth,
  });

  final _HomeFilter filter;
  final VoidCallback onNewChat;
  final VoidCallback onBluetooth;

  @override
  Widget build(BuildContext context) {
    final bluetooth = filter == _HomeFilter.bluetooth;
    return _HomeGlassSurface(
      accent: bluetooth ? Colors.lightBlueAccent : Colors.purpleAccent,
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Icon(
                bluetooth
                    ? Icons.bluetooth_searching_rounded
                    : Icons.alternate_email_rounded,
                color: bluetooth ? Colors.lightBlueAccent : Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              bluetooth ? 'Bluetooth chats' : 'No chats yet',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              bluetooth
                  ? 'Find someone by Bluetooth connection'
                  : 'Find someone by @username',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, height: 1.35),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: bluetooth ? onBluetooth : onNewChat,
              icon: Icon(
                bluetooth ? Icons.bluetooth_rounded : Icons.add_rounded,
              ),
              label: Text(bluetooth ? 'Open Bluetooth' : 'Start chat'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectionalPageSlide extends StatelessWidget {
  const _DirectionalPageSlide({
    required this.animation,
    required this.direction,
    required this.child,
  });

  final Animation<double> animation;
  final double direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = animation.status != AnimationStatus.reverse;
    final slide = incoming
        ? Tween<Offset>(
            begin: Offset(0.16 * direction, 0),
            end: Offset.zero,
          ).animate(animation)
        : Tween<Offset>(
            begin: Offset.zero,
            end: Offset(-0.10 * direction, 0),
          ).animate(animation);
    final opacity = incoming
        ? CurvedAnimation(parent: animation, curve: const Interval(0.25, 1))
        : ReverseAnimation(
            CurvedAnimation(parent: animation, curve: const Interval(0, 0.55)),
          );

    return FadeTransition(
      opacity: opacity,
      child: SlideTransition(
        position: slide,
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.controller,
    required this.onBluetooth,
    required this.onNewChat,
    required this.onSearch,
  });

  final AppController controller;
  final VoidCallback onBluetooth;
  final VoidCallback onNewChat;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final status = controller.status.toLowerCase();
    final online = status.contains('online') || status.contains('сети');
    final ble = controller.ble;
    final connected = ble.peers.where((peer) => peer.connected).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              _GlassLogoChip(),
              const Spacer(),
              _BluetoothStatusCard(
                running: ble.running,
                connected: connected,
                online: online,
                onTap: onBluetooth,
              ),
              const SizedBox(width: 10),
              _RoundGlassButton(
                tooltip: 'New chat',
                icon: Icons.add_rounded,
                onPressed: onNewChat,
                accent: Colors.lightBlueAccent,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _HomeSearchField(onTap: onSearch),
          const SizedBox(height: 8),
          _ConnectionStatusPill(status: controller.status),
        ],
      ),
    );
  }
}

class _ConnectionStatusPill extends StatelessWidget {
  const _ConnectionStatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final online =
        normalized.contains('online') || normalized.contains('в сети');
    final connecting =
        normalized.contains('connect') || normalized.contains('подключ');
    final accent = online
        ? Colors.greenAccent
        : connecting
        ? Colors.lightBlueAccent
        : Colors.orangeAccent;
    final label = online
        ? 'Online'
        : connecting
        ? 'Connecting'
        : status.isEmpty
        ? 'Offline'
        : status;

    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent,
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.45),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 7),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                label,
                key: ValueKey(label),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BluetoothStatusCard extends StatelessWidget {
  const _BluetoothStatusCard({
    required this.running,
    required this.connected,
    required this.online,
    required this.onTap,
  });

  final bool running;
  final int connected;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = running || connected > 0;
    return _HomeGlassSurface(
      accent: active ? Colors.greenAccent : Colors.blueGrey,
      radius: 15,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.bluetooth_connected_rounded
                    : Icons.bluetooth_rounded,
                color: Colors.white,
                size: 22,
              ),
              const SizedBox(width: 9),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Bluetooth',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        active
                            ? connected > 0
                                  ? 'Connected'
                                  : 'On'
                            : 'Off',
                        style: TextStyle(
                          fontSize: 11,
                          color: active ? Colors.greenAccent : Colors.white54,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active
                              ? Colors.greenAccent
                              : online
                              ? Colors.greenAccent
                              : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSearchField extends StatelessWidget {
  const _HomeSearchField({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeGlassSurface(
      accent: Colors.blueGrey,
      radius: 16,
      dim: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 20, color: Colors.white54),
              SizedBox(width: 8),
              Text('Search', style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassLogoChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Image.asset('assets/app_icon.png', width: 48, height: 48),
        const SizedBox(width: 10),
        const Text(
          'MeshChat',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class _RoundFilterButton extends StatelessWidget {
  const _RoundFilterButton({
    required this.onTap,
    required this.icon,
    required this.tooltip,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: _HomeGlassSurface(
        accent: Colors.blueGrey,
        radius: 999,
        dim: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 20, color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

class _HomeFilterBar extends StatelessWidget {
  const _HomeFilterBar({
    required this.selected,
    required this.onChanged,
    required this.onSettings,
  });

  final _HomeFilter selected;
  final ValueChanged<_HomeFilter> onChanged;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Row(
        children: [
          Expanded(
            child: _FilterPill(
              label: 'All',
              icon: Icons.all_inbox_rounded,
              selected: selected == _HomeFilter.all,
              onTap: () => onChanged(_HomeFilter.all),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FilterPill(
              label: 'Personal',
              icon: Icons.person_outline_rounded,
              selected: selected == _HomeFilter.personal,
              onTap: () => onChanged(_HomeFilter.personal),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FilterPill(
              label: 'Groups',
              icon: Icons.groups_rounded,
              selected: selected == _HomeFilter.groups,
              onTap: () => onChanged(_HomeFilter.groups),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FilterPill(
              label: 'Bluetooth',
              icon: Icons.bluetooth_rounded,
              selected: selected == _HomeFilter.bluetooth,
              onTap: () => onChanged(_HomeFilter.bluetooth),
            ),
          ),
          const SizedBox(width: 8),
          _RoundFilterButton(
            icon: Icons.tune_rounded,
            tooltip: 'Settings',
            onTap: onSettings,
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeGlassSurface(
      accent: selected ? Colors.lightBlueAccent : Colors.blueGrey,
      radius: 18,
      selected: selected,
      dim: !selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? Colors.lightBlueAccent : Colors.white70,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatGlassTile extends StatelessWidget {
  const _ChatGlassTile({
    required this.thread,
    required this.onTap,
    required this.onLongPress,
  });

  final ChatThread thread;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final last = thread.lastMessage;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _HomeGlassSurface(
        accent: thread.unread > 0
            ? Colors.lightBlueAccent
            : thread.isGroup
            ? Colors.lightBlueAccent
            : Colors.blueGrey,
        radius: 24,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                _GlassAvatar(profile: thread.profile, isGroup: thread.isGroup),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (thread.pinned) ...[
                            const Icon(
                              Icons.push_pin,
                              size: 14,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              thread.profile.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (last != null)
                            Text(
                              ChatsPage._time(last.createdAt),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        thread.draft.isNotEmpty
                            ? 'Draft: ${thread.draft}'
                            : ChatsPage._previewText(
                                last,
                                thread.profile.publicUsername,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (thread.unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      thread.unread > 99 ? '99+' : '${thread.unread}',
                      style: const TextStyle(
                        color: Color(0xFF06111B),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                else if (thread.muted)
                  const Icon(
                    Icons.notifications_off_outlined,
                    size: 18,
                    color: Colors.white38,
                  )
                else if (!thread.isGroup && thread.profile.online)
                  const Icon(Icons.circle, size: 10, color: Colors.greenAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassAvatar extends StatelessWidget {
  const _GlassAvatar({required this.profile, required this.isGroup});

  final Profile profile;
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.11),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ProfileAvatar(profile: profile, radius: 26),
          if (isGroup)
            const Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: Color(0xFF223244),
                child: Icon(Icons.group, size: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArchiveGlassTile extends StatelessWidget {
  const _ArchiveGlassTile({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _HomeGlassSurface(
        accent: Colors.white54,
        radius: 22,
        child: ListTile(
          leading: const Icon(Icons.archive_outlined),
          title: const Text('Archive'),
          subtitle: Text('$count chats'),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _InlineSettingsPanel extends StatelessWidget {
  const _InlineSettingsPanel({
    required this.controller,
    required this.onProfile,
    required this.onGroup,
    required this.onSettings,
    required this.onDiagnostics,
    required this.onLogout,
  });

  final AppController controller;
  final VoidCallback onProfile;
  final VoidCallback onGroup;
  final VoidCallback onSettings;
  final VoidCallback onDiagnostics;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 98),
      children: [
        _HomeGlassSurface(
          accent: Colors.lightBlueAccent,
          radius: 24,
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(session?.login ?? 'Account'),
            subtitle: Text(
              session?.publicUsername.isNotEmpty == true
                  ? '@${session!.publicUsername}'
                  : controller.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: onProfile,
          ),
        ),
        const SizedBox(height: 10),
        _InlineActionTile(
          icon: Icons.person_outline_rounded,
          title: 'Profile',
          subtitle: 'Name, avatar, description',
          onTap: onProfile,
        ),
        _InlineActionTile(
          icon: Icons.group_add_outlined,
          title: 'Create group',
          subtitle: 'New chat with several people',
          onTap: onGroup,
        ),
        _InlineActionTile(
          icon: Icons.tune_rounded,
          title: 'App settings',
          subtitle: 'Storage, theme, notifications',
          onTap: onSettings,
        ),
        _InlineActionTile(
          icon: Icons.health_and_safety_outlined,
          title: 'Diagnostics',
          subtitle: 'Server, sync, calls, Bluetooth, cache',
          onTap: onDiagnostics,
          accent: Colors.lightBlueAccent,
        ),
        _InlineActionTile(
          icon: Icons.logout_rounded,
          title: 'Log out',
          subtitle: 'Return to account screen',
          onTap: onLogout,
          accent: Colors.redAccent,
        ),
      ],
    );
  }
}

class _InlineBluetoothPanel extends StatelessWidget {
  const _InlineBluetoothPanel({
    required this.controller,
    required this.onOpenDetails,
  });

  final AppController controller;
  final VoidCallback onOpenDetails;

  Future<void> _toggle(BuildContext context) async {
    if (controller.ble.running) {
      await controller.stopBluetoothNearby();
      return;
    }
    final error = await controller.startBluetoothNearby();
    if (error == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final ble = controller.ble;
    final peers = ble.peers;
    final connected = peers.where((peer) => peer.connected).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 98),
      children: [
        _HomeGlassSurface(
          accent: ble.running ? Colors.lightBlueAccent : Colors.blueGrey,
          radius: 24,
          selected: ble.running,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Row(
              children: [
                Icon(
                  ble.running
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_rounded,
                  color: ble.running ? Colors.lightBlueAccent : Colors.white70,
                  size: 32,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Bluetooth',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        ble.running
                            ? '$connected connected - ${peers.length} nearby'
                            : 'Nearby chats are off',
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => _toggle(context),
                  child: Text(ble.running ? 'Stop' : 'Start'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _InlineActionTile(
          icon: Icons.open_in_new_rounded,
          title: 'Advanced Bluetooth screen',
          subtitle: ble.status,
          onTap: onOpenDetails,
        ),
        if (peers.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 36),
            child: Center(
              child: Text(
                'No nearby Bluetooth devices',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          )
        else
          ...peers.map(
            (peer) => _InlineActionTile(
              icon: peer.connected
                  ? Icons.bluetooth_connected_rounded
                  : Icons.bluetooth_rounded,
              title: peer.displayName.isNotEmpty ? peer.displayName : peer.name,
              subtitle: peer.connected
                  ? 'Connected'
                  : peer.rssi == 0
                  ? 'Nearby'
                  : 'Signal ${peer.rssi} dBm',
              onTap: onOpenDetails,
              accent: peer.connected ? Colors.lightBlueAccent : Colors.blueGrey,
            ),
          ),
      ],
    );
  }
}

class _InlineActionTile extends StatelessWidget {
  const _InlineActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = Colors.lightBlueAccent,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _HomeGlassSurface(
        accent: accent,
        radius: 22,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          leading: Icon(icon, color: accent.withValues(alpha: 0.95)),
          title: Text(title),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _HomeBottomBar extends StatelessWidget {
  const _HomeBottomBar({
    required this.selected,
    required this.onChats,
    required this.onSettings,
    required this.onBluetooth,
  });

  final _HomeTab selected;
  final VoidCallback onChats;
  final VoidCallback onSettings;
  final VoidCallback onBluetooth;

  Alignment _alignment() => switch (selected) {
    _HomeTab.chats => Alignment.centerLeft,
    _HomeTab.settings => Alignment.center,
    _HomeTab.bluetooth => Alignment.centerRight,
  };

  @override
  Widget build(BuildContext context) {
    return _HomeGlassSurface(
      accent: Colors.lightBlueAccent,
      radius: 28,
      child: SizedBox(
        height: 76,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Stack(
            children: [
              AnimatedAlign(
                alignment: _alignment(),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Container(
                  width: 96,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: _edgeGlassGradient(
                      base: const Color(0xFF314456),
                      alpha: 0.72,
                      edgeBoost: 0.08,
                    ),
                    border: Border.all(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.32),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.lightBlueAccent.withValues(alpha: 0.18),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _BottomNavItem(
                    icon: Icons.forum_rounded,
                    label: 'Chats',
                    selected: selected == _HomeTab.chats,
                    onTap: onChats,
                  ),
                  _BottomNavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: selected == _HomeTab.settings,
                    onTap: onSettings,
                  ),
                  _BottomNavItem(
                    icon: Icons.bluetooth_rounded,
                    label: 'Bluetooth',
                    selected: selected == _HomeTab.bluetooth,
                    onTap: onBluetooth,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 96,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: selected ? 23 : 21,
              color: selected ? Colors.lightBlueAccent : Colors.white60,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? Colors.white : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.accent,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: _HomeGlassSurface(
        accent: accent,
        radius: 18,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

class _HomeLiquidBackground extends StatefulWidget {
  const _HomeLiquidBackground();

  @override
  State<_HomeLiquidBackground> createState() => _HomeLiquidBackgroundState();
}

class _HomeLiquidBackgroundState extends State<_HomeLiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Timer timer;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    timer = Timer.periodic(const Duration(milliseconds: 7200), (_) {
      if (mounted) controller.forward(from: 0);
    });
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) controller.forward(from: 0);
    });
  }

  @override
  void dispose() {
    timer.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF07111E)),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            isComplex: true,
            willChange: controller.isAnimating,
            painter: _HomeMeshPainter(t: controller.value),
          ),
        ),
      ),
    );
  }
}

class _HomeMeshPainter extends CustomPainter {
  const _HomeMeshPainter({this.t = 0});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final eased = math.sin(t * math.pi).clamp(0.0, 1.0);
    final phase = eased * math.pi * 2;
    final cyanPulse = 0.78 + 0.22 * math.sin(phase);
    final violetPulse = 0.78 + 0.22 * math.sin(phase + math.pi * 0.75);
    final cyan = Paint()
      ..color = const Color(0xFF40CFFF).withValues(alpha: 0.044 * cyanPulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 130);
    final violet = Paint()
      ..color = const Color(0xFF9A6BFF).withValues(alpha: 0.043 * violetPulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 138);
    final blue = Paint()
      ..color = const Color(0xFF348DFF).withValues(alpha: 0.018)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 150);
    final cyanCore = Paint()
      ..color = const Color(0xFF40CFFF).withValues(alpha: 0.085 * cyanPulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 34);
    final violetCore = Paint()
      ..color = const Color(0xFF9A6BFF).withValues(alpha: 0.085 * violetPulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 36);

    final cyanCenter = Offset(
      size.width * (0.18 + 0.035 * math.sin(phase * 0.7)),
      size.height * (0.14 + 0.025 * math.cos(phase * 0.9)),
    );
    final violetCenter = Offset(
      size.width * (0.88 + 0.03 * math.cos(phase * 0.6)),
      size.height * (0.30 + 0.035 * math.sin(phase * 0.8)),
    );
    canvas.drawCircle(cyanCenter, 220 + 10 * cyanPulse, cyan);
    canvas.drawCircle(violetCenter, 260 + 12 * violetPulse, violet);
    canvas.drawCircle(cyanCenter, 38 + 4 * cyanPulse, cyanCore);
    canvas.drawCircle(violetCenter, 42 + 5 * violetPulse, violetCore);
    canvas.drawCircle(
      Offset(
        size.width * (0.55 + 0.025 * math.sin(phase * 0.45)),
        size.height * 0.92,
      ),
      280,
      blue,
    );
  }

  @override
  bool shouldRepaint(covariant _HomeMeshPainter oldDelegate) {
    return oldDelegate.t != t;
  }
}

class _HomeCallBanner extends StatelessWidget {
  const _HomeCallBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.activeCall;
    if (call == null) return const SizedBox.shrink();
    final incoming = call.status == CallStatus.ringing && call.incoming;
    final active = call.status == CallStatus.active;
    final ended = call.status == CallStatus.ended;
    final collapsed = call.collapsed && !ended;
    final title = ended
        ? 'Call ended'
        : incoming
        ? 'Incoming call'
        : active
        ? 'Call active'
        : 'Calling...';
    final details = [
      call.peer.displayName,
      if (!ended) formatDuration(controller.callElapsed),
      if (!ended) controller.callQualityLabel,
      if (controller.callParticipantsLabel.isNotEmpty)
        controller.callParticipantsLabel,
      if (call.localMuted) 'muted',
    ].where((part) => part.isNotEmpty).join(' - ');
    final color = ended
        ? Colors.redAccent
        : active || incoming
        ? Colors.greenAccent
        : Colors.orangeAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: _HomeGlassCallSurface(
        accent: color,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.white24),
                ),
                child: Icon(
                  ended ? Icons.call_end_rounded : Icons.call_rounded,
                  color: color,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ended && call.endReason.isNotEmpty
                      ? '$title: ${call.peer.displayName} - ${call.endReason}'
                      : '$title: $details',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (collapsed)
                IconButton.filledTonal(
                  tooltip: 'Show call',
                  onPressed: controller.toggleCallCollapsed,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                )
              else if (!incoming && !ended)
                IconButton.filledTonal(
                  tooltip: 'Hide',
                  onPressed: controller.toggleCallCollapsed,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
              if (incoming) ...[
                TextButton(
                  onPressed: controller.declineCall,
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: controller.acceptCall,
                  child: const Text('Accept'),
                ),
              ] else if (ended)
                TextButton(
                  onPressed: controller.clearEndedCall,
                  child: const Text('Close'),
                )
              else
                IconButton.filledTonal(
                  tooltip: call.localMuted ? 'Unmute' : 'Mute',
                  onPressed: collapsed ? null : controller.toggleCallMute,
                  icon: Icon(call.localMuted ? Icons.mic_off : Icons.mic),
                ),
              if (!incoming && !ended && !collapsed) ...[
                IconButton.filledTonal(
                  tooltip: call.speakerOn ? 'Speaker off' : 'Speaker on',
                  onPressed: controller.toggleCallSpeaker,
                  icon: Icon(call.speakerOn ? Icons.volume_up : Icons.hearing),
                ),
                FilledButton.tonalIcon(
                  onPressed: controller.endCall,
                  icon: const Icon(Icons.call_end_rounded),
                  label: const Text('End'),
                ),
              ] else if (!incoming && !ended)
                IconButton(
                  tooltip: 'End',
                  onPressed: controller.endCall,
                  icon: const Icon(
                    Icons.call_end_rounded,
                    color: Colors.redAccent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeGlassCallSurface extends StatelessWidget {
  const _HomeGlassCallSurface({required this.accent, required this.child});

  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: _edgeGlassGradient(
              base: const Color(0xFF27313B),
              alpha: 0.72,
              edgeBoost: 0.05,
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
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

LinearGradient _edgeGlassGradient({
  required Color base,
  required double alpha,
  required double edgeBoost,
}) {
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color.lerp(base, Colors.white, edgeBoost)!.withValues(alpha: alpha),
      base.withValues(alpha: alpha),
      Color.lerp(base, Colors.white, edgeBoost)!.withValues(alpha: alpha),
    ],
    stops: const [0, 0.5, 1],
  );
}

class _HomeGlassSurface extends StatelessWidget {
  const _HomeGlassSurface({
    required this.accent,
    required this.child,
    this.radius = 20,
    this.selected = false,
    this.dim = false,
  });

  final Color accent;
  final Widget child;
  final double radius;
  final bool selected;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: _edgeGlassGradient(
              base: selected
                  ? const Color(0xFF2C3945)
                  : dim
                  ? const Color(0xFF1F2832)
                  : const Color(0xFF26313B),
              alpha: selected
                  ? 0.76
                  : dim
                  ? 0.58
                  : 0.66,
              edgeBoost: selected ? 0.06 : 0.045,
            ),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.40)
                  : Colors.white.withValues(alpha: 0.12),
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 14,
                ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _BluetoothChatsStrip extends StatelessWidget {
  const _BluetoothChatsStrip({required this.controller, required this.onOpen});

  final AppController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ble = controller.ble;
    final peers = ble.peers;

    final connected = peers.where((peer) => peer.connected).length;
    final visible = peers.length;
    final subtitle = ble.running
        ? [
            if (connected > 0) '$connected connected',
            '$visible nearby',
            if (ble.scanning) 'scanning',
          ].join(' - ')
        : 'Tap to start nearby Bluetooth chats';

    final accent = ble.running ? Colors.lightBlueAccent : Colors.blueGrey;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: _HomeGlassSurface(
        accent: accent,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          leading: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.09),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Icon(
              ble.running ? Icons.bluetooth_connected : Icons.bluetooth,
              color: ble.running ? Colors.lightBlueAccent : Colors.white70,
            ),
          ),
          title: const Text('Bluetooth chats'),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            ),
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open'),
          ),
          onTap: onOpen,
        ),
      ),
    );
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

String formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
