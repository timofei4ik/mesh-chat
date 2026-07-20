import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

/// Shared transition state used to temporarily replace native platform views
/// with cheap Flutter surfaces while a route snapshot is captured.
class MeshRouteTransition {
  MeshRouteTransition._();

  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);
}

Route<T> meshPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
}) {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    return _MeshCupertinoPageRoute<T>(
      builder: (context) => _MeshRoutePerformanceGate(child: builder(context)),
      settings: settings,
      allowSnapshotting: true,
    );
  }

  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: const Duration(milliseconds: 210),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) =>
        _MeshRoutePerformanceGate(child: builder(context)),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final offset =
          Tween<Offset>(
            begin: const Offset(0.025, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
          );
      return SlideTransition(position: offset, child: child);
    },
  );
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
      animation: Listenable.merge(<Listenable>[primary, secondary]),
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final settled =
            primary.status == AnimationStatus.completed &&
            secondary.status == AnimationStatus.dismissed;
        return TickerMode(enabled: settled, child: child!);
      },
    );
  }
}

class _MeshCupertinoPageRoute<T> extends CupertinoPageRoute<T> {
  _MeshCupertinoPageRoute({
    required super.builder,
    super.settings,
    super.allowSnapshotting,
  });

  AnimationStatusListener? _statusListener;

  @override
  void install() {
    super.install();
    _statusListener = (status) {
      MeshRouteTransition.active.value =
          status == AnimationStatus.forward ||
          status == AnimationStatus.reverse;
    };
    animation?.addStatusListener(_statusListener!);
  }

  @override
  TickerFuture didPush() {
    MeshRouteTransition.active.value = true;
    return super.didPush();
  }

  @override
  void dispose() {
    final listener = _statusListener;
    if (listener != null) animation?.removeStatusListener(listener);
    if (MeshRouteTransition.active.value) {
      MeshRouteTransition.active.value = false;
    }
    super.dispose();
  }
}
