import 'dart:ui';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import 'chat_page.dart';

enum _SearchFilter { all, chats, messages, files, links }

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final input = TextEditingController();
  _SearchFilter filter = _SearchFilter.all;
  List<GlobalSearchResult> rawResults = const [];
  bool openingHiddenChat = false;
  String? hiddenChatError;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void search(String value) {
    final hiddenRequest = _parseHiddenChatQuery(value);
    setState(() {
      hiddenChatError = null;
      rawResults = hiddenRequest == null
          ? widget.controller.searchAllChats(value)
          : const [];
    });
  }

  void openThread(ChatThread thread) {
    widget.controller.markRead(thread);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(controller: widget.controller, thread: thread),
      ),
    );
  }

  Future<void> submitSearch(String value) async {
    final hiddenRequest = _parseHiddenChatQuery(value);
    if (hiddenRequest == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      openingHiddenChat = true;
      hiddenChatError = null;
    });
    final profile = await widget.controller.lookupUsername(
      hiddenRequest.username,
      sendRequest: false,
    );
    if (!mounted) return;
    if (profile == null) {
      setState(() {
        openingHiddenChat = false;
        hiddenChatError = 'Nothing found';
      });
      return;
    }
    final thread = await widget.controller.ensureSecretThread(
      profile,
      hiddenRequest.code,
    );
    if (!mounted) return;
    setState(() => openingHiddenChat = false);
    openThread(thread);
  }

  ({String username, String code})? _parseHiddenChatQuery(String value) {
    final query = value.trim();
    final separator = query.indexOf('#');
    if (separator <= 0 || separator == query.length - 1) return null;
    final username = query.substring(0, separator).trim();
    final code = query.substring(separator + 1).trim();
    final normalizedUsername = username.startsWith('@')
        ? username.substring(1)
        : username;
    if (normalizedUsername.length < 2 || code.length < 2) return null;
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(normalizedUsername)) {
      return null;
    }
    return (username: normalizedUsername, code: code);
  }

  @override
  Widget build(BuildContext context) {
    final results = rawResults.where(_matchesFilter).toList(growable: false);
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Row(
                children: [
                  _RoundGlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _GlassSurface(
                radius: 22,
                child: TextField(
                  controller: input,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Messages, chats, files, links',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                  onChanged: search,
                  onSubmitted: submitSearch,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  _FilterChipButton(
                    label: 'All',
                    icon: Icons.auto_awesome_rounded,
                    selected: filter == _SearchFilter.all,
                    onTap: () => setState(() => filter = _SearchFilter.all),
                  ),
                  _FilterChipButton(
                    label: 'Chats',
                    icon: Icons.chat_bubble_outline_rounded,
                    selected: filter == _SearchFilter.chats,
                    onTap: () => setState(() => filter = _SearchFilter.chats),
                  ),
                  _FilterChipButton(
                    label: 'Messages',
                    icon: Icons.notes_rounded,
                    selected: filter == _SearchFilter.messages,
                    onTap: () =>
                        setState(() => filter = _SearchFilter.messages),
                  ),
                  _FilterChipButton(
                    label: 'Files',
                    icon: Icons.attach_file_rounded,
                    selected: filter == _SearchFilter.files,
                    onTap: () => setState(() => filter = _SearchFilter.files),
                  ),
                  _FilterChipButton(
                    label: 'Links',
                    icon: Icons.link_rounded,
                    selected: filter == _SearchFilter.links,
                    onTap: () => setState(() => filter = _SearchFilter.links),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: input.text.trim().isEmpty
                  ? const Center(
                      child: Text(
                        'Type to search across MeshChat',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : openingHiddenChat
                  ? const Center(child: CircularProgressIndicator())
                  : hiddenChatError != null
                  ? Center(
                      child: Text(
                        hiddenChatError!,
                        style: const TextStyle(color: Colors.white38),
                      ),
                    )
                  : results.isEmpty
                  ? const Center(
                      child: Text(
                        'Nothing found',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                      itemCount: results.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final message = result.message;
                        return _GlassSurface(
                          radius: 18,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.lightBlueAccent
                                  .withValues(alpha: 0.16),
                              child: Icon(
                                _resultIcon(result),
                                color: Colors.lightBlueAccent,
                              ),
                            ),
                            title: Text(
                              result.thread.profile.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              message == null
                                  ? 'Chat'
                                  : _messagePreview(message),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60),
                            ),
                            trailing: message == null
                                ? null
                                : Text(
                                    _time(message.createdAt),
                                    style: const TextStyle(
                                      color: Colors.white38,
                                    ),
                                  ),
                            onTap: () => openThread(result.thread),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _matchesFilter(GlobalSearchResult result) {
    final message = result.message;
    return switch (filter) {
      _SearchFilter.all => true,
      _SearchFilter.chats => message == null,
      _SearchFilter.messages =>
        message != null && message.kind == ChatMessageKind.text,
      _SearchFilter.files =>
        message != null &&
            (message.kind == ChatMessageKind.file ||
                message.kind == ChatMessageKind.sticker),
      _SearchFilter.links => message != null && _hasLink(message.text),
    };
  }

  IconData _resultIcon(GlobalSearchResult result) {
    final message = result.message;
    if (message == null) {
      return result.thread.isGroup
          ? Icons.group_outlined
          : Icons.person_outline;
    }
    if (_hasLink(message.text)) return Icons.link_rounded;
    if (message.kind == ChatMessageKind.sticker) {
      return Icons.auto_awesome_motion_rounded;
    }
    if (message.kind == ChatMessageKind.file) return Icons.attach_file_rounded;
    return Icons.notes_rounded;
  }

  String _messagePreview(ChatMessage message) {
    if (message.kind == ChatMessageKind.sticker) {
      return 'Sticker';
    }
    if (message.kind == ChatMessageKind.file) {
      return message.fileName.isEmpty ? 'File' : 'File: ${message.fileName}';
    }
    return message.text.trim().isEmpty ? 'Message' : message.text;
  }

  String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
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
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? Colors.lightBlueAccent.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? Colors.lightBlueAccent.withValues(alpha: 0.32)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.lightBlueAccent : Colors.white54,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
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

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: Colors.white70, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child, required this.radius});

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
          ),
          child: child,
        ),
      ),
    );
  }
}

bool _hasLink(String text) {
  return RegExp(r'https?://|www\.|t\.me/', caseSensitive: false).hasMatch(text);
}
