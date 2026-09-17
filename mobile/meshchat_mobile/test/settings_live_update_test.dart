import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/app_settings.dart';
import 'package:meshchat_mobile/src/pages/settings_page.dart';
import 'package:meshchat_mobile/src/services/app_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('settings notify listeners before persistence finishes', () async {
    final controller = AppController();
    var notified = false;
    controller.addListener(() => notified = true);
    final saving = controller.updateAppSettings(
      controller.appSettings.copyWith(showOnline: false),
    );
    expect(notified, isTrue);
    expect(controller.appSettings.showOnline, isFalse);
    await saving;
    expect((await AppSettingsStore().load()).showOnline, isFalse);
  });

  test('rapid queued saves keep the newest complete state', () async {
    final store = AppSettingsStore();
    final pending = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      pending.add(
        store.save(
          AppSettings(
            showOnline: i.isEven,
            dataSaver: i.isOdd,
            directMessagePrivacy: i.isOdd
                ? DirectMessagePrivacy.sharedGroups
                : DirectMessagePrivacy.everyone,
          ),
        ),
      );
    }
    await Future.wait(pending);
    final restored = await store.load();
    expect(restored.showOnline, isFalse);
    expect(restored.dataSaver, isTrue);
    expect(restored.directMessagePrivacy, DirectMessagePrivacy.sharedGroups);
  });

  testWidgets('switches and option labels update without reopening settings', (
    tester,
  ) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );
    Finder tile(String label) => find.widgetWithText(SwitchListTile, label);
    await tester.scrollUntilVisible(find.text('Show online'), 350);
    final online = tester.widget<SwitchListTile>(tile('Show online'));
    final avatar = tester.widget<SwitchListTile>(tile('Show avatar'));
    // Two controls changed in the same frame must not restore each other.
    online.onChanged!(false);
    avatar.onChanged!(false);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile('Show online')).value, isFalse);
    expect(tester.widget<SwitchListTile>(tile('Show avatar')).value, isFalse);
    await tester.scrollUntilVisible(find.text('Who can message me'), 150);
    await tester.tap(find.text('Who can message me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shared groups'));
    await tester.pumpAndSettle();
    expect(find.text('People in shared groups'), findsOneWidget);
    expect(controller.appSettings.showOnline, isFalse);
    expect(controller.appSettings.showAvatar, isFalse);
    await tester.scrollUntilVisible(find.text('Data saver'), 250);
    await tester.tap(find.text('Data saver'));
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile('Data saver')).value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
