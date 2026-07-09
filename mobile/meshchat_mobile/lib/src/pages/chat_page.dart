import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart' as image_picker;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../models/sticker_pack.dart';
import '../services/call_alert_service.dart';
import '../widgets/in_app_message_banner.dart';
import '../widgets/profile_avatar.dart';
import 'chat_media_page.dart';
import 'group_info_page.dart';
import 'meeting_point_map_page.dart';
import 'meeting_points_page.dart';
import 'profile_page.dart';

enum _AttachAction { photo, file, sticker, shareLocation }

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.controller,
    required this.thread,
    this.channelPost,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage? channelPost;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final scroll = ScrollController();
  final recorder = AudioRecorder();
  final imagePicker = image_picker.ImagePicker();
  final recordLevels = List<double>.filled(22, 0.25);
  StreamSubscription<Amplitude>? amplitudeSubscription;
  AudioPlayer? ringbackPlayer;
  bool ringbackRunning = false;
  final incomingCallAlert = CallAlertService();
  bool recording = false;
  bool voicePointerDown = false;
  bool didInitialScrollToBottom = false;
  bool showJumpToBottom = false;
  double voiceCancelDrag = 0;
  bool voiceCancelArmed = false;
  bool hasInputText = false;
  DateTime? recordStartedAt;
  ChatMessage? replyTo;
  DateTime? lastTypingSentAt;
  Timer? liveLocationTimer;
  DateTime? liveLocationUntil;
  String? liveLocationMessageId;
  final deletingMessageIds = <String>{};

  bool get isChannelCommentThread =>
      widget.thread.isChannel && widget.channelPost != null;

  ChatMessage? get fixedCommentRoot =>
      isChannelCommentThread ? widget.channelPost : null;

  bool get canPostToThread {
    final thread = widget.thread;
    if (!thread.isChannel) return true;
    if (isChannelCommentThread) {
      return widget.controller.canCommentInChannel(thread);
    }
    if (replyTo != null) return widget.controller.canCommentInChannel(thread);
    return thread.ownerNode == widget.controller.myNodeId ||
        thread.admins.contains(widget.controller.myNodeId) ||
        (thread.ownerNode.isEmpty && thread.admins.isEmpty);
  }

  String get channelWriteBlockedMessage {
    if (isChannelCommentThread) {
      return 'Channel comments are disabled';
    }
    if (widget.thread.isChannel && replyTo != null) {
      return 'Channel comments are disabled';
    }
    return 'Only channel admins can post';
  }

  List<ChatMessage> visibleMessages() {
    final messages = widget.thread.messages;
    if (!widget.thread.isChannel) return messages;
    final root = fixedCommentRoot;
    if (root == null) {
      return messages
          .where((message) => message.replyToMessageId.trim().isEmpty)
          .toList(growable: false);
    }
    return [
      root,
      ...messages.where(
        (message) =>
            message.id != root.id && message.replyToMessageId == root.id,
      ),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  int commentCountFor(ChatMessage post) {
    if (!widget.thread.isChannel || post.replyToMessageId.isNotEmpty) return 0;
    return widget.thread.messages
        .where((message) => message.replyToMessageId == post.id)
        .length;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    input.text = widget.thread.draft;
    hasInputText = input.text.trim().isNotEmpty;
    inputFocus.addListener(() {
      if (inputFocus.hasFocus) scheduleKeyboardScrollToBottom();
    });
    input.addListener(() {
      final hasText = input.text.trim().isNotEmpty;
      if (hasInputText != hasText) {
        setState(() => hasInputText = hasText);
      }
      widget.controller.updateDraft(widget.thread, input.text);
      final now = DateTime.now();
      if (input.text.trim().isNotEmpty &&
          (lastTypingSentAt == null ||
              now.difference(lastTypingSentAt!).inSeconds >= 3)) {
        lastTypingSentAt = now;
        widget.controller.sendTyping(widget.thread);
      }
    });
    scroll.addListener(handleScroll);
    widget.controller.markRead(widget.thread);
    widget.controller.setActiveThread(widget.thread);
    widget.controller.addListener(syncRingback);
    syncRingback();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    amplitudeSubscription?.cancel();
    liveLocationTimer?.cancel();
    unawaited(deleteLastLiveLocationMessage());
    widget.controller.removeListener(syncRingback);
    unawaited(incomingCallAlert.dispose());
    unawaited(stopRingback());
    widget.controller.setActiveThread(null);
    inputFocus.dispose();
    input.dispose();
    scroll.removeListener(handleScroll);
    scroll.dispose();
    recorder.dispose();
    ringbackPlayer?.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (inputFocus.hasFocus) scheduleKeyboardScrollToBottom();
  }

  void syncRingback() {
    unawaited(incomingCallAlert.sync(widget.controller));
    final call = widget.controller.activeCall;
    final shouldPlay =
        call != null && !call.incoming && call.status == CallStatus.outgoing;
    if (shouldPlay) {
      unawaited(startRingback());
    } else {
      unawaited(stopRingback());
    }
  }

  Future<void> startRingback() async {
    if (ringbackRunning) return;
    ringbackRunning = true;
    final player = ringbackPlayer ??= AudioPlayer();
    await player.setReleaseMode(ReleaseMode.loop).catchError((_) {});
    await player
        .play(BytesSource(_softRingbackWav()), volume: 0.30)
        .catchError((_) {});
  }

  Future<void> stopRingback() async {
    if (!ringbackRunning && ringbackPlayer == null) return;
    ringbackRunning = false;
    await ringbackPlayer?.stop().catchError((_) {});
  }

  Uint8List _softRingbackWav() {
    const sampleRate = 22050;
    const seconds = 2.4;
    final samples = (sampleRate * seconds).round();
    final dataBytes = samples * 2;
    final bytes = Uint8List(44 + dataBytes);
    final data = ByteData.sublistView(bytes);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, 36 + dataBytes, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final local = t % seconds;
      final inTone = local < 0.42 || (local > 0.62 && local < 1.02);
      var sample = 0.0;
      if (inTone) {
        final toneT = local < 0.42 ? local : local - 0.62;
        final attack = (toneT / 0.08).clamp(0.0, 1.0);
        final release = ((0.40 - toneT) / 0.14).clamp(0.0, 1.0);
        final envelope = math.sin(math.pi * math.min(attack, release) / 2);
        final base = math.sin(2 * math.pi * 523.25 * t);
        final overtone = math.sin(2 * math.pi * 659.25 * t) * 0.34;
        sample = (base + overtone) * 0.20 * envelope;
      }
      data.setInt16(44 + i * 2, (sample * 32767).round(), Endian.little);
    }
    return bytes;
  }

  Future<void> send() async {
    final text = input.text;
    if (text.trim().isEmpty) return;
    if (!canPostToThread) {
      showSnack(channelWriteBlockedMessage);
      return;
    }
    input.clear();
    widget.controller.updateDraft(widget.thread, '');
    final quote = fixedCommentRoot ?? replyTo;
    setState(() => replyTo = null);
    if (widget.thread.isGroup) {
      await widget.controller.sendGroupMessage(
        widget.thread,
        text,
        replyTo: quote,
      );
    } else {
      await widget.controller.sendMessage(
        widget.thread.profile,
        text,
        replyTo: quote,
        threadOverride: widget.thread,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
  }

  Future<void> attachFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    await sendAttachment(file.name, bytes);
  }

  Future<void> attachPhoto() async {
    final image = await imagePicker.pickImage(
      source: image_picker.ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    final filename = image.name.trim().isEmpty
        ? 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg'
        : image.name;
    await sendAttachment(filename, bytes);
  }

  Future<void> showStickerPanel() async {
    if (!canPostToThread) {
      showSnack(channelWriteBlockedMessage);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => _StickerSheet(
          controller: widget.controller,
          onAddSticker: addStickerFromFile,
          onCreatePack: createStickerPack,
          onToggleFavorite: widget.controller.toggleFavoriteSticker,
          onSend: (sticker) async {
            Navigator.pop(context);
            await sendSticker(sticker);
          },
        ),
      ),
    );
  }

  Future<void> createStickerPack() async {
    final nameInput = TextEditingController(text: 'My stickers');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New sticker pack'),
        content: TextField(
          controller: nameInput,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Pack name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameInput.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameInput.dispose();
    if (name == null || name.trim().isEmpty) return;
    await widget.controller.createStickerPack(name);
  }

  Future<void> addStickerFromFile([String? requestedPackId]) async {
    var packId = requestedPackId;
    if (widget.controller.stickerPacks.isEmpty) {
      await widget.controller.createStickerPack('My stickers');
      packId = widget.controller.stickerPacks.isEmpty
          ? null
          : widget.controller.stickerPacks.first.id;
    }
    packId ??= widget.controller.stickerPacks.isEmpty
        ? null
        : widget.controller.stickerPacks.first.id;
    if (packId == null || packId.isEmpty) return;
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp'],
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null || bytes.isEmpty) return;
    await widget.controller.addSticker(
      packId: packId,
      fileName: file.name,
      bytes: bytes,
    );
  }

  Future<void> sendSticker(StickerItem sticker) async {
    final quote = fixedCommentRoot ?? replyTo;
    setState(() => replyTo = null);
    final error = await widget.controller.sendSticker(
      widget.thread,
      sticker,
      replyTo: quote,
    );
    if (!mounted || error == null) return;
    showSnack(error);
  }

  Future<void> sendMeetingPoint() async {
    if (!widget.thread.isGroup) {
      showSnack('Meeting points are available in groups');
      return;
    }
    if (!canPostToThread) {
      showSnack(channelWriteBlockedMessage);
      return;
    }
    final point = await askMeetingPoint();
    if (point == null) return;
    final quote = fixedCommentRoot ?? replyTo;
    setState(() => replyTo = null);
    await widget.controller.sendGroupMessage(
      widget.thread,
      point.toMessageText(),
      replyTo: quote,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
  }

  Future<void> shareMyLocation() async {
    if (!widget.thread.isGroup) {
      showSnack('Location sharing is available in groups');
      return;
    }
    if (!canPostToThread) {
      showSnack(channelWriteBlockedMessage);
      return;
    }
    final duration = await chooseLocationShareDuration();
    if (duration == null) return;
    final until = duration == Duration.zero
        ? null
        : DateTime.now().toUtc().add(duration);
    await sendCurrentLocationMessage(expiresAt: until);
    if (until != null && mounted) {
      startLiveLocationTimer(until);
      showSnack('Live location is on');
    }
  }

  Future<Duration?> chooseLocationShareDuration() {
    return showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
          child: _ChatGlassSurface(
            radius: 26,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(
                      Icons.my_location_rounded,
                      color: Color(0xFF54F2C7),
                    ),
                    title: Text('Share location'),
                    subtitle: Text('Send once or keep it updating.'),
                  ),
                  _LocationDurationTile(
                    icon: Icons.place_rounded,
                    title: 'Send once',
                    subtitle: 'One location message',
                    onTap: () => Navigator.pop(context, Duration.zero),
                  ),
                  _LocationDurationTile(
                    icon: Icons.timer_rounded,
                    title: 'Live for 15 minutes',
                    subtitle: 'Updates while this chat is open',
                    onTap: () =>
                        Navigator.pop(context, const Duration(minutes: 15)),
                  ),
                  _LocationDurationTile(
                    icon: Icons.schedule_rounded,
                    title: 'Live for 1 hour',
                    subtitle: 'Updates while this chat is open',
                    onTap: () =>
                        Navigator.pop(context, const Duration(hours: 1)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void startLiveLocationTimer(DateTime until) {
    liveLocationUntil = until;
    liveLocationTimer?.cancel();
    liveLocationTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      final target = liveLocationUntil;
      if (target == null || DateTime.now().toUtc().isAfter(target)) {
        timer.cancel();
        unawaited(deleteLastLiveLocationMessage());
        return;
      }
      unawaited(sendCurrentLocationMessage(expiresAt: target, silent: true));
    });
  }

  Future<void> deleteLastLiveLocationMessage() async {
    final id = liveLocationMessageId;
    if (id == null || id.isEmpty) return;
    liveLocationMessageId = null;
    final message = widget.thread.messages
        .where((message) => message.id == id)
        .cast<ChatMessage?>()
        .firstWhere((message) => message != null, orElse: () => null);
    if (message == null || message.deleted) return;
    await widget.controller.deleteMessage(widget.thread, message);
  }

  Future<String?> sendCurrentLocationMessage({
    DateTime? expiresAt,
    bool silent = false,
  }) async {
    final current = await getCurrentLocationText();
    if (!mounted) return null;
    if (current.error != null || current.text == null) {
      if (!silent) {
        showSnack(current.error ?? 'Could not read current location');
      }
      return null;
    }
    final point = _SharedLocation.tryParse(
      rawLocation: current.text!,
      expiresAt: expiresAt,
    );
    if (point == null) {
      if (!silent) showSnack('Could not read current location');
      return null;
    }
    final quote = silent ? null : (fixedCommentRoot ?? replyTo);
    if (!silent) setState(() => replyTo = null);
    final previousLiveId = silent ? liveLocationMessageId : null;
    final sentId = await widget.controller.sendGroupMessage(
      widget.thread,
      point.toMessageText(),
      replyTo: quote,
    );
    if (expiresAt != null && sentId != null) {
      liveLocationMessageId = sentId;
    }
    if (previousLiveId != null && previousLiveId != sentId) {
      final previous = widget.thread.messages
          .where((message) => message.id == previousLiveId)
          .cast<ChatMessage?>()
          .firstWhere((message) => message != null, orElse: () => null);
      if (previous != null && !previous.deleted) {
        await widget.controller.deleteMessage(widget.thread, previous);
      }
    }
    if (!silent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
    }
    return sentId;
  }

  Future<_MeetingPoint?> askMeetingPoint() async {
    final titleInput = TextEditingController(text: 'Meeting point');
    final locationInput = TextEditingController();
    final noteInput = TextEditingController();
    String? error;
    var locating = false;
    final result = await showModalBottomSheet<_MeetingPoint>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              14,
              0,
              14,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: _ChatGlassSurface(
              radius: 28,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.82,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.add_location_alt_rounded,
                          color: Colors.lightBlueAccent,
                        ),
                        title: Text('Meeting point'),
                        subtitle: Text('Paste coordinates or a map link'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: titleInput,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Cafe, entrance, meeting place',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: locationInput,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Coordinates or link',
                          hintText: '59.9343, 30.3351',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: locating
                                  ? null
                                  : () async {
                                      setSheetState(() {
                                        locating = true;
                                        error = null;
                                      });
                                      final current =
                                          await getCurrentLocationText();
                                      if (!context.mounted) return;
                                      setSheetState(() {
                                        locating = false;
                                        if (current.error != null) {
                                          error = current.error;
                                        } else {
                                          locationInput.text = current.text!;
                                        }
                                      });
                                    },
                              icon: locating
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.my_location_rounded),
                              label: Text(
                                locating
                                    ? 'Finding location...'
                                    : 'Use my location',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final parsed = _MeetingPoint.tryParse(
                                  title: titleInput.text,
                                  rawLocation: locationInput.text,
                                  note: noteInput.text,
                                );
                                final picked =
                                    await Navigator.push<MeetingPointMapResult>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => MeetingPointMapPage(
                                          title: titleInput.text.trim().isEmpty
                                              ? 'Meeting point'
                                              : titleInput.text.trim(),
                                          latitude:
                                              parsed?.latitude ?? 59.934300,
                                          longitude:
                                              parsed?.longitude ?? 30.335100,
                                          note: noteInput.text,
                                          picking: true,
                                        ),
                                      ),
                                    );
                                if (!context.mounted || picked == null) return;
                                setSheetState(() {
                                  error = null;
                                  locationInput.text = picked.coordinateText;
                                });
                              },
                              icon: const Icon(Icons.map_rounded),
                              label: const Text('Pick on map'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: noteInput,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Note',
                          hintText: 'Optional',
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () {
                                final parsed = _MeetingPoint.tryParse(
                                  title: titleInput.text,
                                  rawLocation: locationInput.text,
                                  note: noteInput.text,
                                );
                                if (parsed == null) {
                                  setSheetState(() {
                                    error =
                                        'Could not find coordinates in this text';
                                  });
                                  return;
                                }
                                Navigator.pop(context, parsed);
                              },
                              icon: const Icon(Icons.near_me_rounded),
                              label: const Text('Send'),
                            ),
                          ),
                        ],
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
    titleInput.dispose();
    locationInput.dispose();
    noteInput.dispose();
    return result;
  }

  Future<({String? text, String? error})> getCurrentLocationText() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        return (
          text: null,
          error: 'Location services are disabled on this device',
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return (text: null, error: 'Location permission was denied');
      }
      if (permission == LocationPermission.deniedForever) {
        return (
          text: null,
          error: 'Location permission is blocked in system settings',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return (
        text:
            '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
        error: null,
      );
    } catch (_) {
      return (text: null, error: 'Could not read current location');
    }
  }

  Future<void> showAttachMenu() async {
    final action = await showModalBottomSheet<_AttachAction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
          child: _ChatGlassSurface(
            radius: 28,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GlassSheetAction(
                    icon: Icons.photo_library_rounded,
                    title: 'Photo',
                    subtitle: 'Choose from gallery',
                    onTap: () => Navigator.pop(context, _AttachAction.photo),
                  ),
                  _GlassSheetAction(
                    icon: Icons.attach_file_rounded,
                    title: 'File',
                    subtitle: 'Choose any document',
                    onTap: () => Navigator.pop(context, _AttachAction.file),
                  ),
                  _GlassSheetAction(
                    icon: Icons.auto_awesome_motion_rounded,
                    title: 'Sticker',
                    subtitle: 'Open packs, favorites or add your own',
                    onTap: () => Navigator.pop(context, _AttachAction.sticker),
                  ),
                  if (widget.thread.isGroup)
                    _GlassSheetAction(
                      icon: Icons.my_location_rounded,
                      title: 'Share my location',
                      subtitle: 'Show your latest place on the group map',
                      onTap: () =>
                          Navigator.pop(context, _AttachAction.shareLocation),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (action == _AttachAction.photo) {
      await attachPhoto();
    } else if (action == _AttachAction.file) {
      await attachFile();
    } else if (action == _AttachAction.sticker) {
      await showStickerPanel();
    } else if (action == _AttachAction.shareLocation) {
      await shareMyLocation();
    }
  }

  Future<void> sendAttachment(String filename, Uint8List bytes) async {
    if (!canPostToThread) {
      showSnack(channelWriteBlockedMessage);
      return;
    }
    final caption = await askFileCaption(filename);
    if (caption == null) return;
    final quote = fixedCommentRoot ?? replyTo;
    setState(() => replyTo = null);
    final error = widget.thread.isGroup
        ? await widget.controller.sendGroupFile(
            widget.thread,
            filename,
            bytes,
            caption: caption,
            replyTo: quote,
          )
        : await widget.controller.sendFile(
            widget.thread.profile,
            filename,
            bytes,
            caption: caption,
            replyTo: quote,
            threadOverride: widget.thread,
          );
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<String?> askFileCaption(String filename) async {
    final captionInput = TextEditingController();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.attach_file_rounded),
                title: Text(
                  filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('Add a caption or send without it'),
              ),
              TextField(
                controller: captionInput,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Caption',
                  prefixIcon: Icon(Icons.notes_rounded),
                ),
                onSubmitted: (_) => Navigator.pop(context, captionInput.text),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, captionInput.text),
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    captionInput.dispose();
    return result;
  }

  Future<void> toggleVoiceRecording() async {
    if (recording) {
      await stopVoiceRecording();
    } else {
      await startVoiceRecording();
    }
  }

  Future<void> startVoiceHold() async {
    if (recording || voicePointerDown) return;
    voicePointerDown = true;
    resetVoiceHoldDrag();
    await startVoiceRecording();
    if (!recording) voicePointerDown = false;
  }

  Future<void> finishVoiceHold({required bool send}) async {
    if (!voicePointerDown && !recording) return;
    voicePointerDown = false;
    if (!recording) return;
    final shouldSend = send && !voiceCancelArmed;
    if (shouldSend) {
      await stopVoiceRecording();
    } else {
      await cancelRecording();
    }
  }

  void updateVoiceHoldDrag(double delta) {
    if (!recording && !voicePointerDown) return;
    final next = (voiceCancelDrag + delta).clamp(-120.0, 0.0);
    final armed = next <= -72;
    if (next == voiceCancelDrag && armed == voiceCancelArmed) return;
    final becameArmed = armed && !voiceCancelArmed;
    setState(() {
      voiceCancelDrag = next;
      voiceCancelArmed = armed;
    });
    if (becameArmed) {
      HapticFeedback.selectionClick();
    }
  }

  void resetVoiceHoldDrag() {
    if (voiceCancelDrag == 0 && !voiceCancelArmed) return;
    setState(() {
      voiceCancelDrag = 0;
      voiceCancelArmed = false;
    });
  }

  Future<void> startVoiceRecording() async {
    final allowed = await requestMicrophonePermission();
    if (!allowed) {
      return;
    }
    final path = kIsWeb
        ? 'meshchat_voice_${DateTime.now().millisecondsSinceEpoch}.m4a'
        : p.join(
            (await getTemporaryDirectory()).path,
            'meshchat_voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
          );
    try {
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
          numChannels: 1,
          noiseSuppress: true,
          echoCancel: true,
        ),
        path: path,
      );
    } catch (error) {
      if (!mounted) return;
      showSnack('Could not start microphone: $error');
      return;
    }
    await amplitudeSubscription?.cancel();
    amplitudeSubscription = recorder
        .onAmplitudeChanged(const Duration(milliseconds: 90))
        .listen((amplitude) {
          if (!mounted || !recording) return;
          final normalized = ((amplitude.current + 55) / 55).clamp(0.08, 1.0);
          setState(() {
            recordLevels.removeAt(0);
            recordLevels.add(normalized);
          });
        });
    setState(() {
      recording = true;
      recordStartedAt = DateTime.now();
      voiceCancelDrag = 0;
      voiceCancelArmed = false;
      for (var i = 0; i < recordLevels.length; i++) {
        recordLevels[i] = 0.25;
      }
    });
    widget.controller.sendActivity(widget.thread, 'voice');
    unawaited(HapticFeedback.mediumImpact());
  }

  Future<bool> requestMicrophonePermission() async {
    if (kIsWeb) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Microphone access'),
          content: const Text(
            'MeshChat needs microphone access to record voice messages.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return false;
    }

    try {
      final allowed = await recorder.hasPermission();
      if (allowed) return true;
    } catch (error) {
      if (mounted) {
        showSnack(
          kIsWeb ? 'Open MeshChat through HTTPS to use microphone.' : '$error',
        );
      }
      return false;
    }

    if (!mounted) return false;
    showSnack(
      kIsWeb
          ? 'Microphone is blocked. Use HTTPS and allow microphone in Safari settings.'
          : 'Microphone permission is required',
    );
    return false;
  }

  Future<void> stopVoiceRecording() async {
    await amplitudeSubscription?.cancel();
    amplitudeSubscription = null;
    final path = await recorder.stop();
    final duration = recordStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(recordStartedAt!);
    setState(() {
      recording = false;
      recordStartedAt = null;
      voiceCancelDrag = 0;
      voiceCancelArmed = false;
    });
    if (path == null || duration.inMilliseconds < 500) return;
    final bytes = await XFile(path).readAsBytes();
    final filename =
        'voice_${DateTime.now().millisecondsSinceEpoch}_${duration.inSeconds}s.m4a';
    final quote = fixedCommentRoot ?? replyTo;
    if (quote != null && mounted) {
      setState(() => replyTo = null);
    }
    final error = widget.thread.isGroup
        ? await widget.controller.sendGroupFile(
            widget.thread,
            filename,
            bytes,
            replyTo: quote,
          )
        : await widget.controller.sendFile(
            widget.thread.profile,
            filename,
            bytes,
            replyTo: quote,
            threadOverride: widget.thread,
          );
    if (error == null) {
      unawaited(HapticFeedback.lightImpact());
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> cancelRecording() async {
    await amplitudeSubscription?.cancel();
    amplitudeSubscription = null;
    await recorder.cancel();
    if (!mounted) return;
    setState(() {
      recording = false;
      recordStartedAt = null;
      voiceCancelDrag = 0;
      voiceCancelArmed = false;
    });
    voicePointerDown = false;
    unawaited(HapticFeedback.selectionClick());
  }

  void showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void scrollToBottom() {
    if (!scroll.hasClients) return;
    scroll.animateTo(
      scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void jumpToBottom() {
    if (!scroll.hasClients) return;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    handleScroll();
  }

  void scheduleKeyboardScrollToBottom() {
    void settleScroll() {
      if (!mounted || !scroll.hasClients) return;
      jumpToBottom();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => settleScroll());
    Future<void>.delayed(const Duration(milliseconds: 120), settleScroll);
    Future<void>.delayed(const Duration(milliseconds: 280), settleScroll);
    Future<void>.delayed(const Duration(milliseconds: 480), settleScroll);
  }

  void scheduleInitialScrollToBottom(int messageCount) {
    if (didInitialScrollToBottom || messageCount == 0) return;
    didInitialScrollToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      jumpToBottom();
    });
  }

  void handleScroll() {
    if (!scroll.hasClients) return;
    final hiddenBelow = scroll.position.maxScrollExtent - scroll.offset;
    final shouldShow = hiddenBelow > 180;
    if (shouldShow == showJumpToBottom) return;
    setState(() => showJumpToBottom = shouldShow);
  }

  bool get desktopSendHotkeys {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
  }

  KeyEventResult handleInputKey(FocusNode node, KeyEvent event) {
    if (!desktopSendHotkeys || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrlPressed =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    if (ctrlPressed) {
      final selection = input.selection;
      final text = input.text;
      final start = selection.start < 0 ? text.length : selection.start;
      final end = selection.end < 0 ? text.length : selection.end;
      input.value = TextEditingValue(
        text: text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
    } else {
      unawaited(send());
    }
    return KeyEventResult.handled;
  }

  String recordDuration() {
    final started = recordStartedAt;
    if (started == null) return '0:00';
    final duration = DateTime.now().difference(started);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfilePage(
          profile: widget.thread.profile,
          controller: widget.controller,
          thread: widget.thread,
          onMessage: () => Navigator.maybePop(context),
          onCall:
              widget.controller.isSavedMessagesProfile(widget.thread.profile)
              ? null
              : () => unawaited(startCall()),
          onMedia: openMediaList,
        ),
      ),
    );
  }

  void openGroupInfo() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GroupInfoPage(controller: widget.controller, thread: widget.thread),
      ),
    );
  }

  Future<void> showGroupActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: _ChatGlassSurface(
          radius: 28,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: Text(
                    widget.thread.isChannel ? 'Channel info' : 'Group info',
                  ),
                  onTap: () => Navigator.pop(context, 'info'),
                ),
                if (!widget.thread.isChannel)
                  ListTile(
                    leading: const Icon(Icons.add_call),
                    title: const Text('Group call'),
                    onTap: () => Navigator.pop(context, 'call'),
                  ),
                ListTile(
                  leading: const Icon(Icons.search_rounded),
                  title: const Text('Search'),
                  onTap: () => Navigator.pop(context, 'search'),
                ),
                ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: const Text('Meeting points'),
                  onTap: () => Navigator.pop(context, 'meeting_points'),
                ),
                ListTile(
                  leading: const Icon(Icons.perm_media_outlined),
                  title: const Text('Media'),
                  onTap: () => Navigator.pop(context, 'media'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'info':
        openGroupInfo();
        break;
      case 'call':
        await startCall();
        break;
      case 'search':
        showSearchDialog();
        break;
      case 'meeting_points':
        await openMeetingPoints();
        break;
      case 'media':
        await openMediaList();
        break;
    }
  }

  Future<void> showMessageActions(ChatMessage message) async {
    final mine = message.senderNode == widget.controller.myNodeId;
    final pinned = widget.thread.pinnedMessageIds.contains(message.id);
    final canDownload =
        (message.kind == ChatMessageKind.file ||
            message.kind == ChatMessageKind.sticker) &&
        message.fileData.isNotEmpty;
    final canSaveSticker =
        message.kind == ChatMessageKind.sticker && message.fileData.isNotEmpty;
    final canEdit =
        mine &&
        (message.kind == ChatMessageKind.text ||
            message.kind == ChatMessageKind.file ||
            message.kind == ChatMessageKind.sticker);
    final canBlock =
        !mine && !widget.thread.isGroup && message.senderNode.isNotEmpty;
    final blocked = widget.controller.isBlocked(message.senderNode);
    final canReplyOrComment =
        !widget.thread.isChannel ||
        widget.controller.canCommentInChannel(widget.thread);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.32,
        maxChildSize: 0.92,
        builder: (context, scrollController) => SafeArea(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              _ReactionQuickBar(
                onSelected: (reaction) => Navigator.pop(context, reaction),
              ),
              if (mine && message.failed)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Retry'),
                  onTap: () => Navigator.pop(context, 'retry'),
                ),
              ListTile(
                leading: Icon(
                  widget.thread.isChannel
                      ? Icons.forum_outlined
                      : Icons.reply_rounded,
                ),
                title: Text(
                  widget.thread.isChannel && !canReplyOrComment
                      ? 'Comments disabled'
                      : widget.thread.isChannel
                      ? 'Comment'
                      : 'Reply',
                ),
                enabled: canReplyOrComment,
                onTap: canReplyOrComment
                    ? () => Navigator.pop(context, 'reply')
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.forward_rounded),
                title: const Text('Forward'),
                onTap: () => Navigator.pop(context, 'forward'),
              ),
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('Save to Saved Messages'),
                onTap: () => Navigator.pop(context, 'save'),
              ),
              if (canDownload)
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Download'),
                  onTap: () => Navigator.pop(context, 'download'),
                ),
              if (canSaveSticker)
                ListTile(
                  leading: const Icon(Icons.star_border_rounded),
                  title: const Text('Add sticker to favorites'),
                  onTap: () => Navigator.pop(context, 'favorite_sticker'),
                ),
              if (canSaveSticker)
                ListTile(
                  leading: const Icon(Icons.folder_special_outlined),
                  title: const Text('Add to sticker pack'),
                  subtitle: const Text('Saved stickers'),
                  onTap: () => Navigator.pop(context, 'save_sticker_pack'),
                ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: Text(
                    message.kind == ChatMessageKind.file ||
                            message.kind == ChatMessageKind.sticker
                        ? 'Edit caption'
                        : 'Edit',
                  ),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
              ListTile(
                leading: Icon(
                  pinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(pinned ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(context, 'pin'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Delete for me'),
                textColor: Colors.redAccent,
                iconColor: Colors.redAccent,
                onTap: () => Navigator.pop(context, 'delete_me'),
              ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined),
                  title: const Text('Delete for everyone'),
                  textColor: Colors.redAccent,
                  iconColor: Colors.redAccent,
                  onTap: () => Navigator.pop(context, 'delete_everyone'),
                ),
              if (canBlock)
                ListTile(
                  leading: Icon(
                    blocked ? Icons.visibility_rounded : Icons.block_rounded,
                  ),
                  title: Text(blocked ? 'Unblock user' : 'Block user'),
                  textColor: blocked ? null : Colors.redAccent,
                  iconColor: blocked ? null : Colors.redAccent,
                  onTap: () => Navigator.pop(context, 'block'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'retry') {
      final error = await widget.controller.retryMessage(
        widget.thread,
        message,
      );
      if (!mounted) return;
      showSnack(error ?? 'Retrying');
      return;
    }
    if (action == 'reply') {
      if (widget.thread.isChannel && !isChannelCommentThread) {
        await openChannelComments(message);
      } else {
        setState(() => replyTo = message);
      }
      return;
    }
    if (action == 'forward') {
      await showForwardDialog(message);
      return;
    }
    if (action == 'save') {
      final error = await widget.controller.saveMessageToSaved(message);
      if (!mounted) return;
      showSnack(error ?? 'Saved');
      return;
    }
    if (action == 'download') {
      await downloadMessageFile(message);
      return;
    }
    if (action == 'favorite_sticker' || action == 'save_sticker_pack') {
      final error = await widget.controller.saveStickerFromMessage(
        message,
        favorite: action == 'favorite_sticker',
      );
      if (!mounted) return;
      showSnack(
        error ??
            (action == 'favorite_sticker'
                ? 'Sticker added to favorites'
                : 'Sticker added to Saved stickers'),
      );
      return;
    }
    if (action == 'edit') {
      await showEditDialog(message);
      return;
    }
    if (action == 'delete_me' || action == 'delete_everyone') {
      setState(() => deletingMessageIds.add(message.id));
      await Future.delayed(const Duration(milliseconds: 540));
      if (!mounted) return;
      if (action == 'delete_everyone') {
        await widget.controller.deleteMessage(widget.thread, message);
      } else {
        await widget.controller.deleteMessageForMe(widget.thread, message);
      }
      if (mounted) {
        setState(() => deletingMessageIds.remove(message.id));
      }
      return;
    }
    if (action == 'pin') {
      widget.controller.togglePin(widget.thread, message);
      return;
    }
    if (action == 'block') {
      await widget.controller.toggleBlocked(message.senderNode);
      if (!mounted) return;
      showSnack(blocked ? 'User unblocked' : 'User blocked');
      return;
    }
    await widget.controller.sendReaction(widget.thread, message, action);
  }

  Future<void> openChannelComments(ChatMessage post) async {
    if (!widget.thread.isChannel || post.replyToMessageId.isNotEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          controller: widget.controller,
          thread: widget.thread,
          channelPost: post,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> showForwardDialog(ChatMessage message) async {
    final targets = widget.controller.sortedThreads.where((thread) {
      final key = thread.isGroup ? thread.groupId : thread.profile.nodeId;
      final currentKey = widget.thread.isGroup
          ? widget.thread.groupId
          : widget.thread.profile.nodeId;
      return key.isNotEmpty && key != currentKey;
    }).toList();
    if (targets.isEmpty) {
      showSnack('No chats to forward to');
      return;
    }
    final target = await showDialog<ChatThread>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forward to'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: targets.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final target = targets[index];
              return ListTile(
                leading: ProfileAvatar(profile: target.profile, radius: 18),
                title: Text(
                  target.profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(target.isGroup ? 'Group' : 'Chat'),
                onTap: () => Navigator.pop(context, target),
              );
            },
          ),
        ),
      ),
    );
    if (!mounted || target == null) return;
    final error = await widget.controller.forwardMessage(message, target);
    if (!mounted) return;
    showSnack(error ?? 'Forwarded');
  }

  Future<void> downloadMessageFile(ChatMessage message) async {
    if ((message.kind != ChatMessageKind.file &&
            message.kind != ChatMessageKind.sticker) ||
        message.fileData.isEmpty) {
      showSnack('File is not cached');
      return;
    }
    final filename = safeFilename(
      message.fileName.isEmpty ? 'meshchat_file' : message.fileName,
    );
    final bytes = hexDecode(message.fileData);
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: filename,
        bytes: bytes,
      );
      if (!mounted) return;
      if (kIsWeb) {
        showSnack('Downloaded');
        return;
      }
      if (savedPath != null && savedPath.isNotEmpty) {
        await XFile.fromData(bytes, name: filename).saveTo(savedPath);
        showSnack('Saved');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, filename);
      await XFile.fromData(bytes, name: filename).saveTo(path);
      await OpenFilex.open(path);
    } catch (_) {
      if (!mounted) return;
      showSnack('Could not save file');
    }
  }

  Future<void> showEditDialog(ChatMessage message) async {
    final editInput = TextEditingController(text: message.text);
    final isCaption =
        message.kind == ChatMessageKind.file ||
        message.kind == ChatMessageKind.sticker;
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isCaption ? 'Edit caption' : 'Edit message'),
        content: TextField(
          controller: editInput,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: isCaption ? 'Caption' : 'Message',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editInput.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    editInput.dispose();
    if (!mounted || edited == null) return;
    if (!isCaption && edited.trim().isEmpty) return;
    await widget.controller.editMessage(widget.thread, message, edited);
  }

  Future<void> showSearchDialog() async {
    final searchInput = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final results = widget.controller.searchMessages(
            widget.thread,
            searchInput.text,
          );
          return AlertDialog(
            title: const Text('Search'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchInput,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final message = results[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            replyPreview(message),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(messageTime(message.createdAt)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    searchInput.dispose();
  }

  Future<void> openPinnedMessages() async {
    final pinned = widget.thread.pinnedMessages;
    if (pinned.isEmpty) return;
    if (pinned.length == 1) {
      jumpToMessage(pinned.first);
      return;
    }
    final selected = await showModalBottomSheet<ChatMessage>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: pinned.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final message = pinned[index];
            return ListTile(
              leading: const Icon(Icons.push_pin),
              title: Text(
                replyPreview(message),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(messageTime(message.createdAt)),
              onTap: () => Navigator.pop(context, message),
            );
          },
        ),
      ),
    );
    if (selected != null) jumpToMessage(selected);
  }

  void jumpToMessage(ChatMessage message) => jumpToMessageById(message.id);

  void jumpToMessageById(String messageId) {
    final index = widget.thread.messages.indexWhere(
      (candidate) => candidate.id == messageId,
    );
    if (index < 0 || !scroll.hasClients) return;
    final offset = (index * 92.0).clamp(0.0, scroll.position.maxScrollExtent);
    scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> openMediaList() async {
    final messageId = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ChatMediaPage(thread: widget.thread)),
    );
    if (!mounted || messageId == null || messageId.isEmpty) return;
    jumpToMessageById(messageId);
  }

  Future<void> openMeetingPoints() async {
    final messageId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => MeetingPointsPage(
          controller: widget.controller,
          thread: widget.thread,
        ),
      ),
    );
    if (!mounted || messageId == null || messageId.isEmpty) return;
    jumpToMessageById(messageId);
  }

  bool isAlbumPhoto(ChatMessage message) {
    return !message.deleted &&
        message.kind == ChatMessageKind.file &&
        isImageName(message.fileName) &&
        message.fileData.isNotEmpty &&
        message.text.trim().isEmpty;
  }

  bool sameAlbumPhoto(ChatMessage a, ChatMessage b) {
    return isAlbumPhoto(a) &&
        isAlbumPhoto(b) &&
        a.senderNode == b.senderNode &&
        sameDay(a.createdAt, b.createdAt) &&
        b.createdAt.difference(a.createdAt).inMinutes.abs() <= 5;
  }

  bool isCoveredByAlbum(List<ChatMessage> messages, int index) {
    return index > 0 && sameAlbumPhoto(messages[index - 1], messages[index]);
  }

  List<ChatMessage> albumFrom(List<ChatMessage> messages, int index) {
    final album = <ChatMessage>[messages[index]];
    for (var next = index + 1; next < messages.length; next++) {
      if (!sameAlbumPhoto(album.last, messages[next])) break;
      album.add(messages[next]);
      if (album.length >= 10) break;
    }
    return album;
  }

  Future<void> startCall() async {
    final error = widget.thread.isGroup
        ? await widget.controller.startGroupCall(widget.thread)
        : await widget.controller.startCall(widget.thread.profile);
    if (!mounted || error == null) return;
    showSnack(error);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: _ChatRoundButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            onPressed: () => Navigator.maybePop(context),
          ),
        ),
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final profile = widget.thread.profile;
            final isSavedMessages = widget.controller.isSavedMessagesProfile(
              profile,
            );
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.thread.isGroup ? openGroupInfo : openProfile,
              child: Row(
                children: [
                  _ChatAvatarRing(profile: profile),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isChannelCommentThread
                              ? 'Comments'
                              : profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          isChannelCommentThread
                              ? profile.displayName
                              : widget.thread.isGroup
                              ? widget.thread.isChannel
                                    ? '${widget.thread.members.length} subscribers'
                                    : '${widget.thread.members.length} members'
                              : isSavedMessages
                              ? 'private notes'
                              : profile.online
                              ? 'online'
                              : 'offline',
                          style: TextStyle(
                            fontSize: 12,
                            color: widget.thread.isGroup || profile.online
                                ? Colors.greenAccent
                                : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          if (widget.thread.isGroup)
            _ChatRoundButton(
              tooltip: 'Group actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onPressed: showGroupActions,
            )
          else ...[
            if (!widget.controller.isSavedMessagesProfile(
              widget.thread.profile,
            ))
              _ChatRoundButton(
                tooltip: 'Call',
                icon: const Icon(Icons.call_outlined),
                onPressed: startCall,
              ),
            _ChatRoundButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search_rounded),
              onPressed: showSearchDialog,
            ),
            _ChatRoundButton(
              tooltip: 'Media',
              icon: const Icon(Icons.perm_media_outlined),
              onPressed: openMediaList,
            ),
          ],
          const SizedBox(width: 6),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _LiquidMeshBackground(
              enabled: !widget.controller.appSettings.reducedAnimations,
            ),
          ),
          Column(
            children: [
              ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PinnedBar(
                      thread: widget.thread,
                      onTap: openPinnedMessages,
                    ),
                    _CallBanner(controller: widget.controller),
                    if (widget.controller.isTyping(widget.thread))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                        child: _ChatGlassSurface(
                          radius: 16,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 7,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.controller.activityLabel(widget.thread),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) {
                    final messages = visibleMessages();
                    scheduleInitialScrollToBottom(messages.length);
                    return ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        if (isCoveredByAlbum(messages, index)) {
                          return const SizedBox.shrink();
                        }
                        final album = albumFrom(messages, index);
                        final showDate =
                            index == 0 ||
                            !sameDay(
                              messages[index - 1].createdAt,
                              message.createdAt,
                            );
                        return Column(
                          children: [
                            if (showDate) _DatePill(date: message.createdAt),
                            if (album.length > 1)
                              _PhotoAlbumBubble(
                                messages: album,
                                mine:
                                    message.senderNode ==
                                    widget.controller.myNodeId,
                                dataSaver:
                                    widget.controller.appSettings.dataSaver,
                                onLongPress: () =>
                                    showMessageActions(album.last),
                                onReply: () =>
                                    setState(() => replyTo = album.last),
                              )
                            else
                              _MessageDisintegrator(
                                deleting: deletingMessageIds.contains(
                                  message.id,
                                ),
                                child: _MessageBubble(
                                  controller: widget.controller,
                                  thread: widget.thread,
                                  message: message,
                                  mine:
                                      message.senderNode ==
                                      widget.controller.myNodeId,
                                  dataSaver:
                                      widget.controller.appSettings.dataSaver,
                                  onLongPress: () =>
                                      showMessageActions(message),
                                  onReply: () =>
                                      widget.thread.isChannel &&
                                          !isChannelCommentThread
                                      ? openChannelComments(message)
                                      : setState(() => replyTo = message),
                                  onOpenComments:
                                      widget.thread.isChannel &&
                                          !isChannelCommentThread &&
                                          message.replyToMessageId.isEmpty
                                      ? () => openChannelComments(message)
                                      : null,
                                  commentCount: commentCountFor(message),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                  child: _ChatGlassSurface(
                    radius: 24,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                      child: canPostToThread
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (replyTo != null) ...[
                                  _ReplyComposer(
                                    message: replyTo!,
                                    onCancel: () =>
                                        setState(() => replyTo = null),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Row(
                                  children: [
                                    if (!recording) ...[
                                      _ComposerIconButton(
                                        tooltip: 'Attach',
                                        onPressed: showAttachMenu,
                                        icon: Icons.attach_file_rounded,
                                      ),
                                      const SizedBox(width: 6),
                                      _ComposerIconButton(
                                        tooltip: 'Stickers',
                                        onPressed: showStickerPanel,
                                        icon: Icons.auto_awesome_motion_rounded,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(
                                      child: _ComposerInputSurface(
                                        child: recording
                                            ? Transform.translate(
                                                offset: Offset(
                                                  voiceCancelDrag * 0.22,
                                                  0,
                                                ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      voiceCancelArmed
                                                          ? Icons.delete_rounded
                                                          : Icons.mic_rounded,
                                                      color: voiceCancelArmed
                                                          ? Colors.redAccent
                                                          : Colors
                                                                .lightBlueAccent,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          _Waveform(
                                                            levels:
                                                                recordLevels,
                                                          ),
                                                          const SizedBox(
                                                            height: 3,
                                                          ),
                                                          Text(
                                                            voiceCancelArmed
                                                                ? 'Release to cancel'
                                                                : 'Release to send · slide left to cancel',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color:
                                                                  voiceCancelArmed
                                                                  ? Colors
                                                                        .redAccent
                                                                  : Colors
                                                                        .white54,
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      recordDuration(),
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              )
                                            : Focus(
                                                focusNode: inputFocus,
                                                onKeyEvent: handleInputKey,
                                                child: TextField(
                                                  controller: input,
                                                  minLines: 1,
                                                  maxLines: 5,
                                                  textCapitalization:
                                                      TextCapitalization
                                                          .sentences,
                                                  keyboardType:
                                                      TextInputType.multiline,
                                                  textInputAction:
                                                      desktopSendHotkeys
                                                      ? TextInputAction.send
                                                      : TextInputAction.newline,
                                                  decoration:
                                                      const InputDecoration(
                                                        hintText: 'Message',
                                                        isDense: true,
                                                        filled: false,
                                                        border:
                                                            InputBorder.none,
                                                      ),
                                                  onTap:
                                                      scheduleKeyboardScrollToBottom,
                                                  onSubmitted:
                                                      desktopSendHotkeys
                                                      ? (_) => send()
                                                      : null,
                                                ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (recording && !voicePointerDown)
                                      _ComposerIconButton(
                                        tooltip: 'Cancel',
                                        onPressed: cancelRecording,
                                        icon: Icons.close_rounded,
                                        accent: Colors.redAccent,
                                      )
                                    else
                                      AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        transitionBuilder: (child, animation) =>
                                            ScaleTransition(
                                              scale: CurvedAnimation(
                                                parent: animation,
                                                curve: Curves.easeOutBack,
                                              ),
                                              child: FadeTransition(
                                                opacity: animation,
                                                child: child,
                                              ),
                                            ),
                                        child: hasInputText && !recording
                                            ? _ComposerIconButton(
                                                key: const ValueKey('send'),
                                                tooltip: 'Send',
                                                onPressed: send,
                                                icon: Icons.send_rounded,
                                                accent: Colors.lightBlueAccent,
                                              )
                                            : _VoiceHoldButton(
                                                key: const ValueKey('mic'),
                                                onStart: startVoiceHold,
                                                onDragUpdate:
                                                    updateVoiceHoldDrag,
                                                onFinish: () =>
                                                    finishVoiceHold(send: true),
                                                onCancel: () => finishVoiceHold(
                                                  send: false,
                                                ),
                                              ),
                                      ),
                                  ],
                                ),
                              ],
                            )
                          : const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.campaign_outlined,
                                    color: Colors.white54,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Only channel admins can post',
                                      style: TextStyle(color: Colors.white60),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 88,
            child: IgnorePointer(
              ignoring: !showJumpToBottom,
              child: AnimatedOpacity(
                opacity: showJumpToBottom ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Center(
                  child: _ChatRoundButton(
                    tooltip: 'Jump to latest',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: scrollToBottom,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 92,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final call = widget.controller.activeCall;
                if (call == null ||
                    call.collapsed ||
                    call.status == CallStatus.ended) {
                  return const SizedBox.shrink();
                }
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: 1 - value,
                      child: Transform.translate(
                        offset: Offset(0, 72 * value),
                        child: child,
                      ),
                    );
                  },
                  child: _CallBottomSheet(controller: widget.controller),
                );
              },
            ),
          ),
          InAppMessageBanner(
            controller: widget.controller,
            top: MediaQuery.paddingOf(context).top + 8,
            onOpen: (thread) {
              if (thread == widget.thread) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ChatPage(controller: widget.controller, thread: thread),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CallBanner extends StatelessWidget {
  const _CallBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.activeCall;
    if (call == null) return const SizedBox.shrink();
    if (call.collapsed && call.status != CallStatus.ended) {
      return _MiniCallPanel(controller: controller);
    }
    if (!call.collapsed && call.status != CallStatus.ended) {
      return const SizedBox.shrink();
    }
    if (call.status == CallStatus.ended) {
      return _CallPanel(
        icon: Icons.call_end_rounded,
        title: 'Call ended',
        subtitle: call.endReason.isEmpty
            ? call.peer.displayName
            : '${call.peer.displayName} - ${call.endReason}',
        color: Colors.redAccent,
        actions: [
          TextButton(
            onPressed: controller.clearEndedCall,
            child: const Text('Close'),
          ),
        ],
      );
    }
    if (call.status == CallStatus.ringing && call.incoming) {
      return _CallPanel(
        icon: Icons.call_rounded,
        title: 'Incoming call',
        subtitle: call.peer.displayName,
        color: Colors.greenAccent,
        actions: [
          IconButton.filledTonal(
            tooltip: 'Hide',
            onPressed: controller.toggleCallCollapsed,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
          TextButton(
            onPressed: controller.declineCall,
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: controller.acceptCall,
            child: const Text('Accept'),
          ),
        ],
      );
    }
    final active = call.status == CallStatus.active;
    final subtitleParts = <String>[
      call.peer.displayName,
      formatDuration(controller.callElapsed),
      controller.callQualityLabel,
      if (controller.callParticipantsLabel.isNotEmpty)
        controller.callParticipantsLabel,
      if (call.localMuted) 'muted',
    ].where((part) => part.isNotEmpty).join(' - ');
    return _CallPanel(
      icon: active ? Icons.call_rounded : Icons.call_made_rounded,
      title: active ? 'Call active' : 'Calling...',
      subtitle: subtitleParts,
      color: active ? Colors.greenAccent : Colors.orangeAccent,
      participants: call.isGroup ? controller.callParticipants : const [],
      connectedNodeIds: call.connectedNodes,
      localNodeId: controller.myNodeId,
      mutedNodeIds: call.localMuted ? {controller.myNodeId} : const {},
      actions: [
        IconButton.filledTonal(
          tooltip: 'Hide',
          onPressed: controller.toggleCallCollapsed,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
        IconButton.filledTonal(
          tooltip: call.localMuted ? 'Unmute' : 'Mute',
          onPressed: controller.toggleCallMute,
          icon: Icon(call.localMuted ? Icons.mic_off : Icons.mic),
        ),
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
      ],
    );
  }
}

class _CallBottomSheet extends StatelessWidget {
  const _CallBottomSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.activeCall;
    if (call == null) return const SizedBox.shrink();
    final incoming = call.status == CallStatus.ringing && call.incoming;
    final active = call.status == CallStatus.active;
    final title = incoming
        ? 'Incoming call'
        : active
        ? 'Call active'
        : 'Calling...';
    final accent = incoming || active
        ? Colors.lightBlueAccent
        : const Color(0xFF7D8CFF);

    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            color: const Color(0xD8232D38),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: [
              BoxShadow(
                color: Colors.lightBlueAccent.withValues(alpha: 0.08),
                blurRadius: 28,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.34),
                blurRadius: 30,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: _CallGlassButton(
                    tooltip: 'Collapse',
                    icon: Icons.keyboard_arrow_down_rounded,
                    onPressed: controller.toggleCallCollapsed,
                  ),
                ),
                const _CallMeshLogo(),
                const SizedBox(height: 12),
                Text(
                  call.peer.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$title · ${formatDuration(controller.callElapsed)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                _CallStatusStrip(controller: controller),
                const SizedBox(height: 18),
                _CallEqualizer(accent: accent),
                const SizedBox(height: 24),
                if (incoming)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CallGlassButton(
                        tooltip: 'Decline',
                        icon: Icons.call_end_rounded,
                        accent: Colors.redAccent,
                        onPressed: controller.declineCall,
                      ),
                      const SizedBox(width: 34),
                      _CallGlassButton(
                        tooltip: 'Accept',
                        icon: Icons.call_rounded,
                        accent: Colors.greenAccent,
                        onPressed: controller.acceptCall,
                      ),
                    ],
                  )
                else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallGlassButton(
                        tooltip: call.speakerOn ? 'Speaker off' : 'Speaker on',
                        icon: call.speakerOn
                            ? Icons.volume_up_rounded
                            : Icons.hearing_rounded,
                        onPressed: controller.toggleCallSpeaker,
                      ),
                      _CallGlassButton(
                        tooltip: call.localMuted ? 'Unmute' : 'Mute',
                        icon: call.localMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        onPressed: controller.toggleCallMute,
                      ),
                      _CallGlassButton(
                        tooltip: 'Input',
                        icon: Icons.input_rounded,
                        onPressed: () =>
                            _showAudioDevicePicker(context, input: true),
                      ),
                      _CallGlassButton(
                        tooltip: 'Output',
                        icon: Icons.headphones_rounded,
                        onPressed: () =>
                            _showAudioDevicePicker(context, input: false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: 138,
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      onPressed: controller.endCall,
                      child: const Icon(Icons.call_end_rounded, size: 28),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAudioDevicePicker(BuildContext context, {required bool input}) {
    unawaited(controller.refreshCallAudioDevices());
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final devices = input
                ? controller.callAudioInputs
                : controller.callAudioOutputs;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xE61A2530),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 420),
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          children: [
                            ListTile(
                              leading: Icon(
                                input
                                    ? Icons.input_rounded
                                    : Icons.headphones_rounded,
                                color: Colors.lightBlueAccent,
                              ),
                              title: Text(
                                input ? 'Audio input' : 'Audio output',
                              ),
                              subtitle: Text(
                                devices.isEmpty
                                    ? 'No devices reported by the system yet'
                                    : 'Choose device for this call',
                              ),
                            ),
                            ListTile(
                              leading: const Icon(Icons.auto_awesome_rounded),
                              title: const Text('System default'),
                              onTap: () {
                                Navigator.pop(context);
                                if (input) {
                                  unawaited(
                                    controller.selectCallAudioInput(''),
                                  );
                                } else {
                                  unawaited(
                                    controller.selectCallAudioOutput(''),
                                  );
                                }
                              },
                            ),
                            for (final device in devices)
                              ListTile(
                                leading: Icon(
                                  input
                                      ? Icons.settings_input_component_rounded
                                      : Icons.speaker_rounded,
                                ),
                                title: Text(
                                  device.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  if (input) {
                                    unawaited(
                                      controller.selectCallAudioInput(
                                        device.id,
                                      ),
                                    );
                                  } else {
                                    unawaited(
                                      controller.selectCallAudioOutput(
                                        device.id,
                                      ),
                                    );
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CallMeshLogo extends StatelessWidget {
  const _CallMeshLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 128,
      height: 92,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            child: Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF39D6FF).withValues(alpha: 0.30),
                    blurRadius: 36,
                    spreadRadius: 6,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 0,
            child: Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB463FF).withValues(alpha: 0.28),
                    blurRadius: 36,
                    spreadRadius: 6,
                  ),
                ],
              ),
            ),
          ),
          const CustomPaint(
            size: Size(116, 78),
            painter: _CallMeshLogoPainter(),
          ),
        ],
      ),
    );
  }
}

class _CallMeshLogoPainter extends CustomPainter {
  const _CallMeshLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final left = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF39D6FF), Color(0xFF6B8DFF)],
      ).createShader(Offset.zero & size)
      ..strokeWidth = 5.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final right = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF6B8DFF), Color(0xFFB463FF)],
      ).createShader(Offset.zero & size)
      ..strokeWidth = 5.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final nodePaint = Paint()..style = PaintingStyle.fill;

    final points = [
      Offset(size.width * 0.08, size.height * 0.86),
      Offset(size.width * 0.18, size.height * 0.12),
      Offset(size.width * 0.50, size.height * 0.58),
      Offset(size.width * 0.82, size.height * 0.12),
      Offset(size.width * 0.92, size.height * 0.86),
    ];
    canvas.drawLine(points[0], points[1], left);
    canvas.drawLine(points[1], points[2], left);
    canvas.drawLine(points[2], points[3], right);
    canvas.drawLine(points[3], points[4], right);

    for (var i = 0; i < points.length; i++) {
      nodePaint.color = i < 3
          ? const Color(0xFF4DD7FF)
          : const Color(0xFFB463FF);
      canvas.drawCircle(points[i], 6.4, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CallGlassButton extends StatelessWidget {
  const _CallGlassButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.accent = Colors.white70,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: Colors.white.withValues(alpha: 0.12),
            child: InkWell(
              onTap: onPressed,
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Icon(icon, color: accent, size: 27),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallStatusStrip extends StatelessWidget {
  const _CallStatusStrip({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.activeCall;
    if (call == null) return const SizedBox.shrink();
    final connected = call.status == CallStatus.active;
    final statusText = call.status == CallStatus.ringing && call.incoming
        ? 'Incoming'
        : connected
        ? 'Connected'
        : 'Connecting';
    final qualityText = connected
        ? call.quality <= 1
              ? 'Weak'
              : 'Good'
        : 'Waiting audio';
    final participants = controller.callParticipantsLabel;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _CallInfoPill(
          icon: connected ? Icons.link_rounded : Icons.sync_rounded,
          label: statusText,
          accent: connected ? Colors.greenAccent : Colors.lightBlueAccent,
        ),
        _CallInfoPill(
          icon: call.quality <= 1
              ? Icons.signal_cellular_alt_1_bar
              : Icons.network_cell,
          label: qualityText,
          accent: call.quality <= 1 ? Colors.orangeAccent : Colors.greenAccent,
        ),
        if (call.localMuted)
          const _CallInfoPill(
            icon: Icons.mic_off_rounded,
            label: 'Muted',
            accent: Colors.redAccent,
          ),
        if (participants.isNotEmpty)
          _CallInfoPill(
            icon: Icons.groups_rounded,
            label: participants,
            accent: Colors.purpleAccent,
          ),
      ],
    );
  }
}

class _CallInfoPill extends StatelessWidget {
  const _CallInfoPill({
    required this.icon,
    required this.label,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.085),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.12), blurRadius: 14),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _CallEqualizer extends StatefulWidget {
  const _CallEqualizer({required this.accent});

  final Color accent;

  @override
  State<_CallEqualizer> createState() => _CallEqualizerState();
}

class _CallEqualizerState extends State<_CallEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final values = <double>[
      0.20,
      0.36,
      0.52,
      0.78,
      0.42,
      0.28,
      0.62,
      0.86,
      0.46,
      0.32,
      0.58,
      0.74,
      0.44,
      0.30,
      0.54,
      0.68,
      0.38,
      0.24,
    ];
    return SizedBox(
      height: 58,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var index = 0; index < values.length; index++)
                _EqualizerBar(
                  value:
                      values[index] *
                      (0.68 +
                          0.32 *
                              math
                                  .sin(
                                    controller.value * math.pi * 2 +
                                        index * 0.78,
                                  )
                                  .abs()),
                  color: Color.lerp(
                    const Color(0xFF39D6FF),
                    const Color(0xFFB463FF),
                    index / (values.length - 1),
                  )!,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EqualizerBar extends StatelessWidget {
  const _EqualizerBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: 4.5,
      height: 12 + value * 42,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.92),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.42),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class _ChatAvatarRing extends StatelessWidget {
  const _ChatAvatarRing({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final tag = 'profile-avatar-${profile.nodeId}';
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      placeholderBuilder: (context, size, child) => child,
      flightShuttleBuilder:
          (context, animation, direction, fromContext, toContext) =>
              direction == HeroFlightDirection.push
              ? toContext.widget
              : fromContext.widget,
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: ProfileAvatar(profile: profile, radius: 19),
      ),
    );
  }
}

class _ChatRoundButton extends StatelessWidget {
  const _ChatRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: Tooltip(
        message: tooltip,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Material(
              color: Colors.white.withValues(alpha: 0.10),
              shape: CircleBorder(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: InkWell(
                onTap: onPressed,
                customBorder: const CircleBorder(),
                child: SizedBox(width: 42, height: 42, child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerInputSurface extends StatelessWidget {
  const _ComposerInputSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: child,
    );
  }
}

class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.accent = Colors.white70,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Material(
            color: Colors.white.withValues(alpha: 0.11),
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: 42,
                height: 42,
                child: Icon(icon, color: accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceHoldButton extends StatefulWidget {
  const _VoiceHoldButton({
    super.key,
    required this.onStart,
    required this.onDragUpdate,
    required this.onFinish,
    required this.onCancel,
  });

  final Future<void> Function() onStart;
  final ValueChanged<double> onDragUpdate;
  final Future<void> Function() onFinish;
  final Future<void> Function() onCancel;

  @override
  State<_VoiceHoldButton> createState() => _VoiceHoldButtonState();
}

class _VoiceHoldButtonState extends State<_VoiceHoldButton> {
  bool pressed = false;
  int? pointer;

  Future<void> _start() async {
    if (pressed) return;
    setState(() => pressed = true);
    await widget.onStart();
  }

  Future<void> _finish() async {
    if (!pressed) return;
    pointer = null;
    setState(() => pressed = false);
    await widget.onFinish();
  }

  Future<void> _cancel() async {
    if (!pressed) return;
    pointer = null;
    setState(() => pressed = false);
    await widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Hold to record',
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (pointer != null) return;
          pointer = event.pointer;
          unawaited(_start());
        },
        onPointerMove: (event) {
          if (pointer != event.pointer) return;
          widget.onDragUpdate(event.delta.dx);
        },
        onPointerUp: (event) {
          if (pointer != event.pointer) return;
          unawaited(_finish());
        },
        onPointerCancel: (event) {
          if (pointer != event.pointer) return;
          unawaited(_cancel());
        },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: pressed ? 1.08 : 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (pressed ? Colors.redAccent : Colors.white).withValues(
                    alpha: pressed ? 0.22 : 0.11,
                  ),
                  border: Border.all(
                    color: (pressed ? Colors.redAccent : Colors.white)
                        .withValues(alpha: pressed ? 0.34 : 0.10),
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    if (pressed)
                      BoxShadow(
                        color: Colors.redAccent.withValues(alpha: 0.22),
                        blurRadius: 18,
                      ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (pressed)
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 520),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) => Container(
                          width: 22 + value * 17,
                          height: 22 + value * 17,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.redAccent.withValues(
                                alpha: (0.34 * (1 - value)).clamp(0.0, 1.0),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Icon(
                      pressed ? Icons.mic_rounded : Icons.mic_none_rounded,
                      color: pressed ? Colors.redAccent : Colors.white70,
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

class _GlassSheetAction extends StatelessWidget {
  const _GlassSheetAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      leading: CircleAvatar(
        backgroundColor: Colors.white.withValues(alpha: 0.10),
        child: Icon(icon, color: Colors.lightBlueAccent),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60)),
      onTap: onTap,
    );
  }
}

class _StickerSheet extends StatefulWidget {
  const _StickerSheet({
    required this.controller,
    required this.onSend,
    required this.onAddSticker,
    required this.onCreatePack,
    required this.onToggleFavorite,
  });

  final AppController controller;
  final ValueChanged<StickerItem> onSend;
  final Future<void> Function([String? packId]) onAddSticker;
  final Future<void> Function() onCreatePack;
  final Future<void> Function(String stickerId) onToggleFavorite;

  @override
  State<_StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<_StickerSheet> {
  String selectedPackId = 'favorites';

  @override
  Widget build(BuildContext context) {
    final packs = widget.controller.stickerPacks;
    final matchingPack = packs.where((pack) => pack.id == selectedPackId);
    final stickers = selectedPackId == 'favorites'
        ? widget.controller.favoriteStickers
        : matchingPack.isEmpty
        ? const <StickerItem>[]
        : matchingPack.first.stickers;
    final addPackId = selectedPackId == 'favorites'
        ? (packs.isEmpty ? null : packs.first.id)
        : selectedPackId;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          MediaQuery.viewInsetsOf(context).bottom + 14,
        ),
        child: _ChatGlassSurface(
          radius: 30,
          child: SizedBox(
            height: math.min(MediaQuery.sizeOf(context).height * 0.7, 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_motion_rounded,
                        color: Colors.lightBlueAccent,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Stickers',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              'Add PNG, GIF or WebP and send them like packs.',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _StickerRoundButton(
                        tooltip: 'New pack',
                        icon: Icons.create_new_folder_rounded,
                        onTap: widget.onCreatePack,
                      ),
                      const SizedBox(width: 8),
                      _StickerRoundButton(
                        tooltip: 'Add sticker',
                        icon: Icons.add_photo_alternate_rounded,
                        onTap: () => widget.onAddSticker(addPackId),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 38,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _StickerPackChip(
                          label: 'Favorites',
                          icon: Icons.star_rounded,
                          selected: selectedPackId == 'favorites',
                          onTap: () =>
                              setState(() => selectedPackId = 'favorites'),
                        ),
                        for (final pack in packs) ...[
                          const SizedBox(width: 8),
                          _StickerPackChip(
                            label: pack.name,
                            icon: Icons.folder_special_rounded,
                            selected: selectedPackId == pack.id,
                            onTap: () =>
                                setState(() => selectedPackId = pack.id),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: stickers.isEmpty
                        ? _StickerEmptyState(
                            onAdd: () => widget.onAddSticker(addPackId),
                          )
                        : GridView.builder(
                            itemCount: stickers.length,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 116,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                ),
                            itemBuilder: (context, index) {
                              final sticker = stickers[index];
                              return _StickerTile(
                                sticker: sticker,
                                favorite: widget
                                    .controller
                                    .stickerLibrary
                                    .favoriteIds
                                    .contains(sticker.id),
                                onTap: () => widget.onSend(sticker),
                                onFavorite: () =>
                                    widget.onToggleFavorite(sticker.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StickerRoundButton extends StatelessWidget {
  const _StickerRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Icon(icon, size: 20, color: Colors.white70),
        ),
      ),
    );
  }
}

class _StickerPackChip extends StatelessWidget {
  const _StickerPackChip({
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
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected
              ? Colors.lightBlueAccent.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.07),
          border: Border.all(
            color: selected
                ? Colors.lightBlueAccent.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.lightBlueAccent.withValues(alpha: 0.16),
                    blurRadius: 18,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.lightBlueAccent),
            const SizedBox(width: 7),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _StickerEmptyState extends StatelessWidget {
  const _StickerEmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome_motion_rounded,
            size: 44,
            color: Colors.white.withValues(alpha: 0.32),
          ),
          const SizedBox(height: 10),
          const Text(
            'No stickers here yet',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          const Text(
            'Add your own animated GIF/WebP or a PNG.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_photo_alternate_rounded),
            label: const Text('Add sticker'),
          ),
        ],
      ),
    );
  }
}

class _StickerTile extends StatelessWidget {
  const _StickerTile({
    required this.sticker,
    required this.favorite,
    required this.onTap,
    required this.onFavorite,
  });

  final StickerItem sticker;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Colors.white.withValues(alpha: 0.07),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Stack(
            children: [
              Center(
                child: Image.memory(
                  sticker.bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_rounded,
                    color: Colors.white38,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                child: GestureDetector(
                  onTap: onFavorite,
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.black.withValues(alpha: 0.32),
                    child: Icon(
                      favorite ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 17,
                      color: favorite
                          ? const Color(0xFFFFD166)
                          : Colors.white70,
                    ),
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

class _MessageDisintegrator extends StatelessWidget {
  const _MessageDisintegrator({required this.deleting, required this.child});

  final bool deleting;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: deleting ? 1 : 0),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeInOutCubic,
      builder: (context, value, child) {
        final opacity = (1 - value * 1.15).clamp(0.0, 1.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: 1 - value * 0.045,
                alignment: Alignment.center,
                child: child,
              ),
            ),
            if (value > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _DisintegratePainter(progress: value),
                  ),
                ),
              ),
          ],
        );
      },
      child: child,
    );
  }
}

class _DisintegratePainter extends CustomPainter {
  const _DisintegratePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fade = (1 - progress).clamp(0.0, 1.0);
    final colors = [
      Colors.white.withValues(alpha: 0.72 * fade),
      Colors.lightBlueAccent.withValues(alpha: 0.82 * fade),
      const Color(0xFFA56CFF).withValues(alpha: 0.72 * fade),
    ];
    for (var i = 0; i < 28; i++) {
      final seed = i * 12.9898;
      final x = (math.sin(seed) * 0.5 + 0.5) * size.width;
      final y = (math.cos(seed * 1.71) * 0.5 + 0.5) * size.height;
      final angle = -math.pi / 2 + math.sin(seed * 0.37) * math.pi;
      final distance = progress * (12 + (i % 7) * 5);
      final offset = Offset(
        x + math.cos(angle) * distance,
        y + math.sin(angle) * distance,
      );
      final radius = (1.3 + (i % 4) * 0.45) * (0.5 + fade * 0.5);
      canvas.drawCircle(
        offset,
        radius,
        Paint()
          ..color = colors[i % colors.length]
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DisintegratePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _DatePill extends StatelessWidget {
  const _DatePill({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _ChatGlassSurface(
        radius: 999,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          child: Text(
            dateLabel(date),
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

class _LiquidMeshBackground extends StatefulWidget {
  const _LiquidMeshBackground({required this.enabled});

  final bool enabled;

  @override
  State<_LiquidMeshBackground> createState() => _LiquidMeshBackgroundState();
}

class _LiquidMeshBackgroundState extends State<_LiquidMeshBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Timer timer;
  final random = math.Random();
  List<int> activePoints = const [0, 6];
  List<Color> activeColors = const [Color(0xFF45D6FF), Color(0xFFB463FF)];

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    timer = Timer.periodic(const Duration(milliseconds: 8200), (_) {
      if (!widget.enabled) return;
      if (!mounted) return;
      setState(() {
        final first = random.nextInt(_LiquidMeshPainter.pointCount);
        if (random.nextBool()) {
          var second = random.nextInt(_LiquidMeshPainter.pointCount);
          if (second == first) {
            second = (second + 4) % _LiquidMeshPainter.pointCount;
          }
          activePoints = [first, second];
        } else {
          activePoints = [first];
        }
        activeColors = random.nextBool()
            ? const [Color(0xFF45D6FF), Color(0xFFB463FF)]
            : const [Color(0xFFB463FF), Color(0xFF57FFC1)];
      });
      controller.forward(from: 0);
    });
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted && widget.enabled) controller.forward(from: 0);
    });
  }

  @override
  void didUpdateWidget(covariant _LiquidMeshBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) controller.stop();
    if (widget.enabled && !oldWidget.enabled) controller.forward(from: 0);
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
      decoration: const BoxDecoration(color: Color(0xFF111820)),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            isComplex: true,
            willChange: controller.isAnimating,
            painter: _LiquidMeshPainter(
              activePoints: activePoints,
              activeColors: activeColors,
              pulse: widget.enabled
                  ? math.sin(controller.value * math.pi).clamp(0, 1).toDouble()
                  : 0,
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidMeshPainter extends CustomPainter {
  const _LiquidMeshPainter({
    this.activePoints = const [],
    this.activeColors = const [Color(0xFF45D6FF), Color(0xFFB463FF)],
    this.pulse = 0,
  });

  static const pointCount = 11;
  final List<int> activePoints;
  final List<Color> activeColors;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final cyan = Paint()
      ..color = const Color(0xFF45D6FF).withValues(alpha: 0.025)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 58);
    final violet = Paint()
      ..color = const Color(0xFF9B5CFF).withValues(alpha: 0.022)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 62);
    final green = Paint()
      ..color = const Color(0xFF57FFC1).withValues(alpha: 0.018)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);

    canvas.drawCircle(Offset(size.width * 0.18, size.height * 0.18), 130, cyan);
    canvas.drawCircle(
      Offset(size.width * 0.88, size.height * 0.30),
      150,
      violet,
    );
    canvas.drawCircle(
      Offset(size.width * 0.54, size.height * 0.86),
      170,
      green,
    );

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.055)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final nodePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.11)
      ..style = PaintingStyle.fill;

    final points = _points(size);
    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], linePaint);
    }
    canvas.drawLine(points[2], points[6], linePaint);
    canvas.drawLine(points[6], points[10], linePaint);
    canvas.drawLine(points[5], points[9], linePaint);
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final activeIndex = activePoints.indexOf(i);
      if (activeIndex >= 0 && pulse > 0) {
        final activeColor = activeColors[activeIndex % activeColors.length];
        final localPulse = (pulse * (activeIndex == 0 ? 1.0 : 0.88)).clamp(
          0.0,
          1.0,
        );
        final glowPaint = Paint()
          ..color = activeColor.withValues(alpha: 0.34 * localPulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
        final hotPaint = Paint()
          ..color = activeColor.withValues(alpha: 0.88 * localPulse)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(point, 15 * localPulse, glowPaint);
        canvas.drawCircle(point, 3.4 + 2.4 * localPulse, hotPaint);
      }
      canvas.drawCircle(point, 2.4, nodePaint);
    }
  }

  List<Offset> _points(Size size) {
    return <Offset>[
      Offset(size.width * 0.08, size.height * 0.18),
      Offset(size.width * 0.28, size.height * 0.10),
      Offset(size.width * 0.44, size.height * 0.23),
      Offset(size.width * 0.64, size.height * 0.15),
      Offset(size.width * 0.86, size.height * 0.26),
      Offset(size.width * 0.23, size.height * 0.42),
      Offset(size.width * 0.50, size.height * 0.52),
      Offset(size.width * 0.76, size.height * 0.48),
      Offset(size.width * 0.18, size.height * 0.76),
      Offset(size.width * 0.43, size.height * 0.83),
      Offset(size.width * 0.72, size.height * 0.72),
    ];
  }

  @override
  bool shouldRepaint(covariant _LiquidMeshPainter oldDelegate) {
    return oldDelegate.activePoints != activePoints ||
        oldDelegate.activeColors != activeColors ||
        oldDelegate.pulse != pulse;
  }
}

class _ChatGlassSurface extends StatelessWidget {
  const _ChatGlassSurface({required this.child, this.radius = 22});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xB02A3540), Color(0xB0242D37), Color(0xB02A3540)],
              stops: [0, 0.5, 1],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.actions,
    this.participants = const [],
    this.connectedNodeIds = const {},
    this.localNodeId = '',
    this.mutedNodeIds = const {},
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final List<Widget> actions;
  final List<Profile> participants;
  final Set<String> connectedNodeIds;
  final String localNodeId;
  final Set<String> mutedNodeIds;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: _GlassCallSurface(
        accent: color,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              _CallGlowIcon(icon: icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                    if (participants.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _GroupCallRoster(
                        participants: participants,
                        connectedNodeIds: connectedNodeIds,
                        localNodeId: localNodeId,
                        mutedNodeIds: mutedNodeIds,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 0,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassCallSurface extends StatelessWidget {
  const _GlassCallSurface({required this.accent, required this.child});

  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: const Color(0xFF242D37).withValues(alpha: 0.76),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.26),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Stack(children: [child]),
        ),
      ),
    );
  }
}

class _CallGlowIcon extends StatelessWidget {
  const _CallGlowIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Icon(icon, color: color, size: 21),
    );
  }
}

class _GroupCallRoster extends StatelessWidget {
  const _GroupCallRoster({
    required this.participants,
    required this.connectedNodeIds,
    required this.localNodeId,
    required this.mutedNodeIds,
  });

  final List<Profile> participants;
  final Set<String> connectedNodeIds;
  final String localNodeId;
  final Set<String> mutedNodeIds;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final profile in participants.take(8))
          _GroupCallParticipantChip(
            profile: profile,
            connected:
                profile.nodeId == localNodeId ||
                connectedNodeIds.contains(profile.nodeId),
            muted: mutedNodeIds.contains(profile.nodeId),
            current: profile.nodeId == localNodeId,
          ),
      ],
    );
  }
}

class _GroupCallParticipantChip extends StatelessWidget {
  const _GroupCallParticipantChip({
    required this.profile,
    required this.connected,
    required this.muted,
    required this.current,
  });

  final Profile profile;
  final bool connected;
  final bool muted;
  final bool current;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 170),
      padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2D333C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: connected ? Colors.greenAccent : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProfileAvatar(profile: profile, radius: 10),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              current ? '${profile.displayName} (you)' : profile.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
          const SizedBox(width: 5),
          Icon(
            muted
                ? Icons.mic_off_rounded
                : connected
                ? Icons.graphic_eq_rounded
                : Icons.hourglass_empty_rounded,
            size: 12,
            color: muted
                ? Colors.redAccent
                : connected
                ? Colors.greenAccent
                : Colors.orangeAccent,
          ),
        ],
      ),
    );
  }
}

