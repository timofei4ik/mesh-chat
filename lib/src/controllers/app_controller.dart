import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/app_settings.dart';
import '../models/profile.dart';
import '../models/session.dart';
import '../services/app_settings_store.dart';
import '../services/chat_cache_store.dart';
import '../services/mesh_crypto.dart';
import '../services/mesh_socket.dart';
import '../services/notification_service.dart';
import '../services/session_store.dart';

class AppController extends ChangeNotifier {
  static const _fileChunkHexSize = 128 * 1024;
  static const maxMobileFileBytes = 32 * 1024 * 1024;
  static const _maxProfilePacketBytes = 900 * 1024;

  final SessionStore _store = SessionStore();
  final AppSettingsStore _settingsStore = AppSettingsStore();
  final ChatCacheStore _cache = ChatCacheStore();
  final MeshSocket _socket = MeshSocket();
  final MeshCrypto _crypto = MeshCrypto();
  final NotificationService _notifications = NotificationService();
  final Map<String, Profile> profiles = {};
  final Map<String, ChatThread> threads = {};
  final Map<String, ChatThread> groups = {};
  final Map<String, DateTime> typingUntil = {};

  Session? session;
  List<Session> recentSessions = [];
  AppSettings appSettings = const AppSettings();
  bool initialized = false;
  bool busy = false;
  String status = 'Offline';
  DateTime? lastSyncAt;
  String? error;
  Completer<Profile?>? _lookupCompleter;
  Completer<String?>? _profileUpdateCompleter;
  Completer<List<ActiveDevice>>? _activeDevicesCompleter;
  final Map<String, _IncomingFile> _incomingFiles = {};
  final Map<String, _GroupKey> _groupKeys = {};

  bool get hasSession => session != null;
  String get myNodeId => session?.nodeId ?? '';
  Profile get ownProfile {
    final current = session;
    if (current == null) {
      return const Profile(nodeId: '', displayName: 'Пользователь');
    }
    return profiles[current.nodeId] ??
        Profile(
          nodeId: current.nodeId,
          displayName: current.login,
          publicUsername: current.publicUsername,
          publicKey: _crypto.publicKey,
          online: status == 'Online' || status.startsWith('Online:'),
        );
  }

  List<ChatThread> get sortedThreads {
    final result = [
      ...threads.values,
      ...groups.values,
    ].where((thread) => !thread.archived).toList();
    result.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final aTime = a.lastMessage?.createdAt ?? DateTime(1970);
      final bTime = b.lastMessage?.createdAt ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return result;
  }

