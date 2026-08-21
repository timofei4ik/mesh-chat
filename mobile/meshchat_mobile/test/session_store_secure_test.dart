import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/session_secret_store.dart';
import 'package:meshchat_mobile/src/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('new sessions keep credentials out of shared preferences', () async {
    final secrets = MemorySessionSecretStore();
    final store = SessionStore(secretStore: secrets);
    const session = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws',
      serverToken: 'server-secret',
      login: 'alice',
      password: 'account-secret',
      publicUsername: 'Alice',
      nodeId: 'alice-phone',
      email: 'alice@example.com',
      identityRecovery: 'recovery-envelope',
    );

    await store.saveCurrent(session);
    await store.saveRecent(session);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('password'), isNull);
    expect(prefs.getString('server_token'), isNull);
    expect(prefs.getString('identity_recovery'), isNull);
    final recentJson = prefs.getString('recent_sessions') ?? '';
    expect(recentJson, isNot(contains('account-secret')));
    expect(recentJson, isNot(contains('server-secret')));
    expect(recentJson, isNot(contains('recovery-envelope')));
    expect(
      secrets.values.values,
      containsAll(<String>[
        'account-secret',
        'server-secret',
        'recovery-envelope',
      ]),
    );

    final loaded = await store.load();
    expect(loaded?.login, session.login);
    expect(loaded?.password, session.password);
    expect(loaded?.identityRecovery, session.identityRecovery);
    final recent = await store.loadRecent();
    expect(recent, hasLength(1));
    expect(recent.single.login, session.login);
    expect(recent.single.password, session.password);
  });

  test('legacy current session migrates without signing out', () async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'wss://meshchat-losa.ru/ws',
      'server_token': 'legacy-token',
      'login': 'legacy-user',
      'password': 'legacy-password',
      'public_username': 'Legacy',
      'node_id': 'legacy-node',
      'email': 'legacy@example.com',
      'identity_recovery': 'legacy-recovery',
    });
    final secrets = MemorySessionSecretStore();
    final store = SessionStore(secretStore: secrets);

    final session = await store.load();

    expect(session, isNotNull);
    expect(session!.password, 'legacy-password');
    expect(session.serverToken, 'legacy-token');
    expect(session.identityRecovery, 'legacy-recovery');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('password'), isNull);
    expect(prefs.getString('server_token'), isNull);
    expect(prefs.getString('identity_recovery'), isNull);
    expect(
      secrets.values.values,
      containsAll(<String>[
        'legacy-password',
        'legacy-token',
        'legacy-recovery',
      ]),
    );
  });

  test('legacy recent accounts migrate and their JSON is sanitized', () async {
    SharedPreferences.setMockInitialValues({
      'recent_sessions': jsonEncode([
        {
          'server_url': 'wss://meshchat-losa.ru/ws',
          'server_token': 'recent-token',
          'login': 'recent-user',
          'password': 'recent-password',
          'public_username': 'Recent',
          'node_id': 'recent-node',
          'email': 'recent@example.com',
          'identity_recovery': 'recent-recovery',
        },
      ]),
    });
    final secrets = MemorySessionSecretStore();
    final store = SessionStore(secretStore: secrets);

    final recent = await store.loadRecent();

    expect(recent, hasLength(1));
    expect(recent.single.password, 'recent-password');
    expect(recent.single.serverToken, 'recent-token');
    expect(recent.single.identityRecovery, 'recent-recovery');
    final prefs = await SharedPreferences.getInstance();
    final sanitized = prefs.getString('recent_sessions') ?? '';
    expect(sanitized, isNot(contains('recent-password')));
    expect(sanitized, isNot(contains('recent-token')));
    expect(sanitized, isNot(contains('recent-recovery')));
  });

  test('failed secure migration leaves legacy credentials intact', () async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'wss://meshchat-losa.ru/ws',
      'server_token': 'legacy-token',
      'login': 'legacy-user',
      'password': 'legacy-password',
      'public_username': 'Legacy',
      'node_id': 'legacy-node',
      'identity_recovery': 'legacy-recovery',
    });
    final store = SessionStore(secretStore: FailingSessionSecretStore());

    await expectLater(store.load(), throwsStateError);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('password'), 'legacy-password');
    expect(prefs.getString('server_token'), 'legacy-token');
    expect(prefs.getString('identity_recovery'), 'legacy-recovery');
  });

  test('removing a recent account deletes only its credentials', () async {
    final secrets = MemorySessionSecretStore();
    final store = SessionStore(secretStore: secrets);
    const alice = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws',
      serverToken: 'alice-token',
      login: 'alice',
      password: 'alice-password',
      publicUsername: 'Alice',
      nodeId: 'alice-node',
      identityRecovery: 'alice-recovery',
    );
    const bob = Session(
      serverUrl: 'wss://meshchat-losa.ru/ws',
      serverToken: 'bob-token',
      login: 'bob',
      password: 'bob-password',
      publicUsername: 'Bob',
      nodeId: 'bob-node',
      identityRecovery: 'bob-recovery',
    );
    await store.saveRecent(alice);
    await store.saveRecent(bob);

    await store.removeRecent(alice);

    final recent = await store.loadRecent();
    expect(recent, hasLength(1));
    expect(recent.single.login, bob.login);
    expect(recent.single.password, bob.password);
    expect(secrets.values.values, isNot(contains('alice-password')));
    expect(secrets.values.values, isNot(contains('alice-token')));
    expect(secrets.values.values, isNot(contains('alice-recovery')));
    expect(secrets.values.values, contains('bob-password'));
    expect(secrets.values.values, contains('bob-token'));
    expect(secrets.values.values, contains('bob-recovery'));
  });
}

class MemorySessionSecretStore implements SessionSecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class FailingSessionSecretStore implements SessionSecretStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw StateError('secure storage unavailable');
  }
}
