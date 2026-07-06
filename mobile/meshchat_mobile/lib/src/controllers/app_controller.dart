import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/app_settings.dart';
import '../models/profile.dart';
import '../models/session.dart';
import '../models/story_item.dart';
import '../services/app_settings_store.dart';
import '../services/ble_chat_service.dart';
import '../services/call_service.dart';
import '../services/chat_cache_store.dart';
import '../services/mesh_crypto.dart';
import '../services/mesh_socket.dart';
import '../services/notification_service.dart';
import '../services/proximity_screen_service.dart';
import '../services/session_store.dart';
import '../services/story_store.dart';

enum CallStatus { ringing, outgoing, active, ended }

class DiagnosticEvent {
  const DiagnosticEvent({
    required this.time,
    required this.area,
    required this.message,
  });

  final DateTime time;
  final String area;
  final String message;
}

class ActiveCall {
  const ActiveCall({
    required this.callId,
    required this.peer,
    required this.status,
    required this.incoming,
    required this.startedAt,
    this.remoteOfferSdp = '',
    this.endReason = '',
    this.localMuted = false,
    this.isGroup = false,
    this.groupId = '',
    this.groupMembers = const [],
    this.connectedNodes = const {},
    this.speakerOn = true,
    this.collapsed = false,
    this.quality = 0,
  });

  final String callId;
  final Profile peer;
  final CallStatus status;
  final bool incoming;
  final DateTime startedAt;
  final String remoteOfferSdp;
  final String endReason;
  final bool localMuted;
  final bool isGroup;
  final String groupId;
  final List<String> groupMembers;
  final Set<String> connectedNodes;
  final bool speakerOn;
  final bool collapsed;
  final int quality;

  ActiveCall copyWith({
    CallStatus? status,
    String? endReason,
    bool? localMuted,
    Set<String>? connectedNodes,
    bool? speakerOn,
    bool? collapsed,
    int? quality,
  }) {
    return ActiveCall(
      callId: callId,
      peer: peer,
      status: status ?? this.status,
      incoming: incoming,
      startedAt: startedAt,
      remoteOfferSdp: remoteOfferSdp,
      endReason: endReason ?? this.endReason,
      localMuted: localMuted ?? this.localMuted,
      isGroup: isGroup,
      groupId: groupId,
      groupMembers: groupMembers,
      connectedNodes: connectedNodes ?? this.connectedNodes,
      speakerOn: speakerOn ?? this.speakerOn,
      collapsed: collapsed ?? this.collapsed,
      quality: quality ?? this.quality,
    );
  }
}

class AppController extends ChangeNotifier {
  static const _fileChunkHexSize = 128 * 1024;
  static const maxMobileFileBytes = 64 * 1024 * 1024;
  static const maxBluetoothFileBytes = 512 * 1024;
  static const _bluetoothFileChunkHexSize = 8 * 1024;
  static const _maxProfilePacketBytes = 900 * 1024;

  final SessionStore _store = SessionStore();
  final AppSettingsStore _settingsStore = AppSettingsStore();
  final ChatCacheStore _cache = ChatCacheStore();
  final StoryStore _storyStore = StoryStore();
  final MeshSocket _socket = MeshSocket();
  final MeshCrypto _crypto = MeshCrypto();
  final BleChatService ble = BleChatService();
  final CallService _calls = CallService();
  final Map<String, CallService> _groupCalls = {};
  final NotificationService _notifications = NotificationService();
  final ProximityScreenService _proximityScreen = ProximityScreenService();
  final Map<String, Profile> profiles = {};
  final Map<String, ChatThread> threads = {};
  final Map<String, ChatThread> groups = {};
  final Map<String, StoryItem> stories = {};
  final Map<String, DateTime> typingUntil = {};
  final Map<String, String> activityKinds = {};

  Session? session;
  List<Session> recentSessions = [];
  AppSettings appSettings = const AppSettings();
  ActiveCall? activeCall;
  bool initialized = false;
  bool busy = false;
  String status = 'Offline';
  DateTime? lastSyncAt;
  String? error;
  Completer<Profile?>? _lookupCompleter;
  Completer<String?>? _profileUpdateCompleter;
  Completer<List<ActiveDevice>>? _activeDevicesCompleter;
  String _webPushVapidPublicKey = '';
  String _activeThreadKey = '';
  Timer? _callTicker;
  bool _webPushSubscribeInFlight = false;
  bool _retryingQueuedMessages = false;
  Timer? _incomingPreviewTimer;
  final List<DiagnosticEvent> diagnostics = [];
  final List<GroupJoinRequest> groupJoinRequests = [];
  final Map<String, _IncomingFile> _incomingFiles = {};
  final Map<String, _GroupKey> _groupKeys = {};
  ChatThread? incomingPreviewThread;
  ChatMessage? incomingPreviewMessage;
  int incomingPreviewVersion = 0;

  AppController() {
    ble.onPacket = _handleBluetoothPacket;
    ble.addListener(_handleBluetoothStateChanged);
  }

  void addDiagnostic(String area, String message) {
    diagnostics.insert(
      0,
      DiagnosticEvent(time: DateTime.now(), area: area, message: message),
    );
    if (diagnostics.length > 80) {
      diagnostics.removeRange(80, diagnostics.length);
    }
  }

  bool get hasSession => session != null;
  String get myNodeId => session?.nodeId ?? '';
  Duration get callElapsed {
    final call = activeCall;
    if (call == null) return Duration.zero;
    return DateTime.now().difference(call.startedAt);
  }

  String get callQualityLabel {
    final call = activeCall;
    if (call == null || call.status == CallStatus.ended) return '';
    if (call.status != CallStatus.active || call.quality <= 0) {
      return 'Подключается';
    }
    if (call.quality == 1) return 'Слабое';
    return 'Хорошее';
  }

  String get callParticipantsLabel {
    final call = activeCall;
    if (call == null || !call.isGroup) return '';
    final total = callParticipants.length;
    final connected = call.status == CallStatus.active
        ? ({
            myNodeId,
            ...call.connectedNodes,
          }..removeWhere((id) => id.isEmpty)).length
        : call.connectedNodes.length;
    if (total <= 0) return '';
    return 'Подключено $connected/$total';
  }

  List<Profile> get callParticipants {
    final call = activeCall;
    if (call == null || !call.isGroup) return const [];
    final nodes = <String>{
      myNodeId,
      if (!call.peer.nodeId.startsWith('group:')) call.peer.nodeId,
      ...call.groupMembers,
      ...call.connectedNodes,
    }..removeWhere((node) => node.isEmpty);
    return nodes.map((nodeId) {
      if (nodeId == myNodeId) return ownProfile;
      return profiles[nodeId] ??
          Profile(nodeId: nodeId, displayName: nodeId.substring(0, 8));
    }).toList();
  }

  Profile get ownProfile {
    final current = session;
    if (current == null) {
      return const Profile(nodeId: '', displayName: 'Пользователь');
    }
    final profile =
        profiles[current.nodeId] ??
        Profile(
          nodeId: current.nodeId,
          displayName: current.login,
          publicUsername: current.publicUsername,
          publicKey: _crypto.publicKey,
          online: status == 'Online' || status.startsWith('Online:'),
        );
    return profile.copyWith(
      about: appSettings.showAbout ? profile.about : '',
      avatarData: appSettings.showAvatar ? profile.avatarData : '',
      online: appSettings.showOnline && profile.online,
    );
  }

  String get savedMessagesNodeId =>
      myNodeId.isEmpty ? 'saved:local' : 'saved:$myNodeId';

  bool isSavedMessagesProfile(Profile profile) {
    return profile.nodeId == savedMessagesNodeId ||
        profile.nodeId.startsWith('saved:');
  }

  Profile get savedMessagesProfile => Profile(
    nodeId: savedMessagesNodeId,
    displayName: 'Saved Messages',
    publicUsername: 'saved',
    about: 'Private notes, messages and files',
    online: false,
  );

  ChatThread ensureSavedMessagesThread() {
    final key = savedMessagesNodeId;
    final existing = threads[key];
    if (existing != null) {
      existing.profile = savedMessagesProfile;
      return existing;
    }
    final thread = ChatThread(profile: savedMessagesProfile, pinned: true);
    threads[key] = thread;
    unawaited(_saveCache());
    notifyListeners();
    return thread;
  }

  bool _isOwnProfileAlias(Profile profile) {
    final current = session;
    if (current == null) return false;
    if (profile.nodeId == current.nodeId) return true;
    final username = profile.publicUsername.trim().toLowerCase();
    final myUsername = current.publicUsername.trim().toLowerCase();
    return username.isNotEmpty &&
        myUsername.isNotEmpty &&
        username == myUsername;
  }

  Profile _mergeProfile(Profile incoming, {bool? online}) {
    final existing =
        profiles[incoming.nodeId] ?? threads[incoming.nodeId]?.profile;
    if (existing == null) {
      return incoming.copyWith(online: online ?? incoming.online);
    }
    return incoming.copyWith(
      displayName: incoming.displayName.trim().isEmpty
          ? existing.displayName
          : null,
      publicUsername: incoming.publicUsername.trim().isEmpty
          ? existing.publicUsername
          : null,
      about: incoming.about.trim().isEmpty ? existing.about : null,
      avatarData: incoming.avatarData.isEmpty ? existing.avatarData : null,
      publicKey: incoming.publicKey.isEmpty ? existing.publicKey : null,
      online: online ?? incoming.online || existing.online,
    );
  }

  List<ChatThread> get sortedThreads {
    final result = _dedupeVisibleThreads(
      [
        ...threads.values,
        ...groups.values,
      ].where((thread) => !thread.archived).toList(),
    );
    result.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final aTime = a.lastMessage?.createdAt ?? DateTime(1970);
      final bTime = b.lastMessage?.createdAt ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return result;
  }

