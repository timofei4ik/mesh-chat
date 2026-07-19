import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/app_settings.dart';
import '../models/meshpro_subscription.dart';
import '../models/profile.dart';
import '../models/scheduled_message.dart';
import '../models/session.dart';
import '../models/sticker_pack.dart';
import '../models/story_item.dart';
import '../services/app_settings_store.dart';
import '../services/ble_chat_service.dart';
import '../services/call_alert_service.dart';
import '../services/call_service.dart';
import '../services/chat_cache_store.dart';
import '../services/mesh_crypto.dart';
import '../services/mesh_socket.dart';
import '../services/notification_service.dart';
import '../services/own_profile_store.dart';
import '../services/proximity_screen_service.dart';
import '../services/session_store.dart';
import '../services/sticker_store.dart';
import '../services/story_store.dart';
import '../services/sync_cursor_store.dart';
import '../services/sync_delta_buffer.dart';

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

class AiRewriteResult {
  const AiRewriteResult({required this.text, required this.remaining});

  final String text;
  final int remaining;
}

class AiTranslationResult {
  const AiTranslationResult({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.remaining,
  });

  final String text;
  final String sourceLanguage;
  final String targetLanguage;
  final int remaining;
}

class AiSummaryResult {
  const AiSummaryResult({required this.text, required this.remaining});

  final String text;
  final int remaining;
}

class AiTranscriptionResult {
  const AiTranscriptionResult({
    required this.text,
    required this.language,
    required this.durationSeconds,
    required this.remainingMinutes,
  });

  final String text;
  final String language;
  final double durationSeconds;
  final int remainingMinutes;
}

class AiOcrResult {
  const AiOcrResult({
    required this.text,
    required this.language,
    required this.processed,
    required this.remaining,
  });

  final String text;
  final String language;
  final bool processed;
  final int remaining;
}

class AiSmartRepliesResult {
  const AiSmartRepliesResult({required this.replies, required this.remaining});

  final List<String> replies;
  final int remaining;
}

class AiPersonMemoryResult {
  const AiPersonMemoryResult({required this.text, required this.remaining});

  final String text;
  final int remaining;
}

class AiRewriteException implements Exception {
  const AiRewriteException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiTranslationException implements Exception {
  const AiTranslationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiSummaryException implements Exception {
  const AiSummaryException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiTranscriptionException implements Exception {
  const AiTranscriptionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiOcrException implements Exception {
  const AiOcrException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiSmartRepliesException implements Exception {
  const AiSmartRepliesException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AiPersonMemoryException implements Exception {
  const AiPersonMemoryException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
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
    this.hdAudio = false,
    this.enhancedNoiseSuppression = false,
    this.screenSharing = false,
    this.remoteScreenSharing = false,
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
  final bool hdAudio;
  final bool enhancedNoiseSuppression;
  final bool screenSharing;
  final bool remoteScreenSharing;

  ActiveCall copyWith({
    CallStatus? status,
    String? endReason,
    bool? localMuted,
    Set<String>? connectedNodes,
    bool? speakerOn,
    bool? collapsed,
    int? quality,
    bool? screenSharing,
    bool? remoteScreenSharing,
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
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
      screenSharing: screenSharing ?? this.screenSharing,
      remoteScreenSharing: remoteScreenSharing ?? this.remoteScreenSharing,
    );
  }
}

class AppController extends ChangeNotifier {
  static const maxMobileFileBytes = 64 * 1024 * 1024;
  static const maxBluetoothFileBytes = 512 * 1024;
  static const _bluetoothFileChunkHexSize = 8 * 1024;
  static const _maxProfilePacketBytes = 900 * 1024;

  final SessionStore _store = SessionStore();
  final AppSettingsStore _settingsStore = AppSettingsStore();
  final ChatCacheStore _cache = ChatCacheStore();
  final StoryStore _storyStore = StoryStore();
  final StickerStore _stickerStore = StickerStore();
  final SyncCursorStore _syncCursorStore = SyncCursorStore();
  final SyncDeltaBuffer _syncDeltaBuffer = SyncDeltaBuffer();
  final MeshSocket _socket = MeshSocket();
  final MeshCrypto _crypto = MeshCrypto();
  final BleChatService ble = BleChatService();
  final CallService _calls = CallService();
  final Map<String, CallService> _groupCalls = {};
  final NotificationService _notifications = NotificationService();
  final OwnProfileStore _ownProfileStore = OwnProfileStore();
  final ProximityScreenService _proximityScreen = ProximityScreenService();
  final Map<String, Profile> profiles = {};
  final Map<String, ChatThread> threads = {};
  final Map<String, ChatThread> groups = {};
  final Map<String, StoryItem> stories = {};
  final List<StoryItem> storyArchive = [];
  final List<ScheduledMessageItem> scheduledMessages = [];
  final Set<String> hiddenStoryOwners = {};
  final Map<String, DateTime> typingUntil = {};
  final Map<String, String> activityKinds = {};
  StickerLibrary stickerLibrary = const StickerLibrary();
  MeshProSubscription meshProSubscription =
      const MeshProSubscription.inactive();

  Session? session;
  List<Session> recentSessions = [];
  AppSettings appSettings = const AppSettings();
  ActiveCall? activeCall;
  List<CallAudioDevice> callAudioInputs = const [];
  List<CallAudioDevice> callAudioOutputs = const [];
  bool initialized = false;
  bool busy = false;
  String status = 'Offline';
  DateTime? lastSyncAt;
  String? error;
  Completer<Profile?>? _lookupCompleter;
  Completer<MeshProSubscription>? _meshProCompleter;
  final Map<String, Completer<AiRewriteResult>> _aiRewriteCompleters = {};
  final Map<String, Completer<AiTranslationResult>> _aiTranslationCompleters =
      {};
  final Map<String, Completer<AiSummaryResult>> _aiSummaryCompleters = {};
  final Map<String, Completer<AiTranscriptionResult>>
  _aiTranscriptionCompleters = {};
  final Map<String, Completer<AiOcrResult>> _aiOcrCompleters = {};
  final Map<String, Completer<AiSmartRepliesResult>> _aiSmartRepliesCompleters =
      {};
  final Map<String, Completer<AiPersonMemoryResult>> _aiPersonMemoryCompleters =
      {};
  final Map<String, Completer<String?>> _scheduledMessageCompleters = {};
  final Map<String, Completer<String?>> _chatPreferenceCompleters = {};
  bool _lookupSendRequest = true;
  Completer<String?>? _profileUpdateCompleter;
  Completer<List<ActiveDevice>>? _activeDevicesCompleter;
  final Map<String, Completer<String?>> _activeDeviceActionCompleters = {};
  final Map<String, Completer<String?>> _meshProPreferenceCompleters = {};
  final Map<String, Completer<String?>> _passwordChangeCompleters = {};
  String _webPushVapidPublicKey = '';
  String _activeThreadKey = '';
  Timer? _callTicker;
  Timer? _softResyncTimer;
  final Map<int, String> _stickerLibrarySyncChunks = {};
  int _stickerLibrarySyncTotal = 0;
  bool _webPushSubscribeInFlight = false;
  String _androidPushToken = '';
  String _androidPushSubscribedToken = '';
  bool _retryingQueuedMessages = false;
  final Set<String> _resendingMessageIds = {};
  bool _ownProfileHydrated = false;
  int _lastAppliedSyncCursor = 0;
  bool _applyingSyncDelta = false;
  final List<Map<String, dynamic>> _livePacketsDuringDeltaApply = [];
  Timer? _incomingPreviewTimer;
  final List<DiagnosticEvent> diagnostics = [];
  final List<GroupJoinRequest> groupJoinRequests = [];
  final Map<String, _IncomingFile> _incomingFiles = {};
  final Map<String, _GroupKey> _groupKeys = {};
  final Map<String, Map<String, _GroupKey>> _groupKeyHistory = {};
  final Map<String, Map<String, Set<String>>> _reactionActors = {};
  ChatThread? incomingPreviewThread;
  ChatMessage? incomingPreviewMessage;
  int incomingPreviewVersion = 0;

  AppController() {
    _notifications.onAndroidPushToken = _handleAndroidPushToken;
    ble.onPacket = _handleBluetoothPacket;
    ble.addListener(_handleBluetoothStateChanged);
    _calls.onRemoteScreenChanged = _handleRemoteScreenChanged;
    _calls.onLocalScreenEnded = _handleLocalScreenEnded;
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
  List<StickerPack> get stickerPacks => stickerLibrary.packs;
  List<StickerItem> get favoriteStickers => stickerLibrary.favorites;
  List<StickerItem> get allStickers => stickerLibrary.allStickers;

  Future<void> createStickerPack(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || session == null) return;
    final pack = StickerPack(id: const Uuid().v4(), name: trimmed);
    stickerLibrary = stickerLibrary.copyWith(
      packs: [...stickerLibrary.packs, pack],
    );
    await _saveStickers();
    notifyListeners();
  }

  Future<void> addSticker({
    required String packId,
    required String fileName,
    required Uint8List bytes,
    String name = '',
  }) async {
    if (session == null || bytes.isEmpty) return;
    final packIndex = stickerLibrary.packs.indexWhere(
      (pack) => pack.id == packId,
    );
    if (packIndex < 0) return;
    final extension = fileName.split('.').last.toLowerCase();
    final item = StickerItem(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? _stickerDisplayName(fileName) : name.trim(),
      fileName: fileName.trim().isEmpty
          ? 'sticker_${DateTime.now().millisecondsSinceEpoch}.webp'
          : fileName.trim(),
      mimeType: _stickerMimeType(extension),
      base64Data: base64Encode(bytes),
      animated: extension == 'gif' || extension == 'webp',
    );
    final packs = [...stickerLibrary.packs];
    packs[packIndex] = packs[packIndex].copyWith(
      stickers: [...packs[packIndex].stickers, item],
    );
    stickerLibrary = stickerLibrary.copyWith(packs: packs);
    await _saveStickers();
    notifyListeners();
  }

  Future<void> toggleFavoriteSticker(String stickerId) async {
    if (session == null || stickerId.isEmpty) return;
    final favorites = {...stickerLibrary.favoriteIds};
    if (!favorites.remove(stickerId)) favorites.add(stickerId);
    stickerLibrary = stickerLibrary.copyWith(favoriteIds: favorites);
    await _saveStickers();
    notifyListeners();
  }

  Future<String?> saveStickerFromMessage(
    ChatMessage message, {
    required bool favorite,
  }) async {
    if (session == null) return 'No active session';
    if (message.kind != ChatMessageKind.sticker || message.fileData.isEmpty) {
      return 'Sticker is not cached';
    }
    late final Uint8List bytes;
    try {
      bytes = _hexDecode(message.fileData);
    } catch (_) {
      return 'Sticker is damaged';
    }
    if (bytes.isEmpty) return 'Sticker is empty';

    final base64Data = base64Encode(bytes);
    StickerItem? existing;
    for (final item in stickerLibrary.allStickers) {
      if (item.base64Data == base64Data) {
        existing = item;
        break;
      }
    }

    var packs = [...stickerLibrary.packs];
    var favoriteIds = {...stickerLibrary.favoriteIds};
    var savedSticker = existing;

    if (savedSticker == null) {
      const savedPackName = 'Saved stickers';
      var packIndex = packs.indexWhere((pack) => pack.name == savedPackName);
      if (packIndex < 0) {
        packs = [
          ...packs,
          StickerPack(id: const Uuid().v4(), name: savedPackName),
        ];
        packIndex = packs.length - 1;
      }
      final fileName = message.fileName.trim().isEmpty
          ? 'sticker_${DateTime.now().millisecondsSinceEpoch}.webp'
          : message.fileName.trim();
      final extension = fileName.split('.').last.toLowerCase();
      savedSticker = StickerItem(
        id: const Uuid().v4(),
        name: message.text.trim().isEmpty
            ? _stickerDisplayName(fileName)
            : message.text.trim(),
        fileName: fileName,
        mimeType: _stickerMimeType(extension),
        base64Data: base64Data,
        animated: extension == 'gif' || extension == 'webp',
      );
      packs[packIndex] = packs[packIndex].copyWith(
        stickers: [...packs[packIndex].stickers, savedSticker],
      );
    }

    if (favorite) {
      favoriteIds.add(savedSticker.id);
    }
    stickerLibrary = stickerLibrary.copyWith(
      packs: packs,
      favoriteIds: favoriteIds,
    );
    await _saveStickers();
    notifyListeners();
    return null;
  }

  Future<String?> sendSticker(
    ChatThread thread,
    StickerItem sticker, {
    ChatMessage? replyTo,
  }) async {
    final caption = sticker.name.trim();
    if (thread.isBluetooth) {
      return sendBluetoothFileToThread(
        thread,
        sticker.fileName,
        sticker.bytes,
        caption: caption,
        replyTo: replyTo,
        kind: ChatMessageKind.sticker,
      );
    }
    if (thread.isGroup) {
      return sendGroupFile(
        thread,
        sticker.fileName,
        sticker.bytes,
        caption: caption,
        replyTo: replyTo,
        kind: ChatMessageKind.sticker,
      );
    }
    return sendFile(
      thread.profile,
      sticker.fileName,
      sticker.bytes,
      caption: caption,
      replyTo: replyTo,
      threadOverride: thread,
      kind: ChatMessageKind.sticker,
    );
  }

  Future<void> _saveStickers({bool publish = true}) async {
    await _stickerStore.save(session, stickerLibrary);
    if (publish) unawaited(_publishStickerLibrary());
  }

  Future<void> _publishStickerLibrary() async {
    final current = session;
    if (current == null || !_socket.isConnected) return;
    _socket.send({
      'type': 'sticker_library_update',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'login': current.login,
      'sticker_library': stickerLibrary.toJson(),
    });
  }

  String _stickerDisplayName(String fileName) {
    final clean = fileName.trim();
    if (clean.isEmpty) return 'Sticker';
    final dot = clean.lastIndexOf('.');
    return dot <= 0 ? clean : clean.substring(0, dot);
  }

  String _stickerMimeType(String extension) {
    return switch (extension) {
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'image/png',
    };
  }

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
          accountLogin: current.login,
          nodeAliases: [current.nodeId],
          publicUsername: current.publicUsername,
          publicKey: _crypto.publicKey,
          online: status == 'Online' || status.startsWith('Online:'),
        );
    return profile.copyWith(
      accountLogin: current.login,
      nodeAliases: <String>{...profile.nodeAliases, current.nodeId}.toList(),
      publicUsername: profile.publicUsername.trim().isEmpty
          ? current.publicUsername
          : null,
      publicKey: profile.publicKey.isEmpty ? _crypto.publicKey : null,
      online: status == 'Online' || status.startsWith('Online:'),
      meshProBadge:
          meshProSubscription.isActiveNow &&
          meshProSubscription.entitlements.hasFeature('premium_badge'),
      profileBackground:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('profile_background')
          ? profile.profileBackground ?? Profile.defaultBackground
          : Profile.defaultBackground,
      profileEffect:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('profile_effect')
          ? profile.profileEffect ?? Profile.defaultEffect
          : Profile.defaultEffect,
      profileBlinkShape:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('profile_effect')
          ? profile.profileBlinkShape ?? Profile.defaultBlinkShape
          : Profile.defaultBlinkShape,
      avatarDecoration:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('animated_avatar')
          ? profile.avatarDecoration ?? Profile.defaultAvatarDecoration
          : Profile.defaultAvatarDecoration,
      profileGlow:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('profile_glow')
          ? profile.profileGlow ?? false
          : false,
      profileAccent:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('custom_accent')
          ? profile.profileAccent ?? Profile.defaultAccent
          : Profile.defaultAccent,
      emojiStatus:
          meshProSubscription.isActiveNow &&
              meshProSubscription.entitlements.hasFeature('emoji_status')
          ? profile.emojiStatus
          : '',
    );
  }

  Profile get _publicOwnProfile {
    final profile = ownProfile;
    return profile.copyWith(
      about: appSettings.showAbout ? profile.about : '',
      avatarData: appSettings.showAvatar ? profile.avatarData : '',
      online: appSettings.showOnline && profile.online,
    );
  }

  String get _outgoingMessageEffect => _publicOwnProfile.effectiveMessageEffect;

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
      accountLogin: incoming.accountLogin.trim().isEmpty
          ? existing.accountLogin
          : null,
      nodeAliases: incoming.nodeAliases.isEmpty
          ? existing.nodeAliases
          : <String>{...existing.nodeAliases, ...incoming.nodeAliases}.toList(),
      about: incoming.about.trim().isEmpty ? existing.about : null,
      avatarData: incoming.avatarData.isEmpty ? existing.avatarData : null,
      publicKey: incoming.publicKey.isEmpty ? existing.publicKey : null,
      online: online ?? incoming.online || existing.online,
      meshProBadge: incoming.meshProBadge ?? existing.meshProBadge,
      profileBackground:
          incoming.profileBackground ?? existing.profileBackground,
      profileEffect: incoming.profileEffect ?? existing.profileEffect,
      profileBlinkShape:
          incoming.profileBlinkShape ?? existing.profileBlinkShape,
      avatarDecoration: incoming.avatarDecoration ?? existing.avatarDecoration,
      profileGlow: incoming.profileGlow ?? existing.profileGlow,
      profileAccent: incoming.profileAccent ?? existing.profileAccent,
      emojiStatus: incoming.emojiStatus.trim().isEmpty
          ? existing.emojiStatus
          : incoming.emojiStatus,
    );
  }

  Profile _resolveDirectPeerProfile({
    required String nodeId,
    required String accountLogin,
    required String fallbackName,
  }) {
    final normalizedLogin = accountLogin.trim().toLowerCase();
    Profile? known = profiles[nodeId];
    if (known == null) {
      for (final candidate in profiles.values) {
        final sameLogin =
            normalizedLogin.isNotEmpty &&
            candidate.accountLogin.trim().toLowerCase() == normalizedLogin;
        if (sameLogin || candidate.nodeAliases.contains(nodeId)) {
          known = candidate;
          break;
        }
      }
    }
    if (known == null) {
      for (final thread in threads.values) {
        if (thread.isGroup || thread.chatKind != 'normal') continue;
        final candidate = thread.profile;
        final sameLogin =
            normalizedLogin.isNotEmpty &&
            candidate.accountLogin.trim().toLowerCase() == normalizedLogin;
        if (sameLogin || candidate.nodeAliases.contains(nodeId)) {
          known = candidate;
          break;
        }
      }
    }

    final canonicalNode = known?.nodeId.isNotEmpty == true
        ? known!.nodeId
        : nodeId;
    final displayName = known?.displayName.trim().isNotEmpty == true
        ? known!.displayName
        : fallbackName.trim().isNotEmpty
        ? fallbackName.trim()
        : (canonicalNode.length > 8
              ? canonicalNode.substring(0, 8)
              : canonicalNode);
    final incoming =
        (known ?? Profile(nodeId: canonicalNode, displayName: displayName))
            .copyWith(
              displayName: displayName,
              accountLogin: normalizedLogin.isEmpty
                  ? known?.accountLogin ?? ''
                  : normalizedLogin,
              nodeAliases: <String>{
                ...?known?.nodeAliases,
                canonicalNode,
                nodeId,
              }.where((value) => value.isNotEmpty).toList(),
            );
    final merged = _mergeProfile(incoming);
    profiles[canonicalNode] = merged;
    _applyProfileToThreads(merged);
    return merged;
  }

  void _applyProfileToThreads(Profile profile) {
    for (final thread in threads.values) {
      if (thread.isGroup || thread.profile.nodeId != profile.nodeId) continue;
      thread.profile = profile;
    }
  }

  List<ChatThread> get sortedThreads {
    final result = _dedupeVisibleThreads(
      [
        ...threads.values,
        ...groups.values,
      ].where((thread) => !thread.archived && !thread.isSecret).toList(),
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
      ].where((thread) => thread.archived && !thread.isSecret).toList(),
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
    final result =
        stories.values
            .where(
              (story) =>
                  !story.expired &&
                  (story.ownerNode == myNodeId ||
                      !hiddenStoryOwners.contains(story.ownerNode)),
            )
            .toList()
          ..sort((a, b) {
            if (a.ownerNode == myNodeId && b.ownerNode != myNodeId) return -1;
            if (b.ownerNode == myNodeId && a.ownerNode != myNodeId) return 1;
            return b.createdAt.compareTo(a.createdAt);
          });
    return result;
  }

  int unreadStoriesFor(String ownerNode) {
    if (ownerNode == myNodeId) return 0;
    return stories.values
        .where(
          (story) =>
              story.ownerNode == ownerNode &&
              !story.expired &&
              !hiddenStoryOwners.contains(story.ownerNode) &&
              !story.viewedByNodeIds.contains(myNodeId),
        )
        .length;
  }

  List<ChatThread> _dedupeVisibleThreads(List<ChatThread> source) {
    final personal = <String, ChatThread>{};
    final result = <ChatThread>[];
    for (final thread in source) {
      if (thread.isGroup ||
          thread.chatKind != 'normal' ||
          isSavedMessagesProfile(thread.profile)) {
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
    if (thread.chatKind != 'normal') return thread.storageKey;
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
    final key = thread.isGroup ? thread.groupId : thread.storageKey;
    final until = typingUntil[key];
    return until != null && until.isAfter(DateTime.now());
  }

  String activityLabel(ChatThread thread) {
    final key = thread.isGroup ? thread.groupId : thread.storageKey;
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
    await ble.clearQueuedPackets();
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
    return thread.storageKey;
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
      await _loadOwnProfile(session!);
      stickerLibrary = await _stickerStore.load(session);
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
    unawaited(_notifications.refreshAndroidPushToken());
    if (session == null) return;
    if (!_socket.isConnected) {
      await _connect();
    } else {
      unawaited(refreshMeshProSubscription());
    }
    if (ble.running && !ble.scanning) unawaited(ble.startScan());
  }

  Future<void> handleAppPaused() async {
    if (ble.running) await ble.stopScan();
  }

  Future<MeshProSubscription> refreshMeshProSubscription() async {
    if (session == null || !_socket.isConnected) {
      return meshProSubscription;
    }
    final pending = _meshProCompleter;
    if (pending != null) return pending.future;
    final completer = Completer<MeshProSubscription>();
    _meshProCompleter = completer;
    _socket.send({
      'type': 'subscription_status_request',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'product': 'meshpro',
      'ttl': 5,
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (identical(_meshProCompleter, completer)) {
          _meshProCompleter = null;
        }
        return meshProSubscription;
      },
    );
  }

  void _applyMeshProSubscription(Object? raw) {
    meshProSubscription = MeshProSubscription.fromJson(raw);
    final completer = _meshProCompleter;
    _meshProCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(meshProSubscription);
    }
    notifyListeners();
  }

  bool _hasMeshProFeature(String featureId) {
    return meshProSubscription.isActiveNow &&
        meshProSubscription.entitlements.hasFeature(featureId);
  }

  Future<bool> _refreshMeshProFeature(String featureId) async {
    if (_hasMeshProFeature(featureId)) return true;
    if (session == null || !_socket.isConnected) return false;
    try {
      await refreshMeshProSubscription();
    } catch (_) {
      // The feature request will surface the appropriate subscription error.
    }
    return _hasMeshProFeature(featureId);
  }

  Future<AiRewriteResult> rewriteTextWithAi({
    required String text,
    required String style,
  }) async {
    final current = session;
    final normalizedText = text.trim();
    if (current == null) {
      throw const AiRewriteException('unauthorized', 'Sign in first');
    }
    if (normalizedText.isEmpty) {
      throw const AiRewriteException('empty_text', 'Write a message first');
    }
    if (!_socket.isConnected) {
      throw const AiRewriteException(
        'offline',
        'Connect to the server to use AI tools',
      );
    }
    if (!await _refreshMeshProFeature('ai_text_rewrite')) {
      throw const AiRewriteException(
        'meshpro_required',
        'AI writing tools require MeshPro',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiRewriteResult>();
    _aiRewriteCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_text_rewrite_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'style': style,
        'text': normalizedText,
      });
    } catch (_) {
      _aiRewriteCompleters.remove(requestId);
      throw const AiRewriteException(
        'send_failed',
        'Could not send the AI request',
      );
    }

    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiRewriteCompleters.remove(requestId);
        throw const AiRewriteException(
          'timeout',
          'The AI service took too long to respond',
        );
      },
    );
  }

