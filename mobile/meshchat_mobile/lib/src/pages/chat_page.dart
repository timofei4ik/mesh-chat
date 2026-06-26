import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';
import 'group_info_page.dart';
import 'profile_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.controller, required this.thread});

  final AppController controller;
  final ChatThread thread;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final scroll = ScrollController();
  final recorder = AudioRecorder();
  final recordLevels = List<double>.filled(22, 0.25);
  StreamSubscription<Amplitude>? amplitudeSubscription;
  bool recording = false;
  DateTime? recordStartedAt;
  ChatMessage? replyTo;
  DateTime? lastTypingSentAt;

  @override
  void initState() {
    super.initState();
    input.text = widget.thread.draft;
    input.addListener(() {
      widget.controller.updateDraft(widget.thread, input.text);
      final now = DateTime.now();
      if (input.text.trim().isNotEmpty &&
          (lastTypingSentAt == null ||
              now.difference(lastTypingSentAt!).inSeconds >= 3)) {
        lastTypingSentAt = now;
        widget.controller.sendTyping(widget.thread);
      }
    });
    widget.controller.markRead(widget.thread);
    widget.controller.setActiveThread(widget.thread);
  }

  @override
  void dispose() {
    amplitudeSubscription?.cancel();
    widget.controller.setActiveThread(null);
    inputFocus.dispose();
    input.dispose();
    scroll.dispose();
    recorder.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final text = input.text;
    if (text.trim().isEmpty) return;
    input.clear();
    widget.controller.updateDraft(widget.thread, '');
    final quote = replyTo;
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
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
  }

  Future<void> attachFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final caption = await askFileCaption(file.name);
    if (caption == null) return;
    final quote = replyTo;
    setState(() => replyTo = null);
    final error = widget.thread.isGroup
        ? await widget.controller.sendGroupFile(
            widget.thread,
            file.name,
            bytes,
            caption: caption,
            replyTo: quote,
          )
        : await widget.controller.sendFile(
            widget.thread.profile,
            file.name,
            bytes,
            caption: caption,
            replyTo: quote,
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
      for (var i = 0; i < recordLevels.length; i++) {
        recordLevels[i] = 0.25;
      }
    });
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
    });
    if (path == null || duration.inMilliseconds < 500) return;
    final bytes = await XFile(path).readAsBytes();
    final filename =
        'voice_${DateTime.now().millisecondsSinceEpoch}_${duration.inSeconds}s.m4a';
    final error = widget.thread.isGroup
        ? await widget.controller.sendGroupFile(widget.thread, filename, bytes)
        : await widget.controller.sendFile(
            widget.thread.profile,
            filename,
            bytes,
          );
    if (!mounted || error == null) return;
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
    });
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
        builder: (_) => ProfilePage(profile: widget.thread.profile),
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

  Future<void> showMessageActions(ChatMessage message) async {
    final mine = message.senderNode == widget.controller.myNodeId;
    final pinned = widget.thread.pinnedMessageIds.contains(message.id);
    final canDownload =
        message.kind == ChatMessageKind.file && message.fileData.isNotEmpty;
    final canBlock =
        !mine && !widget.thread.isGroup && message.senderNode.isNotEmpty;
    final blocked = widget.controller.isBlocked(message.senderNode);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final reaction in const [
                    '\u2764\uFE0F',
                    '\u{1F44C}',
                    '\u{1FACE}',
                    '\u{1F44D}',
                  ])
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => Navigator.pop(context, reaction),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: _ReactionIcon(reaction: reaction, size: 28),
                      ),
                    ),
                ],
              ),
            ),
            if (mine && message.failed)
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Retry'),
                onTap: () => Navigator.pop(context, 'retry'),
              ),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.forward_rounded),
              title: const Text('Forward'),
              onTap: () => Navigator.pop(context, 'forward'),
            ),
            if (canDownload)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Download'),
                onTap: () => Navigator.pop(context, 'download'),
              ),
            if (mine && message.kind == ChatMessageKind.text)
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete'),
                textColor: Colors.redAccent,
                iconColor: Colors.redAccent,
                onTap: () => Navigator.pop(context, 'delete'),
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
      setState(() => replyTo = message);
      return;
    }
    if (action == 'forward') {
      await showForwardDialog(message);
      return;
    }
    if (action == 'download') {
      await downloadMessageFile(message);
      return;
    }
    if (action == 'edit') {
      await showEditDialog(message);
      return;
    }
    if (action == 'delete') {
      await widget.controller.deleteMessage(widget.thread, message);
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
    if (message.kind != ChatMessageKind.file || message.fileData.isEmpty) {
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
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: editInput,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
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
    if (!mounted || edited == null || edited.trim().isEmpty) return;
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

  void jumpToMessage(ChatMessage message) {
    final index = widget.thread.messages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (index < 0 || !scroll.hasClients) return;
    final offset = (index * 92.0).clamp(0.0, scroll.position.maxScrollExtent);
    scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void openMediaList() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _ChatFilesPage(thread: widget.thread)),
    );
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
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final profile = widget.thread.profile;
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.thread.isGroup ? openGroupInfo : openProfile,
              child: Row(
                children: [
                  ProfileAvatar(profile: profile, radius: 19),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.thread.isGroup
                              ? '${widget.thread.members.length} members'
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
          IconButton.filledTonal(
            tooltip: widget.thread.isGroup ? 'Group call' : 'Call',
            icon: Icon(
              widget.thread.isGroup ? Icons.add_call : Icons.call_outlined,
            ),
            onPressed: startCall,
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: showSearchDialog,
          ),
          IconButton(
            tooltip: 'Media',
            icon: const Icon(Icons.perm_media_outlined),
            onPressed: openMediaList,
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PinnedBar(thread: widget.thread, onTap: openPinnedMessages),
                _CallBanner(controller: widget.controller),
                if (widget.controller.isTyping(widget.thread))
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    color: const Color(0xFF20242B),
                    child: const Text(
                      'typing...',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => scrollToBottom(),
                );
                final messages = widget.thread.messages;
                return ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return _MessageBubble(
                      message: message,
                      mine: message.senderNode == widget.controller.myNodeId,
                      onLongPress: () => showMessageActions(message),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              color: const Color(0xFF20242B),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (replyTo != null) ...[
                    _ReplyComposer(
                      message: replyTo!,
                      onCancel: () => setState(() => replyTo = null),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: recording
                            ? Row(
                                children: [
                                  const Icon(
                                    Icons.mic_rounded,
                                    color: Colors.redAccent,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _Waveform(levels: recordLevels),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    recordDuration(),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              )
                            : Focus(
                                focusNode: inputFocus,
                                onKeyEvent: handleInputKey,
                                child: TextField(
                                  controller: input,
                                  minLines: 1,
                                  maxLines: 5,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: desktopSendHotkeys
                                      ? TextInputAction.send
                                      : TextInputAction.newline,
                                  decoration: const InputDecoration(
                                    hintText: 'Message',
                                    isDense: true,
                                  ),
                                  onSubmitted: desktopSendHotkeys
                                      ? (_) => send()
                                      : null,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: recording ? 'Send voice' : 'Voice',
                        onPressed: toggleVoiceRecording,
                        icon: Icon(
                          recording
                              ? Icons.stop_circle_outlined
                              : Icons.mic_none_rounded,
                        ),
                      ),
                      if (!recording) ...[
                        IconButton(
                          tooltip: 'File',
                          onPressed: attachFile,
                          icon: const Icon(Icons.attach_file_rounded),
                        ),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: send,
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ] else
                        IconButton(
                          tooltip: 'Cancel',
                          onPressed: cancelRecording,
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      color: const Color(0xFF20242B),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                if (participants.isNotEmpty) ...[
                  const SizedBox(height: 6),
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
          ...actions,
        ],
      ),
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
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      color: const Color(0xFF20242B),
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
            icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
          ),
        ],
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

class _ChatFilesPage extends StatelessWidget {
  const _ChatFilesPage({required this.thread});

  final ChatThread thread;

  @override
  Widget build(BuildContext context) {
    final files =
        thread.messages
            .where((message) => message.kind == ChatMessageKind.file)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
      appBar: AppBar(title: const Text('Media & files')),
      body: files.isEmpty
          ? const Center(child: Text('No files yet'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: files.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final message = files[index];
                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20242B),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FilePreview(
                        message: message,
                        imageBytes: _MessageBubble.imageBytesFor(message),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        messageTime(message.createdAt),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.onLongPress,
  });

  final ChatMessage message;
  final bool mine;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final time = message.createdAt.toLocal();
    final imageBytes = imageBytesFor(message);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: imageBytes == null
            ? null
            : () => _showImage(context, imageBytes),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          margin: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(
                  11,
                  message.kind == ChatMessageKind.file && imageBytes != null
                      ? 6
                      : 8,
                  9,
                  6,
                ),
                decoration: BoxDecoration(
                  color: mine
                      ? const Color(0xFF2F7D4A)
                      : const Color(0xFF2A2E35),
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
                    message.kind == ChatMessageKind.file
                        ? _FilePreview(message: message, imageBytes: imageBytes)
                        : Text(message.text),
                    if (message.kind == ChatMessageKind.file &&
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
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                          if (mine) ...[
                            const SizedBox(width: 5),
                            Icon(
                              message.failed
                                  ? Icons.error_outline_rounded
                                  : message.pending
                                  ? Icons.schedule_rounded
                                  : message.delivered
                                  ? Icons.done_all_rounded
                                  : Icons.done_rounded,
                              size: 13,
                              color: message.failed
                                  ? Colors.redAccent
                                  : Colors.white60,
                            ),
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
            ],
          ),
        ),
      ),
    );
  }

  static Uint8List? imageBytesFor(ChatMessage message) {
    if (message.kind != ChatMessageKind.file ||
        !isImageName(message.fileName)) {
      return null;
    }
    try {
      return hexDecode(message.fileData);
    } catch (_) {
      return null;
    }
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
    return Row(
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

String formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String replyPreview(ChatMessage message) {
  if (message.kind == ChatMessageKind.file) {
    return message.fileName.isEmpty ? 'File' : message.fileName;
  }
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
