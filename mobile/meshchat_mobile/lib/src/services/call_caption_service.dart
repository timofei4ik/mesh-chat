import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef CallCaptionResultCallback =
    void Function(String text, bool isFinal, double confidence);
typedef CallCaptionStatusCallback = void Function(String status);
typedef CallCaptionAudioTranscriber =
    Future<String?> Function(Uint8List wavBytes, Duration duration);

class _CaptionAudioChunk {
  const _CaptionAudioChunk(this.bytes, this.duration);

  final Uint8List bytes;
  final Duration duration;
}

class CallCaptionService {
  final SpeechToText _speech = SpeechToText();
  final AudioRecorder _recorder = AudioRecorder();

  bool _enabled = false;
  bool _initialized = false;
  bool _starting = false;
  bool _rotatingServerAudio = false;
  bool _transcribingServerAudio = false;
  Timer? _restartTimer;
  Timer? _serverAudioChunkTimer;
  StreamSubscription<Uint8List>? _iosAudioStreamSubscription;
  BytesBuilder _iosAudioBuffer = BytesBuilder(copy: false);
  DateTime? _serverAudioChunkStartedAt;
  String? _serverAudioChunkPath;
  final ListQueue<_CaptionAudioChunk> _queuedServerAudio =
      ListQueue<_CaptionAudioChunk>();
  CallCaptionResultCallback? _onResult;
  CallCaptionStatusCallback? _onStatus;
  CallCaptionAudioTranscriber? _serverAudioTranscriber;

  static const _serverAudioSampleRate = 16000;
  static const _serverAudioChannels = 1;
  // A six-second phrase gives Whisper enough surrounding context for quieter
  // and longer sentences without exceeding the provider's live-call budget.
  static const _serverAudioChunkDuration = Duration(seconds: 6);

  bool get enabled => _enabled;

