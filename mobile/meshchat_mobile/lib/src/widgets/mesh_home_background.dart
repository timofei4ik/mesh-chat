import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'mesh_frame_clock.dart';
import 'mesh_painting.dart';

class MeshHomeBackground extends StatefulWidget {
  const MeshHomeBackground({super.key, required this.enabled});

  final bool enabled;

  @override
  State<MeshHomeBackground> createState() => MeshHomeBackgroundState();
}

class MeshHomeBackgroundState extends State<MeshHomeBackground>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  final double driftPhase = math.Random().nextDouble() * math.pi * 2;
  bool appActive = true;
  bool tickerModeActive = true;

  bool get canAnimate => widget.enabled && appActive && tickerModeActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(seconds: 240),
      frameInterval: const Duration(milliseconds: 33),
    );
    if (canAnimate) controller.repeat();
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
  void didUpdateWidget(covariant MeshHomeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimationActivity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF06101D),
            Color(0xFF071422),
            Color(0xFF111329),
            Color(0xFF07111E),
          ],
          stops: [0, 0.42, 0.72, 1],
        ),
      ),
      child: RepaintBoundary(
        child: CustomPaint(
          isComplex: true,
          willChange: canAnimate,
          painter: _HomeMeshPainter(clock: controller, driftPhase: driftPhase),
        ),
      ),
    );
  }
}

class _HomeMeshPainter extends CustomPainter {
  _HomeMeshPainter({required this.clock, required this.driftPhase})
    : super(repaint: clock);

  final MeshFrameClock clock;
  final double driftPhase;

  @override
  void paint(Canvas canvas, Size size) {
    final phase = clock.value * math.pi * 2 + driftPhase;
    final cyanPulse = 0.78 + 0.22 * math.sin(phase);
    final violetPulse = 0.78 + 0.22 * math.sin(phase + math.pi * 0.75);
    final cyanCenter = Offset(
      size.width *
          (0.18 + 0.045 * math.sin(phase) + 0.01 * math.sin(phase * 3)),
      size.height * (0.14 + 0.04 * math.cos(phase * 2)),
    );
    final violetCenter = Offset(
      size.width * (0.88 + 0.04 * math.cos(phase * 2 + 1)),
      size.height * (0.30 + 0.045 * math.sin(phase + 2)),
    );
    drawRadialGlow(
      canvas,
      center: cyanCenter,
      radius: 330 + 10 * cyanPulse,
      color: const Color(0xFF40CFFF),
      opacity: 0.052 * cyanPulse,
    );
    drawRadialGlow(
      canvas,
      center: violetCenter,
      radius: 390 + 12 * violetPulse,
      color: const Color(0xFF9A6BFF),
      opacity: 0.050 * violetPulse,
    );
    drawRadialGlow(
      canvas,
      center: cyanCenter,
      radius: 74 + 4 * cyanPulse,
      color: const Color(0xFF40CFFF),
      opacity: 0.10 * cyanPulse,
    );
    drawRadialGlow(
      canvas,
      center: violetCenter,
      radius: 82 + 5 * violetPulse,
      color: const Color(0xFF9A6BFF),
      opacity: 0.10 * violetPulse,
    );
    drawRadialGlow(
      canvas,
      center: Offset(
        size.width * (0.55 + 0.025 * math.sin(phase)),
        size.height * 0.92,
      ),
      radius: 410,
      color: const Color(0xFF348DFF),
      opacity: 0.022,
    );
  }

  @override
  bool shouldRepaint(covariant _HomeMeshPainter oldDelegate) {
    return oldDelegate.clock != clock || oldDelegate.driftPhase != driftPhase;
  }
}
