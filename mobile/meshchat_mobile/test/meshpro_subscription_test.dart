import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/meshpro_subscription.dart';

void main() {
  test('parses an active MeshPro period', () {
    final subscription = MeshProSubscription.fromJson({
      'active': true,
      'status': 'active',
      'plan_code': 'boosty_monthly',
      'current_period_end': '2099-07-14 12:30:00',
    });

    expect(subscription.isActiveNow, isTrue);
    expect(subscription.planCode, 'boosty_monthly');
    expect(subscription.remaining, greaterThan(Duration.zero));
  });

  test('an expired server period cannot unlock MeshPro', () {
    final subscription = MeshProSubscription.fromJson({
      'active': true,
      'status': 'active',
      'current_period_end': '2000-01-01 00:00:00',
    });

    expect(subscription.isActiveNow, isFalse);
    expect(subscription.remaining, Duration.zero);
  });

  test('missing payload is safely inactive', () {
    final subscription = MeshProSubscription.fromJson(null);

    expect(subscription.isActiveNow, isFalse);
    expect(subscription.status, 'inactive');
  });

  test('parses versioned MeshPro entitlements', () {
    final subscription = MeshProSubscription.fromJson({
      'active': true,
      'status': 'active',
      'entitlements': {
        'schema_version': 1,
        'catalog_version': '2026-07-15.1',
        'active': true,
        'features': {'meshprivacy_vpn': true, 'ai_text_rewrite': false},
        'limits': {'file_transfer_bytes': 67108864},
      },
    });

    expect(subscription.entitlements.schemaVersion, 1);
    expect(subscription.entitlements.hasFeature('meshprivacy_vpn'), isTrue);
    expect(subscription.entitlements.hasFeature('ai_text_rewrite'), isFalse);
    expect(subscription.entitlements.limitFor('file_transfer_bytes'), 67108864);
  });

  test('old active status keeps the existing VPN entitlement', () {
    final subscription = MeshProSubscription.fromJson({
      'active': true,
      'status': 'active',
      'current_period_end': '2099-01-01 00:00:00',
    });

    expect(subscription.entitlements.hasFeature('meshprivacy_vpn'), isTrue);
  });
}
