import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/audio_playback_source.dart';

void main() {
  test('detects supported audio containers from their headers', () {
    expect(
      detectAudioPlaybackFormat('voice.bin', _ascii('OggS....OpusHead')),
      hasFormat('.ogg', 'audio/ogg'),
    );
    expect(
      detectAudioPlaybackFormat('voice.bin', _ascii('RIFF....WAVEfmt ')),
      hasFormat('.wav', 'audio/wav'),
    );
    expect(
      detectAudioPlaybackFormat('voice.bin', _ascii('fLaC....')),
      hasFormat('.flac', 'audio/flac'),
    );
    expect(
      detectAudioPlaybackFormat('voice.bin', _ascii('ID3....')),
      hasFormat('.mp3', 'audio/mpeg'),
    );
    expect(
      detectAudioPlaybackFormat(
        'voice.bin',
        Uint8List.fromList([0, 0, 0, 0, ..._ascii('ftypM4A ')]),
      ),
      hasFormat('.m4a', 'audio/mp4'),
    );
    expect(
      detectAudioPlaybackFormat(
        'voice.bin',
        Uint8List.fromList([0xff, 0xf1, 0x50, 0x80]),
      ),
      hasFormat('.aac', 'audio/aac'),
    );
  });

  test('uses a supported filename extension when no header is available', () {
    expect(
      detectAudioPlaybackFormat('voice.AAC', Uint8List.fromList([1, 2, 3])),
      hasFormat('.aac', 'audio/aac'),
    );
    expect(
      detectAudioPlaybackFormat('voice.opus', Uint8List.fromList([1, 2, 3])),
      hasFormat('.opus', 'audio/opus'),
    );
  });
}

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

Matcher hasFormat(String extension, String mimeType) =>
    isA<AudioPlaybackFormat>()
        .having((value) => value.extension, 'extension', extension)
        .having((value) => value.mimeType, 'mimeType', mimeType);
