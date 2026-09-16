import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/story_video_source.dart';
import 'package:meshchat_mobile/src/widgets/story_video_view.dart';
import 'package:video_player/video_player.dart';

class _PreparedController extends VideoPlayerController {
  _PreparedController({this.buffering = false})
    : super.networkUrl(Uri.parse('https://example.invalid/story.mp4'));

  final bool buffering;
  final metadata = Completer<void>();
  final configured = Completer<void>();
  int playCalls = 0;

  @override
  Future<void> initialize() async {
    await metadata.future;
    value = value.copyWith(
      isInitialized: true,
      isBuffering: buffering,
      size: const Size(1920, 1080),
      duration: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> setLooping(bool looping) async {
    value = value.copyWith(isLooping: looping);
    configured.complete();
  }

  @override
  Future<void> play() async {
    playCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preparation waits for metadata and buffering without starting playback',
    () async {
      final controller = _PreparedController(buffering: true);
      var cleaned = 0;
      final source = StoryVideoSource(controller, () async => cleaned++);
      var ready = false;
      final preparation = source.initializeForPlayback().then(
        (_) => ready = true,
      );
      expect(ready, isFalse);
      expect(controller.playCalls, 0);
      controller.metadata.complete();
      await controller.configured.future;
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(controller.playCalls, 0);
      controller.value = controller.value.copyWith(isBuffering: false);
      await preparation;
      expect(ready, isTrue);
      expect(controller.value.isLooping, isTrue);
      expect(controller.playCalls, 0);
      await source.dispose();
      await source.dispose();
      expect(cleaned, 1);
    },
  );

  test('local playback does not require buffered-range events', () async {
    final controller = _PreparedController();
    final source = StoryVideoSource(controller, () async {});
    controller.metadata.complete();
    await source.initializeForPlayback();
    expect(controller.value.buffered, isEmpty);
    expect(controller.playCalls, 0);
    await source.dispose();
  });

  for (final close in [false, true]) {
    test('buffer wait stops on ${close ? 'close' : 'decoder error'}', () async {
      final controller = _PreparedController(buffering: true);
      final source = StoryVideoSource(controller, () async {});
      controller.metadata.complete();
      final preparation = source.initializeForPlayback();
      final check = expectLater(preparation, throwsStateError);
      await controller.configured.future;
      await Future<void>.delayed(Duration.zero);
      if (close) {
        await source.dispose();
      } else {
        controller.value = VideoPlayerValue.erroneous('decoder failed');
      }
      await check;
      expect(controller.playCalls, 0);
      await source.dispose();
    });
  }

  for (final viewport in [const Size(320, 600), const Size(900, 400)]) {
    for (final video in [
      const Size(1920, 1080),
      const Size(1080, 1920),
      const Size(1080, 1080),
      const Size(160, 90),
    ]) {
      testWidgets('contains $video inside $viewport without cropping', (
        tester,
      ) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _PreparedController();
        controller.value = VideoPlayerValue(
          duration: const Duration(seconds: 30),
          size: video,
          isInitialized: true,
        );
        await tester.pumpWidget(
          MaterialApp(home: StoryVideoView(controller: controller)),
        );
        final box = tester.renderObject<RenderBox>(find.byType(VideoPlayer));
        final rect = Rect.fromPoints(
          box.localToGlobal(Offset.zero),
          box.localToGlobal(box.size.bottomRight(Offset.zero)),
        );
        expect(rect.width / rect.height, closeTo(video.aspectRatio, 0.00001));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(viewport.width + 0.001));
        expect(rect.bottom, lessThanOrEqualTo(viewport.height + 0.001));
        expect(rect.center.dx, closeTo(viewport.width / 2, 0.001));
        expect(rect.center.dy, closeTo(viewport.height / 2, 0.001));
        final scale = (viewport.width / video.width)
            .clamp(0.0, 1.0)
            .clamp(0.0, viewport.height / video.height);
        expect(rect.width, closeTo(video.width * scale, 0.001));
        expect(rect.height, closeTo(video.height * scale, 0.001));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await controller.dispose();
      });
    }
  }

  testWidgets('loading, buffering and decoder errors stay visible', (
    tester,
  ) async {
    final controller = _PreparedController();
    await tester.pumpWidget(
      MaterialApp(home: StoryVideoView(controller: controller)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.value = const VideoPlayerValue(
      duration: Duration(seconds: 30),
      size: Size(1920, 1080),
      isInitialized: true,
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.value = controller.value.copyWith(isBuffering: false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    controller.value = VideoPlayerValue.erroneous('decoder failed');
    await tester.pump();
    expect(find.text('Unable to play this video'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });
}