  List<ChatThread> get archivedThreads {
    final result = [
      ...threads.values,
      ...groups.values,
    ].where((thread) => thread.archived).toList();
    result.sort((a, b) {
      final aTime = a.lastMessage?.createdAt ?? DateTime(1970);
      final bTime = b.lastMessage?.createdAt ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return result;
  }

  bool isTyping(ChatThread thread) {
    final key = thread.isGroup ? thread.groupId : thread.profile.nodeId;
    final until = typingUntil[key];
    return until != null && until.isAfter(DateTime.now());
  }

  Future<void> restoreSession() async {
    unawaited(_notifications.initialize());
    appSettings = await _settingsStore.load();
    recentSessions = await _store.loadRecent();
    session = await _store.load();
    if (session != null) {
      await _cache.load(session!, profiles, threads, groups);
      _restoreGroupKeysFromThreads();
      await _repairCachedGroupMessages();
    }
    initialized = true;
    notifyListeners();
    if (session != null) await _connect();
  }

  Future<void> handleAppResumed() async {
    unawaited(_notifications.initialize());
    if (session == null) return;
    if (!_socket.isConnected) {
      await _connect();
    }
  }

  Future<bool> login({
    required String serverUrl,
    required String token,
    required String login,
    required String password,
    required String publicUsername,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final normalized = _normalizeServerUrl(serverUrl);
      final candidate = await _store.save(
        serverUrl: normalized,
        serverToken: token.trim(),
        login: login.trim().toLowerCase(),
        password: password,
        publicUsername: publicUsername.trim().toLowerCase().replaceFirst(
          '@',
          '',
        ),
      );
      await _crypto.initialize(candidate.login, candidate.password);
      final checkError = await _socket.check(candidate, _crypto.publicKey);
      if (checkError != null) {
        error = checkError;
        await _store.clear();
        await _store.removeRecent(candidate);
        recentSessions = await _store.loadRecent();
        return false;
      }
      await _socket.close();
      _clearLocalState();
      session = candidate;
      recentSessions = await _store.loadRecent();
      await _cache.load(candidate, profiles, threads, groups);
      _restoreGroupKeysFromThreads();
      await _repairCachedGroupMessages();
      await _connect();
      return true;
    } catch (exception) {
      error = exception.toString();
      await _store.clear();
      recentSessions = await _store.loadRecent();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> quickLogin(Session candidate) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _crypto.initialize(candidate.login, candidate.password);
      final checkError = await _socket.check(candidate, _crypto.publicKey);
      if (checkError != null) {
        error = checkError;
        return false;
      }
      await _socket.close();
      _clearLocalState();
      await _store.saveCurrent(candidate);
      await _store.saveRecent(candidate);
      session = candidate;
      recentSessions = await _store.loadRecent();
      await _cache.load(candidate, profiles, threads, groups);
      _restoreGroupKeysFromThreads();
      await _repairCachedGroupMessages();
      await _connect();
      return true;
    } catch (exception) {
      error = exception.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> forgetRecent(Session recent) async {
    await _store.removeRecent(recent);
    recentSessions = await _store.loadRecent();
    notifyListeners();
  }

  Future<void> _connect() async {
    final current = session;
    if (current == null) return;
    await _crypto.initialize(current.login, current.password);
    await _socket.connect(
      session: current,
      publicKey: _crypto.publicKey,
      onPacket: _handlePacket,
      onStatus: (value) {
        status = value;
        notifyListeners();
      },
    );
  }

  Future<void> _handlePacket(Map<String, dynamic> packet) async {
    switch (packet['type']) {
      case 'server_welcome':
        if (!MeshSocket.isProtocolCompatible(packet)) {
          status = MeshSocket.protocolError(packet);
        } else {
          status = 'Online';
        }
      case 'server_error':
        if (packet['code'] == 'incompatible_protocol') {
          status = MeshSocket.protocolError(packet);
        } else {
          status =
              packet['message']?.toString() ??
              packet['reason']?.toString() ??
              'Server error';
        }
        notifyListeners();
      case 'server_users':
        _applyOnlineUsers(packet['users']);
      case 'server_sync':
        await _applySync(packet);
      case 'server_sync_done':
        status = 'Online';
        lastSyncAt = DateTime.now();
        await _saveCache();
      case 'username_lookup_result':
        _handleLookup(packet);
      case 'profile_update_result':
        _handleProfileUpdateResult(packet);
      case 'active_devices':
        _handleActiveDevices(packet);
      case 'chat_message':
        await _receiveMessage(packet);
      case 'group_message':
        await _receiveGroupMessage(packet, fromSync: false);
      case 'group_update':
        await _receiveGroupUpdate(packet);
      case 'file_chunk':
        await _receiveFileChunk(packet, fromSync: false);
      case 'server_file_sync_chunk':
        await _receiveFileChunk(packet, fromSync: true);
      case 'message_received':
        _markDelivered(packet['message_id']?.toString() ?? '');
      case 'message_reaction':
      case 'group_reaction':
        _applyReactionPacket(packet);
      case 'message_edit':
      case 'group_message_edit':
        await _applyEditPacket(packet);
      case 'message_delete':
      case 'group_message_delete':
        _applyDeletePacket(packet);
      case 'message_pin':
      case 'group_pin':
        _applyPinPacket(packet);
      case 'typing':
        _applyTypingPacket(packet);
      case 'chat_request':
        _acceptChatRequest(packet);
    }
    notifyListeners();
  }

  void _applyOnlineUsers(dynamic rawUsers) {
    final onlineIds = <String>{};
    final onlineUsernames = <String>{};
    for (final raw in rawUsers is List ? rawUsers : const []) {
      if (raw is! Map) continue;
      final profile = Profile.fromJson(Map<String, dynamic>.from(raw));
      if (profile.nodeId.isEmpty || profile.nodeId == myNodeId) continue;
      onlineIds.add(profile.nodeId);
      final username = profile.publicUsername.trim().toLowerCase();
      if (username.isNotEmpty) onlineUsernames.add(username);
      final onlineProfile = profile.copyWith(online: true);
      profiles[profile.nodeId] = onlineProfile;
      if (threads.containsKey(profile.nodeId)) {
        threads[profile.nodeId]!.profile = onlineProfile;
      }
    }
    for (final entry in profiles.entries.toList()) {
      final username = entry.value.publicUsername.trim().toLowerCase();
      final online =
          onlineIds.contains(entry.key) ||
          (username.isNotEmpty && onlineUsernames.contains(username));
      if (!online) {
        profiles[entry.key] = entry.value.copyWith(online: false);
        if (threads.containsKey(entry.key)) {
          threads[entry.key]!.profile = profiles[entry.key]!;
        }
      } else if (threads.containsKey(entry.key)) {
        profiles[entry.key] = entry.value.copyWith(online: true);
        threads[entry.key]!.profile = profiles[entry.key]!;
      }
    }
    unawaited(_saveCache());
  }

  Future<void> _applySync(Map<String, dynamic> packet) async {
    var addedMessages = 0;
    var skippedMessages = 0;

    if (packet['profile'] is Map) {
      final profile = Profile.fromJson(
        Map<String, dynamic>.from(packet['profile'] as Map),
      );
      if (profile.nodeId.isNotEmpty) {
        profiles[profile.nodeId] = profile.copyWith(online: true);
        final username = profile.publicUsername.trim().toLowerCase();
        if (username.isNotEmpty && session != null) {
          session = session!.copyWith(publicUsername: username);
          await _store.updatePublicUsername(username);
        }
      }
    }

    for (final raw
        in packet['profiles'] is List ? packet['profiles'] as List : const []) {
      if (raw is! Map) continue;
      final profile = Profile.fromJson(Map<String, dynamic>.from(raw));
      if (profile.nodeId.isNotEmpty && profile.nodeId != myNodeId) {
        final current =
            profiles[profile.nodeId] ?? threads[profile.nodeId]?.profile;
        final merged = profile.copyWith(online: current?.online ?? false);
        profiles[profile.nodeId] = merged;
        if (threads.containsKey(profile.nodeId)) {
          threads[profile.nodeId]!.profile = merged;
        }
      }
    }

    for (final raw
        in packet['direct_messages'] is List
            ? packet['direct_messages'] as List
            : const []) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final sender = data['sender_node']?.toString() ?? '';
      final receiver = data['receiver_node']?.toString() ?? '';
      final senderLogin = data['sender_login']?.toString().toLowerCase() ?? '';
      final receiverLogin =
          data['receiver_login']?.toString().toLowerCase() ?? '';
      final myLogin = session?.login.toLowerCase() ?? '';
      final sentByMe =
          sender == myNodeId ||
          (senderLogin.isNotEmpty && senderLogin == myLogin);
      final receivedByMe =
          receiver == myNodeId ||
          (receiverLogin.isNotEmpty && receiverLogin == myLogin);
      final peerId = sentByMe ? receiver : sender;
      if (!sentByMe && !receivedByMe) continue;
      if (peerId.isEmpty || peerId == myNodeId) continue;
      final profile =
          profiles[peerId] ??
          Profile(
            nodeId: peerId,
            displayName:
                data['sender_name']?.toString() ?? peerId.substring(0, 8),
          );
      profiles[peerId] = profile;
      final thread = _ensureThread(profile);
      final id = data['message_id']?.toString() ?? const Uuid().v4();
      if (thread.messages.any((message) => message.id == id)) continue;
      final rawText = _firstString(data, const [
        'message',
        'text',
        'content',
        'body',
      ]);
      if (rawText.isEmpty) {
        skippedMessages++;
        continue;
      }
      final text = await _decryptHistoryText(rawText);
      thread.messages.add(
        ChatMessage(
          id: id,
          senderNode: sentByMe ? myNodeId : sender,
          receiverNode: receiver,
          text: text,
          createdAt: _parsePacketDate(data),
          replyToMessageId: data['reply_to_message_id']?.toString() ?? '',
          replyToText: data['reply_to_text']?.toString() ?? '',
          delivered: true,
        ),
      );
      addedMessages++;
      thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    if (addedMessages > 0 || skippedMessages > 0) {
      status = skippedMessages > 0
          ? 'Online: synced $addedMessages, skipped $skippedMessages'
          : 'Online: synced $addedMessages';
    }

    _applyGroups(packet['groups']);
    for (final raw
        in packet['group_messages'] is List
            ? packet['group_messages'] as List
            : const []) {
      if (raw is! Map) continue;
      await _receiveGroupMessage(
        Map<String, dynamic>.from(raw),
        fromSync: true,
      );
    }
    _applyReactions(packet['reactions']);
    _applyPins(packet['pins']);
    await _saveCache();
  }

  Future<Profile?> lookupUsername(String username) async {
    if (_lookupCompleter != null) return null;
    _lookupCompleter = Completer<Profile?>();
    _socket.send({
      'type': 'username_lookup',
      'source_node': myNodeId,
      'username': username.trim().toLowerCase().replaceFirst('@', ''),
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'ttl': 5,
    });
    return _lookupCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _lookupCompleter = null;
        return null;
      },
    );
  }

  Future<String?> updateProfile({
    required String displayName,
    required String publicUsername,
    required String about,
    required String avatarData,
  }) async {
    final current = session;
    if (current == null) return 'Нет активной сессии';
    if (_profileUpdateCompleter != null) return 'Обновление уже выполняется';

    final normalizedUsername = publicUsername.trim().toLowerCase().replaceFirst(
      '@',
      '',
    );
    final name = displayName.trim().isEmpty
        ? current.login
        : displayName.trim();
    if (!_socket.isConnected) {
      return 'Нет подключения к серверу';
    }
    final packet = {
      'type': 'profile_update',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': current.nodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'login': current.login,
      'display_name': name,
      'public_username': normalizedUsername,
      'about': about.trim(),
      'avatar_data': avatarData,
      'encryption_public_key': _crypto.publicKey,
    };
    final packetBytes = utf8.encode(jsonEncode(packet)).length;
    if (packetBytes > _maxProfilePacketBytes) {
      return 'Профиль слишком большой. Уменьши аватарку или удали её.';
    }

    _profileUpdateCompleter = Completer<String?>();
    try {
      _socket.send(packet);
    } catch (error) {
      _profileUpdateCompleter = null;
      return 'Не удалось отправить профиль: $error';
    }
    final result = await _profileUpdateCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 'Сервер не ответил',
    );
    _profileUpdateCompleter = null;
    if (result != null) return result;

    session = current.copyWith(publicUsername: normalizedUsername);
    await _store.updatePublicUsername(normalizedUsername);
    final profile = Profile(
      nodeId: current.nodeId,
      displayName: name,
      publicUsername: normalizedUsername,
      about: about.trim(),
      avatarData: avatarData,
      publicKey: _crypto.publicKey,
      online: true,
    );
    profiles[current.nodeId] = profile;
    await _saveCache();
    notifyListeners();
    return null;
  }

  void _applyGroups(dynamic rawGroups) {
    for (final raw in rawGroups is List ? rawGroups : const []) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final groupId = data['group_id']?.toString() ?? '';
      if (groupId.isEmpty) continue;
      _ensureGroupThread(
        groupId: groupId,
        groupName: data['group_name']?.toString() ?? 'Группа',
        members: _stringList(data['members']),
        ownerNode: data['owner_node']?.toString() ?? '',
        admins: _stringList(data['admins']),
      );
      for (final rawKey
          in data['group_keys'] is List
              ? data['group_keys'] as List
              : const []) {
        if (rawKey is! Map) continue;
        unawaited(
          _acceptGroupKeyEnvelope(
            groupId,
            rawKey['key_id']?.toString() ?? '',
            rawKey['key_envelope']?.toString() ?? '',
          ),
        );
      }
    }
    unawaited(_saveCache());
  }

