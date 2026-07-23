import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class CallAudioDevice {
  const CallAudioDevice({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final String kind;
}

class CallService {
  static int _screenViewCounter = 0;
  static String _selectedAudioInputId = '';
  static String _selectedAudioOutputId = '';

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  web.HTMLAudioElement? _remoteAudioElement;
  web.HTMLVideoElement? _remoteScreenElement;
  MediaStream? _screenStream;
  RTCRtpSender? _screenSender;
  String? _remoteScreenViewType;
  bool _localMuted = false;
  bool _speakerEnabled = true;
  bool _hdAudio = false;
  bool _enhancedNoiseSuppression = false;
  List<Map<String, dynamic>> _iceServers = const [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  void Function()? onRemoteScreenChanged;
  void Function()? onLocalScreenEnded;

  void setIceServers(List<Map<String, dynamic>> servers) {
    if (servers.isEmpty) return;
    _iceServers = servers
        .map((server) => Map<String, dynamic>.from(server))
        .toList(growable: false);
  }

  Future<List<CallAudioDevice>> audioInputs() async {
    return _devicesOfKind('audioinput');
  }

  Future<List<CallAudioDevice>> audioOutputs() async {
    return _devicesOfKind('audiooutput');
  }

  Future<void> selectAudioInput(String deviceId) async {
    _selectedAudioInputId = deviceId;
  }

  Future<void> selectAudioOutput(String deviceId) async {
    _selectedAudioOutputId = deviceId;
    if (deviceId.isEmpty) return;
    await _remoteAudioElement
        ?.setSinkId(deviceId)
        .toDart
        .catchError((_) => null);
  }

  String get selectedAudioInputId => _selectedAudioInputId;
  String get selectedAudioOutputId => _selectedAudioOutputId;

  Future<String> startOutgoing({
    required void Function(Map<String, dynamic> candidate) onIceCandidate,
    bool hdAudio = false,
    bool enhancedNoiseSuppression = false,
  }) async {
    await _preparePeerConnection(
      onIceCandidate: onIceCandidate,
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
    );
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    final sdp = _enhanceOpusSdp(offer.sdp ?? '');
    await _peerConnection!.setLocalDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    return sdp;
  }

  Future<String> acceptIncoming({
    required String remoteOfferSdp,
    required void Function(Map<String, dynamic> candidate) onIceCandidate,
    bool hdAudio = false,
    bool enhancedNoiseSuppression = false,
  }) async {
    await _preparePeerConnection(
      onIceCandidate: onIceCandidate,
      hdAudio: hdAudio,
      enhancedNoiseSuppression: enhancedNoiseSuppression,
    );
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    await _flushPendingRemoteCandidates();
    final answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    final sdp = _enhanceOpusSdp(answer.sdp ?? '');
    await _peerConnection!.setLocalDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    return sdp;
  }

  Future<void> applyAnswer(String remoteAnswerSdp) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null || remoteAnswerSdp.isEmpty) return;
    await peerConnection.setRemoteDescription(
      RTCSessionDescription(remoteAnswerSdp, 'answer'),
    );
    await _flushPendingRemoteCandidates();
  }

  Future<void> addIceCandidate(Map<String, dynamic> data) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      _pendingRemoteCandidates.add(Map<String, dynamic>.from(data));
      return;
    }
    await _addIceCandidate(peerConnection, data);
  }

  Future<void> _addIceCandidate(
    RTCPeerConnection peerConnection,
    Map<String, dynamic> data,
  ) async {
    final candidate = data['candidate']?.toString() ?? '';
    if (candidate.isEmpty) return;
    await peerConnection.addCandidate(
      RTCIceCandidate(
        candidate,
        data['sdpMid']?.toString(),
        int.tryParse(data['sdpMLineIndex']?.toString() ?? ''),
      ),
    );
  }

  Future<void> end() async {
    await _stopScreenMedia();
    _remoteAudioElement?.srcObject = null;
    _remoteAudioElement?.remove();
    _remoteScreenElement?.srcObject = null;
    _remoteScreenElement?.remove();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioElement = null;
    _remoteScreenElement = null;
    _remoteScreenViewType = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    _speakerEnabled = true;
    _pendingRemoteCandidates.clear();
    onRemoteScreenChanged?.call();
  }

  Future<void> _resetCurrentConnectionOnly() async {
    await _stopScreenMedia();
    _remoteAudioElement?.srcObject = null;
    _remoteAudioElement?.remove();
    _remoteScreenElement?.srcObject = null;
    _remoteScreenElement?.remove();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioElement = null;
    _remoteScreenElement = null;
    _remoteScreenViewType = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    onRemoteScreenChanged?.call();
  }

  Future<void> _flushPendingRemoteCandidates() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null || _pendingRemoteCandidates.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      await _addIceCandidate(peerConnection, candidate);
    }
  }

  Future<void> _preparePeerConnection({
    required void Function(Map<String, dynamic> candidate) onIceCandidate,
    required bool hdAudio,
    required bool enhancedNoiseSuppression,
  }) async {
    await _resetCurrentConnectionOnly();
    final peerConnection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    peerConnection.onIceCandidate = (candidate) {
      final raw = candidate.candidate;
      if (raw == null || raw.isEmpty) return;
      onIceCandidate({
        'candidate': raw,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    peerConnection.onTrack = (event) {
      if (event.streams.isEmpty) return;
      if (event.track.kind == 'audio') {
        _attachRemoteAudio(event.streams.first);
      } else if (event.track.kind == 'video') {
        _attachRemoteScreen(event.streams.first);
      }
    };
    peerConnection.onAddStream = (stream) {
      _attachRemoteAudio(stream);
      _attachRemoteScreen(stream);
    };

    _hdAudio = hdAudio;
    _enhancedNoiseSuppression = enhancedNoiseSuppression;
    MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia(_mediaConstraints());
    } catch (_) {
      _hdAudio = false;
      _enhancedNoiseSuppression = false;
      stream = await navigator.mediaDevices.getUserMedia(_mediaConstraints());
    }
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
      await peerConnection.addTrack(track, stream);
    }
    _localStream = stream;
    _peerConnection = peerConnection;
  }

  Future<void> setMuted(bool muted) async {
    _localMuted = muted;
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  bool get isMuted => _localMuted;

  Future<void> setSpeakerEnabled(bool enabled) async {
    _speakerEnabled = enabled;
  }

  bool get speakerEnabled => _speakerEnabled;

  bool get isScreenSharing => _screenStream != null;

  bool get hasRemoteScreen => _remoteScreenElement?.srcObject != null;

  Future<String> startScreenShare() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) throw StateError('Call is not active');
    await _stopScreenMedia();
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'frameRate': {'ideal': 15, 'max': 24},
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
    });
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) {
      throw StateError('Screen capture returned no video track');
    }
    _screenStream = stream;
    tracks.first.onEnded = () => onLocalScreenEnded?.call();
    _screenSender = await peerConnection.addTrack(tracks.first, stream);
    final offer = await peerConnection.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    final sdp = _enhanceOpusSdp(offer.sdp ?? '');
    await peerConnection.setLocalDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    return sdp;
  }

  Future<String> acceptScreenShareOffer(String remoteOfferSdp) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) throw StateError('Call is not active');
    await peerConnection.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    await _flushPendingRemoteCandidates();
    final answer = await peerConnection.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    final sdp = _enhanceOpusSdp(answer.sdp ?? '');
    await peerConnection.setLocalDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    return sdp;
  }

  Future<void> applyScreenShareAnswer(String remoteAnswerSdp) async {
    await applyAnswer(remoteAnswerSdp);
  }

  Future<void> stopScreenShare() async {
    await _stopScreenMedia();
  }

  Future<void> clearRemoteScreen() async {
    _remoteScreenElement?.srcObject = null;
    onRemoteScreenChanged?.call();
  }

  Widget remoteScreenView() {
    final viewType = _remoteScreenViewType;
    if (viewType == null || _remoteScreenElement?.srcObject == null) {
      return const SizedBox.shrink();
    }
    return HtmlElementView(viewType: viewType);
  }

  void _attachRemoteAudio(MediaStream stream) {
    if (stream.getAudioTracks().isEmpty) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
    final nativeStream = stream as MediaStreamWeb;
    final audio =
        _remoteAudioElement ??
        (web.HTMLAudioElement()
          ..autoplay = true
          ..controls = false
          ..muted = false
          ..setAttribute('playsinline', 'true')
          ..style.display = 'none');
    if (_remoteAudioElement == null) {
      web.document.body?.append(audio);
      _remoteAudioElement = audio;
    }
    audio.srcObject = nativeStream.jsStream;
    if (_selectedAudioOutputId.isNotEmpty) {
      audio.setSinkId(_selectedAudioOutputId).toDart.catchError((_) => null);
    }
    audio.play().toDart.catchError((_) => null);
  }

  void _attachRemoteScreen(MediaStream stream) {
    if (stream.getVideoTracks().isEmpty) return;
    final nativeStream = stream as MediaStreamWeb;
    final video =
        _remoteScreenElement ??
        (web.HTMLVideoElement()
          ..autoplay = true
          ..controls = false
          ..muted = true
          ..setAttribute('playsinline', 'true')
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain'
          ..style.backgroundColor = '#07111e');
    if (_remoteScreenElement == null) {
      final viewType = 'meshchat-screen-${_screenViewCounter++}';
      ui_web.platformViewRegistry.registerViewFactory(
        viewType,
        (viewId) => video,
      );
      _remoteScreenViewType = viewType;
      _remoteScreenElement = video;
    }
    video.srcObject = nativeStream.jsStream;
    video.play().toDart.catchError((_) => null);
    onRemoteScreenChanged?.call();
  }

  Future<void> _stopScreenMedia() async {
    final peerConnection = _peerConnection;
    final sender = _screenSender;
    if (peerConnection != null && sender != null) {
      await peerConnection.removeTrack(sender).catchError((_) => false);
    }
    final stream = _screenStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.onEnded = null;
        track.enabled = false;
        await track.stop();
      }
    }
    _screenSender = null;
    _screenStream = null;
  }

  Map<String, dynamic> _mediaConstraints() {
    final audio = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'googEchoCancellation': true,
      'googAutoGainControl': true,
      'googNoiseSuppression': true,
      'googHighpassFilter': true,
    };
    if (_enhancedNoiseSuppression) {
      audio.addAll({
        'googTypingNoiseDetection': true,
        'googExperimentalNoiseSuppression': true,
        'googNoiseSuppression2': true,
        'googAutoGainControl2': true,
      });
    }
    if (_hdAudio) {
      audio.addAll({
        'sampleRate': {'ideal': 48000},
        'sampleSize': {'ideal': 16},
        'channelCount': {'ideal': 1},
        'latency': {'ideal': 0.01},
      });
    }
    if (_selectedAudioInputId.isNotEmpty) {
      audio['deviceId'] = {'exact': _selectedAudioInputId};
    }
    return {'audio': audio, 'video': false};
  }

  String _enhanceOpusSdp(String sdp) {
    if (!_hdAudio || sdp.isEmpty) return sdp;
    final lines = sdp.split('\r\n');
    final opusPayloads = <String>{};
    for (final line in lines) {
      final match = RegExp(
        r'^a=rtpmap:(\d+) opus/48000',
        caseSensitive: false,
      ).firstMatch(line);
      if (match != null) opusPayloads.add(match.group(1)!);
    }
    for (var index = 0; index < lines.length; index++) {
      for (final payload in opusPayloads) {
        if (!lines[index].startsWith('a=fmtp:$payload ')) continue;
        final additions = <String>[
          if (!lines[index].contains('maxaveragebitrate='))
            'maxaveragebitrate=96000',
          if (!lines[index].contains('useinbandfec=')) 'useinbandfec=1',
          if (!lines[index].contains('usedtx=')) 'usedtx=1',
        ];
        if (additions.isNotEmpty) {
          lines[index] = '${lines[index]};${additions.join(';')}';
        }
      }
    }
    return lines.join('\r\n');
  }

  Future<List<CallAudioDevice>> _devicesOfKind(String kind) async {
    final devices = await navigator.mediaDevices.enumerateDevices().catchError(
      (_) => <MediaDeviceInfo>[],
    );
    var index = 1;
    return devices.where((device) => device.kind == kind).map((device) {
      final label = device.label.trim().isEmpty
          ? (kind == 'audioinput' ? 'Microphone $index' : 'Output $index')
          : device.label.trim();
      index++;
      return CallAudioDevice(id: device.deviceId, label: label, kind: kind);
    }).toList();
  }
}