  bool _isKnownCaptionHallucination(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.!?…]+$'), '');
    // Narrow filter for recognizer artefacts that are not spoken by callers.
    return normalized.contains('добавил субтитры') ||
        normalized.contains('added subtitles') ||
        normalized.contains('dimatorzok') ||
        normalized == 'продолжение следует' ||
        normalized == 'до новых встреч' ||
        normalized == 'спасибо за просмотр' ||
        normalized == 'thank you' ||
        normalized == 'thanks for watching';
  }

  Future<String?> start({
    required CallCaptionResultCallback onResult,
    required CallCaptionStatusCallback onStatus,
    CallCaptionAudioTranscriber? onServerAudioChunk,
  }) async {
    if (_enabled) return null;
    _onResult = onResult;
    _onStatus = onStatus;
    _serverAudioTranscriber = onServerAudioChunk;
    _onStatus?.call('Starting captions...');
    try {
      if ((Platform.isWindows || Platform.isAndroid || Platform.isIOS) &&
          _serverAudioTranscriber != null) {
        return _startServerAudioCaptions();
      }
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onStatus: _handleStatus,
          onError: _handleError,
          finalTimeout: const Duration(seconds: 2),
        );
      }
      if (!_initialized) {
        _onStatus?.call('Speech recognition is unavailable');
        return 'Speech recognition is unavailable on this device';
      }
      _enabled = true;
      await _beginListening();
      return null;
    } catch (error) {
      _enabled = false;
      _onStatus?.call('Captions unavailable');
      final details = error.toString().toLowerCase();
      if (details.contains('recognizernotavailable') ||
          details.contains('speech recognition not available')) {
        return 'Speech recognition is not available on this device';
      }
      return 'Could not start captions on this device';
    }
  }

  Future<void> stop() async {
    _enabled = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _stopServerAudioCaptions();
    if (_speech.isListening) {
      await _speech.stop().catchError((_) {});
    }
    _onStatus?.call('Captions off');
  }

  Future<String?> _startServerAudioCaptions() async {
    final granted = await _recorder.hasPermission();
    if (!granted) {
      _onStatus?.call('Speech permission required');
      return 'Microphone permission is required for captions';
    }
    _enabled = true;
    try {
      if (Platform.isIOS) {
        return _startIosServerAudioCaptions();
      }
      await _startServerAudioChunk();
      _serverAudioChunkTimer = Timer.periodic(
        _serverAudioChunkDuration,
        (_) => unawaited(_rotateServerAudioChunk()),
      );
      _onStatus?.call('Listening');
      return null;
    } catch (error) {
      _enabled = false;
      _onStatus?.call('Captions unavailable');
      return 'Could not start microphone captions: $error';
    }
  }

  Future<String?> _startIosServerAudioCaptions() async {
    // WebRTC owns AVAudioSession during a call. Letting the record plugin
    // reconfigure or deactivate it can mute the call after every chunk.
    await _recorder.ios?.manageAudioSession(false);
    _iosAudioBuffer = BytesBuilder(copy: false);
    _serverAudioChunkStartedAt = DateTime.now();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: _serverAudioChannels,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _iosAudioStreamSubscription = stream.listen(
      (bytes) {
        if (_enabled && bytes.isNotEmpty) _iosAudioBuffer.add(bytes);
      },
      onError: (_) {
        if (_enabled) _onStatus?.call('Captions unavailable');
      },
    );
    _serverAudioChunkTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _flushIosServerAudioChunk(),
    );
    _onStatus?.call('Listening');
    return null;
  }

  void _flushIosServerAudioChunk() {
    if (!_enabled || _serverAudioTranscriber == null) return;
    final pcmBytes = _iosAudioBuffer.takeBytes();
    _iosAudioBuffer = BytesBuilder(copy: false);
    if (pcmBytes.isEmpty) return;
    final duration = Duration(
      microseconds:
          (pcmBytes.length * Duration.microsecondsPerSecond) ~/
          (48000 * _serverAudioChannels * 2),
    );
    final wavBytes = _pcm16ToWav(
      pcmBytes,
      sampleRate: 48000,
      channels: _serverAudioChannels,
    );
    if (_containsSpeech(wavBytes)) {
      _queueServerAudioForTranscription(wavBytes, duration);
    }
    _serverAudioChunkStartedAt = DateTime.now();
    _onStatus?.call('Listening');
  }

  Uint8List _pcm16ToWav(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
  }) {
    const bitsPerSample = 16;
    final header = ByteData(44);
    void writeAscii(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        header.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + pcmBytes.length, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, pcmBytes.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcmBytes]);
  }

  Future<void> _startServerAudioChunk() async {
    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}${Platform.pathSeparator}'
        'meshchat-caption-${DateTime.now().microsecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: _serverAudioSampleRate,
        numChannels: _serverAudioChannels,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: path,
    );
    _serverAudioChunkPath = path;
    _serverAudioChunkStartedAt = DateTime.now();
  }

  Future<void> _rotateServerAudioChunk() async {
    if (_rotatingServerAudio || !_enabled || _serverAudioTranscriber == null) {
      return;
    }
    _rotatingServerAudio = true;
    Uint8List? bytes;
    var duration = _serverAudioChunkDuration;
    try {
      final startedAt = _serverAudioChunkStartedAt;
      final fallbackPath = _serverAudioChunkPath;
      final recordedPath = await _recorder.stop();
      final path = recordedPath ?? fallbackPath;
      if (path == null) return;
      final file = File(path);
      bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {
        // The temporary file can already be gone after an interrupted capture.
      }
      if (bytes.length <= 44) return;
      duration = startedAt == null
          ? _serverAudioChunkDuration
          : DateTime.now().difference(startedAt);
    } catch (_) {
      // Silence and transient provider errors should not stop the call.
    } finally {
      // Begin the next capture before the network request for the previous
      // segment. Waiting for the provider here used to create audible gaps.
      if (_enabled) {
        try {
          await _startServerAudioChunk();
        } catch (_) {
          _onStatus?.call('Captions unavailable');
        }
      }
      _rotatingServerAudio = false;
    }
    if (bytes != null && _containsSpeech(bytes)) {
      _queueServerAudioForTranscription(bytes, duration);
    }
    if (_enabled) {
      _onStatus?.call('Listening');
    }
  }

  void _queueServerAudioForTranscription(Uint8List bytes, Duration duration) {
    if (_transcribingServerAudio) {
      // Never overwrite earlier speech while a provider response is pending.
      // A short bounded queue absorbs network jitter without growing forever.
      if (_queuedServerAudio.length >= 20) {
        _queuedServerAudio.removeFirst();
      }
      _queuedServerAudio.addLast(_CaptionAudioChunk(bytes, duration));
      return;
    }
    unawaited(_transcribeServerAudio(bytes, duration));
  }

  Future<void> _transcribeServerAudio(
    Uint8List bytes,
    Duration duration,
  ) async {
    if (!_enabled || _serverAudioTranscriber == null) return;
    _transcribingServerAudio = true;
    try {
      final text = await _serverAudioTranscriber!(bytes, duration);
      if (_enabled &&
          text != null &&
          text.trim().isNotEmpty &&
          !_isKnownCaptionHallucination(text)) {
        _onResult?.call(text.trim(), true, 1);
      }
    } catch (_) {
      // Transient provider errors should not stop a live call.
    } finally {
      _transcribingServerAudio = false;
      final queued = _queuedServerAudio.isEmpty
          ? null
          : _queuedServerAudio.removeFirst();
      if (_enabled && queued != null) {
        unawaited(_transcribeServerAudio(queued.bytes, queued.duration));
      }
    }
  }

  bool _containsSpeech(Uint8List wavBytes) {
    final dataOffset = _wavDataOffset(wavBytes);
    if (dataOffset == null || dataOffset + 2 >= wavBytes.length) return false;

    final data = ByteData.sublistView(wavBytes);
    var samples = 0;
    var loudSamples = 0;
    var energy = 0.0;
    for (var offset = dataOffset; offset + 1 < wavBytes.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      final amplitude = sample.abs();
      energy += amplitude * amplitude;
      if (amplitude >= 350) loudSamples++;
      samples++;
    }
    if (samples == 0) return false;
    final rms = math.sqrt(energy / samples);
    // AGC can leave a quiet room with a small constant signal. Require both
    // meaningful average energy and enough peaks to avoid transcribing noise.
    return rms >= 150 && loudSamples / samples >= 0.0005;
  }

  int? _wavDataOffset(Uint8List bytes) {
    if (bytes.length < 20 ||
        bytes[0] != 0x52 ||
        bytes[1] != 0x49 ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x46) {
      return null;
    }
    final view = ByteData.sublistView(bytes);
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final isData =
          bytes[offset] == 0x64 &&
          bytes[offset + 1] == 0x61 &&
          bytes[offset + 2] == 0x74 &&
          bytes[offset + 3] == 0x61;
      final size = view.getUint32(offset + 4, Endian.little);
      final payloadOffset = offset + 8;
      if (isData) return payloadOffset < bytes.length ? payloadOffset : null;
      offset = payloadOffset + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  Future<void> _stopServerAudioCaptions() async {
    _serverAudioChunkTimer?.cancel();
    _serverAudioChunkTimer = null;
    final path = _serverAudioChunkPath;
    _serverAudioChunkPath = null;
    _serverAudioChunkStartedAt = null;
    _queuedServerAudio.clear();
    await _iosAudioStreamSubscription?.cancel();
    _iosAudioStreamSubscription = null;
    _iosAudioBuffer = BytesBuilder(copy: false);
    if (await _recorder.isRecording()) {
      try {
        final recordedPath = await _recorder.stop();
        final file = File(recordedPath ?? path ?? '');
        if (await file.exists()) await file.delete();
      } catch (_) {
        // The recorder may already have been stopped by Windows.
      }
    }
  }

  Future<void> _beginListening() async {
    if (!_enabled || _starting || _speech.isListening) return;
    _starting = true;
    try {
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: false,
          autoPunctuation: true,
          enableHapticFeedback: false,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 3),
        ),
      );
      if (_enabled) _onStatus?.call('Listening');
    } finally {
      _starting = false;
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isEmpty || _isKnownCaptionHallucination(text)) return;
    _onResult?.call(text, result.finalResult, result.confidence);
  }

  void _handleStatus(String status) {
    if (!_enabled) return;
    if (status == SpeechToText.listeningStatus) {
      _onStatus?.call('Listening');
      return;
    }
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      _onStatus?.call('Waiting for speech');
      _scheduleRestart();
    }
  }

  void _handleError(SpeechRecognitionError error) {
    if (!_enabled) return;
    final permanent = error.permanent || error.errorMsg == 'error_permission';
    _onStatus?.call(permanent ? 'Speech permission required' : 'Restarting');
    if (permanent) {
      _enabled = false;
      return;
    }
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (!_enabled) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_beginListening());
    });
  }

  void dispose() {
    _enabled = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    unawaited(_stopServerAudioCaptions());
    unawaited(_recorder.dispose().catchError((_) {}));
    unawaited(_speech.cancel().catchError((_) {}));
  }
}
