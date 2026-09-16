import 'package:flutter/material.dart';

import '../models/message_bubble_style.dart';
import '../models/profile.dart';
import 'collection_message_surface.dart';
import 'mesh_sheet_surface.dart';
import 'mesh_workspace.dart';

class MessageBubblePicker extends StatefulWidget {
  const MessageBubblePicker({
    super.key,
    required this.profile,
    required this.onSave,
    this.animatedBackground = true,
    this.themeId = 'default',
    this.onSaveAppearance,
  });
  final Profile profile;
  final Future<String?> Function(String, bool) onSave;
  final bool animatedBackground;
  final String themeId;
  final Future<String?> Function(String, bool, String)? onSaveAppearance;

  @override
  State<MessageBubblePicker> createState() => _MessageBubblePickerState();
}

class _MessageBubblePickerState extends State<MessageBubblePicker> {
  late String selected = widget.profile.effectiveMessageBubbleStyle;
  late bool animatedBackground = widget.animatedBackground;
  late String themeId = widget.themeId == 'default'
      ? 'midnight'
      : widget.themeId;
  bool saving = false;
  String? error;

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    String? result;
    try {
      result = !MeshDesktop.isDesktop || widget.onSaveAppearance == null
          ? await widget.onSave(selected, animatedBackground)
          : await widget.onSaveAppearance!(
              selected,
              animatedBackground,
              themeId,
            );
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
          height:
              MediaQuery.sizeOf(context).height *
              (MeshDesktop.isDesktop ? 0.90 : 0.78),
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
                MessageAppearancePreview(
                  profile: widget.profile,
                  style: selected,
                  themeId: MeshDesktop.isDesktop ? themeId : widget.themeId,
                  animated: animatedBackground,
                ),
                const SizedBox(height: 12),
                Expanded(
                  flex: 0,
                  child:
                      !MeshDesktop.isDesktop || widget.onSaveAppearance == null
                      ? const SizedBox.shrink()
                      : Row(
                          children: [
                            for (final theme in [
                              'midnight',
                              'cyan',
                              'violet',
                              'emerald',
                            ])
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 8,
                                  bottom: 8,
                                ),
                                child: Tooltip(
                                  message: theme,
                                  child: IconButton.filledTonal(
                                    onPressed: saving
                                        ? null
                                        : () => setState(() => themeId = theme),
                                    style: IconButton.styleFrom(
                                      backgroundColor: _previewAccent(theme),
                                    ),
                                    icon: Icon(
                                      themeId == theme
                                          ? Icons.check
                                          : Icons.circle,
                                      size: 18,
                                      color: themeId == theme
                                          ? Colors.white
                                          : Colors.transparent,
                                    ),
                                  ),
                                ),
                              ),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Match profile collection',
                              icon: const Icon(Icons.palette_outlined),
                              onPressed: saving
                                  ? null
                                  : () => setState(() {
                                      selected = 'auto';
                                      final hue = HSVColor.fromColor(
                                        Color(
                                          widget.profile.effectiveProfileAccent,
                                        ),
                                      ).hue;
                                      themeId = hue >= 245 || hue < 60
                                          ? 'violet'
                                          : hue < 170
                                          ? 'emerald'
                                          : 'cyan';
                                    }),
                            ),
                          ],
                        ),
                ),
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

class MessageAppearancePreview extends StatelessWidget {
  const MessageAppearancePreview({
    super.key,
    required this.profile,
    required this.style,
    required this.themeId,
    required this.animated,
  });

  final Profile profile;
  final String style;
  final String themeId;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final previewProfile = profile.copyWith(messageBubbleStyle: style);
    final skin = collectionBubbleSkin(previewProfile);
    final accent = _previewAccent(themeId);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      height: 176,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: _previewBackground(themeId),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: animated
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 28,
                  spreadRadius: -6,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: _PreviewBubble(
              text: 'Looks good from here',
              mine: false,
              showTail: true,
            ),
          ),
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: _PreviewBubble(
              text: 'I will send the details',
              mine: true,
              showTail: false,
              skin: skin,
              color: accent,
            ),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: _PreviewBubble(
              text: 'Voice message  0:18',
              icon: Icons.graphic_eq_rounded,
              mine: true,
              joinedPrevious: true,
              showTail: false,
              skin: skin,
              color: accent,
            ),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: _PreviewBubble(
              text: 'Done  12:42',
              mine: true,
              joinedPrevious: true,
              showTail: true,
              skin: skin,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.text,
    required this.mine,
    required this.showTail,
    this.joinedPrevious = false,
    this.skin,
    this.color,
    this.icon,
  });

  final String text;
  final bool mine;
  final bool showTail;
  final bool joinedPrevious;
  final CollectionBubbleSkin? skin;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: Colors.white70),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ),
      ],
    );
    final decoration = BoxDecoration(color: color ?? const Color(0xFF263441));
    if (skin != null) {
      return CollectionMessageSurface(
        skin: skin!,
        mine: mine,
        showTail: showTail,
        joinedPrevious: joinedPrevious,
        decoration: decoration,
        constraints: const BoxConstraints(maxWidth: 245),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: content,
      );
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 245),
      padding: EdgeInsets.fromLTRB(mine ? 10 : 16, 7, mine ? 16 : 10, 7),
      decoration: ShapeDecoration(
        color: decoration.color,
        shape: CollectionBubbleBorder(
          mine: mine,
          showTail: showTail,
          joinedPrevious: joinedPrevious,
        ),
      ),
      child: content,
    );
  }
}

Color _previewAccent(String themeId) => switch (themeId) {
  'cyan' => const Color(0xFF087F9E),
  'violet' => const Color(0xFF7453C8),
  'emerald' => const Color(0xFF27815B),
  _ => const Color(0xFF2587E8),
};

Color _previewBackground(String themeId) => switch (themeId) {
  'cyan' => const Color(0xFF0C1820),
  'violet' => const Color(0xFF151321),
  'emerald' => const Color(0xFF101B19),
  _ => const Color(0xFF111820),
};
