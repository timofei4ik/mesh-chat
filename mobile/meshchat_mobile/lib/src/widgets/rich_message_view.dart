import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/rich_message_document.dart';

Future<void> openRichLink(BuildContext context, String target) async {
  final uri = RichMessageDocument.safeLink(target);
  if (uri == null) return;
  final allowed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open link?'),
      content: SelectableText(uri.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (allowed != true) return;
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open link');
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }
}

class RichMessageView extends StatefulWidget {
  const RichMessageView({
    super.key,
    required this.document,
    this.attachmentBuilder,
  });
  final RichMessageDocument document;
  final Widget Function(String id, String name)? attachmentBuilder;
  @override
  State<RichMessageView> createState() => _RichMessageViewState();
}

class _RichMessageViewState extends State<RichMessageView> {
  q.QuillController? controller;
  final focus = FocusNode();
  final scroll = ScrollController();
  void create() {
    try {
      final document = q.Document.fromJson(widget.document.ops);
      final plain = document.toPlainText();
      final trailing = RegExp(r'\n+$').firstMatch(plain);
      final visible = trailing != null && trailing.group(0)!.length > 1
          ? q.Document.fromDelta(
              document.toDelta().slice(0, trailing.start + 1),
            )
          : document;
      if (!identical(visible, document)) document.close();
      controller = q.QuillController(
        document: visible,
        selection: const TextSelection.collapsed(offset: 0),
        readOnly: true,
      );
    } catch (_) {
      controller = null;
    }
  }

  @override
  void initState() {
    super.initState();
    create();
  }

  @override
  void didUpdateWidget(RichMessageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.encode() != widget.document.encode()) {
      controller?.dispose();
      create();
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => controller == null
      ? SelectableText(widget.document.text)
      : Localizations.override(
          context: context,
          delegates: q.FlutterQuillLocalizations.localizationsDelegates,
          child: q.QuillEditor.basic(
            controller: controller!,
            focusNode: focus,
            scrollController: scroll,
            config: q.QuillEditorConfig(
              scrollable: false,
              showCursor: false,
              checkBoxReadOnly: true,
              enableInteractiveSelection: true,
              onLaunchUrl: (url) => openRichLink(context, url),
              embedBuilders: [
                MeshRichEmbedBuilder(
                  attachmentBuilder: widget.attachmentBuilder,
                ),
                const MeshFormulaBuilder(),
              ],
            ),
          ),
        );
}

class MeshFormulaBuilder extends q.EmbedBuilder {
  const MeshFormulaBuilder();
  @override
  String get key => 'formula';
  @override
  bool get expanded => false;
  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) =>
      ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - 96).clamp(80, 240),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Math.tex(
            embedContext.node.value.data as String,
            textStyle: const TextStyle(color: Color(0xFFE7EDF4), fontSize: 18),
            onErrorFallback: (_) => const Text('Invalid formula'),
          ),
        ),
      );
}

