import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart' as image_picker;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../models/sticker_pack.dart';
import '../services/call_alert_service.dart';
import '../utils/mesh_page_route.dart';
import '../widgets/in_app_message_banner.dart';
import '../widgets/mesh_frame_clock.dart';
import '../widgets/mesh_liquid_glass.dart';
import '../widgets/meshpro_gate.dart';
import '../widgets/mesh_painting.dart';
import '../widgets/message_send_effect.dart';
import '../widgets/profile_avatar.dart';
import 'chat_media_page.dart';
import 'group_info_page.dart';
import 'meeting_point_map_page.dart';
import 'meeting_points_page.dart';
import 'profile_page.dart';

enum _AttachAction { photo, file, sticker, shareLocation }

class _ScheduleDraft {
  const _ScheduleDraft({
    required this.text,
    required this.sendAt,
    required this.repeatInterval,
  });

  final String text;
  final DateTime sendAt;
  final String repeatInterval;
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.controller,
    required this.thread,
    this.channelPost,
    this.onBack,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage? channelPost;
  final Future<void> Function()? onBack;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final scroll = ScrollController();
  final composerInputKey = GlobalKey();
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
  Timer? initialScrollSettleTimer;
  bool initialScrollInterrupted = false;
  bool showJumpToBottom = false;
  double voiceCancelDrag = 0;
  bool voiceCancelArmed = false;
  bool hasInputText = false;
  bool aiRewriting = false;
  bool aiSummarizing = false;
  bool aiCallSummarizing = false;
  bool aiSmartRepliesLoading = false;
  bool aiPersonMemoryLoading = false;
  List<String> smartReplies = const [];
  bool unreadSummaryVisible = false;
  final unreadMessageIds = <String>[];
  DateTime? recordStartedAt;
  Timer? voiceRecordingTicker;
  ChatMessage? replyTo;
  DateTime? lastTypingSentAt;
  Timer? liveLocationTimer;
  DateTime? liveLocationUntil;
  String? liveLocationMessageId;
  String? highlightedMessageId;
  final deletingMessageIds = <String>{};
  final selectedMessageIds = <String>{};
  final messageTintRefresh = ValueNotifier<int>(0);
  final messageListRefresh = ValueNotifier<int>(0);
  bool messageListScrolling = false;
  bool pendingMessageListRefresh = false;

  bool get isChannelCommentThread =>
      widget.thread.isChannel && widget.channelPost != null;