  ChatThread _ensureGroupThread({
    required String groupId,
    required String groupName,
    List<String> members = const [],
    String ownerNode = '',
    List<String> admins = const [],
  }) {
    final existing = groups[groupId];
    if (existing != null) {
      if (groupName.isNotEmpty) {
        existing.profile = existing.profile.copyWith(displayName: groupName);
      }
      if (members.isNotEmpty) {
        existing.members
          ..clear()
          ..addAll(members);
      }
      if (admins.isNotEmpty) {
        existing.admins
          ..clear()
          ..addAll(admins);
      }
      return existing;
    }
    final profile = Profile(
      nodeId: 'group:$groupId',
      displayName: groupName.isEmpty ? 'Группа' : groupName,
    );
    final thread = ChatThread(
      profile: profile,
      isGroup: true,
      groupId: groupId,
      groupName: groupName.isEmpty ? 'Группа' : groupName,
      members: members,
      ownerNode: ownerNode,
      admins: admins,
    );
    groups[groupId] = thread;
    return thread;
  }

  Future<void> sendGroupMessage(
    ChatThread group,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || session == null || !group.isGroup) return;
    final id = const Uuid().v4();
    group.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: group.groupId,
        text: trimmed,
        createdAt: DateTime.now(),
        replyToMessageId: replyTo?.id ?? '',
        replyToText: replyTo == null ? '' : _replyPreview(replyTo),
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();

