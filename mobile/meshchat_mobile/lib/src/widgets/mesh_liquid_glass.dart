import 'dart:async';
import 'dart:ui' as ui;

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

  /// The selected lens is native; its parent stays on Flutter's canvas so it
  /// cannot cover the unselected labels with another platform view.
  const MeshLiquidGlass.navigation({
    super.key,
    required this.child,
    required this.accent,
    this.radius = 22,
    this.selected = false,
    this.dim = false,
    this.prominent = false,
    this.interactive = true,
  }) : forceFlutterSurface = !selected,
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
    if (forceFlutterSurface) {
      return _staticTransitionSurface(context);
    }

    return ValueListenableBuilder<bool>(
      valueListenable: MeshRouteTransition.active,
      builder: (context, transitioning, _) {
        return _RetainedGlassSurface(
          visible:
              !transitioning &&
              MeshGlassCompositionScope.nativeAllowedOf(context),
          radius: radius,
          tint: accent.withValues(alpha: selected ? 0.10 : 0.06),
          shade: selected ? 0.10 : (dim ? 0.28 : 0.22),
          interactive: interactive,
          fallback: _staticTransitionSurface(context),
          child: child,
        );
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

  Widget _staticTransitionSurface(BuildContext context) {
    final surfaceColor = _matteNavigation
        ? Color.alphaBlend(
            accent.withValues(alpha: selected ? 0.14 : 0.025),
            const Color(0xFF20303D),
          ).withValues(alpha: selected ? 0.86 : 0.72)
        : const Color(0xFF101A23).withValues(alpha: prominent ? 0.78 : 0.72);
    final baseAlpha = selected
        ? 0.22
        : prominent
        ? 0.18
        : dim
        ? 0.08
        : 0.12;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: surfaceColor,
        border: Border.all(
          color: _matteNavigation && selected
              ? accent.withValues(alpha: 0.28)
              : Colors.white.withValues(alpha: _matteNavigation ? 0.22 : 0.13),
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
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: _matteNavigation && !selected
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: surface,
            )
          : surface,
    );
  }
}

class _RetainedGlassSurface extends StatefulWidget {
  const _RetainedGlassSurface({
    required this.visible,
    required this.radius,
    required this.tint,
    required this.shade,
    required this.interactive,
    required this.fallback,
    required this.child,
  });
  final bool visible;
  final double radius;
  final Color tint;
  final double shade;
  final bool interactive;
  final Widget fallback;
  final Widget child;

  @override
  State<_RetainedGlassSurface> createState() => _RetainedGlassSurfaceState();
}

class _RetainedGlassSurfaceState extends State<_RetainedGlassSurface> {
  bool _hasBeenVisible = false;
  MethodChannel? _channel;
  Uint8List? _snapshot;
  Timer? _captureTimer;
  int _generation = 0;

  void _scheduleCapture() {
    _captureTimer?.cancel();
    if (!widget.visible || _channel == null) return;
    final generation = ++_generation;
    _captureTimer = Timer(const Duration(milliseconds: 450), () async {
      try {
        final bytes = await _channel!.invokeMethod<Uint8List>('snapshot');
        if (mounted &&
            widget.visible &&
            generation == _generation &&
            bytes != null &&
            bytes.isNotEmpty) {
          setState(() => _snapshot = bytes);
        }
      } on PlatformException {
        // A snapshot is optional; the native view itself stays mounted.
      } on MissingPluginException {
        // Older native runners can still display glass without snapshots.
      }
    });
  }

  @override
  void didUpdateWidget(_RetainedGlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      ++_generation;
      _scheduleCapture();
    }
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _hasBeenVisible = _hasBeenVisible || widget.visible;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          if (_hasBeenVisible)
            Positioned.fill(
              child: IgnorePointer(
                child: Offstage(
                  offstage: !widget.visible,
                  child: UiKitView(
                    viewType: MeshLiquidGlass.viewType,
                    layoutDirection: Directionality.of(context),
                    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                    creationParams: <String, Object?>{
                      'tint': widget.tint.toARGB32(),
                      'shade': widget.shade,
                      'radius': widget.radius,
                      'interactive': widget.interactive,
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                    onPlatformViewCreated: (id) {
                      _channel = MethodChannel('meshchat/liquid_glass/$id');
                      _scheduleCapture();
                    },
                  ),
                ),
              ),
            ),
          if (!widget.visible && _snapshot != null)
            Positioned.fill(
              child: Image.memory(
                _snapshot!,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
            ),
          if (!widget.visible && _snapshot == null)
            widget.fallback
          else
            widget.child,
        ],
      ),
    );
  }
}
