import 'package:flutter/material.dart';

const meshPageTransitionDuration = Duration(milliseconds: 285);

class MeshRouteTransition {
  MeshRouteTransition._();
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);
  static final Set<Object> _owners = {};
  static void setActive(Object owner, bool value) {
    if (value) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    active.value = _owners.isNotEmpty;
  }
}

Route<T> meshPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool preserveLiquidGlass = false,
  bool fullWidthSlide = false,
}) => _MeshSlideRoute<T>(
  builder: builder,
  settings: settings,
  preserveLiquidGlass: preserveLiquidGlass,
);

Route<T> meshSettingsPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
}) => meshPageRoute<T>(
  builder: builder,
  settings: settings,
  preserveLiquidGlass: true,
);

class _MeshSlideRoute<T> extends PageRouteBuilder<T> {
  _MeshSlideRoute({
    required WidgetBuilder builder,
    super.settings,
    required this.preserveLiquidGlass,
  }) : super(
         transitionDuration: meshPageTransitionDuration,
         reverseTransitionDuration: meshPageTransitionDuration,
         pageBuilder: (context, _, _) =>
             _MeshRoutePerformanceGate(child: builder(context)),
       );

  final bool preserveLiquidGlass;
  NavigatorState? gestureNavigator;
  AnimationStatusListener? gestureEndListener;

  void statusChanged(AnimationStatus status) {
    MeshRouteTransition.setActive(
      this,
      gestureNavigator != null ||
          status == AnimationStatus.forward ||
          status == AnimationStatus.reverse,
    );
  }

  @override
  void install() {
    super.install();
    animation!.addStatusListener(statusChanged);
  }

  void startBack() {
    if (!isCurrent || !popGestureEnabled || gestureNavigator != null) return;
    gestureNavigator = navigator;
    gestureNavigator!.didStartUserGesture();
    MeshRouteTransition.setActive(this, true);
  }

  void updateBack(double delta) {
    if (gestureNavigator == null || !isCurrent) return;
    controller!.value = (controller!.value - delta).clamp(0.0, 1.0);
  }

  void stopGesture() {
    final listener = gestureEndListener;
    if (listener != null) controller!.removeStatusListener(listener);
    gestureEndListener = null;
    gestureNavigator?.didStopUserGesture();
    gestureNavigator = null;
    MeshRouteTransition.setActive(this, false);
  }

  void endBack(double velocity, {bool cancelled = false}) {
    if (gestureNavigator == null) return;
    final commit =
        !cancelled &&
        isCurrent &&
        popDisposition == RoutePopDisposition.pop &&
        (velocity > 650 || (velocity >= -650 && controller!.value < 0.65));
    if (commit) {
      navigator!.pop<T>();
    } else if (isCurrent) {
      controller!.animateTo(
        1,
        duration: Duration(
          microseconds:
              (meshPageTransitionDuration.inMicroseconds *
                      (1 - controller!.value))
                  .round(),
        ),
        curve: Curves.linear,
      );
    }
    if (!controller!.isAnimating) {
      stopGesture();
      return;
    }
    gestureEndListener = (status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        stopGesture();
      }
    };
    controller!.addStatusListener(gestureEndListener!);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        SlideTransition(
          position: Tween<Offset>(
            begin: reduced ? Offset.zero : const Offset(1, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 28 + MediaQuery.paddingOf(context).left,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => startBack(),
            onHorizontalDragUpdate: (details) {
              final width = MediaQuery.sizeOf(context).width;
              if (width > 0) updateBack(details.delta.dx / width);
            },
            onHorizontalDragEnd: (details) =>
                endBack(details.primaryVelocity ?? 0),
            onHorizontalDragCancel: () => endBack(0, cancelled: true),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    stopGesture();
    animation?.removeStatusListener(statusChanged);
    super.dispose();
  }
}

class _MeshRoutePerformanceGate extends StatelessWidget {
  const _MeshRoutePerformanceGate({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final primary = route?.animation;
    final secondary = route?.secondaryAnimation;
    if (primary == null || secondary == null) {
      return RepaintBoundary(child: child);
    }
    return AnimatedBuilder(
      animation: Listenable.merge([primary, secondary]),
      child: RepaintBoundary(child: child),
      builder: (context, child) => TickerMode(
        enabled:
            primary.status == AnimationStatus.completed &&
            secondary.status == AnimationStatus.dismissed,
        child: child!,
      ),
    );
  }
}
