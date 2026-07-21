import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/platform_capabilities.dart';
import '../utils/mesh_page_route.dart';

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

    return ValueListenableBuilder<bool>(
      valueListenable: MeshRouteTransition.active,
      builder: (context, transitioning, _) {
        if (transitioning) return _staticTransitionSurface(context);
        return _nativeGlass(context);
      },
    );
  }

  Widget _staticTransitionSurface(BuildContext context) {
    final baseAlpha = selected
        ? 0.22
        : prominent
        ? 0.18
        : dim
        ? 0.08
        : 0.12;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF111A29).withValues(alpha: 0.78),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Colors.white.withValues(alpha: prominent ? 0.14 : 0.10),
              accent.withValues(alpha: baseAlpha * 0.48),
              const Color(0xFF111A29).withValues(alpha: 0.54),
            ],
            stops: const <double>[0, 0.46, 1],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: selected ? 0.24 : 0.17),
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: accent.withValues(alpha: baseAlpha * 0.22),
              blurRadius: prominent ? 18 : 12,
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            Positioned(
              left: radius * 0.42,
              right: radius * 0.42,
              top: 0,
              height: 1,
              child: ColoredBox(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _nativeGlass(BuildContext context) {
    final tintStrength = selected
        ? 0.16
        : prominent
        ? 0.12
        : dim
        ? 0.035
        : 0.06;
    // UIGlassEffect expects a translucent accent. An opaque, pre-blended tint
    // makes the native material look like an ordinary Flutter panel.
    final nativeTint = accent.withValues(alpha: tintStrength);

    return ClipRRect(
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
          child,
        ],
      ),
    );
  }
}
