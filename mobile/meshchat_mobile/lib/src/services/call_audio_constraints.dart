/// Keep W3C constraints for browsers/desktop and the legacy optional map that
/// flutter_webrtc's Android/iOS getUserMedia parsers actually consume.
Map<String, dynamic> callAudioConstraints({
  required bool native,
  required bool enhanced,
  required bool hd,
  String inputId = '',
}) {
  final legacy = <String, bool>{
    'googEchoCancellation': true,
    'googNoiseSuppression': true,
    'googAutoGainControl': true,
    'googHighpassFilter': true,
    if (enhanced) 'googExperimentalNoiseSuppression': true,
  };
  final audio = <String, dynamic>{
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
    'channelCount': {'ideal': 1},
    if (native) ...legacy,
    if (native)
      'optional': [
        for (final flag in legacy.entries) {flag.key: flag.value},
      ],
    if (hd || enhanced) 'sampleRate': {'ideal': 48000},
    if (hd) 'sampleSize': {'ideal': 16},
    if (inputId.isNotEmpty) 'deviceId': {'exact': inputId},
  };
  return {'audio': audio, 'video': false};
}
