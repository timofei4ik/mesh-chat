import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/pages/chats_page.dart';

void main() {
  for (final status in [
    'Sync failed (StateError). Reconnect to retry.',
    'Syncing messages...',
    'Online: synced 20',
  ]) {
    testWidgets('phone displays connection state accurately: $status', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController()
        ..status = status
        ..session = const Session(
          serverUrl: 'wss://example.test/ws',
          serverToken: '',
          login: 'test',
          password: '',
          publicUsername: 'test',
          nodeId: 'test',
        );
      await tester.pumpWidget(
        MaterialApp(home: ChatsPage(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final label = status.startsWith('Sync failed')
          ? 'Sync failed'
          : status.startsWith('Online')
          ? 'Online'
          : 'Syncing';
      expect(find.text(label), findsOneWidget);
      if (label != 'Syncing') expect(find.text('Syncing'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
