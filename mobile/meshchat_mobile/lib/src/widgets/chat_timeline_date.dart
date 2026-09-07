import 'dart:async';

import 'package:flutter/material.dart';

/// Tracks only mounted rows, including variable-height media and albums.
class ChatTimelineDate extends StatefulWidget {
  const ChatTimelineDate({super.key, required this.child, required this.label});

  final Widget child;
  final String Function(DateTime) label;

  @override
  State<ChatTimelineDate> createState() => _ChatTimelineDateState();
}

class _ChatTimelineDateState extends State<ChatTimelineDate> {
  final rows = <_ChatDateAnchorState>{};
  final date = ValueNotifier<DateTime?>(null);
  Timer? hideTimer;
  bool scheduled = false;

  void update() {
    if (scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (!mounted) return;
      final viewport = context.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      DateTime? first;
      double top = double.infinity;
      for (final row in rows) {
        final box = row.context.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
        if (y + box.size.height > 0 && y < viewport.size.height && y < top) {
          top = y;
          first = row.widget.date;
        }
      }
      date.value = first;
    });
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _DateScope(
    owner: this,
    child: NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.depth != 0) return false;
        if (event is ScrollUpdateNotification ||
            event is ScrollStartNotification) {
          hideTimer?.cancel();
          update();
        }
        if (event is ScrollEndNotification) {
          hideTimer?.cancel();
          hideTimer = Timer(const Duration(milliseconds: 950), () {
            if (mounted) date.value = null;
          });
        }
        return false;
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ValueListenableBuilder<DateTime?>(
                valueListenable: date,
                builder: (context, value, _) => AnimatedOpacity(
                  opacity: value == null ? 0 : 1,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xEB1C2932),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        value == null ? '' : widget.label(value),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DateScope extends InheritedWidget {
  const _DateScope({required this.owner, required super.child});
  final _ChatTimelineDateState owner;
  @override
  bool updateShouldNotify(_DateScope oldWidget) => owner != oldWidget.owner;
}

class ChatDateAnchor extends StatefulWidget {
  const ChatDateAnchor({super.key, required this.date, required this.child});
  final DateTime date;
  final Widget child;
  @override
  State<ChatDateAnchor> createState() => _ChatDateAnchorState();
}

class _ChatDateAnchorState extends State<ChatDateAnchor> {
  _ChatTimelineDateState? owner;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    owner?.rows.remove(this);
    owner = context.dependOnInheritedWidgetOfExactType<_DateScope>()?.owner;
    owner?.rows.add(this);
  }

  @override
  void dispose() {
    owner?.rows.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
