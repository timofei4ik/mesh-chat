import 'package:flutter/material.dart';

void drawRadialGlow(
  Canvas canvas, {
  required Offset center,
  required double radius,
  required Color color,
  required double opacity,
}) {
  if (radius <= 0 || opacity <= 0) return;
  final bounds = Rect.fromCircle(center: center, radius: radius);
  final shader = RadialGradient(
    colors: [
      color.withValues(alpha: (opacity * 1.15).clamp(0.0, 1.0)),
      color.withValues(alpha: opacity * 0.62),
      color.withValues(alpha: 0),
    ],
    stops: const [0, 0.38, 1],
  ).createShader(bounds);
  canvas.drawCircle(center, radius, Paint()..shader = shader);
}
