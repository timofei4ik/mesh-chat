import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/delivery_trace_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('delivery stages persist in newest-first order', () async {
    final store = DeliveryTraceStore();
    final session = Session(
      serverUrl: 'ws://server.test',
      serverToken: 'token',
      login: 'alice',
      password: 'password',
      publicUsername: 'alice',
      nodeId: 'alice-phone',
    );
    await store.record(
      session,
      DeliveryTraceEvent(
        operationId: 'chat_message:one',
        packetId: 'one',
        stage: 'persisted',
        time: DateTime.utc(2026, 8, 25, 10),
      ),
    );
    await store.record(
      session,
      DeliveryTraceEvent(
        operationId: 'chat_message:one',
        packetId: 'one',
        stage: 'server_committed',
        time: DateTime.utc(2026, 8, 25, 10, 0, 1),
      ),
    );

    final restored = await DeliveryTraceStore().load(session);
    expect(restored.map((event) => event.stage), [
      'server_committed',
      'persisted',
    ]);
  });
}
