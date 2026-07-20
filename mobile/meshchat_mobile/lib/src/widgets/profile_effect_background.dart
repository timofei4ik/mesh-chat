import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'mesh_frame_clock.dart';

@visibleForTesting
double profileEffectPulse(double animationValue) {
  final phase = (animationValue.clamp(0.0, 1.0) * 3) % 1;
  final linear = phase <= 0.5 ? phase * 2 : (1 - phase) * 2;
  return linear * linear * (3 - 2 * linear);
}

class ProfileEffectBackground extends StatefulWidget {
  const ProfileEffectBackground({
    super.key,
    required this.profile,
    this.enabled = true,
    this.highRefreshRate = false,
  });

  final Profile profile;
  final bool enabled;
  final bool highRefreshRate;

  @override
  State<ProfileEffectBackground> createState() =>
      _ProfileEffectBackgroundState();
}

class _ProfileEffectBackgroundState extends State<ProfileEffectBackground>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  bool appActive = true;
  bool tickerModeActive = true;

  bool get canAnimate => widget.enabled && appActive && tickerModeActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(milliseconds: 13500),
      frameInterval: widget.highRefreshRate
          ? const Duration(milliseconds: 16)
          : const Duration(milliseconds: 66),
    );
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      if (mounted && canAnimate) controller.repeat();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.valuesOf(context).enabled;
    if (tickerModeActive == next) return;
    tickerModeActive = next;
    _syncAnimationActivity();
  }

  @override
  void didUpdateWidget(covariant ProfileEffectBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _syncAnimationActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;
    _syncAnimationActivity();
  }

  void _syncAnimationActivity() {
    if (!canAnimate) {
      controller.stop(canceled: false);
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0, 0.18, 0.88, 1],
          ).createShader(bounds),
          child: CustomPaint(
            isComplex: true,
            willChange: widget.enabled,
            painter: _ProfileEffectPainter(
              animation: controller,
              seed: 4,
              background: widget.profile.effectiveProfileBanner,
              effect: widget.enabled
                  ? widget.profile.effectiveProfileEffect
                  : 'none',
              blinkShape: widget.profile.effectiveProfileBlinkShape,
              accent: Color(widget.profile.effectiveProfileAccent),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileEffectPainter extends CustomPainter {
  _ProfileEffectPainter({
    required this.animation,
    required this.seed,
    required this.background,
    required this.effect,
    required this.blinkShape,
    required this.accent,
  }) : super(repaint: animation);

  final MeshFrameClock animation;
  final int seed;
  final String background;
  final String effect;
  final String blinkShape;
  final Color accent;

  double get t => animation.value;

  static const violet = Color(0xFFA56BFF);
  static const cyan = Color(0xFF3BD6FF);

  @override
  void paint(Canvas canvas, Size size) {
    final baseColor = switch (background) {
      'aurora' => const Color(0xFF0C1C2B),
      'starlight' => const Color(0xFF0C1123),
      'stardust' => const Color(0xFF090F21),
      'ember' => const Color(0xFF1A1118),
      'sunset' => const Color(0xFF151329),
      'frost' => const Color(0xFF0C1A25),
      'orbit' => const Color(0xFF0B1324),
      _ => const Color(0xFF111927),
    };
    canvas.drawRect(Offset.zero & size, Paint()..color = baseColor);
    _paintBackdrop(canvas, size);

    switch (effect) {
      case 'none':
        break;
      case 'stars':
        _paintStars(canvas, size);
      case 'orbit':
        _paintOrbit(canvas, size);
      default:
        _paintNodes(canvas, size);
    }
  }

  void _paintBackdrop(Canvas canvas, Size size) {
    switch (background) {
      case 'stardust':
        final shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF092A45), Color(0xFF16132C), Color(0xFF271534)],
        ).createShader(Offset.zero & size);
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = shader
            ..color = Colors.white.withValues(alpha: 0.62),
        );
      case 'ember':
        final center = Offset(
          size.width * (0.42 + math.sin(t * math.pi * 2) * 0.06),
          size.height * 1.02,
        );
        final rect = Rect.fromCircle(
          center: center,
          radius: math.max(size.width, size.height) * 0.78,
        );
        canvas.drawCircle(
          center,
          rect.width / 2,
          Paint()
            ..shader = const RadialGradient(
              colors: [Color(0x88FF6A3D), Color(0x445E1730), Color(0x001A1118)],
              stops: [0, 0.46, 1],
            ).createShader(rect),
        );
        _paintDriftingSpecks(canvas, size, const Color(0xFFFF8A52), 13);
      case 'sunset':
        final gradient = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF17294A), Color(0xFF3C234E), Color(0xFF6B2F55)],
        ).createShader(Offset.zero & size);
        canvas.drawRect(Offset.zero & size, Paint()..shader = gradient);
        for (var i = 0; i < 4; i++) {
          final dx =
              (0.08 + i * 0.27 + math.sin(t * math.pi * 2 + i) * 0.045) *
              size.width;
          final dy = size.height * (0.20 + i * 0.18);
          final cloud = Rect.fromCenter(
            center: Offset(dx, dy),
            width: size.width * 0.48,
            height: size.height * 0.24,
          );
          canvas.drawOval(
            cloud,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  (i.isEven ? violet : const Color(0xFFFF7BA7)).withValues(
                    alpha: 0.16,
                  ),
                  Colors.transparent,
                ],
              ).createShader(cloud),
          );
        }
      case 'frost':
        final fog = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF18344A), Color(0xFF102532), Color(0xFF0C1823)],
        ).createShader(Offset.zero & size);
        canvas.drawRect(Offset.zero & size, Paint()..shader = fog);
        final mistPaint = Paint()
          ..color = const Color(0xFFBCEBFF).withValues(alpha: 0.075)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(14, size.height * 0.12);
        for (var row = 0; row < 3; row++) {
          final path = Path();
          for (var i = 0; i <= 12; i++) {
            final x = size.width * i / 12;
            final y =
                size.height * (0.25 + row * 0.28) +
                math.sin(i * 0.72 + t * math.pi * 2 + row) * 7;
            if (i == 0) {
              path.moveTo(x, y);
            } else {
              path.lineTo(x, y);
            }
          }
          canvas.drawPath(path, mistPaint);
        }
        _paintDriftingSpecks(canvas, size, const Color(0xFFCBF3FF), 16);
      case 'orbit':
      case 'aurora':
        final colors = <Color>[cyan, accent, violet];
        for (var band = 0; band < 3; band++) {
          final path = Path();
          for (var i = 0; i <= 18; i++) {
            final x = size.width * i / 18;
            final y =
                size.height * (0.28 + band * 0.22) +
                math.sin(i * 0.38 + t * math.pi * 2 + band * 1.4) *
                    size.height *
                    0.08;
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
              ..strokeWidth = math.max(9, size.height * 0.08)
              ..strokeCap = StrokeCap.round
              ..color = colors[band].withValues(alpha: 0.055),
          );
        }
      default:
        break;
    }
  }

  void _paintDriftingSpecks(Canvas canvas, Size size, Color color, int count) {
    final paint = Paint()..color = color.withValues(alpha: 0.22);
    for (var i = 0; i < count; i++) {
      final x = ((i * 43 + seed * 7) % 101) / 100 * size.width;
      final base = ((i * 67 + 13) % 97) / 96;
      final y =
          (base + math.sin(t * math.pi * 2 + i * 0.73) * 0.075) * size.height;
      canvas.drawCircle(Offset(x, y), i % 5 == 0 ? 1.5 : 0.85, paint);
    }
  }

  List<Offset> _networkPoints(Size size) => [
    Offset(size.width * -0.02, size.height * 0.70),
    Offset(size.width * 0.07, size.height * 0.22),
    Offset(size.width * 0.20, size.height * 0.04),
    Offset(size.width * 0.28, size.height * 0.42),
    Offset(size.width * 0.39, size.height * 0.14),
    Offset(size.width * 0.52, size.height * 0.58),
    Offset(size.width * 0.62, size.height * 0.28),
    Offset(size.width * 0.78, size.height * 0.07),
    Offset(size.width * 0.86, size.height * 0.45),
    Offset(size.width * 1.03, size.height * 0.20),
    Offset(size.width * 0.94, size.height * 0.78),
    Offset(size.width * 0.72, size.height * 0.94),
    Offset(size.width * 0.48, size.height * 0.92),
    Offset(size.width * 0.24, size.height * 0.86),
    Offset(size.width * 0.04, size.height * 0.92),
  ];

  double get _pulse => profileEffectPulse(t);

  void _paintNodes(Canvas canvas, Size size) {
    final points = _networkPoints(size);
    final line = Paint()
      ..color = (background == 'aurora' ? accent : Colors.white).withValues(
        alpha: background == 'aurora' ? 0.09 : 0.055,
      )
      ..strokeWidth = 1.05;
    const links = [
      [0, 1],
      [1, 2],
      [2, 4],
      [3, 5],
      [4, 6],
      [5, 8],
      [6, 7],
      [7, 9],
      [8, 10],
      [10, 11],
      [11, 12],
      [12, 13],
      [13, 14],
      [14, 0],
      [1, 5],
      [3, 8],
      [5, 12],
      [6, 10],
      [4, 12],
    ];
    for (final link in links) {
      canvas.drawLine(points[link[0]], points[link[1]], line);
    }

    final dot = Paint()..color = Colors.white.withValues(alpha: 0.14);
    for (final point in points) {
      canvas.drawCircle(point, 2.2, dot);
    }

    for (var i = 0; i < 2; i++) {
      final index = (seed + i * 5) % points.length;
      final color = (seed + i).isEven ? accent : violet;
      _drawBlinkShape(canvas, points[index], color, 5.2, _pulse);
    }
  }

  void _paintStars(Canvas canvas, Size size) {
    final faint = Paint()..color = Colors.white.withValues(alpha: 0.16);
    for (var i = 0; i < 30; i++) {
      final x = ((i * 47 + 19) % 101) / 100 * size.width;
      final y = ((i * 71 + 11) % 97) / 96 * size.height;
      final radius = i % 4 == 0 ? 1.35 : 0.78;
      canvas.drawCircle(Offset(x, y), radius, faint);
    }

    final activeCount = 2 + seed % 2;
    for (var i = 0; i < activeCount; i++) {
      final index = (seed * 7 + i * 11) % 30;
      final center = Offset(
        ((index * 47 + 19) % 101) / 100 * size.width,
        ((index * 71 + 11) % 97) / 96 * size.height,
      );
      final color = (seed + i).isEven ? cyan : violet;
      _drawBlinkShape(canvas, center, color, 5.5 + i, _pulse);
    }
  }

  void _paintOrbit(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final shortest = math.min(size.width, size.height);
    final rings = <Rect>[
      Rect.fromCenter(
        center: center,
        width: math.min(size.width * 0.76, shortest * 2.3),
        height: shortest * 0.62,
      ),
      Rect.fromCenter(
        center: center,
        width: math.min(size.width * 0.92, shortest * 2.8),
        height: shortest * 0.88,
      ),
    ];
    for (var i = 0; i < rings.length; i++) {
      canvas.drawOval(
        rings[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = (i.isEven ? cyan : violet).withValues(alpha: 0.11),
      );
      final angle = seed * 0.72 + t * math.pi * 2 + i * math.pi;
      final point = Offset(
        center.dx + math.cos(angle) * rings[i].width / 2,
        center.dy + math.sin(angle) * rings[i].height / 2,
      );
      _drawBlinkShape(canvas, point, i.isEven ? cyan : violet, 4.8, _pulse);
    }
  }

  void _drawBlinkShape(
    Canvas canvas,
    Offset center,
    Color color,
    double radius,
    double opacity,
  ) {
    switch (blinkShape) {
      case 'star':
        _drawSparkle(canvas, center, color, radius * 1.12, opacity);
      case 'moose':
        _drawMoose(canvas, center, color, radius * 4.1, opacity);
      default:
        _drawGlowDot(
          canvas,
          center,
          color,
          radius * 3.6,
          radius * 0.8,
          opacity,
        );
    }
  }

  void _drawMoose(
    Canvas canvas,
    Offset center,
    Color color,
    double fontSize,
    double opacity,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: '𐂂',
        style: TextStyle(
          color: color.withValues(alpha: 0.94 * opacity),
          fontFamily: 'NotoSansLinearB',
          fontSize: fontSize,
          height: 1,
          shadows: [
            Shadow(
              color: color.withValues(alpha: 0.66 * opacity),
              blurRadius: 13,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _drawGlowDot(
    Canvas canvas,
    Offset center,
    Color color,
    double glowRadius,
    double coreRadius,
    double opacity,
  ) {
    canvas.drawCircle(
      center,
      glowRadius,
      Paint()
        ..color = color.withValues(alpha: 0.34 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    canvas.drawCircle(
      center,
      coreRadius,
      Paint()..color = color.withValues(alpha: 0.86 * opacity),
    );
  }

  void _drawSparkle(
    Canvas canvas,
    Offset center,
    Color color,
    double radius,
    double opacity,
  ) {
    canvas.drawCircle(
      center,
      radius * 3.2,
      Paint()
        ..color = color.withValues(alpha: 0.28 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..quadraticBezierTo(
        center.dx + radius * 0.22,
        center.dy - radius * 0.22,
        center.dx + radius,
        center.dy,
      )
      ..quadraticBezierTo(
        center.dx + radius * 0.22,
        center.dy + radius * 0.22,
        center.dx,
        center.dy + radius,
      )
      ..quadraticBezierTo(
        center.dx - radius * 0.22,
        center.dy + radius * 0.22,
        center.dx - radius,
        center.dy,
      )
      ..quadraticBezierTo(
        center.dx - radius * 0.22,
        center.dy - radius * 0.22,
        center.dx,
        center.dy - radius,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = color.withValues(alpha: 0.92 * opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _ProfileEffectPainter oldDelegate) {
    return oldDelegate.animation != animation ||
        oldDelegate.seed != seed ||
        oldDelegate.background != background ||
        oldDelegate.effect != effect ||
        oldDelegate.blinkShape != blinkShape ||
        oldDelegate.accent != accent;
  }
}
