import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/app_update_service.dart';

void main() {
  test('detects a newer catalog build', () {
    final result = AppUpdateService.updateFromCatalog(
      '{"apps":[{"id":"meshchat","version":"1.2.0","build":42}]}',
      currentVersion: '1.1.9',
      currentBuild: 41,
    );
    expect(result?.version, '1.2.0');
    expect(result?.build, 42);
  });

  test('does not offer the installed build', () {
    final result = AppUpdateService.updateFromCatalog(
      '{"apps":[{"id":"meshchat","version":"1.2.0","build":42}]}',
      currentVersion: '1.2.0',
      currentBuild: 42,
    );
    expect(result, isNull);
  });

  test('compares semantic versions when a build is unavailable', () {
    expect(AppUpdateService.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
  });
}
