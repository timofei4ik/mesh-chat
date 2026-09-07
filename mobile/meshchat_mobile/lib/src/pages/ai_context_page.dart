import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../controllers/app_controller.dart';
import '../models/ai_context.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';

class AiContextPage extends StatefulWidget {
  const AiContextPage({
    super.key,
    required this.controller,
    required this.thread,
    required this.mode,
    required this.messages,
    this.question = '',
    this.targetId,
    required this.onSource,
    required this.onDraft,
    required this.onReminder,
  });
  final AppController controller;
  final ChatThread thread;
  final String mode;
  final List<ChatMessage> messages;
  final String question;
  final String? targetId;
  final void Function(String) onSource;
  final void Function(String) onDraft;
  final Future<void> Function(String) onReminder;
  @override
  State<AiContextPage> createState() => _AiContextPageState();
}

class _AiContextPageState extends State<AiContextPage> {
  late final session = widget.controller.session;
  late final question = TextEditingController(text: widget.question);
  late final allCandidates = widget.messages.where((m) => !m.deleted).toList();
  late int offset = widget.mode == 'search'
      ? math.max(0, allCandidates.length - 80)
      : 0;
  List<ChatMessage> get candidates => widget.mode == 'search'
      ? allCandidates.sublist(
          offset,
          math.min(offset + 80, allCandidates.length),
        )
      : allCandidates;
  late final selected = candidates.map((m) => m.id).toSet();
  bool busy = false;
  String? error;
  AiContextResult? result;

  @override
  void initState() {
    super.initState();
    // Capture the account before the user can switch it while this page is open.
    session;
  }

  void moveWindow(int delta) {
    if (busy) return;
    setState(() {
      offset = (offset + delta).clamp(
        0,
        math.max(0, allCandidates.length - 80),
      );
      selected
        ..clear()
        ..addAll(candidates.map((m) => m.id));
      result = null;
    });
  }

