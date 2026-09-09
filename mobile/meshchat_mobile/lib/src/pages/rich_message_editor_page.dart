import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_quill/quill_delta.dart' as delta;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cross_file/cross_file.dart';
import '../models/rich_message_document.dart';
import '../services/rich_draft_store.dart';
import '../widgets/rich_message_view.dart';
import '../widgets/rich_editor_theme.dart';

class RichMessageEditorPage extends StatefulWidget {
  const RichMessageEditorPage({
    super.key,
    required this.initial,
    required this.drafts,
    required this.onSend,
    this.onGenerate,
    this.attachmentBuilder,
    this.editing = false,
    this.background,
  });
  final RichMessageDocument initial;
  final RichDraftStore drafts;
  final Future<void> Function(RichMessageDocument) onSend;
  final Future<String> Function(String)? onGenerate;
  final Widget Function(String, String)? attachmentBuilder;
  final bool editing;
  final Widget? background;

  @override
  State<RichMessageEditorPage> createState() => _RichMessageEditorPageState();
}

class _RichMessageEditorPageState extends State<RichMessageEditorPage>
    with WidgetsBindingObserver {
  late final q.QuillController editor;
  final editorFocus = FocusNode(debugLabel: 'rich-message-editor');
  final editorScroll = ScrollController();
  final surfaceKey = GlobalKey();
  BuildContext get surfaceContext => surfaceKey.currentContext ?? context;

  void restoreEditorFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !closing &&
          !sending &&
          !picking &&
          ModalRoute.of(context)?.isCurrent == true) {
        editorFocus.requestFocus();
      }
    });
  }

  Timer? debounce;
  StreamSubscription<q.DocChange>? documentChanges;
  int revision = 0;
  int savedRevision = -1;
  Future<bool> draftWrite = Future.value(true);
  TextSelection? menuSelection;
  bool sending = false;
  bool generating = false;
  bool picking = false;
  bool closing = false;
  String? error;
  bool adjustingCaret = false;

  void guardBlockCaret() {
    if (adjustingCaret || closing || !editor.selection.isCollapsed) return;
    final position = editor.selection.start;
    if (position < 0) return;
    final text = editor.document.toPlainText();
    final start = position == 0 ? 0 : text.lastIndexOf('\n', position - 1) + 1;
    final end = text.indexOf('\n', position);
    if (end < 0 ||
        !editor.document
            .toDelta()
            .slice(start, end)
            .operations
            .any(
              (op) => op.data is Map && (op.data as Map).containsKey('mesh'),
            )) {
      return;
    }
    adjustingCaret = true;
    try {
      var target = end + 1;
      if (target >= editor.document.length || text[target] == '\uFFFC') {
        target = end;
        editor.replaceText(
          end,
          0,
          '\n',
          TextSelection.collapsed(offset: end + 1),
        );
        target++;
      }
      editor.updateSelection(
        TextSelection.collapsed(offset: target),
        q.ChangeSource.local,
      );
    } finally {
      adjustingCaret = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    editor = q.QuillController(
      config: q.QuillControllerConfig(
        // Quill 11's clipboard hook validates foreign content before insertion.
        // ignore: experimental_member_use
        clipboardConfig: q.QuillClipboardConfig(
          // ignore: experimental_member_use
          onRichTextPaste: (value, _) async => delta.Delta.fromJson(
            RichMessageDocument.safePaste(value.toJson()),
          ),
        ),
      ),
      document: q.Document.fromJson(widget.initial.ops),
      selection: const TextSelection.collapsed(offset: 0),
    );
    documentChanges = editor.changes.listen((_) => changed());
    editor.addListener(guardBlockCaret);
  }

  RichMessageDocument document() =>
      RichMessageDocument.fromOps(editor.document.toDelta().toJson());

  void changed() {
    if (!mounted || closing) return;
    revision++;
    debounce?.cancel();
    debounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(saveDraft()),
    );
  }

  Future<bool> saveDraft() {
    draftWrite = draftWrite.then((_) => persistDraft());
    return draftWrite;
  }

  Future<bool> persistDraft() async {
    if (closing || !mounted || savedRevision == revision) return true;
    final currentRevision = revision;
    try {
      final ops = editor.document.toDelta().toJson();
      final value = RichMessageDocument.fromOps(ops);
      await widget.drafts.save(value);
      savedRevision = currentRevision;
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Draft could not be saved. Keep this editor open.',
        );
      }
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(saveDraft());
  }

  @override
  void dispose() {
    debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    documentChanges?.cancel();
    editor.removeListener(guardBlockCaret);
    editor.dispose();
    editorFocus.dispose();
    editorScroll.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (sending || picking || closing) return;
    debounce?.cancel();
    if (!await saveDraft() || !mounted) return;
    setState(() => closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, false);
    });
  }

  Future<void> send() async {
    if (sending || generating || picking) return;
    RichMessageDocument value;
    try {
      value = document();
    } catch (_) {
      setState(
        () => error =
            'This document is too large or contains unsupported formatting.',
      );
      return;
    }
    if (value.text.isEmpty) return;
    debounce?.cancel();
    setState(() {
      sending = true;
      error = null;
    });
    editor.readOnly = true;
    try {
      await draftWrite;
      await widget.drafts.save(value);
      await widget.onSend(value);
      // The message is already enqueued. A preferences error must not make
      // the send button available again and create a duplicate message.
      closing = true;
      try {
        await widget.drafts.save(null);
      } catch (_) {
        /* Retain recovery draft. */
      }
      if (mounted) {
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          sending = false;
          error = e.toString();
        });
      }
      editor.readOnly = false;
      restoreEditorFocus();
    }
  }

  void style(q.Attribute attribute) {
    final current = editor.getSelectionStyle().attributes[attribute.key];
    editor.formatSelection(
      current?.value == attribute.value
          ? q.Attribute.clone(attribute, null)
          : attribute,
    );
    restoreEditorFocus();
  }

  Future<void> attach(FileType type) async {
    if (picking || sending) return;
    final selection = editor.selection;
    setState(() {
      picking = true;
      error = null;
    });
    editor.readOnly = true;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        withData: kIsWeb,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      if (file.size > 64 * 1024 * 1024) throw StateError('File exceeds 64 MB.');
      final bytes = file.bytes ?? await XFile(file.path!).readAsBytes();
      final name = file.name.length <= 200
          ? file.name
          : '${file.name.substring(0, 180)}${file.extension == null ? '' : '.${file.extension}'}';
      final data = await widget.drafts.stage(name, bytes);
      if (!mounted) return;
      editor.updateSelection(selection, q.ChangeSource.local);
      insertBlock(data);
      await saveDraft();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        editor.readOnly = false;
        setState(() => picking = false);
        restoreEditorFocus();
      }
    }
  }

  Future<List<String>?> fields(
    String title,
    List<String> labels,
    List<String> values, {
    String? note,
    int maxLength = 8000,
  }) async {
    final inputs = [
      for (final value in values) TextEditingController(text: value),
    ];
    final result = await showDialog<List<String>>(
      context: surfaceContext,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(note),
                  ),
                for (var i = 0; i < inputs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: inputs[i],
                      maxLines: labels[i] == 'Text' ? 6 : 1,
                      minLines: 1,
                      maxLength: maxLength,
                      decoration: InputDecoration(
                        labelText: labels[i],
                        counterText: '',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, inputs.map((c) => c.text).toList()),
            child: const Text('Insert'),
          ),
        ],
      ),
    );
    // Dialog removal is animated; let its text fields detach first.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final input in inputs) {
      input.dispose();
    }
    restoreEditorFocus();
    return result;
  }

  void insertBlock(Map<String, dynamic> data, {int? offset}) {
    RichMessageDocument.validateEmbed(data);
    final selection = editor.selection;
    final start = offset ?? selection.start;
    if (start < 0) return;
    final text = editor.document.toPlainText();
    final prefix = offset == null && (start == 0 || text[start - 1] != '\n')
        ? '\n'
        : '';
    final content = delta.Delta()
      ..insert(prefix)
      ..insert({'mesh': jsonEncode(data)});
    if (offset == null) content.insert('\n');
    editor.replaceText(
      start,
      offset == null ? selection.end - start : 1,
      content,
      TextSelection.collapsed(
        offset: start + prefix.length + (offset == null ? 2 : 1),
      ),
    );
    restoreEditorFocus();
  }

  void moveBlock(q.EmbedContext embed, bool down) {
    final start = embed.node.documentOffset;
    final text = editor.document.toPlainText();
    final end = text.indexOf('\n', start) + 1;
    if (end <= start) return;
    final doc = editor.document.toDelta();
    var change = delta.Delta();
    int destination;
    if (down) {
      if (end >= text.length - 1) return;
      final nextEnd = text.indexOf('\n', end) + 1;
      final block = doc.slice(start, end);
      final next = doc.slice(end, nextEnd);
      change.retain(start);
      change.delete(nextEnd - start);
      change = change.concat(next).concat(block);
      destination = start + nextEnd - end;
    } else {
      if (start == 0) return;
      final previous = start <= 1 ? 0 : text.lastIndexOf('\n', start - 2) + 1;
      change.retain(previous);
      change.delete(end - previous);
      change = change
          .concat(doc.slice(start, end))
          .concat(doc.slice(previous, start));
      destination = previous;
    }
    editor.compose(
      change,
      TextSelection.collapsed(offset: destination),
      q.ChangeSource.local,
    );
    restoreEditorFocus();
  }

  void typeAroundBlock(q.EmbedContext embed, bool after) {
    final offset = embed.node.documentOffset;
    var at = after
        ? editor.document.toPlainText().indexOf('\n', offset) + 1
        : offset;
    if (at < 0) return;
    at = at.clamp(0, editor.document.length - 1);
    adjustingCaret = true;
    try {
      editor.compose(
        delta.Delta()
          ..retain(at)
          ..insert('\n'),
        TextSelection.collapsed(offset: at),
        q.ChangeSource.local,
      );
      editor.updateSelection(
        TextSelection.collapsed(offset: at),
        q.ChangeSource.local,
      );
    } finally {
      adjustingCaret = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !closing) {
        editor.updateSelection(
          TextSelection.collapsed(offset: at),
          q.ChangeSource.local,
        );
      }
    });
    restoreEditorFocus();
  }

  Future<void> block(
    String type, {
    q.EmbedContext? embed,
    Map<String, dynamic>? initial,
  }) async {
    final data = initial ?? <String, dynamic>{'type': type};
    final offset = embed?.node.documentOffset;
    if (type == 'divider') {
      insertBlock(data);
      return;
    }
    if (type == 'table') {
      final rows = await showDialog<List<List<String>>>(
        context: surfaceContext,
        builder: (_) => _TableDialog(initial: data['rows'] as List?),
      );
      restoreEditorFocus();
      if (rows != null && mounted) {
        insertBlock({'type': type, 'rows': rows}, offset: offset);
      }
      return;
    }
    final keys = switch (type) {
      'details' => ['title', 'text'],
      'button' => ['label', 'url'],
      'location' => ['lat', 'lon'],
      _ => ['text'],
    };
    final labels = switch (type) {
      'details' => ['Title', 'Text'],
      'button' => ['Label', 'URL'],
      'location' => ['Latitude', 'Longitude'],
      _ => ['Text'],
    };
    final selected = editor.selection;
    final plain = editor.document.toPlainText();
    final text = selected.isValid && selected.end <= plain.length
        ? plain.substring(selected.start, selected.end)
        : '';
    final result = await fields(type, labels, [
      for (final key in keys)
        data[key]?.toString() ?? (key == 'text' ? text : ''),
    ]);
    if (result == null || !mounted) return;
    try {
      insertBlock({
        'type': type,
        for (var i = 0; i < keys.length; i++)
          keys[i]: type == 'location' ? double.parse(result[i]) : result[i],
      }, offset: offset);
    } catch (_) {
      setState(() => error = 'Check the block values or link.');
    }
  }

  Future<void> link() async {
    final selection = editor.selection;
    final result = await fields('Link', ['URL'], [''], maxLength: 2048);
    if (result == null || !mounted) return;
    if (RichMessageDocument.safeLink(result.first) == null) {
      setState(() => error = 'Enter a valid https, http, mailto or tel link.');
      return;
    }
    editor.updateSelection(selection, q.ChangeSource.local);
    if (selection.isCollapsed) {
      editor.replaceText(
        selection.start,
        0,
        result.first,
        TextSelection(
          baseOffset: selection.start,
          extentOffset: selection.start + result.first.length,
        ),
      );
    }
    editor.formatSelection(q.LinkAttribute(result.first));
  }

  Future<void> formula() async {
    final result = await showDialog<({String text, bool separateLine})>(
      context: surfaceContext,
      builder: (_) => const _FormulaDialog(),
    );
    restoreEditorFocus();
    if (result == null || !mounted) return;
    final selection = editor.selection;
    var offset = selection.start;
    if (result.separateLine &&
        offset > 0 &&
        editor.document.toPlainText()[offset - 1] != '\n') {
      editor.replaceText(
        offset,
        0,
        '\n',
        TextSelection.collapsed(offset: offset + 1),
      );
      offset++;
    }
    editor.replaceText(
      offset,
      selection.end - selection.start,
      q.BlockEmbed.formula(result.text),
      TextSelection.collapsed(offset: offset + 1),
    );
    if (result.separateLine &&
        editor.document.toPlainText()[offset + 1] != '\n') {
      editor.replaceText(
        offset + 1,
        0,
        '\n',
        TextSelection.collapsed(offset: offset + 2),
      );
    }
  }

  Future<void> emoji() async {
    final value = await showModalBottomSheet<String>(
      context: surfaceContext,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 235,
          child: GridView.count(
            crossAxisCount: 6,
            children: [
              for (final code in [
                0x1f600,
                0x1f60a,
                0x1f602,
                0x1f60e,
                0x1f914,
                0x1f44d,
                0x2764,
                0x1f389,
                0x1f64f,
                0x1f44b,
                0x1f525,
                0x2705,
                0x1f44f,
                0x1f60d,
                0x1f622,
                0x1f4af,
                0x1f91d,
                0x1f680,
              ])
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, String.fromCharCode(code)),
                  child: Text(
                    String.fromCharCode(code),
                    style: const TextStyle(fontSize: 27),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    restoreEditorFocus();
    if (value == null || !mounted) return;
    final selection = editor.selection;
    editor.replaceText(
      selection.start,
      selection.end - selection.start,
      value,
      TextSelection.collapsed(offset: selection.start + value.length),
    );
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: surfaceContext,
      builder: (context) => AlertDialog(
        title: const Text('Clear draft?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    restoreEditorFocus();
    if (confirmed == true && mounted) {
      editor.replaceText(
        0,
        editor.document.length - 1,
        '',
        const TextSelection.collapsed(offset: 0),
      );
    }
  }

  Future<void> generate() async {
    if (generating || widget.onGenerate == null) return;
    final result = await fields(
      'Create with AI',
      ['Text'],
      [''],
      note:
          'Only this instruction is sent to the external AI service. Your chat history is not sent. Review the draft before inserting it.',
      maxLength: 1800,
    );
    if (result == null || !mounted || result.first.trim().isEmpty) return;
    setState(() {
      generating = true;
      error = null;
    });
    try {
      final response = await widget.onGenerate!(result.first);
      if (!mounted) return;
      final reviewed = await fields('AI draft', ['Text'], [response]);
      if (reviewed != null && mounted) {
        final selection = editor.selection;
        editor.replaceText(
          selection.start,
          0,
          reviewed.first,
          TextSelection.collapsed(
            offset: selection.start + reviewed.first.length,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => generating = false);
    }
  }

  q.Attribute? menuAttribute(String label) => switch (label) {
    'Bold' => q.Attribute.bold,
    'Italic' => q.Attribute.italic,
    'Underline' => q.Attribute.underline,
    'Strikethrough' => q.Attribute.strikeThrough,
    'Code' => q.Attribute.inlineCode,
    'Subscript' => q.Attribute.subscript,
    'Superscript' => q.Attribute.superscript,
    'Highlight' => const q.BackgroundAttribute('#365C64'),
    'Heading 1' => q.Attribute.h1,
    'Heading 2' => q.Attribute.h2,
    'Heading 3' => q.Attribute.h3,
    'Quote' => q.Attribute.blockQuote,
    'Code block' => q.Attribute.codeBlock,
    'Footer' => q.Attribute.small,
    'Ordered list' => q.Attribute.ol,
    'Bullet list' => q.Attribute.ul,
    'Checklist' => q.Attribute.unchecked,
    _ => null,
  };

  IconData menuIcon(String label) => switch (label) {
    'Bold' => Icons.format_bold,
    'Italic' => Icons.format_italic,
    'Underline' => Icons.format_underlined,
    'Strikethrough' => Icons.format_strikethrough,
    'Code' || 'Code block' => Icons.code,
    'Subscript' => Icons.subscript,
    'Superscript' => Icons.superscript,
    'Highlight' => Icons.border_color_outlined,
    'Heading 1' || 'Heading 2' || 'Heading 3' => Icons.title,
    'Text' => Icons.notes,
    'Quote' || 'Pullquote' => Icons.format_quote,
    'Footer' => Icons.short_text,
    'Divider' => Icons.horizontal_rule,
    'Ordered list' => Icons.format_list_numbered,
    'Bullet list' => Icons.format_list_bulleted,
    'Checklist' => Icons.checklist,
    'Details' => Icons.unfold_more,
    'Spoiler' => Icons.visibility_off_outlined,
    'Text link' => Icons.link,
    'Button' => Icons.smart_button_outlined,
    'Location' => Icons.location_on_outlined,
    'Photo or video' => Icons.image_outlined,
    'Audio file' => Icons.music_note_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  Widget menu(IconData icon, String label, Map<String, VoidCallback> items) =>
      PopupMenuButton<String>(
        tooltip: label,
        icon: Icon(icon, size: 21),
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 280),
        popUpAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 140),
          curve: Curves.linear,
        ),
        onOpened: () => menuSelection = editor.selection,
        onCanceled: restoreEditorFocus,
        onSelected: (key) {
          if (menuSelection != null) {
            editor.updateSelection(menuSelection!, q.ChangeSource.local);
          }
          items[key]!();
          restoreEditorFocus();
        },
        itemBuilder: (_) {
          final common = editor.getSelectionStyle().attributes;
          final styles = editor.getAllSelectionStyles();
          return [
            for (final key in items.keys)
              () {
                final attr = menuAttribute(key);
                bool matches(q.Style style) =>
                    attr != null &&
                    (style.attributes[attr.key]?.value == attr.value ||
                        key == 'Checklist' &&
                            style.attributes[attr.key]?.value == 'checked');
                final selected =
                    attr != null && matches(editor.getSelectionStyle());
                final mixed = !selected && attr != null && styles.any(matches);
                final plain =
                    key == 'Text' &&
                    ![
                      'header',
                      'blockquote',
                      'code-block',
                      'list',
                    ].any(common.containsKey);
                return PopupMenuItem<String>(
                  value: key,
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Semantics(
                    selected: selected || plain,
                    child: Container(
                      key: ValueKey('rich-menu-$key'),
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: selected || plain
                            ? const Color(0xFF2A3C3D)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            menuIcon(key),
                            size: 19,
                            color: selected || plain
                                ? const Color(0xFFA4DCC2)
                                : const Color(0xFFAABCC3),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              key,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: key == 'Bold'
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontStyle: key == 'Italic'
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 24,
                            child: selected || plain
                                ? const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: Color(0xFFA4DCC2),
                                  )
                                : mixed
                                ? const Icon(
                                    Icons.remove,
                                    size: 18,
                                    color: Color(0xFFA4DCC2),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }(),
          ];
        },
      );

  @override
  Widget build(BuildContext context) => Theme(
    data: richEditorTheme(Theme.of(context)),
    child: Builder(key: surfaceKey, builder: buildEditor),
  );

  Widget buildEditor(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(close());
    },
    child: Scaffold(
      backgroundColor: const Color(0xFF121719),
      appBar: AppBar(
        title: Text(widget.editing ? 'Edit message' : 'Message editor'),
        leading: IconButton(
          tooltip: 'Close',
          onPressed: close,
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedBuilder(
                  animation: editor,
                  builder: (context, _) => ColoredBox(
                    color: const Color(0xFF1B2327),
                    child: AbsorbPointer(
                      absorbing: sending || picking,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Undo',
                              onPressed: editor.hasUndo
                                  ? () {
                                      editor.undo();
                                      restoreEditorFocus();
                                    }
                                  : null,
                              icon: const Icon(Icons.undo),
                            ),
                            IconButton(
                              tooltip: 'Redo',
                              onPressed: editor.hasRedo
                                  ? () {
                                      editor.redo();
                                      restoreEditorFocus();
                                    }
                                  : null,
                              icon: const Icon(Icons.redo),
                            ),
                            const SizedBox(
                              height: 24,
                              child: VerticalDivider(width: 16),
                            ),
                            menu(Icons.text_fields, 'Paragraph', {
                              'Heading 1': () => style(q.Attribute.h1),
                              'Heading 2': () => style(q.Attribute.h2),
                              'Heading 3': () => style(q.Attribute.h3),
                              'Text': () {
                                for (final a in <q.Attribute>[
                                  q.Attribute.header,
                                  q.Attribute.blockQuote,
                                  q.Attribute.codeBlock,
                                  q.Attribute.list,
                                ]) {
                                  editor.formatSelection(
                                    q.Attribute.clone(a, null),
                                  );
                                }
                              },
                              'Quote': () => style(q.Attribute.blockQuote),
                              'Pullquote': () => block('pullquote'),
                              'Code block': () => style(q.Attribute.codeBlock),
                              'Footer': () => style(q.Attribute.small),
                              'Divider': () => block('divider'),
                            }),
                            menu(Icons.format_bold, 'Formatting', {
                              'Bold': () => style(q.Attribute.bold),
                              'Italic': () => style(q.Attribute.italic),
                              'Underline': () => style(q.Attribute.underline),
                              'Strikethrough': () =>
                                  style(q.Attribute.strikeThrough),
                              'Code': () => style(q.Attribute.inlineCode),
                              'Spoiler': () => block('spoiler'),
                              'Subscript': () => style(q.Attribute.subscript),
                              'Superscript': () =>
                                  style(q.Attribute.superscript),
                              'Highlight': () =>
                                  style(const q.BackgroundAttribute('#365C64')),
                            }),
                            menu(Icons.format_list_bulleted, 'Lists', {
                              'Ordered list': () => style(q.Attribute.ol),
                              'Bullet list': () => style(q.Attribute.ul),
                              'Checklist': () => style(q.Attribute.unchecked),
                              'Details': () => block('details'),
                            }),
                            IconButton(
                              tooltip: 'Table',
                              onPressed: () => block('table'),
                              icon: const Icon(Icons.table_chart_outlined),
                            ),
                            menu(Icons.link, 'Links', {
                              'Text link': link,
                              'Button': () => block('button'),
                              'Location': () => block('location'),
                            }),
                            menu(Icons.perm_media_outlined, 'Media', {
                              'Photo or video': () => attach(FileType.media),
                              'Audio file': () => attach(FileType.audio),
                              'File': () => attach(FileType.any),
                              'Location': () => block('location'),
                            }),
                            IconButton(
                              tooltip: 'Formula',
                              onPressed: formula,
                              icon: const Icon(Icons.functions),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Color(0xFFFFAFB7)),
                    ),
                  ),
                if (generating || sending || picking)
                  const LinearProgressIndicator(),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.background != null)
                        IgnorePointer(child: widget.background!),
                      Localizations.override(
                        context: context,
                        delegates:
                            q.FlutterQuillLocalizations.localizationsDelegates,
                        child: q.QuillEditor.basic(
                          controller: editor,
                          focusNode: editorFocus,
                          scrollController: editorScroll,
                          config: q.QuillEditorConfig(
                            padding: const EdgeInsets.all(20),
                            autoFocus: true,
                            expands: true,
                            embedBuilders: [
                              MeshRichEmbedBuilder(
                                onMove: moveBlock,
                                onTypeAround: typeAroundBlock,
                                attachmentBuilder: widget.attachmentBuilder,
                                onRemove: (embed) => editor.replaceText(
                                  embed.node.documentOffset,
                                  1,
                                  '',
                                  TextSelection.collapsed(
                                    offset: embed.node.documentOffset,
                                  ),
                                ),
                                onEdit: (embed, data) => block(
                                  data['type'] as String,
                                  embed: embed,
                                  initial: data,
                                ),
                              ),
                              const MeshFormulaBuilder(),
                            ],
                            onLaunchUrl: (url) => openRichLink(context, url),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF181F22),
                    border: Border(top: BorderSide(color: Color(0xFF303A3F))),
                  ),
                  child: Row(
                    children: [
                      if (widget.onGenerate != null)
                        IconButton(
                          tooltip: 'Create with AI',
                          onPressed: generating || sending ? null : generate,
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            color: Color(0xFFCAB7ED),
                          ),
                        ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Emoji',
                        onPressed: sending ? null : emoji,
                        icon: const Icon(Icons.emoji_emotions_outlined),
                      ),
                      IconButton(
                        tooltip: 'Clear draft',
                        onPressed: sending ? null : clear,
                        icon: const Icon(Icons.delete_outline),
                      ),
                      IconButton.filled(
                        tooltip: widget.editing ? 'Save' : 'Send',
                        onPressed: sending || generating || picking
                            ? null
                            : send,
                        icon: Icon(widget.editing ? Icons.check : Icons.send),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _FormulaDialog extends StatefulWidget {
  const _FormulaDialog();
  @override
  State<_FormulaDialog> createState() => _FormulaDialogState();
}

class _FormulaDialogState extends State<_FormulaDialog> {
  final input = TextEditingController();
  bool separateLine = true;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Formula'),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: input,
              maxLength: 512,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'LaTeX'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: separateLine,
              title: const Text('Separate line'),
              onChanged: (value) =>
                  setState(() => separateLine = value ?? true),
            ),
            SizedBox(
              height: 100,
              child: Center(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Math.tex(
                    input.text.isEmpty ? r'x^2 + y^2' : input.text,
                    textStyle: const TextStyle(
                      fontSize: 22,
                      color: Color(0xFFE7EDF4),
                    ),
                    onErrorFallback: (_) =>
                        const Text('Check the LaTeX expression'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: input.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (
                text: input.text,
                separateLine: separateLine,
              )),
        child: const Text('Insert'),
      ),
    ],
  );
}

class _TableDialog extends StatefulWidget {
  const _TableDialog({this.initial});
  final List? initial;
  @override
  State<_TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends State<_TableDialog> {
  late final List<List<TextEditingController>> cells;
  final removedCells = <TextEditingController>[];

  void removeRow(int index) {
    if (cells.length <= 1) return;
    setState(() => removedCells.addAll(cells.removeAt(index)));
  }

  void removeColumn(int index) {
    if (cells.first.length <= 1) return;
    setState(() {
      for (final row in cells) {
        removedCells.add(row.removeAt(index));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    cells = [
      for (final row
          in widget.initial ??
              [
                ['', '', ''],
                ['', '', ''],
                ['', '', ''],
              ])
        [
          for (final value in row as List)
            TextEditingController(text: value as String),
        ],
    ];
    final width = cells
        .map((row) => row.length)
        .reduce((a, b) => a > b ? a : b);
    for (final row in cells) {
      while (row.length < width) {
        row.add(TextEditingController());
      }
    }
  }

  @override
  void dispose() {
    for (final cell in removedCells) {
      cell.dispose();
    }
    for (final row in cells) {
      for (final cell in row) {
        cell.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Table'),
    content: SizedBox(
      width: 640,
      height: 330,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Add row',
                  onPressed: cells.length >= 20
                      ? null
                      : () => setState(
                          () => cells.add(
                            List.generate(
                              cells.first.length,
                              (_) => TextEditingController(),
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.table_rows_outlined),
                ),
                IconButton(
                  tooltip: 'Add column',
                  onPressed: cells.first.length >= 8
                      ? null
                      : () => setState(() {
                          for (final row in cells) {
                            row.add(TextEditingController());
                          }
                        }),
                  icon: const Icon(Icons.view_column_outlined),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: cells.first.length * 150 + 48,
                child: Table(
                  columnWidths: {
                    cells.first.length: const FixedColumnWidth(48),
                  },
                  children: [
                    TableRow(
                      children: [
                        for (
                          var column = 0;
                          column < cells.first.length;
                          column++
                        )
                          IconButton(
                            tooltip: 'Delete column ${column + 1}',
                            onPressed: cells.first.length > 1
                                ? () => removeColumn(column)
                                : null,
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        const SizedBox(),
                      ],
                    ),
                    for (var row = 0; row < cells.length; row++)
                      TableRow(
                        children: [
                          for (final cell in cells[row])
                            Padding(
                              key: ObjectKey(cell),
                              padding: const EdgeInsets.all(4),
                              child: TextField(
                                controller: cell,
                                maxLength: 2000,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  counterText: '',
                                ),
                              ),
                            ),
                          IconButton(
                            tooltip: 'Delete row ${row + 1}',
                            onPressed: cells.length > 1
                                ? () => removeRow(row)
                                : null,
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, [
          for (final row in cells) [for (final cell in row) cell.text],
        ]),
        child: const Text('Insert'),
      ),
    ],
  );
}
