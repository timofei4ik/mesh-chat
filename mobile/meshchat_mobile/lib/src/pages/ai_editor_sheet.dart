import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../widgets/mesh_liquid_glass.dart';

enum _AiEditorMode { translate, style, fix }

typedef _AiStyleOption = ({
  String id,
  String label,
  IconData icon,
  String description,
});

const _aiStyles = <_AiStyleOption>[
  (
    id: 'zen',
    label: 'Zen',
    icon: Icons.self_improvement_rounded,
    description: 'Calm and minimal',
  ),
  (
    id: 'biblical',
    label: 'Biblical',
    icon: Icons.menu_book_rounded,
    description: 'Solemn and timeless',
  ),
  (
    id: 'viking',
    label: 'Viking',
    icon: Icons.shield_rounded,
    description: 'Bold saga voice',
  ),
  (
    id: 'prehistoric',
    label: 'Prehistoric',
    icon: Icons.landscape_rounded,
    description: 'Playful cave speech',
  ),
  (
    id: 'tribal',
    label: 'Tribal',
    icon: Icons.public_rounded,
    description: 'Rhythmic storytelling',
  ),
  (
    id: 'business',
    label: 'Corp',
    icon: Icons.business_center_rounded,
    description: 'Clear and professional',
  ),
  (
    id: 'friendly',
    label: 'Friendly',
    icon: Icons.sentiment_satisfied_alt_rounded,
    description: 'Warm and natural',
  ),
  (
    id: 'concise',
    label: 'Short',
    icon: Icons.compress_rounded,
    description: 'Brief and direct',
  ),
];

const _aiLanguages = <String, String>{
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

Future<String?> showMeshAiEditor({
  required BuildContext context,
  required AppController controller,
  required String original,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AiEditorSheet(controller: controller, original: original),
  );
}

class _AiEditorSheet extends StatefulWidget {
  const _AiEditorSheet({required this.controller, required this.original});

  final AppController controller;
  final String original;

  @override
  State<_AiEditorSheet> createState() => _AiEditorSheetState();
}

class _AiEditorSheetState extends State<_AiEditorSheet> {
  _AiEditorMode mode = _AiEditorMode.style;
  String style = 'friendly';
  String targetLanguage = 'en';
  String result = '';
  String error = '';
  bool emojify = false;
  bool loading = false;

  Future<void> run() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final String output;
      if (mode == _AiEditorMode.translate) {
        final translation = await widget.controller.translateMessageWithAi(
          text: widget.original,
          targetLanguage: targetLanguage,
          emojify: emojify,
        );
        output = translation.text;
      } else {
        final baseStyle = mode == _AiEditorMode.fix ? 'proofread' : style;
        final rewrite = await widget.controller.rewriteTextWithAi(
          text: widget.original,
          style: emojify ? '$baseStyle+emojify' : baseStyle,
        );
        output = rewrite.text;
      }
      if (!mounted) return;
      setState(() => result = output);
    } on AiRewriteException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } on AiTranslationException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Mesh AI could not process the text');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void selectMode(_AiEditorMode next) {
    if (mode == next) return;
    HapticFeedback.selectionClick();
    setState(() {
      mode = next;
      result = '';
      error = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.84;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFA172331),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white12),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 32),
          ],
        ),
        child: Column(
          children: [
            _EditorHeader(onClose: () => Navigator.pop(context)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _AiModeSelector(mode: mode, onChanged: selectMode),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0.025, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _modeBody(),
              ),
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: loading
                          ? null
                          : result.isEmpty
                          ? run
                          : () => Navigator.pop(context, result),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFF347FB8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                      child: loading
                          ? const SizedBox.square(
                              dimension: 19,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(result.isEmpty ? _runLabel : 'Apply'),
                    ),
                  ),
                  if (result.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Run again',
                      onPressed: run,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _runLabel => switch (mode) {
    _AiEditorMode.translate => 'Translate',
    _AiEditorMode.style => 'Apply style',
    _AiEditorMode.fix => 'Fix text',
  };

  Widget _modeBody() {
    return Padding(
      key: ValueKey(mode),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          if (mode == _AiEditorMode.translate) _languagePicker(),
          if (mode == _AiEditorMode.style) _stylePicker(),
          _emojifyRow(),
          Expanded(
            child: _TextResultCard(
              original: widget.original,
              result: result,
              highlightFixes: mode == _AiEditorMode.fix,
              resultLabel: mode == _AiEditorMode.translate
                  ? 'To ${_aiLanguages[targetLanguage]}'
                  : 'Result',
            ),
          ),
        ],
      ),
    );
  }

  Widget _languagePicker() {
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _aiLanguages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          final entry = _aiLanguages.entries.elementAt(index);
          return ChoiceChip(
            label: Text(entry.value),
            selected: targetLanguage == entry.key,
            onSelected: (_) => setState(() {
              targetLanguage = entry.key;
              result = '';
            }),
          );
        },
      ),
    );
  }

  Widget _stylePicker() {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _aiStyles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          final option = _aiStyles[index];
          final selected = style == option.id;
          return Tooltip(
            message: option.description,
            child: InkWell(
              onTap: () => setState(() {
                style = option.id;
                result = '';
              }),
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 68,
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF2B4962)
                      : Colors.white.withValues(alpha: 0.045),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected ? Colors.lightBlueAccent : Colors.white10,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      option.icon,
                      size: 22,
                      color: selected ? Colors.lightBlueAccent : Colors.white70,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emojifyRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: FilterChip(
          avatar: Icon(
            emojify ? Icons.check_circle_rounded : Icons.add_reaction_outlined,
            color: emojify ? Colors.white : Colors.lightBlueAccent,
            size: 18,
          ),
          label: const Text('Emojify'),
          selected: emojify,
          onSelected: (value) => setState(() {
            emojify = value;
            result = '';
          }),
        ),
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'AI Editor',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
          ),
          const Icon(Icons.info_outline_rounded, color: Colors.white54),
          const SizedBox(width: 6),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}

