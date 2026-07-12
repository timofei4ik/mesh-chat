import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/own_profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('profile follows an account when its device node changes', () async {
    final store = OwnProfileStore();
    const phone = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws',
      serverToken: 'token',
      login: 'tima8016',
      password: 'password',
      publicUsername: 'sundrieddd',
      nodeId: 'phone-node',
    );
    const desktop = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws/',
      serverToken: 'token',
      login: 'TIMA8016',
      password: 'password',
      publicUsername: 'sundrieddd',
      nodeId: 'desktop-node',
    );

    await store.save(
      phone,
      const Profile(
        nodeId: 'phone-node',
        displayName: 'Timofey',
        accountLogin: 'tima8016',
        nodeAliases: ['older-node'],
        publicUsername: 'sundrieddd',
        about: 'About',
        avatarData: 'data:image/png;base64,YXZhdGFy',
      ),
    );

    final restored = await store.load(desktop);
    expect(restored, isNotNull);
    expect(restored!.nodeId, 'desktop-node');
    expect(restored.displayName, 'Timofey');
    expect(restored.avatarData, contains('YXZhdGFy'));
    expect(restored.nodeAliases, containsAll(['phone-node', 'desktop-node']));
  });

  test('profiles are isolated by server and account', () async {
    final store = OwnProfileStore();
    const session = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws',
      serverToken: 'token',
      login: 'first',
      password: 'password',
      publicUsername: 'first',
      nodeId: 'first-node',
    );
    await store.save(
      session,
      const Profile(nodeId: 'first-node', displayName: 'First'),
    );

    expect(
      await store.load(
        session.copyWith(login: 'second', nodeId: 'second-node'),
      ),
      isNull,
    );
  });
}
