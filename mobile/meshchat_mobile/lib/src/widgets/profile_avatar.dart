import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'mesh_frame_clock.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.profile,
    this.radius = 24,
    this.animateDecoration,
    this.squareProgress = 0,
  });

  final Profile profile;
  final double radius;
  final bool? animateDecoration;
  final double squareProgress;

  static final Map<String, MemoryImage> _imageCache = {};

  @override
  Widget build(BuildContext context) {
    final image = _avatarImage(profile.avatarData);
    final decoration = profile.effectiveAvatarDecoration;
    final decorated =
        decoration != Profile.defaultAvatarDecoration && radius >= 16;
    final morph = squareProgress.clamp(0.0, 1.0);
    final avatarRadius = decorated ? radius * (0.79 + 0.21 * morph) : radius;
    final cornerRadius = avatarRadius + (18 - avatarRadius) * morph;
    final avatar = SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: avatarRadius * 2,
            height: avatarRadius * 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF315A7D),
                borderRadius: BorderRadius.circular(cornerRadius),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cornerRadius),
                child: image == null
                    ? Center(
                        child: Text(
                          _initials(profile.displayName),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: avatarRadius * 0.58,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : Image(
                        image: image,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
              ),
            ),
          ),
          if (decorated)
            Positioned.fill(
              child: Opacity(
                opacity: 1 - morph,
                child: _AnimatedAvatarDecoration(
                  style: decoration,
                  animate: animateDecoration ?? radius >= 40,
                ),
              ),
            ),
        ],
      ),
    );
    // Large morphing avatars create a sizeable retained GPU layer. Keeping
    // that layer alive while the profile route closes can leave a stale frame
    // over the chat until another window or scroll repaint occurs.
    if (radius > 96 || morph > 0.02) return avatar;
    return RepaintBoundary(child: avatar);
  }

  static MemoryImage? _avatarImage(String value) {
    if (value.isEmpty) return null;
    final cached = _imageCache[value];
    if (cached != null) return cached;
    final bytes = _avatarBytes(value);
    if (bytes == null) return null;
    if (_imageCache.length > 80) _imageCache.clear();
    return _imageCache[value] = MemoryImage(bytes);
  }

  static Uint8List? _avatarBytes(String value) {
    if (value.isEmpty) return null;
    final comma = value.indexOf(',');
    final raw = comma >= 0 ? value.substring(comma + 1) : value;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final result = parts
        .take(2)
        .where((part) => part.isNotEmpty)
        .map((part) => part.characters.first.toUpperCase())
        .join();
    return result.isEmpty ? '?' : result;
  }
}

class _AnimatedAvatarDecoration extends StatefulWidget {
  const _AnimatedAvatarDecoration({required this.style, required this.animate});

  final String style;
  final bool animate;

  @override
  State<_AnimatedAvatarDecoration> createState() =>
      _AnimatedAvatarDecorationState();
}

class _AnimatedAvatarDecorationState extends State<_AnimatedAvatarDecoration>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  Timer? activationTimer;
  bool activationReady = false;
  AppLifecycleState lifecycleState = AppLifecycleState.resumed;
  bool tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(seconds: 9),
      frameInterval: const Duration(milliseconds: 50),
      value: 0.17,
    );
    activationTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      activationReady = true;
      _syncAnimation();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _AnimatedAvatarDecoration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycleState = state;
    _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.animate &&
        activationReady &&
        tickerEnabled &&
        lifecycleState == AppLifecycleState.resumed;
    if (shouldAnimate) {
      if (!controller.isAnimating) controller.repeat();
    } else if (controller.isAnimating) {
      controller.stop();
    }
  }

  @override
  void dispose() {
    activationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) {
      return IgnorePointer(
        child: CustomPaint(
          painter: _AvatarDecorationPainter(
            style: widget.style,
            progress: 0.17,
          ),
        ),
      );
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) => CustomPaint(
          painter: _AvatarDecorationPainter(
            style: widget.style,
            progress: controller.value,
          ),
        ),
      ),
    );
  }
}

class _AvatarDecorationPainter extends CustomPainter {
  const _AvatarDecorationPainter({required this.style, required this.progress});

  final String style;
  final double progress;