  List<ChatThread> get archivedThreads {
    final result = _dedupeVisibleThreads(
      [
        ...threads.values,
        ...groups.values,
      ].where((thread) => thread.archived).toList(),
    );
    result.sort((a, b) {
      final aTime = a.lastMessage?.createdAt ?? DateTime(1970);
      final bTime = b.lastMessage?.createdAt ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    return result;
  }

  List<StoryItem> get activeStories {
    final expired = stories.values.any((story) => story.expired);
    if (expired) unawaited(_pruneStories());
    final result = stories.values.where((story) => !story.expired).toList()
      ..sort((a, b) {
        if (a.ownerNode == myNodeId && b.ownerNode != myNodeId) return -1;
        if (b.ownerNode == myNodeId && a.ownerNode != myNodeId) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });
    return result;
  }

  List<ChatThread> _dedupeVisibleThreads(List<ChatThread> source) {
    final personal = <String, ChatThread>{};
    final result = <ChatThread>[];
    for (final thread in source) {
      if (thread.isGroup || isSavedMessagesProfile(thread.profile)) {
        result.add(thread);
        continue;
      }
      final key = _threadIdentityKey(thread);
      final existing = personal[key];
      if (existing == null) {
        personal[key] = thread;
        continue;
      }
      personal[key] = _preferVisibleThread(existing, thread);
    }
    result.addAll(personal.values);
    return result;
  }

  String _threadIdentityKey(ChatThread thread) {
    final profile = thread.profile;
    final username = profile.publicUsername.trim().toLowerCase();
    if (username.isNotEmpty) return 'username:$username';
    if (profile.avatarData.isNotEmpty &&
        profile.displayName.trim().isNotEmpty) {
      final avatarKey = profile.avatarData.length <= 96
          ? profile.avatarData
          : profile.avatarData.substring(0, 96);
      return 'visual:${profile.displayName.trim().toLowerCase()}:$avatarKey';
    }
    return 'node:${profile.nodeId}';
  }

  ChatThread _preferVisibleThread(ChatThread a, ChatThread b) {
    if (a.pinned != b.pinned) return a.pinned ? a : b;
    final aTime = a.lastMessage?.createdAt ?? DateTime(1970);
    final bTime = b.lastMessage?.createdAt ?? DateTime(1970);
    final timeCompare = aTime.compareTo(bTime);
    if (timeCompare != 0) return timeCompare > 0 ? a : b;
    if (a.messages.length != b.messages.length) {
      return a.messages.length > b.messages.length ? a : b;
    }
    return a.unread >= b.unread ? a : b;
  }

  bool isTyping(ChatThread thread) {
    final key = thread.isGroup ? thread.groupId : thread.profile.nodeId;
    final until = typingUntil[key];
    return until != null && until.isAfter(DateTime.now());
  }

  String activityLabel(ChatThread thread) {
    final key = thread.isGroup ? thread.groupId : thread.profile.nodeId;
    final until = typingUntil[key];
    if (until == null || !until.isAfter(DateTime.now())) return '';
    return activityKinds[key] == 'voice' ? 'recording voice...' : 'typing...';
  }

  bool isBlocked(String nodeId) => appSettings.blockedNodeIds.contains(nodeId);

  int get queuedMessageCount {
    var count = 0;
    for (final thread in [...threads.values, ...groups.values]) {
      for (final message in thread.messages) {
        if (message.senderNode != myNodeId) continue;
        if (message.deleted) continue;
        if (message.pending || message.failed) count++;
      }
    }
    return count;
  }

  Future<void> retryQueuedMessagesNow() async {
    if (!_socket.isConnected) {
      status = 'Queued: waiting for server connection';
      notifyListeners();
      return;
    }
    await _retryQueuedMessages();
  }

  Future<void> cancelQueuedMessages() async {
    var changed = false;
    for (final thread in [...threads.values, ...groups.values]) {
      final before = thread.messages.length;
      thread.messages.removeWhere(
        (message) =>
            message.senderNode == myNodeId &&
            !message.deleted &&
            (message.pending || message.failed),
      );
      changed = changed || before != thread.messages.length;
    }
    if (!changed) return;
    await _saveCache();
    notifyListeners();
  }

  void _handleBluetoothStateChanged() {
    notifyListeners();
  }

  void clearIncomingPreview() {
    _incomingPreviewTimer?.cancel();
    _incomingPreviewTimer = null;
    if (incomingPreviewMessage == null && incomingPreviewThread == null) return;
    incomingPreviewThread = null;
    incomingPreviewMessage = null;
    incomingPreviewVersion++;
    notifyListeners();
  }

  void _publishIncomingPreview(ChatThread thread, ChatMessage message) {
    if (_isThreadActive(thread)) return;
    incomingPreviewThread = thread;
    incomingPreviewMessage = message;
    incomingPreviewVersion++;
    _incomingPreviewTimer?.cancel();
    _incomingPreviewTimer = Timer(const Duration(seconds: 4), () {
      incomingPreviewThread = null;
      incomingPreviewMessage = null;
      incomingPreviewVersion++;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> toggleBlocked(String nodeId) async {
    if (nodeId.isEmpty || nodeId == myNodeId) return;
    final blocked = {...appSettings.blockedNodeIds};
    if (!blocked.remove(nodeId)) blocked.add(nodeId);
    await updateAppSettings(
      appSettings.copyWith(blockedNodeIds: blocked.toList()..sort()),
    );
  }

  void setActiveThread(ChatThread? thread) {
    final key = thread == null ? '' : _threadReadKey(thread);
    if (_activeThreadKey == key) return;
    _activeThreadKey = key;
    if (thread != null) markRead(thread);
  }

  String _threadReadKey(ChatThread thread) {
    return thread.isGroup
        ? 'group:${thread.groupId}'
        : 'chat:${thread.profile.nodeId}';
  }

  bool _isThreadActive(ChatThread thread) {
    return _activeThreadKey.isNotEmpty &&
        _activeThreadKey == _threadReadKey(thread);
  }

  Future<void> restoreSession() async {
    unawaited(_notifications.initialize());
    appSettings = await _settingsStore.load();
    recentSessions = await _store.loadRecent();
    session = await _store.load();
    if (session != null) {
      await _cache.load(session!, profiles, threads, groups);
      await _loadStories();
      await _repairCachedGroups();
      await _repairCachedMessages();
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

  Future<void> forceResync() async {
    if (session == null) return;
    status = 'Resyncing...';
    addDiagnostic('sync', 'Manual resync requested');
    notifyListeners();
    await _socket.close();
    await _connect();
  }

  Future<void> requestNotificationPermissions() async {
    await _notifications.requestPermissions();
    await _syncWebPushSubscription();
  }

  Future<void> _syncWebPushSubscription() async {
    if (!kIsWeb) return;
    if (_webPushSubscribeInFlight) return;
    if (session == null || _webPushVapidPublicKey.isEmpty) return;
    if (!appSettings.notificationsEnabled) return;
    _webPushSubscribeInFlight = true;
    try {
      final subscription = await _notifications.subscribeToPush(
        _webPushVapidPublicKey,
      );
      if (subscription == null || subscription['endpoint'] == null) return;
      _socket.send({
        'type': 'push_subscribe',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': 'SERVER',
        'subscription': subscription,
        'user_agent': _notifications.webUserAgent(),
        'ttl': 5,
      });
    } finally {
      _webPushSubscribeInFlight = false;
    }
  }

  Future<void> _unsubscribeWebPush() async {
    if (!kIsWeb || session == null) return;
    final endpoint = await _notifications.unsubscribeFromPush();
    _socket.send({
      'type': 'push_unsubscribe',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'endpoint': endpoint,
      'ttl': 5,
    });
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
      await _loadStories();
      await _repairCachedGroups();
      await _repairCachedMessages();
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
      await _loadStories();
      await _repairCachedGroups();
      await _repairCachedMessages();
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
      profile: ownProfile,
      onPacket: _handlePacket,
      onStatus: (value) {
        status = value;
        addDiagnostic('server', value);
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
          addDiagnostic('server', 'Protocol OK, server welcome received');
          _webPushVapidPublicKey =
              packet['web_push_vapid_public_key']?.toString() ?? '';
          unawaited(_syncWebPushSubscription());
          unawaited(_retryQueuedMessages());
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
        addDiagnostic('server', status);
        notifyListeners();
      case 'server_users':
        _applyOnlineUsers(packet['users']);
      case 'server_sync':
        await _applySync(packet);
      case 'server_sync_done':
        status = 'Online';
        lastSyncAt = DateTime.now();
        addDiagnostic('sync', 'Sync received');
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
        await _applyDeletePacket(packet);
      case 'chat_delete':
      case 'group_delete':
        await _applyThreadDeletePacket(packet);
      case 'message_pin':
      case 'group_pin':
        _applyPinPacket(packet);
      case 'typing':
        _applyTypingPacket(packet);
      case 'story_update':
        await _applyStoryPacket(packet);
      case 'story_reaction':
        await _applyStoryReactionPacket(packet);
      case 'story_view':
        await _applyStoryViewPacket(packet);
      case 'story_delete':
        await _applyStoryDeletePacket(packet);
      case 'chat_request':
        _acceptChatRequest(packet);
      case 'group_join_request':
        _handleGroupJoinRequest(packet);
      case 'group_join_response':
        _handleGroupJoinResponse(packet);
      case 'call_offer':
        await _handleCallOffer(packet);
      case 'call_answer':
        await _handleCallAnswer(packet);
      case 'call_end':
        await _handleCallEnd(packet);
      case 'call_ice':
        await _handleCallIce(packet);
    }
    notifyListeners();
  }

  Future<void> _handleBluetoothPacket(Map<String, dynamic> packet) async {
    await _handlePacket({
      ...packet,
      'sender_transport': 'bluetooth',
      'protocol_version':
          packet['protocol_version'] ?? MeshSocket.protocolVersion,
    });
  }

  void _applyOnlineUsers(dynamic rawUsers) {
    final onlineIds = <String>{};
    final onlineUsernames = <String>{};
    for (final raw in rawUsers is List ? rawUsers : const []) {
      if (raw is! Map) continue;
      final profile = Profile.fromJson(Map<String, dynamic>.from(raw));
      if (profile.nodeId.isEmpty || _isOwnProfileAlias(profile)) continue;
      onlineIds.add(profile.nodeId);
      final username = profile.publicUsername.trim().toLowerCase();
      if (username.isNotEmpty) onlineUsernames.add(username);
      final onlineProfile = _mergeProfile(profile, online: true);
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
      if (profile.nodeId.isNotEmpty &&
          (!_isOwnProfileAlias(profile) || profile.nodeId == myNodeId)) {
        profiles[profile.nodeId] = _mergeProfile(profile, online: true);
        final username = profile.publicUsername.trim().toLowerCase();
        if (profile.nodeId == myNodeId &&
            username.isNotEmpty &&
            session != null) {
          session = session!.copyWith(publicUsername: username);
          await _store.updatePublicUsername(username);
        }
      }
    }

    for (final raw
        in packet['profiles'] is List ? packet['profiles'] as List : const []) {
      if (raw is! Map) continue;
      final profile = Profile.fromJson(Map<String, dynamic>.from(raw));
      if (profile.nodeId.isNotEmpty && !_isOwnProfileAlias(profile)) {
        final current =
            profiles[profile.nodeId] ?? threads[profile.nodeId]?.profile;
        final merged = _mergeProfile(profile, online: current?.online ?? false);
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
            displayName: sentByMe
                ? (receiverLogin.isNotEmpty
                      ? receiverLogin
                      : peerId.substring(0, 8))
                : (data['sender_name']?.toString() ?? peerId.substring(0, 8)),
          );
      profiles[peerId] = _mergeProfile(profile);
      final thread = _ensureThread(profile);
      final id = data['message_id']?.toString() ?? const Uuid().v4();
      if (_isDeletedMessage(id)) continue;
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

    await _applyGroups(packet['groups']);
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
    await _applyStories(packet['stories']);
    await _repairCachedGroups();
    await _repairCachedMessages();
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

  Future<void> _applyGroups(dynamic rawGroups) async {
    for (final raw in rawGroups is List ? rawGroups : const []) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final groupId = data['group_id']?.toString() ?? '';
      if (groupId.isEmpty) continue;
      if (appSettings.deletedGroupIds.contains(groupId)) continue;
      if (!appSettings.allowGroupInvites &&
          !groups.containsKey(groupId) &&
          data['owner_node']?.toString() != myNodeId) {
        continue;
      }
      _ensureGroupThread(
        groupId: groupId,
        groupName: data['group_name']?.toString() ?? 'Группа',
        members: _stringList(data['members']),
        ownerNode: data['owner_node']?.toString() ?? '',
        admins: _stringList(data['admins']),
        isChannel: data['is_channel'] == true,
        about: data['group_about']?.toString() ?? '',
        avatarData: data['group_avatar_data']?.toString() ?? '',
      );
      for (final rawKey
          in data['group_keys'] is List
              ? data['group_keys'] as List
              : const []) {
        if (rawKey is! Map) continue;
        await _acceptGroupKeyEnvelope(
          groupId,
          rawKey['key_id']?.toString() ?? '',
          rawKey['key_envelope']?.toString() ?? '',
        );
      }
    }
    unawaited(_saveCache());
  }

  Future<void> _repairCachedGroups() async {
    if (session == null || groups.isEmpty) return;
    var changed = false;
    final deletedGroupIds = appSettings.deletedGroupIds.toSet();
    for (final groupId in deletedGroupIds) {
      final group = groups.remove(groupId);
      if (group == null) continue;
      _groupKeys.remove(groupId);
      typingUntil.remove(groupId);
      activityKinds.remove(groupId);
      await _cache.deleteThread(session, group);
      changed = true;
    }
    final brokenGroupIds = groups.entries
        .where(
          (entry) =>
              entry.key.trim().isEmpty ||
              entry.value.groupId.trim().isEmpty ||
              entry.key != entry.value.groupId,
        )
        .map((entry) => entry.key)
        .toList();
    for (final groupId in brokenGroupIds) {
      groups.remove(groupId);
      _groupKeys.remove(groupId);
      typingUntil.remove(groupId);
      activityKinds.remove(groupId);
      changed = true;
    }
    for (final group in groups.values) {
      changed = _ensureOwnGroupMembership(group) || changed;
    }
    if (changed) await _saveCache();
  }

  Future<void> _repairCachedMessages() async {
    var changed = false;
    for (final thread in [...threads.values, ...groups.values]) {
      changed = _dedupeThreadMessages(thread) || changed;
    }
    if (changed) {
      addDiagnostic('sync', 'Removed duplicate cached messages');
      await _saveCache();
    }
  }

  bool _dedupeThreadMessages(ChatThread thread) {
    final before = thread.messages.length;
    final byId = <String, ChatMessage>{};
    for (final message in thread.messages) {
      if (message.id.trim().isEmpty) continue;
      if (_isDeletedMessage(message.id)) continue;
      final existing = byId[message.id];
      byId[message.id] = existing == null
          ? message
          : _preferRicherMessage(existing, message);
    }
    thread.messages
      ..clear()
      ..addAll(byId.values);
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return thread.messages.length != before;
  }

  ChatMessage _preferRicherMessage(ChatMessage a, ChatMessage b) {
    final aScore = _messageRichnessScore(a);
    final bScore = _messageRichnessScore(b);
    if (aScore != bScore) return aScore > bScore ? a : b;
    if (a.delivered != b.delivered) return a.delivered ? a : b;
    if (a.pending != b.pending) return a.pending ? b : a;
    return a.createdAt.isAfter(b.createdAt) ? a : b;
  }

  int _messageRichnessScore(ChatMessage message) {
    var score = 0;
    if (message.kind == ChatMessageKind.file) score += 8;
    if (message.fileData.isNotEmpty) score += 16;
    if (message.fileName.isNotEmpty) score += 4;
    if (message.fileSize > 0) score += 2;
    if (message.text.isNotEmpty) score += 1;
    return score;
  }

  bool _ensureOwnGroupMembership(ChatThread group) {
    if (session == null || !group.isGroup) return false;
    final oldOwner = group.ownerNode.trim();
    final normalized = _normalizedGroupMembers(group.members);
    final normalizedOwner = _normalizedGroupOwner(oldOwner, normalized);
    if (normalizedOwner != oldOwner && oldOwner.isNotEmpty) {
      normalized.remove(oldOwner);
    }
    if (normalizedOwner.isNotEmpty && !normalized.contains(normalizedOwner)) {
      normalized.add(normalizedOwner);
      normalized.sort();
    }
    final sameMembers =
        normalized.length == group.members.length &&
        normalized.every(group.members.contains);
    final normalizedAdmins = group.admins
        .where((admin) => normalized.contains(admin))
        .toSet()
        .toList();
    if (normalizedOwner == myNodeId && !normalizedAdmins.contains(myNodeId)) {
      normalizedAdmins.add(myNodeId);
    }
    final sameAdmins =
        normalizedAdmins.length == group.admins.length &&
        normalizedAdmins.every(group.admins.contains);
    final sameOwner = group.ownerNode == normalizedOwner;
    if (sameMembers && sameAdmins && sameOwner) return false;
    group.ownerNode = normalizedOwner;
    group.members
      ..clear()
      ..addAll(normalized);
    group.admins
      ..clear()
      ..addAll(normalizedAdmins);
    return true;
  }

  String _normalizedGroupOwner(String ownerNode, List<String> members) {
    final owner = ownerNode.trim();
    if (owner.isEmpty || owner == myNodeId) return myNodeId;
    if (_isLegacyGroupOwnerPlaceholder(owner) && members.contains(myNodeId)) {
      return myNodeId;
    }
    return owner;
  }

  bool _isLegacyGroupOwnerPlaceholder(String nodeId) {
    final value = nodeId.trim();
    if (value.isEmpty || value == myNodeId) return false;
    final uuidLike = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
    return !uuidLike && value.length <= 12;
  }

  List<String> _normalizedGroupMembers(Iterable<String> members) {
    final result = <String>{
      if (myNodeId.isNotEmpty) myNodeId,
      ...members
          .where((id) => id.trim().isNotEmpty)
          .map((id) => id.trim())
          .where((id) => !_isLegacyGroupOwnerPlaceholder(id)),
    }.toList();
    result.sort();
    return result;
  }

  ChatThread _ensureGroupThread({
    required String groupId,
    required String groupName,
    List<String> members = const [],
    String ownerNode = '',
    List<String> admins = const [],
    bool isChannel = false,
    String about = '',
    String avatarData = '',
  }) {
    final hasIncomingMembers = members.any((id) => id.trim().isNotEmpty);
    final normalizedMembers = hasIncomingMembers
        ? _normalizedGroupMembers(members)
        : <String>[];
    final ownerBaseMembers = hasIncomingMembers
        ? normalizedMembers
        : _normalizedGroupMembers(groups[groupId]?.members ?? const <String>[]);
    final normalizedOwner = _normalizedGroupOwner(ownerNode, ownerBaseMembers);
    if (normalizedOwner != ownerNode.trim() && ownerNode.trim().isNotEmpty) {
      normalizedMembers.remove(ownerNode.trim());
      ownerBaseMembers.remove(ownerNode.trim());
    }
    if (normalizedOwner.isNotEmpty &&
        hasIncomingMembers &&
        !normalizedMembers.contains(normalizedOwner)) {
      normalizedMembers.add(normalizedOwner);
      normalizedMembers.sort();
    }
    final adminBase = hasIncomingMembers ? normalizedMembers : ownerBaseMembers;
    final normalizedAdmins = admins
        .where((admin) => adminBase.contains(admin))
        .toSet()
        .toList();
    if (normalizedOwner == myNodeId && !normalizedAdmins.contains(myNodeId)) {
      normalizedAdmins.add(myNodeId);
    }
    final existing = groups[groupId];
    if (existing != null) {
      existing.isChannel = existing.isChannel || isChannel;
      final incomingName = groupName.trim();
      final isDefaultIncomingName =
          incomingName == 'Р“СЂСѓРїРїР°' || incomingName == 'Группа';
      final currentName = existing.profile.displayName.trim();
      final currentIsDefault =
          currentName.isEmpty ||
          currentName == 'Р“СЂСѓРїРїР°' ||
          currentName == 'Группа';
      if (incomingName.isNotEmpty &&
          (!isDefaultIncomingName || currentIsDefault)) {
        existing.profile = existing.profile.copyWith(displayName: groupName);
      }
      if (about.isNotEmpty || avatarData.isNotEmpty) {
        existing.profile = existing.profile.copyWith(
          about: about.isEmpty ? null : about,
          avatarData: avatarData.isEmpty ? null : avatarData,
        );
      }
      if (hasIncomingMembers && normalizedMembers.isNotEmpty) {
        existing.members
          ..clear()
          ..addAll(normalizedMembers);
      }
      if (normalizedAdmins.isNotEmpty || admins.isNotEmpty) {
        existing.admins
          ..clear()
          ..addAll(normalizedAdmins);
      }
      if (normalizedOwner.isNotEmpty) {
        existing.ownerNode = normalizedOwner;
      }
      return existing;
    }
    final profile = Profile(
      nodeId: 'group:$groupId',
      displayName: groupName.isEmpty ? 'Группа' : groupName,
      about: about,
      avatarData: avatarData,
    );
    final thread = ChatThread(
      profile: profile,
      isGroup: true,
      isChannel: isChannel,
      groupId: groupId,
      groupName: groupName.isEmpty ? 'Группа' : groupName,
      members: normalizedMembers.isEmpty
          ? _normalizedGroupMembers(const [])
          : normalizedMembers,
      ownerNode: normalizedOwner,
      admins: normalizedAdmins,
    );
    groups[groupId] = thread;
    return thread;
  }

  Future<String?> sendGroupMessage(
    ChatThread group,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || session == null || !group.isGroup) return null;
    if (group.isChannel && !_canPostToChannel(group)) return null;
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
    if (!_socket.isConnected) {
      status = 'Queued: waiting for server connection';
      notifyListeners();
      return id;
    }

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
      'is_channel': group.isChannel,
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
    return id;
  }

  Future<void> _receiveGroupMessage(
    Map<String, dynamic> packet, {
    required bool fromSync,
  }) async {
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isEmpty) return;
    if (appSettings.deletedGroupIds.contains(groupId)) return;
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: _stringList(packet['members']),
      isChannel: packet['is_channel'] == true,
    );
    final id =
        packet['group_message_id']?.toString() ??
        packet['message_id']?.toString() ??
        packet['packet_id']?.toString() ??
        const Uuid().v4();
    if (_isDeletedMessage(id)) return;
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
    if (isBlocked(packetSender)) return;
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
    final received = group.messages.last;
    group.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (!fromSync && sender != myNodeId) {
      final active = _isThreadActive(group);
      if (active) {
        group.unread = 0;
      } else {
        group.unread++;
      }
      if (!active && !group.muted) {
        unawaited(
          _showNotification(
            title: group.profile.displayName,
            body: '$senderName: $text',
          ),
        );
      }
      _publishIncomingPreview(group, received);
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
    if (appSettings.deletedGroupIds.contains(groupId)) return;
    if (!appSettings.allowGroupInvites &&
        !groups.containsKey(groupId) &&
        packet['owner_node']?.toString() != myNodeId) {
      return;
    }
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: _stringList(packet['members']),
      ownerNode: packet['owner_node']?.toString() ?? '',
      admins: _stringList(packet['admins']),
      isChannel: packet['is_channel'] == true,
      about: packet['group_about']?.toString() ?? '',
      avatarData: packet['group_avatar_data']?.toString() ?? '',
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
    final isCaption = message.kind == ChatMessageKind.file;
    if (session == null || message.senderNode != myNodeId) {
      return;
    }
    if (!isCaption && trimmed.isEmpty) {
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
      if (isCaption) 'file_caption': trimmed,
    });
  }

  Future<void> deleteMessage(ChatThread thread, ChatMessage message) async {
    if (session == null || message.senderNode != myNodeId) return;
    await _rememberDeletedMessage(message.id);
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

  Future<void> deleteMessageForMe(
    ChatThread thread,
    ChatMessage message,
  ) async {
    await _rememberDeletedMessage(message.id);
    _deleteLocalMessage(thread, message.id);
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

  Future<String?> publishStory({
    required String text,
    required String imageData,
    required String videoData,
    required String videoMime,
    required StoryMediaType mediaType,
    required StoryVisibility visibility,
    required List<String> selectedNodeIds,
    required List<String> excludedNodeIds,
  }) async {
    if (session == null) return 'No active session';
    final trimmed = text.trim();
    if (trimmed.isEmpty && imageData.isEmpty && videoData.isEmpty) {
      return 'Story is empty';
    }
    final story = StoryItem(
      id: const Uuid().v4(),
      ownerNode: myNodeId,
      ownerName: ownProfile.displayName,
      ownerAvatarData: ownProfile.avatarData,
      createdAt: DateTime.now(),
      text: trimmed,
      imageData: imageData,
      videoData: videoData,
      videoMime: videoMime,
      mediaType: mediaType,
      visibility: visibility,
      allowedNodeIds: selectedNodeIds,
      excludedNodeIds: excludedNodeIds,
    );
    stories[story.id] = story;
    await _saveStories();
    notifyListeners();

    final recipients = _storyRecipients(
      visibility: visibility,
      selectedNodeIds: selectedNodeIds,
      excludedNodeIds: excludedNodeIds,
    );
    final basePacket = {
      'type': 'story_update',
      'packet_id': story.id,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'story': story.toJson(),
    };
    for (final recipient in recipients) {
      _socket.send({...basePacket, 'destination_node': recipient});
    }
    return null;
  }

  Future<void> likeStory(StoryItem story) async {
    if (session == null || story.ownerNode == myNodeId || story.expired) return;
    final current = stories[story.id] ?? story;
    final liked = current.likedByNodeIds.contains(myNodeId);
    final nextLikes = current.likedByNodeIds
        .where((id) => id != myNodeId)
        .toList();
    if (!liked) nextLikes.add(myNodeId);
    stories[story.id] = current.copyWith(likedByNodeIds: nextLikes);
    await _saveStories();
    notifyListeners();
    _socket.send({
      'type': 'story_reaction',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': story.ownerNode,
      'ttl': 5,
      'sender': session!.login,
      'story_id': story.id,
      'reaction': 'heart',
      'liked': !liked,
    });
  }

  Future<void> markStoryViewed(StoryItem story) async {
    if (session == null || story.ownerNode == myNodeId || story.expired) return;
    final current = stories[story.id] ?? story;
    if (current.viewedByNodeIds.contains(myNodeId)) return;
    final nextViews = [...current.viewedByNodeIds, myNodeId];
    stories[story.id] = current.copyWith(viewedByNodeIds: nextViews);
    await _saveStories();
    notifyListeners();
    _socket.send({
      'type': 'story_view',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': story.ownerNode,
      'ttl': 5,
      'sender': session!.login,
      'story_id': story.id,
    });
  }

  Future<String?> deleteStory(StoryItem story) async {
    if (session == null) return 'No active session';
    if (story.ownerNode != myNodeId) return 'Only your story can be deleted';
    stories.remove(story.id);
    await _saveStories();
    notifyListeners();

    final recipients = _storyRecipients(
      visibility: story.visibility,
      selectedNodeIds: story.allowedNodeIds,
      excludedNodeIds: story.excludedNodeIds,
    )..add('SERVER');
    final basePacket = {
      'type': 'story_delete',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'story_id': story.id,
    };
    for (final recipient in recipients) {
      _socket.send({...basePacket, 'destination_node': recipient});
    }
    return null;
  }

  Set<String> _storyRecipients({
    required StoryVisibility visibility,
    required List<String> selectedNodeIds,
    required List<String> excludedNodeIds,
  }) {
    final known = <String>{};
    final chatPeers = <String>{};
    for (final profile in profiles.values) {
      if (_canTargetStory(profile.nodeId)) known.add(profile.nodeId);
    }
    for (final thread in threads.values) {
      if (_canTargetStory(thread.profile.nodeId)) {
        known.add(thread.profile.nodeId);
        chatPeers.add(thread.profile.nodeId);
      }
    }
    if (visibility == StoryVisibility.chats) return chatPeers;
    if (visibility == StoryVisibility.selected) {
      return selectedNodeIds.where(_canTargetStory).toSet();
    }
    if (visibility == StoryVisibility.excluded) {
      final excluded = excludedNodeIds.toSet();
      return known.where((nodeId) => !excluded.contains(nodeId)).toSet();
    }
    return known;
  }

  bool _canTargetStory(String nodeId) {
    return nodeId.isNotEmpty &&
        nodeId != myNodeId &&
        !nodeId.startsWith('group:') &&
        !nodeId.startsWith('saved:') &&
        !isBlocked(nodeId);
  }

  Future<void> _applyStoryPacket(Map<String, dynamic> packet) async {
    final raw = packet['story'];
    if (raw is! Map) return;
    final story = StoryItem.fromJson(Map<String, dynamic>.from(raw));
    if (story.id.isEmpty ||
        story.ownerNode.isEmpty ||
        story.ownerNode == myNodeId ||
        story.expired ||
        isBlocked(story.ownerNode)) {
      return;
    }
    stories[story.id] = story;
    final owner = profiles[story.ownerNode];
    profiles[story.ownerNode] =
        (owner ??
                Profile(nodeId: story.ownerNode, displayName: story.ownerName))
            .copyWith(
              displayName: story.ownerName,
              avatarData: story.ownerAvatarData.isNotEmpty
                  ? story.ownerAvatarData
                  : null,
            );
    await _saveStories();
  }

  Future<void> _applyStories(dynamic rawStories) async {
    if (rawStories is! List) return;
    var changed = false;
    final incomingIds = <String>{};
    for (final raw in rawStories) {
      if (raw is! Map) continue;
      final story = StoryItem.fromJson(Map<String, dynamic>.from(raw));
      if (story.id.isEmpty || story.ownerNode.isEmpty || story.expired) {
        continue;
      }
      if (story.ownerNode != myNodeId && isBlocked(story.ownerNode)) continue;
      incomingIds.add(story.id);
      stories[story.id] = story;
      changed = true;
    }
    final before = stories.length;
    stories.removeWhere((storyId, story) => !incomingIds.contains(storyId));
    if (before != stories.length) changed = true;
    if (changed) await _saveStories();
  }

  Future<void> _applyStoryReactionPacket(Map<String, dynamic> packet) async {
    final storyId = packet['story_id']?.toString() ?? '';
    final reactor = packet['source_node']?.toString() ?? '';
    if (storyId.isEmpty || reactor.isEmpty || isBlocked(reactor)) return;
    final story = stories[storyId];
    if (story == null) return;
    final liked = packet['liked'] != false;
    final nextLikes = story.likedByNodeIds
        .where((nodeId) => nodeId != reactor)
        .toList();
    if (liked) nextLikes.add(reactor);
    stories[storyId] = story.copyWith(likedByNodeIds: nextLikes);
    await _saveStories();
  }

  Future<void> _applyStoryViewPacket(Map<String, dynamic> packet) async {
    final storyId = packet['story_id']?.toString() ?? '';
    final viewer = packet['source_node']?.toString() ?? '';
    if (storyId.isEmpty || viewer.isEmpty || isBlocked(viewer)) return;
    final story = stories[storyId];
    if (story == null || story.ownerNode != myNodeId) return;
    if (story.viewedByNodeIds.contains(viewer)) return;
    stories[storyId] = story.copyWith(
      viewedByNodeIds: [...story.viewedByNodeIds, viewer],
    );
    await _saveStories();
  }

  Future<void> _applyStoryDeletePacket(Map<String, dynamic> packet) async {
    final storyId = packet['story_id']?.toString() ?? '';
    final source = packet['source_node']?.toString() ?? '';
    if (storyId.isEmpty || source.isEmpty) return;
    final story = stories[storyId];
    if (story == null || story.ownerNode != source) return;
    stories.remove(storyId);
    await _saveStories();
  }

  Future<void> _loadStories() async {
    final current = session;
    stories.clear();
    if (current == null) return;
    stories.addAll(await _storyStore.load(current));
    await _pruneStories();
  }

  Future<void> _saveStories() async {
    await _storyStore.save(session, stories.values);
  }

  Future<void> _pruneStories() async {
    final before = stories.length;
    stories.removeWhere((_, story) => story.expired);
    if (before != stories.length) {
      await _saveStories();
      notifyListeners();
    }
  }

  Future<void> deleteThread(ChatThread thread) async {
    if (thread.isGroup) {
      if (thread.groupId.isNotEmpty) {
        await _rememberDeletedGroup(thread.groupId);
        groups.removeWhere(
          (_, group) =>
              group.groupId == thread.groupId ||
              identical(group, thread) ||
              _looksLikeSameBrokenGroup(group, thread),
        );
        _groupKeys.remove(thread.groupId);
      } else {
        groups.removeWhere(
          (_, group) =>
              identical(group, thread) ||
              _looksLikeSameBrokenGroup(group, thread),
        );
      }
    } else {
      threads.remove(thread.profile.nodeId);
      profiles.remove(thread.profile.nodeId);
    }
    final activityKey = thread.isGroup ? thread.groupId : thread.profile.nodeId;
    typingUntil.remove(activityKey);
    activityKinds.remove(activityKey);
    await _rewriteCache();
    notifyListeners();
  }

  Future<String?> deleteThreadForEveryone(ChatThread thread) async {
    if (session == null) return 'No active session';
    if (thread.isGroup && !_ownsGroup(thread)) {
      return thread.isChannel
          ? 'Only channel owner can delete it'
          : 'Only group owner can delete it';
    }
    final packetBase = {
      'type': thread.isGroup ? 'group_delete' : 'chat_delete',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': thread.groupId,
      'chat_node_id': thread.profile.nodeId,
    };
    final recipients = thread.isGroup
        ? thread.members
              .where((member) => member.isNotEmpty && member != myNodeId)
              .toSet()
        : {thread.profile.nodeId};
    for (final recipient in recipients) {
      _socket.send({
        ...packetBase,
        'packet_id': const Uuid().v4(),
        'destination_node': recipient,
      });
    }
    await deleteThread(thread);
    return null;
  }

  Future<String?> leaveGroup(ChatThread group) async {
    if (session == null) return 'No active session';
    if (!group.isGroup) return 'This is not a group';
    if (_ownsGroup(group)) {
      return group.isChannel
          ? 'Channel owner can delete the channel instead'
          : 'Group owner can delete the group instead';
    }
    final groupId = group.groupId;
    if (groupId.isEmpty) return 'Group id is empty';
    final remaining =
        group.members
            .where((member) => member.isNotEmpty && member != myNodeId)
            .where((member) => !_isLegacyGroupOwnerPlaceholder(member))
            .toSet()
            .toList()
          ..sort();
    group.members
      ..clear()
      ..addAll(remaining);
    group.admins.remove(myNodeId);
    await _publishGroupUpdate(group, rotateKey: true);
    await _rememberDeletedGroup(groupId);
    groups.remove(groupId);
    _groupKeys.remove(groupId);
    typingUntil.remove(groupId);
    activityKinds.remove(groupId);
    await _rewriteCache();
    notifyListeners();
    return null;
  }

  bool _ownsGroup(ChatThread thread) {
    if (!thread.isGroup) return false;
    final owner = thread.ownerNode.trim();
    return owner.isEmpty || owner == myNodeId;
  }

  Future<void> _applyThreadDeletePacket(Map<String, dynamic> packet) async {
    final source = packet['source_node']?.toString() ?? '';
    if (source.isEmpty || source == myNodeId || isBlocked(source)) return;
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isNotEmpty) {
      final group = groups[groupId];
      if (group == null || !group.members.contains(source)) return;
      final owner = group.ownerNode.trim();
      if (owner.isNotEmpty && source != owner) return;
      await _rememberDeletedGroup(groupId);
      groups.remove(groupId);
      _groupKeys.remove(groupId);
      typingUntil.remove(groupId);
      activityKinds.remove(groupId);
    } else {
      final chatNodeId = packet['chat_node_id']?.toString() ?? source;
      final thread = threads[chatNodeId] ?? threads[source];
      if (thread == null) return;
      threads.remove(thread.profile.nodeId);
      profiles.remove(thread.profile.nodeId);
      typingUntil.remove(thread.profile.nodeId);
      activityKinds.remove(thread.profile.nodeId);
    }
    await _rewriteCache();
    notifyListeners();
  }

  bool _looksLikeSameBrokenGroup(ChatThread cached, ChatThread target) {
    if (!cached.isGroup || !target.isGroup) return false;
    if (cached.groupId.isNotEmpty &&
        target.groupId.isNotEmpty &&
        cached.groupId == target.groupId) {
      return true;
    }
    final sameProfile =
        cached.profile.nodeId.isNotEmpty &&
        cached.profile.nodeId == target.profile.nodeId;
    final sameName =
        cached.profile.displayName.trim().isNotEmpty &&
        cached.profile.displayName == target.profile.displayName;
    final sameGroupName =
        cached.groupName.trim().isNotEmpty &&
        cached.groupName == target.groupName;
    return sameProfile || sameName || sameGroupName;
  }

  Future<void> _rememberDeletedGroup(String groupId) async {
    if (groupId.isEmpty || appSettings.deletedGroupIds.contains(groupId)) {
      return;
    }
    final deleted = {...appSettings.deletedGroupIds, groupId}.toList()..sort();
    appSettings = appSettings.copyWith(deletedGroupIds: deleted);
    await _settingsStore.save(appSettings);
  }

  bool _isDeletedMessage(String messageId) {
    return messageId.isNotEmpty &&
        appSettings.deletedMessageIds.contains(messageId);
  }

  Future<void> _rememberDeletedMessage(String messageId) async {
    if (messageId.isEmpty ||
        appSettings.deletedMessageIds.contains(messageId)) {
      return;
    }
    final deleted = [...appSettings.deletedMessageIds, messageId];
    final trimmed = deleted.length > 3000
        ? deleted.sublist(deleted.length - 3000)
        : deleted;
    appSettings = appSettings.copyWith(deletedMessageIds: trimmed);
    await _settingsStore.save(appSettings);
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
    sendActivity(thread, 'typing');
  }

  void sendActivity(ChatThread thread, String kind) {
    if (session == null) return;
    final basePacket = {
      'type': 'typing',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 2,
      'sender': session!.login,
      'group_id': thread.groupId,
      'activity': kind,
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
    final activity = packet['activity']?.toString() ?? 'typing';
    typingUntil[key] = DateTime.now().add(const Duration(seconds: 4));
    activityKinds[key] = activity == 'voice' ? 'voice' : 'typing';
    Timer(const Duration(seconds: 4), () {
      final until = typingUntil[key];
      if (until != null && until.isBefore(DateTime.now())) {
        typingUntil.remove(key);
        activityKinds.remove(key);
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

  Future<void> _applyDeletePacket(Map<String, dynamic> packet) async {
    final messageId =
        packet['message_id']?.toString() ??
        packet['group_message_id']?.toString() ??
        '';
    if (messageId.isEmpty) return;
    await _rememberDeletedMessage(messageId);
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
    if (isSavedMessagesProfile(profile)) {
      return ensureSavedMessagesThread();
    }
    if (_isOwnProfileAlias(profile)) {
      return ChatThread(profile: profile);
    }
    final mergedProfile = _mergeProfile(profile);
    final existing = threads[profile.nodeId];
    if (existing != null) {
      existing.profile = mergedProfile;
      return existing;
    }
    final thread = ChatThread(profile: mergedProfile);
    threads[profile.nodeId] = thread;
    return thread;
  }

  Future<String?> startCall(Profile recipient) async {
    if (session == null) return 'No active session';
    if (isSavedMessagesProfile(recipient)) return 'Cannot call Saved Messages';
    if (recipient.nodeId.isEmpty || recipient.nodeId == myNodeId) {
      return 'Cannot call this user';
    }
    if (activeCall != null && activeCall!.status != CallStatus.ended) {
      return 'Another call is already active';
    }
    final call = ActiveCall(
      callId: const Uuid().v4(),
      peer: recipient,
      status: CallStatus.outgoing,
      incoming: false,
      startedAt: DateTime.now(),
    );
    _setActiveCall(call);
    notifyListeners();
    final offerSdp = await _calls
        .startOutgoing(
          onIceCandidate: (candidate) => _sendCallIce(call, candidate),
        )
        .catchError((error) async {
          _setActiveCall(
            call.copyWith(
              status: CallStatus.ended,
              endReason: 'start failed: $error',
            ),
          );
          notifyListeners();
          return '';
        });
    if (offerSdp.isEmpty) {
      return 'Call audio is not available on this device yet';
    }
    _socket.send({
      'type': 'call_offer',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': recipient.nodeId,
      'ttl': 5,
      'call_id': call.callId,
      'sender': session!.login,
      'media': 'audio',
      'sdp': offerSdp,
    });
    return null;
  }

  Future<String?> startGroupCall(ChatThread thread) async {
    if (session == null) return 'No active session';
    if (!thread.isGroup || thread.groupId.isEmpty) {
      return 'Cannot call this group';
    }
    if (activeCall != null && activeCall!.status != CallStatus.ended) {
      return 'Another call is already active';
    }
    final recipients = thread.members
        .where((nodeId) => nodeId.isNotEmpty && nodeId != myNodeId)
        .toSet()
        .toList();
    if (recipients.isEmpty) return 'No group members to call';
    final call = ActiveCall(
      callId: const Uuid().v4(),
      peer: thread.profile,
      status: CallStatus.outgoing,
      incoming: false,
      startedAt: DateTime.now(),
      isGroup: true,
      groupId: thread.groupId,
      groupMembers: recipients,
    );
    _setActiveCall(call);
    notifyListeners();

    var started = 0;
    for (final recipientNode in recipients) {
      final service = CallService();
      _groupCalls[recipientNode] = service;
      final offerSdp = await service
          .startOutgoing(
            onIceCandidate: (candidate) =>
                _sendCallIceTo(call, recipientNode, candidate),
          )
          .catchError((_) async => '');
      if (offerSdp.isEmpty) {
        unawaited(service.end().catchError((_) {}));
        _groupCalls.remove(recipientNode);
        continue;
      }
      started++;
      _socket.send({
        'type': 'call_offer',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': recipientNode,
        'ttl': 5,
        'call_id': call.callId,
        'sender': session!.login,
        'media': 'audio',
        'sdp': offerSdp,
        'group_id': thread.groupId,
        'group_name': thread.groupName.isEmpty
            ? thread.profile.displayName
            : thread.groupName,
        'group_members': recipients,
      });
    }
    if (started == 0) {
      _setActiveCall(
        call.copyWith(status: CallStatus.ended, endReason: 'audio unavailable'),
      );
      notifyListeners();
      unawaited(_endCallMedia());
      return 'Call audio is not available on this device yet';
    }
    return null;
  }

  Future<void> acceptCall() async {
    final call = activeCall;
    if (session == null || call == null || !call.incoming) return;
    if (call.remoteOfferSdp.isEmpty) {
      _sendCallEnd(call, 'bad_offer');
      _setActiveCall(
        call.copyWith(status: CallStatus.ended, endReason: 'bad offer'),
      );
      notifyListeners();
      return;
    }
    final answerSdp = await _calls
        .acceptIncoming(
          remoteOfferSdp: call.remoteOfferSdp,
          onIceCandidate: (candidate) => _sendCallIce(call, candidate),
        )
        .catchError((error) async {
          _sendCallEnd(call, 'audio_error');
          _setActiveCall(
            call.copyWith(
              status: CallStatus.ended,
              endReason: 'accept failed: $error',
            ),
          );
          notifyListeners();
          return '';
        });
    if (answerSdp.isEmpty) return;
    _setActiveCall(
      call.copyWith(
        status: CallStatus.active,
        connectedNodes: {call.peer.nodeId},
        quality: 2,
      ),
    );
    notifyListeners();
    _socket.send({
      'type': 'call_answer',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': call.peer.nodeId,
      'ttl': 5,
      'call_id': call.callId,
      'accepted': true,
      'sender': session!.login,
      'sdp': answerSdp,
      if (call.isGroup) 'group_id': call.groupId,
    });
  }

  Future<void> declineCall() async {
    final call = activeCall;
    if (session == null || call == null) return;
    _sendCallEnd(call, 'declined');
    _appendCallHistory(call, 'declined_by_me');
    _setActiveCall(
      call.copyWith(status: CallStatus.ended, endReason: 'declined'),
    );
    notifyListeners();
    await _endCallMedia();
  }

  Future<void> endCall() async {
    final call = activeCall;
    if (session == null || call == null) return;
    _sendCallEnd(call, 'ended');
    _appendCallHistory(call, 'ended_by_me');
    _setActiveCall(call.copyWith(status: CallStatus.ended, endReason: 'ended'));
    notifyListeners();
    await _endCallMedia();
  }

  Future<void> toggleCallMute() async {
    final call = activeCall;
    if (call == null || call.status == CallStatus.ended) return;
    final muted = !call.localMuted;
    _setActiveCall(call.copyWith(localMuted: muted));
    notifyListeners();
    await _calls.setMuted(muted).catchError((_) {});
    for (final service in _groupCalls.values) {
      await service.setMuted(muted).catchError((_) {});
    }
  }

  Future<void> toggleCallSpeaker() async {
    final call = activeCall;
    if (call == null || call.status == CallStatus.ended) return;
    final enabled = !call.speakerOn;
    _setActiveCall(call.copyWith(speakerOn: enabled));
    notifyListeners();
    await _calls.setSpeakerEnabled(enabled).catchError((_) {});
    for (final service in _groupCalls.values) {
      await service.setSpeakerEnabled(enabled).catchError((_) {});
    }
  }

  void toggleCallCollapsed() {
    final call = activeCall;
    if (call == null || call.status == CallStatus.ended) return;
    _setActiveCall(call.copyWith(collapsed: !call.collapsed));
    notifyListeners();
  }

  void clearEndedCall() {
    if (activeCall?.status != CallStatus.ended) return;
    _setActiveCall(null);
    notifyListeners();
  }

  void _sendCallEnd(ActiveCall call, String reason) {
    if (call.isGroup && !call.incoming) {
      final destinations = {...call.groupMembers, ..._groupCalls.keys}
        ..remove(myNodeId);
      for (final destination in destinations) {
        _sendCallEndTo(call, destination, reason);
      }
      return;
    }
    _sendCallEndTo(call, call.peer.nodeId, reason);
  }

  void _sendCallEndTo(ActiveCall call, String destination, String reason) {
    if (destination.isEmpty) return;
    _socket.send({
      'type': 'call_end',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': destination,
      'ttl': 5,
      'call_id': call.callId,
      'reason': reason,
      if (call.isGroup) 'group_id': call.groupId,
    });
  }

  void _sendCallIce(ActiveCall call, Map<String, dynamic> candidate) {
    _sendCallIceTo(call, call.peer.nodeId, candidate);
  }

  void _sendCallIceTo(
    ActiveCall call,
    String destination,
    Map<String, dynamic> candidate,
  ) {
    if (destination.isEmpty) return;
    _socket.send({
      'type': 'call_ice',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': destination,
      'ttl': 5,
      'call_id': call.callId,
      'candidate': candidate,
      if (call.isGroup) 'group_id': call.groupId,
    });
  }

  Future<void> _handleCallOffer(Map<String, dynamic> packet) async {
    final sender = packet['source_node']?.toString() ?? '';
    if (sender.isEmpty || sender == myNodeId) return;
    if (isBlocked(sender)) return;
    if (!appSettings.allowCalls) {
      _socket.send({
        'type': 'call_end',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': sender,
        'ttl': 5,
        'call_id': packet['call_id']?.toString() ?? '',
        'reason': 'declined',
      });
      return;
    }
    final groupId = packet['group_id']?.toString() ?? '';
    final groupName = packet['group_name']?.toString() ?? '';
    if (activeCall != null && activeCall!.status != CallStatus.ended) {
      _socket.send({
        'type': 'call_end',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': sender,
        'ttl': 5,
        'call_id': packet['call_id']?.toString() ?? '',
        'reason': 'busy',
      });
      return;
    }
    final senderProfile =
        profiles[sender] ??
        Profile(
          nodeId: sender,
          displayName: packet['sender']?.toString() ?? sender.substring(0, 8),
        );
    profiles[sender] = _mergeProfile(senderProfile);
    _ensureThread(senderProfile);
    final profile = groupId.isEmpty
        ? senderProfile
        : Profile(
            nodeId: sender,
            displayName: groupName.isEmpty ? 'Group call' : groupName,
          );
    _setActiveCall(
      ActiveCall(
        callId: packet['call_id']?.toString() ?? const Uuid().v4(),
        peer: profile,
        status: CallStatus.ringing,
        incoming: true,
        startedAt: DateTime.now(),
        remoteOfferSdp: packet['sdp']?.toString() ?? '',
        isGroup: groupId.isNotEmpty,
        groupId: groupId,
        groupMembers: _stringList(packet['group_members']),
      ),
    );
    unawaited(
      _showCallNotification(
        title: profile.displayName,
        body: groupId.isEmpty ? 'Incoming call' : 'Incoming group call',
      ),
    );
  }

  Future<void> _handleCallAnswer(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null) return;
    if (packet['call_id']?.toString() != call.callId) return;
    final source = packet['source_node']?.toString() ?? '';
    if (packet['accepted'] == true) {
      if (call.isGroup && !call.incoming) {
        final service = _groupCalls[source];
        if (service == null) return;
        await service
            .applyAnswer(packet['sdp']?.toString() ?? '')
            .catchError((_) {});
        _setActiveCall(
          call.copyWith(
            status: CallStatus.active,
            connectedNodes: {...call.connectedNodes, source},
            quality: 2,
          ),
        );
      } else {
        await _calls
            .applyAnswer(packet['sdp']?.toString() ?? '')
            .catchError((_) {});
        _setActiveCall(
          call.copyWith(
            status: CallStatus.active,
            connectedNodes: {source.isEmpty ? call.peer.nodeId : source},
            quality: 2,
          ),
        );
      }
    } else {
      if (call.isGroup && !call.incoming) {
        final service = _groupCalls.remove(source);
        if (service != null) {
          unawaited(
            service
                .end()
                .timeout(const Duration(seconds: 2), onTimeout: () {})
                .catchError((_) {}),
          );
        }
        if (_groupCalls.isNotEmpty) {
          _setActiveCall(
            call.copyWith(
              connectedNodes: {...call.connectedNodes}..remove(source),
              quality: call.connectedNodes.length <= 1 ? 1 : call.quality,
            ),
          );
          notifyListeners();
          return;
        }
      }
      _setActiveCall(
        call.copyWith(
          status: CallStatus.ended,
          endReason: packet['reason']?.toString() ?? 'remote ended',
        ),
      );
      notifyListeners();
      await _endCallMedia();
    }
  }

  Future<void> _handleCallEnd(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null) return;
    final packetCallId = packet['call_id']?.toString() ?? '';
    final source = packet['source_node']?.toString() ?? '';
    if (packetCallId != call.callId && source != call.peer.nodeId) return;
    if (call.isGroup && !call.incoming && _groupCalls.length > 1) {
      final service = _groupCalls.remove(source);
      if (service != null) {
        unawaited(
          service
              .end()
              .timeout(const Duration(seconds: 2), onTimeout: () {})
              .catchError((_) {}),
        );
      }
      final connected = {...call.connectedNodes}..remove(source);
      _setActiveCall(
        call.copyWith(
          connectedNodes: connected,
          quality: connected.isEmpty ? 1 : call.quality,
        ),
      );
      notifyListeners();
      if (_groupCalls.isNotEmpty) return;
    }
    _appendCallHistory(call, packet['reason']?.toString() ?? 'remote ended');
    _setActiveCall(
      call.copyWith(
        status: CallStatus.ended,
        endReason: packet['reason']?.toString() ?? 'remote ended',
      ),
    );
    notifyListeners();
    await _endCallMedia();
  }

  Future<void> _endCallMedia() async {
    await _calls
        .end()
        .timeout(const Duration(seconds: 2), onTimeout: () {})
        .catchError((_) {});
    final services = _groupCalls.values.toList();
    _groupCalls.clear();
    for (final service in services) {
      await service
          .end()
          .timeout(const Duration(seconds: 2), onTimeout: () {})
          .catchError((_) {});
    }
  }

  void _appendCallHistory(ActiveCall call, String reason) {
    final thread = _threadForCall(call);
    if (thread == null) return;
    final id = 'call-${call.callId}-$reason';
    if (thread.messages.any((message) => message.id == id)) return;
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: 'system',
        receiverNode: call.isGroup ? call.groupId : call.peer.nodeId,
        text: _callHistoryText(call, reason),
        createdAt: DateTime.now(),
        delivered: true,
      ),
    );
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    unawaited(_saveCache());
    notifyListeners();
  }

  ChatThread? _threadForCall(ActiveCall call) {
    if (call.isGroup) {
      return groups[call.groupId];
    }
    final existing = threads[call.peer.nodeId];
    if (existing != null) return existing;
    return _ensureThread(call.peer);
  }

  String _callHistoryText(ActiveCall call, String reason) {
    final duration = DateTime.now().difference(call.startedAt);
    final time = _formatShortDuration(duration);
    if (call.status == CallStatus.active) {
      return call.isGroup ? 'Group call ended · $time' : 'Call ended · $time';
    }
    if (reason == 'declined_by_me') return 'Call declined';
    if (reason == 'busy') return 'Call missed · busy';
    if (reason == 'declined') return 'Call declined';
    if (call.incoming && call.status == CallStatus.ringing) {
      return call.isGroup ? 'Missed group call' : 'Missed call';
    }
    return call.isGroup ? 'Group call canceled' : 'Call canceled';
  }

  String _formatShortDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _handleCallIce(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null) return;
    if (packet['call_id']?.toString() != call.callId) return;
    final raw = packet['candidate'];
    if (raw is! Map) return;
    final source = packet['source_node']?.toString() ?? '';
    if (call.isGroup && !call.incoming) {
      final service = _groupCalls[source];
      if (service == null) return;
      await service
          .addIceCandidate(Map<String, dynamic>.from(raw))
          .catchError((_) {});
      final current = activeCall;
      if (current != null && current.callId == call.callId) {
        _setActiveCall(
          current.copyWith(
            connectedNodes: {...current.connectedNodes, source},
            quality: current.status == CallStatus.active ? 2 : 1,
          ),
        );
        notifyListeners();
      }
      return;
    }
    await _calls
        .addIceCandidate(Map<String, dynamic>.from(raw))
        .catchError((_) {});
    final current = activeCall;
    if (current != null && current.callId == call.callId) {
      _setActiveCall(
        current.copyWith(
          connectedNodes: {...current.connectedNodes, source},
          quality: current.status == CallStatus.active ? 2 : 1,
        ),
      );
      notifyListeners();
    }
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
    if (isSavedMessagesProfile(recipient)) {
      thread.messages.add(
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: savedMessagesNodeId,
          text: trimmed,
          createdAt: DateTime.now(),
          replyToMessageId: replyTo?.id ?? '',
          replyToText: replyTo == null ? '' : _replyPreview(replyTo),
          delivered: true,
        ),
      );
      unawaited(_saveCache());
      notifyListeners();
      return;
    }
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
    if (!_socket.isConnected) {
      status = 'Queued: waiting for server connection';
      notifyListeners();
      return;
    }
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

  Future<String?> startBluetoothNearby() async {
    final current = session;
    if (current == null) return 'No active session';
    await _crypto.initialize(current.login, current.password);
    try {
      await ble.start(profile: ownProfile, publicKey: _crypto.publicKey);
      return null;
    } catch (error) {
      return 'Bluetooth start failed: $error';
    }
  }

  Future<void> stopBluetoothNearby() => ble.stop();

  Future<String?> sendBluetoothMessage(BlePeer peer, String text) async {
    final current = session;
    final trimmed = text.trim();
    if (current == null) return 'No active session';
    if (trimmed.isEmpty) return null;
    var connectedPeer = peer;
    try {
      connectedPeer = await ble.connect(peer);
    } catch (error) {
      return 'Bluetooth connect failed: $error';
    }
    if (connectedPeer.nodeId.isEmpty) {
      return 'Could not read MeshChat profile over Bluetooth';
    }
    if (connectedPeer.nodeId == myNodeId) return 'Cannot send to yourself';
    final recipient = Profile(
      nodeId: connectedPeer.nodeId,
      displayName: connectedPeer.displayName.isEmpty
          ? connectedPeer.name
          : connectedPeer.displayName,
      publicUsername: connectedPeer.publicUsername,
      publicKey: connectedPeer.publicKey,
      online: true,
    );
    profiles[recipient.nodeId] = _mergeProfile(recipient, online: true);
    final id = const Uuid().v4();
    final thread = _ensureThread(recipient);
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: recipient.nodeId,
        text: trimmed,
        createdAt: DateTime.now(),
        delivered: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();
    final wireText = await _crypto.encryptText(recipient.publicKey, trimmed);
    try {
      await ble.sendPacket(connectedPeer, {
        'type': 'chat_message',
        'packet_id': id,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': recipient.nodeId,
        'ttl': 1,
        'sender': current.login,
        'message': wireText,
      });
      return null;
    } catch (error) {
      _replaceMessage(id, (message) => message.copyWith(failed: true));
      return 'Bluetooth send failed: $error';
    }
  }

  Future<String?> sendBluetoothFile(
    BlePeer peer,
    String filename,
    Uint8List bytes, {
    String caption = '',
  }) async {
    final current = session;
    if (current == null) return 'No active session';
    if (bytes.isEmpty) return 'File is empty';
    if (bytes.length > maxBluetoothFileBytes) {
      return 'Bluetooth files are limited to 512 KB';
    }
    var connectedPeer = peer;
    try {
      connectedPeer = await ble.connect(peer);
    } catch (error) {
      return 'Bluetooth connect failed: $error';
    }
    if (connectedPeer.nodeId.isEmpty || connectedPeer.publicKey.isEmpty) {
      return 'Could not read MeshChat profile over Bluetooth';
    }
    if (connectedPeer.nodeId == myNodeId) return 'Cannot send to yourself';

    final recipient = Profile(
      nodeId: connectedPeer.nodeId,
      displayName: connectedPeer.displayName.isEmpty
          ? connectedPeer.name
          : connectedPeer.displayName,
      publicUsername: connectedPeer.publicUsername,
      publicKey: connectedPeer.publicKey,
      online: true,
    );
    profiles[recipient.nodeId] = _mergeProfile(recipient, online: true);

    final id = const Uuid().v4();
    final trimmedCaption = caption.trim();
    final data = _hexEncode(bytes);
    final thread = _ensureThread(recipient);
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: recipient.nodeId,
        text: trimmedCaption,
        createdAt: DateTime.now(),
        kind: ChatMessageKind.file,
        fileName: filename,
        fileData: data,
        fileSize: bytes.length,
        delivered: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();

    final totalChunks = (data.length / _bluetoothFileChunkHexSize).ceil();
    try {
      for (var index = 0; index < totalChunks; index++) {
        final start = index * _bluetoothFileChunkHexSize;
        final end = min(data.length, start + _bluetoothFileChunkHexSize);
        await ble.sendPacket(connectedPeer, {
          'type': 'file_chunk',
          'packet_id': const Uuid().v4(),
          'protocol_version': MeshSocket.protocolVersion,
          'source_node': myNodeId,
          'destination_node': recipient.nodeId,
          'ttl': 1,
          'sender': current.login,
          'file_id': id,
          'filename': filename,
          'caption': trimmedCaption,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      return null;
    } catch (error) {
      _replaceMessage(id, (message) => message.copyWith(failed: true));
      return 'Bluetooth file send failed: $error';
    }
  }

  Future<String?> sendFile(
    Profile recipient,
    String filename,
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
  }) async {
    if (session == null) return 'Нет активной сессии';
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) {
      return 'Файл больше 64 МБ';
    }

    final id = const Uuid().v4();
    final data = _hexEncode(bytes);
    final trimmedCaption = caption.trim();
    final thread = _ensureThread(recipient);
    if (isSavedMessagesProfile(recipient)) {
      thread.messages.add(
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: savedMessagesNodeId,
          text: trimmedCaption,
          createdAt: DateTime.now(),
          kind: ChatMessageKind.file,
          fileName: filename,
          fileData: data,
          fileSize: bytes.length,
          replyToMessageId: replyTo?.id ?? '',
          replyToText: replyTo == null ? '' : _replyPreview(replyTo),
          delivered: true,
          progress: 1,
        ),
      );
      unawaited(_saveCache());
      notifyListeners();
      return null;
    }
    thread.messages.add(
      ChatMessage(
        id: id,
        senderNode: myNodeId,
        receiverNode: recipient.nodeId,
        text: trimmedCaption,
        createdAt: DateTime.now(),
        kind: ChatMessageKind.file,
        fileName: filename,
        fileData: _hexEncode(bytes),
        fileSize: bytes.length,
        replyToMessageId: replyTo?.id ?? '',
        replyToText: replyTo == null ? '' : _replyPreview(replyTo),
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();
    if (!_socket.isConnected) {
      status = 'Queued: waiting for server connection';
      notifyListeners();
      return null;
    }

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
        'caption': trimmedCaption,
        'reply_to_message_id': replyTo?.id ?? '',
        'reply_to_text': replyTo == null ? '' : _replyPreview(replyTo),
        'chunk_index': index,
        'total_chunks': totalChunks,
        'data': data.substring(start, end),
      });
      _replaceMessage(
        id,
        (message) => message.copyWith(progress: (index + 1) / totalChunks),
      );
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    _replaceMessage(
      id,
      (message) => message.copyWith(pending: false, progress: 1),
    );
    return null;
  }

  Future<String?> forwardMessage(ChatMessage message, ChatThread target) async {
    if (session == null) return 'No active session';
    if (message.deleted) return 'Message was deleted';
    if (message.kind == ChatMessageKind.file) {
      if (message.fileData.isEmpty) return 'File is not cached';
      final filename = message.fileName.isEmpty
          ? 'meshchat_file'
          : message.fileName;
      final bytes = _hexDecode(message.fileData);
      return target.isGroup
          ? sendGroupFile(target, filename, bytes, caption: message.text)
          : sendFile(target.profile, filename, bytes, caption: message.text);
    }
    final text = message.text.trim();
    if (text.isEmpty) return 'Message is empty';
    if (target.isGroup) {
      await sendGroupMessage(target, text);
    } else {
      await sendMessage(target.profile, text);
    }
    return null;
  }

  Future<String?> saveMessageToSaved(ChatMessage message) async {
    if (session == null) return 'No active session';
    if (message.deleted) return 'Message was deleted';
    final target = ensureSavedMessagesThread();
    if (message.kind == ChatMessageKind.file) {
      if (message.fileData.isEmpty) return 'File is not cached';
      final filename = message.fileName.isEmpty
          ? 'meshchat_file'
          : message.fileName;
      final bytes = _hexDecode(message.fileData);
      return sendFile(target.profile, filename, bytes, caption: message.text);
    }
    final text = message.text.trim();
    if (text.isEmpty) return 'Message is empty';
    await sendMessage(target.profile, text);
    return null;
  }

  Future<String?> retryMessage(ChatThread thread, ChatMessage message) async {
    if (!message.failed && !message.pending) return null;
    _deleteLocalMessage(thread, message.id);
    if (message.kind == ChatMessageKind.file) {
      if (message.fileData.isEmpty) return 'File is not cached';
      final bytes = _hexDecode(message.fileData);
      final filename = message.fileName.isEmpty
          ? message.text
          : message.fileName;
      return thread.isGroup
          ? sendGroupFile(thread, filename, bytes, caption: message.text)
          : sendFile(thread.profile, filename, bytes, caption: message.text);
    }
    if (thread.isGroup) {
      await sendGroupMessage(thread, message.text);
    } else {
      await sendMessage(thread.profile, message.text);
    }
    return null;
  }

  Future<void> _retryQueuedMessages() async {
    if (_retryingQueuedMessages || session == null || !_socket.isConnected) {
      return;
    }
    _retryingQueuedMessages = true;
    try {
      final queued = <({ChatThread thread, ChatMessage message})>[];
      for (final thread in [...threads.values, ...groups.values]) {
        for (final message in thread.messages) {
          if (message.senderNode != myNodeId) continue;
          if (!message.pending && !message.failed) continue;
          if (message.deleted) continue;
          queued.add((thread: thread, message: message));
        }
      }
      if (queued.isEmpty) return;
      addDiagnostic('sync', 'Retrying ${queued.length} queued messages');
      for (final item in queued) {
        if (!_socket.isConnected) break;
        await retryMessage(item.thread, item.message);
      }
      await _saveCache();
      notifyListeners();
    } finally {
      _retryingQueuedMessages = false;
    }
  }

  Future<ChatThread?> createGroup({
    required String name,
    required List<Profile> members,
    bool isChannel = false,
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
      isChannel: isChannel,
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

  Future<String?> requestGroupJoinFromInvite(String rawLink) async {
    final current = session;
    if (current == null) return 'No active session';
    final invite = _decodeGroupInvite(rawLink);
    if (invite == null) return 'Invite link is not valid';
    final groupId = invite['group_id']?.toString() ?? '';
    final ownerNode = invite['owner_node']?.toString() ?? '';
    if (groupId.isEmpty || ownerNode.isEmpty) return 'Invite is incomplete';
    if (groups.containsKey(groupId)) return 'You are already in this chat';
    if (ownerNode == myNodeId) return 'This is your own invite';
    _socket.send({
      'type': 'group_join_request',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': ownerNode,
      'ttl': 5,
      'sender': current.login,
      'group_id': groupId,
      'group_name': invite['name']?.toString() ?? 'Group',
      'is_channel': invite['is_channel'] == true,
      'requester_profile': ownProfile.toJson(),
    });
    return null;
  }

  Map<String, dynamic>? _decodeGroupInvite(String rawLink) {
    final trimmed = rawLink.trim();
    if (trimmed.isEmpty) return null;
    try {
      final uri = Uri.parse(trimmed);
      String payload = '';
      if (uri.scheme == 'meshchat' && uri.host == 'group') {
        payload = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
      } else if (trimmed.startsWith('meshchat://group/')) {
        payload = trimmed.substring('meshchat://group/'.length);
      }
      if (payload.isEmpty) return null;
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded);
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
    return null;
  }

  void _handleGroupJoinRequest(Map<String, dynamic> packet) {
    final groupId = packet['group_id']?.toString() ?? '';
    final requesterNode = packet['source_node']?.toString() ?? '';
    final group = groups[groupId];
    if (group == null || requesterNode.isEmpty) return;
    final ownerOrAdmin =
        group.ownerNode == myNodeId ||
        group.admins.contains(myNodeId) ||
        (group.ownerNode.isEmpty && group.members.contains(myNodeId));
    if (!ownerOrAdmin || group.members.contains(requesterNode)) return;
    final profileRaw = packet['requester_profile'];
    final profile = profileRaw is Map
        ? Profile.fromJson(Map<String, dynamic>.from(profileRaw))
        : Profile(
            nodeId: requesterNode,
            displayName: packet['sender']?.toString() ?? requesterNode,
          );
    profiles[profile.nodeId] = _mergeProfile(profile);
    groupJoinRequests.removeWhere(
      (request) =>
          request.groupId == groupId &&
          request.requester.nodeId == requesterNode,
    );
    groupJoinRequests.insert(
      0,
      GroupJoinRequest(
        id: packet['packet_id']?.toString() ?? const Uuid().v4(),
        groupId: groupId,
        groupName: packet['group_name']?.toString().isNotEmpty == true
            ? packet['group_name'].toString()
            : group.profile.displayName,
        isChannel: packet['is_channel'] == true || group.isChannel,
        requester: profile,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<String?> acceptGroupJoinRequest(GroupJoinRequest request) async {
    final group = groups[request.groupId];
    if (group == null) return 'Group is not available';
    final error = await updateGroupMembers(group, [
      ...group.members,
      request.requester.nodeId,
    ], rotateKey: true);
    if (error != null) return error;
    groupJoinRequests.removeWhere((item) => item.id == request.id);
    _socket.send({
      'type': 'group_join_response',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': request.requester.nodeId,
      'ttl': 5,
      'group_id': request.groupId,
      'group_name': group.profile.displayName,
      'accepted': true,
    });
    notifyListeners();
    return null;
  }

  void declineGroupJoinRequest(GroupJoinRequest request) {
    groupJoinRequests.removeWhere((item) => item.id == request.id);
    _socket.send({
      'type': 'group_join_response',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': request.requester.nodeId,
      'ttl': 5,
      'group_id': request.groupId,
      'group_name': request.groupName,
      'accepted': false,
    });
    notifyListeners();
  }

  void _handleGroupJoinResponse(Map<String, dynamic> packet) {
    final accepted = packet['accepted'] == true;
    final groupName = packet['group_name']?.toString() ?? 'Group';
    addDiagnostic(
      'groups',
      accepted ? 'Join accepted: $groupName' : 'Join declined: $groupName',
    );
  }

  bool _canPostToChannel(ChatThread group) {
    if (!group.isChannel) return true;
    return group.ownerNode == myNodeId ||
        group.admins.contains(myNodeId) ||
        (group.ownerNode.isEmpty && group.admins.isEmpty);
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

  Future<String?> updateGroupProfile(
    ChatThread group, {
    required String name,
    required String about,
    required String avatarData,
  }) async {
    if (session == null) return 'No active session';
    if (!group.isGroup) return 'This is not a group';
    final isOwner =
        group.ownerNode.isEmpty ||
        group.ownerNode == myNodeId ||
        group.admins.contains(myNodeId);
    if (!isOwner) return 'Only admins can edit group info';
    final displayName = name.trim();
    if (displayName.isEmpty) return 'Group name is empty';
    group.profile = group.profile.copyWith(
      displayName: displayName,
      about: about.trim(),
      avatarData: avatarData,
    );
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
    final groupName = group.profile.displayName.trim().isEmpty
        ? group.groupName
        : group.profile.displayName;
    final basePacket = {
      'type': 'group_update',
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': group.groupId,
      'group_name': groupName,
      'group_about': group.profile.about,
      'group_avatar_data': group.profile.avatarData,
      'is_channel': group.isChannel,
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
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
  }) async {
    if (session == null) return 'Нет активной сессии';
    if (!group.isGroup) return 'Это не группа';
    if (group.isChannel && !_canPostToChannel(group)) {
      return 'Only channel admins can post';
    }
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) return 'Файл больше 64 МБ';

    final id = const Uuid().v4();
    final groupKey = _getOrCreateGroupKey(group.groupId);
    final trimmedCaption = caption.trim();
    final wireFilename = await _crypto.encryptGroupText(groupKey.key, filename);
    final wireCaption = trimmedCaption.isEmpty
        ? ''
        : await _crypto.encryptGroupText(groupKey.key, trimmedCaption);
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
        text: trimmedCaption,
        createdAt: DateTime.now(),
        kind: ChatMessageKind.file,
        fileName: filename,
        fileData: _hexEncode(bytes),
        fileSize: bytes.length,
        replyToMessageId: replyTo?.id ?? '',
        replyToText: replyTo == null ? '' : _replyPreview(replyTo),
        pending: true,
      ),
    );
    unawaited(_saveCache());
    notifyListeners();
    if (!_socket.isConnected) {
      status = 'Queued: waiting for server connection';
      notifyListeners();
      return null;
    }

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
          'caption': wireCaption,
          'reply_to_message_id': replyTo?.id ?? '',
          'reply_to_text': replyTo == null ? '' : _replyPreview(replyTo),
          'group_id': group.groupId,
          'group_name': group.groupName.isEmpty
              ? group.profile.displayName
              : group.groupName,
          'is_channel': group.isChannel,
          'group_key_id': groupKey.id,
          'group_key_envelope': envelope,
          'group_key_sender_envelope': senderEnvelope,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
        });
        _replaceMessage(
          id,
          (message) => message.copyWith(progress: (index + 1) / totalChunks),
        );
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
          'caption': wireCaption,
          'reply_to_message_id': replyTo?.id ?? '',
          'reply_to_text': replyTo == null ? '' : _replyPreview(replyTo),
          'group_id': group.groupId,
          'group_name': group.groupName.isEmpty
              ? group.profile.displayName
              : group.groupName,
          'is_channel': group.isChannel,
          'group_key_id': groupKey.id,
          'group_key_envelope': senderEnvelope,
          'group_key_sender_envelope': senderEnvelope,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
        });
        _replaceMessage(
          id,
          (message) => message.copyWith(progress: (index + 1) / totalChunks),
        );
      }
    }
    _replaceMessage(
      id,
      (message) => message.copyWith(pending: false, progress: 1),
    );
    return null;
  }

  Future<void> _receiveMessage(Map<String, dynamic> packet) async {
    final sender = packet['source_node']?.toString() ?? '';
    if (sender.isEmpty) return;
    if (isBlocked(sender)) return;
    final profile =
        profiles[sender] ??
        Profile(
          nodeId: sender,
          displayName: packet['sender']?.toString() ?? sender.substring(0, 8),
        );
    profiles[sender] = profile;
    final thread = _ensureThread(profile);
    final id =
        packet['message_id']?.toString() ??
        packet['packet_id']?.toString() ??
        const Uuid().v4();
    if (_isDeletedMessage(id)) return;
    if (!thread.messages.any((message) => message.id == id)) {
      final text = await _crypto.decryptText(
        packet['message']?.toString() ?? '',
      );
      final message = ChatMessage(
        id: id,
        senderNode: sender,
        receiverNode: myNodeId,
        text: text,
        createdAt: DateTime.now(),
        replyToMessageId: packet['reply_to_message_id']?.toString() ?? '',
        replyToText: packet['reply_to_text']?.toString() ?? '',
        delivered: true,
      );
      thread.messages.add(message);
      final active = _isThreadActive(thread);
      if (active) {
        thread.unread = 0;
      } else {
        thread.unread++;
      }
      if (!active && !thread.muted) {
        unawaited(_showNotification(title: profile.displayName, body: text));
      }
      _publishIncomingPreview(thread, message);
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
    if (_isDeletedMessage(fileId)) return;
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
      if (appSettings.deletedGroupIds.contains(groupId)) {
        _incomingFiles.remove(fileId);
        return;
      }
      final group = _ensureGroupThread(
        groupId: groupId,
        groupName: first['group_name']?.toString() ?? 'Группа',
        isChannel: first['is_channel'] == true,
      );
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
      if (isBlocked(sender)) {
        _incomingFiles.remove(fileId);
        return;
      }
      final fullData = List<String>.generate(
        incoming.totalChunks,
        (index) => incoming.chunks[index] ?? '',
      ).join();
      final decryptedName = await _crypto.decryptGroupText(
        _groupKeys[groupId]?.key,
        filename,
      );
      final decryptedCaption = await _crypto.decryptGroupText(
        _groupKeys[groupId]?.key,
        first['caption']?.toString() ?? '',
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
      final message = ChatMessage(
        id: fileId,
        senderNode: sender,
        receiverNode: groupId,
        text: decryptedCaption,
        createdAt: _parsePacketDate(first),
        kind: ChatMessageKind.file,
        fileName: decryptedName,
        fileData: decryptedData,
        fileSize: decryptedData.length ~/ 2,
        replyToMessageId: first['reply_to_message_id']?.toString() ?? '',
        replyToText: first['reply_to_text']?.toString() ?? '',
        delivered: true,
      );
      final inserted = _upsertFileMessage(group, message);
      if (inserted && !fromSync && sender != myNodeId) {
        final active = _isThreadActive(group);
        if (active) {
          group.unread = 0;
        } else {
          group.unread++;
        }
        if (!active && !group.muted) {
          unawaited(
            _showNotification(
              title: group.profile.displayName,
              body: _fileNotificationBody(decryptedName),
            ),
          );
        }
        _publishIncomingPreview(group, message);
      }
      await _saveCache();
      notifyListeners();
      _incomingFiles.remove(fileId);
      return;
    }

    final sender = first['sender_node']?.toString().isNotEmpty == true
        ? first['sender_node'].toString()
        : first['source_node']?.toString() ?? '';
    if (isBlocked(sender)) {
      _incomingFiles.remove(fileId);
      return;
    }
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
    final fullData = List<String>.generate(
      incoming.totalChunks,
      (index) => incoming.chunks[index] ?? '',
    ).join();
    final message = ChatMessage(
      id: fileId,
      senderNode: sentByMe ? myNodeId : sender,
      receiverNode: receiver,
      text: first['caption']?.toString() ?? '',
      createdAt: _parsePacketDate(first),
      kind: ChatMessageKind.file,
      fileName: filename,
      fileData: fullData,
      fileSize: fullData.length ~/ 2,
      replyToMessageId: first['reply_to_message_id']?.toString() ?? '',
      replyToText: first['reply_to_text']?.toString() ?? '',
      delivered: true,
    );
    final inserted = _upsertFileMessage(thread, message);
    if (inserted && !fromSync && sender != myNodeId) {
      final active = _isThreadActive(thread);
      if (active) {
        thread.unread = 0;
      } else {
        thread.unread++;
      }
      if (!active && !thread.muted) {
        unawaited(
          _showNotification(
            title: profile.displayName,
            body: _fileNotificationBody(filename),
          ),
        );
      }
      _publishIncomingPreview(thread, message);
    }
    await _saveCache();
    notifyListeners();
    _incomingFiles.remove(fileId);
  }

  bool _upsertFileMessage(ChatThread thread, ChatMessage incoming) {
    final index = thread.messages.indexWhere(
      (message) => message.id == incoming.id,
    );
    if (index < 0) {
      thread.messages.add(incoming);
      thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return true;
    }
    final current = thread.messages[index];
    final shouldUpgrade =
        current.kind != ChatMessageKind.file ||
        current.fileData.isEmpty ||
        current.fileName.isEmpty ||
        current.fileSize <= 0;
    if (!shouldUpgrade) return false;
    final shouldReplaceText =
        incoming.text.isNotEmpty &&
        (current.text.isEmpty ||
            current.text.startsWith(MeshCrypto.groupPrefix) ||
            current.text.startsWith('['));
    final shouldReplaceName =
        incoming.fileName.isNotEmpty &&
        (current.fileName.isEmpty ||
            current.fileName.startsWith(MeshCrypto.groupPrefix) ||
            current.fileData.isEmpty);
    thread.messages[index] = current.copyWith(
      kind: ChatMessageKind.file,
      text: shouldReplaceText ? incoming.text : current.text,
      fileName: shouldReplaceName ? incoming.fileName : current.fileName,
      fileData: incoming.fileData.isNotEmpty
          ? incoming.fileData
          : current.fileData,
      fileSize: incoming.fileSize > 0 ? incoming.fileSize : current.fileSize,
      delivered: true,
      pending: false,
      failed: false,
      progress: 1,
    );
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return false;
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

  Future<void> _showCallNotification({
    required String title,
    required String body,
  }) async {
    if (!appSettings.notificationsEnabled) return;
    await _notifications.showCall(
      title: title,
      body: appSettings.notificationPreview ? body : 'Incoming call',
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
      final raw = value.toString().trim();
      final parsed = _parseWireDate(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  DateTime? _parseWireDate(String raw) {
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    final hasExplicitZone =
        raw.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(raw);
    final looksLikeSqlUtc =
        raw.contains(' ') && !raw.contains('T') && !hasExplicitZone;
    if (looksLikeSqlUtc) {
      return DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
        parsed.microsecond,
      );
    }
    return parsed;
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
    if (!appSettings.notificationsEnabled && settings.notificationsEnabled) {
      unawaited(requestNotificationPermissions());
    } else if (appSettings.notificationsEnabled &&
        !settings.notificationsEnabled) {
      unawaited(_unsubscribeWebPush());
    }
    appSettings = settings;
    await _settingsStore.save(settings);
    notifyListeners();
  }

  void _setActiveCall(ActiveCall? call) {
    activeCall = call;
    unawaited(
      _proximityScreen.setEnabled(
        call != null && call.status != CallStatus.ended,
      ),
    );
    if (call == null || call.status == CallStatus.ended) {
      _callTicker?.cancel();
      _callTicker = null;
    } else {
      _callTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        final current = activeCall;
        if (current == null || current.status == CallStatus.ended) {
          _callTicker?.cancel();
          _callTicker = null;
          return;
        }
        notifyListeners();
      });
    }
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
    await ble.stop();
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
    groupJoinRequests.clear();
    stories.clear();
    typingUntil.clear();
    activityKinds.clear();
    _incomingFiles.clear();
    _incomingPreviewTimer?.cancel();
    _incomingPreviewTimer = null;
    incomingPreviewThread = null;
    incomingPreviewMessage = null;
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

  Future<void> _rewriteCache() async {
    try {
      await _cache.clear(session);
      await _cache.save(session, [...threads.values, ...groups.values]);
    } catch (_) {
      // Keep the in-memory state even if local storage is temporarily unhappy.
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
    _callTicker?.cancel();
    unawaited(_proximityScreen.dispose());
    ble.removeListener(_handleBluetoothStateChanged);
    ble.dispose();
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

class GroupJoinRequest {
  const GroupJoinRequest({
    required this.id,
    required this.groupId,
    required this.groupName,
    required this.isChannel,
    required this.requester,
    required this.createdAt,
  });

  final String id;
  final String groupId;
  final String groupName;
  final bool isChannel;
  final Profile requester;
  final DateTime createdAt;
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
