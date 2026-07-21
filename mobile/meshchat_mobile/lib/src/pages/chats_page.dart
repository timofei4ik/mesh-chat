import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../models/story_item.dart';
import '../services/call_alert_service.dart';
import '../utils/mesh_page_route.dart';
import '../widgets/in_app_message_banner.dart';
import '../widgets/mesh_frame_clock.dart';
import '../widgets/mesh_liquid_glass.dart';
import '../widgets/meshpro_badge.dart';
import '../widgets/meshpro_gate.dart';
import '../widgets/mesh_painting.dart';
import '../widgets/profile_avatar.dart';
import 'bluetooth_nearby_page.dart';
import 'chat_page.dart';
import 'diagnostics_page.dart';
import 'edit_profile_page.dart';
import 'global_search_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';

enum _HomeFilter { all, personal, groups, channels, bluetooth }

enum _HomeTab { chats, settings, bluetooth }

class _ActionSheetGlass extends StatelessWidget {
  const _ActionSheetGlass({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: Transform.scale(
            scale: 0.98 + value * 0.02,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
        child: MeshLiquidGlass(
          radius: 28,
          accent: Colors.lightBlueAccent,
          prominent: true,
          fallbackBuilder: (context, child) => ClipRRect(
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
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: child,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
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
            leading: const Icon(Icons.bookmark_border_rounded),
            title: const Text('Saved Messages'),
            subtitle: const Text('Private notes, files and forwards'),
            onTap: () => Navigator.pop(context, 'saved'),
          ),
          ListTile(
            leading: const Icon(Icons.group_add_outlined),
            title: const Text('Create group'),
            subtitle: const Text('Start a group chat'),
            onTap: () => Navigator.pop(context, 'group'),
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Create channel'),
            subtitle: const Text('Broadcast posts to subscribers'),
            onTap: () => Navigator.pop(context, 'channel'),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2_rounded),
            title: const Text('Join by invite link'),
            subtitle: const Text('Paste a MeshChat group/channel invite'),
            onTap: () => Navigator.pop(context, 'join'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'user') {
      await findUser(context);
    } else if (action == 'saved') {
      final thread = controller.ensureSavedMessagesThread();
      if (!context.mounted) return;
      openThread(context, thread);
    } else if (action == 'group') {
      await createGroup(context);
    } else if (action == 'channel') {
      await createGroup(context, isChannel: true);
    } else if (action == 'join') {
      await joinByInvite(context);
    }
  }

  Future<void> joinByInvite(BuildContext context) async {
    final input = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join by invite'),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'meshchat://group/...',
            prefixIcon: Icon(Icons.link_rounded),
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
            child: const Text('Request'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!context.mounted || link == null || link.trim().isEmpty) return;
    final error = await controller.requestGroupJoinFromInvite(link);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Join request sent')));
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

  Future<void> createGroup(
    BuildContext context, {
    bool isChannel = false,
  }) async {
    final nameInput = TextEditingController();
    final membersInput = TextEditingController();
    final result = await showDialog<({String name, String members})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isChannel ? 'New channel' : 'New group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameInput,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(
                  isChannel ? Icons.campaign_outlined : Icons.group_outlined,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: membersInput,
              decoration: InputDecoration(
                labelText: isChannel ? 'Subscribers' : 'Members',
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
            child: Text(isChannel ? 'Create channel' : 'Create'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isChannel
                ? 'Add at least one subscriber'
                : 'Add at least one member',
          ),
        ),
      );
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
      isChannel: isChannel,
    );
    if (!context.mounted) return;
    if (group == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isChannel ? 'Could not create channel' : 'Could not create group',
          ),
        ),
      );
      return;
    }
    openThread(context, group);
  }

  void openChat(BuildContext context, Profile profile) {
    final thread =
        controller.threadForProfile(profile) ?? ChatThread(profile: profile);
    controller.threads[profile.nodeId] = thread;
    openThread(context, thread);
  }

  void openThread(BuildContext context, ChatThread thread) {
    controller.markRead(thread);
    final host = context.findAncestorStateOfType<_ChatStackHostState>();
    if (host != null) {
      unawaited(host.open(thread));
      return;
    }
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => ChatPage(controller: controller, thread: thread),
      ),
    );
  }

  void openProfile(BuildContext context, Profile profile) {
    final thread = controller.threadForProfile(profile);
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (profileContext) => ProfilePage(
          profile: profile,
          controller: controller,
          thread: thread,
          onMessage: () {
            Navigator.pop(context);
            openChat(context, profile);
          },
          onCall: () {
            Navigator.of(profileContext).pop();
            unawaited(_startCallAfterProfileClose(context, profile));
          },
          onMedia: thread == null ? null : () => openThread(context, thread),
        ),
      ),
    );
  }

  Future<void> _startCallAfterProfileClose(
    BuildContext context,
    Profile profile,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!context.mounted) return;
    final error = await controller.startCall(profile);
    if (!context.mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  void editOwnProfile(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => EditProfilePage(controller: controller),
      ),
    );
  }

  void openSettings(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(builder: (_) => SettingsPage(controller: controller)),
    );
  }

  void openDiagnostics(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => DiagnosticsPage(controller: controller),
      ),
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

  void openGlobalSearch(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => GlobalSearchPage(controller: controller),
      ),
    );
  }

  Future<void> showThreadMenu(BuildContext context, ChatThread thread) async {
    final ownsGroup =
        thread.isGroup &&
        (thread.ownerNode.trim().isEmpty ||
            thread.ownerNode == controller.myNodeId);
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
            if (thread.isGroup && !ownsGroup)
              ListTile(
                leading: const Icon(
                  Icons.logout_rounded,
                  color: Colors.redAccent,
                ),
                title: Text(
                  thread.isChannel ? 'Leave channel' : 'Leave group',
                  style: const TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(context, 'leave'),
              ),
            if (!thread.isGroup)
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
            if (!thread.isGroup || ownsGroup)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.redAccent,
                ),
                title: Text(
                  thread.isGroup
                      ? (thread.isChannel ? 'Delete channel' : 'Delete group')
                      : 'Delete for everyone',
                  style: const TextStyle(color: Colors.redAccent),
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
    if (action == 'leave') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(thread.isChannel ? 'Leave channel?' : 'Leave group?'),
          content: Text(
            thread.isChannel
                ? 'The channel will disappear from your chats and will not be restored after relogin.'
                : 'The group will disappear from your chats and will not be restored after relogin.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        final error = await controller.leaveGroup(thread);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error ?? 'Left')));
        }
      }
    }
    if (!context.mounted) return;
    if (action == 'delete' || action == 'delete_all') {
      final forEveryone = action == 'delete_all';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            thread.isGroup
                ? (thread.isChannel ? 'Delete channel?' : 'Delete group?')
                : (forEveryone ? 'Delete for everyone?' : 'Delete chat?'),
          ),
          content: Text(
            thread.isGroup
                ? 'Only the owner can delete it for everyone.'
                : forEveryone
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
        String? error;
        if (forEveryone) {
          error = await controller.deleteThreadForEveryone(thread);
        } else {
          await controller.deleteThread(thread);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error ??
                    (forEveryone
                        ? (thread.isGroup ? 'Deleted' : 'Delete sent')
                        : 'Chat deleted'),
              ),
            ),
          );
        }
      }
    }
  }

  void openArchived(BuildContext context) {
    Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) =>
            _ArchivedChatsPage(controller: controller, parent: this),
      ),
    );
  }

  Future<void> openStoryComposer(BuildContext context) async {
    final people =
        controller.profiles.values
            .where(
              (profile) =>
                  profile.nodeId.isNotEmpty &&
                  profile.nodeId != controller.myNodeId &&
                  !profile.nodeId.startsWith('group:') &&
                  !profile.nodeId.startsWith('saved:'),
            )
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final textController = TextEditingController();
    var visibility = StoryVisibility.everyone;
    var imageData = '';
    var videoData = '';
    var videoMime = 'video/mp4';
    var videoDurationSeconds = 0;
    var mediaType = StoryMediaType.none;
    var hd = false;
    final selected = <String>{};
    final excluded = <String>{};
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final hdAvailable = meshProFeatureEnabled(controller, 'story_hd');
          final extendedVideoAvailable = meshProFeatureEnabled(
            controller,
            'story_extended_video',
          );
          final imageLimit = hd && hdAvailable
              ? 5 * 1024 * 1024
              : 2 * 1024 * 1024;
          final videoLimit = extendedVideoAvailable
              ? 10 * 1024 * 1024
              : 8 * 1024 * 1024;
          final durationLimit =
              controller.meshProSubscription.entitlements.limitFor(
                'story_video_seconds',
              ) ??
              30;
          final chooser =
              visibility == StoryVisibility.selected ||
              visibility == StoryVisibility.excluded;
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: _ActionSheetGlass(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 12, 18, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'New story',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                  child: TextField(
                    controller: textController,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'What is happening?',
                      prefixIcon: Icon(Icons.auto_awesome_rounded),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () async {
                            final picked = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: true,
                            );
                            final bytes = picked?.files.single.bytes;
                            if (bytes == null) return;
                            if (bytes.length > imageLimit) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Story photo is too large, choose up to ${imageLimit ~/ (1024 * 1024)} MB',
                                  ),
                                ),
                              );
                              return;
                            }
                            setSheetState(() {
                              imageData = base64Encode(bytes);
                              videoData = '';
                              videoDurationSeconds = 0;
                              mediaType = StoryMediaType.image;
                            });
                          },
                          icon: const Icon(Icons.photo_rounded),
                          label: Text(
                            imageData.isEmpty ? 'Add photo' : 'Photo selected',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () async {
                            final picked = await FilePicker.platform.pickFiles(
                              type: FileType.video,
                              withData: true,
                            );
                            final file = picked?.files.single;
                            final bytes = file?.bytes;
                            if (bytes == null) return;
                            if (bytes.length > videoLimit) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Story video is too large, choose up to ${videoLimit ~/ (1024 * 1024)} MB',
                                  ),
                                ),
                              );
                              return;
                            }
                            final mime = _videoMime(file?.extension ?? '');
                            final duration = await _storyVideoDurationSeconds(
                              bytes,
                              mime,
                            );
                            if (duration > durationLimit) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Story video can be up to $durationLimit seconds',
                                  ),
                                ),
                              );
                              return;
                            }
                            setSheetState(() {
                              videoData = base64Encode(bytes);
                              videoMime = mime;
                              videoDurationSeconds = duration;
                              imageData = '';
                              mediaType = StoryMediaType.video;
                            });
                          },
                          icon: const Icon(Icons.movie_rounded),
                          label: Text(
                            videoData.isEmpty ? 'Add video' : 'Video selected',
                          ),
                        ),
                      ),
                      if (imageData.isNotEmpty || videoData.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: () => setSheetState(() {
                            imageData = '';
                            videoData = '';
                            videoDurationSeconds = 0;
                            mediaType = StoryMediaType.none;
                          }),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: hd && hdAvailable,
                    onChanged: (value) async {
                      if (!hdAvailable) {
                        await showMeshProPaywall(
                          context,
                          controller,
                          featureId: 'story_hd',
                          featureTitle: 'HD stories',
                          featureDescription:
                              'Publish larger photos with an HD marker.',
                        );
                        return;
                      }
                      setSheetState(() => hd = value);
                    },
                    secondary: Icon(
                      hdAvailable
                          ? Icons.hd_rounded
                          : Icons.lock_outline_rounded,
                      color: hdAvailable
                          ? Colors.lightBlueAccent
                          : Colors.white38,
                    ),
                    title: const Text('HD story'),
                    subtitle: Text(
                      extendedVideoAvailable
                          ? 'Up to $durationLimit seconds of video'
                          : 'MeshPro unlocks longer videos and server archive',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: DropdownButtonFormField<StoryVisibility>(
                    initialValue: visibility,
                    decoration: const InputDecoration(
                      labelText: 'Who can see it',
                      prefixIcon: Icon(Icons.visibility_rounded),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: StoryVisibility.everyone,
                        child: Text('Everyone I know'),
                      ),
                      DropdownMenuItem(
                        value: StoryVisibility.chats,
                        child: Text('Only people with chats'),
                      ),
                      DropdownMenuItem(
                        value: StoryVisibility.selected,
                        child: Text('Only selected people'),
                      ),
                      DropdownMenuItem(
                        value: StoryVisibility.excluded,
                        child: Text('Everyone except...'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setSheetState(() => visibility = value);
                    },
                  ),
                ),
                if (chooser)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final person = people[index];
                        final bucket = visibility == StoryVisibility.selected
                            ? selected
                            : excluded;
                        return CheckboxListTile(
                          value: bucket.contains(person.nodeId),
                          onChanged: (value) => setSheetState(() {
                            if (value == true) {
                              bucket.add(person.nodeId);
                            } else {
                              bucket.remove(person.nodeId);
                            }
                          }),
                          secondary: ProfileAvatar(profile: person, radius: 18),
                          title: Text(person.displayName),
                          subtitle: person.publicUsername.isEmpty
                              ? null
                              : Text('@${person.publicUsername}'),
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, 'publish'),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('Publish story'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result != 'publish') return;
    final error = await controller.publishStory(
      text: textController.text,
      imageData: imageData,
      videoData: videoData,
      videoMime: videoMime,
      mediaType: mediaType,
      visibility: visibility,
      selectedNodeIds: selected.toList(),
      excludedNodeIds: excluded.toList(),
      hd: hd,
      videoDurationSeconds: videoDurationSeconds,
    );
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void openStory(BuildContext context, StoryItem story) {
    unawaited(controller.markStoryViewed(story));
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) =>
            _StoryViewerPage(controller: controller, story: story),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void openStoryArchive(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _StoryArchivePage(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _ChatStackHost(
        controller: controller,
        home: ListenableBuilder(
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
                          itemCount:
                              threads.length + (archivedCount > 0 ? 1 : 0),
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
                                    child: MeshProProfileName(
                                      profile: thread.profile,
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
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
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
                              onLongPress: () =>
                                  showThreadMenu(context, thread),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
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
    if (message.kind == ChatMessageKind.sticker) {
      return 'Sticker';
    }
    if (message.kind == ChatMessageKind.file) {
      return _isImageName(message.fileName)
          ? 'Photo'
          : 'File: ${message.fileName.isEmpty ? 'unnamed' : message.fileName}';
    }
    final meeting = _meetingPointPreview(message.text);
    if (meeting != null) return meeting;
    if (message.text.contains('::meshchat_location_v1::')) {
      return 'Shared location';
    }
    return message.text;
  }

  static String? _meetingPointPreview(String text) {
    const prefix = '::meshchat_meeting_v1::';
    final prefixIndex = text.indexOf(prefix);
    if (prefixIndex < 0) return null;
    try {
      final raw = jsonDecode(text.substring(prefixIndex + prefix.length));
      if (raw is! Map) return 'Meeting point';
      final title = raw['title']?.toString().trim() ?? '';
      return title.isEmpty ? 'Meeting point' : 'Meeting point: $title';
    } catch (_) {
      return 'Meeting point';
    }
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

class _ChatStackHost extends StatefulWidget {
  const _ChatStackHost({required this.controller, required this.home});

  final AppController controller;
  final Widget home;

  @override
  State<_ChatStackHost> createState() => _ChatStackHostState();
}

class _ChatStackHostState extends State<_ChatStackHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 260),
  );
  ChatThread? activeThread;
  bool opening = false;
  bool dragging = false;

  Future<void> open(ChatThread thread) async {
    if (activeThread != null || opening) return;
    opening = true;
    transition.value = 0;
    setState(() => activeThread = thread);

    // Give the chat one complete layout frame while it is still outside the
    // viewport. The transition then moves already-built layers only.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 56));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || activeThread != thread) return;
    await transition.animateTo(1, curve: Curves.easeOutCubic);
    if (mounted) setState(() => opening = false);
  }

  Future<void> close() async {
    if (activeThread == null) return;
    opening = false;
    await transition.animateBack(0, curve: Curves.easeOutCubic);
    if (!mounted) return;
    setState(() => activeThread = null);
  }

  void startBackDrag(DragStartDetails details) {
    if (activeThread == null || opening) return;
    dragging = true;
    HapticFeedback.selectionClick();
  }

  void updateBackDrag(DragUpdateDetails details, double width) {
    if (!dragging || width <= 0) return;
    transition.value = (transition.value - details.delta.dx / width).clamp(
      0.0,
      1.0,
    );
  }

  Future<void> endBackDrag(DragEndDetails details) async {
    if (!dragging) return;
    dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    if (transition.value < 0.72 || velocity > 520) {
      await close();
    } else {
      await transition.animateTo(1, curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thread = activeThread;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return AnimatedBuilder(
          animation: transition,
          builder: (context, _) {
            final value = transition.value;
            return Stack(
              fit: StackFit.expand,
              children: [
                TickerMode(
                  enabled: thread == null,
                  child: RepaintBoundary(child: widget.home),
                ),
                if (thread != null)
                  Transform.translate(
                    offset: Offset(width * (1 - value), 0),
                    child: RepaintBoundary(
                      child: ChatPage(
                        key: ValueKey('active-chat-${thread.storageKey}'),
                        controller: widget.controller,
                        thread: thread,
                        onBack: close,
                      ),
                    ),
                  ),
                if (thread != null && !opening)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 28,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragStart: startBackDrag,
                      onHorizontalDragUpdate: (details) =>
                          updateBackDrag(details, width),
                      onHorizontalDragEnd: endBackDrag,
                      onHorizontalDragCancel: () {
                        dragging = false;
                        transition.animateTo(1, curve: Curves.easeOutCubic);
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
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
    _HomeFilter.channels => 3,
    _HomeFilter.bluetooth => 4,
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
        allThreads
            .where(
              (thread) =>
                  !thread.isGroup &&
                  !thread.isBluetooth &&
                  thread.chatKind == 'normal',
            )
            .toList(),
      _HomeFilter.groups =>
        allThreads
            .where((thread) => thread.isGroup && !thread.isChannel)
            .toList(),
      _HomeFilter.channels =>
        allThreads.where((thread) => thread.isChannel).toList(),
      _HomeFilter.bluetooth =>
        allThreads.where((thread) => thread.isBluetooth).toList(),
    };
    final archivedCount = controller.archivedThreads.length;

    return Stack(
      children: [
        Positioned.fill(
          child: _HomeLiquidBackground(
            enabled: !widget.controller.appSettings.reducedAnimations,
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              _HomeHeader(
                controller: controller,
                onBluetooth: () => selectTab(_HomeTab.bluetooth),
                onNewChat: () => widget.parent.startNew(context),
                onSearch: () => widget.parent.openGlobalSearch(context),
              ),
              _QueuedMessagesBanner(controller: controller),
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
        InAppMessageBanner(
          controller: controller,
          top: MediaQuery.paddingOf(context).top + 8,
          onOpen: (thread) => widget.parent.openThread(context, thread),
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
    final requestCount = filter == _HomeFilter.all
        ? controller.groupJoinRequests.length
        : 0;
    final archiveCount = archivedCount > 0 && filter == _HomeFilter.all ? 1 : 0;
    final storyCount = filter == _HomeFilter.all ? 1 : 0;
    final headerCount = storyCount + requestCount + archiveCount;
    return switch (tab) {
      _HomeTab.settings => _InlineSettingsPanel(
        controller: controller,
        onProfile: () => parent.editOwnProfile(context),
        onGroup: () => parent.createGroup(context),
        onChannel: () => parent.createGroup(context, isChannel: true),
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
        child: threads.isEmpty && archivedCount == 0 && requestCount == 0
            ? RefreshIndicator(
                key: ValueKey('empty-$filter'),
                color: Colors.lightBlueAccent,
                backgroundColor: const Color(0xFF111B2A),
                onRefresh: controller.handleAppResumed,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 92, 24, 140),
                  children: [
                    if (storyCount > 0) ...[
                      _StoriesStrip(
                        controller: controller,
                        onAdd: () => parent.openStoryComposer(context),
                        onArchive: () => parent.openStoryArchive(context),
                        onOpen: (story) => parent.openStory(context, story),
                      ),
                      const SizedBox(height: 14),
                    ],
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
                  padding: const EdgeInsets.fromLTRB(10, 14, 10, 112),
                  itemCount: threads.length + headerCount,
                  itemBuilder: (context, index) {
                    if (index < storyCount) {
                      return _StoriesStrip(
                        controller: controller,
                        onAdd: () => parent.openStoryComposer(context),
                        onArchive: () => parent.openStoryArchive(context),
                        onOpen: (story) => parent.openStory(context, story),
                      );
                    }
                    final afterStories = index - storyCount;
                    if (afterStories < requestCount) {
                      final request =
                          controller.groupJoinRequests[afterStories];
                      return _AnimatedChatEntrance(
                        index: index,
                        child: _JoinRequestGlassTile(
                          request: request,
                          controller: controller,
                        ),
                      );
                    }
                    if (afterStories < requestCount + archiveCount &&
                        archiveCount > 0) {
                      return _AnimatedChatEntrance(
                        index: index,
                        child: _ArchiveGlassTile(
                          count: archivedCount,
                          onTap: () => parent.openArchived(context),
                        ),
                      );
                    }
                    final threadIndex = index - headerCount;
                    final thread = threads[threadIndex];
                    return _DismissibleChatTile(
                      key: ValueKey('dismiss-${thread.storageKey}'),
                      thread: thread,
                      controller: controller,
                      child: _AnimatedChatEntrance(
                        key: ValueKey('chat-${thread.storageKey}'),
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

class _StoriesStrip extends StatelessWidget {
  const _StoriesStrip({
    required this.controller,
    required this.onAdd,
    required this.onArchive,
    required this.onOpen,
  });

  final AppController controller;
  final VoidCallback onAdd;
  final VoidCallback onArchive;
  final ValueChanged<StoryItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final stories = controller.activeStories;
    final showHint = stories.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
      child: SizedBox(
        height: 112,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          itemCount: stories.length + 1 + (showHint ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _AddStoryTile(onTap: onAdd, onArchive: onArchive);
            }
            if (showHint && index == 1) {
              return const _StoriesHintTile();
            }
            final story = stories[index - 1];
            return _StoryTile(
              story: story,
              mine: story.ownerNode == controller.myNodeId,
              unreadCount: controller.unreadStoriesFor(story.ownerNode),
              onTap: () => onOpen(story),
            );
          },
        ),
      ),
    );
  }
}

class _StoriesHintTile extends StatelessWidget {
  const _StoriesHintTile();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 184,
      child: _HomeGlassSurface(
        accent: Colors.blueGrey,
        radius: 22,
        dim: true,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_stories_outlined,
                    size: 18,
                    color: Colors.white70,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Add story',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                "Friends' stories will appear here.",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white54, height: 1.25),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddStoryTile extends StatelessWidget {
  const _AddStoryTile({required this.onTap, required this.onArchive});

  final VoidCallback onTap;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: _HomeGlassSurface(
        accent: Colors.lightBlueAccent,
        radius: 22,
        child: Stack(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: onTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: Color(0x3329C8FF),
                      child: Icon(
                        Icons.add_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'My story',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 5,
              top: 5,
              child: Tooltip(
                message: 'Story archive',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onArchive,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(
                      Icons.history_rounded,
                      size: 15,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryTile extends StatelessWidget {
  const _StoryTile({
    required this.story,
    required this.mine,
    required this.unreadCount,
    required this.onTap,
  });

  final StoryItem story;
  final bool mine;
  final int unreadCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = _storyImage(story.imageData);
    final video = story.mediaType == StoryMediaType.video;
    return SizedBox(
      width: 92,
      child: _HomeGlassSurface(
        accent: mine ? Colors.lightBlueAccent : Colors.purpleAccent,
        radius: 22,
        selected: mine,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: video
                              ? Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF122238),
                                        Color(0xFF201A38),
                                      ],
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: Colors.white,
                                    size: 34,
                                  ),
                                )
                              : image == null
                              ? Container(
                                  color: const Color(0xFF101B28),
                                  alignment: Alignment.center,
                                  child: ProfileAvatar(
                                    profile: Profile(
                                      nodeId: story.ownerNode,
                                      displayName: story.ownerName,
                                      avatarData: story.ownerAvatarData,
                                    ),
                                    radius: 22,
                                  ),
                                )
                              : Image.memory(
                                  image,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  gaplessPlayback: true,
                                ),
                        ),
                      ),
                      if (unreadCount > 0)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.lightBlueAccent,
                              borderRadius: BorderRadius.circular(999),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.lightBlueAccent.withValues(
                                    alpha: 0.5,
                                  ),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Text(
                              unreadCount > 9 ? '9+' : '$unreadCount',
                              style: const TextStyle(
                                color: Color(0xFF06101B),
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  mine ? 'You' : story.ownerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    );
  }
}

class _StoryArchivePage extends StatelessWidget {
  const _StoryArchivePage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _HomeLiquidBackground(enabled: true)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Story archive',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        final archive = controller.storyArchive;
                        if (archive.isEmpty) {
                          return const Center(
                            child: Text(
                              'Your published stories will appear here',
                              style: TextStyle(color: Colors.white54),
                            ),
                          );
                        }
                        return GridView.builder(
                          itemCount: archive.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.78,
                              ),
                          itemBuilder: (context, index) {
                            final story = archive[index];
                            final image = _storyImage(story.imageData);
                            return _HomeGlassSurface(
                              accent: Colors.lightBlueAccent,
                              radius: 24,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(24),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => _StoryViewerPage(
                                        controller: controller,
                                        story: story,
                                      ),
                                    ),
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          child:
                                              story.mediaType ==
                                                  StoryMediaType.video
                                              ? const ColoredBox(
                                                  color: Color(0xFF101B28),
                                                  child: Center(
                                                    child: Icon(
                                                      Icons
                                                          .play_circle_fill_rounded,
                                                      color: Colors.white,
                                                      size: 38,
                                                    ),
                                                  ),
                                                )
                                              : image == null
                                              ? const ColoredBox(
                                                  color: Color(0xFF101B28),
                                                  child: Center(
                                                    child: Icon(
                                                      Icons
                                                          .auto_stories_rounded,
                                                      color: Colors.white70,
                                                      size: 34,
                                                    ),
                                                  ),
                                                )
                                              : Image.memory(
                                                  image,
                                                  width: double.infinity,
                                                  fit: BoxFit.cover,
                                                ),
                                        ),
                                      ),
                                      const SizedBox(height: 9),
                                      Text(
                                        _formatStoryArchiveDate(
                                          story.createdAt,
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${story.viewedByNodeIds.length} views  •  ${story.likedByNodeIds.length} likes',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryViewerPage extends StatefulWidget {
  const _StoryViewerPage({required this.controller, required this.story});

  final AppController controller;
  final StoryItem story;

  @override
  State<_StoryViewerPage> createState() => _StoryViewerPageState();
}

class _StoryViewerPageState extends State<_StoryViewerPage> {
  VideoPlayerController? videoController;
  final TextEditingController replyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    final story = widget.story;
    if (story.mediaType == StoryMediaType.video && story.videoData.isNotEmpty) {
      final raw = story.videoData.contains(',')
          ? story.videoData.substring(story.videoData.indexOf(',') + 1)
          : story.videoData;
      videoController =
          VideoPlayerController.networkUrl(
              Uri.parse('data:${story.videoMime};base64,$raw'),
            )
            ..setLooping(true)
            ..initialize().then((_) {
              if (!mounted) return;
              setState(() {});
              videoController?.play();
            });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    videoController?.dispose();
    replyController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _deleteStory(StoryItem story) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete story?'),
        content: const Text('It will disappear for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final error = await widget.controller.deleteStory(story);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.pop(context);
  }

  void _showViewers(StoryItem story) {
    final profiles = widget.controller.profiles;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final viewers = story.viewedByNodeIds;
        return _HomeGlassSurface(
          accent: Colors.lightBlueAccent,
          radius: 28,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Viewed by ${viewers.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (viewers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'No views yet',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: viewers.length,
                        separatorBuilder: (_, _) =>
                            const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (context, index) {
                          final nodeId = viewers[index];
                          final profile = profiles[nodeId];
                          final name =
                              profile?.displayName.trim().isNotEmpty == true
                              ? profile!.displayName
                              : nodeId;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: ProfileAvatar(
                              profile:
                                  profile ??
                                  Profile(nodeId: nodeId, displayName: name),
                              radius: 20,
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            trailing: story.reactionFor(nodeId).isEmpty
                                ? null
                                : Text(
                                    _storyReactionEmoji(
                                      story.reactionFor(nodeId),
                                    ),
                                    style: const TextStyle(fontSize: 22),
                                  ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _sendReply(StoryItem story) async {
    final text = replyController.text.trim();
    if (text.isEmpty) return;
    replyController.clear();
    await widget.controller.replyToStory(story, text);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reply sent')));
  }

  Future<void> _hideAuthor(StoryItem story) async {
    await widget.controller.hideStoriesFrom(story.ownerNode);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Stories from ${story.ownerName} hidden')),
    );
  }

  Future<void> _showReactionPicker(StoryItem story) async {
    const reactions = <String>['heart', 'fire', 'laugh', 'wow', 'sad', 'clap'];
    final extraAvailable = meshProFeatureEnabled(
      widget.controller,
      'story_extra_reactions',
    );
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ActionSheetGlass(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'React to story',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final reaction in reactions)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton.filledTonal(
                        tooltip: _storyReactionLabel(reaction),
                        onPressed: () => Navigator.pop(context, reaction),
                        icon: Text(
                          _storyReactionEmoji(reaction),
                          style: const TextStyle(fontSize: 23),
                        ),
                      ),
                      if (reaction != 'heart' && !extraAvailable)
                        const Positioned(
                          right: -2,
                          bottom: -2,
                          child: Icon(
                            Icons.lock_rounded,
                            size: 14,
                            color: Colors.amberAccent,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    if (selected != 'heart' && !extraAvailable) {
      await showMeshProPaywall(
        context,
        widget.controller,
        featureId: 'story_extra_reactions',
        featureTitle: 'More story reactions',
        featureDescription:
            'React with fire, laughter, surprise, sadness or applause.',
      );
      return;
    }
    await widget.controller.reactToStory(story, selected);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.controller.stories[widget.story.id] ?? widget.story;
    final ownStory = story.ownerNode == widget.controller.myNodeId;
    final image = _storyImage(story.imageData);
    final left = story.createdAt
        .add(const Duration(hours: 24))
        .difference(DateTime.now());
    final hoursLeft = math.max(0, left.inHours);
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _HomeLiquidBackground(enabled: true)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      ),
                      const SizedBox(width: 10),
                      ProfileAvatar(
                        profile: Profile(
                          nodeId: story.ownerNode,
                          displayName: story.ownerName,
                          avatarData: story.ownerAvatarData,
                        ),
                        radius: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              story.ownerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                              ),
                            ),
                            Text(
                              hoursLeft <= 0
                                  ? 'Expires soon${story.hd ? '  ·  HD' : ''}'
                                  : 'Disappears in $hoursLeft h${story.hd ? '  ·  HD' : ''}',
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                      if (story.ownerNode != widget.controller.myNodeId)
                        IconButton.filledTonal(
                          tooltip: 'React',
                          onPressed: () => _showReactionPicker(story),
                          icon:
                              story
                                  .reactionFor(widget.controller.myNodeId)
                                  .isEmpty
                              ? const Icon(
                                  Icons.favorite_border_rounded,
                                  color: Colors.pinkAccent,
                                )
                              : Text(
                                  _storyReactionEmoji(
                                    story.reactionFor(
                                      widget.controller.myNodeId,
                                    ),
                                  ),
                                  style: const TextStyle(fontSize: 22),
                                ),
                        ),
                      if (!ownStory)
                        PopupMenuButton<String>(
                          icon: const Icon(
                            Icons.more_horiz_rounded,
                            color: Colors.white,
                          ),
                          color: const Color(0xFF172536),
                          onSelected: (value) {
                            if (value == 'hide') unawaited(_hideAuthor(story));
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'hide',
                              child: Row(
                                children: [
                                  Icon(Icons.visibility_off_rounded),
                                  SizedBox(width: 10),
                                  Text('Hide stories'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      if (ownStory) ...[
                        IconButton.filledTonal(
                          tooltip: 'Views',
                          onPressed: () => _showViewers(story),
                          icon: Badge.count(
                            count: story.viewedByNodeIds.length,
                            isLabelVisible: story.viewedByNodeIds.isNotEmpty,
                            child: const Icon(
                              Icons.visibility_rounded,
                              color: Colors.lightBlueAccent,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Delete story',
                          onPressed: () => _deleteStory(story),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: _HomeGlassSurface(
                      accent: Colors.lightBlueAccent,
                      radius: 30,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            if (story.mediaType == StoryMediaType.video &&
                                videoController != null)
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: videoController!.value.isInitialized
                                      ? AspectRatio(
                                          aspectRatio: videoController!
                                              .value
                                              .aspectRatio,
                                          child: VideoPlayer(videoController!),
                                        )
                                      : const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                ),
                              )
                            else if (image != null)
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: Image.memory(
                                    image,
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    gaplessPlayback: true,
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            if (story.text.isNotEmpty) ...[
                              if (image != null ||
                                  story.mediaType == StoryMediaType.video)
                                const SizedBox(height: 14),
                              Text(
                                story.text,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  height: 1.25,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                            if (story.reactionCount > 0) ...[
                              const SizedBox(height: 14),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  for (final entry in story.reactions.entries)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 9,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.08,
                                        ),
                                        borderRadius: BorderRadius.circular(99),
                                      ),
                                      child: Text(
                                        '${_storyReactionEmoji(entry.key)} ${entry.value.length}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            if (image == null &&
                                story.mediaType != StoryMediaType.video)
                              const Spacer(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!ownStory) ...[
                    const SizedBox(height: 12),
                    _HomeGlassSurface(
                      accent: Colors.lightBlueAccent,
                      radius: 24,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: replyController,
                                minLines: 1,
                                maxLines: 3,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  hintText: 'Reply to story',
                                  hintStyle: TextStyle(color: Colors.white38),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _sendReply(story),
                              ),
                            ),
                            IconButton.filled(
                              onPressed: () => _sendReply(story),
                              icon: const Icon(Icons.send_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<int> _storyVideoDurationSeconds(Uint8List bytes, String mime) async {
  if (bytes.isEmpty) return 0;
  final controller = VideoPlayerController.networkUrl(
    Uri.parse('data:$mime;base64,${base64Encode(bytes)}'),
  );
  try {
    await controller.initialize().timeout(const Duration(seconds: 8));
    return (controller.value.duration.inMilliseconds / 1000).ceil();
  } catch (_) {
    return 0;
  } finally {
    await controller.dispose();
  }
}

String _storyReactionEmoji(String reaction) {
  return switch (reaction) {
    'fire' => '🔥',
    'laugh' => '😂',
    'wow' => '😮',
    'sad' => '😢',
    'clap' => '👏',
    _ => '❤️',
  };
}

String _storyReactionLabel(String reaction) {
  return switch (reaction) {
    'fire' => 'Fire',
    'laugh' => 'Laugh',
    'wow' => 'Wow',
    'sad' => 'Sad',
    'clap' => 'Applause',
    _ => 'Heart',
  };
}

String _videoMime(String extension) {
  switch (extension.toLowerCase().replaceFirst('.', '')) {
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'm4v':
      return 'video/x-m4v';
    default:
      return 'video/mp4';
  }
}

String _formatStoryArchiveDate(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
}

Uint8List? _storyImage(String value) {
  if (value.isEmpty) return null;
  final comma = value.indexOf(',');
  final raw = comma >= 0 ? value.substring(comma + 1) : value;
  try {
    return base64Decode(raw);
  } catch (_) {
    return null;
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
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.92, end: 1),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              builder: (context, value, child) =>
                  Transform.scale(scale: value, child: child),
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
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 360;
              return Row(
                children: [
                  Expanded(child: _GlassLogoChip(compact: compact)),
                  SizedBox(width: compact ? 6 : 10),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 126 : 168),
                    child: _BluetoothStatusCard(
                      running: ble.running,
                      connected: connected,
                      online: online,
                      onTap: onBluetooth,
                      compact: compact,
                    ),
                  ),
                  SizedBox(width: compact ? 6 : 10),
                  _RoundGlassButton(
                    tooltip: 'New chat',
                    icon: Icons.add_rounded,
                    onPressed: onNewChat,
                    accent: Colors.lightBlueAccent,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          _HomeSearchField(onTap: onSearch),
          const SizedBox(height: 10),
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
    this.compact = false,
  });

  final bool running;
  final int connected;
  final bool online;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final active = running || connected > 0;
    final accent = active ? Colors.greenAccent : Colors.blueGrey;
    return MeshLiquidGlass(
      accent: accent,
      radius: 15,
      interactive: true,
      fallbackBuilder: (context, child) =>
          _HomeGlassSurface(accent: accent, radius: 15, child: child),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 9 : 13,
            9,
            compact ? 9 : 13,
            9,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.bluetooth_connected_rounded
                    : Icons.bluetooth_rounded,
                color: Colors.white,
                size: compact ? 20 : 22,
              ),
              SizedBox(width: compact ? 6 : 9),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Bluetooth',
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      color: Colors.white70,
                    ),
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
                          fontSize: compact ? 10 : 11,
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

class _HomeSearchField extends StatefulWidget {
  const _HomeSearchField({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_HomeSearchField> createState() => _HomeSearchFieldState();
}

class _HomeSearchFieldState extends State<_HomeSearchField> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: MeshLiquidGlass(
        accent: pressed ? Colors.lightBlueAccent : Colors.blueGrey,
        radius: 18,
        dim: false,
        selected: pressed,
        interactive: true,
        fallbackBuilder: (context, child) => _HomeGlassSurface(
          accent: pressed ? Colors.lightBlueAccent : Colors.blueGrey,
          radius: 18,
          dim: false,
          selected: pressed,
          child: child,
        ),
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => pressed = true),
          onTapCancel: () => setState(() => pressed = false),
          onTapUp: (_) => setState(() => pressed = false),
          borderRadius: BorderRadius.circular(18),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 21, color: Colors.white60),
                SizedBox(width: 10),
                Text(
                  'Search',
                  style: TextStyle(
                    color: Colors.white60,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassLogoChip extends StatelessWidget {
  const _GlassLogoChip({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Image.asset(
          'assets/app_icon.png',
          width: compact ? 44 : 54,
          height: compact ? 44 : 54,
        ),
        SizedBox(width: compact ? 7 : 10),
        Flexible(
          child: Text(
            'MeshChat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 19 : 24,
              fontWeight: FontWeight.w900,
            ),
          ),
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
    final liquidGlass = MeshPlatformScope.liquidGlassOf(context);
    final button = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 38,
        height: 38,
        child: Icon(icon, size: 20, color: Colors.white70),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: liquidGlass
          ? MeshLiquidGlass(
              accent: Colors.lightBlueAccent,
              radius: 999,
              dim: true,
              interactive: true,
              child: button,
            )
          : _HomeGlassSurface(
              accent: Colors.blueGrey,
              radius: 999,
              dim: true,
              child: button,
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

  int _selectedIndex() => switch (selected) {
    _HomeFilter.all => 0,
    _HomeFilter.personal => 1,
    _HomeFilter.groups => 2,
    _HomeFilter.channels => 3,
    _HomeFilter.bluetooth => 4,
  };

  @override
  Widget build(BuildContext context) {
    final liquidGlass = MeshPlatformScope.liquidGlassOf(context);
    const itemWidth = 104.0;
    const itemGap = 5.0;
    const settingsWidth = 38.0;
    const edgePadding = 3.0;
    final pills = <Widget>[
      _FilterPill(
        label: 'All',
        icon: Icons.all_inbox_rounded,
        selected: selected == _HomeFilter.all,
        onTap: () => onChanged(_HomeFilter.all),
      ),
      _FilterPill(
        label: 'Personal',
        icon: Icons.person_outline_rounded,
        selected: selected == _HomeFilter.personal,
        onTap: () => onChanged(_HomeFilter.personal),
      ),
      _FilterPill(
        label: 'Groups',
        icon: Icons.groups_rounded,
        selected: selected == _HomeFilter.groups,
        onTap: () => onChanged(_HomeFilter.groups),
      ),
      _FilterPill(
        label: 'Channels',
        icon: Icons.campaign_outlined,
        selected: selected == _HomeFilter.channels,
        onTap: () => onChanged(_HomeFilter.channels),
      ),
      _FilterPill(
        label: 'Bluetooth',
        icon: Icons.bluetooth_rounded,
        selected: selected == _HomeFilter.bluetooth,
        onTap: () => onChanged(_HomeFilter.bluetooth),
      ),
    ];
    final content = liquidGlass
        ? SizedBox(
            height: 44,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                width:
                    edgePadding * 2 +
                    itemWidth * pills.length +
                    itemGap * pills.length +
                    settingsWidth,
                height: 44,
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      left:
                          edgePadding +
                          _selectedIndex() * (itemWidth + itemGap),
                      top: edgePadding,
                      width: itemWidth,
                      height: 38,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      child: MeshLiquidGlass(
                        accent: Colors.lightBlueAccent,
                        radius: 19,
                        selected: true,
                        interactive: false,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(edgePadding),
                        child: Row(
                          children: [
                            for (
                              var index = 0;
                              index < pills.length;
                              index++
                            ) ...[
                              SizedBox(width: itemWidth, child: pills[index]),
                              const SizedBox(width: itemGap),
                            ],
                            const SizedBox(width: settingsWidth),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: edgePadding,
                      top: edgePadding,
                      width: settingsWidth,
                      height: settingsWidth,
                      child: _RoundFilterButton(
                        icon: Icons.tune_rounded,
                        tooltip: 'Settings',
                        onTap: onSettings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: pills.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 9),
              itemBuilder: (context, index) {
                if (index < pills.length) return pills[index];
                return _RoundFilterButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'Settings',
                  onTap: onSettings,
                );
              },
            ),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: liquidGlass
          ? MeshLiquidGlass(
              accent: Colors.lightBlueAccent,
              radius: 22,
              dim: true,
              interactive: true,
              child: content,
            )
          : content,
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
    final liquidGlass = MeshPlatformScope.liquidGlassOf(context);
    final content = TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: Container(
          constraints: const BoxConstraints(minWidth: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: Color.lerp(
                  Colors.white70,
                  Colors.lightBlueAccent,
                  value,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: Color.lerp(Colors.white70, Colors.white, value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (liquidGlass) {
      return content;
    }
    return _HomeGlassSurface(
      accent: selected ? Colors.lightBlueAccent : Colors.blueGrey,
      radius: 22,
      selected: selected,
      dim: !selected,
      child: content,
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
            : thread.isChannel
            ? const Color(0xFF9B7CFF)
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
                _GlassAvatar(
                  profile: thread.profile,
                  isGroup: thread.isGroup,
                  isChannel: thread.isChannel,
                ),
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
                            child: MeshProProfileName(
                              profile: thread.profile,
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
  const _GlassAvatar({
    required this.profile,
    required this.isGroup,
    required this.isChannel,
  });

  final Profile profile;
  final bool isGroup;
  final bool isChannel;

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
            Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: const Color(0xFF223244),
                child: Icon(isChannel ? Icons.campaign : Icons.group, size: 12),
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

class _JoinRequestGlassTile extends StatelessWidget {
  const _JoinRequestGlassTile({
    required this.request,
    required this.controller,
  });

  final GroupJoinRequest request;
  final AppController controller;

  Future<void> _accept(BuildContext context) async {
    final error = await controller.acceptGroupJoinRequest(request);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Request accepted')));
  }

  void _decline(BuildContext context) {
    controller.declineGroupJoinRequest(request);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Request declined')));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutBack,
        builder: (context, value, child) => Transform.scale(
          scale: 0.96 + value * 0.04,
          child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
        ),
        child: _HomeGlassSurface(
          accent: Colors.lightBlueAccent,
          radius: 24,
          selected: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                ProfileAvatar(profile: request.requester, radius: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${request.requester.displayName} wants to join',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${request.isChannel ? 'Channel' : 'Group'} · ${request.groupName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Decline',
                  onPressed: () => _decline(context),
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: 'Accept',
                  onPressed: () => _accept(context),
                  icon: const Icon(Icons.check_rounded),
                ),
              ],
            ),
          ),
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
    required this.onChannel,
    required this.onSettings,
    required this.onDiagnostics,
    required this.onLogout,
  });

  final AppController controller;
  final VoidCallback onProfile;
  final VoidCallback onGroup;
  final VoidCallback onChannel;
  final VoidCallback onSettings;
  final VoidCallback onDiagnostics;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 98),
      children: [
        _MeshProSettingsCard(controller: controller),
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
          icon: Icons.campaign_outlined,
          title: 'Create channel',
          subtitle: 'Broadcast posts to subscribers',
          onTap: onChannel,
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

class _MeshProSettingsCard extends StatefulWidget {
  const _MeshProSettingsCard({required this.controller});

  final AppController controller;

  @override
  State<_MeshProSettingsCard> createState() => _MeshProSettingsCardState();
}

class _MeshProSettingsCardState extends State<_MeshProSettingsCard> {
  Timer? clock;

  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subscription = widget.controller.meshProSubscription;
    final active = subscription.isActiveNow;
    final accent = active ? const Color(0xFF67F3C4) : const Color(0xFFB28AFF);
    return _HomeGlassSurface(
      accent: accent,
      radius: 24,
      selected: active,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium_rounded, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    active ? 'MeshPro active' : 'MeshPro',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh subscription',
                  onPressed: () =>
                      widget.controller.refreshMeshProSubscription(),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Text(
              meshProRemainingLabel(widget.controller),
              style: TextStyle(color: active ? accent : Colors.white60),
            ),
            if (meshProExpiryLabel(widget.controller).isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                meshProExpiryLabel(widget.controller),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => showMeshProPaywall(context, widget.controller),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(active ? 'Extend on Boosty' : 'Buy on Boosty'),
              ),
            ),
          ],
        ),
      ),
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

class _InlineActionTile extends StatefulWidget {
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
  State<_InlineActionTile> createState() => _InlineActionTileState();
}

class _InlineActionTileState extends State<_InlineActionTile> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedScale(
        scale: pressed ? 0.985 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: _HomeGlassSurface(
          accent: widget.accent,
          radius: 22,
          selected: pressed,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => pressed = true),
            onTapCancel: () => setState(() => pressed = false),
            onTapUp: (_) => setState(() => pressed = false),
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              leading: AnimatedScale(
                scale: pressed ? 1.12 : 1,
                duration: const Duration(milliseconds: 140),
                child: Icon(
                  widget.icon,
                  color: widget.accent.withValues(alpha: pressed ? 1 : 0.95),
                ),
              ),
              title: Text(widget.title),
              subtitle: Text(
                widget.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: AnimatedRotation(
                turns: pressed ? 0.03 : 0,
                duration: const Duration(milliseconds: 140),
                child: const Icon(Icons.chevron_right_rounded),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeBottomBar extends StatefulWidget {
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

  @override
  State<_HomeBottomBar> createState() => _HomeBottomBarState();
}

class _HomeBottomBarState extends State<_HomeBottomBar> {
  double? _dragCenterX;
  int? _dragIndex;
  bool _dragging = false;
  bool _dragMoving = false;
  bool _settling = false;
  Timer? _pauseTimer;
  Timer? _settleTimer;

  int _index(_HomeTab tab) => switch (tab) {
    _HomeTab.chats => 0,
    _HomeTab.settings => 1,
    _HomeTab.bluetooth => 2,
  };

  void _selectIndex(int index) {
    switch (index) {
      case 0:
        widget.onChats();
      case 1:
        widget.onSettings();
      case 2:
        widget.onBluetooth();
    }
  }

  void _updateDrag(double localX, double width) {
    final itemWidth = width / 3;
    final center = localX.clamp(itemWidth / 2, width - itemWidth / 2);
    final nextIndex = (center / itemWidth).floor().clamp(0, 2);
    if (_dragIndex != null && _dragIndex != nextIndex) {
      HapticFeedback.selectionClick();
    }
    _pauseTimer?.cancel();
    setState(() {
      _dragCenterX = center;
      _dragIndex = nextIndex;
      _dragMoving = true;
    });
    _pauseTimer = Timer(const Duration(milliseconds: 115), () {
      if (!mounted || !_dragging) return;
      setState(() => _dragMoving = false);
    });
  }

  void _startDrag(DragStartDetails details, double width) {
    _settleTimer?.cancel();
    setState(() {
      _dragging = true;
      _settling = false;
    });
    _updateDrag(details.localPosition.dx, width);
  }

  void _finishDrag({required bool commit}) {
    if (!_dragging) return;
    final target = _dragIndex ?? _index(widget.selected);
    _pauseTimer?.cancel();
    setState(() {
      _dragging = false;
      _dragMoving = false;
      _dragCenterX = null;
      _dragIndex = null;
      _settling = true;
    });
    if (commit) {
      HapticFeedback.mediumImpact();
      _selectIndex(target);
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _settling = false);
    });
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final liquidGlass = MeshPlatformScope.liquidGlassOf(context);
    final content = SizedBox(
      height: 76,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / 3;
            final selectedIndex = _dragIndex ?? _index(widget.selected);
            final indicatorLeft = _dragCenterX == null
                ? itemWidth * _index(widget.selected)
                : _dragCenterX! - itemWidth / 2;
            final indicatorScale = _dragging
                ? _dragMoving
                      ? const Offset(1.08, 0.90)
                      : const Offset(0.92, 0.94)
                : _settling
                ? const Offset(0.88, 0.86)
                : const Offset(1, 1);
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (details) =>
                  _startDrag(details, constraints.maxWidth),
              onHorizontalDragUpdate: (details) =>
                  _updateDrag(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragEnd: (_) => _finishDrag(commit: true),
              onHorizontalDragCancel: () => _finishDrag(commit: false),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    left: indicatorLeft,
                    top: 0,
                    width: itemWidth,
                    height: 56,
                    duration: _dragging
                        ? Duration.zero
                        : const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: TweenAnimationBuilder<Offset>(
                      tween: Tween(end: indicatorScale),
                      duration: Duration(milliseconds: _dragging ? 105 : 220),
                      curve: Curves.easeOutCubic,
                      builder: (context, scale, child) => Transform.scale(
                        scaleX: scale.dx,
                        scaleY: scale.dy,
                        child: child,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: liquidGlass
                            ? MeshLiquidGlass(
                                accent: Colors.lightBlueAccent,
                                radius: 22,
                                selected: true,
                                interactive: false,
                                child: const SizedBox.expand(),
                              )
                            : DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(22),
                                  gradient: _edgeGlassGradient(
                                    base: const Color(0xFF314456),
                                    alpha: 0.72,
                                    edgeBoost: 0.08,
                                  ),
                                  border: Border.all(
                                    color: Colors.lightBlueAccent.withValues(
                                      alpha: 0.32,
                                    ),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.lightBlueAccent.withValues(
                                        alpha: 0.18,
                                      ),
                                      blurRadius: 18,
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _BottomNavItem(
                          icon: Icons.forum_rounded,
                          label: 'Chats',
                          selected: selectedIndex == 0,
                          onTap: widget.onChats,
                        ),
                      ),
                      Expanded(
                        child: _BottomNavItem(
                          icon: Icons.settings_outlined,
                          label: 'Settings',
                          selected: selectedIndex == 1,
                          onTap: widget.onSettings,
                        ),
                      ),
                      Expanded(
                        child: _BottomNavItem(
                          icon: Icons.bluetooth_rounded,
                          label: 'Bluetooth',
                          selected: selectedIndex == 2,
                          onTap: widget.onBluetooth,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (liquidGlass) {
      return MeshLiquidGlass(
        accent: Colors.lightBlueAccent,
        radius: 28,
        prominent: true,
        interactive: true,
        child: content,
      );
    }
    return _HomeGlassSurface(
      accent: Colors.lightBlueAccent,
      radius: 28,
      child: content,
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
    return SizedBox(
      width: 96,
      height: 56,
      child: ClipRect(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: selected ? 1 : 0),
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutBack,
            builder: (context, value, _) {
              final isSettings = icon == Icons.settings_outlined;
              final isBluetooth = icon == Icons.bluetooth_rounded;
              final isChats = icon == Icons.forum_rounded;
              final rotation = isSettings ? value * math.pi * 0.75 : 0.0;
              final scale =
                  1.0 +
                  value *
                      (isBluetooth
                          ? 0.13
                          : isChats
                          ? 0.1
                          : 0.08);
              final lift = isChats ? -3.0 * math.sin(value * math.pi) : 0.0;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 96,
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.rotate(
                      angle: rotation,
                      child: Transform.translate(
                        offset: Offset(0, lift),
                        child: Transform.scale(
                          scale: scale,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (isBluetooth && value > 0)
                                Container(
                                  width: 24 + value * 8,
                                  height: 24 + value * 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.lightBlueAccent.withValues(
                                        alpha: 0.18 * value,
                                      ),
                                    ),
                                  ),
                                ),
                              Icon(
                                icon,
                                size: 21 + value * 2,
                                color: Color.lerp(
                                  Colors.white60,
                                  Colors.lightBlueAccent,
                                  value,
                                ),
                                shadows: [
                                  if (value > 0)
                                    Shadow(
                                      color: Colors.lightBlueAccent.withValues(
                                        alpha: 0.45 * value,
                                      ),
                                      blurRadius: 12 * value,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 3 - value),
                    SizedBox(
                      width: 80,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: Color.lerp(
                              Colors.white60,
                              Colors.white,
                              value,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
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
      child: MeshLiquidGlass(
        accent: accent,
        radius: 18,
        interactive: true,
        fallbackBuilder: (context, child) =>
            _HomeGlassSurface(accent: accent, radius: 18, child: child),
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
  const _HomeLiquidBackground({required this.enabled});

  final bool enabled;

  @override
  State<_HomeLiquidBackground> createState() => _HomeLiquidBackgroundState();
}

class _HomeLiquidBackgroundState extends State<_HomeLiquidBackground>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  late final Timer timer;
  bool appActive = true;
  bool tickerModeActive = true;

  bool get canAnimate => widget.enabled && appActive && tickerModeActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(milliseconds: 3200),
      frameInterval: const Duration(milliseconds: 80),
    );
    timer = Timer.periodic(const Duration(milliseconds: 9400), (_) {
      if (canAnimate) controller.forward(from: 0);
    });
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted && canAnimate) controller.forward(from: 0);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.valuesOf(context).enabled;
    if (tickerModeActive == next) return;
    tickerModeActive = next;
    _syncAnimationActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;
    _syncAnimationActivity();
  }

  void _syncAnimationActivity() {
    if (!canAnimate) {
      controller.stop(canceled: false);
    } else if (controller.value > 0 && controller.value < 1) {
      controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _HomeLiquidBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!canAnimate) controller.stop(canceled: false);
    if (canAnimate && !oldWidget.enabled) controller.forward(from: 0);
  }

  @override
  void dispose() {
    timer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF06101D),
            Color(0xFF071422),
            Color(0xFF111329),
            Color(0xFF07111E),
          ],
          stops: [0, 0.42, 0.72, 1],
        ),
      ),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return CustomPaint(
              isComplex: true,
              willChange: controller.isAnimating,
              painter: _HomeMeshPainter(t: canAnimate ? controller.value : 0),
            );
          },
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
    final cyanCenter = Offset(
      size.width * (0.18 + 0.035 * math.sin(phase * 0.7)),
      size.height * (0.14 + 0.025 * math.cos(phase * 0.9)),
    );
    final violetCenter = Offset(
      size.width * (0.88 + 0.03 * math.cos(phase * 0.6)),
      size.height * (0.30 + 0.035 * math.sin(phase * 0.8)),
    );
    drawRadialGlow(
      canvas,
      center: cyanCenter,
      radius: 330 + 10 * cyanPulse,
      color: const Color(0xFF40CFFF),
      opacity: 0.052 * cyanPulse,
    );
    drawRadialGlow(
      canvas,
      center: violetCenter,
      radius: 390 + 12 * violetPulse,
      color: const Color(0xFF9A6BFF),
      opacity: 0.050 * violetPulse,
    );
    drawRadialGlow(
      canvas,
      center: cyanCenter,
      radius: 74 + 4 * cyanPulse,
      color: const Color(0xFF40CFFF),
      opacity: 0.10 * cyanPulse,
    );
    drawRadialGlow(
      canvas,
      center: violetCenter,
      radius: 82 + 5 * violetPulse,
      color: const Color(0xFF9A6BFF),
      opacity: 0.10 * violetPulse,
    );
    drawRadialGlow(
      canvas,
      center: Offset(
        size.width * (0.55 + 0.025 * math.sin(phase * 0.45)),
        size.height * 0.92,
      ),
      radius: 410,
      color: const Color(0xFF348DFF),
      opacity: 0.022,
    );
  }

  @override
  bool shouldRepaint(covariant _HomeMeshPainter oldDelegate) {
    return oldDelegate.t != t;
  }
}

class _QueuedMessagesBanner extends StatelessWidget {
  const _QueuedMessagesBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.queuedMessageCount;
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: _HomeGlassSurface(
        accent: Colors.orangeAccent,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.orangeAccent.withValues(alpha: 0.13),
                  border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.26),
                  ),
                ),
                child: const Icon(
                  Icons.schedule_send_rounded,
                  color: Colors.orangeAccent,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$count waiting to send',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: controller.cancelQueuedMessages,
                child: const Text('Cancel'),
              ),
              FilledButton.tonal(
                onPressed: controller.retryQueuedMessagesNow,
                child: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
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
    return MeshLiquidGlass(
      radius: 20,
      accent: accent,
      prominent: true,
      fallbackBuilder: (context, child) => ClipRRect(
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
      ),
      child: child,
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
    final nativeMaterial = MeshPlatformScope.liquidGlassOf(context);
    final base = nativeMaterial
        ? selected
              ? const Color(0xFF263746)
              : dim
              ? const Color(0xFF111A25)
              : const Color(0xFF1B2B3B)
        : selected
        ? const Color(0xFF30414D)
        : dim
        ? const Color(0xFF18222D)
        : const Color(0xFF243241);
    final alpha = nativeMaterial
        ? selected
              ? 0.38
              : dim
              ? 0.17
              : 0.31
        : selected
        ? 0.80
        : dim
        ? 0.50
        : 0.70;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: _edgeGlassGradient(
          base: base,
          alpha: alpha,
          edgeBoost: nativeMaterial
              ? selected
                    ? 0.035
                    : 0.022
              : selected
              ? 0.075
              : dim
              ? 0.03
              : 0.052,
        ),
        border: Border.all(
          color: selected
              ? accent.withValues(alpha: 0.44)
              : dim
              ? Colors.white.withValues(alpha: nativeMaterial ? 0.10 : 0.08)
              : Colors.white.withValues(alpha: nativeMaterial ? 0.16 : 0.13),
        ),
        boxShadow: [
          if (selected)
            BoxShadow(color: accent.withValues(alpha: 0.16), blurRadius: 14),
          if (!dim)
            BoxShadow(
              color: Colors.white.withValues(
                alpha: nativeMaterial ? 0.02 : 0.018,
              ),
              blurRadius: 1,
              offset: const Offset(0, 1),
            ),
          BoxShadow(
            color: Colors.black.withValues(alpha: nativeMaterial ? 0.12 : 0.24),
            blurRadius: nativeMaterial
                ? 13
                : dim
                ? 10
                : 20,
            offset: Offset(
              0,
              nativeMaterial
                  ? 4
                  : dim
                  ? 5
                  : 10,
            ),
          ),
        ],
      ),
      child: child,
    );
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: nativeMaterial
          ? surface
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: surface,
            ),
    );
    return RepaintBoundary(child: clipped);
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
                title: MeshProProfileName(profile: thread.profile),
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
