import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';

void main() {
  const session = Session(
    serverUrl: 'wss://meshchat.example/ws',
    serverToken: 'token',
    login: 'alice',
    password: 'secret',
    publicUsername: 'alice',
    nodeId: 'alice-phone',
  );

  test('same account survives refreshed profile and credentials', () {
    final refreshed = session.copyWith(
      serverUrl: 'WSS://MESHCHAT.EXAMPLE/WS/',
      serverToken: 'new-token',
      password: 'new-secret',
      publicUsername: 'alice-new',
      nodeId: 'alice-desktop',
      email: 'alice@example.com',
    );

    expect(session.isSameAccountAs(refreshed), isTrue);
    expect(refreshed.isSameAccountAs(session), isTrue);
  });

  test('different server, login, or signed-out state is another account', () {
    expect(session.isSameAccountAs(session.copyWith(login: 'bob')), isFalse);
    expect(
      session.isSameAccountAs(
        session.copyWith(serverUrl: 'wss://other.example/ws'),
      ),
      isFalse,
    );
    expect(session.isSameAccountAs(null), isFalse);
  });
}