  bool get selectingMessages => selectedMessageIds.isNotEmpty;

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
          .where(
            (message) =>
                !message.isChannelComment &&
                message.replyToMessageId.trim().isEmpty,
          )
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
    final unreadCount = widget.thread.unread.clamp(
      0,
      widget.thread.messages.length,
    );
    if (unreadCount > 0) {
      final incoming = visibleMessages()
          .where(
            (message) =>
                !message.deleted &&
                message.senderNode != widget.controller.myNodeId,
          )
          .toList(growable: false);
      final start = math.max(0, incoming.length - unreadCount);
      unreadMessageIds.addAll(
        incoming.skip(start).map((message) => message.id),
      );
      unreadSummaryVisible = unreadMessageIds.isNotEmpty;
    }
    input.text = widget.thread.draft;
    hasInputText = input.text.trim().isNotEmpty;
    inputFocus.addListener(() {
      if (inputFocus.hasFocus) scheduleKeyboardScrollToBottom();
    });
    input.addListener(() {
      final hasText = input.text.trim().isNotEmpty;
      final clearReplies = hasText && smartReplies.isNotEmpty;
      if (hasInputText != hasText || clearReplies) {
        setState(() {
          hasInputText = hasText;
          if (clearReplies) smartReplies = const [];
        });
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
    widget.controller.addListener(syncMessageList);
    widget.controller.markRead(widget.thread);
    widget.controller.setActiveThread(widget.thread);
    widget.controller.addListener(syncRingback);
    syncRingback();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    amplitudeSubscription?.cancel();
    voiceRecordingTicker?.cancel();
    initialScrollSettleTimer?.cancel();
    liveLocationTimer?.cancel();
    unawaited(deleteLastLiveLocationMessage());
    widget.controller.removeListener(syncRingback);
    widget.controller.removeListener(syncMessageList);
    unawaited(incomingCallAlert.dispose());
    unawaited(stopRingback());
    widget.controller.setActiveThread(null);
    inputFocus.dispose();
    input.dispose();
    scroll.removeListener(handleScroll);
    scroll.dispose();
    messageTintRefresh.dispose();
    messageListRefresh.dispose();
    recorder.dispose();
    ringbackPlayer?.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (inputFocus.hasFocus) scheduleKeyboardScrollToBottom();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      syncRingback();
      final target = liveLocationUntil;
      if (target != null && DateTime.now().toUtc().isBefore(target)) {
        startLiveLocationTimer(target);
        unawaited(
          sendCurrentLocationMessage(
            expiresAt: target,
            silent: true,
            lowPowerLocation: true,
          ),
        );
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      liveLocationTimer?.cancel();
      liveLocationTimer = null;
      if (recording || voicePointerDown) unawaited(cancelRecording());
    }
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
    playSendFlight(text.trim());
    input.clear();
    widget.controller.updateDraft(widget.thread, '');
    final quote = fixedCommentRoot ?? replyTo;
    setState(() {
      replyTo = null;
      smartReplies = const [];
    });
    String? error;
    if (widget.thread.isBluetooth) {
      error = await widget.controller.sendBluetoothMessageToThread(
        widget.thread,
        text,
        replyTo: quote,
      );
    } else if (widget.thread.isGroup) {
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
    if (error != null && mounted) showSnack(error);
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
  }

  Future<void> showAiRewrite() async {
    final original = input.text.trim();
    if (original.isEmpty || aiRewriting) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_text_rewrite',
      title: 'AI writing assistant',
      description:
          'Fix punctuation or rewrite a draft in a clearer style before sending.',
    );
    if (!allowed || !mounted) return;
    final style = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const _AiRewriteSheet(),
    );
    if (style == null || !mounted) return;
    setState(() => aiRewriting = true);
    try {
      final result = await widget.controller.rewriteTextWithAi(
        text: original,
        style: style,
      );
      if (!mounted) return;
      input.value = TextEditingValue(
        text: result.text,
        selection: TextSelection.collapsed(offset: result.text.length),
      );
      inputFocus.requestFocus();
    } on AiRewriteException catch (error) {
      if (mounted) showSnack(error.message);
    } catch (_) {
      if (mounted) showSnack('AI rewrite failed');
    } finally {
      if (mounted) setState(() => aiRewriting = false);
    }
  }

  Future<void> showUnreadSummary() async {
    if (aiSummarizing || unreadMessageIds.isEmpty) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_chat_summary',
      title: 'Unread summary',
      description:
          'Create a short summary of the unread messages in this chat.',
    );
    if (!allowed || !mounted) return;
    final unreadIds = unreadMessageIds.toSet();
    final messages = visibleMessages()
        .where((message) => unreadIds.contains(message.id))
        .toList(growable: false);
    if (messages.isEmpty) {
      setState(() => unreadSummaryVisible = false);
      return;
    }
    setState(() => aiSummarizing = true);
    try {
      final result = await widget.controller.summarizeMessagesWithAi(messages);
      if (!mounted) return;
      setState(() => unreadSummaryVisible = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: Color(0xFFB28AFF)),
              SizedBox(width: 10),
              Expanded(child: Text('Unread summary')),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: SelectableText(
                result.text,
                style: const TextStyle(height: 1.45),
              ),
            ),
          ),
          actions: [
            Text(
              '${result.remaining} summaries left',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.text));
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on AiSummaryException catch (error) {
      if (mounted) showSnack(error.message);
    } catch (_) {
      if (mounted) showSnack('Could not create summary');
    } finally {
      if (mounted) setState(() => aiSummarizing = false);
    }
  }

  Future<void> showCallSummary() async {
    if (aiCallSummarizing) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_call_summary',
      title: 'Call summary',
      description:
          'Structure a transcript or your call notes into topics, decisions, tasks and dates.',
    );
    if (!allowed || !mounted) return;
    final notesController = TextEditingController();
    final notes = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Call notes or transcript'),
        content: SizedBox(
          width: 540,
          child: TextField(
            controller: notesController,
            autofocus: true,
            minLines: 7,
            maxLines: 14,
            decoration: const InputDecoration(
              hintText:
                  'Paste a transcript or write what was discussed. MeshChat does not record calls automatically.',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              final value = notesController.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Summarize'),
          ),
        ],
      ),
    );
    notesController.dispose();
    if (notes == null || !mounted) return;
    setState(() => aiCallSummarizing = true);
    try {
      final result = await widget.controller.summarizeCallNotesWithAi(notes);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: Color(0xFFB28AFF)),
              SizedBox(width: 10),
              Expanded(child: Text('Call summary')),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(child: SelectableText(result.text)),
          ),
          actions: [
            Text(
              '${result.remaining} summaries left',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.text));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on AiSummaryException catch (error) {
      if (mounted) showSnack(error.message);
    } catch (_) {
      if (mounted) showSnack('Could not create a call summary');
    } finally {
      if (mounted) setState(() => aiCallSummarizing = false);
    }
  }

  Future<void> showSmartReplies() async {
    if (aiSmartRepliesLoading || input.text.trim().isNotEmpty) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_smart_replies',
      title: 'Smart replies',
      description: 'Generate three short replies from the recent context.',
    );
    if (!allowed || !mounted) return;
    final messages = visibleMessages()
        .where((message) => !message.deleted)
        .toList(growable: false);
    final start = math.max(0, messages.length - 20);
    setState(() {
      aiSmartRepliesLoading = true;
      smartReplies = const [];
    });
    try {
      final result = await widget.controller.suggestRepliesWithAi(
        messages.sublist(start),
      );
      if (!mounted) return;
      setState(() => smartReplies = result.replies);
    } on AiSmartRepliesException catch (error) {
      if (mounted) showSnack(error.message);
    } catch (_) {
      if (mounted) showSnack('Could not generate smart replies');
    } finally {
      if (mounted) setState(() => aiSmartRepliesLoading = false);
    }
  }

  void useSmartReply(String reply) {
    setState(() => smartReplies = const []);
    input.value = TextEditingValue(
      text: reply,
      selection: TextSelection.collapsed(offset: reply.length),
    );
    inputFocus.requestFocus();
  }

  Future<void> showPersonMemory() async {
    if (aiPersonMemoryLoading) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_person_memory',
      title: 'Memory about ${widget.thread.profile.displayName}',
      description:
          'Ask a question and get an answer based only on this conversation.',
    );
    if (!allowed || !mounted) return;
    final questionController = TextEditingController();
    final question = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.psychology_alt_rounded, color: Color(0xFFB28AFF)),
            SizedBox(width: 10),
            Expanded(child: Text('Ask chat memory')),
          ],
        ),
        content: TextField(
          controller: questionController,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'What did we agree on last Friday?',
            prefixIcon: Icon(Icons.search_rounded),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              final value = questionController.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Ask'),
          ),
        ],
      ),
    );
    questionController.dispose();
    if (question == null || !mounted) return;
    setState(() => aiPersonMemoryLoading = true);
    try {
      final result = await widget.controller.askPersonMemoryWithAi(
        thread: widget.thread,
        question: question,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.psychology_alt_rounded, color: Color(0xFFB28AFF)),
              SizedBox(width: 10),
              Expanded(child: Text('Chat memory')),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: SingleChildScrollView(child: SelectableText(result.text)),
          ),
          actions: [
            Text(
              '${result.remaining} searches left',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.text));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on AiPersonMemoryException catch (error) {
      if (mounted) showSnack(error.message);
    } catch (_) {
      if (mounted) showSnack('Could not search chat memory');
    } finally {
      if (mounted) setState(() => aiPersonMemoryLoading = false);
    }
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
            useNativeGlass: true,
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
      unawaited(
        sendCurrentLocationMessage(
          expiresAt: target,
          silent: true,
          lowPowerLocation: true,
        ),
      );
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
    bool lowPowerLocation = false,
  }) async {
    final current = await getCurrentLocationText(lowPower: lowPowerLocation);
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
              useNativeGlass: true,
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
                                      meshPageRoute<MeetingPointMapResult>(
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

  Future<({String? text, String? error})> getCurrentLocationText({
    bool lowPower = false,
  }) async {
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
        locationSettings: LocationSettings(
          accuracy: lowPower ? LocationAccuracy.medium : LocationAccuracy.high,
          timeLimit: const Duration(seconds: 12),
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
            useNativeGlass: true,
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
    final error = widget.thread.isBluetooth
        ? await widget.controller.sendBluetoothFileToThread(
            widget.thread,
            filename,
            bytes,
            caption: caption,
            replyTo: quote,
          )
        : widget.thread.isGroup
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
    voiceRecordingTicker?.cancel();
    voiceRecordingTicker = Timer.periodic(const Duration(milliseconds: 250), (
      _,
    ) {
      if (!mounted || !recording) {
        voiceRecordingTicker?.cancel();
        voiceRecordingTicker = null;
        return;
      }
      setState(() {});
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
    voiceRecordingTicker?.cancel();
    voiceRecordingTicker = null;
    await amplitudeSubscription?.cancel();
    amplitudeSubscription = null;
    final path = await recorder.stop();
    final duration = recordStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(recordStartedAt!);
    if (!mounted) return;
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
    final error = widget.thread.isBluetooth
        ? await widget.controller.sendBluetoothFileToThread(
            widget.thread,
            filename,
            bytes,
            replyTo: quote,
          )
        : widget.thread.isGroup
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
    voiceRecordingTicker?.cancel();
    voiceRecordingTicker = null;
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
    initialScrollInterrupted = false;
    var ticks = 0;
    void settle() {
      if (!mounted || initialScrollInterrupted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !initialScrollInterrupted) jumpToBottom();
      });
    }

    settle();
    initialScrollSettleTimer?.cancel();
    initialScrollSettleTimer = Timer.periodic(
      const Duration(milliseconds: 140),
      (timer) {
        ticks++;
        settle();
        if (ticks >= 12 || initialScrollInterrupted) timer.cancel();
      },
    );
  }

  bool handleInitialUserScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      messageListScrolling = true;
    }
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      initialScrollInterrupted = true;
      initialScrollSettleTimer?.cancel();
    }
    if (notification is ScrollEndNotification) {
      messageListScrolling = false;
      messageTintRefresh.value++;
      if (pendingMessageListRefresh) {
        pendingMessageListRefresh = false;
        messageListRefresh.value++;
      }
    }
    return false;
  }

  void syncMessageList() {
    if (!mounted) return;
    if (messageListScrolling) {
      pendingMessageListRefresh = true;
      return;
    }
    messageListRefresh.value++;
  }

  void playSendFlight(String text) {
    if (text.isEmpty || !mounted) return;
    final inputBox =
        composerInputKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (inputBox == null || overlayBox == null || !inputBox.hasSize) return;
    final origin = overlayBox.globalToLocal(
      inputBox.localToGlobal(Offset.zero),
    );
    final start = origin & inputBox.size;
    final targetWidth = (72.0 + text.length * 7.0)
        .clamp(88.0, 250.0)
        .toDouble();
    final media = MediaQuery.of(context);
    final end = Rect.fromLTWH(
      media.size.width - targetWidth - 14,
      math.max(media.padding.top + 76, start.top - 104),
      targetWidth,
      math.min(48, start.height),
    );
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SendFlightOverlay(
        start: start,
        end: end,
        text: text,
        color: _chatBubbleColor(widget.thread.themeId, true),
        onFinished: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
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

  Future<void> openProfile() async {
    Widget buildProfile(BuildContext context) => ProfilePage(
      profile: widget.thread.profile,
      controller: widget.controller,
      thread: widget.thread,
      onMessage: () => Navigator.maybePop(context),
      onCall: widget.controller.isSavedMessagesProfile(widget.thread.profile)
          ? null
          : () => unawaited(startCallFromProfile(context)),
      onMedia: openMediaList,
      onAppearance: () => unawaited(showChatAppearance()),
    );
    await Navigator.push<void>(
      context,
      meshPageRoute<void>(builder: buildProfile),
    );
  }

  Future<void> startCallFromProfile(BuildContext profileContext) async {
    Navigator.of(profileContext).pop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    await startCall();
    final call = widget.controller.activeCall;
    if (call != null && call.status != CallStatus.ended && call.collapsed) {
      widget.controller.toggleCallCollapsed();
    }
  }

  void openGroupInfo() {
    Navigator.push<void>(
      context,
      meshPageRoute<void>(
        builder: (_) =>
            GroupInfoPage(controller: widget.controller, thread: widget.thread),
      ),
    );
  }

  Future<void> showChatAppearance() async {
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'per_chat_theme',
      title: 'Chat appearance',
      description:
          'Choose a separate color theme, bubble shape and animated background for this chat.',
    );
    if (!allowed || !mounted) return;
    var themeId = widget.thread.themeId;
    var bubbleStyle = widget.thread.bubbleStyle;
    var animatedBackground = widget.thread.animatedBackground;
    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: _ChatGlassSurface(
            radius: 28,
            useNativeGlass: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chat appearance',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Theme',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in const [
                        ('midnight', 'Midnight'),
                        ('cyan', 'Cyan'),
                        ('violet', 'Violet'),
                        ('emerald', 'Emerald'),
                      ])
                        ChoiceChip(
                          selected: themeId == option.$1,
                          avatar: CircleAvatar(
                            radius: 8,
                            backgroundColor: _chatThemeAccent(option.$1),
                          ),
                          label: Text(option.$2),
                          onSelected: (_) =>
                              setSheetState(() => themeId = option.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Message bubbles',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'classic', label: Text('Classic')),
                      ButtonSegment(value: 'soft', label: Text('Soft')),
                      ButtonSegment(value: 'compact', label: Text('Compact')),
                    ],
                    selected: {bubbleStyle},
                    onSelectionChanged: (selection) =>
                        setSheetState(() => bubbleStyle = selection.first),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: animatedBackground,
                    onChanged: (value) =>
                        setSheetState(() => animatedBackground = value),
                    secondary: const Icon(Icons.auto_awesome_rounded),
                    title: const Text('Animated background'),
                    subtitle: const Text('Gentle Mesh lights behind messages'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (apply != true || !mounted) return;
    final error = await widget.controller.updateChatAppearance(
      widget.thread,
      themeId: themeId,
      bubbleStyle: bubbleStyle,
      animatedBackground: animatedBackground,
    );
    if (!mounted) return;
    if (error == null) setState(() {});
    if (error != null) showSnack(error);
  }

  Future<void> showScheduleComposer() async {
    if (isChannelCommentThread || widget.thread.isBluetooth) {
      showSnack('Scheduling is unavailable in this chat');
      return;
    }
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'scheduled_messages',
      title: 'Scheduled messages',
      description:
          'Send a message later or turn it into a daily, weekly or monthly reminder.',
    );
    if (!allowed || !mounted) return;
    final scheduleInput = TextEditingController(text: input.text);
    var sendAt = DateTime.now().add(const Duration(hours: 1));
    sendAt = DateTime(
      sendAt.year,
      sendAt.month,
      sendAt.day,
      sendAt.hour,
      sendAt.minute,
    );
    var repeat = 'none';
    final draft = await showModalBottomSheet<_ScheduleDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: _ChatGlassSurface(
              radius: 28,
              useNativeGlass: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.thread.isChannel
                          ? 'Schedule channel post'
                          : 'Schedule message',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: scheduleInput,
                      minLines: 2,
                      maxLines: 5,
                      autofocus: scheduleInput.text.trim().isEmpty,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        prefixIcon: Icon(Icons.schedule_send_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_rounded),
                      title: const Text('Send at'),
                      subtitle: Text(_formatScheduleDate(sendAt)),
                      trailing: const Icon(Icons.edit_calendar_rounded),
                      onTap: () async {
                        final day = await showDatePicker(
                          context: context,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 366),
                          ),
                          initialDate: sendAt,
                        );
                        if (day == null || !context.mounted) return;
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(sendAt),
                        );
                        if (time == null) return;
                        setSheetState(() {
                          sendAt = DateTime(
                            day.year,
                            day.month,
                            day.day,
                            time.hour,
                            time.minute,
                          );
                        });
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: repeat,
                      decoration: const InputDecoration(
                        labelText: 'Repeat',
                        prefixIcon: Icon(Icons.repeat_rounded),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('Never')),
                        DropdownMenuItem(value: 'daily', child: Text('Daily')),
                        DropdownMenuItem(
                          value: 'weekly',
                          child: Text('Weekly'),
                        ),
                        DropdownMenuItem(
                          value: 'monthly',
                          child: Text('Monthly'),
                        ),
                      ],
                      onChanged: (value) =>
                          setSheetState(() => repeat = value ?? 'none'),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          final text = scheduleInput.text.trim();
                          if (text.isEmpty) return;
                          if (!sendAt.isAfter(
                            DateTime.now().add(const Duration(seconds: 5)),
                          )) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Choose a future time'),
                              ),
                            );
                            return;
                          }
                          Navigator.pop(
                            context,
                            _ScheduleDraft(
                              text: text,
                              sendAt: sendAt,
                              repeatInterval: repeat,
                            ),
                          );
                        },
                        icon: const Icon(Icons.schedule_send_rounded),
                        label: const Text('Schedule'),
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
    scheduleInput.dispose();
    if (draft == null || !mounted) return;
    final error = await widget.controller.scheduleTextMessage(
      widget.thread,
      draft.text,
      sendAt: draft.sendAt,
      repeatInterval: draft.repeatInterval,
    );
    if (!mounted) return;
    if (error == null) {
      if (input.text.trim() == draft.text) input.clear();
      widget.controller.updateDraft(widget.thread, input.text);
    } else {
      showSnack(error);
    }
  }

  Future<void> showScheduledMessages() async {
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'scheduled_messages',
      title: 'Scheduled messages',
      description: 'View and cancel messages queued for this chat.',
    );
    if (!allowed || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        top: false,
        child: _ChatGlassSurface(
          radius: 28,
          useNativeGlass: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final scheduled = widget.controller.scheduledForThread(
                  widget.thread,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Scheduled messages',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Schedule another',
                            onPressed: () {
                              Navigator.pop(context);
                              unawaited(showScheduleComposer());
                            },
                            icon: const Icon(Icons.add_rounded),
                          ),
                        ],
                      ),
                    ),
                    if (scheduled.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(22, 26, 22, 34),
                        child: Column(
                          children: [
                            Icon(
                              Icons.schedule_rounded,
                              size: 42,
                              color: Colors.white38,
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Nothing scheduled for this chat',
                              style: TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                          itemCount: scheduled.length,
                          separatorBuilder: (_, _) =>
                              const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (context, index) {
                            final item = scheduled[index];
                            return ListTile(
                              leading: Icon(
                                item.repeats
                                    ? Icons.repeat_rounded
                                    : Icons.schedule_send_rounded,
                                color: _chatThemeAccent(widget.thread.themeId),
                              ),
                              title: Text(item.preview),
                              subtitle: Text(
                                '${_formatScheduleDate(item.nextRunAt)}${item.repeats ? ' - ${_scheduleRepeatLabel(item.repeatInterval)}' : ''}',
                              ),
                              trailing: IconButton(
                                tooltip: 'Cancel',
                                onPressed: () async {
                                  final error = await widget.controller
                                      .cancelScheduledMessage(item);
                                  if (!mounted || error == null) return;
                                  showSnack(error);
                                },
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: Colors.redAccent,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> showDirectActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: _ChatGlassSurface(
          radius: 28,
          useNativeGlass: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.perm_media_outlined),
                  title: const Text('Media'),
                  onTap: () => Navigator.pop(context, 'media'),
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Chat appearance'),
                  onTap: () => Navigator.pop(context, 'appearance'),
                ),
                if (!widget.thread.isBluetooth &&
                    !widget.controller.isSavedMessagesProfile(
                      widget.thread.profile,
                    ))
                  ListTile(
                    leading: aiPersonMemoryLoading
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.psychology_alt_rounded),
                    title: const Text('Ask chat memory'),
                    subtitle: const Text('Answers only from this conversation'),
                    onTap: () => Navigator.pop(context, 'person_memory'),
                  ),
                if (!widget.thread.isBluetooth &&
                    !widget.controller.isSavedMessagesProfile(
                      widget.thread.profile,
                    ))
                  ListTile(
                    leading: const Icon(Icons.schedule_rounded),
                    title: const Text('Scheduled messages'),
                    onTap: () => Navigator.pop(context, 'scheduled'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'media':
        await openMediaList();
        break;
      case 'appearance':
        await showChatAppearance();
        break;
      case 'scheduled':
        await showScheduledMessages();
        break;
      case 'person_memory':
        await showPersonMemory();
        break;
    }
  }

  Future<void> showGroupActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: _ChatGlassSurface(
          radius: 28,
          useNativeGlass: true,
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
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Chat appearance'),
                  onTap: () => Navigator.pop(context, 'appearance'),
                ),
                if (!isChannelCommentThread)
                  ListTile(
                    leading: const Icon(Icons.schedule_rounded),
                    title: const Text('Scheduled messages'),
                    onTap: () => Navigator.pop(context, 'scheduled'),
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
      case 'appearance':
        await showChatAppearance();
        break;
      case 'scheduled':
        await showScheduledMessages();
        break;
    }
  }

  void startMessageSelection(Iterable<ChatMessage> messages) {
    HapticFeedback.selectionClick();
    setState(() {
      selectedMessageIds
        ..clear()
        ..addAll(messages.map((message) => message.id));
    });
  }

  void toggleMessageSelection(Iterable<ChatMessage> messages) {
    HapticFeedback.selectionClick();
    final ids = messages.map((message) => message.id).toSet();
    final allSelected = ids.every(selectedMessageIds.contains);
    setState(() {
      if (allSelected) {
        selectedMessageIds.removeAll(ids);
      } else {
        selectedMessageIds.addAll(ids);
      }
    });
  }

  List<ChatMessage> selectedMessages() {
    final result = visibleMessages()
        .where((message) => selectedMessageIds.contains(message.id))
        .toList();
    return result..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  void clearMessageSelection() {
    if (!selectingMessages) return;
    setState(selectedMessageIds.clear);
  }

  Future<void> deleteSelectedMessages({required bool forEveryone}) async {
    final messages = selectedMessages();
    if (messages.isEmpty) return;
    if (forEveryone &&
        messages.any(
          (message) => message.senderNode != widget.controller.myNodeId,
        )) {
      showSnack('Only your messages can be deleted for everyone');
      return;
    }
    final ids = messages.map((message) => message.id).toSet();
    setState(() {
      deletingMessageIds.addAll(ids);
      selectedMessageIds.clear();
    });
    await Future.delayed(const Duration(milliseconds: 540));
    if (!mounted) return;
    for (final message in messages) {
      if (forEveryone) {
        await widget.controller.deleteMessage(widget.thread, message);
      } else {
        await widget.controller.deleteMessageForMe(widget.thread, message);
      }
    }
    if (mounted) {
      setState(() => deletingMessageIds.removeAll(ids));
    }
  }

  Future<void> copySelectedMessages() async {
    final text = selectedMessages()
        .map((message) => message.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) clearMessageSelection();
  }

  Future<void> saveSelectedMessages() async {
    final messages = selectedMessages();
    for (final message in messages) {
      final error = await widget.controller.saveMessageToSaved(message);
      if (!mounted) return;
      if (error != null) {
        showSnack(error);
        return;
      }
    }
    clearMessageSelection();
  }

  Future<void> showMessageActions(
    ChatMessage message, {
    List<ChatMessage>? selectionGroup,
  }) async {
    HapticFeedback.selectionClick();
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
    final canTranslate = message.text.trim().isNotEmpty;
    final canCopyText = message.text.trim().isNotEmpty;
    final blocked = widget.controller.isBlocked(message.senderNode);
    final canReplyOrComment =
        !widget.thread.isChannel ||
        widget.controller.canCommentInChannel(widget.thread);
    final actions = <_MessageActionSpec>[
      if (mine && message.failed)
        const _MessageActionSpec('retry', 'Retry', Icons.refresh_rounded),
      _MessageActionSpec(
        'reply',
        widget.thread.isChannel && !canReplyOrComment
            ? 'Comments disabled'
            : widget.thread.isChannel
            ? 'Comment'
            : 'Reply',
        widget.thread.isChannel ? Icons.forum_outlined : Icons.reply_rounded,
        enabled: canReplyOrComment,
      ),
      const _MessageActionSpec('forward', 'Forward', Icons.forward_rounded),
      const _MessageActionSpec(
        'save',
        'Save to Saved Messages',
        Icons.bookmark_add_outlined,
      ),
      if (canCopyText)
        const _MessageActionSpec('copy', 'Copy', Icons.copy_rounded),
      if (canCopyText)
        const _MessageActionSpec(
          'select_text',
          'Select text',
          Icons.text_fields_rounded,
        ),
      const _MessageActionSpec(
        'select_messages',
        'Select messages',
        Icons.check_circle_outline_rounded,
      ),
      if (canTranslate)
        const _MessageActionSpec(
          'translate',
          'Translate',
          Icons.translate_rounded,
          subtitle: 'MeshPro',
        ),
      if (canDownload)
        const _MessageActionSpec(
          'download',
          'Download',
          Icons.download_rounded,
        ),
      if (canSaveSticker)
        const _MessageActionSpec(
          'favorite_sticker',
          'Add sticker to favorites',
          Icons.star_border_rounded,
        ),
      if (canSaveSticker)
        const _MessageActionSpec(
          'save_sticker_pack',
          'Add to sticker pack',
          Icons.folder_special_outlined,
          subtitle: 'Saved stickers',
        ),
      if (canEdit)
        _MessageActionSpec(
          'edit',
          message.kind == ChatMessageKind.file ||
                  message.kind == ChatMessageKind.sticker
              ? 'Edit caption'
              : 'Edit',
          Icons.edit_rounded,
        ),
      _MessageActionSpec(
        'pin',
        pinned ? 'Unpin' : 'Pin',
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
      ),
      const _MessageActionSpec(
        'delete_me',
        'Delete for me',
        Icons.delete_sweep_outlined,
        destructive: true,
      ),
      if (mine)
        const _MessageActionSpec(
          'delete_everyone',
          'Delete for everyone',
          Icons.delete_forever_outlined,
          destructive: true,
        ),
      if (canBlock)
        _MessageActionSpec(
          'block',
          blocked ? 'Unblock user' : 'Block user',
          blocked ? Icons.visibility_rounded : Icons.block_rounded,
          destructive: !blocked,
        ),
    ];
    final action = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close message actions',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (dialogContext, _, _) => _MessageContextOverlay(
        reactions: widget.controller.appSettings.quickReactions,
        actions: actions,
        message: message,
        mine: mine,
        preview: _MessageBubbleBody(
          controller: widget.controller,
          thread: widget.thread,
          message: message,
          mine: mine,
          imageBytes: _MessageBubble.imageBytesFor(
            message,
            dataSaver: widget.controller.appSettings.dataSaver,
          ),
          highlighted: true,
          commentCount: commentCountFor(message),
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
      if (error != null) showSnack(error);
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
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.text));
      return;
    }
    if (action == 'select_text') {
      await showMessageTextSelection(message.text);
      return;
    }
    if (action == 'select_messages') {
      startMessageSelection(selectionGroup ?? [message]);
      return;
    }
    if (action == 'save') {
      final error = await widget.controller.saveMessageToSaved(message);
      if (!mounted) return;
      if (error != null) showSnack(error);
      return;
    }
    if (action == 'translate') {
      await showTranslationSheet(message);
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
      if (error != null) showSnack(error);
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
      return;
    }
    if (action.startsWith('reaction:')) {
      await widget.controller.sendReaction(
        widget.thread,
        message,
        action.substring('reaction:'.length),
      );
    }
  }

  Future<void> showMessageTextSelection(String text) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.58),
      builder: (context) => Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: _MessageContextGlass(
          radius: 26,
          prominent: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Select text',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        style: const TextStyle(fontSize: 16, height: 1.35),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) Navigator.pop(context);
                        },
                        icon: const Icon(Icons.copy_all_rounded),
                        label: const Text('Copy all'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> showTranslationSheet(ChatMessage message) async {
    const languages = <String, String>{
      'ru': 'Russian',
      'en': 'English',
      'es': 'Spanish',
      'de': 'German',
      'fr': 'French',
      'it': 'Italian',
      'pt': 'Portuguese',
      'zh': 'Chinese',
      'ja': 'Japanese',
      'ko': 'Korean',
    };
    final localeCode = PlatformDispatcher.instance.locale.languageCode;
    var targetLanguage = RegExp(r'[А-Яа-яЁё]').hasMatch(message.text)
        ? 'en'
        : languages.containsKey(localeCode) && localeCode != 'en'
        ? localeCode
        : 'ru';
    AiTranslationResult? result;
    String? errorText;
    var loading = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> translate() async {
            if (loading) return;
            setModalState(() {
              loading = true;
              errorText = null;
            });
            try {
              final translated = await widget.controller.translateMessageWithAi(
                text: message.text,
                targetLanguage: targetLanguage,
              );
              if (!sheetContext.mounted) return;
              setModalState(() => result = translated);
            } on AiTranslationException catch (error) {
              if (!sheetContext.mounted) return;
              setModalState(() => errorText = error.message);
            } catch (error) {
              if (!sheetContext.mounted) return;
              setModalState(() => errorText = error.toString());
            } finally {
              if (sheetContext.mounted) {
                setModalState(() => loading = false);
              }
            }
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Message translation',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      DropdownButton<String>(
                        value: targetLanguage,
                        items: [
                          for (final entry in languages.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: loading
                            ? null
                            : (value) {
                                if (value == null) return;
                                setModalState(() {
                                  targetLanguage = value;
                                  result = null;
                                });
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _TranslationCard(label: 'Original', text: message.text),
                  if (result != null) ...[
                    const SizedBox(height: 10),
                    _TranslationCard(
                      label:
                          '${languages[result!.targetLanguage] ?? result!.targetLanguage} translation',
                      text: result!.text,
                      trailing: IconButton(
                        tooltip: 'Copy translation',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: result!.text),
                          );
                        },
                      ),
                    ),
                  ],
                  if (errorText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: loading ? null : translate,
                    icon: loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.translate_rounded),
                    label: Text(
                      result == null ? 'Translate' : 'Translate again',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> openChannelComments(ChatMessage post) async {
    if (!widget.thread.isChannel || post.replyToMessageId.isNotEmpty) return;
    await Navigator.push(
      context,
      meshPageRoute<void>(
        builder: (_) => ChatPage(
          controller: widget.controller,
          thread: widget.thread,
          channelPost: post,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> showForwardDialog(ChatMessage message) =>
      showForwardMessagesDialog([message]);

  Future<void> showForwardMessagesDialog(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
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
    for (final message in messages) {
      final error = await widget.controller.forwardMessage(message, target);
      if (!mounted) return;
      if (error != null) {
        showSnack(error);
        return;
      }
    }
    clearMessageSelection();
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
        return;
      }
      if (savedPath != null && savedPath.isNotEmpty) {
        await XFile.fromData(bytes, name: filename).saveTo(savedPath);
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
    setState(() => highlightedMessageId = messageId);
    Future<void>.delayed(const Duration(milliseconds: 1100), () {
      if (mounted && highlightedMessageId == messageId) {
        setState(() => highlightedMessageId = null);
      }
    });
  }

  Future<void> openMediaList() async {
    final messageId = await Navigator.push<String>(
      context,
      meshPageRoute<String>(
        builder: (_) => ChatMediaPage(thread: widget.thread),
      ),
    );
    if (!mounted || messageId == null || messageId.isEmpty) return;
    jumpToMessageById(messageId);
  }

  Future<void> openMeetingPoints() async {
    final messageId = await Navigator.push<String>(
      context,
      meshPageRoute<String>(
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
    final headerInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return PopScope(
      canPop: widget.onBack == null && !selectingMessages,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selectingMessages) {
          clearMessageSelection();
        } else {
          unawaited(widget.onBack?.call());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          forceMaterialTransparency: true,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leadingWidth: 62,
          leading: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _ChatRoundButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              onPressed: selectingMessages
                  ? clearMessageSelection
                  : () {
                      final onBack = widget.onBack;
                      if (onBack != null) {
                        unawaited(onBack());
                      } else {
                        Navigator.maybePop(context);
                      }
                    },
            ),
          ),
          titleSpacing: 4,
          title: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final profile = widget.thread.profile;
              final isSavedMessages = widget.controller.isSavedMessagesProfile(
                profile,
              );
              final active = widget.controller.isTyping(widget.thread);
              final subtitle = active
                  ? widget.controller.activityLabel(widget.thread)
                  : isChannelCommentThread
                  ? profile.displayName
                  : widget.thread.isGroup
                  ? widget.thread.isChannel
                        ? '${widget.thread.members.length} subscribers'
                        : '${widget.thread.members.length} members'
                  : isSavedMessages
                  ? 'private notes'
                  : profile.online
                  ? 'online'
                  : 'offline';
              return _ChatHeaderIdentity(
                title: isChannelCommentThread
                    ? 'Comments'
                    : profile.displayName,
                subtitle: subtitle,
                active: active || widget.thread.isGroup || profile.online,
                onTap: widget.thread.isGroup ? openGroupInfo : openProfile,
              );
            },
          ),
          actions: <Widget>[
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => _ChatHeaderAvatarButton(
                profile: widget.thread.profile,
                onTap: widget.thread.isGroup ? openGroupInfo : openProfile,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: _LiquidMeshBackground(
                enabled:
                    !widget.controller.appSettings.reducedAnimations &&
                    widget.thread.animatedBackground,
                themeId: widget.thread.themeId,
              ),
            ),
            Column(
              children: [
                SizedBox(height: headerInset),
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (unreadSummaryVisible)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 7, 10, 0),
                          child: Align(
                            alignment: Alignment.center,
                            child: FilledButton.tonalIcon(
                              onPressed: aiSummarizing
                                  ? null
                                  : showUnreadSummary,
                              icon: aiSummarizing
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.auto_awesome_rounded,
                                      size: 18,
                                    ),
                              label: Text(
                                'Summarize ${unreadMessageIds.length} unread',
                              ),
                            ),
                          ),
                        ),
                      _PinnedBar(
                        thread: widget.thread,
                        onTap: openPinnedMessages,
                      ),
                      _CallBanner(
                        controller: widget.controller,
                        onSummarize: showCallSummary,
                        summaryLoading: aiCallSummarizing,
                      ),
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
                                  widget.controller.activityLabel(
                                    widget.thread,
                                  ),
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
                  child: ValueListenableBuilder<int>(
                    valueListenable: messageListRefresh,
                    builder: (context, _, _) {
                      final messages = visibleMessages();
                      scheduleInitialScrollToBottom(messages.length);
                      return NotificationListener<ScrollNotification>(
                        onNotification: handleInitialUserScroll,
                        child: ListView.builder(
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
                                if (showDate)
                                  _DatePill(date: message.createdAt),
                                if (album.length > 1)
                                  _PhotoAlbumBubble(
                                    thread: widget.thread,
                                    messages: album,
                                    mine:
                                        message.senderNode ==
                                        widget.controller.myNodeId,
                                    dataSaver:
                                        widget.controller.appSettings.dataSaver,
                                    selected: album.every(
                                      (item) =>
                                          selectedMessageIds.contains(item.id),
                                    ),
                                    onTap: selectingMessages
                                        ? () => toggleMessageSelection(album)
                                        : null,
                                    onLongPress: () => selectingMessages
                                        ? toggleMessageSelection(album)
                                        : showMessageActions(
                                            album.last,
                                            selectionGroup: album,
                                          ),
                                    onReply: () =>
                                        setState(() => replyTo = album.last),
                                  )
                                else
                                  _ViewportMessageTint(
                                    refreshListenable: messageTintRefresh,
                                    builder: (context, positionTint) =>
                                        _MessageDisintegrator(
                                          deleting: deletingMessageIds.contains(
                                            message.id,
                                          ),
                                          child: _MessageBubble(
                                            key: ValueKey(message.id),
                                            controller: widget.controller,
                                            thread: widget.thread,
                                            message: message,
                                            mine:
                                                message.senderNode ==
                                                widget.controller.myNodeId,
                                            dataSaver: widget
                                                .controller
                                                .appSettings
                                                .dataSaver,
                                            selected: selectedMessageIds
                                                .contains(message.id),
                                            onTap: selectingMessages
                                                ? () => toggleMessageSelection([
                                                    message,
                                                  ])
                                                : null,
                                            onLongPress: () => selectingMessages
                                                ? toggleMessageSelection([
                                                    message,
                                                  ])
                                                : showMessageActions(message),
                                            onReply: () =>
                                                widget.thread.isChannel &&
                                                    !isChannelCommentThread
                                                ? openChannelComments(message)
                                                : setState(
                                                    () => replyTo = message,
                                                  ),
                                            onReplyQuoteTap:
                                                message.replyToMessageId.isEmpty
                                                ? null
                                                : () => jumpToMessageById(
                                                    message.replyToMessageId,
                                                  ),
                                            highlighted:
                                                highlightedMessageId ==
                                                message.id,
                                            onOpenComments:
                                                widget.thread.isChannel &&
                                                    !isChannelCommentThread &&
                                                    message
                                                        .replyToMessageId
                                                        .isEmpty
                                                ? () => openChannelComments(
                                                    message,
                                                  )
                                                : null,
                                            commentCount: commentCountFor(
                                              message,
                                            ),
                                            positionTint: positionTint,
                                          ),
                                        ),
                                  ),
                              ],
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                    child: selectingMessages
                        ? _MessageSelectionBar(
                            count: selectedMessageIds.length,
                            canDeleteForEveryone: selectedMessages().every(
                              (message) =>
                                  message.senderNode ==
                                  widget.controller.myNodeId,
                            ),
                            canCopy: selectedMessages().any(
                              (message) => message.text.trim().isNotEmpty,
                            ),
                            onClose: clearMessageSelection,
                            onForward: () =>
                                showForwardMessagesDialog(selectedMessages()),
                            onCopy: copySelectedMessages,
                            onSave: saveSelectedMessages,
                            onDeleteForMe: () =>
                                deleteSelectedMessages(forEveryone: false),
                            onDeleteForEveryone: () =>
                                deleteSelectedMessages(forEveryone: true),
                          )
                        : canPostToThread
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
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) =>
                                    SizeTransition(
                                      sizeFactor: animation,
                                      alignment: AlignmentDirectional.topStart,
                                      child: FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                    ),
                                child:
                                    aiSmartRepliesLoading ||
                                        smartReplies.isNotEmpty
                                    ? Padding(
                                        key: const ValueKey(
                                          'smart-replies-visible',
                                        ),
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: _SmartRepliesBar(
                                          loading: aiSmartRepliesLoading,
                                          replies: smartReplies,
                                          onSelected: useSmartReply,
                                          onClose: () => setState(
                                            () => smartReplies = const [],
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('smart-replies-hidden'),
                                      ),
                              ),
                              Row(
                                children: [
                                  if (!recording) ...[
                                    _ComposerIconButton(
                                      tooltip: 'Attach',
                                      onPressed: showAttachMenu,
                                      icon: Icons.attach_file_rounded,
                                    ),
                                    const SizedBox(width: 8),
                                    _ComposerIconButton(
                                      tooltip: 'Stickers',
                                      onPressed: showStickerPanel,
                                      icon: Icons.auto_awesome_motion_rounded,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: _ComposerInputSurface(
                                      key: composerInputKey,
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
                                                          levels: recordLevels,
                                                        ),
                                                        const SizedBox(
                                                          height: 3,
                                                        ),
                                                        Text(
                                                          voiceCancelArmed
                                                              ? 'Release to cancel'
                                                              : 'Release to send · slide left to cancel',
                                                          maxLines: 1,
                                                          overflow: TextOverflow
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
                                                                FontWeight.w700,
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
                                                decoration: InputDecoration(
                                                  hintText: 'Message',
                                                  isDense: true,
                                                  filled: false,
                                                  border: InputBorder.none,
                                                  enabledBorder:
                                                      InputBorder.none,
                                                  focusedBorder:
                                                      InputBorder.none,
                                                  disabledBorder:
                                                      InputBorder.none,
                                                  errorBorder: InputBorder.none,
                                                  focusedErrorBorder:
                                                      InputBorder.none,
                                                  focusColor:
                                                      Colors.transparent,
                                                  hoverColor:
                                                      Colors.transparent,
                                                  suffixIcon: hasInputText
                                                      ? IconButton(
                                                          tooltip:
                                                              'AI writing assistant',
                                                          onPressed: aiRewriting
                                                              ? null
                                                              : showAiRewrite,
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          icon: AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      180,
                                                                ),
                                                            child: aiRewriting
                                                                ? const SizedBox(
                                                                    key: ValueKey(
                                                                      'ai-loading',
                                                                    ),
                                                                    width: 17,
                                                                    height: 17,
                                                                    child: CircularProgressIndicator(
                                                                      strokeWidth:
                                                                          2,
                                                                    ),
                                                                  )
                                                                : const Icon(
                                                                    Icons
                                                                        .auto_awesome_rounded,
                                                                    key: ValueKey(
                                                                      'ai-ready',
                                                                    ),
                                                                    size: 20,
                                                                    color: Color(
                                                                      0xFFB28AFF,
                                                                    ),
                                                                  ),
                                                          ),
                                                        )
                                                      : IconButton(
                                                          tooltip:
                                                              'Smart replies',
                                                          onPressed:
                                                              aiSmartRepliesLoading
                                                              ? null
                                                              : showSmartReplies,
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          icon:
                                                              aiSmartRepliesLoading
                                                              ? const SizedBox(
                                                                  width: 17,
                                                                  height: 17,
                                                                  child: CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        2,
                                                                  ),
                                                                )
                                                              : const Icon(
                                                                  Icons
                                                                      .quickreply_outlined,
                                                                  size: 20,
                                                                  color: Color(
                                                                    0xFF73D9FF,
                                                                  ),
                                                                ),
                                                        ),
                                                  suffixIconConstraints:
                                                      const BoxConstraints(
                                                        minWidth: 38,
                                                        minHeight: 36,
                                                      ),
                                                ),
                                                onTap:
                                                    scheduleKeyboardScrollToBottom,
                                                onSubmitted: desktopSendHotkeys
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
                                              tooltip:
                                                  'Send · hold to schedule',
                                              onPressed: send,
                                              onLongPress: showScheduleComposer,
                                              icon: Icons.send_rounded,
                                              accent: _chatThemeAccent(
                                                widget.thread.themeId,
                                              ),
                                            )
                                          : _VoiceHoldButton(
                                              key: const ValueKey('mic'),
                                              onStart: startVoiceHold,
                                              onDragUpdate: updateVoiceHoldDrag,
                                              onFinish: () =>
                                                  finishVoiceHold(send: true),
                                              onCancel: () =>
                                                  finishVoiceHold(send: false),
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
                  meshPageRoute<void>(
                    builder: (_) =>
                        ChatPage(controller: widget.controller, thread: thread),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CallBanner extends StatelessWidget {
  const _CallBanner({
    required this.controller,
    required this.onSummarize,
    required this.summaryLoading,
  });

  final AppController controller;
  final VoidCallback onSummarize;
  final bool summaryLoading;

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
          TextButton.icon(
            onPressed: summaryLoading ? null : onSummarize,
            icon: summaryLoading
                ? const SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Summary'),
          ),
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

    return MeshLiquidGlass(
      forceFlutterSurface: true,
      radius: 34,
      accent: accent,
      prominent: true,
      interactive: false,
      fallbackBuilder: (context, child) => ClipRRect(
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
            child: child,
          ),
        ),
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
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              '$title · ${formatDuration(controller.callElapsed)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            _CallStatusStrip(controller: controller),
            if (call.remoteScreenSharing) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () => _openRemoteScreenFullscreen(context),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: const Color(0xFF07111E),
                    child: SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          controller.buildRemoteCallScreen(),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: BoxShape.circle,
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(
                                  Icons.fullscreen_rounded,
                                  size: 21,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                runAlignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
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
                  if (controller.canShareCallScreen)
                    _CallGlassButton(
                      tooltip: call.screenSharing
                          ? 'Stop screen sharing'
                          : 'Share screen',
                      icon: call.screenSharing
                          ? Icons.stop_screen_share_rounded
                          : Icons.screen_share_rounded,
                      accent: call.screenSharing
                          ? Colors.lightBlueAccent
                          : Colors.white70,
                      onPressed: () => _toggleScreenShare(context),
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
    );
  }

  Future<void> _toggleScreenShare(BuildContext context) async {
    final error = await controller.toggleCallScreenShare();
    if (error == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  void _openRemoteScreenFullscreen(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) =>
            _FullscreenRemoteScreen(controller: controller),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
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

class _FullscreenRemoteScreen extends StatelessWidget {
  const _FullscreenRemoteScreen({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                boundaryMargin: const EdgeInsets.all(80),
                child: SizedBox.expand(
                  child: ColoredBox(
                    color: Colors.black,
                    child: controller.buildRemoteCallScreen(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: MeshLiquidGlass(
                forceFlutterSurface: true,
                accent: Colors.white70,
                radius: 999,
                interactive: true,
                child: IconButton(
                  tooltip: 'Close full screen',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_fullscreen_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
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
              customBorder: const CircleBorder(),
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
        if (call.hdAudio)
          const _CallInfoPill(
            icon: Icons.hd_rounded,
            label: 'HD voice',
            accent: Colors.lightBlueAccent,
          ),
        if (call.screenSharing || call.remoteScreenSharing)
          _CallInfoPill(
            icon: Icons.screen_share_rounded,
            label: call.screenSharing ? 'Sharing screen' : 'Screen shared',
            accent: Colors.purpleAccent,
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
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  AppLifecycleState lifecycleState = AppLifecycleState.resumed;
  bool tickerEnabled = true;

  bool get canAnimate =>
      lifecycleState == AppLifecycleState.resumed && tickerEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(milliseconds: 1250),
      frameInterval: const Duration(milliseconds: 50),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (tickerEnabled == enabled) return;
    tickerEnabled = enabled;
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycleState = state;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (canAnimate) {
      if (!controller.isAnimating) controller.repeat();
    } else {
      controller.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
          final frame = (controller.value * 38).floor() / 38;
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
                                  .sin(frame * math.pi * 2 + index * 0.78)
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
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: ProfileAvatar(profile: profile, radius: 19),
    );
  }
}

class _ChatHeaderIdentity extends StatelessWidget {
  const _ChatHeaderIdentity({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 310),
      child: MeshLiquidGlass(
        forceFlutterSurface: true,
        radius: 23,
        accent: const Color(0xFF72D7FF),
        interactive: true,
        fallbackBuilder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF1A2533).withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.25),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: active ? Colors.greenAccent : Colors.white54,
                      ),
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

class _ChatHeaderAvatarButton extends StatelessWidget {
  const _ChatHeaderAvatarButton({required this.profile, required this.onTap});

  final Profile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Open profile',
      child: MeshLiquidGlass(
        forceFlutterSurface: true,
        radius: 999,
        accent: const Color(0xFFB463FF),
        interactive: true,
        fallbackBuilder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1A2533),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: _ChatAvatarRing(profile: profile),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewportMessageTint extends StatefulWidget {
  const _ViewportMessageTint({
    required this.refreshListenable,
    required this.builder,
  });

  final Listenable refreshListenable;
  final Widget Function(BuildContext context, double position) builder;

  @override
  State<_ViewportMessageTint> createState() => _ViewportMessageTintState();
}

class _ViewportMessageTintState extends State<_ViewportMessageTint> {
  double position = 0.55;

  @override
  void initState() {
    super.initState();
    widget.refreshListenable.addListener(refreshPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => refreshPosition());
  }

  @override
  void didUpdateWidget(covariant _ViewportMessageTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshListenable == widget.refreshListenable) return;
    oldWidget.refreshListenable.removeListener(refreshPosition);
    widget.refreshListenable.addListener(refreshPosition);
  }

  void refreshPosition() {
    if (!mounted) return;
    final renderObject = context.findRenderObject();
    final viewportHeight = MediaQuery.sizeOf(context).height;
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final next = (renderObject.localToGlobal(Offset.zero).dy / viewportHeight)
        .clamp(0.0, 1.0);
    if ((next - position).abs() < 0.015) return;
    setState(() => position = next);
  }

  @override
  void dispose() {
    widget.refreshListenable.removeListener(refreshPosition);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, position);
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
        child: MeshLiquidGlass(
          forceFlutterSurface: true,
          radius: 999,
          accent: Colors.lightBlueAccent,
          prominent: true,
          interactive: true,
          fallbackBuilder: (context, child) => ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Material(
                color: Colors.white.withValues(alpha: 0.10),
                shape: CircleBorder(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                ),
                child: child,
              ),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.055),
                border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
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

class _AiRewriteSheet extends StatelessWidget {
  const _AiRewriteSheet();

  static const options =
      <({String id, String title, String subtitle, IconData icon})>[
        (
          id: 'proofread',
          title: 'Fix punctuation',
          subtitle: 'Correct spelling and grammar without changing your tone',
          icon: Icons.spellcheck_rounded,
        ),
        (
          id: 'concise',
          title: 'Make concise',
          subtitle: 'Shorten the draft and keep the important details',
          icon: Icons.compress_rounded,
        ),
        (
          id: 'friendly',
          title: 'Conversational',
          subtitle: 'Make it sound natural, warm, and friendly',
          icon: Icons.sentiment_satisfied_alt_rounded,
        ),
        (
          id: 'business',
          title: 'Business',
          subtitle: 'Use a clear and professional tone',
          icon: Icons.business_center_rounded,
        ),
        (
          id: 'soften',
          title: 'Make softer',
          subtitle: 'Reduce tension while preserving the meaning',
          icon: Icons.spa_outlined,
        ),
        (
          id: 'expand',
          title: 'Add detail',
          subtitle: 'Make the thought more complete without inventing facts',
          icon: Icons.notes_rounded,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
        decoration: BoxDecoration(
          color: const Color(0xF516202C),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF9A6DFF).withValues(alpha: 0.16),
              blurRadius: 34,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: Color(0xFFB28AFF)),
                  SizedBox(width: 10),
                  Text(
                    'Rewrite with Mesh AI',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
            for (final option in options)
              ListTile(
                leading: Icon(option.icon, color: const Color(0xFF7DCEFF)),
                title: Text(
                  option.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  option.subtitle,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                onTap: () => Navigator.pop(context, option.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _SmartRepliesBar extends StatelessWidget {
  const _SmartRepliesBar({
    required this.loading,
    required this.replies,
    required this.onSelected,
    required this.onClose,
  });

  final bool loading;
  final List<String> replies;
  final ValueChanged<String> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (loading && replies.isEmpty) {
      return const SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 9),
            Text(
              'Thinking of replies...',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 5),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 17,
              color: Color(0xFFB28AFF),
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: replies.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final reply = replies[index];
                return ActionChip(
                  onPressed: () => onSelected(reply),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 210),
                    child: Text(
                      reply,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.13)),
                  backgroundColor: Colors.white.withValues(alpha: 0.07),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Hide replies',
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _MessageSelectionBar extends StatelessWidget {
  const _MessageSelectionBar({
    required this.count,
    required this.canDeleteForEveryone,
    required this.canCopy,
    required this.onClose,
    required this.onForward,
    required this.onCopy,
    required this.onSave,
    required this.onDeleteForMe,
    required this.onDeleteForEveryone,
  });

  final int count;
  final bool canDeleteForEveryone;
  final bool canCopy;
  final VoidCallback onClose;
  final VoidCallback onForward;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDeleteForMe;
  final VoidCallback onDeleteForEveryone;

  @override
  Widget build(BuildContext context) {
    return _MessageContextGlass(
      radius: 28,
      prominent: true,
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Text(
                '$count',
                key: ValueKey(count),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Forward selected',
                      onPressed: onForward,
                      icon: const Icon(Icons.forward_rounded),
                    ),
                    IconButton(
                      tooltip: 'Copy selected text',
                      onPressed: canCopy ? onCopy : null,
                      icon: const Icon(Icons.copy_all_rounded),
                    ),
                    IconButton(
                      tooltip: 'Save to Saved Messages',
                      onPressed: onSave,
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                    IconButton(
                      tooltip: 'Delete for me',
                      onPressed: onDeleteForMe,
                      color: Colors.redAccent,
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                    IconButton(
                      tooltip: canDeleteForEveryone
                          ? 'Delete for everyone'
                          : 'Only your messages can be deleted for everyone',
                      onPressed: canDeleteForEveryone
                          ? onDeleteForEveryone
                          : null,
                      color: Colors.redAccent,
                      icon: const Icon(Icons.delete_forever_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendFlightOverlay extends StatefulWidget {
  const _SendFlightOverlay({
    required this.start,
    required this.end,
    required this.text,
    required this.color,
    required this.onFinished,
  });

  final Rect start;
  final Rect end;
  final String text;
  final Color color;
  final VoidCallback onFinished;

  @override
  State<_SendFlightOverlay> createState() => _SendFlightOverlayState();
}

class _SendFlightOverlayState extends State<_SendFlightOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Animation<double> curved;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 310),
    );
    curved = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished();
    });
    controller.forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, _) {
          final progress = curved.value;
          final rect = Rect.lerp(widget.start, widget.end, progress)!;
          return Positioned.fromRect(
            rect: rect,
            child: Opacity(
              opacity: (1 - math.max(0, (progress - 0.82) / 0.18))
                  .clamp(0.0, 1.0)
                  .toDouble(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.24),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ComposerInputSurface extends StatelessWidget {
  const _ComposerInputSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MeshLiquidGlass(
      forceFlutterSurface: true,
      radius: 22,
      accent: const Color(0xFF72D7FF),
      interactive: true,
      fallbackBuilder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A2533).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: child,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: child,
      ),
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
    this.onLongPress,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final Color accent;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MeshLiquidGlass(
        forceFlutterSurface: true,
        radius: 999,
        accent: accent,
        interactive: true,
        fallbackBuilder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1A2533).withValues(alpha: 0.96),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            onLongPress: onLongPress,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: accent),
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
          child: MeshLiquidGlass(
            forceFlutterSurface: true,
            radius: 999,
            accent: pressed ? Colors.redAccent : Colors.lightBlueAccent,
            interactive: true,
            fallbackBuilder: (context, child) => DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A2533).withValues(alpha: 0.96),
                border: Border.all(
                  color: (pressed ? Colors.redAccent : Colors.white).withValues(
                    alpha: pressed ? 0.34 : 0.12,
                  ),
                ),
              ),
              child: child,
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: pressed
                    ? Colors.redAccent.withValues(alpha: 0.14)
                    : Colors.transparent,
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
          useNativeGlass: true,
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

Color _chatThemeAccent(String themeId) {
  return switch (themeId) {
    'cyan' => const Color(0xFF45D6FF),
    'violet' => const Color(0xFFB463FF),
    'emerald' => const Color(0xFF57E6A8),
    _ => const Color(0xFF69AFFF),
  };
}

Color _chatThemeBackground(String themeId) {
  return switch (themeId) {
    'cyan' => const Color(0xFF0C1820),
    'violet' => const Color(0xFF151321),
    'emerald' => const Color(0xFF101B19),
    _ => const Color(0xFF111820),
  };
}

List<Color> _chatThemeGlowColors(String themeId) {
  return switch (themeId) {
    'cyan' => const [Color(0xFF45D6FF), Color(0xFF3AA9FF), Color(0xFF57FFC1)],
    'violet' => const [Color(0xFFB463FF), Color(0xFF7E73FF), Color(0xFFFF72D0)],
    'emerald' => const [
      Color(0xFF57FFC1),
      Color(0xFF2BD6A1),
      Color(0xFF45D6FF),
    ],
    _ => const [Color(0xFF45D6FF), Color(0xFFB463FF), Color(0xFF57FFC1)],
  };
}

Color _chatBubbleColor(String themeId, bool mine) {
  if (!mine) {
    return switch (themeId) {
      'cyan' => const Color(0xFF20343E),
      'violet' => const Color(0xFF302B42),
      'emerald' => const Color(0xFF243832),
      _ => const Color(0xFF2A2E35),
    };
  }
  return switch (themeId) {
    'cyan' => const Color(0xFF087F9E),
    'violet' => const Color(0xFF7453C8),
    'emerald' => const Color(0xFF27815B),
    _ => const Color(0xFF2587E8),
  };
}

BorderRadius _chatBubbleRadius(String style, bool mine) {
  final large = style == 'soft'
      ? 19.0
      : style == 'compact'
      ? 9.0
      : 12.0;
  final tail = style == 'soft'
      ? 11.0
      : style == 'compact'
      ? 3.0
      : 4.0;
  return BorderRadius.only(
    topLeft: Radius.circular(large),
    topRight: Radius.circular(large),
    bottomLeft: Radius.circular(mine ? large : tail),
    bottomRight: Radius.circular(mine ? tail : large),
  );
}

EdgeInsets _chatBubblePadding(String style, {required bool mediaPreview}) {
  if (style == 'compact') {
    return EdgeInsets.fromLTRB(9, mediaPreview ? 4 : 6, 8, 5);
  }
  if (style == 'soft') {
    return EdgeInsets.fromLTRB(13, mediaPreview ? 7 : 10, 11, 8);
  }
  return EdgeInsets.fromLTRB(11, mediaPreview ? 6 : 8, 9, 6);
}

String _formatScheduleDate(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _scheduleRepeatLabel(String value) {
  return switch (value) {
    'daily' => 'Daily',
    'weekly' => 'Weekly',
    'monthly' => 'Monthly',
    _ => 'Once',
  };
}

class _LiquidMeshBackground extends StatefulWidget {
  const _LiquidMeshBackground({required this.enabled, required this.themeId});

  final bool enabled;
  final String themeId;

  @override
  State<_LiquidMeshBackground> createState() => _LiquidMeshBackgroundState();
}

class _LiquidMeshBackgroundState extends State<_LiquidMeshBackground>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  late final Timer timer;
  final random = math.Random();
  List<int> activePoints = const [0, 6];
  late List<Color> activeColors;
  bool appActive = true;
  bool tickerModeActive = true;

  bool get canAnimate => widget.enabled && appActive && tickerModeActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    activeColors = _chatThemeGlowColors(widget.themeId);
    controller = MeshFrameClock(
      duration: const Duration(milliseconds: 2200),
      frameInterval: const Duration(milliseconds: 50),
    );
    timer = Timer.periodic(const Duration(milliseconds: 8200), (_) {
      if (!canAnimate) return;
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
        final palette = _chatThemeGlowColors(widget.themeId);
        activeColors = random.nextBool()
            ? palette
            : [palette[1], palette[2], palette[0]];
      });
      controller.forward(from: 0);
    });
    Future<void>.delayed(const Duration(milliseconds: 700), () {
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
  void didUpdateWidget(covariant _LiquidMeshBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeId != widget.themeId) {
      activeColors = _chatThemeGlowColors(widget.themeId);
      if (canAnimate) controller.forward(from: 0);
    }
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
      decoration: BoxDecoration(color: _chatThemeBackground(widget.themeId)),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            isComplex: true,
            willChange: controller.isAnimating,
            painter: _LiquidMeshPainter(
              activePoints: activePoints,
              activeColors: activeColors,
              pulse: canAnimate
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
    drawRadialGlow(
      canvas,
      center: Offset(size.width * 0.18, size.height * 0.18),
      radius: 205,
      color: activeColors[0],
      opacity: 0.030,
    );
    drawRadialGlow(
      canvas,
      center: Offset(size.width * 0.88, size.height * 0.30),
      radius: 235,
      color: activeColors[1 % activeColors.length],
      opacity: 0.027,
    );
    drawRadialGlow(
      canvas,
      center: Offset(size.width * 0.54, size.height * 0.86),
      radius: 255,
      color: activeColors[2 % activeColors.length],
      opacity: 0.022,
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
  const _ChatGlassSurface({
    required this.child,
    this.radius = 22,
    this.useNativeGlass = false,
  });

  final Widget child;
  final double radius;
  final bool useNativeGlass;

  @override
  Widget build(BuildContext context) {
    Widget fallback(BuildContext context, Widget child) => ClipRRect(
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

    if (!useNativeGlass) return fallback(context, child);
    return MeshLiquidGlass(
      forceFlutterSurface: true,
      radius: radius,
      accent: Colors.lightBlueAccent,
      fallbackBuilder: fallback,
      child: child,
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
    return MeshLiquidGlass(
      forceFlutterSurface: true,
      radius: 22,
      accent: accent,
      prominent: true,
      fallbackBuilder: (context, child) => ClipRRect(
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
            child: child,
          ),
        ),
      ),
      child: Stack(children: [child]),
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
    required this.thread,
    required this.messages,
    required this.mine,
    required this.dataSaver,
    required this.onLongPress,
    required this.onReply,
    this.onTap,
    this.selected = false,
  });

  final ChatThread thread;
  final List<ChatMessage> messages;
  final bool mine;
  final bool dataSaver;
  final VoidCallback onLongPress;
  final VoidCallback onReply;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final visible = messages.take(4).toList(growable: false);
    final last = messages.last;
    final time = last.createdAt.toLocal();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        onHorizontalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 650) onReply();
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 286),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
          decoration: BoxDecoration(
            color: _chatBubbleColor(thread.themeId, mine),
            borderRadius: _chatBubbleRadius(thread.bubbleStyle, mine),
            border: selected
                ? Border.all(color: const Color(0xFF75D9FF), width: 2)
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF5BCBFF).withValues(alpha: 0.26),
                      blurRadius: 18,
                    ),
                  ]
                : null,
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
                        onTap:
                            onTap ??
                            (bytes == null
                                ? null
                                : () => _showAlbumImage(context, bytes)),
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
                  if (selected) ...[
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: Color(0xFF75D9FF),
                    ),
                    const SizedBox(width: 5),
                  ],
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
    super.key,
    required this.controller,
    required this.thread,
    required this.message,
    required this.mine,
    required this.dataSaver,
    required this.onLongPress,
    required this.onReply,
    this.onTap,
    this.selected = false,
    this.onReplyQuoteTap,
    this.highlighted = false,
    this.onOpenComments,
    this.commentCount = 0,
    this.positionTint = 0.55,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage message;
  final bool mine;
  final bool dataSaver;
  final VoidCallback onLongPress;
  final VoidCallback onReply;
  final VoidCallback? onTap;
  final bool selected;
  final VoidCallback? onReplyQuoteTap;
  final bool highlighted;
  final VoidCallback? onOpenComments;
  final int commentCount;
  final double positionTint;

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
  bool replyArmed = false;
  bool appeared = false;
  late final bool animateAppearance;

  @override
  void initState() {
    super.initState();
    animateAppearance =
        DateTime.now().difference(widget.message.createdAt).abs() <
        const Duration(seconds: 4);
    appeared = !animateAppearance;
    if (animateAppearance) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => appeared = true);
      });
    }
  }

  void _updateReplyDrag(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta <= 0 && replyDrag <= 0) return;
    final next = (replyDrag + delta).clamp(0, 86).toDouble();
    final armed = next >= 54;
    if (armed && !replyArmed) HapticFeedback.selectionClick();
    setState(() {
      replyDrag = next;
      replyArmed = armed;
    });
  }

  void _finishReplyDrag(DragEndDetails details) {
    final shouldReply = replyDrag >= 54 || (details.primaryVelocity ?? 0) > 650;
    if (shouldReply) widget.onReply();
    setState(() {
      replyDrag = 0;
      replyArmed = false;
    });
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
      tween: Tween(begin: animateAppearance ? 0 : 1, end: appeared ? 1 : 0),
      duration: animateAppearance
          ? const Duration(milliseconds: 260)
          : Duration.zero,
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
              onHorizontalDragUpdate: widget.selected || widget.onTap != null
                  ? null
                  : _updateReplyDrag,
              onHorizontalDragEnd: widget.selected || widget.onTap != null
                  ? null
                  : _finishReplyDrag,
              onHorizontalDragCancel: widget.selected || widget.onTap != null
                  ? null
                  : () => setState(() {
                      replyDrag = 0;
                      replyArmed = false;
                    }),
              onLongPress: widget.onLongPress,
              onTap:
                  widget.onTap ??
                  (imageBytes == null
                      ? null
                      : () => _showImage(context, imageBytes, message.id)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(replyDrag, 0, 0),
                transformAlignment: Alignment.center,
                constraints: const BoxConstraints(maxWidth: 340),
                margin: const EdgeInsets.only(bottom: 8),
                child: MessageSendEffect(
                  messageId: message.id,
                  effect: message.messageEffect,
                  enabled:
                      widget.controller.appSettings.messageEffectsEnabled &&
                      !widget.controller.appSettings.reducedAnimations &&
                      message.messageEffect != 'none' &&
                      DateTime.now().difference(message.createdAt).abs() <
                          const Duration(seconds: 12),
                  child: _MessageBubbleBody(
                    controller: widget.controller,
                    thread: widget.thread,
                    message: message,
                    mine: mine,
                    imageBytes: imageBytes,
                    onReplyQuoteTap: widget.onReplyQuoteTap,
                    highlighted: widget.highlighted || widget.selected,
                    onOpenComments: widget.onOpenComments,
                    commentCount: widget.commentCount,
                    positionTint: widget.positionTint,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImage(BuildContext context, Uint8List bytes, String messageId) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(14),
        backgroundColor: Colors.black,
        child: Hero(
          tag: 'message-media-$messageId',
          child: InteractiveViewer(
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
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
    this.onReplyQuoteTap,
    this.highlighted = false,
    this.onOpenComments,
    this.commentCount = 0,
    this.positionTint = 0.55,
  });

  final AppController controller;
  final ChatThread thread;
  final ChatMessage message;
  final bool mine;
  final Uint8List? imageBytes;
  final VoidCallback? onReplyQuoteTap;
  final bool highlighted;
  final VoidCallback? onOpenComments;
  final int commentCount;
  final double positionTint;

  @override
  Widget build(BuildContext context) {
    final time = message.createdAt.toLocal();
    final meetingPoint = _MeetingPoint.fromMessageText(message.text);
    final sharedLocation = _SharedLocation.fromMessageText(message.text);
    final groupPresentation = _groupMessagePresentation(
      controller: controller,
      thread: thread,
      message: message,
      mine: mine,
    );
    final baseBubbleColor = _chatBubbleColor(thread.themeId, mine);
    final verticalShade = ((0.54 - positionTint) * 0.20).clamp(-0.07, 0.10);
    final bubbleColor = verticalShade >= 0
        ? Color.lerp(baseBubbleColor, Colors.black, verticalShade)!
        : Color.lerp(baseBubbleColor, Colors.white, -verticalShade)!;
    final inlineMetadata =
        message.kind == ChatMessageKind.text &&
        meetingPoint == null &&
        sharedLocation == null;
    final metadata = _MessageMetadata(message: message, mine: mine, time: time);
    if (message.kind == ChatMessageKind.sticker) {
      return Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (groupPresentation.senderName.isNotEmpty) ...[
            Text(
              groupPresentation.senderName,
              style: TextStyle(
                color: _senderAccent(message.senderNode),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
          ],
          if (message.replyToText.isNotEmpty) ...[
            Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2E35).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _ReplyQuote(
                text: message.replyToText,
                onTap: onReplyQuoteTap,
              ),
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
        AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(maxWidth: 340),
          padding: _chatBubblePadding(
            thread.bubbleStyle,
            mediaPreview:
                (message.kind == ChatMessageKind.file ||
                    message.kind == ChatMessageKind.sticker) &&
                imageBytes != null,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: _chatBubbleRadius(thread.bubbleStyle, mine),
            border: highlighted
                ? Border.all(
                    color: const Color(0xFF82D8FF).withValues(alpha: 0.78),
                    width: 1.4,
                  )
                : null,
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: const Color(0xFF82D8FF).withValues(alpha: 0.2),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (groupPresentation.senderName.isNotEmpty) ...[
                Text(
                  groupPresentation.senderName,
                  style: TextStyle(
                    color: _senderAccent(message.senderNode),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              if (message.replyToText.isNotEmpty) ...[
                _ReplyQuote(text: message.replyToText, onTap: onReplyQuoteTap),
                const SizedBox(height: 6),
              ],
              if (inlineMetadata)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: _MessageTextContent(
                        text: groupPresentation.text,
                        createdAt: message.createdAt,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: metadata,
                    ),
                  ],
                )
              else
                message.kind == ChatMessageKind.sticker
                    ? _StickerMessagePreview(
                        message: message,
                        imageBytes: imageBytes,
                      )
                    : message.kind == ChatMessageKind.file
                    ? _FilePreview(
                        message: message,
                        imageBytes: imageBytes,
                        controller: controller,
                      )
                    : meetingPoint == null
                    ? _SharedLocationPreview(location: sharedLocation!)
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
              if (!inlineMetadata) ...[
                const SizedBox(height: 3),
                Align(
                  alignment: Alignment.centerRight,
                  widthFactor: 1,
                  child: metadata,
                ),
              ],
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

class _MessageMetadata extends StatelessWidget {
  const _MessageMetadata({
    required this.message,
    required this.mine,
    required this.time,
  });

  final ChatMessage message;
  final bool mine;
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 10, color: Colors.white60),
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
    );
  }
}

class _MessageTextContent extends StatelessWidget {
  const _MessageTextContent({required this.text, required this.createdAt});

  final String text;
  final DateTime createdAt;

  @override
  Widget build(BuildContext context) {
    final suggestion = _ContextSuggestion.parse(text, createdAt.toLocal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _LinkifiedSelectableText(text: text),
        if (suggestion != null) ...[
          const SizedBox(height: 8),
          _ContextActionCard(suggestion: suggestion),
        ],
      ],
    );
  }
}

class _LinkifiedSelectableText extends StatefulWidget {
  const _LinkifiedSelectableText({required this.text});

  final String text;

  @override
  State<_LinkifiedSelectableText> createState() =>
      _LinkifiedSelectableTextState();
}

class _LinkifiedSelectableTextState extends State<_LinkifiedSelectableText> {
  static final _linkPattern = RegExp(
    r'(?:(?:https?://|www\.)[^\s<>]+|(?:mailto:|tel:)[^\s<>]+)',
    caseSensitive: false,
  );
  final recognizers = <TapGestureRecognizer>[];
  late List<InlineSpan> spans;

  @override
  void initState() {
    super.initState();
    spans = _linkifiedSpans();
  }

  @override
  void didUpdateWidget(covariant _LinkifiedSelectableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _disposeRecognizers();
    spans = _linkifiedSpans();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
    recognizers.clear();
  }

  List<InlineSpan> _linkifiedSpans() {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _linkPattern.allMatches(widget.text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      var label = match.group(0)!;
      var suffix = '';
      while (label.isNotEmpty && '.,!?;:)'.contains(label[label.length - 1])) {
        suffix = label[label.length - 1] + suffix;
        label = label.substring(0, label.length - 1);
      }
      final target = label.toLowerCase().startsWith('www.')
          ? 'https://$label'
          : label;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _openLink(target);
      recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: label,
          style: const TextStyle(
            color: Color(0xFF74D8FF),
            decoration: TextDecoration.underline,
            decorationColor: Color(0x8874D8FF),
          ),
          recognizer: recognizer,
        ),
      );
      if (suffix.isNotEmpty) spans.add(TextSpan(text: suffix));
      cursor = match.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return spans;
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    var opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      TextSpan(style: DefaultTextStyle.of(context).style, children: spans),
    );
  }
}

class _ContextActionCard extends StatelessWidget {
  const _ContextActionCard({required this.suggestion});

  final _ContextSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final opened = await launchUrl(
            suggestion.uri,
            mode: LaunchMode.externalApplication,
          );
          if (!opened && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Could not ${suggestion.actionLabel.toLowerCase()}',
                ),
              ),
            );
          }
        },
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: suggestion.color.withValues(alpha: 0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(suggestion.icon, size: 18, color: suggestion.color),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      suggestion.actionLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      suggestion.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.arrow_outward_rounded,
                size: 15,
                color: suggestion.color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextSuggestion {
  const _ContextSuggestion({
    required this.actionLabel,
    required this.detail,
    required this.icon,
    required this.color,
    required this.uri,
  });

  final String actionLabel;
  final String detail;
  final IconData icon;
  final Color color;
  final Uri uri;

  static _ContextSuggestion? parse(String source, DateTime createdAt) {
    final text = source.trim();
    if (text.isEmpty || text.startsWith('::meshchat_')) return null;

    final address = RegExp(
      r'(?:адрес|address)\s*[:\-]?\s+([^\n]{5,80})',
      caseSensitive: false,
    ).firstMatch(text);
    if (address != null) {
      final query = address.group(1)!.trim();
      return _ContextSuggestion(
        actionLabel: 'Open on map',
        detail: query,
        icon: Icons.map_outlined,
        color: const Color(0xFF65E6C4),
        uri: Uri.https('www.google.com', '/maps/search/', {
          'api': '1',
          'query': query,
        }),
      );
    }

    final relative = RegExp(
      r'(?:через|in)\s+(\d{1,3})\s*(минут(?:у|ы)?|мин|час(?:а|ов)?|minutes?|mins?|hours?|hrs?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (relative != null) {
      final amount = int.parse(relative.group(1)!);
      final unit = relative.group(2)!.toLowerCase();
      final duration = unit.startsWith('ч') || unit.startsWith('h')
          ? Duration(hours: amount)
          : Duration(minutes: amount);
      final start = DateTime.now().add(duration);
      return _calendarSuggestion(
        label: 'Create reminder',
        detail: _contextDateLabel(start),
        title: text,
        start: start,
        icon: Icons.alarm_add_rounded,
      );
    }

    final tomorrow = RegExp(
      r'(?:завтра|tomorrow)(?:\s+в|\s+at)?\s+(\d{1,2})[:.]?(\d{2})?',
      caseSensitive: false,
    ).firstMatch(text);
    if (tomorrow != null) {
      final now = DateTime.now();
      final start = DateTime(
        now.year,
        now.month,
        now.day + 1,
        int.parse(tomorrow.group(1)!),
        int.tryParse(tomorrow.group(2) ?? '') ?? 0,
      );
      return _calendarSuggestion(
        label: 'Create event',
        detail: _contextDateLabel(start),
        title: text,
        start: start,
        icon: Icons.event_available_rounded,
      );
    }
    return null;
  }

  static _ContextSuggestion _calendarSuggestion({
    required String label,
    required String detail,
    required String title,
    required DateTime start,
    required IconData icon,
  }) {
    final end = start.add(const Duration(hours: 1));
    return _ContextSuggestion(
      actionLabel: label,
      detail: detail,
      icon: icon,
      color: const Color(0xFF8EC8FF),
      uri: Uri.https('calendar.google.com', '/calendar/render', {
        'action': 'TEMPLATE',
        'text': title,
        'dates': '${_calendarStamp(start)}/${_calendarStamp(end)}',
        'details': 'Created from a MeshChat message',
      }),
    );
  }
}

String _calendarStamp(DateTime value) {
  final utc = value.toUtc();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}T'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

String _contextDateLabel(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.'
    '${value.month.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

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
  const _ReplyQuote({required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
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
    return Hero(
      tag: 'message-media-${message.id}',
      child: ConstrainedBox(
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
      ),
    );
  }
}

class _FilePreview extends StatefulWidget {
  const _FilePreview({
    required this.message,
    required this.imageBytes,
    required this.controller,
  });

  final ChatMessage message;
  final Uint8List? imageBytes;
  final AppController controller;

  @override
  State<_FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<_FilePreview> {
  bool extractingText = false;
  late String localOcrText;
  late bool localOcrProcessed;

  ChatMessage get message => widget.message;

  @override
  void initState() {
    super.initState();
    localOcrText = message.ocrText;
    localOcrProcessed = message.ocrProcessed;
  }

  @override
  void didUpdateWidget(covariant _FilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.ocrText != message.ocrText ||
        oldWidget.message.ocrProcessed != message.ocrProcessed) {
      localOcrText = message.ocrText;
      localOcrProcessed = message.ocrProcessed;
    }
  }

  Future<void> extractText() async {
    if (extractingText) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_image_ocr',
      title: 'Extract text',
      description: 'Recognize text in this photo or document image.',
    );
    if (!allowed || !mounted) return;
    setState(() => extractingText = true);
    try {
      final result = await widget.controller.extractImageTextWithAi(message);
      if (!mounted) return;
      setState(() {
        localOcrText = result.text;
        localOcrProcessed = result.processed;
      });
    } on AiOcrException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Text extraction failed')));
    } finally {
      if (mounted) setState(() => extractingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.imageBytes;
    if (bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Hero(
            tag: 'message-media-${message.id}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 300,
                  maxHeight: 260,
                ),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          if (localOcrProcessed)
            _OcrResultCard(text: localOcrText)
          else if (isOcrImageName(message.fileName))
            TextButton.icon(
              onPressed: extractingText ? null : extractText,
              icon: extractingText
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.document_scanner_outlined, size: 18),
              label: Text(
                extractingText ? 'Extracting text...' : 'Extract text',
              ),
            ),
          _FileCaption(text: message.text),
        ],
      );
    }
    if (isImageName(message.fileName)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _UnavailableFilePreview(
            icon: Icons.image_not_supported_outlined,
            title: message.fileName.isEmpty ? 'Photo' : message.fileName,
            subtitle: 'Preview is not cached',
          ),
          if (localOcrProcessed) ...[
            const SizedBox(height: 7),
            _OcrResultCard(text: localOcrText),
          ],
        ],
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
          _AudioPreview(message: message, controller: widget.controller),
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

class _OcrResultCard extends StatelessWidget {
  const _OcrResultCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final recognized = text.trim();
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.document_scanner_outlined,
                size: 16,
                color: Color(0xFF73D9FF),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Recognized text',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.white70,
                  ),
                ),
              ),
              if (recognized.isNotEmpty)
                IconButton(
                  tooltip: 'Copy text',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: recognized));
                  },
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded, size: 16),
                ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: SelectableText(
                recognized.isEmpty ? 'No readable text found' : recognized,
                style: TextStyle(
                  height: 1.35,
                  fontSize: 12,
                  color: recognized.isEmpty ? Colors.white54 : Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageStatusLabel extends StatefulWidget {
  const _MessageStatusLabel({required this.message});

  final ChatMessage message;

  @override
  State<_MessageStatusLabel> createState() => _MessageStatusLabelState();
}

class _MessageStatusLabelState extends State<_MessageStatusLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController clock;

  @override
  void initState() {
    super.initState();
    clock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant _MessageStatusLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  void _syncClock() {
    if (widget.message.pending && !widget.message.failed) {
      if (!clock.isAnimating) {
        clock.repeat(period: const Duration(milliseconds: 1400));
      }
    } else {
      if (clock.isAnimating) clock.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final tooltip = message.failed
        ? 'Failed'
        : message.pending
        ? 'Sending'
        : message.read
        ? 'Read'
        : message.delivered
        ? 'Delivered'
        : 'Sent';
    final child = message.failed
        ? const Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: Colors.redAccent,
          )
        : message.pending
        ? AnimatedBuilder(
            animation: clock,
            builder: (context, _) => CustomPaint(
              size: const Size.square(14),
              painter: _SendingClockPainter(progress: clock.value),
            ),
          )
        : Icon(
            message.read ? Icons.done_all_rounded : Icons.done_rounded,
            size: 14,
            color: message.read ? const Color(0xFF82D8FF) : Colors.white60,
          );
    return TweenAnimationBuilder<double>(
      key: ValueKey(
        '${message.id}-${message.pending}-${message.delivered}-${message.read}-${message.failed}',
      ),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.82 + value * 0.18, child: child),
      ),
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(dimension: 15, child: child),
      ),
    );
  }
}

class _SendingClockPainter extends CustomPainter {
  const _SendingClockPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1;
    final paint = Paint()
      ..color = Colors.white60
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, paint);
    // Both hands finish exactly where they started, so repeat() has no seam.
    final minuteAngle = progress * math.pi * 4 - math.pi / 2;
    final hourAngle = progress * math.pi * 2 - math.pi / 2;
    canvas.drawLine(
      center,
      center + Offset(math.cos(hourAngle), math.sin(hourAngle)) * radius * 0.46,
      paint,
    );
    canvas.drawLine(
      center,
      center +
          Offset(math.cos(minuteAngle), math.sin(minuteAngle)) * radius * 0.72,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SendingClockPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

({String senderName, String text}) _groupMessagePresentation({
  required AppController controller,
  required ChatThread thread,
  required ChatMessage message,
  required bool mine,
}) {
  if (!thread.isGroup || mine) return (senderName: '', text: message.text);
  var senderName = message.senderName.trim();
  senderName = senderName.isNotEmpty
      ? senderName
      : controller.profiles[message.senderNode]?.displayName.trim() ?? '';
  var text = message.text;
  if (senderName.isNotEmpty && text.startsWith('$senderName: ')) {
    text = text.substring(senderName.length + 2);
  }
  return (senderName: senderName, text: text);
}

Color _senderAccent(String senderNode) {
  const palette = <Color>[
    Color(0xFF79CFFF),
    Color(0xFF9EB7FF),
    Color(0xFFB9A1FF),
    Color(0xFF73D9C2),
    Color(0xFFE3A7C6),
    Color(0xFFD6BD82),
  ];
  return palette[senderNode.hashCode.abs() % palette.length];
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
      child: _LinkifiedSelectableText(text: caption),
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
  const _AudioPreview({required this.message, required this.controller});

  final ChatMessage message;
  final AppController controller;

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
  bool transcribing = false;
  String localTranscription = '';
  Duration duration = Duration.zero;
  Duration position = Duration.zero;

  @override
  void initState() {
    super.initState();
    localTranscription = widget.message.transcription;
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
  void didUpdateWidget(covariant _AudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.transcription != widget.message.transcription) {
      localTranscription = widget.message.transcription;
    }
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

  Future<void> transcribe() async {
    if (transcribing) return;
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'ai_voice_transcription',
      title: 'Voice transcription',
      description: 'Turn this voice message into searchable text.',
    );
    if (!allowed || !mounted) return;
    setState(() => transcribing = true);
    try {
      final result = await widget.controller.transcribeVoiceWithAi(
        widget.message,
      );
      if (!mounted) return;
      setState(() => localTranscription = result.text);
    } on AiTranscriptionException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voice transcription failed')),
      );
    } finally {
      if (mounted) setState(() => transcribing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final levels = levelsFor(widget.message);
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
          if (localTranscription.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                localTranscription.trim(),
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: transcribing ? null : transcribe,
                icon: transcribing
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 16),
                label: Text(transcribing ? 'Transcribing...' : 'Transcribe'),
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

class _MessageActionSpec {
  const _MessageActionSpec(
    this.id,
    this.label,
    this.icon, {
    this.subtitle,
    this.destructive = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool destructive;
  final bool enabled;
}

class _MessageContextOverlay extends StatefulWidget {
  const _MessageContextOverlay({
    required this.reactions,
    required this.actions,
    required this.message,
    required this.mine,
    required this.preview,
  });

  final List<String> reactions;
  final List<_MessageActionSpec> actions;
  final ChatMessage message;
  final bool mine;
  final Widget preview;

  @override
  State<_MessageContextOverlay> createState() => _MessageContextOverlayState();
}

class _MessageContextOverlayState extends State<_MessageContextOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation;
  late final Animation<double> fade;
  late final Animation<double> scale;
  late final Animation<Offset> reactionSlide;
  late final Animation<Offset> menuSlide;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 260),
    );
    fade = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    scale = Tween<double>(
      begin: 0.94,
      end: 1,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack));
    reactionSlide = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
    menuSlide = Tween<Offset>(
      begin: const Offset(0, -0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutQuart));
    animation.forward();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  Future<void> closeWith(String value) async {
    if (!mounted) return;
    await animation.reverse();
    if (mounted) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final visibleReactions = widget.reactions.isEmpty
        ? const [
            '\u{1F44D}',
            '\u{1F44C}',
            '\u{1F628}',
            '\u{1F389}',
            '\u{1F622}',
            '\u2764\uFE0F',
            '\u{1F921}',
          ]
        : widget.reactions.take(7).toList(growable: false);
    final size = MediaQuery.sizeOf(context);
    final horizontal = size.width >= 760;
    final contentWidth = math.min(horizontal ? 430.0 : size.width - 28, 430.0);
    final menuHeight = math.min(
      size.height * (horizontal ? 0.54 : 0.42),
      430.0,
    );

    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                await animation.reverse();
                if (context.mounted) Navigator.pop(context);
              },
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: 15 * fade.value,
                  sigmaY: 15 * fade.value,
                ),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.58 * fade.value),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SizedBox(
                  width: contentWidth,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: FadeTransition(
                      opacity: fade,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: widget.mine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          SlideTransition(
                            position: reactionSlide,
                            child: _MessageContextGlass(
                              radius: 30,
                              prominent: true,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 7,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    for (final reaction in visibleReactions)
                                      _ContextReactionButton(
                                        reaction: reaction,
                                        onTap: () =>
                                            closeWith('reaction:$reaction'),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          ScaleTransition(
                            scale: scale,
                            alignment: widget.mine
                                ? Alignment.bottomRight
                                : Alignment.bottomLeft,
                            child: IgnorePointer(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.min(contentWidth, 350),
                                ),
                                child: widget.preview,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SlideTransition(
                            position: menuSlide,
                            child: Align(
                              alignment: widget.mine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: SizedBox(
                                width: math.min(contentWidth, 350),
                                child: _MessageContextGlass(
                                  radius: 28,
                                  prominent: true,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: menuHeight,
                                    ),
                                    child: ListView.separated(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      shrinkWrap: true,
                                      itemCount: widget.actions.length,
                                      separatorBuilder: (context, index) =>
                                          Divider(
                                            height: 1,
                                            indent: 54,
                                            color: Colors.white.withValues(
                                              alpha: 0.075,
                                            ),
                                          ),
                                      itemBuilder: (context, index) {
                                        final action = widget.actions[index];
                                        return _MessageContextActionTile(
                                          action: action,
                                          onTap: action.enabled
                                              ? () => closeWith(action.id)
                                              : null,
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
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
      ),
    );
  }
}

class _MessageContextGlass extends StatelessWidget {
  const _MessageContextGlass({
    required this.child,
    required this.radius,
    this.prominent = false,
  });

  final Widget child;
  final double radius;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return MeshLiquidGlass(
      forceFlutterSurface: true,
      radius: radius,
      accent: const Color(0xFF8EDCFF),
      prominent: prominent,
      interactive: true,
      fallbackBuilder: (context, child) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xEB182331),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.34),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
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

class _ContextReactionButton extends StatelessWidget {
  const _ContextReactionButton({required this.reaction, required this.onTap});

  final String reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      radius: 24,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: _ReactionIcon(reaction: reaction, size: 27),
      ),
    );
  }
}

class _MessageContextActionTile extends StatelessWidget {
  const _MessageContextActionTile({required this.action, this.onTap});

  final _MessageActionSpec action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive
        ? const Color(0xFFFF5D67)
        : onTap == null
        ? Colors.white30
        : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
          child: Row(
            children: [
              Icon(action.icon, color: color, size: 23),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (action.subtitle != null)
                      Text(
                        action.subtitle!,
                        style: const TextStyle(
                          color: Color(0xFFB28AFF),
                          fontSize: 11,
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

class _TranslationCard extends StatelessWidget {
  const _TranslationCard({
    required this.label,
    required this.text,
    this.trailing,
  });

  final String label;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(text),
          ],
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

bool isOcrImageName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp');
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
