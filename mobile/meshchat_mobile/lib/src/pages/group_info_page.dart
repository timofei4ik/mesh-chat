import 'dart:convert';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';
import 'chat_media_page.dart';
import 'meeting_point_map_page.dart';
import 'profile_page.dart';

class GroupInfoPage extends StatelessWidget {
  const GroupInfoPage({
    super.key,
    required this.controller,
    required this.thread,
  });

  final AppController controller;
  final ChatThread thread;

  String get inviteLink {
    final payload = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'type': thread.isChannel ? 'channel_invite' : 'group_invite',
          'group_id': thread.groupId,
          'name': thread.profile.displayName,
          'is_channel': thread.isChannel,
          'owner_node': thread.ownerNode,
        }),
      ),
    );
    return 'meshchat://group/$payload';
  }

  Future<void> showInvite(BuildContext context) async {
    final link = inviteLink;
    final copied = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _GroupGlassSurface(
            radius: 30,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    thread.isChannel
                        ? Icons.campaign_outlined
                        : Icons.group_add_outlined,
                    color: Colors.lightBlueAccent,
                    size: 34,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    thread.isChannel ? 'Channel invite' : 'Group invite',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: ColoredBox(
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(
                          data: link,
                          version: QrVersions.auto,
                          size: 190,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.circle,
                            color: Color(0xFF111827),
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.circle,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    link,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (context.mounted) Navigator.pop(context, true);
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy invite link'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    if (copied == true) _showSnack(context, 'Invite copied');
  }

  Future<void> addMember(BuildContext context) async {
    final input = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(thread.isChannel ? 'Add subscriber' : 'Add member'),
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
      _showSnack(
        context,
        thread.isChannel ? 'Already subscribed' : 'Already in group',
      );
      return;
    }

    final error = await controller.updateGroupMembers(thread, [
      ...thread.members,
      profile.nodeId,
    ], rotateKey: true);
    if (!context.mounted) return;
    _showSnack(
      context,
      error ?? (thread.isChannel ? 'Subscriber added' : 'Member added'),
    );
  }

  Future<void> removeMember(BuildContext context, Profile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(thread.isChannel ? 'Remove subscriber?' : 'Remove member?'),
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
    _showSnack(
      context,
      error ?? (thread.isChannel ? 'Subscriber removed' : 'Member removed'),
    );
  }

  void openProfile(BuildContext context, Profile profile) {
    Navigator.push<void>(
      context,
      PageRouteBuilder<void>(
        opaque: true,
        allowSnapshotting: false,
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 165),
        pageBuilder: (context, animation, secondaryAnimation) =>
            RepaintBoundary(child: ProfilePage(profile: profile)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
              child: child,
            ),
      ),
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
    if (error != null) {
      _showSnack(context, error);
      return;
    }
    Navigator.of(context).pop();
    final call = controller.activeCall;
    if (call != null && call.status != CallStatus.ended && call.collapsed) {
      controller.toggleCallCollapsed();
    }
  }

  Future<void> openMemberMap(BuildContext context) async {
    final locations = _latestSharedLocations();
    final meetingPoints = _meetingPoints();
    final firstLocation = locations.isNotEmpty
        ? locations.first.location
        : null;
    final firstMeeting = meetingPoints.isNotEmpty
        ? meetingPoints.first.point
        : null;
    final initialLat =
        firstLocation?.latitude ?? firstMeeting?.latitude ?? 59.934300;
    final initialLng =
        firstLocation?.longitude ?? firstMeeting?.longitude ?? 30.335100;
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => MeetingPointMapPage(
          title: '${thread.profile.displayName} map',
          latitude: initialLat,
          longitude: initialLng,
          allowMeetingPointCreation: true,
          pins: [
            for (final entry in locations)
              MeetingPointMapPin(
                title: _profileFor(entry.nodeId).displayName,
                latitude: entry.location.latitude,
                longitude: entry.location.longitude,
                note: entry.location.coordinateLabel,
                senderName: _profileFor(entry.nodeId).publicUsername.isEmpty
                    ? ''
                    : '@${_profileFor(entry.nodeId).publicUsername}',
                timestamp: _formatLocationTime(entry.createdAt),
                messageId: entry.messageId,
              ),
            for (final entry in meetingPoints)
              MeetingPointMapPin(
                title: entry.point.title,
                latitude: entry.point.latitude,
                longitude: entry.point.longitude,
                note: 'Meeting point',
                senderName: _profileFor(entry.nodeId).displayName,
                timestamp: _formatLocationTime(entry.createdAt),
                messageId: entry.messageId,
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || result == null) return;
    if (result is String && result.isNotEmpty) {
      Navigator.pop(context, result);
      return;
    }
    if (result is MeetingPointMapDeleteResult) {
      await _deleteMapMessage(context, result.messageId);
      return;
    }
    if (result is MeetingPointMapResult) {
      final name = controller.ownProfile.displayName.trim().isEmpty
          ? 'Member'
          : controller.ownProfile.displayName.trim();
      await controller.sendGroupMessage(
        thread,
        _MeetingPointProposal(
          title: '$name suggests meeting here',
          latitude: result.latitude,
          longitude: result.longitude,
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
        ).toMessageText(),
      );
      if (!context.mounted) return;
      _showSnack(context, 'Meeting point sent');
    }
  }

  Future<void> _deleteMapMessage(BuildContext context, String messageId) async {
    final message = _messageById(messageId);
    if (message == null) {
      _showSnack(context, 'Message not found');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete map message?'),
        content: const Text('This will delete the location or meeting point.'),
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
    if (ok != true || !context.mounted) return;
    await controller.deleteMessage(thread, message);
    if (!context.mounted) return;
    _showSnack(context, 'Deleted');
  }

  Future<void> leaveOrDelete(BuildContext context) async {
    final isOwner = _isOwner;
    final title = isOwner
        ? (thread.isChannel ? 'Delete channel?' : 'Delete group?')
        : (thread.isChannel ? 'Leave channel?' : 'Leave group?');
    final content = isOwner
        ? 'This removes it for everyone. This action cannot be undone.'
        : 'It will disappear from your chats and will not be restored after relogin.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(isOwner ? 'Delete' : 'Leave'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final error = isOwner
        ? await controller.deleteThreadForEveryone(thread)
        : await controller.leaveGroup(thread);
    if (!context.mounted) return;
    _showSnack(context, error ?? (isOwner ? 'Deleted' : 'Left'));
    if (error == null) {
      final navigator = Navigator.of(context);
      navigator.pop();
      if (navigator.canPop()) navigator.pop();
    }
  }

  Future<void> editGroupProfile(BuildContext context) async {
    var avatarData = thread.profile.avatarData;
    final nameInput = TextEditingController(text: thread.profile.displayName);
    final aboutInput = TextEditingController(text: thread.profile.about);
    final error = await showDialog<String?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(thread.isChannel ? 'Edit channel' : 'Edit group'),
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
    _showSnack(
      context,
      error.isEmpty
          ? (thread.isChannel ? 'Channel updated' : 'Group updated')
          : error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final effectiveOwnerNode = _effectiveOwnerNode();
        final visibleMemberSet = <String>{};
        final members = thread.members
            .where((nodeId) => nodeId.isNotEmpty)
            .where(
              (nodeId) =>
                  nodeId == effectiveOwnerNode ||
                  !_isLegacyOwnerPlaceholder(nodeId),
            )
            .where(visibleMemberSet.add)
            .toSet()
            .toList();
        if (effectiveOwnerNode.isNotEmpty &&
            !members.contains(effectiveOwnerNode)) {
          members.add(effectiveOwnerNode);
        }
        members.sort((a, b) {
          final aName = _profileFor(a).displayName.toLowerCase();
          final bName = _profileFor(b).displayName.toLowerCase();
          return aName.compareTo(bName);
        });
        final isOwner =
            effectiveOwnerNode.isEmpty ||
            effectiveOwnerNode == controller.myNodeId;
        final canManageChannel =
            isOwner || thread.admins.contains(controller.myNodeId);

        return Scaffold(
          backgroundColor: const Color(0xFF07111E),
          appBar: AppBar(
            backgroundColor: const Color(0xFF07111E),
            title: Text(thread.isChannel ? 'Channel info' : 'Group info'),
            actions: [
              IconButton(
                tooltip: thread.isChannel ? 'Edit channel' : 'Edit group',
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
                        thread.isChannel
                            ? '${members.length} subscribers'
                            : '${members.length} members',
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
                          if (!thread.isChannel)
                            _GroupActionButton(
                              icon: Icons.call_outlined,
                              label: 'Call',
                              onTap: () => startGroupCall(context),
                            ),
                          if (!thread.isChannel)
                            _GroupActionButton(
                              icon: Icons.map_outlined,
                              label: 'Map',
                              onTap: () => openMemberMap(context),
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
                          _GroupActionButton(
                            icon: Icons.qr_code_2_rounded,
                            label: 'Invite',
                            onTap: () => showInvite(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (thread.isChannel) ...[
                _GroupGlassSurface(
                  radius: 22,
                  child: SwitchListTile(
                    secondary: const Icon(Icons.forum_outlined),
                    title: const Text(
                      'Comments',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      thread.commentsEnabled
                          ? 'Subscribers can comment on posts'
                          : 'Only admins can reply to posts',
                    ),
                    value: thread.commentsEnabled,
                    onChanged: canManageChannel
                        ? (value) async {
                            final error = await controller
                                .updateChannelCommentsEnabled(thread, value);
                            if (!context.mounted) return;
                            _showSnack(
                              context,
                              error ??
                                  (value
                                      ? 'Comments enabled'
                                      : 'Comments disabled'),
                            );
                          }
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _GroupGlassSurface(
                radius: 22,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Roles',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        thread.isChannel
                            ? 'Owner: can manage subscribers and admins.'
                            : 'Owner: can add/remove members and admins.',
                      ),
                      Text(
                        thread.isChannel
                            ? 'Admin: can publish channel posts.'
                            : 'Admin: marked in the member list.',
                      ),
                      Text(
                        thread.isChannel
                            ? thread.commentsEnabled
                                  ? 'Subscriber: can read posts and comment.'
                                  : 'Subscriber: can read posts.'
                            : 'Member: can read and send messages.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  thread.isChannel ? 'Subscribers' : 'Members',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (members.isEmpty)
                Text(
                  thread.isChannel
                      ? 'Subscriber list is not loaded yet'
                      : 'Member list is not loaded yet',
                  style: const TextStyle(color: Colors.white54),
                )
              else
                ...members.map((nodeId) {
                  final profile = _profileFor(nodeId);
                  final role = _roleFor(nodeId);
                  final canRemove =
                      isOwner &&
                      nodeId != controller.myNodeId &&
                      nodeId != effectiveOwnerNode;
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
                                tooltip: thread.isChannel
                                    ? 'Remove from channel'
                                    : 'Remove from group',
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
              const SizedBox(height: 14),
              _GroupGlassSurface(
                radius: 22,
                child: ListTile(
                  leading: Icon(
                    isOwner ? Icons.delete_forever_outlined : Icons.logout,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    isOwner
                        ? (thread.isChannel ? 'Delete channel' : 'Delete group')
                        : (thread.isChannel ? 'Leave channel' : 'Leave group'),
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  subtitle: Text(
                    isOwner
                        ? 'Only owner can delete it for everyone'
                        : 'You will not be added back after relogin',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  onTap: () => leaveOrDelete(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Profile _profileFor(String nodeId) {
    return controller.profiles[nodeId] ??
        Profile(
          nodeId: nodeId,
          displayName: nodeId.length <= 8 ? nodeId : nodeId.substring(0, 8),
        );
  }

  String _effectiveOwnerNode() {
    final owner = thread.ownerNode.trim();
    if (owner.isEmpty || owner == controller.myNodeId) {
      return controller.myNodeId;
    }
    if (_isLegacyOwnerPlaceholder(owner) &&
        thread.members.contains(controller.myNodeId)) {
      return controller.myNodeId;
    }
    return owner;
  }

  bool _isLegacyOwnerPlaceholder(String nodeId) {
    final value = nodeId.trim();
    if (value.isEmpty || value == controller.myNodeId) return false;
    final uuidLike = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
    return !uuidLike && value.length <= 12;
  }

  bool get _isOwner {
    final owner = _effectiveOwnerNode();
    return owner.isEmpty || owner == controller.myNodeId;
  }

  String _roleFor(String nodeId) {
    if (nodeId == _effectiveOwnerNode()) return 'owner';
    if (thread.admins.contains(nodeId)) return 'admin';
    return '';
  }

  List<_SharedLocationEntry> _latestSharedLocations() {
    final allowedMembers = thread.members.toSet()..add(controller.myNodeId);
    final owner = _effectiveOwnerNode();
    if (owner.isNotEmpty) allowedMembers.add(owner);
    final latest = <String, _SharedLocationEntry>{};
    for (final message in thread.messages) {
      if (message.deleted) continue;
      if (allowedMembers.isNotEmpty &&
          !allowedMembers.contains(message.senderNode)) {
        continue;
      }
      final location = _SharedLocation.fromMessageText(message.text);
      if (location == null) continue;
      if (location.isExpired) continue;
      final previous = latest[message.senderNode];
      if (previous == null || message.createdAt.isAfter(previous.createdAt)) {
        latest[message.senderNode] = _SharedLocationEntry(
          nodeId: message.senderNode,
          messageId: message.id,
          location: location,
          createdAt: message.createdAt,
        );
      }
    }
    final result = latest.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  List<_MeetingPointEntry> _meetingPoints() {
    final result = <_MeetingPointEntry>[];
    for (final message in thread.messages) {
      if (message.deleted) continue;
      final point = _MeetingPointProposal.fromMessageText(message.text);
      if (point == null) continue;
      if (point.isExpired) continue;
      result.add(
        _MeetingPointEntry(
          nodeId: message.senderNode,
          messageId: message.id,
          point: point,
          createdAt: message.createdAt,
        ),
      );
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  ChatMessage? _messageById(String id) {
    for (final message in thread.messages) {
      if (message.id == id) return message;
    }
    return null;
  }

  static String _formatLocationTime(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SharedLocationEntry {
  const _SharedLocationEntry({
    required this.nodeId,
    required this.messageId,
    required this.location,
    required this.createdAt,
  });

  final String nodeId;
  final String messageId;
  final _SharedLocation location;
  final DateTime createdAt;
}

class _MeetingPointEntry {
  const _MeetingPointEntry({
    required this.nodeId,
    required this.messageId,
    required this.point,
    required this.createdAt,
  });

  final String nodeId;
  final String messageId;
  final _MeetingPointProposal point;
  final DateTime createdAt;
}

class _MeetingPointProposal {
  const _MeetingPointProposal({
    required this.title,
    required this.latitude,
    required this.longitude,
    this.expiresAt,
  });

  static const prefix = '::meshchat_meeting_v1::';

  final String title;
  final double latitude;
  final double longitude;
  final DateTime? expiresAt;

  bool get isExpired {
    final value = expiresAt;
    return value != null && DateTime.now().toUtc().isAfter(value.toUtc());
  }

  String toMessageText() {
    return '$prefix${jsonEncode({'title': title.trim().isEmpty ? 'Meeting point' : title.trim(), 'lat': latitude, 'lng': longitude, 'note': '', if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String()})}';
  }

  static _MeetingPointProposal? fromMessageText(String text) {
    if (!text.startsWith(prefix)) return null;
    try {
      final raw = jsonDecode(text.substring(prefix.length));
      if (raw is! Map) return null;
      final lat = double.tryParse(raw['lat']?.toString() ?? '');
      final lng = double.tryParse(raw['lng']?.toString() ?? '');
      if (lat == null ||
          lng == null ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        return null;
      }
      final title = raw['title']?.toString().trim() ?? '';
      return _MeetingPointProposal(
        title: title.isEmpty ? 'Meeting point' : title,
        latitude: lat,
        longitude: lng,
        expiresAt: DateTime.tryParse(raw['expires_at']?.toString() ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

class _SharedLocation {
  const _SharedLocation({
    required this.latitude,
    required this.longitude,
    this.expiresAt,
  });

  static const prefix = '::meshchat_location_v1::';

  final double latitude;
  final double longitude;
  final DateTime? expiresAt;

  bool get isExpired {
    final value = expiresAt;
    return value != null && DateTime.now().toUtc().isAfter(value.toUtc());
  }

  String get coordinateLabel {
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  static _SharedLocation? fromMessageText(String text) {
    if (!text.startsWith(prefix)) return null;
    try {
      final raw = jsonDecode(text.substring(prefix.length));
      if (raw is! Map) return null;
      final lat = double.tryParse(raw['lat']?.toString() ?? '');
      final lng = double.tryParse(raw['lng']?.toString() ?? '');
      if (lat == null ||
          lng == null ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        return null;
      }
      return _SharedLocation(
        latitude: lat,
        longitude: lng,
        expiresAt: DateTime.tryParse(raw['expires_at']?.toString() ?? ''),
      );
    } catch (_) {
      return null;
    }
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
