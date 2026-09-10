import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/app_settings.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/services/app_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('direct message privacy survives local settings reload', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppSettingsStore();
    const settings = AppSettings(
      directMessagePrivacy: DirectMessagePrivacy.sharedGroups,
    );

    await store.save(settings);

    expect(
      (await store.load()).directMessagePrivacy,
      DirectMessagePrivacy.sharedGroups,
    );
  });

  test('profile privacy metadata survives cache serialization', () {
    const profile = Profile(
      nodeId: 'alice-node',
      displayName: 'Alice',
      directMessagePrivacy: 'nobody',
      privacyShowOnline: false,
      privacyShowAvatar: false,
      privacyShowAbout: false,
    );

    final restored = Profile.fromJson(profile.toJson());

    expect(restored.directMessagePrivacy, 'nobody');
    expect(restored.privacyShowOnline, isFalse);
    expect(restored.privacyShowAvatar, isFalse);
    expect(restored.privacyShowAbout, isFalse);
  });
}
