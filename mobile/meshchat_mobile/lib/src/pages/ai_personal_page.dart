import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../controllers/app_controller.dart';
import '../services/ai_personal_store.dart';

/// One small library for local presets and editable call notes, not chat chrome.
class AiPersonalPage extends StatefulWidget {
  const AiPersonalPage({
    super.key,
    required this.controller,
    required this.presets,
  });
  final AppController controller;
  final bool presets;
  @override
  State<AiPersonalPage> createState() => _AiPersonalPageState();
}

class _AiPersonalPageState extends State<AiPersonalPage> {
  late final session = widget.controller.session;
  late final store = AiPersonalStore('${session?.serverUrl}|${session?.login}');
  List<Map<String, dynamic>> entries = [];
  String? error;
  bool loading = true;
  String get collection => widget.presets ? 'presets' : 'notes';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await store.read(collection);
      if (mounted && widget.controller.session == session) {
        setState(() => entries = data);
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not read saved data');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> persist(
    List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) change,
  ) async {
    if (widget.controller.session != session) {
      throw StateError('Account changed');
    }
    final next = await store.update(collection, change);
    if (mounted && widget.controller.session == session) {
      setState(() {
        entries = next;
        error = null;
      });
    }
  }

  Future<void> edit([Map<String, dynamic>? entry]) async {
    if (widget.controller.session != session) return;
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PersonalEditor(
        controller: widget.controller,
        presets: widget.presets,
        initial: entry,
      ),
    );
    if (value == null || !mounted) return;
    try {
      await persist(
        (current) => [
          value,
          ...current.where((item) => item['id'] != value['id']),
        ],
      );
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }

  Future<void> delete(Map<String, dynamic> entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry['title']}?'),
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
    if (confirmed != true) return;
    try {
      await persist(
        (current) =>
            current.where((item) => item['id'] != entry['id']).toList(),
      );
    } catch (_) {
      if (mounted) setState(() => error = 'Could not delete entry');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101A23),
    appBar: AppBar(
      title: Text(widget.presets ? 'My writing styles' : 'Call notes'),
      actions: [
        IconButton(
          tooltip: 'Add',
          onPressed: loading ? null : () => edit(),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: loading
            ? const CircularProgressIndicator()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Saved on this device for this account',
                    style: TextStyle(color: Colors.white70),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        widget.presets
                            ? 'No saved styles'
                            : 'No saved call notes',
                      ),
                    ),
                  for (final entry in entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry['title']?.toString() ?? ''),
                      subtitle: Text(
                        entry['text']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        if (widget.presets) {
                          if (widget.controller.session == session) {
                            Navigator.pop(context, entry);
                          }
                        } else {
                          edit(entry);
                        }
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) =>
                            action == 'edit' ? edit(entry) : delete(entry),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}

class _PersonalEditor extends StatefulWidget {
  const _PersonalEditor({
    required this.controller,
    required this.presets,
    this.initial,
  });
  final AppController controller;
  final bool presets;
  final Map<String, dynamic>? initial;
  @override
  State<_PersonalEditor> createState() => _PersonalEditorState();
}

class _PersonalEditorState extends State<_PersonalEditor> {
  late final session = widget.controller.session;
  late final title = TextEditingController(
    text: widget.initial?['title']?.toString() ?? '',
  );
  late final text = TextEditingController(
    text: widget.initial?['text']?.toString() ?? '',
  );
  late final examples = TextEditingController(
    text: widget.initial?['examples']?.toString() ?? '',
  );
  bool busy = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    text.dispose();
    examples.dispose();
    super.dispose();
  }

  Future<void> summarize() async {
    if (busy || text.text.trim().isEmpty) return;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send these notes to Mesh AI?'),
        content: const Text(
          'Only the text currently in this editor will be sent to the server and its external AI provider. No call audio is attached.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send notes'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted || widget.controller.session != session) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.controller.runContextAiTool({
        'mode': 'notes',
        'sources': [
          {'id': 'notes', 'text': text.text},
        ],
      });
      if (mounted && widget.controller.session == session) {
        text.text = result.answer;
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception is AiSummaryException
              ? exception.message
              : 'Could not summarize notes',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> favorite() async {
    if (text.text.trim().isEmpty || widget.controller.session != session) {
      return;
    }
    await widget.controller.sendMessage(
      widget.controller.savedMessagesProfile,
      '${title.text}\n\n${text.text}',
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Added to Saved Messages')));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.presets ? 'Writing style' : 'Call notes'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              enabled: !busy,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: text,
              enabled: !busy,
              minLines: 4,
              maxLines: 10,
              maxLength: widget.presets ? 1600 : 12000,
              decoration: InputDecoration(
                labelText: widget.presets
                    ? 'Style preferences'
                    : 'Decisions, open questions and next steps',
              ),
            ),
            if (widget.presets)
              TextField(
                controller: examples,
                enabled: !busy,
                minLines: 2,
                maxLines: 5,
                maxLength: 2400,
                decoration: const InputDecoration(
                  labelText: 'Examples of your writing (optional)',
                ),
              ),
            if (!widget.presets)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy ? null : summarize,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(busy ? 'Processing...' : 'Organize with AI'),
                ),
              ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
      ),
    ),
    actions: [
      if (!widget.presets)
        IconButton(
          tooltip: 'Add to Saved Messages',
          onPressed: busy ? null : favorite,
          icon: const Icon(Icons.bookmark_add_outlined),
        ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () {
                if (widget.controller.session != session) {
                  setState(() => error = 'Account changed');
                  return;
                }
                if (title.text.trim().isEmpty || text.text.trim().isEmpty) {
                  setState(() => error = 'Enter a title and text');
                  return;
                }
                Navigator.pop(context, {
                  'id': widget.initial?['id'] ?? const Uuid().v4(),
                  'title': title.text.trim(),
                  'text': text.text.trim(),
                  'examples': examples.text.trim(),
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                });
              },
        child: const Text('Save'),
      ),
    ],
  );
}
