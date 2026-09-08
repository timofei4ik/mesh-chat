import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshchat_mobile/src/services/app_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'noise suppression is enabled for a new account without MeshPro',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect((await AppSettingsStore().load()).callNoiseSuppression, true);
    },
  );
  test(
    'legacy subscription updates cannot reset a local noise preference',
    () async {
      SharedPreferences.setMockInitialValues({
        'meshpro_enhanced_noise_suppression': false,
      });
      final store = AppSettingsStore();
      final migrated = await store.load();
      expect(migrated.callNoiseSuppression, false);
      await store.save(
        migrated.copyWith(meshProEnhancedNoiseSuppression: true),
      );
      expect((await store.load()).callNoiseSuppression, false);
      await store.save(migrated.copyWith(callNoiseSuppression: true));
      expect((await store.load()).callNoiseSuppression, true);
    },
  );
}