  String get title => switch (widget.mode) {
    'search' => 'Search by meaning',
    'plan' => 'Conversation plan',
    'reply' => 'Reply suggestions',
    _ => 'Ask attachment',
  };
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> run() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      if (widget.controller.session != session) {
        throw StateError('Account changed');
      }
      final messages = candidates
          .where((m) => selected.contains(m.id))
          .toList();
      if (messages.isEmpty) throw StateError('Select at least one source');
      for (final message in messages) {
        final current = widget.controller.messageInThread(
          widget.thread,
          message.id,
        );
        if (current == null ||
            current.deleted ||
            aiMessageText(current) != aiMessageText(message)) {
          throw StateError(
            'Messages changed. Reopen this action to review the updated context.',
          );
        }
      }
      var hex = '';
      if (widget.mode == 'document') {
        final message = messages.single;
        if (message.fileSize > 3 * 1024 * 1024) {
          throw StateError('Maximum attachment size is 3 MB');
        }
        if (!await widget.controller.ensureMediaAvailable(
          widget.thread,
          message,
        )) {
          throw StateError('Download the attachment first');
        }
        hex =
            widget.controller
                .messageInThread(widget.thread, message.id)
                ?.fileData ??
            '';
        if (hex.isEmpty || hex.length > 6 * 1024 * 1024) {
          throw StateError('Attachment is unavailable or larger than 3 MB');
        }
      }
      if (widget.controller.session != session) {
        throw StateError('Account changed');
      }
      final sources = widget.mode == 'document'
          ? <Map<String, dynamic>>[]
          : aiMessageSources(messages, targetId: widget.targetId);
      if (sources.length > 120 ||
          sources.fold<int>(0, (n, s) => n + (s['text'] as String).length) >
              30000) {
        throw StateError(
          'Select fewer messages (maximum 120 messages / 30,000 characters)',
        );
      }
      final response = await widget.controller.runContextAiTool({
        'mode': widget.mode,
        'question': question.text.trim(),
        'sources': sources,
      }, attachmentHex: hex);
      if (!mounted || widget.controller.session != session) return;
      setState(() => result = response);
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception is AiSummaryException
              ? exception.message
              : exception.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void openSource(String id) {
    if (widget.controller.session != session) return;
    final source = result?.sources.where((s) => s['id'] == id).firstOrNull;
    if (source == null) return;
    if (id.startsWith('page:')) {
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Page ${id.substring(5)}'),
          content: SingleChildScrollView(
            child: SelectableText(source['text']?.toString() ?? ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else if (selected.contains(id)) {
      Navigator.pop(context);
      widget.onSource(id);
    }
  }

  Widget sourceLinks(List<String> ids) => Wrap(
    spacing: 8,
    children: [
      for (final id in ids)
        TextButton.icon(
          onPressed: () => openSource(id),
          icon: const Icon(Icons.link_rounded, size: 16),
          label: Text(
            id.startsWith('page:')
                ? 'Page ${id.substring(5)}'
                : 'Message ${candidates.indexWhere((m) => m.id == id) + 1}',
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101A23),
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.mode == 'search' || widget.mode == 'document')
              TextField(
                controller: question,
                enabled: !busy,
                minLines: 1,
                maxLines: 3,
                maxLength: 800,
                decoration: const InputDecoration(labelText: 'Question'),
              ),
            if (widget.mode == 'search' && allCandidates.length > 80)
              Row(
                children: [
                  IconButton(
                    tooltip: 'Older messages',
                    onPressed: busy || offset == 0
                        ? null
                        : () => moveWindow(-80),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      '${offset + 1}-${offset + candidates.length} / ${allCandidates.length} loaded messages',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Newer messages',
                    onPressed:
                        busy ||
                            offset + candidates.length >= allCandidates.length
                        ? null
                        : () => moveWindow(80),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ExpansionTile(
              initiallyExpanded: true,
              title: Text(
                'Context: ${selected.length} of ${candidates.length} messages',
              ),
              children: [
                SizedBox(
                  height: 210,
                  child: ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (_, index) {
                      final message = candidates[index];
                      return CheckboxListTile(
                        value: selected.contains(message.id),
                        onChanged:
                            busy ||
                                widget.mode == 'document' ||
                                message.id == widget.targetId
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(message.id);
                                } else {
                                  selected.remove(message.id);
                                }
                                result = null;
                              }),
                        title: Text(
                          aiMessageText(message),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${message.senderName}  ${message.createdAt.toLocal()}',
                        ),
                        secondary: IconButton(
                          tooltip: 'View source',
                          icon: const Icon(Icons.open_in_new_rounded),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              content: SingleChildScrollView(
                                child: SelectableText(aiMessageText(message)),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.mode == 'document'
                  ? 'The selected file and question will be sent to Mesh AI and its external AI provider. PDF: first 12 pages, up to 2,000 characters per page. PNG/JPEG: visible text. Maximum 3 MB.'
                  : 'Only the checked messages and your question will be sent to Mesh AI and its external AI provider. Other chat history is not included.',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : run,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded),
              label: Text(busy ? 'Processing...' : 'Send selected context'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            if (result != null) ...[
              const Divider(height: 32),
              SelectableText(result!.answer),
              sourceLinks(result!.sourceIds),
              for (final item in result!.items) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item['text']?.toString() ?? ''),
                  subtitle: item['due'] == null
                      ? null
                      : Text('Suggested date: ${item['due']}'),
                  trailing: IconButton(
                    tooltip: 'Review reminder',
                    icon: const Icon(Icons.alarm_add_rounded),
                    onPressed: () {
                      if (widget.controller.session != session) return;
                      widget.onReminder(item['text']?.toString() ?? '');
                    },
                  ),
                ),
                sourceLinks(
                  (item['source_ids'] as List? ?? [])
                      .whereType<String>()
                      .toList(),
                ),
              ],
              for (final reply in result!.replies)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(reply),
                  trailing: const Icon(Icons.edit_note_rounded),
                  onTap: () {
                    if (widget.controller.session != session) return;
                    Navigator.pop(context);
                    widget.onDraft(reply);
                  },
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
