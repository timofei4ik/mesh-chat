import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/platform_capabilities.dart';
import '../utils/mesh_page_route.dart';
import 'mesh_performance_scope.dart';

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

/// Covered screens stay on Flutter's canvas, below the moving foreground page.
class MeshGlassCompositionScope extends InheritedWidget {
  const MeshGlassCompositionScope({
    super.key,
    required this.nativeAllowed,
    required super.child,
  });

  final bool nativeAllowed;

  static bool nativeAllowedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MeshGlassCompositionScope>()
          ?.nativeAllowed ??
      true;

  @override
  bool updateShouldNotify(MeshGlassCompositionScope oldWidget) =>
      oldWidget.nativeAllowed != nativeAllowed;
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
    this.forceFlutterSurface = false,
    this.fallbackBuilder,
  }) : _matteNavigation = false;

  /// Navigation keeps one compositor during both completed and cancelled swipes.
  const MeshLiquidGlass.navigation({
    super.key,
    required this.child,
    required this.accent,
    this.radius = 22,
    this.selected = false,
    this.dim = false,
    this.prominent = false,
    this.interactive = true,
  }) : forceFlutterSurface = true,
       fallbackBuilder = null,
       _matteNavigation = true;

  static const viewType = 'meshchat/liquid_glass';

  final Widget child;
  final Color accent;
  final double radius;
  final bool selected;
  final bool dim;
  final bool prominent;
  final bool interactive;
  final bool forceFlutterSurface;
  final MeshGlassFallbackBuilder? fallbackBuilder;
  final bool _matteNavigation;

  @override
  Widget build(BuildContext context) {
    if (MeshPerformanceScope.lowEndDeviceModeOf(context)) {
      return _lowEndSurface(context);
    }
    if (!MeshPlatformScope.liquidGlassOf(context)) {
      return fallbackBuilder?.call(context, child) ?? child;
    }

    // A UIKit platform view composed over a fast scrolling Flutter texture
    // forces both renderers to synchronize every frame. Chat screens use a
    // matching Flutter surface so scrolling and interactive routes stay on a
    // single GPU composition path; static iOS screens retain native glass.
    if (forceFlutterSurface ||
        !MeshGlassCompositionScope.nativeAllowedOf(context)) {
      return _staticTransitionSurface(context);
    }

    return ValueListenableBuilder<bool>(
      valueListenable: MeshRouteTransition.active,
      builder: (context, transitioning, _) {
        // Do not cross-fade a UIKit platform view during a route transition.
        // Keeping both renderers alive forces an expensive texture sync on
        // every iOS frame and makes an otherwise cheap slide visibly stutter.
        return transitioning
            ? _routeTransitionSurface(context)
            : _revealedNativeGlass(context);
      },
    );
  }

  Widget _lowEndSurface(BuildContext context) {
    final tint = selected
        ? 0.18
        : prominent
        ? 0.13
        : dim
        ? 0.045
        : 0.08;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            accent.withValues(alpha: tint),
            const Color(0xFF172231),
          ),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Colors.white.withValues(alpha: selected ? 0.18 : 0.10),
          ),
        ),
        child: child,
      ),
    );
  }

  Widget _routeTransitionSurface(BuildContext context) =>
      _staticTransitionSurface(context);

  Widget _revealedNativeGlass(BuildContext context) => _nativeGlass(context);

  Widget _staticTransitionSurface(BuildContext context) {
    final surfaceColor = _matteNavigation
        ? Color.alphaBlend(
            accent.withValues(alpha: selected ? 0.14 : 0.025),
            const Color(0xFF20303D),
          ).withValues(alpha: selected ? 0.96 : 0.93)
        : const Color(0xFF101A23).withValues(alpha: prominent ? 0.78 : 0.72);
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
          color: surfaceColor,
          border: Border.all(
            color: _matteNavigation && selected
                ? accent.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: selected ? 0.22 : 0.13),
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
              child: ColoredBox(color: Colors.white.withValues(alpha: 0.16)),
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
                  'shade': dim ? 0.30 : 0.24,
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
