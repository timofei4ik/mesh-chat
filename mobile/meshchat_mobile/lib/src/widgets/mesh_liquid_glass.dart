import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/platform_capabilities.dart';

typedef MeshGlassFallbackBuilder =
    Widget Function(BuildContext context, Widget child);

class MeshPlatformScope extends InheritedWidget {
  const MeshPlatformScope({
    super.key,
    required this.capabilities,
    required super.child,
  });

  final MeshPlatformCapabilities capabilities;

  static MeshPlatformCapabilities of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MeshPlatformScope>()
            ?.capabilities ??
        MeshPlatformCapabilities.standard;
  }

  static bool liquidGlassOf(BuildContext context) {
    return of(context).liquidGlassEnabled;
  }

  @override
  bool updateShouldNotify(MeshPlatformScope oldWidget) {
    return oldWidget.capabilities.iosMajorVersion !=
            capabilities.iosMajorVersion ||
        oldWidget.capabilities.reduceTransparency !=
            capabilities.reduceTransparency;
  }
}

class MeshLiquidGlass extends StatelessWidget {
  const MeshLiquidGlass({
    super.key,
    required this.child,
    required this.accent,
    this.radius = 22,
    this.selected = false,
    this.dim = false,
    this.prominent = false,
    this.interactive = true,
    this.fallbackBuilder,
  });

  static const viewType = 'meshchat/liquid_glass';

  final Widget child;
  final Color accent;
  final double radius;
  final bool selected;
  final bool dim;
  final bool prominent;
  final bool interactive;
  final MeshGlassFallbackBuilder? fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    if (!MeshPlatformScope.liquidGlassOf(context)) {
      return fallbackBuilder?.call(context, child) ?? child;
    }

    final darkBase = dim
        ? const Color(0xFF101925)
        : prominent
        ? const Color(0xFF162333)
        : const Color(0xFF131F2D);
    final tintStrength = selected
        ? 0.22
        : prominent
        ? 0.16
        : 0.10;
    // UIGlassEffect expects a translucent accent. An opaque, pre-blended tint
    // makes the native material look like an ordinary Flutter panel.
    final nativeTint = accent.withValues(alpha: tintStrength);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.26),
            blurRadius: prominent ? 26 : 18,
            offset: const Offset(0, 10),
          ),
          if (selected || prominent)
            BoxShadow(
              color: accent.withValues(alpha: selected ? 0.20 : 0.12),
              blurRadius: selected ? 22 : 28,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: UiKitView(
                  viewType: viewType,
                  layoutDirection: Directionality.of(context),
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  creationParams: <String, Object?>{
                    'tint': nativeTint.toARGB32(),
                    'radius': radius,
                    'interactive': interactive,
                  },
                  creationParamsCodec: const StandardMessageCodec(),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: darkBase.withValues(
                    alpha: dim
                        ? 0.018
                        : prominent
                        ? 0.038
                        : 0.026,
                  ),
                ),
              ),
            ),
            child,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LiquidGlassRimPainter(
                    radius: radius,
                    accent: accent,
                    selected: selected,
                    prominent: prominent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiquidGlassRimPainter extends CustomPainter {
  const _LiquidGlassRimPainter({
    required this.radius,
    required this.accent,
    required this.selected,
    required this.prominent,
  });

  final double radius;
  final Color accent;
  final bool selected;
  final bool prominent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final safeRadius = radius.clamp(0.0, size.shortestSide / 2);
    final border = RRect.fromRectAndRadius(
      rect.deflate(0.75),
      Radius.circular(safeRadius),
    );
    canvas.drawRRect(
      border,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..color = Colors.white.withValues(
          alpha: selected || prominent ? 0.20 : 0.15,
        ),
    );

    final inset = mathMin(2.0, size.shortestSide / 8);
    final highlightRect = Rect.fromLTWH(
      inset,
      inset,
      mathMax(0, size.width - inset * 2),
      mathMax(0, size.height - inset * 2),
    );
    final highlightRadius = mathMax(0, safeRadius - inset);
    final topLeft = Path()
      ..moveTo(highlightRect.left, highlightRect.center.dy)
      ..lineTo(highlightRect.left, highlightRect.top + highlightRadius)
      ..quadraticBezierTo(
        highlightRect.left,
        highlightRect.top,
        highlightRect.left + highlightRadius,
        highlightRect.top,
      )
      ..lineTo(highlightRect.center.dx, highlightRect.top);
    canvas.drawPath(
      topLeft,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.1
        ..color = Colors.white.withValues(alpha: 0.22),
    );

    final bottomRight = Path()
      ..moveTo(highlightRect.right, highlightRect.center.dy)
      ..lineTo(highlightRect.right, highlightRect.bottom - highlightRadius)
      ..quadraticBezierTo(
        highlightRect.right,
        highlightRect.bottom,
        highlightRect.right - highlightRadius,
        highlightRect.bottom,
      )
      ..lineTo(highlightRect.center.dx, highlightRect.bottom);
    canvas.drawPath(
      bottomRight,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.0
        ..color = accent.withValues(alpha: selected || prominent ? 0.22 : 0.12),
    );
  }

  double mathMin(double a, double b) => a < b ? a : b;
  double mathMax(double a, double b) => a > b ? a : b;

  @override
  bool shouldRepaint(_LiquidGlassRimPainter oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.accent != accent ||
        oldDelegate.selected != selected ||
        oldDelegate.prominent != prominent;
  }
}