class _MiniCallPanel extends StatelessWidget {
  const _MiniCallPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.activeCall;
    if (call == null) return const SizedBox.shrink();
    final active = call.status == CallStatus.active;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: _GlassCallSurface(
        accent: active ? Colors.greenAccent : Colors.orangeAccent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                active ? Icons.call_rounded : Icons.call_made_rounded,
                color: active ? Colors.greenAccent : Colors.orangeAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${call.peer.displayName} - ${formatDuration(controller.callElapsed)} - ${controller.callQualityLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Show call',
                onPressed: controller.toggleCallCollapsed,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
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

class _ReplyComposer extends StatelessWidget {
  const _ReplyComposer({required this.message, required this.onCancel});

  final ChatMessage message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2E35),
        borderRadius: BorderRadius.circular(10),
        border: const Border(
          left: BorderSide(color: Color(0xFF4EA3FF), width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              replyPreview(message),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.thread, required this.onTap});

  final ChatThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pinned = thread.pinnedMessages;
    if (pinned.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          color: Color(0xFF242A33),
          border: Border(bottom: BorderSide(color: Color(0xFF333A45))),
        ),
        child: Row(
          children: [
            const Icon(Icons.push_pin, size: 18, color: Colors.white70),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                replyPreview(pinned.first),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            if (pinned.length > 1)
              Text(
                '+${pinned.length - 1}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _PhotoAlbumBubble extends StatelessWidget {
  const _PhotoAlbumBubble({
    required this.messages,
    required this.mine,
    required this.dataSaver,
    required this.onLongPress,
    required this.onReply,
  });

  final List<ChatMessage> messages;
  final bool mine;
  final bool dataSaver;
  final VoidCallback onLongPress;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final visible = messages.take(4).toList(growable: false);
    final last = messages.last;
    final time = last.createdAt.toLocal();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onHorizontalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 650) onReply();
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 286),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
          decoration: BoxDecoration(
            color: mine ? const Color(0xFF2587E8) : const Color(0xFF2A2E35),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(mine ? 12 : 4),
              bottomRight: Radius.circular(mine ? 4 : 12),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 274,
                  height: messages.length == 2 ? 136 : 214,
                  child: GridView.builder(
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: visible.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: messages.length == 2 ? 2 : 2,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                      childAspectRatio: messages.length == 2 ? 1 : 1.26,
                    ),
                    itemBuilder: (context, index) {
                      final message = visible[index];
                      final bytes = _MessageBubble.imageBytesFor(
                        message,
                        dataSaver: dataSaver,
                      );
                      return GestureDetector(
                        onTap: bytes == null
                            ? null
                            : () => _showAlbumImage(context, bytes),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Color(0xFF101D2B),
                              ),
                              child: bytes == null
                                  ? const Icon(
                                      Icons.image_not_supported_outlined,
                                      color: Colors.white38,
                                    )
                                  : Image.memory(
                                      bytes,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                    ),
                            ),
                            if (index == 3 && messages.length > 4)
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                ),
                                child: Center(
                                  child: Text(
                                    '+${messages.length - 4}',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
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
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${time.hour.toString().padLeft(2, '0')}:'
                    '${time.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 10, color: Colors.white60),
                  ),
                  if (mine) ...[
                    const SizedBox(width: 5),
                    _MessageStatusLabel(message: last),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAlbumImage(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(14),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.controller,
    required this.thread,
    required this.message,
    required this.mine,
    required this.dataSaver,
    required this.onLongPress,
    required this.onReply,
    this.onOpenComments,
    this.commentCount = 0,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage message;
  final bool mine;
  final bool dataSaver;
  final VoidCallback onLongPress;
  final VoidCallback onReply;
  final VoidCallback? onOpenComments;
  final int commentCount;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();

  static final Map<String, Uint8List> _imageBytesCache = {};

  static Uint8List? imageBytesFor(
    ChatMessage message, {
    bool dataSaver = false,
  }) {
    if ((message.kind != ChatMessageKind.file &&
            message.kind != ChatMessageKind.sticker) ||
        !isImageName(message.fileName)) {
      return null;
    }
    if (dataSaver && message.fileSize > 512 * 1024) return null;
    final cacheKey =
        '${message.id}:${message.fileSize}:${message.fileData.length}';
    final cached = _imageBytesCache[cacheKey];
    if (cached != null) return cached;
    try {
      final bytes = hexDecode(message.fileData);
      if (_imageBytesCache.length > 96) {
        _imageBytesCache.clear();
      }
      _imageBytesCache[cacheKey] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

class _MessageBubbleState extends State<_MessageBubble> {
  double replyDrag = 0;
  bool appeared = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => appeared = true);
    });
  }

  void _updateReplyDrag(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta <= 0 && replyDrag <= 0) return;
    setState(() {
      replyDrag = (replyDrag + delta).clamp(0, 86);
    });
  }

  void _finishReplyDrag(DragEndDetails details) {
    final shouldReply = replyDrag >= 54 || (details.primaryVelocity ?? 0) > 650;
    if (shouldReply) widget.onReply();
    setState(() => replyDrag = 0);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final mine = widget.mine;
    final imageBytes = _MessageBubble.imageBytesFor(
      message,
      dataSaver: widget.dataSaver,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: appeared ? 1 : 0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset((mine ? 18 : -18) * (1 - value), 8 * (1 - value)),
          child: Transform.scale(
            scale: 0.98 + value * 0.02,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Stack(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedOpacity(
                  opacity: (replyDrag / 24).clamp(0.0, 1.0),
                  duration: const Duration(milliseconds: 90),
                  child: Transform.translate(
                    offset: Offset((replyDrag - 26).clamp(-14.0, 0.0), 0),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 8),
                      child: CircleAvatar(
                        radius: 17,
                        backgroundColor: Colors.lightBlueAccent.withValues(
                          alpha: 0.18,
                        ),
                        child: const Icon(
                          Icons.reply_rounded,
                          size: 18,
                          color: Colors.lightBlueAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            GestureDetector(
              onHorizontalDragUpdate: _updateReplyDrag,
              onHorizontalDragEnd: _finishReplyDrag,
              onHorizontalDragCancel: () => setState(() => replyDrag = 0),
              onLongPress: widget.onLongPress,
              onTap: imageBytes == null
                  ? null
                  : () => _showImage(context, imageBytes),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(replyDrag, 0, 0),
                transformAlignment: Alignment.center,
                constraints: const BoxConstraints(maxWidth: 340),
                margin: const EdgeInsets.only(bottom: 8),
                child: RepaintBoundary(
                  child: _MessageBubbleBody(
                    controller: widget.controller,
                    thread: widget.thread,
                    message: message,
                    mine: mine,
                    imageBytes: imageBytes,
                    onOpenComments: widget.onOpenComments,
                    commentCount: widget.commentCount,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImage(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(14),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _MessageBubbleBody extends StatelessWidget {
  const _MessageBubbleBody({
    required this.controller,
    required this.thread,
    required this.message,
    required this.mine,
    required this.imageBytes,
    this.onOpenComments,
    this.commentCount = 0,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage message;
  final bool mine;
  final Uint8List? imageBytes;
  final VoidCallback? onOpenComments;
  final int commentCount;

  @override
  Widget build(BuildContext context) {
    final time = message.createdAt.toLocal();
    final meetingPoint = _MeetingPoint.fromMessageText(message.text);
    final sharedLocation = _SharedLocation.fromMessageText(message.text);
    if (message.kind == ChatMessageKind.sticker) {
      return Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (message.replyToText.isNotEmpty) ...[
            Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2E35).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _ReplyQuote(text: message.replyToText),
            ),
            const SizedBox(height: 6),
          ],
          _StickerMessagePreview(message: message, imageBytes: imageBytes),
          if (message.pending && message.progress > 0) ...[
            const SizedBox(height: 5),
            SizedBox(
              width: 136,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: message.progress.clamp(0.02, 1),
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.white70,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
              if (message.edited) ...[
                const SizedBox(width: 5),
                const Text(
                  'edited',
                  style: TextStyle(fontSize: 10, color: Colors.white38),
                ),
              ],
              if (mine) ...[
                const SizedBox(width: 5),
                _MessageStatusLabel(message: message),
              ],
            ],
          ),
          if (message.reactions.isNotEmpty) ...[
            const SizedBox(height: 3),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final entry in message.reactions.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF465163),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: _ReactionBadge(
                      reaction: entry.key,
                      count: entry.value,
                    ),
                  ),
              ],
            ),
          ],
          if (onOpenComments != null) ...[
            const SizedBox(height: 4),
            _ChannelCommentsButton(
              count: commentCount,
              onTap: onOpenComments!,
              alignRight: mine,
            ),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: EdgeInsets.fromLTRB(
            11,
            (message.kind == ChatMessageKind.file ||
                        message.kind == ChatMessageKind.sticker) &&
                    imageBytes != null
                ? 6
                : 8,
            9,
            6,
          ),
          decoration: BoxDecoration(
            color: mine ? const Color(0xFF2587E8) : const Color(0xFF2A2E35),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(mine ? 12 : 4),
              bottomRight: Radius.circular(mine ? 4 : 12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyToText.isNotEmpty) ...[
                _ReplyQuote(text: message.replyToText),
                const SizedBox(height: 6),
              ],
              message.kind == ChatMessageKind.sticker
                  ? _StickerMessagePreview(
                      message: message,
                      imageBytes: imageBytes,
                    )
                  : message.kind == ChatMessageKind.file
                  ? _FilePreview(message: message, imageBytes: imageBytes)
                  : meetingPoint == null
                  ? sharedLocation == null
                        ? Text(message.text)
                        : _SharedLocationPreview(location: sharedLocation)
                  : _MeetingPointPreview(
                      controller: controller,
                      thread: thread,
                      message: message,
                      point: meetingPoint,
                    ),
              if ((message.kind == ChatMessageKind.file ||
                      message.kind == ChatMessageKind.sticker) &&
                  message.pending &&
                  message.progress > 0) ...[
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: message.progress.clamp(0.02, 1),
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.white70,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 3),
              Align(
                alignment: Alignment.centerRight,
                widthFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${time.hour.toString().padLeft(2, '0')}:'
                      '${time.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white60,
                      ),
                    ),
                    if (message.edited) ...[
                      const SizedBox(width: 5),
                      const Text(
                        'edited',
                        style: TextStyle(fontSize: 10, color: Colors.white54),
                      ),
                    ],
                    if (mine) ...[
                      const SizedBox(width: 5),
                      _MessageStatusLabel(message: message),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (message.reactions.isNotEmpty) ...[
          const SizedBox(height: 3),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final entry in message.reactions.entries)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF465163),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: _ReactionBadge(
                    reaction: entry.key,
                    count: entry.value,
                  ),
                ),
            ],
          ),
        ],
        if (onOpenComments != null) ...[
          const SizedBox(height: 4),
          _ChannelCommentsButton(
            count: commentCount,
            onTap: onOpenComments!,
            alignRight: mine,
          ),
        ],
      ],
    );
  }
}

class _ChannelCommentsButton extends StatelessWidget {
  const _ChannelCommentsButton({
    required this.count,
    required this.onTap,
    required this.alignRight,
  });

  final int count;
  final VoidCallback onTap;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final label = count == 0
        ? 'Comment'
        : count == 1
        ? '1 comment'
        : '$count comments';
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B2B3A).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.lightBlueAccent.withValues(alpha: 0.28),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.forum_outlined,
                  size: 15,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
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

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
        border: const Border(
          left: BorderSide(color: Color(0xFF8EC8FF), width: 3),
        ),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.white70),
      ),
    );
  }
}

class _SharedLocationPreview extends StatelessWidget {
  const _SharedLocationPreview({required this.location});

  final _SharedLocation location;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.24)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF54F2C7).withValues(alpha: 0.24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.greenAccent.withValues(alpha: 0.22),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: const Icon(
                Icons.my_location_rounded,
                color: Color(0xFF54F2C7),
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Shared location',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    location.coordinateLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _MeetingPointButton(
              icon: Icons.map_rounded,
              label: 'Open',
              onTap: () => location.open(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationDurationTile extends StatelessWidget {
  const _LocationDurationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: const Color(0xFF54F2C7)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MeetingPointPreview extends StatelessWidget {
  const _MeetingPointPreview({
    required this.controller,
    required this.thread,
    required this.message,
    required this.point,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage message;
  final _MeetingPoint point;

  bool get canEdit => message.senderNode == controller.myNodeId;

  Future<void> setStatus(String reaction) async {
    if (point.statuses[controller.myNodeId] == reaction) return;
    await controller.editMessage(
      thread,
      message,
      point.withStatus(controller.myNodeId, reaction).toMessageText(),
    );
  }

  Future<void> editPoint(BuildContext context) async {
    final titleInput = TextEditingController(text: point.title);
    final noteInput = TextEditingController(text: point.note);
    final latInput = TextEditingController(
      text: point.latitude.toStringAsFixed(6),
    );
    final lngInput = TextEditingController(
      text: point.longitude.toStringAsFixed(6),
    );
    final result = await showDialog<_MeetingPoint>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit meeting point'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleInput,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: noteInput,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: latInput,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Lat'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: lngInput,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Lng'),
                    ),
                  ),
                ],
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
            onPressed: () {
              final lat = double.tryParse(latInput.text.trim());
              final lng = double.tryParse(lngInput.text.trim());
              if (lat == null ||
                  lng == null ||
                  lat < -90 ||
                  lat > 90 ||
                  lng < -180 ||
                  lng > 180) {
                return;
              }
              Navigator.pop(
                context,
                point.copyWith(
                  title: titleInput.text.trim(),
                  note: noteInput.text.trim(),
                  latitude: lat,
                  longitude: lng,
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    titleInput.dispose();
    noteInput.dispose();
    latInput.dispose();
    lngInput.dispose();
    if (result == null) return;
    await controller.editMessage(thread, message, result.toMessageText());
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.lightBlueAccent.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF43D9FF), Color(0xFF9C63FF)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.lightBlueAccent.withValues(alpha: 0.20),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.location_on_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        point.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        point.coordinateLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (point.note.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                point.note.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
            if (point.expiresAt != null) ...[
              const SizedBox(height: 8),
              Text(
                point.expiryLabel,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MeetingPointButton(
                    icon: Icons.map_rounded,
                    label: 'Open',
                    onTap: () => point.open(context, route: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MeetingPointButton(
                    icon: Icons.near_me_rounded,
                    label: 'Route',
                    onTap: () => point.open(context, route: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (point.statuses.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in point.statuses.entries)
                    _MeetingStatusChip(
                      status: entry.value,
                      name:
                          controller.profiles[entry.key]?.displayName ??
                          (entry.key == controller.myNodeId ? 'You' : 'Guest'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _MeetingPointButton(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'I will come',
                  onTap: () => setStatus('✅'),
                ),
                _MeetingPointButton(
                  icon: Icons.cancel_outlined,
                  label: 'Can not',
                  onTap: () => setStatus('🚫'),
                ),
                _MeetingPointButton(
                  icon: Icons.flag_circle_outlined,
                  label: 'Here',
                  onTap: () => setStatus('📍'),
                ),
                if (canEdit)
                  _MeetingPointButton(
                    icon: Icons.edit_location_alt_outlined,
                    label: 'Edit',
                    onTap: () => editPoint(context),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MeetingPointButton extends StatelessWidget {
  const _MeetingPointButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
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

class _MeetingStatusChip extends StatelessWidget {
  const _MeetingStatusChip({required this.status, required this.name});

  final String status;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Text(
        '$status $name',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _StickerMessagePreview extends StatelessWidget {
  const _StickerMessagePreview({
    required this.message,
    required this.imageBytes,
  });

  final ChatMessage message;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final bytes = imageBytes;
    if (bytes == null) {
      return const SizedBox(
        width: 148,
        height: 128,
        child: Center(
          child: Icon(Icons.auto_awesome_motion_rounded, color: Colors.white38),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 96,
        maxWidth: 180,
        minHeight: 92,
        maxHeight: 190,
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.broken_image_rounded, color: Colors.white38),
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.message, required this.imageBytes});

  final ChatMessage message;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final bytes = imageBytes;
    if (bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300, maxHeight: 260),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
          _FileCaption(text: message.text),
        ],
      );
    }
    if (isImageName(message.fileName)) {
      return _UnavailableFilePreview(
        icon: Icons.image_not_supported_outlined,
        title: message.fileName.isEmpty ? 'Photo' : message.fileName,
        subtitle: 'Preview is not cached',
      );
    }
    if (isAudioName(message.fileName)) {
      if (message.fileData.isEmpty) {
        return _UnavailableFilePreview(
          icon: Icons.graphic_eq_rounded,
          title: message.fileName.isEmpty ? 'Voice message' : message.fileName,
          subtitle: 'Audio is not cached',
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _AudioPreview(message: message),
          _FileCaption(text: message.text),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => openFile(context, message),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 30),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.fileName.isEmpty ? 'File' : message.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatSize(message.fileSize)} · open',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _FileCaption(text: message.text),
      ],
    );
  }

  Future<void> openFile(BuildContext context, ChatMessage message) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opening files is not available on web')),
      );
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final filename = safeFilename(
        message.fileName.isEmpty ? 'meshchat_file' : message.fileName,
      );
      final file = XFile.fromData(hexDecode(message.fileData), name: filename);
      final path = p.join(dir.path, filename);
      await file.saveTo(path);
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.message)));
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open file')));
    }
  }
}

class _MessageStatusLabel extends StatelessWidget {
  const _MessageStatusLabel({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isFile = message.kind == ChatMessageKind.file;
    final (icon, label, color) = message.failed
        ? (Icons.error_outline_rounded, 'failed', Colors.redAccent)
        : message.pending
        ? (
            Icons.schedule_rounded,
            isFile && message.progress > 0
                ? '${(message.progress * 100).clamp(1, 99).round()}%'
                : 'sending',
            Colors.white60,
          )
        : message.delivered
        ? (Icons.done_all_rounded, 'delivered', Colors.white60)
        : (Icons.done_rounded, 'sent', Colors.white60);
    return TweenAnimationBuilder<double>(
      key: ValueKey(
        '${message.id}-${message.pending}-${message.delivered}-${message.failed}',
      ),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.82 + value * 0.18, child: child),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileCaption extends StatelessWidget {
  const _FileCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final caption = text.trim();
    if (caption.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Text(caption),
    );
  }
}

class _UnavailableFilePreview extends StatelessWidget {
  const _UnavailableFilePreview({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 30, color: Colors.white70),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.message});

  final ChatMessage message;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  late final AudioPlayer player;
  StreamSubscription<Duration>? durationSubscription;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<void>? completeSubscription;
  bool playing = false;
  bool sourceReady = false;
  Duration duration = Duration.zero;
  Duration position = Duration.zero;

  @override
  void initState() {
    super.initState();
    player = AudioPlayer();
    durationSubscription = player.onDurationChanged.listen((value) {
      if (mounted) setState(() => duration = value);
    });
    positionSubscription = player.onPositionChanged.listen((value) {
      if (mounted) setState(() => position = value);
    });
    completeSubscription = player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        playing = false;
        position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    durationSubscription?.cancel();
    positionSubscription?.cancel();
    completeSubscription?.cancel();
    player.dispose();
    super.dispose();
  }

  Future<void> ensureSource() async {
    if (sourceReady) return;
    await player.setSource(BytesSource(hexDecode(widget.message.fileData)));
    sourceReady = true;
  }

  Future<void> toggle() async {
    if (playing) {
      await player.pause();
      if (mounted) setState(() => playing = false);
      return;
    }
    try {
      await ensureSource();
      await player.resume();
      if (mounted) setState(() => playing = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not play audio')));
    }
  }

  Future<void> seekToFraction(double fraction) async {
    try {
      await ensureSource();
      if (duration <= Duration.zero) return;
      final clamped = fraction.clamp(0.0, 1.0);
      final target = Duration(
        milliseconds: (duration.inMilliseconds * clamped).round(),
      );
      await player.seek(target);
      if (mounted) setState(() => position = target);
    } catch (_) {
      // Some platform audio backends can reject seeking before metadata loads.
    }
  }

  @override
  Widget build(BuildContext context) {
    final levels = levelsFor(widget.message);
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;
    return SizedBox(
      width: 260,
      child: Row(
        children: [
          IconButton.filled(
            tooltip: playing ? 'Pause' : 'Play',
            onPressed: toggle,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.message.fileName.isEmpty
                      ? 'Audio'
                      : widget.message.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                _Waveform(
                  levels: levels,
                  active: playing,
                  progress: progress,
                  onSeek: seekToFraction,
                  color: Colors.white70,
                ),
                const SizedBox(height: 4),
                Text(
                  duration.inMilliseconds > 0
                      ? '${formatDuration(position)} / ${formatDuration(duration)}'
                      : formatSize(widget.message.fileSize),
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<double> levelsFor(ChatMessage message) {
    var seed =
        message.fileSize +
        message.fileName.codeUnits.fold<int>(0, (a, b) => a + b);
    return List<double>.generate(24, (index) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return 0.18 + (seed % 82) / 100;
    });
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.levels,
    this.active = true,
    this.progress = 0,
    this.onSeek,
    this.color = Colors.white70,
  });

  final List<double> levels;
  final bool active;
  final double progress;
  final ValueChanged<double>? onSeek;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        void seek(Offset localPosition) {
          final width = constraints.maxWidth;
          if (width <= 0) return;
          onSeek?.call(localPosition.dx / width);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeek == null
              ? null
              : (details) => seek(details.localPosition),
          onHorizontalDragUpdate: onSeek == null
              ? null
              : (details) => seek(details.localPosition),
          child: SizedBox(
            height: 28,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var index = 0; index < levels.length; index++)
                  Expanded(
                    child: Align(
                      alignment: Alignment.center,
                      child: FractionallySizedBox(
                        heightFactor: levels[index].clamp(0.08, 1.0),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1.2),
                          decoration: BoxDecoration(
                            color: _barColor(index),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _barColor(int index) {
    final playedBars = (levels.length * progress.clamp(0.0, 1.0)).round();
    if (index < playedBars) return color;
    return active
        ? color.withValues(alpha: 0.48)
        : color.withValues(alpha: 0.32);
  }
}

const _mooseReaction = '\u{1FACE}';
const _mooseReactionAsset = 'assets/moose_reaction.png';

class _ReactionQuickBar extends StatelessWidget {
  const _ReactionQuickBar({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    const reactions = [
      '\u2764\uFE0F',
      '\u{1F44C}',
      _mooseReaction,
      '\u{1F44D}',
    ];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.88, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Opacity(
        opacity: scale.clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF182231).withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF46D9FF).withValues(alpha: 0.12),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final reaction in reactions)
                      InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => onSelected(reaction),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: _ReactionIcon(reaction: reaction, size: 30),
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

class _ReactionIcon extends StatelessWidget {
  const _ReactionIcon({required this.reaction, required this.size});

  final String reaction;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (reaction == _mooseReaction) {
      return Image.asset(
        _mooseReactionAsset,
        width: size,
        height: size,
        filterQuality: FilterQuality.high,
      );
    }
    return Text(reaction, style: TextStyle(fontSize: size));
  }
}

class _ReactionBadge extends StatelessWidget {
  const _ReactionBadge({required this.reaction, required this.count});

  final String reaction;
  final int count;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('$reaction-$count'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Transform.scale(
        scale: 0.78 + value * 0.22,
        child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReactionIcon(reaction: reaction, size: 14),
          if (count > 1) ...[
            const SizedBox(width: 3),
            Text(
              count.toString(),
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }
}

bool isImageName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp');
}

bool isAudioName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.opus') ||
      lower.endsWith('.flac');
}

String safeFilename(String name) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return safe.isEmpty ? 'meshchat_file' : safe;
}

Uint8List hexDecode(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

String formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

class _MeetingPoint {
  const _MeetingPoint({
    required this.title,
    required this.latitude,
    required this.longitude,
    this.note = '',
    this.expiresAt,
    this.statuses = const {},
  });

  static const prefix = '::meshchat_meeting_v1::';

  final String title;
  final double latitude;
  final double longitude;
  final String note;
  final DateTime? expiresAt;
  final Map<String, String> statuses;

  String get coordinateLabel {
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  String get expiryLabel {
    final value = expiresAt;
    if (value == null) return '';
    final local = value.toLocal();
    return 'Active until ${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  _MeetingPoint copyWith({
    String? title,
    double? latitude,
    double? longitude,
    String? note,
    DateTime? expiresAt,
    Map<String, String>? statuses,
  }) {
    return _MeetingPoint(
      title: title ?? this.title,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      note: note ?? this.note,
      expiresAt: expiresAt ?? this.expiresAt,
      statuses: statuses ?? this.statuses,
    );
  }

  _MeetingPoint withStatus(String nodeId, String status) {
    final next = Map<String, String>.from(statuses);
    if (status.trim().isEmpty) {
      next.remove(nodeId);
    } else {
      next[nodeId] = status;
    }
    return copyWith(statuses: next);
  }

  String toMessageText() {
    return '$prefix${jsonEncode({'title': title.trim().isEmpty ? 'Meeting point' : title.trim(), 'lat': latitude, 'lng': longitude, 'note': note.trim(), if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(), if (statuses.isNotEmpty) 'statuses': statuses})}';
  }

  static _MeetingPoint? fromMessageText(String text) {
    final prefixIndex = text.indexOf(prefix);
    if (prefixIndex < 0) return null;
    try {
      final raw = jsonDecode(text.substring(prefixIndex + prefix.length));
      if (raw is! Map) return null;
      final lat = double.tryParse(raw['lat']?.toString() ?? '');
      final lng = double.tryParse(raw['lng']?.toString() ?? '');
      if (lat == null || lng == null || !_validCoordinates(lat, lng)) {
        return null;
      }
      return _MeetingPoint(
        title: raw['title']?.toString().trim().isEmpty == false
            ? raw['title'].toString().trim()
            : 'Meeting point',
        latitude: lat,
        longitude: lng,
        note: raw['note']?.toString() ?? '',
        expiresAt: DateTime.tryParse(raw['expires_at']?.toString() ?? ''),
        statuses: _stringMap(raw['statuses']),
      );
    } catch (_) {
      return null;
    }
  }

  static _MeetingPoint? tryParse({
    required String title,
    required String rawLocation,
    required String note,
  }) {
    final coordinates = _extractCoordinates(rawLocation);
    if (coordinates == null) return null;
    return _MeetingPoint(
      title: title.trim().isEmpty ? 'Meeting point' : title.trim(),
      latitude: coordinates.$1,
      longitude: coordinates.$2,
      note: note.trim(),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
    );
  }

  static (double, double)? _extractCoordinates(String value) {
    final normalized = value
        .replaceAll('%2C', ',')
        .replaceAll('%2c', ',')
        .replaceAll(';', ',');
    final patterns = [
      RegExp(r'@(-?\d{1,2}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)'),
      RegExp(r'll=(-?\d{1,2}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)'),
      RegExp(r'[?&]q=(-?\d{1,2}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)'),
      RegExp(r'(-?\d{1,2}(?:[.,]\d+)?)\s*,\s*(-?\d{1,3}(?:[.,]\d+)?)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(normalized);
      if (match == null) continue;
      final lat = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      final lng = double.tryParse(match.group(2)!.replaceAll(',', '.'));
      if (lat != null && lng != null && _validCoordinates(lat, lng)) {
        return (lat, lng);
      }
    }
    return null;
  }

  static bool _validCoordinates(double lat, double lng) {
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()))
      ..removeWhere((key, value) => key.trim().isEmpty || value.trim().isEmpty);
  }

  Future<void> open(BuildContext context, {required bool route}) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => MeetingPointMapPage(
          title: title,
          latitude: latitude,
          longitude: longitude,
          note: note,
          routeOnOpen: route,
        ),
      ),
    );
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

  String get coordinateLabel {
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  String toMessageText() {
    return '$prefix${jsonEncode({'lat': latitude, 'lng': longitude, 'ts': DateTime.now().toUtc().toIso8601String(), if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String()})}';
  }

  static _SharedLocation? fromMessageText(String text) {
    final prefixIndex = text.indexOf(prefix);
    if (prefixIndex < 0) return null;
    try {
      final raw = jsonDecode(text.substring(prefixIndex + prefix.length));
      if (raw is! Map) return null;
      final lat = double.tryParse(raw['lat']?.toString() ?? '');
      final lng = double.tryParse(raw['lng']?.toString() ?? '');
      if (lat == null || lng == null || !_validCoordinates(lat, lng)) {
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

  static _SharedLocation? tryParse({
    required String rawLocation,
    DateTime? expiresAt,
  }) {
    final coordinates = _MeetingPoint._extractCoordinates(rawLocation);
    if (coordinates == null) return null;
    return _SharedLocation(
      latitude: coordinates.$1,
      longitude: coordinates.$2,
      expiresAt: expiresAt,
    );
  }

  static bool _validCoordinates(double lat, double lng) {
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  Future<void> open(BuildContext context) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => MeetingPointMapPage(
          title: 'Shared location',
          latitude: latitude,
          longitude: longitude,
          note: coordinateLabel,
        ),
      ),
    );
  }
}

String formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String replyPreview(ChatMessage message) {
  if (message.kind == ChatMessageKind.sticker) {
    return 'Sticker';
  }
  if (message.kind == ChatMessageKind.file) {
    return message.fileName.isEmpty ? 'File' : message.fileName;
  }
  final point = _MeetingPoint.fromMessageText(message.text);
  if (point != null) return 'Meeting point: ${point.title}';
  final text = message.text.trim();
  if (text.isEmpty) return 'Message';
  return text.length > 90 ? '${text.substring(0, 90)}...' : text;
}

String messageTime(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

bool sameDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String dateLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (sameDay(local, now)) return 'Today';
  if (sameDay(local, now.subtract(const Duration(days: 1)))) {
    return 'Yesterday';
  }
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}.${local.year}';
}
