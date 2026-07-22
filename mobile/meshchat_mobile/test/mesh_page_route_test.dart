import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/utils/mesh_page_route.dart';

void main() {
  setUp(() {
    MeshRouteTransition.active.value = false;
  });

  tearDown(() {
    MeshRouteTransition.active.value = false;
  });

  testWidgets('preserved route keeps native liquid glass active', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('home')),
      ),
    );

    navigatorKey.currentState!.push<void>(
      meshPageRoute<void>(
        preserveLiquidGlass: true,
        builder: (_) => const Scaffold(body: Text('profile')),
      ),
    );
    await tester.pump();
    expect(MeshRouteTransition.active.value, isFalse);
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    expect(MeshRouteTransition.active.value, isFalse);
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
