import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/system_call_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('system call UI is dormant until explicitly enabled', () async {
    final ui = SystemCallUi(onAction: (_, _) async => true);
    ui.initialize();
    expect(await ui.reportIncoming('call', 'Caller'), isFalse);
    await ui.reportEnded('call');
    ui.dispose();
  });
  test(
    'enabled bridge forwards identity and reports native rejection',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemCallUi.channel, (call) async {
        calls.add(call);
        return false;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemCallUi.channel, null),
      );
      final ui = SystemCallUi(enabled: true, onAction: (_, _) async => true);
      expect(await ui.reportIncoming('uuid', 'Caller'), isFalse);
      await ui.reportEnded('uuid');
      expect(calls.map((c) => c.method), ['incoming', 'ended']);
      expect(calls.first.arguments['callId'], 'uuid');
      ui.dispose();
    },
  );
}
