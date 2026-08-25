import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/incoming_file_staging_store.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'meshchat-incoming-stage-',
    );
    incomingFileStagingDirectoryOverrideForTesting = temporary.path;
  });

  tearDown(() async {
    incomingFileStagingDirectoryOverrideForTesting = null;
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'incoming chunks survive a store restart and assemble in order',
    () async {
      final firstStore = IncomingFileStagingStore();
      expect(
        await firstStore.putChunk(
          sessionKey: 'account-a',
          fileId: 'photo-a',
          chunkIndex: 1,
          totalChunks: 3,
          bytes: Uint8List.fromList([3, 4]),
        ),
        isNull,
      );
      expect(
        await firstStore.putChunk(
          sessionKey: 'account-a',
          fileId: 'photo-a',
          chunkIndex: 0,
          totalChunks: 3,
          bytes: Uint8List.fromList([1, 2]),
        ),
        isNull,
      );

      final restartedStore = IncomingFileStagingStore();
      final assembled = await restartedStore.putChunk(
        sessionKey: 'account-a',
        fileId: 'photo-a',
        chunkIndex: 2,
        totalChunks: 3,
        bytes: Uint8List.fromList([5, 6]),
      );
      expect(assembled, orderedEquals([1, 2, 3, 4, 5, 6]));

      await restartedStore.delete('account-a', 'photo-a');
      expect(
        await restartedStore.putChunk(
          sessionKey: 'account-a',
          fileId: 'photo-a',
          chunkIndex: 2,
          totalChunks: 3,
          bytes: Uint8List.fromList([5, 6]),
        ),
        isNull,
      );
    },
  );

  test('a changed chunk count resets stale partial data', () async {
    final store = IncomingFileStagingStore();
    await store.putChunk(
      sessionKey: 'account-a',
      fileId: 'file-a',
      chunkIndex: 0,
      totalChunks: 2,
      bytes: Uint8List.fromList([9]),
    );

    final assembled = await store.putChunk(
      sessionKey: 'account-a',
      fileId: 'file-a',
      chunkIndex: 0,
      totalChunks: 1,
      bytes: Uint8List.fromList([7]),
    );
    expect(assembled, orderedEquals([7]));
  });

  test('invalid indexes are rejected before touching storage', () async {
    final store = IncomingFileStagingStore();
    expect(
      () => store.putChunk(
        sessionKey: 'account-a',
        fileId: 'file-a',
        chunkIndex: 2,
        totalChunks: 2,
        bytes: Uint8List.fromList([1]),
      ),
      throwsFormatException,
    );
  });
}
