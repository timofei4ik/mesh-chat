import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const firstSession = Session(
    serverUrl: 'wss://meshchat.example/ws',
    serverToken: '',
    login: 'alice',
    password: 'secret',
    publicUsername: 'alice',
    nodeId: 'alice-phone',
  );
  const secondSession = Session(
    serverUrl: 'wss://meshchat.example/ws',
    serverToken: '',
    login: 'bob',
    password: 'secret',
    publicUsername: 'bob',
    nodeId: 'bob-phone',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores cursors per account and never moves them backwards', () async {
    final store = SyncCursorStore();

    expect(await store.load(firstSession), 0);
    await store.save(firstSession, 12);
    await store.save(firstSession, 4);
    await store.save(secondSession, 7);

    expect(await store.load(firstSession), 12);
    expect(await store.load(secondSession), 7);
  });

  test('normalizes server URL and can clear one account', () async {
    final store = SyncCursorStore();
    const sameAccountWithSlash = Session(
      serverUrl: 'WSS://MESHCHAT.EXAMPLE/WS/',
      serverToken: '',
      login: 'ALICE',
      password: 'secret',
      publicUsername: 'alice',
      nodeId: 'alice-desktop',
    );

    await store.save(firstSession, 21);
    expect(await store.load(sameAccountWithSlash), 21);

    await store.clear(sameAccountWithSlash);
    expect(await store.load(firstSession), 0);
  });

  test('requires a cache checkpoint before resuming with a cursor', () {
    expect(
      SyncCursorStore.safeCursor(accountCursor: 100, cacheCursor: null),
      0,
    );
    expect(SyncCursorStore.safeCursor(accountCursor: 100, cacheCursor: 80), 80);
    expect(SyncCursorStore.safeCursor(accountCursor: 80, cacheCursor: 100), 80);
    expect(SyncCursorStore.safeCursor(accountCursor: 0, cacheCursor: null), 0);
  });
}
