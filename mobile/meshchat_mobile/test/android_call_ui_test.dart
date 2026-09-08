import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/android_call_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('meshchat/android_calls');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, Object> action(String id, String verb, {bool expired = false}) =>
      {
        'call_id': id,
        'action': verb,
        'expires_at':
            DateTime.now().millisecondsSinceEpoch + (expired ? -1000 : 45000),
      };
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('only a current matching call can consume a valid action', () {
    expect(AndroidCallAction(action('a', 'answer')).matches('a'), isTrue);
    expect(AndroidCallAction(action('a', 'answer')).matches('b'), isFalse);
    expect(AndroidCallAction(action('a', 'answer')).matches(null), isFalse);
    expect(
      AndroidCallAction(action('a', 'answer', expired: true)).matches('a'),
      isFalse,
    );
    expect(AndroidCallAction(action('a', 'unknown')).matches('a'), isFalse);
  });

  test('cold answer waits for signaling and is acknowledged once', () async {
    final pending = [action('a', 'answer')];
    var handled = 0;
    String? activeId;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'actions') return pending.toList();
      if (call.method == 'ack') pending.clear();
      return null;
    });
    final ui = AndroidCallUi()
      ..onAction = (event) async {
        if (!event.matches(activeId)) return false;
        handled++;
        return true;
      };
    await ui.initialize();
    expect(pending, hasLength(1));
    activeId = 'b';
    await ui.drain();
    expect(handled, 0);
    activeId = 'a';
    await ui.drain();
    await ui.drain();
    expect(handled, 1);
    expect(pending, isEmpty);
  });

  test('expired actions close native UI without answering', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'actions') {
        return [action('a', 'answer', expired: true)];
      }
      return null;
    });
    final ui = AndroidCallUi()..onAction = (_) async => fail('Expired answer');
    await ui.initialize();
    expect(methods, ['actions', 'ended']);
  });

  test(
    'native presentation failure leaves notification fallback available',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'denied'),
      );
      final ui = AndroidCallUi();
      expect(await ui.show({'call_id': 'a', 'title': 'Caller'}), isFalse);
      expect(ui.presented, isEmpty);
      await ui.initialize();
    },
  );

  test('other platforms do not invoke the Android bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Android bridge on iOS'),
    );
    final ui = AndroidCallUi();
    await ui.initialize();
    expect(await ui.show({'call_id': 'a'}), isFalse);
    await ui.end('a');
  });
}
