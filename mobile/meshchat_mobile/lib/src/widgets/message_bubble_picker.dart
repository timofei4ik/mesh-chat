import 'package:flutter/material.dart';

import '../models/message_bubble_style.dart';
import '../models/profile.dart';
import 'collection_message_surface.dart';
import 'mesh_sheet_surface.dart';

class MessageBubblePicker extends StatefulWidget {
  const MessageBubblePicker({
    super.key,
    required this.profile,
    required this.onSave,
    this.animatedBackground = true,
  });
  final Profile profile;
  final Future<String?> Function(String, bool) onSave;
  final bool animatedBackground;

  @override
  State<MessageBubblePicker> createState() => _MessageBubblePickerState();
}

class _MessageBubblePickerState extends State<MessageBubblePicker> {
  late String selected = widget.profile.effectiveMessageBubbleStyle;
  late bool animatedBackground = widget.animatedBackground;
  bool saving = false;
  String? error;

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    String? result;
    try {
      result = await widget.onSave(selected, animatedBackground);
    } catch (_) {
      result = 'Could not save bubble style. Try again.';
    }
    if (!mounted) return;
    if (result == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        saving = false;
        error = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: MeshSheetSurface(
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Message bubbles',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Your messages in all chats',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: messageBubbleStyles.length,
                    itemBuilder: (context, index) {
                      final entry = messageBubbleStyles.entries.elementAt(
                        index,
                      );
                      final skin = collectionBubbleSkin(
                        widget.profile.copyWith(messageBubbleStyle: entry.key),
                      );
                      final active = selected == entry.key;
                      return Semantics(
                        selected: active,
                        child: InkWell(
                          onTap: saving
                              ? null
                              : () => setState(() {
                                  selected = entry.key;
                                  error = null;
                                }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(child: Text(entry.value)),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 116,
                                  height: 48,
                                  child: skin == null
                                      ? Container(
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF287CC0),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: const Text(
                                            'Hello',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        )
                                      : CollectionMessageSurface(
                                          skin: skin,
                                          mine: true,
                                          decoration: const BoxDecoration(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          constraints:
                                              const BoxConstraints.expand(),
                                          child: const Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text('Hello'),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 10),
                                Icon(
                                  active
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: active
                                      ? const Color(0xFF43D9FF)
                                      : Colors.white38,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Animated background'),
                  value: animatedBackground,
                  onChanged: saving
                      ? null
                      : (value) => setState(() => animatedBackground = value),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: saving ? null : save,
                  icon: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(saving ? 'Saving...' : 'Apply'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
