import 'dart:ui';

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
    this.forceFlutterSurface = false,
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
  final bool forceFlutterSurface;
  final MeshGlassFallbackBuilder? fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    if (!MeshPlatformScope.liquidGlassOf(context)) {
      return fallbackBuilder?.call(context, child) ?? child;
    }

    // A UIKit platform view composed over a fast scrolling Flutter texture
    // forces both renderers to synchronize every frame. Chat screens use a
    // matching Flutter surface so scrolling and interactive routes stay on a
    // single GPU composition path; static iOS screens retain native glass.
    if (forceFlutterSurface) {
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

  Widget _routeTransitionSurface(BuildContext context) {
    final tintAlpha = selected
        ? 0.19
        : prominent
        ? 0.15
        : dim
        ? 0.055
        : 0.09;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: const Color(0xFF172231).withValues(alpha: 0.32),
            border: Border.all(
              color: Colors.white.withValues(alpha: selected ? 0.24 : 0.15),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: accent.withValues(alpha: tintAlpha),
                blurRadius: prominent ? 19 : 14,
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              Positioned(
                left: radius * 0.35,
                right: radius * 0.35,
                top: 0,
                height: 1,
                child: ColoredBox(color: Colors.white.withValues(alpha: 0.22)),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _revealedNativeGlass(BuildContext context) {
    return _MeshNativeGlassReveal(
      fallback: _routeTransitionSurface(context),
      child: _nativeGlass(context),
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
          color: const Color(
            0xFF172231,
          ).withValues(alpha: prominent ? 0.66 : 0.58),
          border: Border.all(
            color: Colors.white.withValues(alpha: selected ? 0.22 : 0.13),
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

class _MeshNativeGlassReveal extends StatefulWidget {
  const _MeshNativeGlassReveal({required this.fallback, required this.child});

  final Widget fallback;
  final Widget child;

  @override
  State<_MeshNativeGlassReveal> createState() => _MeshNativeGlassRevealState();
}

class _MeshNativeGlassRevealState extends State<_MeshNativeGlassReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  )..forward();
  late final Animation<double> opacity = CurvedAnimation(
    parent: controller,
    curve: Curves.easeOutCubic,
  );
  bool complete = false;

  @override
  void initState() {
    super.initState();
    controller.addStatusListener(handleStatus);
  }

  void handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() => complete = true);
  }

  @override
  void dispose() {
    controller.removeStatusListener(handleStatus);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (complete) return widget.child;
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        widget.fallback,
        FadeTransition(opacity: opacity, child: widget.child),
      ],
    );
  }
}
