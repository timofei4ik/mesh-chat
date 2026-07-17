import 'dart:math' as math;

import 'package:flutter/material.dart';

class MessageSendEffect extends StatefulWidget {
  const MessageSendEffect({
    super.key,
    required this.messageId,
    required this.effect,
    required this.enabled,
    required this.child,
  });

  final String messageId;
  final String effect;
  final bool enabled;
  final Widget child;

  @override
  State<MessageSendEffect> createState() => _MessageSendEffectState();
}

class _MessageSendEffectState extends State<MessageSendEffect>
    with SingleTickerProviderStateMixin {
  static final Set<String> _played = <String>{};

  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 920),
  );

  bool get shouldPlay {
    if (!widget.enabled || widget.effect == 'none') return false;
    return _played.add(widget.messageId);
  }

  @override
  void initState() {
    super.initState();
    if (shouldPlay) controller.forward();
  }

  @override
  void didUpdateWidget(covariant MessageSendEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.messageId != widget.messageId ||
            oldWidget.effect != widget.effect ||
            oldWidget.enabled != widget.enabled) &&
        shouldPlay) {
      controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        child: widget.child,
        builder: (context, child) {
          return CustomPaint(
            foregroundPainter: controller.value > 0 && controller.value < 1
                ? _MessageEffectPainter(
                    effect: widget.effect,
                    progress: Curves.easeOutCubic.transform(controller.value),
                  )
                : null,
            child: child,
          );
        },
      ),
    );
  }
}

class _MessageEffectPainter extends CustomPainter {
  const _MessageEffectPainter({required this.effect, required this.progress});

  final String effect;
  final double progress;

  static const cyan = Color(0xFF42D9FF);
  static const violet = Color(0xFFA56BFF);

  @override
  void paint(Canvas canvas, Size size) {
    final fade = math.sin(progress * math.pi).clamp(0.0, 1.0);
    switch (effect) {
      case 'ember':
        _paintEmber(canvas, size, fade);
      case 'sunset':
        _paintWave(canvas, size, fade, const Color(0xFFFF7BB6), violet);
      case 'frost':
        _paintFrost(canvas, size, fade);
      case 'orbit':
        _paintOrbit(canvas, size, fade);
      default:
        _paintStardust(canvas, size, fade);
    }
  }

  void _paintStardust(Canvas canvas, Size size, double fade) {
    for (var i = 0; i < 9; i++) {
      final angle = i * math.pi * 2 / 9 + 0.35;
      final travel = (12 + (i % 3) * 7) * progress;
      final center =
          size.center(Offset.zero) +
          Offset(math.cos(angle) * travel, math.sin(angle) * travel);
      _sparkle(
        canvas,
        center,
        i.isEven ? cyan : Colors.white,
        (2.1 + i % 2) * fade,
      );
    }
  }

  void _paintEmber(Canvas canvas, Size size, double fade) {
    final glowRect = Rect.fromCenter(
      center: Offset(size.width * 0.55, size.height * 0.72),
      width: size.width * 0.9,
      height: size.height * 1.2,
    );
    canvas.drawOval(
      glowRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFF774E).withValues(alpha: 0.20 * fade),
            Colors.transparent,
          ],
        ).createShader(glowRect),
    );
    final paint = Paint()
      ..color = const Color(0xFFFFB05F).withValues(alpha: 0.9 * fade);
    for (var i = 0; i < 7; i++) {
      final x = size.width * (0.16 + i * 0.115);
      final y = size.height * 0.82 - progress * (13 + i % 3 * 6);
      canvas.drawCircle(Offset(x, y), i.isEven ? 1.5 : 1, paint);
    }
  }

  void _paintWave(
    Canvas canvas,
    Size size,
    double fade,
    Color start,
    Color end,
  ) {
    final path = Path();
    for (var i = 0; i <= 22; i++) {
      final x = size.width * i / 22;
      final y =
          size.height * 0.58 +
          math.sin(i * 0.62 - progress * math.pi * 4) * 5 * fade;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..shader = LinearGradient(
          colors: [
            start.withValues(alpha: fade),
            end.withValues(alpha: fade),
          ],
        ).createShader(Offset.zero & size),
    );
  }

  void _paintFrost(Canvas canvas, Size size, double fade) {
    final paint = Paint()
      ..color = const Color(0xFFC8F5FF).withValues(alpha: 0.9 * fade)
      ..strokeWidth = 1;
    for (var i = 0; i < 7; i++) {
      final center = Offset(
        size.width * (0.12 + i * 0.13),
        size.height * (0.30 + (i % 3) * 0.18),
      );
      final radius = 2 + progress * 3;
      canvas.drawLine(
        center - Offset(radius, 0),
        center + Offset(radius, 0),
        paint,
      );
      canvas.drawLine(
        center - Offset(0, radius),
        center + Offset(0, radius),
        paint,
      );
    }
  }

  void _paintOrbit(Canvas canvas, Size size, double fade) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCenter(
      center: center,
      width: size.width * (0.70 + progress * 0.28),
      height: size.height * (0.55 + progress * 0.25),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..shader = LinearGradient(
          colors: [
            cyan.withValues(alpha: fade),
            violet.withValues(alpha: fade),
          ],
        ).createShader(rect),
    );
  }

  void _sparkle(Canvas canvas, Offset center, Color color, double radius) {
    if (radius <= 0) return;
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius * 0.28, center.dy - radius * 0.28)
      ..lineTo(center.dx + radius, center.dy)
      ..lineTo(center.dx + radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx, center.dy + radius)
      ..lineTo(center.dx - radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx - radius, center.dy)
      ..lineTo(center.dx - radius * 0.28, center.dy - radius * 0.28)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _MessageEffectPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.effect != effect;
  }
}
