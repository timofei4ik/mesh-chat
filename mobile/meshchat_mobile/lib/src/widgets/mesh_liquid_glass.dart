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