class MeshRichEmbedBuilder extends q.EmbedBuilder {
  const MeshRichEmbedBuilder({
    this.onEdit,
    this.attachmentBuilder,
    this.onRemove,
    this.onMove,
    this.onTypeAround,
  });
  final void Function(q.EmbedContext)? onRemove;
  final void Function(q.EmbedContext, bool)? onMove;
  final void Function(q.EmbedContext, bool)? onTypeAround;
  final void Function(q.EmbedContext, Map<String, dynamic>)? onEdit;
  final Widget Function(String, String)? attachmentBuilder;
  @override
  String get key => 'mesh';
  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) {
    Map<String, dynamic> data;
    try {
      data = RichMessageDocument.validateEmbed(
        jsonDecode(embedContext.node.value.data as String),
      );
    } catch (_) {
      return const Text('[Unsupported content]');
    }
    final child = switch (data['type']) {
      'divider' => const Divider(height: 24),
      'table' => _RichTable(
        rows: (data['rows'] as List)
            .map((r) => List<String>.from(r as List))
            .toList(),
      ),
      'spoiler' => _RichSpoiler(
        text: data['text'] as String,
        revealed: !embedContext.readOnly,
      ),
      'details' => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(data['title'] as String),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(data['text'] as String),
          ),
        ],
      ),
      'pullquote' => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          data['text'] as String,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            fontStyle: FontStyle.italic,
            color: Color(0xFFC7EFFF),
          ),
        ),
      ),
      'button' => OutlinedButton(
        onPressed: () => openRichLink(context, data['url'] as String),
        child: Text(data['label'] as String),
      ),
      'location' => OutlinedButton.icon(
        icon: const Icon(Icons.location_on_outlined),
        label: const Text('Location'),
        onPressed: () =>
            openRichLink(context, RichMessageDocument.embedText(data)),
      ),
      'attachment' =>
        attachmentBuilder?.call(data['id'] as String, data['name'] as String) ??
            Row(
              children: [
                const Icon(Icons.attach_file),
                const SizedBox(width: 8),
                Expanded(child: Text(data['name'] as String)),
              ],
            ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          child,
          if (!embedContext.readOnly)
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                if (onMove != null) ...[
                  IconButton(
                    tooltip: 'Move block up',
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: () => onMove!(embedContext, false),
                  ),
                  IconButton(
                    tooltip: 'Move block down',
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: () => onMove!(embedContext, true),
                  ),
                ],
                if (onTypeAround != null) ...[
                  IconButton(
                    tooltip: 'Write before block',
                    icon: const Icon(Icons.vertical_align_top, size: 18),
                    onPressed: () => onTypeAround!(embedContext, false),
                  ),
                  IconButton(
                    tooltip: 'Write after block',
                    icon: const Icon(Icons.vertical_align_bottom, size: 18),
                    onPressed: () => onTypeAround!(embedContext, true),
                  ),
                ],
                if (!embedContext.readOnly && onRemove != null)
                  IconButton(
                    tooltip: 'Remove block',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => onRemove!(embedContext),
                  ),
                if (!embedContext.readOnly &&
                    onEdit != null &&
                    [
                      'table',
                      'details',
                      'pullquote',
                      'spoiler',
                      'button',
                    ].contains(data['type']))
                  IconButton(
                    tooltip: 'Edit block',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => onEdit!(embedContext, data),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RichTable extends StatefulWidget {
  const _RichTable({required this.rows});
  final List<List<String>> rows;
  @override
  State<_RichTable> createState() => _RichTableState();
}

class _RichTableState extends State<_RichTable> {
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final count = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : count * 130.0;
        final minimum =
            count * 72.0 * MediaQuery.textScalerOf(context).scale(14) / 14;
        final width = available.clamp(
          minimum,
          (count * 130.0).clamp(minimum, double.infinity),
        );
        final overflow = width > available + 0.5;
        return Scrollbar(
          controller: scroll,
          thumbVisibility: overflow,
          trackVisibility: overflow,
          notificationPredicate: (notification) => notification.depth == 0,
          child: SingleChildScrollView(
            controller: scroll,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.only(bottom: overflow ? 12 : 0),
            child: SizedBox(
              width: width,
              child: Table(
                border: TableBorder.all(color: Colors.white24),
                children: [
                  for (var i = 0; i < rows.length; i++)
                    TableRow(
                      decoration: i == 0
                          ? const BoxDecoration(color: Color(0xFF2B3A48))
                          : null,
                      children: [
                        for (var j = 0; j < count; j++)
                          Padding(
                            padding: const EdgeInsets.all(9),
                            child: SelectableText(
                              j < rows[i].length ? rows[i][j] : '',
                              style: TextStyle(
                                fontWeight: i == 0
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RichSpoiler extends StatefulWidget {
  const _RichSpoiler({required this.text, required this.revealed});
  final String text;
  final bool revealed;
  @override
  State<_RichSpoiler> createState() => _RichSpoilerState();
}

class _RichSpoilerState extends State<_RichSpoiler> {
  bool opened = false;
  @override
  void didUpdateWidget(_RichSpoiler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) opened = false;
  }

  @override
  Widget build(BuildContext context) => opened || widget.revealed
      ? SelectableText(widget.text)
      : TextButton.icon(
          onPressed: () => setState(() => opened = true),
          icon: const Icon(Icons.visibility_off_outlined),
          label: const Text('Spoiler'),
        );
}
