import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'mesh_workspace.dart';
import '../services/message_search.dart';

class MeshMessageSearch extends StatefulWidget {
  const MeshMessageSearch({
    super.key,
    required this.search,
    required this.onSelect,
    this.messages = const [],
    this.onClose,
    this.onMeaning,
    this.senderLabels = const {},
  });
  final List<ChatMessage> Function(String) search;
  final ValueChanged<ChatMessage> onSelect;
  final List<ChatMessage> messages;
  final VoidCallback? onClose;
  final ValueChanged<String>? onMeaning;
  final Map<String, String> senderLabels;
  @override
  State<MeshMessageSearch> createState() => _MeshMessageSearchState();
}

class _MeshMessageSearchState extends State<MeshMessageSearch> {
  Timer? debounce;
  List<ChatMessage> results = [];
  String? selected;
  String query = '';
  String? sender;
  DateTime? day;
  MessageSearchKind kind = MessageSearchKind.all;

  void refresh() {
    final filter = MessageSearchFilter(
      query: query,
      sender: sender,
      day: day,
      kind: kind,
    );
    setState(
      () => results =
          (widget.messages.isEmpty ? widget.search(query) : widget.messages)
              .where(filter.matches)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MeshSurface.panel,
    appBar: AppBar(
      title: const Text('Search'),
      leading: IconButton(
        tooltip: 'Close search',
        icon: const Icon(Icons.close),
        onPressed: widget.onClose ?? () => Navigator.pop(context),
      ),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search messages',
            ),
            onChanged: (query) {
              this.query = query;
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 180), () {
                if (mounted) {
                  refresh();
                }
              });
            },
          ),
        ),
        if (widget.onMeaning != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.manage_search),
              label: const Text('By meaning'),
              onPressed: () => widget.onMeaning!(query),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              PopupMenuButton<String>(
                tooltip: 'Sender',
                onSelected: (value) {
                  sender = value.isEmpty ? null : value;
                  refresh();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: '', child: Text('All senders')),
                  for (final id
                      in widget.messages.map((m) => m.senderNode).toSet())
                    PopupMenuItem(
                      value: id,
                      child: Text(
                        widget.senderLabels[id] ??
                            (widget.messages
                                    .firstWhere((m) => m.senderNode == id)
                                    .senderName
                                    .isEmpty
                                ? id
                                : widget.messages
                                      .firstWhere((m) => m.senderNode == id)
                                      .senderName),
                      ),
                    ),
                ],
                child: Chip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text(
                    sender == null ? 'All senders' : 'Sender selected',
                  ),
                ),
              ),
              PopupMenuButton<MessageSearchKind>(
                tooltip: 'Message type',
                onSelected: (value) {
                  kind = value;
                  refresh();
                },
                itemBuilder: (_) => [
                  for (final value in MessageSearchKind.values)
                    PopupMenuItem(value: value, child: Text(value.name)),
                ],
                child: Chip(
                  avatar: const Icon(Icons.filter_list, size: 18),
                  label: Text(kind.name),
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  day == null
                      ? 'Date'
                      : MaterialLocalizations.of(
                          context,
                        ).formatCompactDate(day!),
                ),
                onPressed: () async {
                  final value = await showDatePicker(
                    context: context,
                    initialDate: day ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (!mounted || value == null) return;
                  day = value;
                  refresh();
                },
              ),
              if (day != null ||
                  sender != null ||
                  kind != MessageSearchKind.all)
                IconButton(
                  tooltip: 'Reset filters',
                  icon: const Icon(Icons.filter_alt_off),
                  onPressed: () {
                    day = null;
                    sender = null;
                    kind = MessageSearchKind.all;
                    refresh();
                  },
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, index) {
              final message = results[index];
              return ListTile(
                selected: selected == message.id,
                selectedTileColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                title: Text(
                  message.text.isEmpty ? message.fileName : message.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  MaterialLocalizations.of(
                    context,
                  ).formatCompactDate(message.createdAt),
                ),
                onTap: () {
                  setState(() => selected = message.id);
                  widget.onSelect(message);
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