  static const tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    if (shortest <= 0) return;
    final center = size.center(Offset.zero);
    final avatarRadius = shortest * 0.395;
    switch (style) {
      case 'stardust':
        _paintStardust(canvas, center, avatarRadius, shortest);
        return;
      case 'ember':
        _paintEmber(canvas, center, avatarRadius, shortest);
        return;
      case 'sunset_clouds':
        _paintSunsetClouds(canvas, center, avatarRadius, shortest);
        return;
      case 'neon_orbit':
        _paintNeonOrbit(canvas, center, avatarRadius, shortest);
        return;
      case 'frost_bloom':
        _paintFrostBloom(canvas, center, avatarRadius, shortest);
        return;
    }
  }

  void _paintStardust(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    _ring(canvas, center, radius, const Color(0x66EAF7FF), size * 0.012);
    const angles = <double>[
      -2.82,
      -2.47,
      -2.08,
      -1.72,
      -1.34,
      -0.96,
      -0.51,
      0.08,
      0.57,
      1.02,
      1.54,
      2.02,
      2.47,
      2.86,
    ];
    for (var i = 0; i < angles.length; i++) {
      final phase = tau * progress + i * 1.37;
      final pulse = 0.58 + 0.42 * math.sin(phase).abs();
      final orbit = radius * (1.04 + (i % 3) * 0.045);
      final point = center + Offset.fromDirection(angles[i], orbit);
      final starRadius = size * (0.018 + (i % 4) * 0.004) * pulse;
      final color = i % 5 == 0
          ? const Color(0xFFD8F8FF)
          : const Color(0xFFFFFFFF);
      _glow(canvas, point, starRadius * 1.8, color, 0.16 * pulse);
      _star(canvas, point, starRadius, color.withValues(alpha: 0.88 * pulse));
    }
  }

  void _paintEmber(Canvas canvas, Offset center, double radius, double size) {
    _ring(canvas, center, radius, const Color(0x667D231E), size * 0.014);
    for (var i = 0; i < 10; i++) {
      final angle = 0.03 + (math.pi - 0.06) * i / 9;
      final sway = math.sin(tau * progress + i * 0.91) * 0.055;
      final height =
          size *
          (0.075 + (i % 3) * 0.014) *
          (0.88 + 0.12 * math.sin(tau * progress + i));
      final base = center + Offset.fromDirection(angle, radius * 1.01);
      _flame(
        canvas,
        base,
        angle + sway,
        height,
        size * 0.035,
        i.isEven ? const Color(0xFFE64B3C) : const Color(0xFFFF7043),
      );
    }
    for (var i = 0; i < 4; i++) {
      final phase = (progress + i * 0.23) % 1;
      final x = center.dx + math.sin(i * 2.3) * radius * 0.72;
      final y = center.dy + radius * 0.92 - phase * size * 0.19;
      final point = Offset(x, y);
      _glow(canvas, point, size * 0.022, const Color(0xFFFF8A50), 0.2);
      canvas.drawCircle(
        point,
        size * 0.009 * (1 - phase * 0.4),
        Paint()..color = const Color(0xFFFFC06A).withValues(alpha: 1 - phase),
      );
    }
  }

  void _paintSunsetClouds(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    _ring(canvas, center, radius, const Color(0x665E4A8A), size * 0.012);
    final drift = math.sin(tau * progress) * size * 0.018;
    _cloud(
      canvas,
      center + Offset(-radius * 0.66 + drift, -radius * 0.74),
      size,
      const [Color(0xFFB58CFF), Color(0xFFE58ED8), Color(0xFF7A8DFF)],
      0.56,
    );
    _cloud(
      canvas,
      center + Offset(radius * 0.67 - drift, radius * 0.72),
      size * 0.88,
      const [Color(0xFFFF9CC9), Color(0xFF9D73E8), Color(0xFF6EC5E9)],
      0.5,
    );
    final motePhase = (progress * 1.6) % 1;
    final mote = center + Offset(radius * 0.82, -radius * (0.2 + motePhase));
    _glow(canvas, mote, size * 0.025, const Color(0xFFFFC1E8), 0.22);
  }

  void _paintNeonOrbit(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    final rotation = tau * progress;
    final rect = Rect.fromCircle(center: center, radius: radius * 1.06);
    canvas.drawArc(
      rect,
      rotation,
      math.pi * 0.78,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = size * 0.018
        ..color = const Color(0xFF3BD6FF).withValues(alpha: 0.82),
    );
    canvas.drawArc(
      rect,
      rotation + math.pi,
      math.pi * 0.72,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = size * 0.018
        ..color = const Color(0xFFA56BFF).withValues(alpha: 0.82),
    );
    final tiltedRadius = radius * 1.14;
    for (var i = 0; i < 3; i++) {
      final angle = rotation * (i.isEven ? 1 : -1) + i * tau / 3;
      final point = center + Offset.fromDirection(angle, tiltedRadius);
      final color = i.isEven
          ? const Color(0xFF64E6FF)
          : const Color(0xFFB98CFF);
      _glow(canvas, point, size * 0.045, color, 0.24);
      canvas.drawCircle(point, size * 0.017, Paint()..color = color);
    }
  }

  void _paintFrostBloom(
    Canvas canvas,
    Offset center,
    double radius,
    double size,
  ) {
    _ring(canvas, center, radius, const Color(0x668EDFFF), size * 0.012);
    const angles = <double>[-2.72, -2.05, -1.57, -1.08, -0.42, 0.52, 1.18, 2.0];
    for (var i = 0; i < angles.length; i++) {
      final pulse = 0.9 + 0.1 * math.sin(tau * progress + i * 0.7);
      final point = center + Offset.fromDirection(angles[i], radius * 1.02);
      final color = i.isEven
          ? const Color(0xFFB9F4FF)
          : const Color(0xFF82B9FF);
      _crystal(
        canvas,
        point,
        angles[i],
        size * (0.065 + (i % 3) * 0.01) * pulse,
        size * 0.026,
        color,
      );
    }
  }

  void _ring(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double width,
  ) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  void _star(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final angle = -math.pi / 2 + i * math.pi / 4;
      final pointRadius = i.isEven ? radius : radius * 0.28;
      final point = center + Offset.fromDirection(angle, pointRadius);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _flame(
    Canvas canvas,
    Offset base,
    double angle,
    double height,
    double width,
    Color color,
  ) {
    final outward = Offset(math.cos(angle), math.sin(angle));
    final tangent = Offset(-outward.dy, outward.dx);
    final tip = base + outward * height;
    final path = Path()
      ..moveTo((base - tangent * width).dx, (base - tangent * width).dy)
      ..quadraticBezierTo(
        (base + outward * height * 0.34 - tangent * width * 0.15).dx,
        (base + outward * height * 0.34 - tangent * width * 0.15).dy,
        tip.dx,
        tip.dy,
      )
      ..quadraticBezierTo(
        (base + outward * height * 0.3 + tangent * width * 0.55).dx,
        (base + outward * height * 0.3 + tangent * width * 0.55).dy,
        (base + tangent * width).dx,
        (base + tangent * width).dy,
      )
      ..close();
    _glow(canvas, tip, width * 1.4, color, 0.16);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.72));
    canvas.drawCircle(
      base + outward * height * 0.26,
      width * 0.38,
      Paint()..color = const Color(0xFFFFC36A).withValues(alpha: 0.58),
    );
  }

  void _cloud(
    Canvas canvas,
    Offset center,
    double size,
    List<Color> colors,
    double alpha,
  ) {
    final points = <Offset>[
      const Offset(-0.075, 0.008),
      const Offset(-0.035, -0.02),
      const Offset(0.01, -0.034),
      const Offset(0.05, -0.01),
      const Offset(0.082, 0.012),
      const Offset(0.018, 0.025),
    ];
    final radii = <double>[0.045, 0.056, 0.066, 0.052, 0.041, 0.06];
    for (var i = 0; i < points.length; i++) {
      final point = center + points[i] * size;
      final color = colors[i % colors.length].withValues(alpha: alpha);
      _glow(canvas, point, radii[i] * size * 1.25, color, alpha * 0.18);
      canvas.drawCircle(point, radii[i] * size, Paint()..color = color);
    }
  }

  void _crystal(
    Canvas canvas,
    Offset base,
    double angle,
    double height,
    double width,
    Color color,
  ) {
    final outward = Offset(math.cos(angle), math.sin(angle));
    final tangent = Offset(-outward.dy, outward.dx);
    final tip = base + outward * height;
    final path = Path()
      ..moveTo((base - tangent * width).dx, (base - tangent * width).dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo((base + tangent * width).dx, (base + tangent * width).dy)
      ..lineTo(
        (base - outward * height * 0.18).dx,
        (base - outward * height * 0.18).dy,
      )
      ..close();
    _glow(canvas, tip, width * 1.7, color, 0.16);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.68));
    canvas.drawLine(
      base - outward * height * 0.12,
      tip,
      Paint()
        ..strokeWidth = width * 0.28
        ..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  void _glow(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double alpha,
  ) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.65),
    );
  }

  @override
  bool shouldRepaint(covariant _AvatarDecorationPainter oldDelegate) {
    return oldDelegate.style != style || oldDelegate.progress != progress;
  }
}
