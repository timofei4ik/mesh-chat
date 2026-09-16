import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:meshchat_mobile/src/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('simultaneous notification initialization shares one attempt', () async {
    final plugin = _TestNotificationPlugin()..gate = Completer<bool?>();
    final service = NotificationService(plugin: plugin);
    final first = service.initialize();
    final second = service.initialize();
    await plugin.started.future.timeout(const Duration(seconds: 2));
    expect(plugin.initializations, 1);
    plugin.gate!.complete(true);
    await Future.wait([first, second]);
    await service.initialize();
    expect(plugin.initializations, 1);
    service.systemCalls.dispose();
  });

  test('rejected notification initialization can be retried', () async {
    final plugin = _TestNotificationPlugin()..result = false;
    final service = NotificationService(plugin: plugin);
    await expectLater(service.initialize(), throwsStateError);
    plugin.result = true;
    await service.initialize();
    expect(plugin.initializations, 2);
    service.systemCalls.dispose();
  });
  test('notification target survives payload round trip', () {
    const target = NotificationTarget(
      packetType: 'group_message',
      sourceNode: 'alice-phone',
      groupId: 'group-7',
      callId: 'call-1',
    );

    final restored = NotificationTarget.decode(target.encode());

    expect(restored, isNotNull);
    expect(restored!.packetType, 'group_message');
    expect(restored.sourceNode, 'alice-phone');
    expect(restored.groupId, 'group-7');
    expect(restored.callId, 'call-1');
  });

  test('native push field names map to an activation target', () {
    final target = NotificationTarget.fromMap({
      'type': 'call_offer',
      'source_node': 'alice-phone',
      'call_id': 'call-1',
    });

    expect(target.packetType, 'call_offer');
    expect(target.sourceNode, 'alice-phone');
    expect(target.callId, 'call-1');
    expect(target.isEmpty, isFalse);
  });

  test('invalid or navigation-free payload is ignored', () {
    expect(NotificationTarget.decode('{broken'), isNull);
    expect(NotificationTarget.decode('{"packet_type":"chat_message"}'), isNull);
    expect(NotificationTarget.decode('[]'), isNull);
  });
}

class _TestNotificationPlugin implements FlutterLocalNotificationsPlugin {
  int initializations = 0;
  final started = Completer<void>();
  bool result = true;
  Completer<bool?>? gate;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) {
    initializations++;
    if (!started.isCompleted) started.complete();
    return gate?.future ?? Future.value(result);
  }

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
