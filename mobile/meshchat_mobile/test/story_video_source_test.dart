import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/story_item.dart';
import 'package:meshchat_mobile/src/services/story_video_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('30 MiB video has a 40 MiB base64 payload', () {
    expect(StoryItem.maxVideoBytes, 30 * 1024 * 1024);
    expect(StoryItem.maxVideoBase64Length, 40 * 1024 * 1024);
  });

  for (final entry in {
    'video/mp4': 'mp4',
    'video/quicktime': 'mov',
    'video/webm': 'webm',
    'video/x-m4v': 'm4v',
  }.entries) {
    test(
      'uses a local ${entry.value} file and cleans up on disposal',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'story_source_test_',
        );
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => root.path);
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await root.delete(recursive: true);
        });
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final source = await StoryVideoSource.prepareEncoded(
          'data:${entry.key};base64,${base64Encode(bytes)}',
          entry.key,
        );
        final file = File.fromUri(Uri.parse(source.controller.dataSource));
        expect(file.path, endsWith('video.${entry.value}'));
        expect(await file.readAsBytes(), bytes);
        await source.dispose();
        await source.dispose();
        expect(await file.exists(), isFalse);
        expect(await root.list().toList(), isEmpty);
      },
    );
  }
}