    final groupKey = _getOrCreateGroupKey(group.groupId);
    final encryptedText = await _crypto.encryptGroupText(groupKey.key, trimmed);
    final senderEnvelope = await _crypto.wrapGroupKey(
      _crypto.publicKey,
      groupKey.key,
    );
    final basePacket = {
      'type': 'group_message',
      'packet_id': id,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': group.groupId,
      'group_name': group.groupName.isEmpty
          ? group.profile.displayName
          : group.groupName,
      'group_message_id': id,
      'members': group.members,
      'owner_node': group.ownerNode,
      'admins': group.admins,
      'message': encryptedText,
      'reply_to_message_id': replyTo?.id ?? '',
      'reply_to_text': replyTo == null ? '' : _replyPreview(replyTo),
      'group_key_id': groupKey.id,
      'group_key_sender_envelope': senderEnvelope,
    };
    var sent = false;
    for (final member in group.members.where((member) => member != myNodeId)) {
      final publicKey = profiles[member]?.publicKey ?? '';
      if (publicKey.isEmpty) continue;
      _socket.send({
        ...basePacket,
        'destination_node': member,
        'group_key_envelope': await _crypto.wrapGroupKey(
          publicKey,
          groupKey.key,
        ),
      });
      sent = true;
    }
    if (!sent) {
      _socket.send({
        ...basePacket,
        'destination_node': 'SERVER',
        'group_key_envelope': senderEnvelope,
      });
    }
    _replaceMessage(id, (message) => message.copyWith(pending: false));
  }

  Future<void> _receiveGroupMessage(
    Map<String, dynamic> packet, {
    required bool fromSync,
  }) async {
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isEmpty) return;
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: _stringList(packet['members']),
    );
    final id =
        packet['group_message_id']?.toString() ??
        packet['message_id']?.toString() ??
        packet['packet_id']?.toString() ??
        const Uuid().v4();
    await _acceptGroupKeyEnvelope(
      groupId,
      packet['group_key_id']?.toString() ?? '',
      packet['group_key_envelope']?.toString() ??
          packet['group_key_sender_envelope']?.toString() ??
          '',
    );
    final existingIndex = group.messages.indexWhere(
      (message) => message.id == id,
    );
    if (existingIndex >= 0) {
      await _repairGroupMessageText(group, existingIndex, packet);
      return;
    }
    final packetSender = packet['sender_node']?.toString().isNotEmpty == true
        ? packet['sender_node'].toString()
        : packet['source_node']?.toString() ?? '';
    final senderLogin = packet['sender_login']?.toString().toLowerCase() ?? '';
    final myLogin = session?.login.toLowerCase() ?? '';
    final sentByMe =
        packetSender == myNodeId ||
        (senderLogin.isNotEmpty && senderLogin == myLogin);
    final sender = sentByMe ? myNodeId : packetSender;
    final senderName =
        packet['sender_name']?.toString() ??
        packet['sender']?.toString() ??
        sender;
    final prefix = sentByMe || senderName.isEmpty ? '' : '$senderName: ';
    final rawText = _firstString(packet, const ['message', 'text', 'content']);
    if (rawText.isEmpty) return;
    final text = await _crypto.decryptGroupText(
      _groupKeys[groupId]?.key,
      rawText,
    );
    group.messages.add(
      ChatMessage(
        id: id,
        senderNode: sender,
        receiverNode: groupId,
        text: '$prefix$text',
        createdAt: _parsePacketDate(packet),
        replyToMessageId: packet['reply_to_message_id']?.toString() ?? '',
        replyToText: packet['reply_to_text']?.toString() ?? '',
        delivered: true,
      ),
    );
    group.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (!fromSync && sender != myNodeId) {
      group.unread++;
      if (!group.muted) {
        unawaited(
          _showNotification(
            title: group.profile.displayName,
            body: '$senderName: $text',
          ),
        );
      }
    }
    await _saveCache();
  }

  Future<void> _repairGroupMessageText(
    ChatThread group,
    int messageIndex,
    Map<String, dynamic> packet,
  ) async {
    final current = group.messages[messageIndex];
    if (!current.text.startsWith(MeshCrypto.groupPrefix)) return;
    final rawText = _firstString(packet, const ['message', 'text', 'content']);
    if (rawText.isEmpty) return;
    final text = await _crypto.decryptGroupText(
      _groupKeys[group.groupId]?.key,
      rawText,
    );
    if (text.isEmpty || text.startsWith(MeshCrypto.groupPrefix)) return;
    group.messages[messageIndex] = current.copyWith(text: text);
    await _saveCache();
    notifyListeners();
  }

  Future<void> _receiveGroupUpdate(Map<String, dynamic> packet) async {
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isEmpty) return;
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: _stringList(packet['members']),
      ownerNode: packet['owner_node']?.toString() ?? '',
      admins: _stringList(packet['admins']),
    );
    await _acceptGroupKeyEnvelope(
      groupId,
      packet['group_key_id']?.toString() ?? '',
      packet['group_key_envelope']?.toString() ??
          packet['group_key_sender_envelope']?.toString() ??
          '',
    );
    groups[group.groupId] = group;
    await _saveCache();
  }

  void _handleLookup(Map<String, dynamic> packet) {
    final completer = _lookupCompleter;
    _lookupCompleter = null;
    if (completer == null ||
        packet['ok'] != true ||
        packet['profile'] is! Map) {
      completer?.complete(null);
      return;
    }
    final profile = Profile.fromJson(
      Map<String, dynamic>.from(packet['profile'] as Map),
    );
    profiles[profile.nodeId] = profile;
    _ensureThread(profile);
    unawaited(_saveCache());
    _socket.send({
      'type': 'chat_request',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': profile.nodeId,
      'ttl': 5,
      'from_name': session!.login,
      'from_node_id': myNodeId,
      'sender_ip': 'SERVER',
      'sender_port': 0,
      'sender_transport': 'server',
    });
    completer.complete(profile);
  }

  void _handleActiveDevices(Map<String, dynamic> packet) {
    final completer = _activeDevicesCompleter;
    _activeDevicesCompleter = null;
    final rawDevices = packet['devices'];
    final devices = rawDevices is List
        ? rawDevices
              .whereType<Map>()
              .map(
                (raw) => ActiveDevice.fromJson(Map<String, dynamic>.from(raw)),
              )
              .toList()
        : <ActiveDevice>[];
    completer?.complete(devices);
  }

  void _handleProfileUpdateResult(Map<String, dynamic> packet) {
    final completer = _profileUpdateCompleter;
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      completer.complete(null);
    } else {
      completer.complete(
        packet['reason']?.toString().isNotEmpty == true
            ? packet['reason'].toString()
            : 'Не удалось обновить профиль',
      );
    }
  }

  void _applyReactions(dynamic rawReactions) {
    for (final thread in [...threads.values, ...groups.values]) {
      for (var i = 0; i < thread.messages.length; i++) {
        if (thread.messages[i].reactions.isNotEmpty) {
          thread.messages[i] = thread.messages[i].copyWith(reactions: const {});
        }
      }
    }
    for (final raw in rawReactions is List ? rawReactions : const []) {
      if (raw is! Map) continue;
      _applyReactionPacket(Map<String, dynamic>.from(raw));
    }
  }

  void _applyReactionPacket(Map<String, dynamic> packet) {
    final messageId =
        packet['message_id']?.toString() ??
        packet['group_message_id']?.toString() ??
        '';
    final reaction = packet['reaction']?.toString() ?? '';
    if (messageId.isEmpty || reaction.isEmpty) return;
    for (final thread in [...threads.values, ...groups.values]) {
      final index = thread.messages.indexWhere(
        (message) => message.id == messageId,
      );
      if (index < 0) continue;
      final current = Map<String, int>.from(thread.messages[index].reactions);
      current[reaction] = (current[reaction] ?? 0) + 1;
      thread.messages[index] = thread.messages[index].copyWith(
        reactions: current,
      );
      unawaited(_saveCache());
      notifyListeners();
      return;
    }
  }

  Future<void> sendReaction(
    ChatThread thread,
    ChatMessage message,
    String reaction,
  ) async {
    if (session == null || reaction.trim().isEmpty) return;
    _applyReactionPacket({'message_id': message.id, 'reaction': reaction});
    final basePacket = {
      'type': thread.isGroup ? 'group_reaction' : 'message_reaction',
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'message_id': message.id,
      'group_message_id': message.id,
      'group_id': thread.groupId,
      'reaction': reaction,
    };
    if (thread.isGroup) {
      final recipients = thread.members
          .where((member) => member.isNotEmpty && member != myNodeId)
          .toSet();
      if (recipients.isEmpty) {
        recipients.add('SERVER');
      }
      for (final recipient in recipients) {
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': recipient,
        });
      }
    } else {
      _socket.send({
        ...basePacket,
        'packet_id': const Uuid().v4(),
        'destination_node': thread.profile.nodeId,
      });
    }
  }

  Future<void> editMessage(
    ChatThread thread,
    ChatMessage message,
    String text,
  ) async {
    final trimmed = text.trim();
    if (session == null || trimmed.isEmpty || message.senderNode != myNodeId) {
      return;
    }
    _replaceMessage(
      message.id,
      (current) => current.copyWith(text: trimmed, edited: true),
    );
    if (thread.isGroup) {
      final groupKey = _getOrCreateGroupKey(thread.groupId);
      final encryptedText = await _crypto.encryptGroupText(
        groupKey.key,
        trimmed,
      );
      final senderEnvelope = await _crypto.wrapGroupKey(
        _crypto.publicKey,
        groupKey.key,
      );
      final basePacket = {
        'type': 'group_message_edit',
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'ttl': 5,
        'sender': session!.login,
        'group_id': thread.groupId,
        'group_message_id': message.id,
        'message': encryptedText,
        'group_key_id': groupKey.id,
        'group_key_sender_envelope': senderEnvelope,
      };
      var sent = false;
      for (final member in thread.members.where(
        (member) => member != myNodeId,
      )) {
        final publicKey = profiles[member]?.publicKey ?? '';
        if (publicKey.isEmpty) continue;
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': member,
          'group_key_envelope': await _crypto.wrapGroupKey(
            publicKey,
            groupKey.key,
          ),
        });
        sent = true;
      }
      if (!sent) {
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': 'SERVER',
          'group_key_envelope': senderEnvelope,
        });
      }
      return;
    }

    final encryptedText = await _crypto.encryptText(
      thread.profile.publicKey,
      trimmed,
    );
    _socket.send({
      'type': 'message_edit',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': thread.profile.nodeId,
      'ttl': 5,
      'sender': session!.login,
      'message_id': message.id,
      'message': encryptedText,
    });
  }

  Future<void> deleteMessage(ChatThread thread, ChatMessage message) async {
    if (session == null || message.senderNode != myNodeId) return;
    _deleteLocalMessage(thread, message.id);
    final basePacket = {
      'type': thread.isGroup ? 'group_message_delete' : 'message_delete',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'message_id': message.id,
      'group_message_id': message.id,
      'group_id': thread.groupId,
    };
    if (thread.isGroup) {
      final recipients = thread.members
          .where((member) => member.isNotEmpty && member != myNodeId)
          .toSet();
      if (recipients.isEmpty) recipients.add('SERVER');
      for (final recipient in recipients) {
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': recipient,
        });
      }
    } else {
      _socket.send({...basePacket, 'destination_node': thread.profile.nodeId});
    }
  }

  void togglePin(ChatThread thread, ChatMessage message) {
    if (session == null) return;
    final pinned = thread.pinnedMessageIds.contains(message.id);
    if (pinned) {
      thread.pinnedMessageIds.remove(message.id);
    } else {
      thread.pinnedMessageIds.remove(message.id);
      thread.pinnedMessageIds.insert(0, message.id);
    }
    unawaited(_saveCache());
    notifyListeners();
    final basePacket = {
      'type': thread.isGroup ? 'group_pin' : 'message_pin',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'message_id': message.id,
      'group_id': thread.groupId,
      'action': pinned ? 'unpin' : 'pin',
      'text': _replyPreview(message),
    };
    if (thread.isGroup) {
      final recipients = thread.members
          .where((member) => member.isNotEmpty && member != myNodeId)
          .toSet();
      if (recipients.isEmpty) recipients.add('SERVER');
      for (final recipient in recipients) {
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': recipient,
        });
      }
    } else {
      _socket.send({...basePacket, 'destination_node': thread.profile.nodeId});
    }
  }

  void updateDraft(ChatThread thread, String value) {
    if (thread.draft == value) return;
    thread.draft = value;
    unawaited(_saveCache());
    notifyListeners();
  }

  void toggleThreadArchive(ChatThread thread) {
    thread.archived = !thread.archived;
    unawaited(_saveCache());
    notifyListeners();
  }

  void toggleThreadPin(ChatThread thread) {
    thread.pinned = !thread.pinned;
    unawaited(_saveCache());
    notifyListeners();
  }

  void toggleThreadMute(ChatThread thread) {
    thread.muted = !thread.muted;
    unawaited(_saveCache());
    notifyListeners();
  }

  List<ChatMessage> searchMessages(ChatThread thread, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return thread.messages.where((message) {
      final haystack = [
        message.text,
        message.fileName,
        message.replyToText,
      ].join(' ').toLowerCase();
      return haystack.contains(needle);
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void sendTyping(ChatThread thread) {
    if (session == null) return;
    final basePacket = {
      'type': 'typing',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 2,
      'sender': session!.login,
      'group_id': thread.groupId,
    };
    if (thread.isGroup) {
      for (final member in thread.members.where(
        (member) => member != myNodeId,
      )) {
        _socket.send({...basePacket, 'destination_node': member});
      }
    } else {
      _socket.send({...basePacket, 'destination_node': thread.profile.nodeId});
    }
  }

  void _applyTypingPacket(Map<String, dynamic> packet) {
    final source = packet['source_node']?.toString() ?? '';
    if (source.isEmpty || source == myNodeId) return;
    final groupId = packet['group_id']?.toString() ?? '';
    final key = groupId.isNotEmpty ? groupId : source;
    typingUntil[key] = DateTime.now().add(const Duration(seconds: 4));
    Timer(const Duration(seconds: 4), () {
      final until = typingUntil[key];
      if (until != null && until.isBefore(DateTime.now())) {
        typingUntil.remove(key);
        notifyListeners();
      }
    });
  }

  void _applyPins(dynamic rawPins) {
    for (final thread in [...threads.values, ...groups.values]) {
      thread.pinnedMessageIds.clear();
    }
    for (final raw in rawPins is List ? rawPins : const []) {
      if (raw is! Map) continue;
      _applyPinPacket(Map<String, dynamic>.from(raw), fromSync: true);
    }
    unawaited(_saveCache());
    notifyListeners();
  }

  Future<void> _applyEditPacket(Map<String, dynamic> packet) async {
    final messageId =
        packet['message_id']?.toString() ??
        packet['group_message_id']?.toString() ??
        '';
    if (messageId.isEmpty) return;
    var text = packet['message']?.toString() ?? '';
    if (packet['type'] == 'group_message_edit') {
      final groupId = packet['group_id']?.toString() ?? '';
      await _acceptGroupKeyEnvelope(
        groupId,
        packet['group_key_id']?.toString() ?? '',
        packet['group_key_envelope']?.toString() ??
            packet['group_key_sender_envelope']?.toString() ??
            '',
      );
      text = await _crypto.decryptGroupText(_groupKeys[groupId]?.key, text);
    } else {
      text = await _crypto.decryptText(text);
    }
    _replaceMessage(
      messageId,
      (message) => message.copyWith(text: text, edited: true),
    );
  }

  void _applyDeletePacket(Map<String, dynamic> packet) {
    final messageId =
        packet['message_id']?.toString() ??
        packet['group_message_id']?.toString() ??
        '';
    if (messageId.isEmpty) return;
    for (final thread in [...threads.values, ...groups.values]) {
      if (_deleteLocalMessage(thread, messageId)) return;
    }
  }

  void _applyPinPacket(Map<String, dynamic> packet, {bool fromSync = false}) {
    final messageId = packet['message_id']?.toString() ?? '';
    if (messageId.isEmpty) return;
    final action = packet['action']?.toString() ?? 'pin';
    for (final thread in [...threads.values, ...groups.values]) {
      if (!thread.messages.any((message) => message.id == messageId)) continue;
      thread.pinnedMessageIds.remove(messageId);
      if (action != 'unpin') {
        thread.pinnedMessageIds.insert(0, messageId);
      }
      if (!fromSync) {
        unawaited(_saveCache());
        notifyListeners();
      }
      return;
    }
  }

  ChatThread _ensureThread(Profile profile) {
    final existing = threads[profile.nodeId];
    if (existing != null) {
      existing.profile = profile;
      return existing;
    }
    final thread = ChatThread(profile: profile);
    threads[profile.nodeId] = thread;
    return thread;
  }

  String _replyPreview(ChatMessage message) {
    if (message.kind == ChatMessageKind.file) {
      return message.fileName.isEmpty ? 'Файл' : message.fileName;
    }
    return message.text.length > 80
        ? '${message.text.substring(0, 80)}...'
        : message.text;
  }

  Future<void> sendMessage(
    Profile recipient,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || session == null) return;
    final id = const Uuid().v4();
    final thread = _ensureThread(recipient);
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: recipient.nodeId,
        text: trimmed,
        createdAt: DateTime.now(),
        replyToMessageId: replyTo?.id ?? '',
        replyToText: replyTo == null ? '' : _replyPreview(replyTo),
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();
    final wireText = await _crypto.encryptText(recipient.publicKey, trimmed);
    _socket.send({
      'type': 'chat_message',
      'packet_id': id,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': recipient.nodeId,
      'ttl': 5,
      'sender': session!.login,
      'message': wireText,
      'reply_to_message_id': replyTo?.id ?? '',
      'reply_to_text': replyTo == null ? '' : _replyPreview(replyTo),
    });
    _replaceMessage(id, (message) => message.copyWith(pending: false));
  }

  Future<String?> sendFile(
    Profile recipient,
    String filename,
    Uint8List bytes,
  ) async {
    if (session == null) return 'Нет активной сессии';
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) {
      return 'Файл больше 32 МБ';
    }

    final id = const Uuid().v4();
    final data = _hexEncode(bytes);
    final thread = _ensureThread(recipient);
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: recipient.nodeId,
        text: filename,
        createdAt: DateTime.now(),
        kind: ChatMessageKind.file,
        fileName: filename,
        fileData: _hexEncode(bytes),
        fileSize: bytes.length,
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();

    final totalChunks = (data.length / _fileChunkHexSize).ceil();
    for (var index = 0; index < totalChunks; index++) {
      final start = index * _fileChunkHexSize;
      final end = start + _fileChunkHexSize > data.length
          ? data.length
          : start + _fileChunkHexSize;
      _socket.send({
        'type': 'file_chunk',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': recipient.nodeId,
        'ttl': 5,
        'sender': session!.login,
        'file_id': id,
        'filename': filename,
        'chunk_index': index,
        'total_chunks': totalChunks,
        'data': data.substring(start, end),
      });
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    _replaceMessage(id, (message) => message.copyWith(pending: false));
    return null;
  }

  Future<ChatThread?> createGroup({
    required String name,
    required List<Profile> members,
  }) async {
    final current = session;
    final groupName = name.trim();
    if (current == null || groupName.isEmpty) return null;
    final uniqueMembers = <String>{
      myNodeId,
      ...members.map((profile) => profile.nodeId).where((id) => id.isNotEmpty),
    }.toList();
    final groupId = const Uuid().v4();
    final keyId = _newGroupKeyId();
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: groupName,
      members: uniqueMembers,
      ownerNode: myNodeId,
      admins: [myNodeId],
    );
    _rememberGroupKey(groupId, _GroupKey(keyId, _crypto.generateGroupKey()));
    await _publishGroupUpdate(group, rotateKey: false);
    await _saveCache();
    notifyListeners();
    return group;
  }

  Future<String?> updateGroupMembers(
    ChatThread group,
    List<String> members, {
    bool rotateKey = true,
  }) async {
    if (session == null) return 'Нет активной сессии';
    if (!group.isGroup) return 'Это не группа';
    if (group.ownerNode.isNotEmpty && group.ownerNode != myNodeId) {
      return 'Менять участников может только владелец группы';
    }
    final uniqueMembers = <String>{
      myNodeId,
      ...members.where((id) => id.isNotEmpty),
    }.toList();
    group.members
      ..clear()
      ..addAll(uniqueMembers);
    group.admins.removeWhere((admin) => !uniqueMembers.contains(admin));
    await _publishGroupUpdate(group, rotateKey: rotateKey);
    await _saveCache();
    notifyListeners();
    return null;
  }

  Future<String?> toggleGroupAdmin(ChatThread group, String nodeId) async {
    if (session == null) return 'Нет активной сессии';
    if (!group.isGroup) return 'Это не группа';
    if (group.ownerNode.isNotEmpty && group.ownerNode != myNodeId) {
      return 'Only owner can change admins';
    }
    if (nodeId == group.ownerNode ||
        nodeId == myNodeId && group.ownerNode.isEmpty) {
      return 'Owner role cannot be changed';
    }
    if (group.admins.contains(nodeId)) {
      group.admins.remove(nodeId);
    } else {
      group.admins.add(nodeId);
    }
    await _publishGroupUpdate(group, rotateKey: false);
    await _saveCache();
    notifyListeners();
    return null;
  }

  Future<void> _publishGroupUpdate(
    ChatThread group, {
    required bool rotateKey,
  }) async {
    if (session == null || !group.isGroup) return;
    final key = rotateKey
        ? _rotateGroupKey(group.groupId)
        : _getOrCreateGroupKey(group.groupId);
    final senderEnvelope = await _crypto.wrapGroupKey(
      _crypto.publicKey,
      key.key,
    );
    final groupName = group.groupName.isEmpty
        ? group.profile.displayName
        : group.groupName;
    final basePacket = {
      'type': 'group_update',
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': group.groupId,
      'group_name': groupName,
      'members': group.members,
      'owner_node': group.ownerNode.isEmpty ? myNodeId : group.ownerNode,
      'admins': group.admins,
      'group_key_id': key.id,
      'group_key_sender_envelope': senderEnvelope,
    };

    var sent = false;
    for (final member in group.members.where((member) => member != myNodeId)) {
      final publicKey = profiles[member]?.publicKey ?? '';
      if (publicKey.isEmpty) continue;
      _socket.send({
        ...basePacket,
        'packet_id': const Uuid().v4(),
        'destination_node': member,
        'group_key_envelope': await _crypto.wrapGroupKey(publicKey, key.key),
      });
      sent = true;
    }

    _socket.send({
      ...basePacket,
      'packet_id': const Uuid().v4(),
      'destination_node': sent ? myNodeId : 'SERVER',
      'group_key_envelope': senderEnvelope,
    });
  }

  Future<String?> sendGroupFile(
    ChatThread group,
    String filename,
    Uint8List bytes,
  ) async {
    if (session == null) return 'Нет активной сессии';
    if (!group.isGroup) return 'Это не группа';
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) return 'Файл больше 32 МБ';

    final id = const Uuid().v4();
    final groupKey = _getOrCreateGroupKey(group.groupId);
    final wireFilename = await _crypto.encryptGroupText(groupKey.key, filename);
    final wireBytes = await _crypto.encryptGroupBytes(groupKey.key, bytes);
    final data = _hexEncode(Uint8List.fromList(wireBytes));
    final senderEnvelope = await _crypto.wrapGroupKey(
      _crypto.publicKey,
      groupKey.key,
    );
    group.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: group.groupId,
        text: filename,
        createdAt: DateTime.now(),
        kind: ChatMessageKind.file,
        fileName: filename,
        fileData: _hexEncode(bytes),
        fileSize: bytes.length,
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();

    final totalChunks = (data.length / _fileChunkHexSize).ceil();
    final recipients = group.members.where((member) => member != myNodeId);
    var sent = false;
    for (final member in recipients) {
      final publicKey = profiles[member]?.publicKey ?? '';
      if (publicKey.isEmpty) continue;
      final envelope = await _crypto.wrapGroupKey(publicKey, groupKey.key);
      for (var index = 0; index < totalChunks; index++) {
        final start = index * _fileChunkHexSize;
        final end = start + _fileChunkHexSize > data.length
            ? data.length
            : start + _fileChunkHexSize;
        _socket.send({
          'type': 'file_chunk',
          'packet_id': const Uuid().v4(),
          'protocol_version': MeshSocket.protocolVersion,
          'source_node': myNodeId,
          'destination_node': member,
          'ttl': 5,
          'sender': session!.login,
          'file_id': id,
          'filename': wireFilename,
          'group_id': group.groupId,
          'group_name': group.groupName.isEmpty
              ? group.profile.displayName
              : group.groupName,
          'group_key_id': groupKey.id,
          'group_key_envelope': envelope,
          'group_key_sender_envelope': senderEnvelope,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
        });
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      sent = true;
    }
    if (!sent) {
      for (var index = 0; index < totalChunks; index++) {
        final start = index * _fileChunkHexSize;
        final end = start + _fileChunkHexSize > data.length
            ? data.length
            : start + _fileChunkHexSize;
        _socket.send({
          'type': 'file_chunk',
          'packet_id': const Uuid().v4(),
          'protocol_version': MeshSocket.protocolVersion,
          'source_node': myNodeId,
          'destination_node': 'SERVER',
          'ttl': 5,
          'sender': session!.login,
          'file_id': id,
          'filename': wireFilename,
          'group_id': group.groupId,
          'group_name': group.groupName.isEmpty
              ? group.profile.displayName
              : group.groupName,
          'group_key_id': groupKey.id,
          'group_key_envelope': senderEnvelope,
          'group_key_sender_envelope': senderEnvelope,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
        });
      }
    }
    _replaceMessage(id, (message) => message.copyWith(pending: false));
    return null;
  }

  Future<void> _receiveMessage(Map<String, dynamic> packet) async {
    final sender = packet['source_node']?.toString() ?? '';
    if (sender.isEmpty) return;
    final profile =
        profiles[sender] ??
        Profile(
          nodeId: sender,
          displayName: packet['sender']?.toString() ?? sender.substring(0, 8),
        );
    profiles[sender] = profile;
    final thread = _ensureThread(profile);
    final id = packet['packet_id']?.toString() ?? const Uuid().v4();
    if (!thread.messages.any((message) => message.id == id)) {
      final text = await _crypto.decryptText(
        packet['message']?.toString() ?? '',
      );
      thread.messages.add(
        ChatMessage(
          id: id,
          senderNode: sender,
          receiverNode: myNodeId,
          text: text,
          createdAt: DateTime.now(),
          replyToMessageId: packet['reply_to_message_id']?.toString() ?? '',
          replyToText: packet['reply_to_text']?.toString() ?? '',
          delivered: true,
        ),
      );
      thread.unread++;
      if (!thread.muted) {
        unawaited(_showNotification(title: profile.displayName, body: text));
      }
      unawaited(_saveCache());
    }
    _socket.send({
      'type': 'message_received',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': sender,
      'message_id': id,
      'ttl': 5,
    });
  }

  Future<void> _receiveFileChunk(
    Map<String, dynamic> packet, {
    required bool fromSync,
  }) async {
    final fileId = packet['file_id']?.toString() ?? '';
    final filename = packet['filename']?.toString() ?? 'file';
    final chunkIndex = int.tryParse(packet['chunk_index']?.toString() ?? '');
    final totalChunks = int.tryParse(packet['total_chunks']?.toString() ?? '');
    final data = packet['data']?.toString() ?? '';
    if (fileId.isEmpty ||
        chunkIndex == null ||
        totalChunks == null ||
        totalChunks <= 0 ||
        data.isEmpty) {
      return;
    }

    final incoming = _incomingFiles.putIfAbsent(
      fileId,
      () => _IncomingFile(packet, totalChunks),
    );
    incoming.chunks[chunkIndex] = data;
    if (incoming.chunks.length < incoming.totalChunks) return;

    final first = incoming.firstPacket;
    final groupId = first['group_id']?.toString() ?? '';
    if (groupId.isNotEmpty) {
      final group = _ensureGroupThread(
        groupId: groupId,
        groupName: first['group_name']?.toString() ?? 'Группа',
      );
      if (!group.messages.any((message) => message.id == fileId)) {
        await _acceptGroupKeyEnvelope(
          groupId,
          first['group_key_id']?.toString() ?? '',
          first['group_key_envelope']?.toString() ??
              first['group_key_sender_envelope']?.toString() ??
              '',
        );
        final sender = first['sender_node']?.toString().isNotEmpty == true
            ? first['sender_node'].toString()
            : first['source_node']?.toString() ?? '';
        final fullData = List<String>.generate(
          incoming.totalChunks,
          (index) => incoming.chunks[index] ?? '',
        ).join();
        final decryptedName = await _crypto.decryptGroupText(
          _groupKeys[groupId]?.key,
          filename,
        );
        var decryptedData = fullData;
        try {
          decryptedData = _hexEncode(
            Uint8List.fromList(
              await _crypto.decryptGroupBytes(
                _groupKeys[groupId]?.key,
                _hexDecode(fullData),
              ),
            ),
          );
        } catch (_) {
          decryptedData = fullData;
        }
        group.messages.add(
          ChatMessage(
            id: fileId,
            senderNode: sender,
            receiverNode: groupId,
            text: decryptedName,
            createdAt: _parsePacketDate(first),
            kind: ChatMessageKind.file,
            fileName: decryptedName,
            fileData: decryptedData,
            fileSize: decryptedData.length ~/ 2,
            delivered: true,
          ),
        );
        group.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (!fromSync && sender != myNodeId) {
          group.unread++;
          if (!group.muted) {
            unawaited(
              _showNotification(
                title: group.profile.displayName,
                body: _fileNotificationBody(decryptedName),
              ),
            );
          }
        }
        await _saveCache();
        notifyListeners();
      }
      _incomingFiles.remove(fileId);
      return;
    }

    final sender = first['sender_node']?.toString().isNotEmpty == true
        ? first['sender_node'].toString()
        : first['source_node']?.toString() ?? '';
    final receiver = first['receiver_node']?.toString().isNotEmpty == true
        ? first['receiver_node'].toString()
        : first['destination_node']?.toString() ?? '';
    final senderLogin = first['sender_login']?.toString().toLowerCase() ?? '';
    final receiverLogin =
        first['receiver_login']?.toString().toLowerCase() ?? '';
    final myLogin = session?.login.toLowerCase() ?? '';
    final sentByMe =
        sender == myNodeId ||
        (senderLogin.isNotEmpty && senderLogin == myLogin);
    final receivedByMe =
        receiver == myNodeId ||
        (receiverLogin.isNotEmpty && receiverLogin == myLogin);
    final peerId = sentByMe ? receiver : sender;
    if (!sentByMe && !receivedByMe) {
      _incomingFiles.remove(fileId);
      return;
    }
    if (peerId.isEmpty || peerId == myNodeId) {
      _incomingFiles.remove(fileId);
      return;
    }

    final profile =
        profiles[peerId] ??
        Profile(
          nodeId: peerId,
          displayName:
              first['sender_name']?.toString() ??
              first['sender']?.toString() ??
              peerId.substring(0, 8),
        );
    profiles[peerId] = profile;
    final thread = _ensureThread(profile);
    if (!thread.messages.any((message) => message.id == fileId)) {
      final fullData = List<String>.generate(
        incoming.totalChunks,
        (index) => incoming.chunks[index] ?? '',
      ).join();
      thread.messages.add(
        ChatMessage(
          id: fileId,
          senderNode: sentByMe ? myNodeId : sender,
          receiverNode: receiver,
          text: filename,
          createdAt: _parsePacketDate(first),
          kind: ChatMessageKind.file,
          fileName: filename,
          fileData: fullData,
          fileSize: fullData.length ~/ 2,
          delivered: true,
        ),
      );
      thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (!fromSync && sender != myNodeId) {
        thread.unread++;
        if (!thread.muted) {
          unawaited(
            _showNotification(
              title: profile.displayName,
              body: _fileNotificationBody(filename),
            ),
          );
        }
      }
      await _saveCache();
      notifyListeners();
    }
    _incomingFiles.remove(fileId);
  }

  Future<String> _decryptHistoryText(String rawText) async {
    try {
      return await _crypto.decryptText(rawText);
    } catch (_) {
      return '[Не удалось расшифровать сообщение]';
    }
  }

  String _firstString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value == null) continue;
      final text = value.toString();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _fileNotificationBody(String filename) {
    if (_isImageName(filename)) return 'Photo';
    return filename.trim().isEmpty ? 'File' : 'File: $filename';
  }

  Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    if (!appSettings.notificationsEnabled) return;
    await _notifications.showMessage(
      title: title,
      body: appSettings.notificationPreview ? body : 'New message',
      sound: appSettings.notificationSound,
      vibration: appSettings.notificationVibration,
    );
  }

  bool _isImageName(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) {
      if (item is Map) {
        return item['node_id']?.toString() ??
            item['login']?.toString() ??
            item['name']?.toString() ??
            item.toString();
      }
      return item.toString();
    }).toList();
  }

  DateTime _parsePacketDate(Map<String, dynamic> data) {
    for (final key in const ['created_at', 'timestamp', 'time', 'date']) {
      final value = data[key];
      if (value == null) continue;
      final parsed = DateTime.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  String _hexEncode(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Uint8List _hexDecode(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  _GroupKey _getOrCreateGroupKey(String groupId) {
    final existing = _groupKeys[groupId];
    if (existing != null) return existing;
    final created = _GroupKey(_newGroupKeyId(), _crypto.generateGroupKey());
    _rememberGroupKey(groupId, created);
    return created;
  }

  _GroupKey _rotateGroupKey(String groupId) {
    final created = _GroupKey(_newGroupKeyId(), _crypto.generateGroupKey());
    _rememberGroupKey(groupId, created);
    return created;
  }

  Future<bool> _acceptGroupKeyEnvelope(
    String groupId,
    String keyId,
    String envelope,
  ) async {
    if (groupId.isEmpty || keyId.isEmpty || envelope.isEmpty) return false;
    final groupKey = await _crypto.unwrapGroupKey(envelope);
    if (groupKey == null) return false;
    final current = _groupKeys[groupId];
    if (current == null || keyId.compareTo(current.id) >= 0) {
      _rememberGroupKey(groupId, _GroupKey(keyId, groupKey));
    }
    return true;
  }

  void _rememberGroupKey(String groupId, _GroupKey key) {
    if (groupId.isEmpty) return;
    _groupKeys[groupId] = key;
    final group = groups[groupId];
    if (group == null) return;
    group.groupKeyId = key.id;
    group.groupKeyData = base64Url.encode(key.key);
  }

  void _restoreGroupKeysFromThreads() {
    for (final group in groups.values) {
      if (group.groupId.isEmpty ||
          group.groupKeyId.isEmpty ||
          group.groupKeyData.isEmpty) {
        continue;
      }
      try {
        final padding = (4 - group.groupKeyData.length % 4) % 4;
        final key = base64Url.decode(group.groupKeyData + ('=' * padding));
        if (key.isNotEmpty) {
          _groupKeys[group.groupId] = _GroupKey(group.groupKeyId, key);
        }
      } catch (_) {
        group.groupKeyId = '';
        group.groupKeyData = '';
      }
    }
  }

  Future<void> _repairCachedGroupMessages() async {
    var changed = false;
    for (final group in groups.values) {
      final key = _groupKeys[group.groupId]?.key;
      if (key == null) continue;
      for (var i = 0; i < group.messages.length; i++) {
        final message = group.messages[i];
        if (!message.text.startsWith(MeshCrypto.groupPrefix)) continue;
        final text = await _crypto.decryptGroupText(key, message.text);
        if (text.isEmpty || text.startsWith(MeshCrypto.groupPrefix)) continue;
        group.messages[i] = message.copyWith(text: text);
        changed = true;
      }
    }
    if (changed) {
      await _saveCache();
      notifyListeners();
    }
  }

  String _newGroupKeyId() {
    return '${DateTime.now().millisecondsSinceEpoch}-'
        '${const Uuid().v4()}';
  }

  void _acceptChatRequest(Map<String, dynamic> packet) {
    final nodeId =
        packet['from_node_id']?.toString() ??
        packet['source_node']?.toString() ??
        '';
    if (nodeId.isEmpty) return;
    final profile =
        profiles[nodeId] ??
        Profile(
          nodeId: nodeId,
          displayName:
              packet['from_name']?.toString() ?? nodeId.substring(0, 8),
        );
    profiles[nodeId] = profile;
    _ensureThread(profile);
    unawaited(_saveCache());
    _socket.send({
      'type': 'chat_response',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': nodeId,
      'ttl': 5,
      'accepted': true,
      'from_name': session!.login,
      'from_node_id': myNodeId,
      'sender_ip': 'SERVER',
      'sender_port': 0,
      'sender_transport': 'server',
    });
  }

  void _markDelivered(String id) {
    if (id.isEmpty) return;
    _replaceMessage(id, (message) => message.copyWith(delivered: true));
  }

  void _replaceMessage(
    String id,
    ChatMessage Function(ChatMessage message) transform,
  ) {
    for (final thread in [...threads.values, ...groups.values]) {
      final index = thread.messages.indexWhere((message) => message.id == id);
      if (index >= 0) {
        thread.messages[index] = transform(thread.messages[index]);
        unawaited(_saveCache());
        notifyListeners();
        return;
      }
    }
  }

  bool _deleteLocalMessage(ChatThread thread, String messageId) {
    final before = thread.messages.length;
    thread.messages.removeWhere((message) => message.id == messageId);
    thread.pinnedMessageIds.remove(messageId);
    if (thread.messages.length == before) return false;
    unawaited(_saveCache());
    notifyListeners();
    return true;
  }

  void markRead(ChatThread thread) {
    thread.unread = 0;
    unawaited(_saveCache());
    notifyListeners();
  }

  Future<CacheStats> cacheStats() async {
    return _cache.stats(session);
  }

  bool get websocketLive => _socket.isConnected;

  Future<void> updateAppSettings(AppSettings settings) async {
    appSettings = settings;
    await _settingsStore.save(settings);
    notifyListeners();
  }

  List<GlobalSearchResult> searchAllChats(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final results = <GlobalSearchResult>[];
    for (final thread in [...threads.values, ...groups.values]) {
      final title = thread.profile.displayName.toLowerCase();
      final username = thread.profile.publicUsername.toLowerCase();
      if (title.contains(needle) || username.contains(needle)) {
        results.add(GlobalSearchResult(thread: thread));
      }
      for (final message in thread.messages.reversed) {
        final haystack = [
          message.text,
          message.fileName,
          message.replyToText,
        ].join(' ').toLowerCase();
        if (haystack.contains(needle)) {
          results.add(GlobalSearchResult(thread: thread, message: message));
          if (results.length >= 100) return results;
        }
      }
    }
    return results;
  }

  Future<ConnectionDiagnostics> diagnoseConnection() async {
    final current = session;
    if (current == null) {
      return const ConnectionDiagnostics(
        ok: false,
        message: 'No active session',
        latency: Duration.zero,
      );
    }
    await _crypto.initialize(current.login, current.password);
    return _socket.diagnose(current, _crypto.publicKey);
  }

  Future<List<ActiveDevice>> loadActiveDevices() async {
    if (_activeDevicesCompleter != null) return _activeDevicesCompleter!.future;
    _activeDevicesCompleter = Completer<List<ActiveDevice>>();
    _socket.send({
      'type': 'active_devices_request',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
    });
    return _activeDevicesCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _activeDevicesCompleter = null;
        return const [];
      },
    );
  }

  Future<void> clearLocalCache() async {
    await _cache.clear(session);
    await _socket.close();
    _clearLocalState();
    await _connect();
    notifyListeners();
  }

  Future<void> logout() async {
    await _socket.close();
    await _store.clear();
    session = null;
    _clearLocalState();
    status = 'Offline';
    notifyListeners();
  }

  void _clearLocalState() {
    profiles.clear();
    threads.clear();
    groups.clear();
    typingUntil.clear();
    _incomingFiles.clear();
    _groupKeys.clear();
  }

  Future<void> _saveCache() async {
    try {
      await _cache.save(session, [...threads.values, ...groups.values]);
    } catch (_) {
      // Web storage can reject writes when Safari quota is exhausted.
      // The app should keep working; sync can restore data later.
    }
  }

  String _normalizeServerUrl(String value) {
    var result = value.trim();
    if (result.startsWith('https://')) {
      result = 'wss://${result.substring(8)}';
    } else if (result.startsWith('http://')) {
      result = 'ws://${result.substring(7)}';
    } else if (!result.startsWith('ws://') && !result.startsWith('wss://')) {
      result = 'ws://$result';
    }
    return result.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  void dispose() {
    _socket.close();
    super.dispose();
  }
}

class _IncomingFile {
  _IncomingFile(this.firstPacket, this.totalChunks);

  final Map<String, dynamic> firstPacket;
  final int totalChunks;
  final Map<int, String> chunks = {};
}

class _GroupKey {
  const _GroupKey(this.id, this.key);

  final String id;
  final List<int> key;
}

class GlobalSearchResult {
  const GlobalSearchResult({required this.thread, this.message});

  final ChatThread thread;
  final ChatMessage? message;
}

class ActiveDevice {
  const ActiveDevice({
    required this.nodeId,
    this.displayName = '',
    this.appVersion = '',
    this.online = false,
    this.lastSeen = '',
  });

  final String nodeId;
  final String displayName;
  final String appVersion;
  final bool online;
  final String lastSeen;

  factory ActiveDevice.fromJson(Map<String, dynamic> json) {
    return ActiveDevice(
      nodeId: json['node_id']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? '',
      online: json['online'] == true,
      lastSeen: json['last_seen']?.toString() ?? '',
    );
  }
}
