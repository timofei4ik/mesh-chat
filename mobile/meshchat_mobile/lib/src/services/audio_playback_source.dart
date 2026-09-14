import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'audio_playback_source_io.dart'
    if (dart.library.js_interop) 'audio_playback_source_web.dart'
    as platform;

class PreparedAudioSource {
  PreparedAudioSource(this.source, this._cleanup, {this.devicePath});

  final Source source;
  final String? devicePath;
  final Future<void> Function() _cleanup;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _cleanup();
}

class AudioPlaybackFormat {
  const AudioPlaybackFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}

Future<PreparedAudioSource> prepareAudioPlaybackSource({
  required Uint8List bytes,
  required String filename,
}) async {
  if (bytes.isEmpty) throw const FormatException('Audio data is empty');
  final format = detectAudioPlaybackFormat(filename, bytes);
  final prepared = await platform.prepareAudioPlaybackSource(
    bytes: bytes,
    extension: format.extension,
    mimeType: format.mimeType,
  );
  return PreparedAudioSource(prepared.$1, prepared.$2, devicePath: prepared.$3);
}

AudioPlaybackFormat detectAudioPlaybackFormat(
  String filename,
  Uint8List bytes,
) {
  if (_startsWithAscii(bytes, 'OggS')) {
    return const AudioPlaybackFormat('.ogg', 'audio/ogg');
  }
  if (_startsWithAscii(bytes, 'fLaC')) {
    return const AudioPlaybackFormat('.flac', 'audio/flac');
  }
  if (_startsWithAscii(bytes, 'RIFF') &&
      _startsWithAscii(bytes, 'WAVE', offset: 8)) {
    return const AudioPlaybackFormat('.wav', 'audio/wav');
  }
  if (_startsWithAscii(bytes, 'ID3') || _looksLikeMp3Frame(bytes)) {
    return const AudioPlaybackFormat('.mp3', 'audio/mpeg');
  }
  if (_startsWithAscii(bytes, 'ftyp', offset: 4)) {
    return const AudioPlaybackFormat('.m4a', 'audio/mp4');
  }
  if (_looksLikeAacAdts(bytes)) {
    return const AudioPlaybackFormat('.aac', 'audio/aac');
  }
  if (_startsWithAscii(bytes, 'OpusHead')) {
    return const AudioPlaybackFormat('.opus', 'audio/opus');
  }

  final extension = _filenameExtension(filename);
  return switch (extension) {
    '.aac' => const AudioPlaybackFormat('.aac', 'audio/aac'),
    '.flac' => const AudioPlaybackFormat('.flac', 'audio/flac'),
    '.m4a' => const AudioPlaybackFormat('.m4a', 'audio/mp4'),
    '.mp3' => const AudioPlaybackFormat('.mp3', 'audio/mpeg'),
    '.ogg' => const AudioPlaybackFormat('.ogg', 'audio/ogg'),
    '.opus' => const AudioPlaybackFormat('.opus', 'audio/opus'),
    '.wav' => const AudioPlaybackFormat('.wav', 'audio/wav'),
    _ => const AudioPlaybackFormat('.audio', 'application/octet-stream'),
  };
}

bool _startsWithAscii(Uint8List bytes, String marker, {int offset = 0}) {
  if (offset < 0 || bytes.length < offset + marker.length) return false;
  for (var index = 0; index < marker.length; index++) {
    if (bytes[offset + index] != marker.codeUnitAt(index)) return false;
  }
  return true;
}

bool _looksLikeMp3Frame(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xff) return false;
  final second = bytes[1];
  final hasSync = second & 0xe0 == 0xe0;
  final validLayer = second & 0x06 != 0;
  return hasSync && validLayer;
}

bool _looksLikeAacAdts(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xff) return false;
  return bytes[1] & 0xf6 == 0xf0;
}

String _filenameExtension(String filename) {
  final normalized = filename.trim().toLowerCase();
  final dot = normalized.lastIndexOf('.');
  return dot < 0 ? '' : normalized.substring(dot);
}
