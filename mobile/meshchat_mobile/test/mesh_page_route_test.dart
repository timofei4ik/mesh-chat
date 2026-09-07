import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/utils/mesh_page_route.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'linear transition, cancelled and committed edge swipe on $platform',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        const destination = ValueKey('destination');
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        navigator.currentState!.push(
          meshPageRoute<void>(
            builder: (_) =>
                const Scaffold(key: destination, body: Text('Profile')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 57));
        final x1 = tester.getTopLeft(find.byKey(destination)).dx;
        await tester.pump(const Duration(milliseconds: 57));
        final x2 = tester.getTopLeft(find.byKey(destination)).dx;
        await tester.pump(const Duration(milliseconds: 57));
        final x3 = tester.getTopLeft(find.byKey(destination)).dx;
        expect(x1 - x2, closeTo(x2 - x3, 1));
        expect(x1 - x2, closeTo(160, 1));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(const Offset(10, 250));
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(90, 0));
        await tester.pump();
        expect(tester.getTopLeft(find.byKey(destination)).dx, greaterThan(50));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(find.text('Profile'), findsOneWidget);
        expect(tester.getTopLeft(find.byKey(destination)).dx, closeTo(0, 0.1));
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        await tester.dragFrom(const Offset(10, 250), const Offset(500, 0));
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Profile'), findsNothing);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        expect(MeshRouteTransition.active.value, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'back swipe respects PopScope and leaves central horizontal gestures alone',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push(
        meshSettingsPageRoute<void>(
          builder: (_) => const PopScope(
            canPop: false,
            child: Scaffold(body: Text('Unsaved')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(10, 250), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved'), findsOneWidget);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        meshPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Media')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 250), const Offset(350, 0));
      await tester.pumpAndSettle();
      expect(find.text('Media'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