  void _handleAiRewriteResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiRewriteCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      completer.complete(
        AiRewriteResult(
          text: packet['text']?.toString() ?? '',
          remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
        ),
      );
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'AI writing tools require MeshPro',
      'quota_exceeded': 'The monthly AI rewrite limit has been reached',
      'ai_unavailable': 'AI is not configured on the server yet',
      'provider_error': 'The AI provider is temporarily unavailable',
      'text_too_long': 'This message is too long for the AI assistant',
      'unsupported_style': 'This writing style is not supported',
      'empty_text': 'Write a message first',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiRewriteException(code, messages[code] ?? 'AI rewrite failed'),
    );
  }

  Future<AiTranslationResult> translateMessageWithAi({
    required String text,
    required String targetLanguage,
  }) async {
    final current = session;
    final normalizedText = text.trim();
    final normalizedTarget = targetLanguage.trim().toLowerCase();
    if (current == null) {
      throw const AiTranslationException('unauthorized', 'Sign in first');
    }
    if (normalizedText.isEmpty) {
      throw const AiTranslationException(
        'empty_text',
        'This message has no text to translate',
      );
    }
    if (!_socket.isConnected) {
      throw const AiTranslationException(
        'offline',
        'Connect to the server to translate messages',
      );
    }
    if (!await _refreshMeshProFeature('ai_message_translation')) {
      throw const AiTranslationException(
        'meshpro_required',
        'Message translation requires MeshPro',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiTranslationResult>();
    _aiTranslationCompleters[requestId] = completer;
    _socket.send({
      'type': 'ai_message_translation_request',
      'packet_id': requestId,
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': current.nodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'text': normalizedText,
      'target_language': normalizedTarget,
    });
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiTranslationCompleters.remove(requestId);
        throw const AiTranslationException(
          'timeout',
          'The translation service took too long to respond',
        );
      },
    );
  }

  void _handleAiTranslationResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiTranslationCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      completer.complete(
        AiTranslationResult(
          text: packet['text']?.toString() ?? '',
          sourceLanguage: packet['source_language']?.toString() ?? 'auto',
          targetLanguage: packet['target_language']?.toString() ?? '',
          remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
        ),
      );
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Message translation requires MeshPro',
      'quota_exceeded': 'The monthly translation limit has been reached',
      'ai_unavailable': 'AI is not configured on the server yet',
      'provider_error': 'The translation provider is temporarily unavailable',
      'text_too_long': 'This message is too long to translate',
      'unsupported_language': 'This language is not supported',
      'empty_text': 'This message has no text to translate',
      'unauthorized': 'Sign in again to use translation',
    };
    completer.completeError(
      AiTranslationException(code, messages[code] ?? 'Translation failed'),
    );
  }

  Future<AiSummaryResult> summarizeMessagesWithAi(
    List<ChatMessage> messages,
  ) async {
    final current = session;
    if (current == null) {
      throw const AiSummaryException('unauthorized', 'Sign in first');
    }
    if (!_socket.isConnected) {
      throw const AiSummaryException(
        'offline',
        'Connect to the server to create a summary',
      );
    }
    if (!await _refreshMeshProFeature('ai_chat_summary')) {
      throw const AiSummaryException(
        'meshpro_required',
        'Unread summaries require MeshPro',
      );
    }

    final payload = <Map<String, String>>[];
    for (final message in messages.where((item) => !item.deleted).take(80)) {
      var text = message.text.trim();
      if (text.isEmpty && message.kind == ChatMessageKind.sticker) {
        text = '[Sticker]';
      } else if (text.isEmpty && message.kind == ChatMessageKind.file) {
        final lowerName = message.fileName.toLowerCase();
        if (RegExp(r'\.(m4a|mp3|wav|ogg|webm|aac)$').hasMatch(lowerName)) {
          text = message.transcription.trim().isNotEmpty
              ? '[Voice message] ${message.transcription.trim()}'
              : '[Voice message]';
        } else if (RegExp(
          r'\.(png|jpe?g|gif|webp|heic)$',
        ).hasMatch(lowerName)) {
          text = '[Photo]';
        } else {
          text = message.fileName.trim().isEmpty
              ? '[File]'
              : '[File: ${message.fileName.trim()}]';
        }
      }
      if (text.isEmpty) continue;
      final sender = message.senderNode == myNodeId
          ? 'You'
          : (profiles[message.senderNode]?.displayName.trim().isNotEmpty == true
                ? profiles[message.senderNode]!.displayName.trim()
                : message.senderNode);
      payload.add({'sender': sender, 'text': text});
    }
    if (payload.isEmpty) {
      throw const AiSummaryException(
        'no_messages',
        'There are no unread messages to summarize',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiSummaryResult>();
    _aiSummaryCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_chat_summary_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'messages': payload,
      });
    } catch (_) {
      _aiSummaryCompleters.remove(requestId);
      throw const AiSummaryException(
        'send_failed',
        'Could not send the summary request',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiSummaryCompleters.remove(requestId);
        throw const AiSummaryException(
          'timeout',
          'The AI service took too long to respond',
        );
      },
    );
  }

  Future<AiSummaryResult> summarizeCallNotesWithAi(String notes) async {
    final current = session;
    final normalizedNotes = notes.trim();
    if (current == null) {
      throw const AiSummaryException('unauthorized', 'Sign in first');
    }
    if (normalizedNotes.isEmpty) {
      throw const AiSummaryException(
        'no_transcript',
        'Add call notes or a transcript first',
      );
    }
    if (!_socket.isConnected) {
      throw const AiSummaryException(
        'offline',
        'Connect to the server to create a call summary',
      );
    }
    if (!await _refreshMeshProFeature('ai_call_summary')) {
      throw const AiSummaryException(
        'meshpro_required',
        'AI call summaries require MeshPro',
      );
    }
    final requestId = const Uuid().v4();
    final completer = Completer<AiSummaryResult>();
    _aiSummaryCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_call_summary_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'notes': normalizedNotes,
      });
    } catch (_) {
      _aiSummaryCompleters.remove(requestId);
      throw const AiSummaryException(
        'send_failed',
        'Could not send the call summary request',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiSummaryCompleters.remove(requestId);
        throw const AiSummaryException(
          'timeout',
          'The call summary took too long',
        );
      },
    );
  }

  Future<AiTranscriptionResult> transcribeVoiceWithAi(
    ChatMessage message,
  ) async {
    final current = session;
    if (current == null) {
      throw const AiTranscriptionException('unauthorized', 'Sign in first');
    }
    if (!_socket.isConnected) {
      throw const AiTranscriptionException(
        'offline',
        'Connect to the server to transcribe audio',
      );
    }
    if (!await _refreshMeshProFeature('ai_voice_transcription')) {
      throw const AiTranscriptionException(
        'meshpro_required',
        'Voice transcription requires MeshPro',
      );
    }
    if (message.fileData.isEmpty) {
      throw const AiTranscriptionException(
        'empty_audio',
        'The audio file is not cached on this device',
      );
    }
    final bytes = _hexDecode(message.fileData);
    if (bytes.isEmpty) {
      throw const AiTranscriptionException('empty_audio', 'Audio is empty');
    }
    if (bytes.length > 8 * 1024 * 1024) {
      throw const AiTranscriptionException(
        'audio_too_large',
        'Voice transcription supports files up to 8 MB',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiTranscriptionResult>();
    _aiTranscriptionCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_voice_transcription_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'message_id': message.id,
        'filename': message.fileName.trim().isEmpty
            ? 'voice.m4a'
            : message.fileName,
        'audio_base64': base64Encode(bytes),
        'duration_seconds': _voiceDurationHint(message.fileName),
      });
    } catch (_) {
      _aiTranscriptionCompleters.remove(requestId);
      throw const AiTranscriptionException(
        'send_failed',
        'Could not send the transcription request',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 70),
      onTimeout: () {
        _aiTranscriptionCompleters.remove(requestId);
        throw const AiTranscriptionException(
          'timeout',
          'Voice transcription took too long',
        );
      },
    );
  }

  Future<AiOcrResult> extractImageTextWithAi(ChatMessage message) async {
    final current = session;
    if (current == null) {
      throw const AiOcrException('unauthorized', 'Sign in first');
    }
    if (!_socket.isConnected) {
      throw const AiOcrException(
        'offline',
        'Connect to the server to extract text',
      );
    }
    if (!await _refreshMeshProFeature('ai_image_ocr')) {
      throw const AiOcrException(
        'meshpro_required',
        'Photo and document OCR requires MeshPro',
      );
    }
    if (message.fileData.isEmpty) {
      throw const AiOcrException(
        'empty_image',
        'The image is not cached on this device',
      );
    }
    final bytes = _hexDecode(message.fileData);
    if (bytes.isEmpty) {
      throw const AiOcrException('empty_image', 'The image is empty');
    }
    if (bytes.length > 2 * 1024 * 1024) {
      throw const AiOcrException(
        'image_too_large',
        'OCR currently supports images up to 2 MB',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiOcrResult>();
    _aiOcrCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_image_ocr_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'message_id': message.id,
        'filename': message.fileName.trim().isEmpty
            ? 'image.jpg'
            : message.fileName,
        'image_base64': base64Encode(bytes),
      });
    } catch (_) {
      _aiOcrCompleters.remove(requestId);
      throw const AiOcrException(
        'send_failed',
        'Could not send the OCR request',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 70),
      onTimeout: () {
        _aiOcrCompleters.remove(requestId);
        throw const AiOcrException('timeout', 'Text extraction took too long');
      },
    );
  }

  Future<AiSmartRepliesResult> suggestRepliesWithAi(
    List<ChatMessage> messages,
  ) async {
    final current = session;
    if (current == null) {
      throw const AiSmartRepliesException('unauthorized', 'Sign in first');
    }
    if (!_socket.isConnected) {
      throw const AiSmartRepliesException(
        'offline',
        'Connect to the server to generate replies',
      );
    }
    if (!await _refreshMeshProFeature('ai_smart_replies')) {
      throw const AiSmartRepliesException(
        'meshpro_required',
        'Smart replies require MeshPro',
      );
    }

    final payload = <Map<String, dynamic>>[];
    for (final message in messages.where((item) => !item.deleted).take(20)) {
      var text = message.text.trim();
      if (text.isEmpty && message.transcription.trim().isNotEmpty) {
        text = '[Voice] ${message.transcription.trim()}';
      } else if (text.isEmpty && message.ocrText.trim().isNotEmpty) {
        text = '[Image text] ${message.ocrText.trim()}';
      } else if (text.isEmpty && message.kind == ChatMessageKind.file) {
        text = message.fileName.trim().isEmpty
            ? '[Attachment]'
            : '[Attachment: ${message.fileName.trim()}]';
      } else if (text.isEmpty && message.kind == ChatMessageKind.sticker) {
        text = '[Sticker]';
      }
      if (text.isEmpty) continue;
      final isMine = message.senderNode == myNodeId;
      final sender = isMine
          ? 'You'
          : (profiles[message.senderNode]?.displayName.trim().isNotEmpty == true
                ? profiles[message.senderNode]!.displayName.trim()
                : 'Other person');
      payload.add({'sender': sender, 'text': text, 'is_mine': isMine});
    }
    if (payload.isEmpty || payload.every((item) => item['is_mine'] == true)) {
      throw const AiSmartRepliesException(
        'no_messages',
        'There is no incoming message to answer yet',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiSmartRepliesResult>();
    _aiSmartRepliesCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_smart_replies_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'messages': payload,
      });
    } catch (_) {
      _aiSmartRepliesCompleters.remove(requestId);
      throw const AiSmartRepliesException(
        'send_failed',
        'Could not request smart replies',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiSmartRepliesCompleters.remove(requestId);
        throw const AiSmartRepliesException(
          'timeout',
          'Smart replies took too long',
        );
      },
    );
  }

  Future<AiPersonMemoryResult> askPersonMemoryWithAi({
    required ChatThread thread,
    required String question,
  }) async {
    final current = session;
    final normalizedQuestion = question.trim();
    if (current == null) {
      throw const AiPersonMemoryException('unauthorized', 'Sign in first');
    }
    if (thread.isGroup || thread.isBluetooth) {
      throw const AiPersonMemoryException(
        'unsupported_chat',
        'Personal memory is available in direct chats',
      );
    }
    if (normalizedQuestion.isEmpty) {
      throw const AiPersonMemoryException(
        'empty_question',
        'Ask a question about this conversation',
      );
    }
    if (!_socket.isConnected) {
      throw const AiPersonMemoryException(
        'offline',
        'Connect to the server to search chat memory',
      );
    }
    if (!await _refreshMeshProFeature('ai_person_memory')) {
      throw const AiPersonMemoryException(
        'meshpro_required',
        'Personal AI memory requires MeshPro',
      );
    }

    final messages = thread.messages
        .where((message) => !message.deleted)
        .toList(growable: false);
    final start = max(0, messages.length - 240);
    final payload = <Map<String, String>>[];
    for (final message in messages.skip(start)) {
      var text = message.text.trim();
      if (text.isEmpty && message.transcription.trim().isNotEmpty) {
        text = '[Voice] ${message.transcription.trim()}';
      } else if (text.isEmpty && message.ocrText.trim().isNotEmpty) {
        text = '[Image text] ${message.ocrText.trim()}';
      } else if (text.isEmpty && message.kind == ChatMessageKind.file) {
        text = message.fileName.trim().isEmpty
            ? '[Attachment]'
            : '[Attachment: ${message.fileName.trim()}]';
      } else if (text.isEmpty && message.kind == ChatMessageKind.sticker) {
        text = '[Sticker]';
      }
      if (text.isEmpty) continue;
      final mine = message.senderNode == myNodeId;
      payload.add({
        'sender': mine ? 'You' : thread.profile.displayName,
        'text': text,
        'date': message.createdAt.toUtc().toIso8601String(),
      });
    }
    if (payload.isEmpty) {
      throw const AiPersonMemoryException(
        'no_messages',
        'There are no searchable messages in this chat',
      );
    }

    final requestId = const Uuid().v4();
    final completer = Completer<AiPersonMemoryResult>();
    _aiPersonMemoryCompleters[requestId] = completer;
    try {
      _socket.send({
        'type': 'ai_person_memory_request',
        'packet_id': requestId,
        'request_id': requestId,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': current.nodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
        'question': normalizedQuestion,
        'messages': payload,
      });
    } catch (_) {
      _aiPersonMemoryCompleters.remove(requestId);
      throw const AiPersonMemoryException(
        'send_failed',
        'Could not send the memory request',
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        _aiPersonMemoryCompleters.remove(requestId);
        throw const AiPersonMemoryException(
          'timeout',
          'Chat memory took too long to respond',
        );
      },
    );
  }

  double _voiceDurationHint(String filename) {
    final match = RegExp(r'_(\d+)s(?:\.|$)').firstMatch(filename);
    return double.tryParse(match?.group(1) ?? '') ?? 0;
  }

  void _handleAiSummaryResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiSummaryCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      completer.complete(
        AiSummaryResult(
          text: packet['text']?.toString() ?? '',
          remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
        ),
      );
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Unread summaries require MeshPro',
      'quota_exceeded': 'The monthly summary limit has been reached',
      'ai_unavailable': 'AI is not configured on the server yet',
      'provider_error': 'The AI provider is temporarily unavailable',
      'no_messages': 'There are no unread messages to summarize',
      'no_transcript': 'Add call notes or a transcript first',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiSummaryException(code, messages[code] ?? 'Could not create summary'),
    );
  }

  void _handleAiTranscriptionResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiTranscriptionCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      final result = AiTranscriptionResult(
        text: packet['text']?.toString() ?? '',
        language: packet['language']?.toString() ?? '',
        durationSeconds:
            double.tryParse(packet['duration_seconds']?.toString() ?? '') ?? 0,
        remainingMinutes:
            int.tryParse(packet['remaining_minutes']?.toString() ?? '') ?? 0,
      );
      final messageId = packet['message_id']?.toString() ?? '';
      _applyVoiceTranscription(messageId, result);
      completer.complete(result);
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Voice transcription requires MeshPro',
      'quota_exceeded': 'The monthly transcription limit has been reached',
      'ai_unavailable': 'AI transcription is not configured on the server',
      'provider_error': 'Could not transcribe this voice message',
      'unsupported_audio_format': 'This audio format is not supported',
      'audio_too_large': 'Voice transcription supports files up to 8 MB',
      'empty_audio': 'The audio file is not available on this device',
      'invalid_audio': 'The cached audio file is invalid',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiTranscriptionException(
        code,
        messages[code] ?? 'Voice transcription failed',
      ),
    );
  }

  void _handleAiOcrResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiOcrCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      final result = AiOcrResult(
        text: packet['text']?.toString() ?? '',
        language: packet['language']?.toString() ?? '',
        processed: packet['processed'] == true,
        remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
      );
      _applyImageOcr(packet['message_id']?.toString() ?? '', result);
      completer.complete(result);
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Photo and document OCR requires MeshPro',
      'quota_exceeded': 'The monthly OCR limit has been reached',
      'ai_unavailable': 'Image OCR is not configured on the server',
      'provider_error': 'Could not extract text from this image',
      'unsupported_image_format': 'OCR supports JPEG, PNG, and WebP images',
      'image_too_large': 'OCR currently supports images up to 2 MB',
      'empty_image': 'The image is not available on this device',
      'invalid_image': 'The cached image is invalid',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiOcrException(code, messages[code] ?? 'Text extraction failed'),
    );
  }

  void _handleAiSmartRepliesResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiSmartRepliesCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      final rawReplies = packet['replies'];
      final replies = rawReplies is List
          ? rawReplies
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .take(3)
                .toList(growable: false)
          : const <String>[];
      if (replies.length == 3) {
        completer.complete(
          AiSmartRepliesResult(
            replies: replies,
            remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
          ),
        );
      } else {
        completer.completeError(
          const AiSmartRepliesException(
            'invalid_response',
            'The AI service returned incomplete replies',
          ),
        );
      }
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Smart replies require MeshPro',
      'quota_exceeded': 'The monthly smart reply limit has been reached',
      'ai_unavailable': 'AI is not configured on the server yet',
      'provider_error': 'Could not generate smart replies',
      'no_messages': 'There is no incoming message to answer yet',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiSmartRepliesException(
        code,
        messages[code] ?? 'Could not generate smart replies',
      ),
    );
  }

  void _handleAiPersonMemoryResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _aiPersonMemoryCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (packet['ok'] == true) {
      completer.complete(
        AiPersonMemoryResult(
          text: packet['text']?.toString() ?? '',
          remaining: int.tryParse(packet['remaining']?.toString() ?? '') ?? 0,
        ),
      );
      return;
    }
    final code = packet['error']?.toString() ?? 'unknown_error';
    const messages = <String, String>{
      'meshpro_required': 'Personal AI memory requires MeshPro',
      'quota_exceeded': 'The monthly memory search limit has been reached',
      'ai_unavailable': 'AI is not configured on the server yet',
      'provider_error': 'Could not search this conversation',
      'empty_question': 'Ask a question about this conversation',
      'no_messages': 'There are no searchable messages in this chat',
      'unauthorized': 'Sign in again to use AI tools',
    };
    completer.completeError(
      AiPersonMemoryException(
        code,
        messages[code] ?? 'Could not search chat memory',
      ),
    );
  }

  void _applyVoiceTranscription(
    String messageId,
    AiTranscriptionResult result,
  ) {
    if (messageId.isEmpty) return;
    var changed = false;
    for (final thread in [...threads.values, ...groups.values]) {
      final index = thread.messages.indexWhere(
        (message) => message.id == messageId,
      );
      if (index < 0) continue;
      final current = thread.messages[index];
      thread.messages[index] = current.copyWith(
        transcription: result.text,
        transcriptionLanguage: result.language,
        transcriptionDurationSeconds: result.durationSeconds,
      );
      changed = true;
    }
    if (!changed) return;
    unawaited(_saveCache());
    notifyListeners();
  }

  void _applyImageOcr(String messageId, AiOcrResult result) {
    if (messageId.isEmpty) return;
    var changed = false;
    for (final thread in [...threads.values, ...groups.values]) {
      final index = thread.messages.indexWhere(
        (message) => message.id == messageId,
      );
      if (index < 0) continue;
      final current = thread.messages[index];
      thread.messages[index] = current.copyWith(
        ocrText: result.text,
        ocrLanguage: result.language,
        ocrProcessed: result.processed,
      );
      changed = true;
    }
    if (!changed) return;
    unawaited(_saveCache());
    notifyListeners();
  }

  Future<void> forceResync() async {
    if (session == null) return;
    status = 'Resyncing...';
    addDiagnostic('sync', 'Manual resync requested');
    notifyListeners();
    await _socket.close();
    await _connect();
  }

  void _scheduleSoftResync(String reason) {
    if (session == null || !_socket.isConnected) return;
    if (_softResyncTimer?.isActive == true) return;
    _softResyncTimer = Timer(const Duration(milliseconds: 700), () {
      addDiagnostic('sync', reason);
      unawaited(forceResync());
    });
  }

  Future<void> requestNotificationPermissions() async {
    await _notifications.requestPermissions();
    await _syncWebPushSubscription();
    await _syncAndroidPushToken();
  }

  void _handleAndroidPushToken(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty || _androidPushToken == normalized) return;
    _androidPushToken = normalized;
    _androidPushSubscribedToken = '';
    unawaited(_syncAndroidPushToken());
  }

  Future<void> _syncAndroidPushToken() async {
    if (kIsWeb ||
        session == null ||
        !_socket.isConnected ||
        !appSettings.notificationsEnabled ||
        _androidPushToken.isEmpty ||
        _androidPushSubscribedToken == _androidPushToken) {
      return;
    }
    _socket.send({
      'type': 'fcm_subscribe',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'token': _androidPushToken,
      'ttl': 5,
    });
    _androidPushSubscribedToken = _androidPushToken;
  }

  Future<void> _unsubscribeAndroidPush() async {
    if (kIsWeb ||
        session == null ||
        !_socket.isConnected ||
        _androidPushToken.isEmpty) {
      return;
    }
    _socket.send({
      'type': 'fcm_unsubscribe',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'token': _androidPushToken,
      'ttl': 5,
    });
    _androidPushSubscribedToken = '';
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
      var candidate = await _store.save(
        serverUrl: normalized,
        serverToken: token.trim(),
        login: login.trim().toLowerCase(),
        password: password,
        publicUsername: publicUsername.trim().toLowerCase().replaceFirst(
          '@',
          '',
        ),
      );
      await _initializeCryptoForSession(candidate);
      final checkError = await _socket.check(candidate, _crypto.publicKey);
      if (checkError != null) {
        error = checkError;
        await _store.clear();
        await _store.removeRecent(candidate);
        recentSessions = await _store.loadRecent();
        return false;
      }
      candidate = await _adoptServerIdentityRecovery(candidate);
      await _socket.close();
      _clearLocalState();
      session = candidate;
      recentSessions = await _store.loadRecent();
      await _cache.load(candidate, profiles, threads, groups);
      await _loadOwnProfile(candidate);
      stickerLibrary = await _stickerStore.load(candidate);
      await _loadStories();
      await _repairCachedGroups();
      await _repairCachedMessages();
      _restoreGroupKeysFromThreads();
      await _repairCachedGroupMessages();
      await _connect(reactivateDevice: true);
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
      await _initializeCryptoForSession(candidate);
      final checkError = await _socket.check(candidate, _crypto.publicKey);
      if (checkError != null) {
        error = checkError;
        return false;
      }
      candidate = await _adoptServerIdentityRecovery(candidate);
      await _socket.close();
      _clearLocalState();
      await _store.saveCurrent(candidate);
      await _store.saveRecent(candidate);
      session = candidate;
      recentSessions = await _store.loadRecent();
      await _cache.load(candidate, profiles, threads, groups);
      await _loadOwnProfile(candidate);
      stickerLibrary = await _stickerStore.load(candidate);
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

  Future<void> _initializeCryptoForSession(Session current) async {
    final recovery = current.identityRecovery.trim();
    if (recovery.isEmpty) {
      await _crypto.initialize(current.login, current.password);
      return;
    }
    final restored = await _crypto.initializeFromIdentityRecovery(
      current.login,
      current.password,
      recovery,
    );
    if (!restored) {
      throw StateError(
        'Could not unlock the encrypted message history on this device',
      );
    }
  }

  Future<Session> _adoptServerIdentityRecovery(Session current) async {
    final recovery = _socket.lastIdentityRecovery.trim();
    if (recovery.isEmpty || recovery == current.identityRecovery) {
      return current;
    }
    final restored = await _crypto.initializeFromIdentityRecovery(
      current.login,
      current.password,
      recovery,
    );
    if (!restored) {
      throw StateError(
        'The password is valid, but the encrypted history key could not be restored',
      );
    }
    final updated = current.copyWith(identityRecovery: recovery);
    await _store.saveCurrent(updated);
    await _store.saveRecent(updated);
    return updated;
  }

  Future<void> forgetRecent(Session recent) async {
    await _store.removeRecent(recent);
    await _ownProfileStore.remove(recent);
    await _syncCursorStore.clear(recent);
    recentSessions = await _store.loadRecent();
    notifyListeners();
  }

  Future<void> _connect({bool reactivateDevice = false}) async {
    final current = session;
    if (current == null) return;
    await _initializeCryptoForSession(current);
    final accountCursor = await _syncCursorStore.load(current);
    final cacheCursor = await _cache.loadSyncCursor(current);
    final syncCursor = SyncCursorStore.safeCursor(
      accountCursor: accountCursor,
      cacheCursor: cacheCursor,
    );
    if (accountCursor > 0 && cacheCursor == null) {
      addDiagnostic(
        'sync',
        'Local cache has no matching checkpoint; requesting full snapshot',
      );
    } else if (syncCursor < accountCursor) {
      addDiagnostic(
        'sync',
        'Local cache checkpoint is behind; resuming from $syncCursor',
      );
    }
    _lastAppliedSyncCursor = syncCursor;
    _syncDeltaBuffer.abort();
    _applyingSyncDelta = false;
    _livePacketsDuringDeltaApply.clear();
    await _socket.connect(
      session: current,
      publicKey: _crypto.publicKey,
      profile: _publicOwnProfile,
      deviceName: _defaultDeviceName,
      reactivateDevice: reactivateDevice,
      syncCursor: syncCursor,
      onPacket: _handlePacket,
      onStatus: (value) {
        status = value;
        addDiagnostic('server', value);
        notifyListeners();
      },
    );
  }

  Future<void> _handlePacket(
    Map<String, dynamic> packet, {
    bool fromDeltaReplay = false,
  }) async {
    final packetType = packet['type']?.toString() ?? '';
    if (_applyingSyncDelta &&
        !fromDeltaReplay &&
        SyncDeltaBuffer.isDurableEventPacket(packet)) {
      _livePacketsDuringDeltaApply.add(Map<String, dynamic>.from(packet));
      return;
    }
    if (packetType == 'server_sync_delta_begin') {
      try {
        _syncDeltaBuffer.begin(packet, localCursor: _lastAppliedSyncCursor);
        status = 'Syncing changes...';
        addDiagnostic('sync', 'Delta sync started');
      } catch (syncError) {
        _requestAuthoritativeSnapshot('invalid delta begin: $syncError');
      }
      notifyListeners();
      return;
    }
    if (packetType == 'server_sync_delta_event') {
      try {
        _syncDeltaBuffer.addEvent(packet);
      } catch (syncError) {
        _requestAuthoritativeSnapshot('invalid delta event: $syncError');
      }
      return;
    }
    if (packetType == 'server_sync_done' && _syncDeltaBuffer.isActive) {
      await _completeDeltaSync(packet);
      return;
    }
    if (packetType == 'server_sync_done' &&
        packet['sync_v2'] is Map &&
        (packet['sync_v2'] as Map)['mode'] == 'delta') {
      _requestAuthoritativeSnapshot('delta completion without active sync');
      return;
    }
    if (_syncDeltaBuffer.shouldBufferLivePacket(packet)) {
      _syncDeltaBuffer.bufferLivePacket(packet);
      return;
    }

    switch (packet['type']) {
      case 'server_welcome':
        _syncDeltaBuffer.abort();
        _applyingSyncDelta = false;
        _livePacketsDuringDeltaApply.clear();
        _applyMeshProSubscription(packet['subscription']);
        if (!MeshSocket.isProtocolCompatible(packet)) {
          status = MeshSocket.protocolError(packet);
        } else {
          status = 'Online';
          addDiagnostic('server', 'Protocol OK, server welcome received');
          _webPushVapidPublicKey =
              packet['web_push_vapid_public_key']?.toString() ?? '';
          unawaited(_syncWebPushSubscription());
          unawaited(_syncAndroidPushToken());
          unawaited(_retryQueuedMessages());
        }
      case 'server_error':
        if (packet['code'] == 'incompatible_protocol') {
          status = MeshSocket.protocolError(packet);
        } else if (packet['code'] == 'device_revoked') {
          status = 'This device was signed out remotely';
          unawaited(_handleDeviceRevoked());
        } else if (packet['code'] == 'account_password_changed') {
          status = 'The account password was changed on another device';
          unawaited(_handlePasswordChangedElsewhere());
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
        final syncCursor = int.tryParse(
          packet['sync_cursor']?.toString() ?? '',
        );
        final current = session;
        await _saveCache();
        if (current != null && syncCursor != null && syncCursor >= 0) {
          await _cache.saveSyncCursor(current, syncCursor);
          await _syncCursorStore.save(current, syncCursor);
          _lastAppliedSyncCursor = syncCursor;
          _socket.updateSyncCursor(syncCursor);
          _socket.send({
            'type': 'sync_v2_ack',
            'source_node': myNodeId,
            'cursor': syncCursor,
            'protocol_version': MeshSocket.protocolVersion,
          });
        }
        status = 'Online';
        lastSyncAt = DateTime.now();
        addDiagnostic('sync', 'Sync received');
        notifyListeners();
      case 'mutation_ack':
        _applyMutationAck(packet);
      case 'file_transfer_progress':
        _applyFileTransferProgress(packet);
      case 'username_lookup_result':
        _handleLookup(packet);
      case 'profile_update_result':
        _handleProfileUpdateResult(packet);
      case 'account_password_change_result':
        _handlePasswordChangeResult(packet);
      case 'subscription_status_result':
        _applyMeshProSubscription(packet['subscription']);
      case 'ai_text_rewrite_result':
        _handleAiRewriteResult(packet);
      case 'ai_message_translation_result':
        _handleAiTranslationResult(packet);
      case 'ai_chat_summary_result':
        _handleAiSummaryResult(packet);
      case 'ai_voice_transcription_result':
        _handleAiTranscriptionResult(packet);
      case 'ai_image_ocr_result':
        _handleAiOcrResult(packet);
      case 'ai_smart_replies_result':
        _handleAiSmartRepliesResult(packet);
      case 'ai_person_memory_result':
        _handleAiPersonMemoryResult(packet);
      case 'ai_call_summary_result':
        _handleAiSummaryResult(packet);
      case 'active_devices':
        _handleActiveDevices(packet);
      case 'active_device_action_result':
        _handleActiveDeviceActionResult(packet);
      case 'meshpro_preferences_result':
        await _handleMeshProPreferencesResult(packet);
      case 'meshpro_preferences_changed':
        await _applyMeshProPreferences(packet['preferences']);
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
      case 'server_sticker_library_sync_chunk':
        await _applyStickerLibrarySyncChunk(packet);
      case 'message_received':
        _markDelivered(packet['message_id']?.toString() ?? '');
      case 'message_read':
        _markMessagesRead(_stringList(packet['message_ids']));
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
      case 'group_member_leave':
        await _applyGroupMemberLeavePacket(packet);
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
      case 'chat_preferences_result':
        _handleChatPreferencesResult(packet);
      case 'scheduled_message_result':
        _handleScheduledMessageResult(packet);
      case 'scheduled_messages':
        _applyScheduledMessages(packet['items']);
      case 'scheduled_message_sent':
        _handleScheduledMessageSent(packet);
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
      case 'call_screen_offer':
        await _handleCallScreenOffer(packet);
      case 'call_screen_answer':
        await _handleCallScreenAnswer(packet);
      case 'call_screen_stop':
        await _handleCallScreenStop(packet);
    }
    notifyListeners();
  }

  Future<void> _completeDeltaSync(Map<String, dynamic> packet) async {
    try {
      final batch = _syncDeltaBuffer.complete(packet);
      _applyingSyncDelta = true;
      _livePacketsDuringDeltaApply.clear();
      for (final event in batch.events) {
        await _handlePacket(event, fromDeltaReplay: true);
      }
      final current = session;
      if (current == null) {
        throw const FormatException('session ended during delta sync');
      }
      await _saveCache();
      await _cache.saveSyncCursor(current, batch.targetCursor);
      await _syncCursorStore.save(current, batch.targetCursor);
      _lastAppliedSyncCursor = batch.targetCursor;
      _socket.updateSyncCursor(batch.targetCursor);
      _socket.send({
        'type': 'sync_v2_ack',
        'source_node': myNodeId,
        'cursor': batch.targetCursor,
        'protocol_version': MeshSocket.protocolVersion,
      });
      final bufferedLivePackets = <Map<String, dynamic>>[
        ...batch.livePackets,
        ..._livePacketsDuringDeltaApply,
      ];
      _applyingSyncDelta = false;
      _livePacketsDuringDeltaApply.clear();
      for (final livePacket in bufferedLivePackets) {
        await _handlePacket(livePacket);
      }
      status = 'Online';
      lastSyncAt = DateTime.now();
      addDiagnostic('sync', 'Delta sync applied through ${batch.targetCursor}');
      notifyListeners();
    } catch (syncError) {
      _applyingSyncDelta = false;
      _livePacketsDuringDeltaApply.clear();
      _requestAuthoritativeSnapshot('delta apply failed: $syncError');
    }
  }

  void _requestAuthoritativeSnapshot(String reason) {
    _syncDeltaBuffer.abort();
    status = 'Repairing sync...';
    addDiagnostic('sync', reason);
    if (_socket.isConnected) {
      _socket.send({
        'type': 'sync_v2_snapshot_request',
        'source_node': myNodeId,
        'cursor': _lastAppliedSyncCursor,
        'reason': reason,
        'protocol_version': MeshSocket.protocolVersion,
      });
    }
    notifyListeners();
  }

  Future<void> _handleBluetoothPacket(Map<String, dynamic> packet) async {
    const allowedTypes = {
      'chat_message',
      'file_chunk',
      'message_received',
      'message_read',
      'message_reaction',
      'message_edit',
      'message_delete',
      'message_pin',
      'chat_delete',
      'typing',
    };
    final type = packet['type']?.toString() ?? '';
    final source = packet['source_node']?.toString() ?? '';
    final destination = packet['destination_node']?.toString() ?? '';
    final protocol = int.tryParse(packet['protocol_version']?.toString() ?? '');
    if (!allowedTypes.contains(type) ||
        source.isEmpty ||
        source == myNodeId ||
        destination != myNodeId ||
        protocol != MeshSocket.protocolVersion) {
      addDiagnostic('bluetooth', 'Rejected invalid Bluetooth packet: $type');
      return;
    }
    await _handlePacket({...packet, 'sender_transport': 'bluetooth'});
  }

  bool _isBluetoothPacket(Map<String, dynamic> packet) =>
      packet['sender_transport'] == 'bluetooth';

  Future<void> _sendDeliveryReceipt(
    Map<String, dynamic> packet,
    String sender,
    String messageId,
  ) async {
    if (sender.isEmpty || messageId.isEmpty) return;
    final receipt = {
      'type': 'message_received',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': sender,
      'message_id': messageId,
      'ttl': _isBluetoothPacket(packet) ? 1 : 5,
    };
    if (_isBluetoothPacket(packet)) {
      try {
        await ble.sendPacketToNode(sender, receipt);
      } catch (error) {
        addDiagnostic('bluetooth', 'Delivery receipt queue failed: $error');
      }
    } else {
      _socket.send(receipt);
    }
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
      _applyProfileToThreads(onlineProfile);
    }
    for (final entry in profiles.entries.toList()) {
      final username = entry.value.publicUsername.trim().toLowerCase();
      final online =
          onlineIds.contains(entry.key) ||
          (username.isNotEmpty && onlineUsernames.contains(username));
      if (!online) {
        profiles[entry.key] = entry.value.copyWith(online: false);
        _applyProfileToThreads(profiles[entry.key]!);
      } else {
        profiles[entry.key] = entry.value.copyWith(online: true);
        _applyProfileToThreads(profiles[entry.key]!);
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
        final merged = _mergeProfile(profile, online: true);
        profiles[profile.nodeId] = merged;
        final username = profile.publicUsername.trim().toLowerCase();
        if (profile.nodeId == myNodeId && session != null) {
          final own = _normalizeOwnProfile(merged, session!);
          profiles[myNodeId] = own;
          _ownProfileHydrated = true;
          await _saveOwnProfile(own);
          if (username.isNotEmpty) {
            session = session!.copyWith(publicUsername: username);
            await _store.updatePublicUsername(username);
          }
        }
      }
    }

    if (packet['sticker_library'] is Map) {
      stickerLibrary = StickerLibrary.fromJson(
        Map<String, dynamic>.from(packet['sticker_library'] as Map),
      );
      await _saveStickers(publish: false);
    } else if (packet['sticker_library_chunked'] != true &&
        stickerLibrary.packs.isNotEmpty) {
      unawaited(_publishStickerLibrary());
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
        _applyProfileToThreads(merged);
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
      final profile = _resolveDirectPeerProfile(
        nodeId: peerId,
        accountLogin: sentByMe ? receiverLogin : senderLogin,
        fallbackName: sentByMe
            ? receiverLogin
            : data['sender_name']?.toString() ?? '',
      );
      final thread = _ensurePacketThread(profile, data);
      final id = data['message_id']?.toString() ?? const Uuid().v4();
      if (_isDeletedMessage(id)) continue;
      final existingIndex = thread.messages.indexWhere(
        (message) => message.id == id,
      );
      if (existingIndex >= 0) {
        final current = thread.messages[existingIndex];
        thread.messages[existingIndex] = current.copyWith(
          replyToMessageId:
              data['reply_to_message_id']?.toString() ??
              current.replyToMessageId,
          replyToText: data['reply_to_text']?.toString() ?? current.replyToText,
          pending: false,
          delivered: true,
          failed: false,
        );
        continue;
      }
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
          messageEffect: data['message_effect']?.toString() ?? 'none',
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
    await _applyStoryArchive(packet['story_archive']);
    _applyChatPreferences(packet['chat_preferences']);
    await _applyMeshProPreferences(packet['meshpro_preferences']);
    _applyScheduledMessages(packet['scheduled_messages']);
    await _repairCachedGroups();
    await _repairCachedMessages();
    await _saveCache();
    notifyListeners();
  }

  Future<void> _applyStickerLibrarySyncChunk(
    Map<String, dynamic> packet,
  ) async {
    final chunkIndex = int.tryParse(packet['chunk_index']?.toString() ?? '');
    final totalChunks = int.tryParse(packet['total_chunks']?.toString() ?? '');
    final data = packet['data']?.toString() ?? '';
    if (chunkIndex == null ||
        totalChunks == null ||
        chunkIndex < 0 ||
        totalChunks <= 0 ||
        chunkIndex >= totalChunks) {
      addDiagnostic('sync', 'Ignored invalid sticker library chunk');
      return;
    }

    if (chunkIndex == 0 || _stickerLibrarySyncTotal != totalChunks) {
      _stickerLibrarySyncChunks.clear();
      _stickerLibrarySyncTotal = totalChunks;
    }
    _stickerLibrarySyncChunks[chunkIndex] = data;
    if (_stickerLibrarySyncChunks.length != totalChunks) return;

    final payload = StringBuffer();
    for (var index = 0; index < totalChunks; index++) {
      final chunk = _stickerLibrarySyncChunks[index];
      if (chunk == null) return;
      payload.write(chunk);
    }

    try {
      final decoded = jsonDecode(payload.toString());
      if (decoded is! Map) {
        throw const FormatException('Sticker library payload is not a map');
      }
      stickerLibrary = StickerLibrary.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      await _saveStickers(publish: false);
      addDiagnostic('sync', 'Sticker library sync received');
      notifyListeners();
    } catch (error) {
      addDiagnostic('sync', 'Sticker library sync failed: $error');
    } finally {
      _stickerLibrarySyncChunks.clear();
      _stickerLibrarySyncTotal = 0;
    }
  }

  Future<Profile?> lookupUsername(
    String username, {
    bool sendRequest = true,
  }) async {
    if (_lookupCompleter != null) return null;
    _lookupCompleter = Completer<Profile?>();
    _lookupSendRequest = sendRequest;
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
    String? profileBackground,
    String? profileEffect,
    String? profileBlinkShape,
    String? avatarDecoration,
    bool? profileGlow,
    int? profileAccent,
    String? emojiStatus,
  }) async {
    final current = session;
    if (current == null) return 'Нет активной сессии';
    if (_profileUpdateCompleter != null) return 'Обновление уже выполняется';
    if (!_ownProfileHydrated) {
      return 'Профиль ещё синхронизируется. Попробуй через пару секунд.';
    }

    final normalizedUsername = publicUsername.trim().toLowerCase().replaceFirst(
      '@',
      '',
    );
    final name = displayName.trim().isEmpty
        ? current.login
        : displayName.trim();
    final normalizedBlinkShape = profileBlinkShape == null
        ? null
        : Profile.normalizeBlinkShape(profileBlinkShape);
    final normalizedBackground = profileBackground == null
        ? null
        : Profile.normalizeBackground(profileBackground);
    final normalizedEffect = profileEffect == null
        ? null
        : Profile.normalizeEffect(profileEffect);
    final normalizedDecoration = avatarDecoration == null
        ? null
        : Profile.normalizeAvatarDecoration(avatarDecoration);
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
      'profile_background': ?normalizedBackground,
      'profile_effect': ?normalizedEffect,
      'profile_blink_shape': ?normalizedBlinkShape,
      'avatar_decoration': ?normalizedDecoration,
      'profile_glow': ?profileGlow,
      'profile_accent': ?profileAccent,
      'emoji_status': ?emojiStatus,
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
    var result = await _profileUpdateCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 'Сервер не ответил',
    );
    _profileUpdateCompleter = null;

    final requestedBackground = normalizedBackground;
    final fallbackBackground = Profile.legacyCompatibleBackground(
      requestedBackground,
    );
    if (result?.trim().toLowerCase() == 'invalid profile background' &&
        requestedBackground != null &&
        requestedBackground != fallbackBackground) {
      final fallbackPacket = Map<String, dynamic>.from(packet)
        ..['packet_id'] = const Uuid().v4()
        ..['profile_background'] = fallbackBackground;
      _profileUpdateCompleter = Completer<String?>();
      try {
        _socket.send(fallbackPacket);
      } catch (error) {
        _profileUpdateCompleter = null;
        return 'Could not send the compatible profile update: $error';
      }
      result = await _profileUpdateCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => 'Server did not answer the compatible profile update',
      );
      _profileUpdateCompleter = null;
    }
    if (result != null) return result;

    session = current.copyWith(publicUsername: normalizedUsername);
    await _store.updatePublicUsername(normalizedUsername);
    final existing = profiles[current.nodeId];
    final profile = Profile(
      nodeId: current.nodeId,
      displayName: name,
      accountLogin: current.login,
      nodeAliases: profiles[current.nodeId]?.nodeAliases ?? [current.nodeId],
      publicUsername: normalizedUsername,
      about: about.trim(),
      avatarData: avatarData,
      publicKey: _crypto.publicKey,
      online: true,
      meshProBadge: existing?.meshProBadge,
      profileBackground: normalizedBackground ?? existing?.profileBackground,
      profileEffect: normalizedEffect ?? existing?.profileEffect,
      profileBlinkShape: normalizedBlinkShape ?? existing?.profileBlinkShape,
      avatarDecoration: normalizedDecoration ?? existing?.avatarDecoration,
      profileGlow: profileGlow ?? existing?.profileGlow,
      profileAccent: profileAccent ?? existing?.profileAccent,
      emojiStatus: emojiStatus ?? existing?.emojiStatus ?? '',
    );
    profiles[current.nodeId] = profile;
    _ownProfileHydrated = true;
    await _saveOwnProfile(profile);
    await _saveCache();
    notifyListeners();
    return null;
  }

  Future<void> _applyGroups(dynamic rawGroups) async {
    final syncedGroupIds = <String>{};
    for (final raw in rawGroups is List ? rawGroups : const []) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final groupId = data['group_id']?.toString() ?? '';
      if (groupId.isEmpty) continue;
      syncedGroupIds.add(groupId);
      final incomingMembers = _stringList(data['members']);
      final includesMe = incomingMembers.contains(myNodeId);
      if (appSettings.deletedGroupIds.contains(groupId)) {
        if (!includesMe) continue;
        await _forgetDeletedGroup(groupId);
      }
      if (!appSettings.allowGroupInvites &&
          !groups.containsKey(groupId) &&
          data['owner_node']?.toString() != myNodeId &&
          !includesMe) {
        continue;
      }
      _ensureGroupThread(
        groupId: groupId,
        groupName: data['group_name']?.toString() ?? 'Группа',
        members: incomingMembers,
        ownerNode: data['owner_node']?.toString() ?? '',
        admins: _stringList(data['admins']),
        isChannel: data['is_channel'] == true,
        commentsEnabled: data.containsKey('comments_enabled')
            ? data['comments_enabled'] != false
            : null,
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
    if (rawGroups is List) {
      final staleGroupIds = groups.keys
          .where((groupId) => !syncedGroupIds.contains(groupId))
          .toList();
      for (final groupId in staleGroupIds) {
        groups.remove(groupId);
        _groupKeys.remove(groupId);
        _groupKeyHistory.remove(groupId);
        typingUntil.remove(groupId);
        activityKinds.remove(groupId);
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
      _groupKeyHistory.remove(groupId);
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
      _groupKeyHistory.remove(groupId);
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
    if (message.kind == ChatMessageKind.file ||
        message.kind == ChatMessageKind.sticker) {
      score += 8;
    }
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
    if (owner.isEmpty) return '';
    if (owner == myNodeId) return myNodeId;
    if (_isLegacyGroupOwnerPlaceholder(owner)) return '';
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
    bool? commentsEnabled,
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
    final existingOwner = groups[groupId]?.ownerNode.trim() ?? '';
    final normalizedOwner = _normalizedGroupOwner(
      ownerNode.trim().isEmpty ? existingOwner : ownerNode,
      ownerBaseMembers,
    );
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
      if (commentsEnabled != null) {
        existing.commentsEnabled = commentsEnabled;
      }
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
      commentsEnabled: commentsEnabled ?? true,
      groupId: groupId,
      groupName: groupName.isEmpty ? 'Группа' : groupName,
      members: normalizedMembers,
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
    ChatMessage? retryingMessage,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || session == null || !group.isGroup) return null;
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final isChannelComment =
        retryingMessage?.isChannelComment == true ||
        (group.isChannel && replyToMessageId.isNotEmpty);
    if (isChannelComment && !canCommentInChannel(group)) {
      return null;
    }
    if (group.isChannel && !_canPostToChannel(group) && !isChannelComment) {
      return null;
    }
    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final outgoing =
        retryingMessage?.copyWith(
          isChannelComment: isChannelComment,
          pending: true,
          delivered: false,
          failed: false,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: group.groupId,
          text: trimmed,
          senderName: ownProfile.displayName,
          createdAt: DateTime.now(),
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          isChannelComment: isChannelComment,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(group, outgoing);
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
      'sender_name': ownProfile.displayName,
      'sender_login': session!.login,
      'group_id': group.groupId,
      'group_name': group.groupName.isEmpty
          ? group.profile.displayName
          : group.groupName,
      'is_channel': group.isChannel,
      'comments_enabled': group.commentsEnabled,
      'group_message_id': id,
      'members': group.members,
      'owner_node': group.ownerNode,
      'admins': group.admins,
      'message': encryptedText,
      'reply_to_message_id': replyToMessageId,
      'reply_to_text': replyToText,
      'message_effect': messageEffect,
      'is_channel_comment': isChannelComment,
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
    if (!_socket.supportsMutationAck) {
      _replaceMessage(id, (message) => message.copyWith(pending: false));
    }
    return id;
  }

  Future<void> _receiveGroupMessage(
    Map<String, dynamic> packet, {
    required bool fromSync,
  }) async {
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isEmpty) return;
    if (appSettings.deletedGroupIds.contains(groupId)) return;
    final existingGroup = groups[groupId];
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: existingGroup == null
          ? _stringList(packet['members'])
          : const <String>[],
      isChannel: packet['is_channel'] == true,
      commentsEnabled: packet.containsKey('comments_enabled')
          ? packet['comments_enabled'] != false
          : null,
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
      final current = group.messages[existingIndex];
      final replyToMessageId =
          packet['reply_to_message_id']?.toString() ?? current.replyToMessageId;
      group.messages[existingIndex] = current.copyWith(
        replyToMessageId: replyToMessageId,
        replyToText: packet['reply_to_text']?.toString() ?? current.replyToText,
        isChannelComment:
            packet['is_channel_comment'] == true ||
            (group.isChannel && replyToMessageId.isNotEmpty) ||
            current.isChannelComment,
        pending: false,
        delivered: true,
        failed: false,
      );
      await _repairGroupMessageText(group, existingIndex, packet);
      await _saveCache();
      notifyListeners();
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
    final rawText = _firstString(packet, const ['message', 'text', 'content']);
    if (rawText.isEmpty) return;
    final text = await _crypto.decryptGroupText(
      _groupKeyForPacket(groupId, packet['group_key_id']?.toString() ?? ''),
      rawText,
    );
    final isServicePayload =
        text.startsWith('::meshchat_location_v1::') ||
        text.startsWith('::meshchat_meeting_v1::');
    final displayText = text;
    final replyToMessageId = packet['reply_to_message_id']?.toString() ?? '';
    group.messages.add(
      ChatMessage(
        id: id,
        senderNode: sender,
        receiverNode: groupId,
        text: displayText,
        senderName: isServicePayload ? '' : senderName,
        createdAt: _parsePacketDate(packet),
        replyToMessageId: replyToMessageId,
        replyToText: packet['reply_to_text']?.toString() ?? '',
        isChannelComment:
            packet['is_channel_comment'] == true ||
            (group.isChannel && replyToMessageId.isNotEmpty),
        messageEffect: packet['message_effect']?.toString() ?? 'none',
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
    if (!current.text.startsWith(MeshCrypto.groupPrefix) &&
        !_isGroupDecryptFailure(current.text)) {
      return;
    }
    final rawText = _firstString(packet, const ['message', 'text', 'content']);
    if (rawText.isEmpty) return;
    final text = await _crypto.decryptGroupText(
      _groupKeyForPacket(
        group.groupId,
        packet['group_key_id']?.toString() ?? '',
      ),
      rawText,
    );
    if (text.isEmpty ||
        text.startsWith(MeshCrypto.groupPrefix) ||
        _isGroupDecryptFailure(text)) {
      return;
    }
    group.messages[messageIndex] = current.copyWith(text: text);
    await _saveCache();
    notifyListeners();
  }

  bool _isGroupDecryptFailure(String text) {
    return text.contains('ошибка расшифровки') ||
        text.contains('РѕС€РёР±РєР° СЂР°СЃС€РёС„СЂРѕРІРєРё') ||
        text.contains('ключ недоступен') ||
        text.contains('РєР»СЋС‡ РЅРµРґРѕСЃС‚СѓРїРµРЅ');
  }

  Future<void> _receiveGroupUpdate(Map<String, dynamic> packet) async {
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isEmpty) return;
    final incomingMembers = _stringList(packet['members']);
    final includesMe = incomingMembers.contains(myNodeId);
    if (appSettings.deletedGroupIds.contains(groupId)) {
      if (!includesMe) return;
      await _forgetDeletedGroup(groupId);
    }
    if (!appSettings.allowGroupInvites &&
        !groups.containsKey(groupId) &&
        packet['owner_node']?.toString() != myNodeId &&
        !includesMe) {
      return;
    }
    if (groups.containsKey(groupId) &&
        incomingMembers.isNotEmpty &&
        !incomingMembers.contains(myNodeId)) {
      await _rememberDeletedGroup(groupId);
      groups.remove(groupId);
      _groupKeys.remove(groupId);
      _groupKeyHistory.remove(groupId);
      typingUntil.remove(groupId);
      activityKinds.remove(groupId);
      await _rewriteCache();
      notifyListeners();
      return;
    }
    final group = _ensureGroupThread(
      groupId: groupId,
      groupName: packet['group_name']?.toString() ?? 'Группа',
      members: incomingMembers,
      ownerNode: packet['owner_node']?.toString() ?? '',
      admins: _stringList(packet['admins']),
      isChannel: packet['is_channel'] == true,
      commentsEnabled: packet.containsKey('comments_enabled')
          ? packet['comments_enabled'] != false
          : null,
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
    notifyListeners();
    _scheduleSoftResync('Group updated: refreshing history');
  }

  void _handleLookup(Map<String, dynamic> packet) {
    final completer = _lookupCompleter;
    final sendRequest = _lookupSendRequest;
    _lookupCompleter = null;
    _lookupSendRequest = true;
    if (completer == null ||
        packet['ok'] != true ||
        packet['profile'] is! Map) {
      completer?.complete(null);
      return;
    }
    final profile = Profile.fromJson(
      Map<String, dynamic>.from(packet['profile'] as Map),
    );
    profiles[profile.nodeId] = _mergeProfile(profile);
    unawaited(_saveCache());
    if (sendRequest) {
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
    }
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

  String get _defaultDeviceName {
    if (kIsWeb) return 'Web browser';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android device',
      TargetPlatform.iOS => 'iPhone or iPad',
      TargetPlatform.windows => 'Windows PC',
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.linux => 'Linux PC',
      TargetPlatform.fuchsia => 'MeshChat device',
    };
  }

  void _handleActiveDeviceActionResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _activeDeviceActionCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      packet['ok'] == true
          ? null
          : packet['reason']?.toString() ?? 'Device action failed',
    );
  }

  void _handlePasswordChangeResult(Map<String, dynamic> packet) {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _passwordChangeCompleters.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      packet['ok'] == true
          ? null
          : _passwordChangeError(packet['reason']?.toString() ?? ''),
    );
  }

  String _passwordChangeError(String reason) {
    return switch (reason) {
      'password_too_short' => 'Use at least 8 characters',
      'password_too_long' => 'Password is too long',
      'password_unchanged' => 'Choose a different password',
      'invalid_current_password' =>
        'This signed-in session no longer has the current password',
      'invalid_encryption_recovery' =>
        'Could not prepare encrypted history recovery',
      'account_not_found' => 'Account was not found',
      _ => 'Could not change the password',
    };
  }

  Future<void> _applyMeshProPreferences(Object? raw) async {
    if (raw is! Map) return;
    final data = Map<String, dynamic>.from(raw);
    final reactions = <String>[];
    final rawReactions = data['quick_reactions'];
    if (rawReactions is List) {
      for (final item in rawReactions) {
        final value = item?.toString().trim() ?? '';
        if (value.isEmpty || value.length > 16 || reactions.contains(value)) {
          continue;
        }
        reactions.add(value);
      }
    }
    final updated = appSettings.copyWith(
      quickReactions: reactions.isEmpty ? null : reactions,
      meshProHdAudio: data['hd_audio'] == true,
      meshProEnhancedNoiseSuppression:
          data['enhanced_noise_suppression'] == true,
    );
    appSettings = updated;
    await _settingsStore.save(updated);
    notifyListeners();
  }

  Future<void> _handleMeshProPreferencesResult(
    Map<String, dynamic> packet,
  ) async {
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _meshProPreferenceCompleters.remove(requestId);
    if (packet['ok'] == true) {
      await _applyMeshProPreferences(packet['preferences']);
      if (completer != null && !completer.isCompleted) {
        completer.complete(null);
      }
      return;
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        packet['reason']?.toString() ?? 'Could not save MeshPro settings',
      );
    }
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
    _reactionActors.clear();
    for (final thread in [...threads.values, ...groups.values]) {
      for (var i = 0; i < thread.messages.length; i++) {
        if (thread.messages[i].reactions.isNotEmpty ||
            thread.messages[i].reactionActors.isNotEmpty) {
          thread.messages[i] = thread.messages[i].copyWith(
            reactions: const {},
            reactionActors: const {},
          );
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
    final actor = _reactionActorIdentity(packet);
    for (final thread in [...threads.values, ...groups.values]) {
      final index = thread.messages.indexWhere(
        (message) => message.id == messageId,
      );
      if (index < 0) continue;
      final message = thread.messages[index];
      final byReaction = _reactionActors.putIfAbsent(messageId, () => {});
      final actors = byReaction.putIfAbsent(reaction, () => <String>{})
        ..addAll(message.reactionActors[reaction] ?? const <String>[]);
      if (actor.isNotEmpty && !actors.add(actor)) return;

      final nextActors = <String, List<String>>{
        for (final entry in message.reactionActors.entries)
          entry.key: [...entry.value],
      };
      if (actors.isNotEmpty) {
        nextActors[reaction] = actors.toList(growable: false)..sort();
      }
      final current = Map<String, int>.from(message.reactions);
      current[reaction] = actors.isNotEmpty
          ? actors.length
          : (current[reaction] ?? 0) + 1;
      thread.messages[index] = message.copyWith(
        reactions: current,
        reactionActors: nextActors,
      );
      unawaited(_saveCache());
      notifyListeners();
      return;
    }
  }

  String _reactionActorIdentity(Map<String, dynamic> packet) {
    final explicit = packet['reactor_identity']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) {
      final separator = explicit.indexOf(':');
      if (separator > 0 && separator < explicit.length - 1) {
        final kind = explicit.substring(0, separator).trim().toLowerCase();
        final value = explicit.substring(separator + 1).trim();
        if (kind == 'login') return 'login:${value.toLowerCase()}';
        if (kind == 'node') return 'node:$value';
      }
      return explicit.toLowerCase();
    }
    final actorLogin =
        packet['reactor_login']?.toString().trim().toLowerCase() ??
        packet['sender_login']?.toString().trim().toLowerCase() ??
        '';
    if (actorLogin.isNotEmpty) return 'login:$actorLogin';
    final actorNode =
        packet['reactor_node']?.toString().trim() ??
        packet['source_node']?.toString().trim() ??
        '';
    return actorNode.isEmpty ? '' : 'node:$actorNode';
  }

  Future<void> sendReaction(
    ChatThread thread,
    ChatMessage message,
    String reaction,
  ) async {
    if (session == null || reaction.trim().isEmpty) return;
    _applyReactionPacket({
      'message_id': message.id,
      'reaction': reaction,
      'source_node': myNodeId,
      'reactor_login': session!.login,
    });
    if (thread.isBluetooth) {
      await _sendBluetoothThreadPacket(thread, {
        'type': 'message_reaction',
        'message_id': message.id,
        'reaction': reaction,
      });
      return;
    }
    final basePacket = {
      'type': thread.isGroup ? 'group_reaction' : 'message_reaction',
      'operation_id':
          '${thread.isGroup ? 'group_reaction' : 'message_reaction'}:'
          '${const Uuid().v4()}',
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'message_id': message.id,
      'group_message_id': message.id,
      'group_id': thread.groupId,
      'reaction': reaction,
      'reactor_login': session!.login,
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
    final isCaption =
        message.kind == ChatMessageKind.file ||
        message.kind == ChatMessageKind.sticker;
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
    if (thread.isBluetooth) {
      final publicKey = thread.profile.publicKey.trim();
      if (publicKey.isEmpty) {
        addDiagnostic(
          'bluetooth',
          'Could not edit ${message.id}: peer key is unavailable',
        );
        return;
      }
      await _sendBluetoothThreadPacket(thread, {
        'type': 'message_edit',
        'message_id': message.id,
        'message': await _crypto.encryptText(publicKey, trimmed),
        if (isCaption) 'file_caption': trimmed,
      });
      return;
    }
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
        'operation_id': 'group_message_edit:${const Uuid().v4()}',
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
    if (!thread.isBluetooth &&
        (message.kind == ChatMessageKind.file ||
            message.kind == ChatMessageKind.sticker)) {
      await _socket.cancelFileTransfer(message.id);
    }
    await _rememberDeletedMessage(message.id);
    _deleteLocalMessage(thread, message.id);
    if (thread.isBluetooth) {
      await ble.cancelQueuedMessage(message.id);
      await _sendBluetoothThreadPacket(thread, {
        'type': 'message_delete',
        'message_id': message.id,
      });
      return;
    }
    final basePacket = {
      'type': thread.isGroup ? 'group_message_delete' : 'message_delete',
      'operation_id':
          '${thread.isGroup ? 'group_message_delete' : 'message_delete'}:'
          '${const Uuid().v4()}',
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
      recipients.add('SERVER');
      for (final recipient in recipients) {
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': recipient,
        });
      }
    } else {
      _socket.send({...basePacket, 'destination_node': thread.profile.nodeId});
      _socket.send({
        ...basePacket,
        'packet_id': const Uuid().v4(),
        'destination_node': 'SERVER',
      });
    }
  }

  Future<void> deleteMessageForMe(
    ChatThread thread,
    ChatMessage message,
  ) async {
    if (thread.isBluetooth) {
      await ble.cancelQueuedMessage(message.id);
    }
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
      'operation_id':
          '${thread.isGroup ? 'group_pin' : 'message_pin'}:'
          '${const Uuid().v4()}',
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
    if (thread.isBluetooth) {
      unawaited(
        _sendBluetoothThreadPacket(thread, {
          'type': 'message_pin',
          'message_id': message.id,
          'action': pinned ? 'unpin' : 'pin',
          'text': _replyPreview(message),
        }),
      );
      return;
    }
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

  String chatPreferenceKey(ChatThread thread) {
    if (thread.isGroup && thread.groupId.isNotEmpty) {
      return 'group:${thread.groupId}';
    }
    if (isSavedMessagesProfile(thread.profile)) return 'saved';
    if (thread.isSecret && thread.threadId.isNotEmpty) {
      return 'secret:${thread.threadId}';
    }
    if (thread.isBluetooth) {
      final identity =
          thread.profile.accountLogin.trim().toLowerCase().isNotEmpty
          ? thread.profile.accountLogin.trim().toLowerCase()
          : thread.profile.nodeId;
      return 'bluetooth:$identity';
    }
    final login = thread.profile.accountLogin.trim().toLowerCase();
    if (login.isNotEmpty) return 'direct:$login';
    final username = thread.profile.publicUsername.trim().toLowerCase();
    if (username.isNotEmpty) return 'direct:@$username';
    return 'direct:${thread.profile.nodeId}';
  }

  Future<String?> updateChatAppearance(
    ChatThread thread, {
    required String themeId,
    required String bubbleStyle,
    required bool animatedBackground,
  }) async {
    if (session == null) return 'No active session';
    if (!_socket.isConnected) return 'No server connection';
    if (!meshProSubscription.isActiveNow ||
        !meshProSubscription.entitlements.hasFeature('per_chat_theme') ||
        !meshProSubscription.entitlements.hasFeature(
          'custom_message_bubbles',
        )) {
      return 'MeshPro required';
    }
    if (animatedBackground &&
        !meshProSubscription.entitlements.hasFeature(
          'animated_chat_backgrounds',
        )) {
      return 'MeshPro required';
    }
    final chatKey = chatPreferenceKey(thread);
    if (chatKey.isEmpty) return 'Chat is not ready';
    final pending = _chatPreferenceCompleters[chatKey];
    if (pending != null) return 'Appearance update is already in progress';
    final completer = Completer<String?>();
    _chatPreferenceCompleters[chatKey] = completer;
    _socket.send({
      'type': 'chat_preferences_update',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'chat_key': chatKey,
      'theme_id': themeId,
      'bubble_style': bubbleStyle,
      'animated_background': animatedBackground,
    });
    final error = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 'Server did not confirm the appearance',
    );
    _chatPreferenceCompleters.remove(chatKey);
    if (error != null) return error;
    thread
      ..themeId = themeId
      ..bubbleStyle = bubbleStyle
      ..animatedBackground = animatedBackground;
    await _saveCache();
    notifyListeners();
    return null;
  }

  void _handleChatPreferencesResult(Map<String, dynamic> packet) {
    final chatKey = packet['chat_key']?.toString() ?? '';
    final completer = _chatPreferenceCompleters[chatKey];
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      packet['ok'] == true
          ? null
          : packet['reason']?.toString() ?? 'Appearance update failed',
    );
  }

  void _applyChatPreferences(dynamic rawPreferences) {
    if (rawPreferences is! List) return;
    final appearanceEnabled =
        meshProSubscription.isActiveNow &&
        meshProSubscription.entitlements.hasFeature('per_chat_theme') &&
        meshProSubscription.entitlements.hasFeature('custom_message_bubbles');
    final byKey = <String, Map<String, dynamic>>{};
    for (final raw in rawPreferences) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final key = data['chat_key']?.toString() ?? '';
      if (key.isNotEmpty) byKey[key] = data;
    }
    for (final thread in [...threads.values, ...groups.values]) {
      if (!appearanceEnabled) {
        thread
          ..themeId = 'midnight'
          ..bubbleStyle = 'classic'
          ..animatedBackground = false;
        continue;
      }
      final preference = byKey[chatPreferenceKey(thread)];
      if (preference == null) continue;
      thread
        ..themeId = preference['theme_id']?.toString() ?? 'midnight'
        ..bubbleStyle = preference['bubble_style']?.toString() ?? 'classic'
        ..animatedBackground =
            preference['animated_background'] == true &&
            meshProSubscription.entitlements.hasFeature(
              'animated_chat_backgrounds',
            );
    }
  }

  List<ScheduledMessageItem> scheduledForThread(ChatThread thread) {
    final key = chatPreferenceKey(thread);
    return scheduledMessages.where((item) => item.chatKey == key).toList()
      ..sort((a, b) => a.nextRunAt.compareTo(b.nextRunAt));
  }

  Future<String?> scheduleTextMessage(
    ChatThread thread,
    String text, {
    required DateTime sendAt,
    String repeatInterval = 'none',
  }) async {
    final current = session;
    final trimmed = text.trim();
    if (current == null) return 'No active session';
    if (trimmed.isEmpty) return 'Message is empty';
    if (!_socket.isConnected) return 'No server connection';
    if (!meshProSubscription.isActiveNow ||
        !meshProSubscription.entitlements.hasFeature('scheduled_messages')) {
      return 'MeshPro required';
    }
    if (repeatInterval != 'none' &&
        !meshProSubscription.entitlements.hasFeature('recurring_reminders')) {
      return 'Recurring reminders require MeshPro';
    }
    if (thread.isBluetooth || isSavedMessagesProfile(thread.profile)) {
      return 'Scheduling is unavailable in this chat';
    }
    if (thread.isChannel && !_canPostToChannel(thread)) {
      return 'Only channel admins can schedule posts';
    }

    final payloads = <Map<String, dynamic>>[];
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
      final basePacket = <String, dynamic>{
        'type': 'group_message',
        'source_node': myNodeId,
        'ttl': 5,
        'sender': current.login,
        'group_id': thread.groupId,
        'group_name': thread.groupName.isEmpty
            ? thread.profile.displayName
            : thread.groupName,
        'is_channel': thread.isChannel,
        'comments_enabled': thread.commentsEnabled,
        'members': thread.members,
        'owner_node': thread.ownerNode,
        'admins': thread.admins,
        'message': encryptedText,
        'reply_to_message_id': '',
        'reply_to_text': '',
        'group_key_id': groupKey.id,
        'group_key_sender_envelope': senderEnvelope,
      };
      for (final member in thread.members.where(
        (member) => member != myNodeId,
      )) {
        final publicKey = profiles[member]?.publicKey ?? '';
        if (publicKey.isEmpty) continue;
        payloads.add({
          ...basePacket,
          'destination_node': member,
          'group_key_envelope': await _crypto.wrapGroupKey(
            publicKey,
            groupKey.key,
          ),
        });
      }
      if (payloads.isEmpty) {
        payloads.add({
          ...basePacket,
          'destination_node': 'SERVER',
          'group_key_envelope': senderEnvelope,
        });
      }
    } else {
      final recipient = thread.profile;
      final wireText = await _crypto.encryptText(recipient.publicKey, trimmed);
      payloads.add({
        'type': 'chat_message',
        'source_node': myNodeId,
        'destination_node': recipient.nodeId,
        'ttl': 5,
        'sender': current.login,
        'message': wireText,
        'chat_kind': thread.chatKind,
        'chat_id': thread.threadId,
        'reply_to_message_id': '',
        'reply_to_text': '',
      });
    }

    final requestId = const Uuid().v4();
    final completer = Completer<String?>();
    _scheduledMessageCompleters[requestId] = completer;
    _socket.send({
      'type': 'scheduled_message_create',
      'packet_id': const Uuid().v4(),
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'chat_key': chatPreferenceKey(thread),
      'send_at': sendAt.toUtc().toIso8601String(),
      'repeat_interval': repeatInterval,
      'preview': trimmed,
      'payloads': payloads,
    });
    final result = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 'Server did not confirm the schedule',
    );
    _scheduledMessageCompleters.remove(requestId);
    return result;
  }

  Future<String?> cancelScheduledMessage(ScheduledMessageItem item) async {
    if (!_socket.isConnected) return 'No server connection';
    final requestId = const Uuid().v4();
    final completer = Completer<String?>();
    _scheduledMessageCompleters[requestId] = completer;
    _socket.send({
      'type': 'scheduled_message_cancel',
      'packet_id': const Uuid().v4(),
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'ttl': 5,
      'schedule_id': item.id,
    });
    final result = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 'Server did not confirm cancellation',
    );
    _scheduledMessageCompleters.remove(requestId);
    return result;
  }

  void _handleScheduledMessageResult(Map<String, dynamic> packet) {
    final action = packet['action']?.toString() ?? '';
    if (packet['ok'] == true) {
      if (action == 'create' && packet['item'] is Map) {
        final item = ScheduledMessageItem.fromJson(
          Map<String, dynamic>.from(packet['item'] as Map),
        );
        if (item.id.isNotEmpty) {
          scheduledMessages.removeWhere((existing) => existing.id == item.id);
          scheduledMessages.add(item);
        }
      } else if (action == 'cancel') {
        final id = packet['schedule_id']?.toString() ?? '';
        scheduledMessages.removeWhere((item) => item.id == id);
      }
    }
    final requestId = packet['request_id']?.toString() ?? '';
    final completer = _scheduledMessageCompleters[requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        packet['ok'] == true
            ? null
            : packet['reason']?.toString() ?? 'Schedule update failed',
      );
    }
    notifyListeners();
  }

  void _applyScheduledMessages(dynamic rawItems) {
    if (rawItems is! List) return;
    scheduledMessages
      ..clear()
      ..addAll(
        rawItems
            .whereType<Map>()
            .map(
              (raw) =>
                  ScheduledMessageItem.fromJson(Map<String, dynamic>.from(raw)),
            )
            .where((item) => item.id.isNotEmpty),
      )
      ..sort((a, b) => a.nextRunAt.compareTo(b.nextRunAt));
  }

  void _handleScheduledMessageSent(Map<String, dynamic> packet) {
    final id = packet['schedule_id']?.toString() ?? '';
    final repeat = packet['repeat_interval']?.toString() ?? 'none';
    if (repeat == 'none') {
      scheduledMessages.removeWhere((item) => item.id == id);
    } else {
      _socket.send({
        'type': 'scheduled_messages_request',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': 'SERVER',
        'ttl': 5,
      });
    }
    _scheduleSoftResync('Scheduled message sent: refreshing history');
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
    bool hd = false,
    int videoDurationSeconds = 0,
  }) async {
    if (session == null) return 'No active session';
    final trimmed = text.trim();
    if (trimmed.isEmpty && imageData.isEmpty && videoData.isEmpty) {
      return 'Story is empty';
    }
    final storyLimit =
        meshProSubscription.entitlements.limitFor('story_parallel_items') ?? 3;
    final ownActiveStories = stories.values
        .where((story) => story.ownerNode == myNodeId && !story.expired)
        .length;
    if (ownActiveStories >= storyLimit) {
      return 'Active story limit reached ($storyLimit)';
    }
    if (hd &&
        (!meshProSubscription.isActiveNow ||
            !meshProSubscription.entitlements.hasFeature('story_hd'))) {
      return 'HD stories require MeshPro';
    }
    final durationLimit =
        meshProSubscription.entitlements.limitFor('story_video_seconds') ?? 30;
    if (videoDurationSeconds > durationLimit) {
      return 'Story video can be up to $durationLimit seconds';
    }
    final story = StoryItem(
      id: const Uuid().v4(),
      ownerNode: myNodeId,
      ownerName: _publicOwnProfile.displayName,
      ownerAvatarData: _publicOwnProfile.avatarData,
      createdAt: DateTime.now(),
      text: trimmed,
      imageData: imageData,
      videoData: videoData,
      videoMime: videoMime,
      mediaType: mediaType,
      visibility: visibility,
      allowedNodeIds: selectedNodeIds,
      excludedNodeIds: excludedNodeIds,
      hd: hd,
      videoDurationSeconds: videoDurationSeconds,
    );
    stories[story.id] = story;
    storyArchive
      ..removeWhere((item) => item.id == story.id)
      ..insert(0, story);
    await _saveStories();
    await _saveStoryArchive();
    notifyListeners();

    final recipients = _storyRecipients(
      visibility: visibility,
      selectedNodeIds: selectedNodeIds,
      excludedNodeIds: excludedNodeIds,
    )..add('SERVER');
    final basePacket = {
      'type': 'story_update',
      'operation_id': 'story_update:${const Uuid().v4()}',
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
    await reactToStory(story, 'heart');
  }

  Future<void> reactToStory(StoryItem story, String reaction) async {
    if (session == null || story.ownerNode == myNodeId || story.expired) return;
    const allowed = {'heart', 'fire', 'laugh', 'wow', 'sad', 'clap'};
    if (!allowed.contains(reaction)) return;
    if (reaction != 'heart' &&
        (!meshProSubscription.isActiveNow ||
            !meshProSubscription.entitlements.hasFeature(
              'story_extra_reactions',
            ))) {
      return;
    }
    final current = stories[story.id] ?? story;
    final previousReaction = current.reactionFor(myNodeId);
    final nextReaction = previousReaction == reaction ? '' : reaction;
    final nextReactions = <String, List<String>>{
      for (final entry in current.reactions.entries)
        entry.key: entry.value.where((node) => node != myNodeId).toList(),
    }..removeWhere((_, reactors) => reactors.isEmpty);
    if (nextReaction.isNotEmpty) {
      nextReactions[nextReaction] = [...?nextReactions[nextReaction], myNodeId];
    }
    final nextLikes = nextReactions['heart'] ?? const <String>[];
    final updated = current.copyWith(
      reactions: nextReactions,
      likedByNodeIds: nextLikes,
    );
    stories[story.id] = updated;
    final archiveIndex = storyArchive.indexWhere((item) => item.id == story.id);
    if (archiveIndex >= 0) storyArchive[archiveIndex] = updated;
    await _saveStories();
    await _saveStoryArchive();
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
      'reaction': nextReaction.isEmpty ? reaction : nextReaction,
      'liked': nextReaction.isNotEmpty,
      'replace_existing': true,
    });
  }

  Future<void> replyToStory(StoryItem story, String text) async {
    if (session == null || story.ownerNode == myNodeId || story.expired) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final profile =
        profiles[story.ownerNode] ??
        Profile(nodeId: story.ownerNode, displayName: story.ownerName);
    await sendMessage(profile, trimmed, replyTo: _storyReplyMessage(story));
  }

  ChatMessage _storyReplyMessage(StoryItem story) {
    final preview = story.text.trim().isNotEmpty
        ? story.text.trim()
        : story.mediaType == StoryMediaType.video
        ? 'Story video'
        : story.mediaType == StoryMediaType.image
        ? 'Story photo'
        : 'Story';
    return ChatMessage(
      id: story.id,
      senderNode: story.ownerNode,
      receiverNode: myNodeId,
      text: 'Story: $preview',
      createdAt: story.createdAt,
    );
  }

  Future<void> hideStoriesFrom(String ownerNode) async {
    if (ownerNode.isEmpty || ownerNode == myNodeId) return;
    hiddenStoryOwners.add(ownerNode);
    await _storyStore.saveHiddenOwners(session, hiddenStoryOwners);
    notifyListeners();
  }

  Future<void> unhideStoriesFrom(String ownerNode) async {
    if (!hiddenStoryOwners.remove(ownerNode)) return;
    await _storyStore.saveHiddenOwners(session, hiddenStoryOwners);
    notifyListeners();
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
    storyArchive.removeWhere((item) => item.id == story.id);
    await _saveStoryArchive();
    notifyListeners();

    final recipients = _storyRecipients(
      visibility: story.visibility,
      selectedNodeIds: story.allowedNodeIds,
      excludedNodeIds: story.excludedNodeIds,
    )..add('SERVER');
    final basePacket = {
      'type': 'story_delete',
      'operation_id': 'story_delete:${const Uuid().v4()}',
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
      if (story.ownerNode == myNodeId) {
        storyArchive.removeWhere((item) => item.id == story.id);
        storyArchive.add(story);
      }
      changed = true;
    }
    final before = stories.length;
    stories.removeWhere((storyId, story) => !incomingIds.contains(storyId));
    if (before != stories.length) changed = true;
    if (changed) {
      storyArchive.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _saveStories();
      await _saveStoryArchive();
    }
  }

  Future<void> _applyStoryArchive(dynamic rawArchive) async {
    if (rawArchive is! List) return;
    final merged = <String, StoryItem>{
      for (final story in storyArchive) story.id: story,
    };
    for (final raw in rawArchive) {
      if (raw is! Map) continue;
      final story = StoryItem.fromJson(Map<String, dynamic>.from(raw));
      if (story.id.isEmpty || story.ownerNode != myNodeId) continue;
      merged[story.id] = story;
    }
    storyArchive
      ..clear()
      ..addAll(merged.values)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _saveStoryArchive();
  }

  Future<void> _applyStoryReactionPacket(Map<String, dynamic> packet) async {
    final storyId = packet['story_id']?.toString() ?? '';
    final reactor = packet['source_node']?.toString() ?? '';
    if (storyId.isEmpty || reactor.isEmpty || isBlocked(reactor)) return;
    final story = stories[storyId];
    if (story == null) return;
    final liked = packet['liked'] != false;
    final reaction = packet['reaction']?.toString() ?? 'heart';
    final nextReactions = <String, List<String>>{
      for (final entry in story.reactions.entries)
        entry.key: entry.value.where((nodeId) => nodeId != reactor).toList(),
    }..removeWhere((_, reactors) => reactors.isEmpty);
    if (liked) {
      nextReactions[reaction] = [...?nextReactions[reaction], reactor];
    }
    final updated = story.copyWith(
      reactions: nextReactions,
      likedByNodeIds: nextReactions['heart'] ?? const <String>[],
    );
    stories[storyId] = updated;
    final archiveIndex = storyArchive.indexWhere((item) => item.id == storyId);
    if (archiveIndex >= 0) {
      storyArchive[archiveIndex] = updated;
      await _saveStoryArchive();
    }
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
    final archiveIndex = storyArchive.indexWhere((item) => item.id == storyId);
    if (archiveIndex >= 0) {
      storyArchive[archiveIndex] = storyArchive[archiveIndex].copyWith(
        viewedByNodeIds: [
          ...storyArchive[archiveIndex].viewedByNodeIds,
          viewer,
        ],
      );
      await _saveStoryArchive();
    }
    await _saveStories();
  }

  Future<void> _applyStoryDeletePacket(Map<String, dynamic> packet) async {
    final storyId = packet['story_id']?.toString() ?? '';
    final source = packet['source_node']?.toString() ?? '';
    if (storyId.isEmpty || source.isEmpty) return;
    final story = stories[storyId];
    if (story == null || story.ownerNode != source) return;
    stories.remove(storyId);
    storyArchive.removeWhere((item) => item.id == storyId);
    await _saveStoryArchive();
    await _saveStories();
  }

  Future<void> _loadStories() async {
    final current = session;
    stories.clear();
    storyArchive.clear();
    hiddenStoryOwners.clear();
    if (current == null) return;
    stories.addAll(await _storyStore.load(current));
    storyArchive.addAll(await _storyStore.loadArchive(current));
    hiddenStoryOwners.addAll(await _storyStore.loadHiddenOwners(current));
    await _pruneStories();
  }

  Future<void> _saveStories() async {
    await _storyStore.save(session, stories.values);
  }

  Future<void> _saveStoryArchive() async {
    await _storyStore.saveArchive(session, storyArchive);
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
    if (thread.isBluetooth) {
      for (final message in thread.messages) {
        await ble.cancelQueuedMessage(message.id);
      }
    }
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
        _groupKeyHistory.remove(thread.groupId);
      } else {
        groups.removeWhere(
          (_, group) =>
              identical(group, thread) ||
              _looksLikeSameBrokenGroup(group, thread),
        );
      }
    } else {
      threads.removeWhere((key, value) => identical(value, thread));
      if (!threads.values.any(
        (item) => item.profile.nodeId == thread.profile.nodeId,
      )) {
        profiles.remove(thread.profile.nodeId);
      }
    }
    final activityKey = thread.isGroup ? thread.groupId : thread.storageKey;
    typingUntil.remove(activityKey);
    activityKinds.remove(activityKey);
    await _rewriteCache();
    notifyListeners();
  }

  Future<String?> deleteThreadForEveryone(ChatThread thread) async {
    if (session == null) return 'No active session';
    if (thread.isBluetooth) {
      await _sendBluetoothThreadPacket(thread, {'type': 'chat_delete'});
      await deleteThread(thread);
      return null;
    }
    if (thread.isGroup && !_ownsGroup(thread)) {
      return thread.isChannel
          ? 'Only channel owner can delete it'
          : 'Only group owner can delete it';
    }
    final packetBase = {
      'type': thread.isGroup ? 'group_delete' : 'chat_delete',
      'operation_id':
          '${thread.isGroup ? 'group_delete' : 'chat_delete'}:'
          '${const Uuid().v4()}',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': thread.groupId,
      'chat_node_id': thread.profile.nodeId,
      'chat_kind': thread.chatKind,
      'chat_id': thread.threadId,
    };
    final recipients = thread.isGroup ? {'SERVER'} : {thread.profile.nodeId};
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
    final packetBase = {
      'type': 'group_member_leave',
      'operation_id': 'group_member_leave:${const Uuid().v4()}',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': groupId,
      'group_name': group.profile.displayName,
      'is_channel': group.isChannel,
      'leaver_node': myNodeId,
      'members': remaining,
      'owner_node': group.ownerNode,
      'admins': group.admins.where((admin) => admin != myNodeId).toList(),
    };
    final recipients = {
      ...remaining,
      if (group.ownerNode.isNotEmpty) group.ownerNode,
      'SERVER',
    }..remove(myNodeId);
    for (final recipient in recipients) {
      _socket.send({
        ...packetBase,
        'packet_id': const Uuid().v4(),
        'destination_node': recipient,
      });
    }
    await _rememberDeletedGroup(groupId);
    groups.remove(groupId);
    _groupKeys.remove(groupId);
    _groupKeyHistory.remove(groupId);
    typingUntil.remove(groupId);
    activityKinds.remove(groupId);
    await _rewriteCache();
    notifyListeners();
    return null;
  }

  Future<void> _applyGroupMemberLeavePacket(Map<String, dynamic> packet) async {
    final groupId = packet['group_id']?.toString() ?? '';
    final leaver =
        packet['leaver_node']?.toString() ??
        packet['source_node']?.toString() ??
        '';
    if (groupId.isEmpty || leaver.isEmpty || leaver == myNodeId) return;
    final group = groups[groupId];
    if (group == null || !group.members.contains(leaver)) return;
    group.members.removeWhere((member) => member == leaver);
    group.admins.removeWhere((admin) => admin == leaver);
    typingUntil.remove(groupId);
    activityKinds.remove(groupId);
    await _saveCache();
    notifyListeners();
  }

  bool _ownsGroup(ChatThread thread) {
    if (!thread.isGroup) return false;
    final owner = thread.ownerNode.trim();
    return owner == myNodeId;
  }

  Future<void> _applyThreadDeletePacket(Map<String, dynamic> packet) async {
    final source = packet['source_node']?.toString() ?? '';
    if (source.isEmpty || source == myNodeId || isBlocked(source)) return;
    final groupId = packet['group_id']?.toString() ?? '';
    if (groupId.isNotEmpty) {
      final group = groups[groupId];
      if (group == null) return;
      final owner = group.ownerNode.trim();
      if (source != owner && !group.members.contains(source)) return;
      if (owner.isNotEmpty && source != owner) return;
      await _rememberDeletedGroup(groupId);
      groups.remove(groupId);
      _groupKeys.remove(groupId);
      _groupKeyHistory.remove(groupId);
      typingUntil.remove(groupId);
      activityKinds.remove(groupId);
    } else {
      final chatNodeId = packet['chat_node_id']?.toString() ?? source;
      final chatId = packet['chat_id']?.toString() ?? '';
      final chatKind = packet['chat_kind']?.toString() ?? 'normal';
      final thread = chatKind == 'bluetooth'
          ? threads['bluetooth:$source']
          : chatId.isNotEmpty
          ? threads[chatId]
          : (threads[chatNodeId] ?? threads[source]);
      if (thread == null) return;
      threads.removeWhere((_, value) => identical(value, thread));
      if (!threads.values.any(
        (item) => item.profile.nodeId == thread.profile.nodeId,
      )) {
        profiles.remove(thread.profile.nodeId);
      }
      typingUntil.remove(thread.storageKey);
      activityKinds.remove(thread.storageKey);
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

  Future<void> _forgetDeletedGroup(String groupId) async {
    if (groupId.isEmpty || !appSettings.deletedGroupIds.contains(groupId)) {
      return;
    }
    final deleted = appSettings.deletedGroupIds
        .where((deletedGroupId) => deletedGroupId != groupId)
        .toList();
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
    if (thread.isChannel) return;
    final basePacket = {
      'type': 'typing',
      'packet_id': const Uuid().v4(),
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 2,
      'sender': session!.login,
      'group_id': thread.groupId,
      'chat_kind': thread.chatKind,
      'chat_id': thread.threadId,
      'activity': kind,
    };
    if (thread.isBluetooth) {
      unawaited(
        _sendBluetoothThreadPacket(thread, {
          'type': 'typing',
          'activity': kind,
        }),
      );
      return;
    }
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
    if (groupId.isNotEmpty && groups[groupId]?.isChannel == true) return;
    final chatId = packet['chat_id']?.toString() ?? '';
    final chatKind = packet['chat_kind']?.toString() ?? 'normal';
    final key = groupId.isNotEmpty
        ? groupId
        : chatKind == 'bluetooth'
        ? 'direct:bluetooth:$source'
        : chatId.isNotEmpty
        ? 'direct:$chatId'
        : 'direct:normal:$source';
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
      text = await _crypto.decryptGroupText(
        _groupKeyForPacket(groupId, packet['group_key_id']?.toString() ?? ''),
        text,
      );
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
      if (_deleteLocalMessage(thread, messageId)) {
        notifyListeners();
        return;
      }
    }
    notifyListeners();
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

  ChatThread? threadForProfile(Profile profile) {
    return threads[profile.nodeId];
  }

  ChatThread? bluetoothThreadForNode(String nodeId) {
    return threads['bluetooth:$nodeId'];
  }

  BlePeer? bluetoothPeerForNode(String nodeId) {
    final normalized = nodeId.trim();
    if (normalized.isEmpty) return null;
    for (final peer in ble.peers) {
      if (peer.nodeId == normalized) return peer;
    }
    return null;
  }

  Future<ChatThread> ensureSecretThread(Profile profile, String code) async {
    final normalizedCode = _normalizeSecretCode(code);
    if (normalizedCode.isEmpty) {
      return _ensureThread(profile);
    }
    final threadIds = await _secretThreadIds(profile, normalizedCode);
    final mergedProfile = _mergeProfile(profile);
    for (final threadId in threadIds) {
      final existing = threads[threadId];
      if (existing != null) {
        existing.profile = mergedProfile;
        return existing;
      }
    }
    final threadId = threadIds.first;
    final thread = ChatThread(
      profile: mergedProfile,
      threadId: threadId,
      chatKind: 'secret',
      accessCode: normalizedCode,
      muted: true,
    );
    threads[threadId] = thread;
    unawaited(_saveCache());
    notifyListeners();
    return thread;
  }

  ChatThread _ensureBluetoothThread(Profile profile) {
    final mergedProfile = _mergeProfile(profile, online: true);
    final threadId = 'bluetooth:${profile.nodeId}';
    final existing = threads[threadId];
    if (existing != null) {
      existing.profile = mergedProfile;
      return existing;
    }
    final thread = ChatThread(
      profile: mergedProfile,
      threadId: threadId,
      chatKind: 'bluetooth',
    );
    threads[threadId] = thread;
    return thread;
  }

  ChatThread _ensurePacketThread(Profile profile, Map<String, dynamic> data) {
    final chatKind = data['chat_kind']?.toString() ?? 'normal';
    final chatId = data['chat_id']?.toString() ?? '';
    if (chatKind == 'secret' && chatId.isNotEmpty) {
      final existing = threads[chatId];
      final mergedProfile = _mergeProfile(profile);
      if (existing != null) {
        existing.profile = mergedProfile;
        return existing;
      }
      final thread = ChatThread(
        profile: mergedProfile,
        threadId: chatId,
        chatKind: 'secret',
        muted: true,
      );
      threads[chatId] = thread;
      return thread;
    }
    if (chatKind == 'bluetooth') {
      return _ensureBluetoothThread(profile);
    }
    return _ensureThread(profile);
  }

  String _normalizeSecretCode(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  }

  Future<List<String>> _secretThreadIds(Profile profile, String code) async {
    final result = <String>[];
    final ownLogin = session?.login.trim().toLowerCase() ?? '';
    final peerLogin = profile.accountLogin.trim().toLowerCase();
    if (ownLogin.isNotEmpty && peerLogin.isNotEmpty) {
      result.add(
        await _secretThreadId('meshchat-secret-v2', ownLogin, peerLogin, code),
      );
    }

    final ownNodes = <String>{myNodeId, ...ownProfile.nodeAliases}
      ..removeWhere((value) => value.isEmpty);
    final peerNodes = <String>{profile.nodeId, ...profile.nodeAliases}
      ..removeWhere((value) => value.isEmpty);
    for (final ownNode in ownNodes) {
      for (final peerNode in peerNodes) {
        final legacyId = await _secretThreadId(
          'meshchat-secret-v1',
          ownNode,
          peerNode,
          code,
        );
        if (!result.contains(legacyId)) result.add(legacyId);
      }
    }
    if (result.isEmpty) {
      result.add(
        await _secretThreadId(
          'meshchat-secret-v1',
          myNodeId,
          profile.nodeId,
          code,
        ),
      );
    }
    return result;
  }

  Future<String> _secretThreadId(
    String version,
    String firstIdentity,
    String secondIdentity,
    String code,
  ) async {
    final identities = [firstIdentity, secondIdentity]..sort();
    final digest = await Sha256().hash(
      utf8.encode('$version:${identities.join(':')}:$code'),
    );
    return 'secret:${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  bool _meshProCallFeatureEnabled(String featureId, bool preference) {
    return preference &&
        meshProSubscription.isActiveNow &&
        meshProSubscription.entitlements.hasFeature(featureId);
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
    final hdAudio = _meshProCallFeatureEnabled(
      'call_hd_audio',
      appSettings.meshProHdAudio,
    );
    final enhancedNoiseSuppression = _meshProCallFeatureEnabled(
      'call_noise_suppression_plus',
      appSettings.meshProEnhancedNoiseSuppression,
    );
    final call = ActiveCall(
      callId: const Uuid().v4(),
      peer: recipient,
      status: CallStatus.outgoing,
      incoming: false,
      startedAt: DateTime.now(),
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
    );
    _setActiveCall(call);
    notifyListeners();
    final offerSdp = await _calls
        .startOutgoing(
          onIceCandidate: (candidate) => _sendCallIce(call, candidate),
          hdAudio: hdAudio,
          enhancedNoiseSuppression: enhancedNoiseSuppression,
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
      'hd_audio': hdAudio,
      'enhanced_noise_suppression': enhancedNoiseSuppression,
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
    final hdAudio = _meshProCallFeatureEnabled(
      'call_hd_audio',
      appSettings.meshProHdAudio,
    );
    final enhancedNoiseSuppression = _meshProCallFeatureEnabled(
      'call_noise_suppression_plus',
      appSettings.meshProEnhancedNoiseSuppression,
    );
    final call = ActiveCall(
      callId: const Uuid().v4(),
      peer: thread.profile,
      status: CallStatus.outgoing,
      incoming: false,
      startedAt: DateTime.now(),
      isGroup: true,
      groupId: thread.groupId,
      groupMembers: recipients,
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
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
            hdAudio: hdAudio,
            enhancedNoiseSuppression: enhancedNoiseSuppression,
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
        'hd_audio': hdAudio,
        'enhanced_noise_suppression': enhancedNoiseSuppression,
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
    unawaited(CallAlertService.stopAll());
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
          hdAudio: call.hdAudio,
          enhancedNoiseSuppression: call.enhancedNoiseSuppression,
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
    unawaited(CallAlertService.stopAll());
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
    unawaited(CallAlertService.stopAll());
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

  bool get canShareCallScreen {
    final call = activeCall;
    return call != null &&
        call.status == CallStatus.active &&
        !call.isGroup &&
        meshProSubscription.isActiveNow &&
        meshProSubscription.entitlements.hasFeature('call_screen_share');
  }

  Widget buildRemoteCallScreen() => _calls.remoteScreenView();

  Future<String?> toggleCallScreenShare() async {
    final call = activeCall;
    if (call == null || call.status != CallStatus.active) {
      return 'Start the call before sharing your screen';
    }
    if (call.isGroup) {
      return 'Screen sharing is currently available in direct calls';
    }
    if (!meshProSubscription.isActiveNow ||
        !meshProSubscription.entitlements.hasFeature('call_screen_share')) {
      return 'Screen sharing requires MeshPro';
    }
    if (call.screenSharing) {
      await _calls.stopScreenShare().catchError((_) {});
      _setActiveCall(call.copyWith(screenSharing: false));
      _socket.send({
        'type': 'call_screen_stop',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': call.peer.nodeId,
        'ttl': 5,
        'call_id': call.callId,
      });
      notifyListeners();
      return null;
    }
    try {
      final offerSdp = await _calls.startScreenShare();
      if (offerSdp.isEmpty) return 'Screen capture did not start';
      _setActiveCall(call.copyWith(screenSharing: true));
      _socket.send({
        'type': 'call_screen_offer',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': call.peer.nodeId,
        'ttl': 5,
        'call_id': call.callId,
        'sdp': offerSdp,
      });
      notifyListeners();
      return null;
    } catch (error) {
      await _calls.stopScreenShare().catchError((_) {});
      return 'Could not share the screen: $error';
    }
  }

  void _handleRemoteScreenChanged() {
    final call = activeCall;
    if (call == null || call.status == CallStatus.ended) return;
    final remoteSharing = _calls.hasRemoteScreen;
    if (call.remoteScreenSharing == remoteSharing) return;
    _setActiveCall(call.copyWith(remoteScreenSharing: remoteSharing));
    notifyListeners();
  }

  void _handleLocalScreenEnded() {
    final call = activeCall;
    if (call == null || !call.screenSharing) return;
    unawaited(toggleCallScreenShare());
  }

  Future<void> refreshCallAudioDevices() async {
    final inputs = await _calls.audioInputs().catchError(
      (_) => const <CallAudioDevice>[],
    );
    final outputs = await _calls.audioOutputs().catchError(
      (_) => const <CallAudioDevice>[],
    );
    callAudioInputs = inputs;
    callAudioOutputs = outputs;
    notifyListeners();
  }

  Future<void> selectCallAudioInput(String deviceId) async {
    await _calls.selectAudioInput(deviceId).catchError((_) {});
    for (final service in _groupCalls.values) {
      await service.selectAudioInput(deviceId).catchError((_) {});
    }
  }

  Future<void> selectCallAudioOutput(String deviceId) async {
    await _calls.selectAudioOutput(deviceId).catchError((_) {});
    for (final service in _groupCalls.values) {
      await service.selectAudioOutput(deviceId).catchError((_) {});
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
    unawaited(CallAlertService.stopAll());
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
          accountLogin:
              packet['sender_login']?.toString() ??
              packet['sender']?.toString() ??
              '',
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
        hdAudio: _meshProCallFeatureEnabled(
          'call_hd_audio',
          appSettings.meshProHdAudio,
        ),
        enhancedNoiseSuppression: _meshProCallFeatureEnabled(
          'call_noise_suppression_plus',
          appSettings.meshProEnhancedNoiseSuppression,
        ),
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
    unawaited(CallAlertService.stopAll());
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

  Future<void> _handleCallScreenOffer(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null || call.isGroup || call.status != CallStatus.active) {
      return;
    }
    if (packet['call_id']?.toString() != call.callId) return;
    final source = packet['source_node']?.toString() ?? '';
    final offerSdp = packet['sdp']?.toString() ?? '';
    if (source.isEmpty || offerSdp.isEmpty) return;
    try {
      final answerSdp = await _calls.acceptScreenShareOffer(offerSdp);
      _setActiveCall(call.copyWith(remoteScreenSharing: true));
      _socket.send({
        'type': 'call_screen_answer',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': source,
        'ttl': 5,
        'call_id': call.callId,
        'sdp': answerSdp,
      });
      notifyListeners();
    } catch (error) {
      addDiagnostic('call', 'Screen offer failed: $error');
    }
  }

  Future<void> _handleCallScreenAnswer(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null || call.isGroup || !call.screenSharing) return;
    if (packet['call_id']?.toString() != call.callId) return;
    final answerSdp = packet['sdp']?.toString() ?? '';
    if (answerSdp.isEmpty) return;
    await _calls.applyScreenShareAnswer(answerSdp).catchError((error) {
      addDiagnostic('call', 'Screen answer failed: $error');
    });
  }

  Future<void> _handleCallScreenStop(Map<String, dynamic> packet) async {
    final call = activeCall;
    if (call == null || packet['call_id']?.toString() != call.callId) return;
    await _calls.clearRemoteScreen().catchError((_) {});
    _setActiveCall(call.copyWith(remoteScreenSharing: false));
    notifyListeners();
  }

  String _replyPreview(ChatMessage message) {
    if (message.kind == ChatMessageKind.sticker) {
      return message.text.isEmpty ? 'Sticker' : message.text;
    }
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
    ChatThread? threadOverride,
    ChatMessage? retryingMessage,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || session == null) return;
    if (threadOverride?.isBluetooth == true) {
      final sendError = await sendBluetoothMessageToThread(
        threadOverride!,
        trimmed,
        replyTo: replyTo,
      );
      if (sendError != null) addDiagnostic('bluetooth', sendError);
      return;
    }
    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final thread = threadOverride ?? _ensureThread(recipient);
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
          messageEffect: messageEffect,
          delivered: true,
        ),
      );
      unawaited(_saveCache());
      notifyListeners();
      return;
    }
    final outgoing =
        retryingMessage?.copyWith(
          pending: true,
          delivered: false,
          failed: false,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: recipient.nodeId,
          text: trimmed,
          createdAt: DateTime.now(),
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(thread, outgoing);
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
      'chat_kind': thread.chatKind,
      'chat_id': thread.threadId,
      'reply_to_message_id': replyToMessageId,
      'reply_to_text': replyToText,
      'message_effect': messageEffect,
    });
    if (!_socket.supportsMutationAck) {
      _replaceMessage(id, (message) => message.copyWith(pending: false));
    }
  }

  Future<String?> startBluetoothNearby() async {
    final current = session;
    if (current == null) return 'No active session';
    await _initializeCryptoForSession(current);
    try {
      await ble.start(profile: _publicOwnProfile, publicKey: _crypto.publicKey);
      return null;
    } catch (error) {
      return 'Bluetooth start failed: $error';
    }
  }

  Future<void> stopBluetoothNearby() => ble.stop();

  Future<String?> sendBluetoothMessage(
    BlePeer peer,
    String text, {
    ChatMessage? replyTo,
    ChatMessage? retryingMessage,
  }) async {
    final current = session;
    final trimmed = text.trim();
    if (current == null) return 'No active session';
    if (trimmed.isEmpty) return null;
    final startError = await _ensureBluetoothReadyForSend();
    if (startError != null) return startError;
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
    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final thread = _ensureBluetoothThread(recipient);
    final createdAt = retryingMessage?.createdAt ?? DateTime.now();
    final outgoing =
        retryingMessage?.copyWith(
          pending: true,
          delivered: false,
          failed: false,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: recipient.nodeId,
          text: trimmed,
          createdAt: createdAt,
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(thread, outgoing);
    unawaited(_saveCache());
    notifyListeners();
    final wireText = await _crypto.encryptText(recipient.publicKey, trimmed);
    try {
      final packet = {
        'type': 'chat_message',
        'packet_id': id,
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': recipient.nodeId,
        'ttl': 1,
        'sender': current.login,
        'message': wireText,
        'reply_to_message_id': replyToMessageId,
        'reply_to_text': replyToText,
        'message_effect': messageEffect,
        'chat_kind': thread.chatKind,
        'chat_id': thread.threadId,
        'created_at': createdAt.toUtc().toIso8601String(),
      };
      final result = connectedPeer.id.isEmpty
          ? await ble.sendPacketToNode(recipient.nodeId, packet)
          : await ble.sendPacket(connectedPeer, packet);
      _replaceMessage(
        id,
        (message) => message.copyWith(
          pending: result == BleSendResult.queued,
          failed: false,
        ),
      );
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
    ChatMessage? replyTo,
    ChatMessageKind kind = ChatMessageKind.file,
    ChatMessage? retryingMessage,
  }) async {
    final current = session;
    if (current == null) return 'No active session';
    if (bytes.isEmpty) return 'File is empty';
    if (bytes.length > maxBluetoothFileBytes) {
      return 'Bluetooth files are limited to 512 KB';
    }
    final startError = await _ensureBluetoothReadyForSend();
    if (startError != null) return startError;
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

    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final trimmedCaption = caption.trim();
    final data = _hexEncode(bytes);
    final thread = _ensureBluetoothThread(recipient);
    final createdAt = retryingMessage?.createdAt ?? DateTime.now();
    final outgoing =
        retryingMessage?.copyWith(
          pending: true,
          delivered: false,
          failed: false,
          progress: 0,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: recipient.nodeId,
          text: trimmedCaption,
          createdAt: createdAt,
          kind: kind,
          fileName: filename,
          fileData: data,
          fileSize: bytes.length,
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(thread, outgoing);
    unawaited(_saveCache());
    notifyListeners();

    final totalChunks = (data.length / _bluetoothFileChunkHexSize).ceil();
    var queued = false;
    try {
      for (var index = 0; index < totalChunks; index++) {
        final start = index * _bluetoothFileChunkHexSize;
        final end = min(data.length, start + _bluetoothFileChunkHexSize);
        final packet = {
          'type': 'file_chunk',
          'packet_id': const Uuid().v4(),
          'protocol_version': MeshSocket.protocolVersion,
          'source_node': myNodeId,
          'destination_node': recipient.nodeId,
          'ttl': 1,
          'sender': current.login,
          'chat_kind': thread.chatKind,
          'chat_id': thread.threadId,
          'file_id': id,
          'message_kind': kind.name,
          'filename': filename,
          'caption': trimmedCaption,
          'reply_to_message_id': replyToMessageId,
          'reply_to_text': replyToText,
          'message_effect': messageEffect,
          'chunk_index': index,
          'total_chunks': totalChunks,
          'data': data.substring(start, end),
          'created_at': createdAt.toUtc().toIso8601String(),
        };
        final result = connectedPeer.id.isEmpty
            ? await ble.sendPacketToNode(recipient.nodeId, packet)
            : await ble.sendPacket(connectedPeer, packet);
        queued = queued || result == BleSendResult.queued;
      }
      _replaceMessage(
        id,
        (message) => message.copyWith(
          pending: queued,
          failed: false,
          progress: queued ? message.progress : 1,
        ),
      );
      return null;
    } catch (error) {
      _replaceMessage(id, (message) => message.copyWith(failed: true));
      return 'Bluetooth file send failed: $error';
    }
  }

  Future<String?> sendBluetoothMessageToThread(
    ChatThread thread,
    String text, {
    ChatMessage? replyTo,
    ChatMessage? retryingMessage,
  }) {
    if (!thread.isBluetooth) {
      return Future<String?>.value('This is not a Bluetooth chat');
    }
    return sendBluetoothMessage(
      bluetoothPeerForNode(thread.profile.nodeId) ??
          _cachedBluetoothPeer(thread.profile),
      text,
      replyTo: replyTo,
      retryingMessage: retryingMessage,
    );
  }

  Future<String?> sendBluetoothFileToThread(
    ChatThread thread,
    String filename,
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
    ChatMessageKind kind = ChatMessageKind.file,
    ChatMessage? retryingMessage,
  }) {
    if (!thread.isBluetooth) {
      return Future<String?>.value('This is not a Bluetooth chat');
    }
    return sendBluetoothFile(
      bluetoothPeerForNode(thread.profile.nodeId) ??
          _cachedBluetoothPeer(thread.profile),
      filename,
      bytes,
      caption: caption,
      replyTo: replyTo,
      kind: kind,
      retryingMessage: retryingMessage,
    );
  }

  BlePeer _cachedBluetoothPeer(Profile profile) => BlePeer(
    id: '',
    name: profile.displayName,
    nodeId: profile.nodeId,
    displayName: profile.displayName,
    publicUsername: profile.publicUsername,
    publicKey: profile.publicKey,
  );

  Future<String?> _ensureBluetoothReadyForSend() async {
    if (ble.running) return null;
    return startBluetoothNearby();
  }

  Future<BleSendResult?> _sendBluetoothThreadPacket(
    ChatThread thread,
    Map<String, dynamic> payload,
  ) async {
    if (!thread.isBluetooth || thread.profile.nodeId.isEmpty) return null;
    final startError = await _ensureBluetoothReadyForSend();
    if (startError != null) {
      addDiagnostic('bluetooth', startError);
      return null;
    }
    try {
      return await ble.sendPacketToNode(thread.profile.nodeId, {
        ...payload,
        'packet_id': payload['packet_id'] ?? const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': thread.profile.nodeId,
        'ttl': 1,
        'sender': session?.login ?? '',
        'chat_kind': 'bluetooth',
        'chat_id': '',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (error) {
      addDiagnostic('bluetooth', 'Bluetooth action failed: $error');
      return null;
    }
  }

  Future<String?> sendFile(
    Profile recipient,
    String filename,
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
    ChatThread? threadOverride,
    ChatMessageKind kind = ChatMessageKind.file,
    ChatMessage? retryingMessage,
  }) async {
    if (session == null) return 'Нет активной сессии';
    if (threadOverride?.isBluetooth == true) {
      return sendBluetoothFileToThread(
        threadOverride!,
        filename,
        bytes,
        caption: caption,
        replyTo: replyTo,
        kind: kind,
        retryingMessage: retryingMessage,
      );
    }
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) {
      return 'Файл больше 64 МБ';
    }

    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final data = _hexEncode(bytes);
    final trimmedCaption = caption.trim();
    final thread = threadOverride ?? _ensureThread(recipient);
    final createdAt = retryingMessage?.createdAt ?? DateTime.now();
    if (isSavedMessagesProfile(recipient)) {
      thread.messages.add(
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: savedMessagesNodeId,
          text: trimmedCaption,
          createdAt: createdAt,
          kind: kind,
          fileName: filename,
          fileData: data,
          fileSize: bytes.length,
          replyToMessageId: replyTo?.id ?? '',
          replyToText: replyTo == null ? '' : _replyPreview(replyTo),
          messageEffect: messageEffect,
          delivered: true,
          progress: 1,
        ),
      );
      unawaited(_saveCache());
      notifyListeners();
      return null;
    }
    final outgoing =
        retryingMessage?.copyWith(
          pending: true,
          delivered: false,
          failed: false,
          progress: 0,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: recipient.nodeId,
          text: trimmedCaption,
          createdAt: DateTime.now(),
          kind: kind,
          fileName: filename,
          fileData: data,
          fileSize: bytes.length,
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(thread, outgoing);
    unawaited(_saveCache());
    notifyListeners();
    final operationId = 'file_transfer:$id';
    try {
      await _socket.queueFileTransfer(
        transferId: const Uuid().v4(),
        operationId: operationId,
        bytes: bytes,
        packet: {
          'type': 'file_chunk',
          'protocol_version': MeshSocket.protocolVersion,
          'source_node': myNodeId,
          'destination_node': recipient.nodeId,
          'ttl': 5,
          'sender': session!.login,
          'chat_kind': thread.chatKind,
          'chat_id': thread.threadId,
          'file_id': id,
          'message_kind': kind.name,
          'filename': filename,
          'caption': trimmedCaption,
          'reply_to_message_id': replyToMessageId,
          'reply_to_text': replyToText,
          'message_effect': messageEffect,
          'created_at': createdAt.toUtc().toIso8601String(),
        },
      );
      if (!_socket.isConnected) {
        status = 'Queued: waiting for server connection';
        notifyListeners();
      }
      return null;
    } catch (error) {
      _replaceMessage(
        id,
        (message) => message.copyWith(pending: false, failed: true),
      );
      return 'File queue failed: $error';
    }
  }

  Future<String?> forwardMessage(ChatMessage message, ChatThread target) async {
    if (session == null) return 'No active session';
    if (message.deleted) return 'Message was deleted';
    if (message.kind == ChatMessageKind.file ||
        message.kind == ChatMessageKind.sticker) {
      if (message.fileData.isEmpty) return 'File is not cached';
      final filename = message.fileName.isEmpty
          ? 'meshchat_file'
          : message.fileName;
      final bytes = _hexDecode(message.fileData);
      return target.isBluetooth
          ? sendBluetoothFileToThread(
              target,
              filename,
              bytes,
              caption: message.text,
              kind: message.kind,
            )
          : target.isGroup
          ? sendGroupFile(
              target,
              filename,
              bytes,
              caption: message.text,
              kind: message.kind,
            )
          : sendFile(
              target.profile,
              filename,
              bytes,
              caption: message.text,
              kind: message.kind,
            );
    }
    final text = message.text.trim();
    if (text.isEmpty) return 'Message is empty';
    if (target.isBluetooth) {
      return sendBluetoothMessageToThread(target, text);
    } else if (target.isGroup) {
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
    if (message.kind == ChatMessageKind.file ||
        message.kind == ChatMessageKind.sticker) {
      if (message.fileData.isEmpty) return 'File is not cached';
      final filename = message.fileName.isEmpty
          ? 'meshchat_file'
          : message.fileName;
      final bytes = _hexDecode(message.fileData);
      return sendFile(
        target.profile,
        filename,
        bytes,
        caption: message.text,
        kind: message.kind,
      );
    }
    final text = message.text.trim();
    if (text.isEmpty) return 'Message is empty';
    await sendMessage(target.profile, text);
    return null;
  }

  Future<String?> retryMessage(ChatThread thread, ChatMessage message) async {
    if (!message.failed && !message.pending) return null;
    if (!_resendingMessageIds.add(message.id)) {
      return 'Message is already being retried';
    }
    try {
      if (!thread.isBluetooth &&
          (message.kind == ChatMessageKind.file ||
              message.kind == ChatMessageKind.sticker) &&
          await _socket.hasQueuedFileTransfer(message.id)) {
        _replaceMessage(
          message.id,
          (current) => current.copyWith(pending: true, failed: false),
        );
        await _socket.retryFileTransfer(message.id);
        return null;
      }
      if (message.kind == ChatMessageKind.file ||
          message.kind == ChatMessageKind.sticker) {
        if (message.fileData.isEmpty) return 'File is not cached';
      }
      if (thread.isBluetooth) {
        await ble.cancelQueuedMessage(message.id);
        if (message.kind == ChatMessageKind.file ||
            message.kind == ChatMessageKind.sticker) {
          return sendBluetoothFileToThread(
            thread,
            message.fileName.isEmpty ? message.text : message.fileName,
            _hexDecode(message.fileData),
            caption: message.text,
            kind: message.kind,
            retryingMessage: message,
          );
        }
        return sendBluetoothMessageToThread(
          thread,
          message.text,
          retryingMessage: message,
        );
      }
      if (message.kind == ChatMessageKind.file ||
          message.kind == ChatMessageKind.sticker) {
        final bytes = _hexDecode(message.fileData);
        final filename = message.fileName.isEmpty
            ? message.text
            : message.fileName;
        return thread.isGroup
            ? sendGroupFile(
                thread,
                filename,
                bytes,
                caption: message.text,
                kind: message.kind,
                retryingMessage: message,
              )
            : sendFile(
                thread.profile,
                filename,
                bytes,
                caption: message.text,
                threadOverride: thread,
                kind: message.kind,
                retryingMessage: message,
              );
      }
      if (thread.isGroup) {
        await sendGroupMessage(thread, message.text, retryingMessage: message);
      } else {
        await sendMessage(
          thread.profile,
          message.text,
          threadOverride: thread,
          retryingMessage: message,
        );
      }
      return null;
    } finally {
      _resendingMessageIds.remove(message.id);
    }
  }

  Future<void> _retryQueuedMessages() async {
    if (_retryingQueuedMessages || session == null || !_socket.isConnected) {
      return;
    }
    _retryingQueuedMessages = true;
    try {
      final queued = <({ChatThread thread, ChatMessage message})>[];
      final seenMessageIds = <String>{};
      for (final thread in [...threads.values, ...groups.values]) {
        if (thread.isBluetooth) continue;
        for (final message in thread.messages) {
          if (message.senderNode != myNodeId) continue;
          if (!message.pending && !message.failed) continue;
          if (message.deleted) continue;
          if (!seenMessageIds.add(message.id)) continue;
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
    final ownerIsRepairable =
        group.ownerNode.trim().isEmpty ||
        _isLegacyGroupOwnerPlaceholder(group.ownerNode);
    if (ownerIsRepairable) {
      group.ownerNode = myNodeId;
      if (!group.admins.contains(myNodeId)) {
        group.admins.add(myNodeId);
      }
    }
    if (group.ownerNode != myNodeId) {
      return 'Менять участников может только владелец группы';
    }
    final previousMembers = group.members
        .where((member) => member.isNotEmpty && member != myNodeId)
        .toSet();
    final previousMemberSet = group.members
        .where((member) => member.isNotEmpty)
        .toSet();
    final uniqueMembers = <String>{
      myNodeId,
      ...members.where((id) => id.isNotEmpty),
    }.toList();
    final nextMemberSet = uniqueMembers.toSet();
    final removedMembers = previousMemberSet.difference(nextMemberSet);
    final addedMembers = nextMemberSet
        .difference(previousMemberSet)
        .where((member) => member != myNodeId)
        .toSet();
    group.members
      ..clear()
      ..addAll(uniqueMembers);
    group.admins.removeWhere((admin) => !uniqueMembers.contains(admin));
    await _publishGroupUpdate(
      group,
      rotateKey: rotateKey && removedMembers.isNotEmpty,
      extraRecipients: previousMembers,
    );
    if (addedMembers.isNotEmpty && removedMembers.isEmpty) {
      await _publishGroupKeyHistory(group, addedMembers);
    }
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
      'requester_profile': _publicOwnProfile.toJson(),
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
    if (accepted) {
      _scheduleSoftResync('Group join accepted: syncing history');
    }
  }

  bool _canPostToChannel(ChatThread group) {
    if (!group.isChannel) return true;
    return group.ownerNode == myNodeId || group.admins.contains(myNodeId);
  }

  bool canCommentInChannel(ChatThread group) {
    if (!group.isChannel) return true;
    return group.commentsEnabled || _canPostToChannel(group);
  }

  Future<String?> updateChannelCommentsEnabled(
    ChatThread group,
    bool enabled,
  ) async {
    if (session == null) return 'No active session';
    if (!group.isChannel) return 'This is not a channel';
    if (!_canPostToChannel(group)) return 'Only channel admins can change this';
    group.commentsEnabled = enabled;
    await _publishGroupUpdate(group, rotateKey: false);
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
    Set<String> extraRecipients = const {},
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
      'operation_id': 'group_update:${const Uuid().v4()}',
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'ttl': 5,
      'sender': session!.login,
      'group_id': group.groupId,
      'group_name': groupName,
      'group_about': group.profile.about,
      'group_avatar_data': group.profile.avatarData,
      'is_channel': group.isChannel,
      'comments_enabled': group.commentsEnabled,
      'members': group.members,
      'owner_node': group.ownerNode.isEmpty ? myNodeId : group.ownerNode,
      'admins': group.admins,
      'group_key_id': key.id,
      'group_key_sender_envelope': senderEnvelope,
    };

    final recipients = {
      ...group.members.where((member) => member != myNodeId),
      ...extraRecipients.where((member) => member != myNodeId),
    };
    for (final member in recipients) {
      final publicKey = profiles[member]?.publicKey ?? '';
      if (publicKey.isEmpty) continue;
      _socket.send({
        ...basePacket,
        'packet_id': const Uuid().v4(),
        'destination_node': member,
        'group_key_envelope': await _crypto.wrapGroupKey(publicKey, key.key),
      });
    }

    _socket.send({
      ...basePacket,
      'packet_id': const Uuid().v4(),
      'destination_node': 'SERVER',
      'group_key_envelope': senderEnvelope,
    });
  }

  Future<void> _publishGroupKeyHistory(
    ChatThread group,
    Set<String> recipients,
  ) async {
    if (session == null || !group.isGroup || recipients.isEmpty) return;
    final keys = _groupKeyHistory[group.groupId]?.values.toList() ?? const [];
    if (keys.isEmpty) return;
    final groupName = group.profile.displayName.trim().isEmpty
        ? group.groupName
        : group.profile.displayName;
    for (final key in keys) {
      final senderEnvelope = await _crypto.wrapGroupKey(
        _crypto.publicKey,
        key.key,
      );
      final basePacket = {
        'type': 'group_update',
        'operation_id': 'group_update:${const Uuid().v4()}',
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'ttl': 5,
        'sender': session!.login,
        'group_id': group.groupId,
        'group_name': groupName,
        'group_about': group.profile.about,
        'group_avatar_data': group.profile.avatarData,
        'is_channel': group.isChannel,
        'comments_enabled': group.commentsEnabled,
        'members': group.members,
        'owner_node': group.ownerNode.isEmpty ? myNodeId : group.ownerNode,
        'admins': group.admins,
        'group_key_id': key.id,
        'group_key_sender_envelope': senderEnvelope,
      };
      for (final member in recipients) {
        final publicKey = profiles[member]?.publicKey ?? '';
        if (publicKey.isEmpty) continue;
        _socket.send({
          ...basePacket,
          'packet_id': const Uuid().v4(),
          'destination_node': member,
          'group_key_envelope': await _crypto.wrapGroupKey(publicKey, key.key),
        });
      }
    }
  }

  Future<String?> sendGroupFile(
    ChatThread group,
    String filename,
    Uint8List bytes, {
    String caption = '',
    ChatMessage? replyTo,
    ChatMessageKind kind = ChatMessageKind.file,
    ChatMessage? retryingMessage,
  }) async {
    if (session == null) return 'Нет активной сессии';
    if (!group.isGroup) return 'Это не группа';
    final replyToMessageId =
        retryingMessage?.replyToMessageId ?? replyTo?.id ?? '';
    final replyToText =
        retryingMessage?.replyToText ??
        (replyTo == null ? '' : _replyPreview(replyTo));
    final isChannelComment =
        retryingMessage?.isChannelComment == true ||
        (group.isChannel && replyToMessageId.isNotEmpty);
    if (isChannelComment && !canCommentInChannel(group)) {
      return 'Channel comments are disabled';
    }
    if (group.isChannel && !_canPostToChannel(group) && !isChannelComment) {
      return 'Only channel admins can post';
    }
    if (bytes.isEmpty) return 'Файл пустой';
    if (bytes.length > maxMobileFileBytes) return 'Файл больше 64 МБ';

    final id = retryingMessage?.id ?? const Uuid().v4();
    final messageEffect =
        retryingMessage?.messageEffect ?? _outgoingMessageEffect;
    final groupKey = _getOrCreateGroupKey(group.groupId);
    final trimmedCaption = caption.trim();
    final wireFilename = await _crypto.encryptGroupText(groupKey.key, filename);
    final wireCaption = trimmedCaption.isEmpty
        ? ''
        : await _crypto.encryptGroupText(groupKey.key, trimmedCaption);
    final wireBytes = await _crypto.encryptGroupBytes(groupKey.key, bytes);
    final encryptedBytes = Uint8List.fromList(wireBytes);
    final senderEnvelope = await _crypto.wrapGroupKey(
      _crypto.publicKey,
      groupKey.key,
    );
    final createdAt = retryingMessage?.createdAt ?? DateTime.now();
    final outgoing =
        retryingMessage?.copyWith(
          isChannelComment: isChannelComment,
          pending: true,
          delivered: false,
          failed: false,
          progress: 0,
        ) ??
        ChatMessage(
          id: id,
          senderNode: myNodeId,
          receiverNode: group.groupId,
          text: trimmedCaption,
          createdAt: createdAt,
          kind: kind,
          fileName: filename,
          fileData: _hexEncode(bytes),
          fileSize: bytes.length,
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
          isChannelComment: isChannelComment,
          messageEffect: messageEffect,
          pending: true,
        );
    _upsertOutgoingMessage(group, outgoing);
    unawaited(_saveCache());
    notifyListeners();
    final operationId = 'file_transfer:$id';
    final recipients = group.members
        .where((member) => member.isNotEmpty && member != myNodeId)
        .toSet();
    var sent = false;
    try {
      for (final member in recipients) {
        final publicKey = profiles[member]?.publicKey ?? '';
        if (publicKey.isEmpty) continue;
        final envelope = await _crypto.wrapGroupKey(publicKey, groupKey.key);
        await _socket.queueFileTransfer(
          transferId: const Uuid().v4(),
          operationId: operationId,
          bytes: encryptedBytes,
          deferSend: true,
          packet: {
            'type': 'file_chunk',
            'protocol_version': MeshSocket.protocolVersion,
            'source_node': myNodeId,
            'destination_node': member,
            'ttl': 5,
            'sender': session!.login,
            'file_id': id,
            'message_kind': kind.name,
            'filename': wireFilename,
            'caption': wireCaption,
            'reply_to_message_id': replyToMessageId,
            'reply_to_text': replyToText,
            'message_effect': messageEffect,
            'is_channel_comment': isChannelComment,
            'group_id': group.groupId,
            'group_name': group.groupName.isEmpty
                ? group.profile.displayName
                : group.groupName,
            'is_channel': group.isChannel,
            'comments_enabled': group.commentsEnabled,
            'group_key_id': groupKey.id,
            'group_key_envelope': envelope,
            'group_key_sender_envelope': senderEnvelope,
            'created_at': createdAt.toUtc().toIso8601String(),
          },
        );
        sent = true;
      }
      if (!sent) {
        await _socket.queueFileTransfer(
          transferId: const Uuid().v4(),
          operationId: operationId,
          bytes: encryptedBytes,
          deferSend: true,
          packet: {
            'type': 'file_chunk',
            'protocol_version': MeshSocket.protocolVersion,
            'source_node': myNodeId,
            'destination_node': 'SERVER',
            'ttl': 5,
            'sender': session!.login,
            'file_id': id,
            'message_kind': kind.name,
            'filename': wireFilename,
            'caption': wireCaption,
            'reply_to_message_id': replyToMessageId,
            'reply_to_text': replyToText,
            'message_effect': messageEffect,
            'is_channel_comment': isChannelComment,
            'group_id': group.groupId,
            'group_name': group.groupName.isEmpty
                ? group.profile.displayName
                : group.groupName,
            'is_channel': group.isChannel,
            'comments_enabled': group.commentsEnabled,
            'group_key_id': groupKey.id,
            'group_key_envelope': senderEnvelope,
            'group_key_sender_envelope': senderEnvelope,
            'created_at': createdAt.toUtc().toIso8601String(),
          },
        );
      }
      await _socket.flushFileTransfers();
      if (!_socket.isConnected) {
        status = 'Queued: waiting for server connection';
        notifyListeners();
      }
      return null;
    } catch (error) {
      _replaceMessage(
        id,
        (message) => message.copyWith(pending: false, failed: true),
      );
      return 'File queue failed: $error';
    }
  }

  Future<void> _receiveMessage(Map<String, dynamic> packet) async {
    final sender = packet['sender_node']?.toString().isNotEmpty == true
        ? packet['sender_node'].toString()
        : packet['source_node']?.toString() ?? '';
    if (sender.isEmpty) return;
    final receiver =
        packet['original_destination_node']?.toString().isNotEmpty == true
        ? packet['original_destination_node'].toString()
        : packet['receiver_node']?.toString().isNotEmpty == true
        ? packet['receiver_node'].toString()
        : packet['destination_node']?.toString() ?? '';
    final senderLogin =
        packet['sender_login']?.toString().trim().toLowerCase() ?? '';
    final receiverLogin =
        packet['receiver_login']?.toString().trim().toLowerCase() ?? '';
    final myLogin = session?.login.trim().toLowerCase() ?? '';
    final sentByMe =
        sender == myNodeId ||
        (senderLogin.isNotEmpty && senderLogin == myLogin);
    final receivedByMe =
        receiver == myNodeId ||
        (receiverLogin.isNotEmpty && receiverLogin == myLogin);
    if (!sentByMe && !receivedByMe) return;
    if (!sentByMe && isBlocked(sender)) return;

    final peerId = sentByMe ? receiver : sender;
    if (peerId.isEmpty || peerId == myNodeId) return;
    final peerLogin = sentByMe ? receiverLogin : senderLogin;
    final profile = _resolveDirectPeerProfile(
      nodeId: peerId,
      accountLogin: peerLogin,
      fallbackName: sentByMe
          ? receiverLogin
          : packet['sender_name']?.toString() ??
                packet['sender']?.toString() ??
                '',
    );
    final thread = _ensurePacketThread(profile, packet);
    final id =
        packet['message_id']?.toString() ??
        packet['packet_id']?.toString() ??
        const Uuid().v4();
    if (_isDeletedMessage(id)) return;
    final existingIndex = thread.messages.indexWhere(
      (message) => message.id == id,
    );
    if (existingIndex >= 0) {
      final current = thread.messages[existingIndex];
      thread.messages[existingIndex] = current.copyWith(
        pending: false,
        delivered: true,
        failed: false,
      );
      unawaited(_saveCache());
    } else {
      final text = await _crypto.decryptText(
        packet['message']?.toString() ?? '',
      );
      final message = ChatMessage(
        id: id,
        senderNode: sentByMe ? myNodeId : sender,
        receiverNode: receiver,
        text: text,
        createdAt: _parsePacketDate(packet),
        replyToMessageId: packet['reply_to_message_id']?.toString() ?? '',
        replyToText: packet['reply_to_text']?.toString() ?? '',
        messageEffect: packet['message_effect']?.toString() ?? 'none',
        delivered: true,
      );
      thread.messages.add(message);
      thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (!sentByMe) {
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
      }
      unawaited(_saveCache());
    }
    if (!sentByMe) {
      await _sendDeliveryReceipt(packet, sender, id);
    }
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
        commentsEnabled: first.containsKey('comments_enabled')
            ? first['comments_enabled'] != false
            : null,
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
      if (!await _verifyIncomingFilePayload(first, fullData)) {
        _incomingFiles.remove(fileId);
        return;
      }
      final decryptedName = await _crypto.decryptGroupText(
        _groupKeyForPacket(groupId, first['group_key_id']?.toString() ?? ''),
        filename,
      );
      final decryptedCaption = await _crypto.decryptGroupText(
        _groupKeyForPacket(groupId, first['group_key_id']?.toString() ?? ''),
        first['caption']?.toString() ?? '',
      );
      var decryptedData = fullData;
      try {
        decryptedData = _hexEncode(
          Uint8List.fromList(
            await _crypto.decryptGroupBytes(
              _groupKeyForPacket(
                groupId,
                first['group_key_id']?.toString() ?? '',
              ),
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
        kind: _fileMessageKind(first),
        fileName: decryptedName,
        fileData: decryptedData,
        fileSize: decryptedData.length ~/ 2,
        replyToMessageId: first['reply_to_message_id']?.toString() ?? '',
        replyToText: first['reply_to_text']?.toString() ?? '',
        isChannelComment:
            first['is_channel_comment'] == true ||
            (group.isChannel &&
                (first['reply_to_message_id']?.toString() ?? '').isNotEmpty),
        messageEffect: first['message_effect']?.toString() ?? 'none',
        transcription: first['transcription']?.toString() ?? '',
        transcriptionLanguage:
            first['transcription_language']?.toString() ?? '',
        transcriptionDurationSeconds:
            double.tryParse(
              first['transcription_duration_seconds']?.toString() ?? '',
            ) ??
            0,
        ocrText: first['ocr_text']?.toString() ?? '',
        ocrLanguage: first['ocr_language']?.toString() ?? '',
        ocrProcessed: first['ocr_processed'] == true,
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
          accountLogin: sentByMe
              ? receiverLogin
              : senderLogin.isNotEmpty
              ? senderLogin
              : first['sender']?.toString() ?? '',
        );
    profiles[peerId] = _mergeProfile(profile);
    _applyProfileToThreads(profiles[peerId]!);
    final thread = _ensurePacketThread(profiles[peerId]!, first);
    final fullData = List<String>.generate(
      incoming.totalChunks,
      (index) => incoming.chunks[index] ?? '',
    ).join();
    if (!await _verifyIncomingFilePayload(first, fullData)) {
      _incomingFiles.remove(fileId);
      return;
    }
    final message = ChatMessage(
      id: fileId,
      senderNode: sentByMe ? myNodeId : sender,
      receiverNode: receiver,
      text: first['caption']?.toString() ?? '',
      createdAt: _parsePacketDate(first),
      kind: _fileMessageKind(first),
      fileName: filename,
      fileData: fullData,
      fileSize: fullData.length ~/ 2,
      replyToMessageId: first['reply_to_message_id']?.toString() ?? '',
      replyToText: first['reply_to_text']?.toString() ?? '',
      messageEffect: first['message_effect']?.toString() ?? 'none',
      transcription: first['transcription']?.toString() ?? '',
      transcriptionLanguage: first['transcription_language']?.toString() ?? '',
      transcriptionDurationSeconds:
          double.tryParse(
            first['transcription_duration_seconds']?.toString() ?? '',
          ) ??
          0,
      ocrText: first['ocr_text']?.toString() ?? '',
      ocrLanguage: first['ocr_language']?.toString() ?? '',
      ocrProcessed: first['ocr_processed'] == true,
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
    if (!fromSync && sender != myNodeId) {
      await _sendDeliveryReceipt(first, sender, fileId);
    }
  }

  Future<bool> _verifyIncomingFilePayload(
    Map<String, dynamic> packet,
    String hexData,
  ) async {
    final expected =
        packet['file_sha256']?.toString().trim().toLowerCase() ?? '';
    if (expected.isEmpty) return true;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      addDiagnostic('file', 'Rejected malformed file checksum');
      return false;
    }
    try {
      final bytes = _hexDecode(hexData);
      final digest = await Sha256().hash(bytes);
      final actual = digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual == expected) return true;
      addDiagnostic(
        'file',
        'Rejected file ${packet['file_id']}: checksum mismatch',
      );
      return false;
    } catch (error) {
      addDiagnostic('file', 'Rejected invalid file payload: $error');
      return false;
    }
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
        current.kind != incoming.kind ||
        current.fileData.isEmpty ||
        current.fileName.isEmpty ||
        current.fileSize <= 0 ||
        (incoming.transcription.isNotEmpty &&
            incoming.transcription != current.transcription) ||
        (incoming.ocrProcessed &&
            (!current.ocrProcessed || incoming.ocrText != current.ocrText)) ||
        (current.messageEffect == 'none' && incoming.messageEffect != 'none') ||
        (current.replyToMessageId.isEmpty &&
            incoming.replyToMessageId.isNotEmpty) ||
        (!current.isChannelComment && incoming.isChannelComment);
    final shouldConfirmDelivery =
        current.pending || current.failed || !current.delivered;
    if (!shouldUpgrade && !shouldConfirmDelivery) return false;
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
      kind: incoming.kind,
      text: shouldReplaceText ? incoming.text : current.text,
      fileName: shouldReplaceName ? incoming.fileName : current.fileName,
      fileData: incoming.fileData.isNotEmpty
          ? incoming.fileData
          : current.fileData,
      fileSize: incoming.fileSize > 0 ? incoming.fileSize : current.fileSize,
      transcription: incoming.transcription.isNotEmpty
          ? incoming.transcription
          : current.transcription,
      transcriptionLanguage: incoming.transcriptionLanguage.isNotEmpty
          ? incoming.transcriptionLanguage
          : current.transcriptionLanguage,
      transcriptionDurationSeconds: incoming.transcriptionDurationSeconds > 0
          ? incoming.transcriptionDurationSeconds
          : current.transcriptionDurationSeconds,
      ocrText: incoming.ocrProcessed ? incoming.ocrText : current.ocrText,
      ocrLanguage: incoming.ocrProcessed
          ? incoming.ocrLanguage
          : current.ocrLanguage,
      ocrProcessed: incoming.ocrProcessed || current.ocrProcessed,
      messageEffect: incoming.messageEffect != 'none'
          ? incoming.messageEffect
          : current.messageEffect,
      replyToMessageId: incoming.replyToMessageId.isNotEmpty
          ? incoming.replyToMessageId
          : current.replyToMessageId,
      replyToText: incoming.replyToText.isNotEmpty
          ? incoming.replyToText
          : current.replyToText,
      isChannelComment: incoming.isChannelComment || current.isChannelComment,
      delivered: true,
      pending: false,
      failed: false,
      progress: 1,
    );
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return false;
  }

  ChatMessageKind _fileMessageKind(Map<String, dynamic> packet) {
    final raw =
        packet['message_kind']?.toString() ??
        packet['kind']?.toString() ??
        packet['file_kind']?.toString() ??
        '';
    final kind = ChatMessageKind.fromName(raw);
    return kind == ChatMessageKind.sticker
        ? ChatMessageKind.sticker
        : ChatMessageKind.file;
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
    } else {
      _rememberHistoricalGroupKey(groupId, _GroupKey(keyId, groupKey));
    }
    return true;
  }

  List<int>? _groupKeyForPacket(String groupId, String keyId) {
    if (groupId.isEmpty) return null;
    if (keyId.isNotEmpty) {
      final historical = _groupKeyHistory[groupId]?[keyId];
      if (historical != null) return historical.key;
    }
    return _groupKeys[groupId]?.key;
  }

  void _rememberHistoricalGroupKey(String groupId, _GroupKey key) {
    if (groupId.isEmpty || key.id.isEmpty) return;
    _groupKeyHistory.putIfAbsent(groupId, () => {})[key.id] = key;
  }

  void _rememberGroupKey(String groupId, _GroupKey key) {
    if (groupId.isEmpty) return;
    _rememberHistoricalGroupKey(groupId, key);
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
          _rememberGroupKey(group.groupId, _GroupKey(group.groupKeyId, key));
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
          accountLogin: packet['from_name']?.toString() ?? '',
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
    _replaceMessage(
      id,
      (message) =>
          message.copyWith(delivered: true, pending: false, failed: false),
    );
  }

  void _markMessagesRead(List<String> ids) {
    for (final id in ids.toSet()) {
      if (id.isEmpty) continue;
      _replaceMessage(
        id,
        (message) => message.copyWith(
          read: true,
          delivered: true,
          pending: false,
          failed: false,
        ),
      );
    }
  }

  void _applyMutationAck(Map<String, dynamic> packet) {
    if (packet['operation_complete'] != true) return;
    final messageId = packet['packet_id']?.toString() ?? '';
    if (messageId.isEmpty) return;
    final accepted = packet['ok'] != false;
    _replaceMessage(
      messageId,
      (message) => message.copyWith(pending: false, failed: !accepted),
    );
  }

  void _applyFileTransferProgress(Map<String, dynamic> packet) {
    final fileId = packet['file_id']?.toString() ?? '';
    if (fileId.isEmpty) return;
    final progress = double.tryParse(packet['progress']?.toString() ?? '') ?? 0;
    final complete = packet['complete'] == true;
    final failed = packet['failed'] == true;
    _replaceMessage(
      fileId,
      (message) => message.copyWith(
        progress: progress.clamp(0.0, 1.0),
        pending: !complete && !failed,
        failed: failed,
      ),
    );
    if (failed) {
      final reason = packet['reason']?.toString() ?? 'transfer_failed';
      addDiagnostic('file', 'Transfer $fileId failed: $reason');
    }
  }

  void _upsertOutgoingMessage(ChatThread thread, ChatMessage outgoing) {
    final index = thread.messages.indexWhere(
      (message) => message.id == outgoing.id,
    );
    if (index >= 0) {
      thread.messages[index] = outgoing;
    } else {
      thread.messages.add(outgoing);
    }
    thread.messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
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
    final unreadBySender = <String, List<String>>{};
    for (var index = 0; index < thread.messages.length; index++) {
      final message = thread.messages[index];
      final sender = message.senderNode.trim();
      if (sender.isEmpty || sender == myNodeId || message.read) continue;
      unreadBySender.putIfAbsent(sender, () => <String>[]).add(message.id);
      thread.messages[index] = message.copyWith(read: true);
    }
    for (final entry in unreadBySender.entries) {
      final receipt = {
        'type': 'message_read',
        'packet_id': const Uuid().v4(),
        'protocol_version': MeshSocket.protocolVersion,
        'source_node': myNodeId,
        'destination_node': entry.key,
        'message_ids': entry.value,
        'ttl': thread.isBluetooth ? 1 : 5,
      };
      if (thread.isBluetooth) {
        unawaited(ble.sendPacketToNode(entry.key, receipt));
      } else {
        _socket.send(receipt);
      }
    }
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
      unawaited(_unsubscribeAndroidPush());
    }
    appSettings = settings;
    await _settingsStore.save(settings);
    notifyListeners();
  }

  Future<String?> updateMeshProPreferences({
    List<String>? quickReactions,
    bool? hdAudio,
    bool? enhancedNoiseSuppression,
  }) async {
    if (session == null) return 'Sign in first';
    if (!meshProSubscription.isActiveNow) return 'MeshPro is required';
    if (!_socket.isConnected) return 'Connect to the server first';
    final limit =
        meshProSubscription.entitlements.limitFor('quick_reactions') ?? 4;
    final normalized = <String>[];
    for (final raw in quickReactions ?? appSettings.quickReactions) {
      final reaction = raw.trim();
      if (reaction.isEmpty ||
          reaction.length > 16 ||
          normalized.contains(reaction)) {
        continue;
      }
      normalized.add(reaction);
      if (normalized.length >= limit) break;
    }
    if (normalized.isEmpty) return 'Choose at least one quick reaction';

    final requestId = const Uuid().v4();
    final completer = Completer<String?>();
    _meshProPreferenceCompleters[requestId] = completer;
    _socket.send({
      'type': 'meshpro_preferences_update',
      'packet_id': requestId,
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'quick_reactions': normalized,
      'hd_audio': hdAudio ?? appSettings.meshProHdAudio,
      'enhanced_noise_suppression':
          enhancedNoiseSuppression ??
          appSettings.meshProEnhancedNoiseSuppression,
      'ttl': 5,
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _meshProPreferenceCompleters.remove(requestId);
        return 'Server did not confirm the settings';
      },
    );
  }

  void _setActiveCall(ActiveCall? call) {
    activeCall = call;
    unawaited(
      _proximityScreen.setEnabled(
        call != null && call.status != CallStatus.ended,
      ),
    );
    if (call == null || call.status == CallStatus.ended) {
      unawaited(CallAlertService.stopAll());
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
      if (thread.isSecret) continue;
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
    await _initializeCryptoForSession(current);
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

  Future<String?> changePassword(String newPassword) async {
    final current = session;
    if (current == null || !_socket.isConnected) {
      return 'Connect to the server first';
    }
    if (newPassword.length < 8) return 'Use at least 8 characters';
    if (newPassword.length > 256) return 'Password is too long';
    if (newPassword == current.password) return 'Choose a different password';

    final recovery = await _crypto.createIdentityRecovery(
      current.login,
      newPassword,
    );
    final requestId = const Uuid().v4();
    final completer = Completer<String?>();
    _passwordChangeCompleters[requestId] = completer;
    _socket.send({
      'type': 'account_password_change_request',
      'packet_id': requestId,
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'current_password': current.password,
      'new_password': newPassword,
      'encryption_recovery': recovery,
      'ttl': 5,
    });

    final result = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _passwordChangeCompleters.remove(requestId);
        return 'Server did not confirm the password change';
      },
    );
    if (result != null) return result;

    final updated = current.copyWith(
      password: newPassword,
      identityRecovery: recovery,
    );
    await _store.saveCurrent(updated);
    await _store.saveRecent(updated);
    session = updated;
    recentSessions = await _store.loadRecent();
    await _socket.close();
    await _connect();
    notifyListeners();
    return null;
  }

  Future<String?> renameActiveDevice(ActiveDevice device, String deviceName) {
    return _activeDeviceAction(device, 'rename', deviceName: deviceName);
  }

  Future<String?> revokeActiveDevice(ActiveDevice device) {
    if (device.nodeId == myNodeId) {
      return Future<String?>.value('The current device cannot revoke itself');
    }
    return _activeDeviceAction(device, 'revoke');
  }

  Future<String?> _activeDeviceAction(
    ActiveDevice device,
    String action, {
    String? deviceName,
  }) async {
    if (session == null || !_socket.isConnected) {
      return 'Connect to the server first';
    }
    final requestId = const Uuid().v4();
    final completer = Completer<String?>();
    _activeDeviceActionCompleters[requestId] = completer;
    _socket.send({
      'type': 'active_device_action_request',
      'packet_id': requestId,
      'request_id': requestId,
      'protocol_version': MeshSocket.protocolVersion,
      'source_node': myNodeId,
      'destination_node': 'SERVER',
      'target_node': device.nodeId,
      'action': action,
      if (deviceName != null) 'device_name': deviceName.trim(),
      'ttl': 5,
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _activeDeviceActionCompleters.remove(requestId);
        return 'Server did not confirm the device action';
      },
    );
  }

  Future<void> clearLocalCache() async {
    final current = session;
    await _cache.clear(session);
    await _socket.close();
    _clearLocalState();
    if (current != null) await _loadOwnProfile(current);
    await _connect();
    notifyListeners();
  }

  Future<void> logout() async {
    await ble.stop();
    await _unsubscribeAndroidPush();
    await _socket.close();
    await _store.clear();
    session = null;
    _clearLocalState();
    status = 'Offline';
    notifyListeners();
  }

  Future<void> _handleDeviceRevoked() async {
    final current = session;
    await _socket.close();
    await _store.clear();
    if (current != null) {
      await _store.removeRecent(current);
    }
    session = null;
    recentSessions = await _store.loadRecent();
    _clearLocalState();
    status = 'This device was signed out remotely';
    error = 'Enter the password again to reactivate this device';
    notifyListeners();
  }

  Future<void> _handlePasswordChangedElsewhere() async {
    final current = session;
    await _socket.close();
    await _store.clear();
    if (current != null) await _store.removeRecent(current);
    session = null;
    recentSessions = await _store.loadRecent();
    _clearLocalState();
    status = 'The account password was changed on another device';
    error = 'Enter the new password to sign in again';
    notifyListeners();
  }

  void _clearLocalState() {
    _ownProfileHydrated = false;
    profiles.clear();
    threads.clear();
    groups.clear();
    groupJoinRequests.clear();
    stories.clear();
    storyArchive.clear();
    scheduledMessages.clear();
    stickerLibrary = const StickerLibrary();
    hiddenStoryOwners.clear();
    typingUntil.clear();
    activityKinds.clear();
    _incomingFiles.clear();
    _incomingPreviewTimer?.cancel();
    _softResyncTimer?.cancel();
    _incomingPreviewTimer = null;
    _softResyncTimer = null;
    incomingPreviewThread = null;
    incomingPreviewMessage = null;
    _groupKeys.clear();
    _groupKeyHistory.clear();
    meshProSubscription = const MeshProSubscription.inactive();
    final meshProCompleter = _meshProCompleter;
    _meshProCompleter = null;
    if (meshProCompleter != null && !meshProCompleter.isCompleted) {
      meshProCompleter.complete(meshProSubscription);
    }
    for (final completer in _aiRewriteCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiRewriteException('signed_out', 'Signed out'),
        );
      }
    }
    _aiRewriteCompleters.clear();
    for (final completer in _aiTranslationCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiTranslationException('signed_out', 'Signed out'),
        );
      }
    }
    _aiTranslationCompleters.clear();
    for (final completer in _aiSummaryCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiSummaryException('signed_out', 'Signed out'),
        );
      }
    }
    _aiSummaryCompleters.clear();
    for (final completer in _aiTranscriptionCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiTranscriptionException('signed_out', 'Signed out'),
        );
      }
    }
    _aiTranscriptionCompleters.clear();
    for (final completer in _aiOcrCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiOcrException('signed_out', 'Signed out'),
        );
      }
    }
    _aiOcrCompleters.clear();
    for (final completer in _aiSmartRepliesCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiSmartRepliesException('signed_out', 'Signed out'),
        );
      }
    }
    _aiSmartRepliesCompleters.clear();
    for (final completer in _aiPersonMemoryCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiPersonMemoryException('signed_out', 'Signed out'),
        );
      }
    }
    _aiPersonMemoryCompleters.clear();
    for (final completer in _scheduledMessageCompleters.values) {
      if (!completer.isCompleted) completer.complete('Signed out');
    }
    _scheduledMessageCompleters.clear();
    for (final completer in _chatPreferenceCompleters.values) {
      if (!completer.isCompleted) completer.complete('Signed out');
    }
    _chatPreferenceCompleters.clear();
    for (final completer in _activeDeviceActionCompleters.values) {
      if (!completer.isCompleted) completer.complete('Signed out');
    }
    _activeDeviceActionCompleters.clear();
    for (final completer in _meshProPreferenceCompleters.values) {
      if (!completer.isCompleted) completer.complete('Signed out');
    }
    _meshProPreferenceCompleters.clear();
    for (final completer in _passwordChangeCompleters.values) {
      if (!completer.isCompleted) completer.complete('Signed out');
    }
    _passwordChangeCompleters.clear();
  }

  Future<void> _saveCache() async {
    try {
      await _cache.save(session, [...threads.values, ...groups.values]);
    } catch (_) {
      // Web storage can reject writes when Safari quota is exhausted.
      // The app should keep working; sync can restore data later.
    }
  }

  Future<void> _loadOwnProfile(Session current) async {
    Profile? stored;
    try {
      stored = await _ownProfileStore.load(current);
    } catch (error) {
      addDiagnostic('profile', 'Local profile load failed: $error');
      return;
    }
    if (stored == null) return;
    profiles[current.nodeId] = _normalizeOwnProfile(stored, current);
    _ownProfileHydrated = true;
  }

  Future<void> _saveOwnProfile(Profile profile) async {
    final current = session;
    if (current == null) return;
    try {
      await _ownProfileStore.save(current, profile);
    } catch (error) {
      addDiagnostic('profile', 'Local profile save failed: $error');
    }
  }

  Profile _normalizeOwnProfile(Profile profile, Session current) {
    return profile.copyWith(
      nodeId: current.nodeId,
      accountLogin: current.login,
      nodeAliases: <String>{
        ...profile.nodeAliases,
        profile.nodeId,
        current.nodeId,
      }.where((value) => value.isNotEmpty).toList(),
      publicUsername: profile.publicUsername.trim().isEmpty
          ? current.publicUsername
          : null,
      publicKey: profile.publicKey.isEmpty ? _crypto.publicKey : null,
    );
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
    for (final completer in _aiRewriteCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiRewriteException('disposed', 'Application closed'),
        );
      }
    }
    _aiRewriteCompleters.clear();
    for (final completer in _aiTranslationCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiTranslationException('disposed', 'Application closed'),
        );
      }
    }
    _aiTranslationCompleters.clear();
    for (final completer in _aiSummaryCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiSummaryException('disposed', 'Application closed'),
        );
      }
    }
    _aiSummaryCompleters.clear();
    for (final completer in _aiTranscriptionCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiTranscriptionException('disposed', 'Application closed'),
        );
      }
    }
    _aiTranscriptionCompleters.clear();
    for (final completer in _aiOcrCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiOcrException('disposed', 'Application closed'),
        );
      }
    }
    _aiOcrCompleters.clear();
    for (final completer in _aiSmartRepliesCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiSmartRepliesException('disposed', 'Application closed'),
        );
      }
    }
    _aiSmartRepliesCompleters.clear();
    for (final completer in _aiPersonMemoryCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiPersonMemoryException('disposed', 'Application closed'),
        );
      }
    }
    _aiPersonMemoryCompleters.clear();
    for (final completer in _scheduledMessageCompleters.values) {
      if (!completer.isCompleted) completer.complete('Application closed');
    }
    _scheduledMessageCompleters.clear();
    for (final completer in _chatPreferenceCompleters.values) {
      if (!completer.isCompleted) completer.complete('Application closed');
    }
    _chatPreferenceCompleters.clear();
    for (final completer in _passwordChangeCompleters.values) {
      if (!completer.isCompleted) completer.complete('Application closed');
    }
    _passwordChangeCompleters.clear();
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
    this.deviceName = '',
    this.appVersion = '',
    this.online = false,
    this.revoked = false,
    this.lastSeen = '',
  });

  final String nodeId;
  final String displayName;
  final String deviceName;
  final String appVersion;
  final bool online;
  final bool revoked;
  final String lastSeen;

  factory ActiveDevice.fromJson(Map<String, dynamic> json) {
    return ActiveDevice(
      nodeId: json['node_id']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? '',
      online: json['online'] == true,
      revoked: json['revoked'] == true,
      lastSeen: json['last_seen']?.toString() ?? '',
    );
  }
}
