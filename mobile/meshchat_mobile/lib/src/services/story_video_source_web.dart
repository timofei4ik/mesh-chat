import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

Future<(VideoPlayerController, Future<void> Function())> prepare(
  Uint8List bytes,
  String mime,
) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  return (
    VideoPlayerController.networkUrl(Uri.parse(url)),
    () async {
      web.URL.revokeObjectURL(url);
    },
  );
}
