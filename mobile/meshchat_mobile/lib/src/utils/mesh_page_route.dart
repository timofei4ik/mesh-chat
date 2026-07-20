import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

Route<T> meshPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
}) {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      allowSnapshotting: true,
    );
  }

  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: const Duration(milliseconds: 210),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
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
