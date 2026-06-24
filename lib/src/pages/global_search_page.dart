import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import 'chat_page.dart';

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final input = TextEditingController();
  List<GlobalSearchResult> results = const [];

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void search(String value) {
    setState(() {
      results = widget.controller.searchAllChats(value);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: input,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search chats and messages',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: search,
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text(
                      'Type to search across all chats',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = results[index];
                      final message = result.message;
                      return ListTile(
                        leading: Icon(
                          result.thread.isGroup
                              ? Icons.group_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(result.thread.profile.displayName),
                        subtitle: Text(
                          message == null ? 'Chat' : _messagePreview(message),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: message == null
                            ? null
                            : Text(_time(message.createdAt)),
                        onTap: () => openThread(result.thread),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _messagePreview(ChatMessage message) {
    if (message.kind == ChatMessageKind.file) {
      return message.fileName.isEmpty ? 'File' : 'File: ${message.fileName}';
    }
    return message.text;
  }

  String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
