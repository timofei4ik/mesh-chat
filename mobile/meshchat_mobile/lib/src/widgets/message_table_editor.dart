import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MessageTableEditor extends StatefulWidget {
  const MessageTableEditor({super.key, this.initial});
  final List? initial;
  @override
  State<MessageTableEditor> createState() => _MessageTableEditorState();
}

class _MessageTableEditorState extends State<MessageTableEditor> {
  late List<List<String>> cells;
  final input = TextEditingController();
  final inputFocus = FocusNode();
  int anchorRow = 0, anchorColumn = 0, endRow = 0, endColumn = 0;
  bool rangeMode = false;
  (int, int)? lastTappedCell;
  DateTime? lastCellTapAt;
  int get top => math.min(anchorRow, endRow);
  int get bottom => math.max(anchorRow, endRow);
  int get left => math.min(anchorColumn, endColumn);
  int get right => math.max(anchorColumn, endColumn);
  String address(int row, int column) =>
      '${String.fromCharCode(65 + column)}${row + 1}';
  String get selection => top == bottom && left == right
      ? address(top, left)
      : '${address(top, left)}:${address(bottom, right)}';

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
        [for (final value in row as List) value.toString()],
    ];
    if (cells.isEmpty) cells.add(['']);
    final width = cells.fold<int>(
      1,
      (width, row) => math.max(width, row.length),
    );
    for (final row in cells) {
      while (row.length < width) {
        row.add('');
      }
    }
    input.text = cells[0][0];
  }

  @override
  void dispose() {
    input.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  void select(int row, int column, {bool extend = false, bool edit = false}) {
    setState(() {
      if (!extend && !rangeMode && !HardwareKeyboard.instance.isShiftPressed) {
        anchorRow = row;
        anchorColumn = column;
      }
      endRow = row;
      endColumn = column;
      input.text = cells[anchorRow][anchorColumn];
      input.selection = TextSelection(
        baseOffset: 0,
        extentOffset: input.text.length,
      );
    });
    if (edit) inputFocus.requestFocus();
  }

  void fill(String value) {
    setState(() {
      for (var row = top; row <= bottom; row++) {
        for (var column = left; column <= right; column++) {
          cells[row][column] = value;
        }
      }
    });
  }

  Future<void> copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: [
          for (var row = top; row <= bottom; row++)
            cells[row].sublist(left, right + 1).join('\t'),
        ].join('\n'),
      ),
    );
  }

  Future<void> paste() async {
    final rowStart = top, columnStart = left;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    final lines = data!.text!.replaceAll('\r\n', '\n').split('\n');
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    final values = [for (final line in lines) line.split('\t')];
    if (values.length == 1 && values.first.length == 1) {
      input.text = values.first.first;
      fill(input.text);
      return;
    }
    final width = math.min(
      8,
      columnStart + values.fold<int>(1, (v, r) => math.max(v, r.length)),
    );
    setState(() {
      while (cells.length < math.min(20, rowStart + values.length)) {
        cells.add(List.filled(cells.first.length, ''));
      }
      for (final row in cells) {
        while (row.length < width) {
          row.add('');
        }
      }
      for (var r = 0; r < values.length && rowStart + r < cells.length; r++) {
        for (var c = 0; c < values[r].length && columnStart + c < width; c++) {
          cells[rowStart + r][columnStart + c] = values[r][c].substring(
            0,
            math.min(2000, values[r][c].length),
          );
        }
      }
      input.text = cells[anchorRow][anchorColumn];
    });
  }

  void action(String value) {
    if (value == 'row' && cells.length >= 20 ||
        value == 'column' && cells.first.length >= 8 ||
        value == 'deleteRows' && bottom - top + 1 >= cells.length ||
        value == 'deleteColumns' && right - left + 1 >= cells.first.length) {
      return;
    }
    if (value == 'copy') {
      copy();
      return;
    }
    if (value == 'paste') {
      paste();
      return;
    }
    if (value == 'clear') {
      input.clear();
      fill('');
      return;
    }
    setState(() {
      if (value == 'row') {
        cells.insert(bottom + 1, List.filled(cells.first.length, ''));
      }
      if (value == 'column') {
        final at = right + 1;
        for (final row in cells) {
          row.insert(at, '');
        }
      }
      if (value == 'deleteRows') cells.removeRange(top, bottom + 1);
      if (value == 'deleteColumns') {
        final from = left, to = right + 1;
        for (final row in cells) {
          row.removeRange(from, to);
        }
      }
      anchorRow = math.min(anchorRow, cells.length - 1);
      anchorColumn = math.min(anchorColumn, cells.first.length - 1);
      endRow = anchorRow;
      endColumn = anchorColumn;
      input.text = cells[anchorRow][anchorColumn];
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    Widget header(String label, VoidCallback onTap) => InkWell(
      onTap: onTap,
      child: SizedBox(height: 36, child: Center(child: Text(label))),
    );
    Widget axisButtons({required bool rows}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: rows ? 'Add row' : 'Add column',
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            side: BorderSide(color: color.outline.withValues(alpha: 0.4)),
          ),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          onPressed: (rows ? cells.length < 20 : cells.first.length < 8)
              ? () => action(rows ? 'row' : 'column')
              : null,
          icon: const Icon(Icons.add, size: 20),
        ),
        IconButton(
          tooltip: rows ? 'Delete rows' : 'Delete columns',
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            side: BorderSide(color: color.outline.withValues(alpha: 0.4)),
          ),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          onPressed:
              (rows
                  ? bottom - top + 1 < cells.length
                  : right - left + 1 < cells.first.length)
              ? () => action(rows ? 'deleteRows' : 'deleteColumns')
              : null,
          icon: const Icon(Icons.remove, size: 20),
        ),
      ],
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
      title: Row(
        children: [
          const Expanded(child: Text('Table')),
          IconButton(
            tooltip: 'Select range',
            isSelected: rangeMode,
            onPressed: () => setState(() => rangeMode = !rangeMode),
            icon: const Icon(Icons.select_all),
          ),
          PopupMenuButton<String>(
            tooltip: 'Table actions',
            onSelected: action,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('Copy')),
              const PopupMenuItem(value: 'paste', child: Text('Paste')),
              const PopupMenuItem(value: 'clear', child: Text('Clear cells')),
            ],
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        width: 680,
        height: (available - 180).clamp(100.0, 440.0),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    selection,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('table-cell-input'),
                    controller: input,
                    focusNode: inputFocus,
                    maxLength: 2000,
                    maxLines: 1,
                    decoration: const InputDecoration(
                      counterText: '',
                      isDense: true,
                    ),
                    onChanged: fill,
                    onSubmitted: (_) => select(
                      math.min(endRow + 1, cells.length - 1),
                      endColumn,
                      edit: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: 80 + cells.first.length * 132 + 80,
                    child: Table(
                      columnWidths: {
                        0: const FixedColumnWidth(80),
                        cells.first.length + 1: const FixedColumnWidth(80),
                      },
                      border: TableBorder.all(
                        color: color.outline.withValues(alpha: 0.4),
                      ),
                      defaultColumnWidth: const FixedColumnWidth(132),
                      children: [
                        TableRow(
                          children: [
                            header(
                              '',
                              () => setState(() {
                                anchorRow = anchorColumn = 0;
                                endRow = cells.length - 1;
                                endColumn = cells.first.length - 1;
                                input.text = cells[0][0];
                              }),
                            ),
                            for (var c = 0; c < cells.first.length; c++)
                              header(String.fromCharCode(65 + c), () {
                                select(0, c);
                                setState(() {
                                  anchorRow = 0;
                                  anchorColumn = c;
                                  endRow = cells.length - 1;
                                  endColumn = c;
                                });
                              }),
                            axisButtons(rows: false),
                          ],
                        ),
                        for (var r = 0; r < cells.length; r++)
                          TableRow(
                            children: [
                              header('${r + 1}', () {
                                select(r, 0);
                                setState(() {
                                  anchorRow = r;
                                  anchorColumn = 0;
                                  endRow = r;
                                  endColumn = cells.first.length - 1;
                                });
                              }),
                              for (var c = 0; c < cells[r].length; c++)
                                Semantics(
                                  selected:
                                      r >= top &&
                                      r <= bottom &&
                                      c >= left &&
                                      c <= right,
                                  label: address(r, c),
                                  child: GestureDetector(
                                    key: ValueKey('table-cell-$r-$c'),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      final now = DateTime.now();
                                      final edit =
                                          lastTappedCell == (r, c) &&
                                          lastCellTapAt != null &&
                                          now.difference(lastCellTapAt!) <
                                              const Duration(milliseconds: 350);
                                      lastTappedCell = (r, c);
                                      lastCellTapAt = now;
                                      select(r, c, edit: edit);
                                    },
                                    onLongPress: () {
                                      select(r, c);
                                      setState(() => rangeMode = true);
                                    },
                                    child: Container(
                                      height: 48,
                                      alignment: Alignment.centerLeft,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            r >= top &&
                                                r <= bottom &&
                                                c >= left &&
                                                c <= right
                                            ? color.primary.withValues(
                                                alpha: 0.18,
                                              )
                                            : color.surface,
                                        border:
                                            r == anchorRow && c == anchorColumn
                                            ? Border.all(
                                                color: color.primary,
                                                width: 2,
                                              )
                                            : null,
                                      ),
                                      child: Text(
                                        cells[r][c],
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 48),
                            ],
                          ),
                        TableRow(
                          children: [
                            axisButtons(rows: true),
                            for (var c = 0; c <= cells.first.length; c++)
                              const SizedBox(height: 40),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, cells),
          child: Text(widget.initial == null ? 'Insert' : 'Save'),
        ),
      ],
    );
  }
}
