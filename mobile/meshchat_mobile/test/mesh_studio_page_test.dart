import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/meshpro_subscription.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/pages/mesh_studio_page.dart';

void main() {
  testWidgets('MeshStudio fits a narrow phone and shows all core controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController()
      ..session = const Session(
        serverUrl: 'wss://example.test/ws',
        serverToken: 'token',
        login: 'studio',
        password: 'password',
        publicUsername: 'studio',
        nodeId: 'node-studio',
      )
      ..meshProSubscription = MeshProSubscription(
        active: true,
        status: 'active',
        planCode: 'meshpro',
        periodEnd: DateTime.now().add(const Duration(days: 7)),
        entitlements: const MeshProEntitlements(
          schemaVersion: 1,
          catalogVersion: 'test',
          active: true,
          features: {
            'premium_badge': true,
            'profile_background': true,
            'profile_effect': true,
            'animated_avatar': true,
            'profile_glow': true,
            'custom_accent': true,
            'emoji_status': true,
          },
          limits: {},
        ),
      );
    controller.profiles['node-studio'] = const Profile(
      nodeId: 'node-studio',
      displayName: 'Studio User',
      publicUsername: 'studio',
      meshProBadge: true,
      profileBackground: 'stardust',
      profileEffect: 'stars',
      profileBlinkShape: 'star',
      avatarDecoration: 'stardust',
      profileGlow: true,
      profileAccent: 0xFF75DFFF,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MeshStudioPage(controller: controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('MeshStudio'), findsOneWidget);
    expect(find.text('Live profile'), findsOneWidget);
    expect(find.text('Linked presets'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('mesh-studio-live-profile')))
          .width,
      greaterThan(300),
    );
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -700),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Banner and animation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
