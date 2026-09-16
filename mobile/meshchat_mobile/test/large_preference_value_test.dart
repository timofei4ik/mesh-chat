import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/file_transfer_payload_store.dart';
import 'package:meshchat_mobile/src/services/large_preference_value.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryPayloads extends FileTransferPayloadStore {
  final values = <String, Uint8List>{};
  bool failWrites = false;

  @override
  Future<String> write(
    String sessionKey,
    String transferId,
    Uint8List bytes,
  ) async {
    if (failWrites) throw StateError('Storage full');
    final ref = '$sessionKey:$transferId';
    values[ref] = bytes;
    return ref;
  }

  @override
  Future<Uint8List> readChunk(String reference, int offset, int length) async =>
      values[reference] ?? Uint8List(0);

  @override
  Future<void> delete(String reference) async => values.remove(reference);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'story': 'legacy'}));

  test(
    'migrates legacy data and keeps large values out of preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final payloads = MemoryPayloads();
      final store = LargePreferenceValue(payloads: payloads, usePayloads: true);
      expect(await store.read(prefs, 'story'), 'legacy');
      final video = 'AAAA' * (30 * 1024 * 1024 ~/ 3);
      await store.write(prefs, 'story', video);
      expect(prefs.getString('story'), isNull);
      expect(prefs.getString('story:blob')!.length, lessThan(100));
      expect(await store.read(prefs, 'story'), video);
      await store.write(prefs, 'story', 'replacement');
      expect(payloads.values.length, 1);
      expect(await store.read(prefs, 'story'), 'replacement');
      await store.remove(prefs, 'story');
      expect(payloads.values, isEmpty);
      expect(await store.read(prefs, 'story'), isNull);
    },
  );

  test('failed migration preserves existing data', () async {
    final prefs = await SharedPreferences.getInstance();
    final payloads = MemoryPayloads()..failWrites = true;
    final store = LargePreferenceValue(payloads: payloads, usePayloads: true);
    await expectLater(store.write(prefs, 'story', 'new'), throwsStateError);
    expect(await store.read(prefs, 'story'), 'legacy');
  });

  test('native preference storage is unchanged', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LargePreferenceValue(usePayloads: false);
    await store.write(prefs, 'story', 'native');
    expect(prefs.getString('story'), 'native');
    expect(await store.read(prefs, 'story'), 'native');
  });
}