class _AiModeSelector extends StatefulWidget {
  const _AiModeSelector({required this.mode, required this.onChanged});

  final _AiEditorMode mode;
  final ValueChanged<_AiEditorMode> onChanged;

  @override
  State<_AiModeSelector> createState() => _AiModeSelectorState();
}

class _AiModeSelectorState extends State<_AiModeSelector> {
  double? dragCenter;

  int get index => _AiEditorMode.values.indexOf(widget.mode);

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      height: 64,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / 3;
          void update(double dx) {
            final center = dx.clamp(
              width / 2,
              constraints.maxWidth - width / 2,
            );
            final next = (center / width).floor().clamp(0, 2);
            setState(() => dragCenter = center);
            if (_AiEditorMode.values[next] != widget.mode) {
              widget.onChanged(_AiEditorMode.values[next]);
            }
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) =>
                update(details.localPosition.dx),
            onHorizontalDragUpdate: (details) =>
                update(details.localPosition.dx),
            onHorizontalDragEnd: (_) => setState(() => dragCenter = null),
            onHorizontalDragCancel: () => setState(() => dragCenter = null),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: dragCenter == null
                      ? const Duration(milliseconds: 260)
                      : Duration.zero,
                  curve: Curves.easeOutCubic,
                  left: dragCenter == null
                      ? width * index
                      : dragCenter! - width / 2,
                  top: 5,
                  width: width,
                  height: 54,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF29455D).withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.lightBlueAccent.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _item(
                      _AiEditorMode.translate,
                      Icons.translate_rounded,
                      'Translate',
                    ),
                    _item(
                      _AiEditorMode.style,
                      Icons.auto_fix_high_rounded,
                      'Style',
                    ),
                    _item(_AiEditorMode.fix, Icons.task_alt_rounded, 'Fix'),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    return MeshLiquidGlass(
      accent: Colors.lightBlueAccent,
      radius: 30,
      prominent: true,
      interactive: true,
      fallbackBuilder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF101C28),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white10),
        ),
        child: child,
      ),
      child: content,
    );
  }

  Widget _item(_AiEditorMode value, IconData icon, String label) {
    final selected = widget.mode == value;
    return Expanded(
      child: InkWell(
        onTap: () => widget.onChanged(value),
        borderRadius: BorderRadius.circular(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 21,
              color: selected ? Colors.lightBlueAccent : Colors.white70,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.lightBlueAccent : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextResultCard extends StatelessWidget {
  const _TextResultCard({
    required this.original,
    required this.result,
    required this.resultLabel,
    required this.highlightFixes,
  });

  final String original;
  final String result;
  final String resultLabel;
  final bool highlightFixes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF101C28),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Original',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            highlightFixes && result.isNotEmpty
                ? _FixComparisonText(original: original, result: result)
                : SelectableText(
                    original,
                    style: const TextStyle(height: 1.35),
                  ),
            if (result.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 13),
                child: Divider(height: 1),
              ),
              Text(
                resultLabel,
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              SelectableText(
                result,
                style: TextStyle(
                  height: 1.4,
                  color: highlightFixes ? Colors.lightBlueAccent : Colors.white,
                  decoration: highlightFixes
                      ? TextDecoration.underline
                      : TextDecoration.none,
                  decorationColor: Colors.lightBlueAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FixComparisonText extends StatelessWidget {
  const _FixComparisonText({required this.original, required this.result});

  final String original;
  final String result;

  @override
  Widget build(BuildContext context) {
    final originalWords = RegExp(
      r'\s+|\S+',
    ).allMatches(original).map((match) => match.group(0)!).toList();
    final resultWords = RegExp(
      r'\s+|\S+',
    ).allMatches(result).map((match) => match.group(0)!).toList();
    var prefix = 0;
    while (prefix < originalWords.length &&
        prefix < resultWords.length &&
        originalWords[prefix] == resultWords[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < originalWords.length - prefix &&
        suffix < resultWords.length - prefix &&
        originalWords[originalWords.length - suffix - 1] ==
            resultWords[resultWords.length - suffix - 1]) {
      suffix++;
    }
    final unchangedStart = originalWords.take(prefix).join();
    final removed = originalWords
        .skip(prefix)
        .take(originalWords.length - prefix - suffix)
        .join();
    final unchangedEnd = suffix == 0
        ? ''
        : originalWords.skip(originalWords.length - suffix).join();
    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(color: Colors.white, height: 1.4),
        children: [
          if (unchangedStart.isNotEmpty) TextSpan(text: unchangedStart),
          if (removed.isNotEmpty)
            TextSpan(
              text: removed,
              style: const TextStyle(
                color: Colors.redAccent,
                decoration: TextDecoration.lineThrough,
                decorationColor: Colors.redAccent,
              ),
            ),
          if (unchangedEnd.isNotEmpty) TextSpan(text: unchangedEnd),
        ],
      ),
    );
  }
}
