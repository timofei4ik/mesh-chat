import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/services/chat_cache_store.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const first = Session(
    serverUrl: 'wss://cache.test',
    serverToken: '',
    login: 'first',
    password: '',
    publicUsername: '',
    nodeId: 'one',
  );
  final second = first.copyWith(login: 'second', nodeId: 'two');
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'meshchat-account-transition-',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'delayed save cannot replace the next account cache while its state is empty',
    () async {
      final store = ChatCacheStore();
      final previous = ChatThread(
        profile: const Profile(
          nodeId: 'previous-peer',
          displayName: 'Previous',
        ),
      );
      final retained = ChatThread(
        profile: const Profile(
          nodeId: 'retained-peer',
          displayName: 'Retained',
        ),
      );
      await store.saveCheckpoint(first, [previous], 30);
      await store.saveCheckpoint(second, [retained], 40);
      final controller = AppController()..session = first;
      controller.threads['previous-peer'] = previous;
      controller.toggleThreadPin(previous);
      // Account handoff changes the session before asynchronous disk hydration.
      controller.session = second;
      controller.threads.clear();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final restored = <String, ChatThread>{};
      await store.load(second, {}, restored, {});
      expect(restored.keys, contains('retained-peer'));
      expect(await store.loadSyncCursor(second), 40);
      // Native media plugins are not initialized by this persistence-only test.
      controller.session = null;
    },
  );
}
