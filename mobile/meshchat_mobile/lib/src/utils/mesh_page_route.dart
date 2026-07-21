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
  bool snapshotContent = false,
}) {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    return _MeshCupertinoPageRoute<T>(
      builder: (context) {
        final page = _MeshRoutePerformanceGate(child: builder(context));
        return snapshotContent ? _MeshTransitionSnapshot(child: page) : page;
      },
      settings: settings,
      allowSnapshotting: !snapshotContent,
    );
  }

  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: const Duration(milliseconds: 210),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) {
      final page = _MeshRoutePerformanceGate(child: builder(context));
      return snapshotContent ? _MeshTransitionSnapshot(child: page) : page;
    },
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

class _MeshTransitionSnapshot extends StatefulWidget {
  const _MeshTransitionSnapshot({required this.child});

  final Widget child;

  @override
  State<_MeshTransitionSnapshot> createState() =>
      _MeshTransitionSnapshotState();
}

class _MeshTransitionSnapshotState extends State<_MeshTransitionSnapshot> {
  final SnapshotController snapshot = SnapshotController();
  Animation<double>? primary;
  Animation<double>? secondary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final nextPrimary = route?.animation;
    final nextSecondary = route?.secondaryAnimation;
    if (identical(primary, nextPrimary) &&
        identical(secondary, nextSecondary)) {
      return;
    }
    primary?.removeStatusListener(handleAnimationStatus);
    secondary?.removeStatusListener(handleAnimationStatus);
    primary = nextPrimary;
    secondary = nextSecondary;
    primary?.addStatusListener(handleAnimationStatus);
    secondary?.addStatusListener(handleAnimationStatus);
    syncSnapshot();
  }

  void handleAnimationStatus(AnimationStatus _) => syncSnapshot();

  void syncSnapshot() {
    final shouldSnapshot =
        primary?.status != AnimationStatus.completed ||
        secondary?.status != AnimationStatus.dismissed;
    if (snapshot.allowSnapshotting == shouldSnapshot) return;
    snapshot.allowSnapshotting = shouldSnapshot;
    if (shouldSnapshot) snapshot.clear();
  }

  @override
  void dispose() {
    primary?.removeStatusListener(handleAnimationStatus);
    secondary?.removeStatusListener(handleAnimationStatus);
    snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      controller: snapshot,
      mode: SnapshotMode.forced,
      child: widget.child,
    );
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
