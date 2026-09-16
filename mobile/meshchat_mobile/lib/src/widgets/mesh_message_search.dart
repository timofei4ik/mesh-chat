import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'mesh_workspace.dart';

class MeshMessageSearch extends StatefulWidget {
  const MeshMessageSearch({
    super.key,
    required this.search,
    required this.onSelect,
  });
  final List<ChatMessage> Function(String) search;
  final ValueChanged<ChatMessage> onSelect;
  @override
  State<MeshMessageSearch> createState() => _MeshMessageSearchState();
}

class _MeshMessageSearchState extends State<MeshMessageSearch> {
  Timer? debounce;
  List<ChatMessage> results = [];
  String? selected;
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
        onPressed: () => Navigator.pop(context),
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
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 180), () {
                if (mounted) {
                  setState(
                    () => results = query.trim().isEmpty
                        ? []
                        : widget.search(query),
                  );
                }
              });
            },
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
