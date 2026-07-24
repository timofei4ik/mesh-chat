import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_models.dart';

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
  static const _audioSession = MethodChannel('meshchat/audio_session');
  static String _selectedAudioInputId = '';
  static String _selectedAudioOutputId = '';

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;
  static bool get _isAndroid => Platform.isAndroid;
  static bool get _isIOS => Platform.isIOS;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer? _remoteAudioRenderer;
  RTCVideoRenderer? _remoteScreenRenderer;
  MediaStream? _screenStream;
  RTCRtpSender? _screenSender;
  bool _localMuted = false;
  bool _speakerEnabled = true;
  bool _hdAudio = false;
  bool _enhancedNoiseSuppression = false;
  List<Map<String, dynamic>> _iceServers = const [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  Timer? _statsTimer;
  void Function()? onRemoteScreenChanged;
  void Function()? onLocalScreenEnded;
  void Function(CallConnectionPhase phase)? onConnectionStateChanged;
  void Function(CallQualitySnapshot quality)? onQualityChanged;

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
    if (deviceId.isEmpty) return;
    await Helper.selectAudioInput(deviceId).catchError((_) {});
  }

  Future<void> selectAudioOutput(String deviceId) async {
    _selectedAudioOutputId = deviceId;
    if (deviceId.isEmpty) {
      await setSpeakerEnabled(_speakerEnabled).catchError((_) {});
      return;
    }
    await Helper.selectAudioOutput(deviceId).catchError((_) {});
    await _remoteAudioRenderer?.audioOutput(deviceId).catchError((_) => false);
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

  Future<String> createRestartOffer() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) return '';
    await peerConnection.restartIce();
    final offer = await peerConnection.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': isScreenSharing ? 1 : 0,
      'iceRestart': true,
    });
    final sdp = _enhanceOpusSdp(offer.sdp ?? '');
    await peerConnection.setLocalDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    return sdp;
  }

  Future<String> acceptRestartOffer(String remoteOfferSdp) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null || remoteOfferSdp.isEmpty) return '';
    await peerConnection.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    await _flushPendingRemoteCandidates();
    final answer = await peerConnection.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': isScreenSharing ? 1 : 0,
    });
    final sdp = _enhanceOpusSdp(answer.sdp ?? '');
    await peerConnection.setLocalDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    return sdp;
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
    _stopStats();
    await _stopScreenMedia();
    await _stopMediaTracks();
    _remoteAudioRenderer?.srcObject = null;
    await _remoteAudioRenderer?.dispose();
    _remoteScreenRenderer?.srcObject = null;
    await _remoteScreenRenderer?.dispose();
    await _localStream?.dispose();
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioRenderer = null;
    _remoteScreenRenderer = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    _speakerEnabled = true;
    _pendingRemoteCandidates.clear();
    onRemoteScreenChanged?.call();
    await _deactivateCallAudio();
    await _clearAndroidCommunicationDevice();
  }

  Future<void> _resetCurrentConnectionOnly() async {
    _stopStats();
    await _stopScreenMedia();
    await _stopMediaTracks();
    _remoteAudioRenderer?.srcObject = null;
    await _remoteAudioRenderer?.dispose();
    _remoteScreenRenderer?.srcObject = null;
    await _remoteScreenRenderer?.dispose();
    await _localStream?.dispose();
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioRenderer = null;
    _remoteScreenRenderer = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    onRemoteScreenChanged?.call();
    await _deactivateCallAudio();
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
    await _activateCallAudio();
    await _prepareMobileAudio();
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
    peerConnection.onConnectionState = _handleConnectionState;
    peerConnection.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _handleConnectionPhase(CallConnectionPhase.connected);
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          _handleConnectionPhase(CallConnectionPhase.connecting);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _handleConnectionPhase(CallConnectionPhase.disconnected);
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _handleConnectionPhase(CallConnectionPhase.failed);
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _handleConnectionPhase(CallConnectionPhase.closed);
        default:
          break;
      }
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
    await _setSpeakerphoneOnButPreferBluetooth();
    if (_selectedAudioInputId.isNotEmpty) {
      await Helper.selectAudioInput(_selectedAudioInputId).catchError((_) {});
    }
    if (_selectedAudioOutputId.isNotEmpty) {
      await Helper.selectAudioOutput(_selectedAudioOutputId).catchError((_) {});
    }
    await _activateCallAudio();
    _speakerEnabled = true;
    _localStream = stream;
    _peerConnection = peerConnection;
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        _handleConnectionPhase(CallConnectionPhase.newConnection);
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        _handleConnectionPhase(CallConnectionPhase.connecting);
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _handleConnectionPhase(CallConnectionPhase.connected);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _handleConnectionPhase(CallConnectionPhase.disconnected);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _handleConnectionPhase(CallConnectionPhase.failed);
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _handleConnectionPhase(CallConnectionPhase.closed);
    }
  }

  void _handleConnectionPhase(CallConnectionPhase phase) {
    onConnectionStateChanged?.call(phase);
    if (phase == CallConnectionPhase.connected) {
      _startStats();
    } else if (phase == CallConnectionPhase.closed ||
        phase == CallConnectionPhase.failed) {
      _stopStats();
    }
  }

  void _startStats() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _collectQuality();
    });
    _collectQuality();
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> _collectQuality() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) return;
    final reports = await peerConnection.getStats().catchError(
      (_) => <StatsReport>[],
    );
    if (reports.isEmpty) return;
    final byId = {for (final report in reports) report.id: report};
    StatsReport? selectedPair;
    StatsReport? inboundAudio;
    for (final report in reports) {
      final values = report.values;
      if (report.type == 'candidate-pair' &&
          (values['selected'] == true ||
              values['nominated'] == true &&
                  (values['state']?.toString() == 'succeeded'))) {
        selectedPair = report;
      }
      if (report.type == 'inbound-rtp' &&
          values['kind']?.toString() == 'audio') {
        inboundAudio = report;
      }
    }
    if (selectedPair == null && inboundAudio == null) return;
    final pairValues = selectedPair?.values ?? const <dynamic, dynamic>{};
    final inboundValues = inboundAudio?.values ?? const <dynamic, dynamic>{};
    final received = _asDouble(inboundValues['packetsReceived']);
    final lost = _asDouble(inboundValues['packetsLost']);
    final total = received + lost;
    final rttSeconds = _asDouble(pairValues['currentRoundTripTime']) > 0
        ? _asDouble(pairValues['currentRoundTripTime'])
        : _asDouble(pairValues['totalRoundTripTime']);
    final localCandidate = byId[pairValues['localCandidateId']?.toString()];
    final remoteCandidate = byId[pairValues['remoteCandidateId']?.toString()];
    final localType = localCandidate?.values['candidateType']?.toString() ?? '';
    final remoteType =
        remoteCandidate?.values['candidateType']?.toString() ?? '';
    final route = localType == 'relay' || remoteType == 'relay'
        ? 'turn'
        : selectedPair == null
        ? 'unknown'
        : 'direct';
    onQualityChanged?.call(
      CallQualitySnapshot(
        roundTripTimeMs: (rttSeconds * 1000).round(),
        jitterMs: (_asDouble(inboundValues['jitter']) * 1000).round(),
        packetLossPercent: total <= 0 ? 0 : (lost / total * 100),
        route: route,
      ),
    );
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> setMuted(bool muted) async {
    _localMuted = muted;
    final tracks = _localStream?.getAudioTracks() ?? <MediaStreamTrack>[];
    for (final track in tracks) {
      track.enabled = !muted;
    }
    await _activateCallAudio();
    if (_selectedAudioOutputId.isNotEmpty) {
      await Helper.selectAudioOutput(_selectedAudioOutputId).catchError((_) {});
    }
  }

  bool get isMuted => _localMuted;

  Future<void> setSpeakerEnabled(bool enabled) async {
    _speakerEnabled = enabled;
    await _activateCallAudio();
    if (!_isMobile) return;
    await Helper.setSpeakerphoneOn(enabled).catchError((_) {});
    if (enabled) {
      await _setSpeakerphoneOnButPreferBluetooth();
    } else {
      await _clearAndroidCommunicationDevice();
    }
  }

  bool get speakerEnabled => _speakerEnabled;

  bool get isScreenSharing => _screenStream != null;

  bool get hasRemoteScreen =>
      _remoteScreenRenderer?.srcObject?.getVideoTracks().isNotEmpty == true;

  Future<String> startScreenShare() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) throw StateError('Call is not active');
    await _stopScreenMedia();
    final MediaStream stream;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final sources = await desktopCapturer.getSources(
        types: const [SourceType.Screen],
      );
      if (sources.isEmpty) {
        throw StateError('No screen is available to share');
      }
      stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': sources.first.id},
          'mandatory': {'frameRate': 20.0},
        },
      });
    } else {
      stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });
    }
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) {
      await stream.dispose();
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
    _remoteScreenRenderer?.srcObject = null;
    onRemoteScreenChanged?.call();
  }

  Widget remoteScreenView() {
    final renderer = _remoteScreenRenderer;
    if (renderer == null || renderer.srcObject == null) {
      return const SizedBox.shrink();
    }
    return RTCVideoView(
      renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }

  Future<void> _attachRemoteAudio(MediaStream stream) async {
    if (stream.getAudioTracks().isEmpty) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
    final renderer = _remoteAudioRenderer ?? RTCVideoRenderer();
    if (_remoteAudioRenderer == null) {
      await renderer.initialize();
      _remoteAudioRenderer = renderer;
    }
    renderer.srcObject = stream;
    await _activateCallAudio();
    if (_selectedAudioOutputId.isNotEmpty) {
      await renderer
          .audioOutput(_selectedAudioOutputId)
          .catchError((_) => false);
    }
    await setSpeakerEnabled(_speakerEnabled).catchError((_) {});
  }

  Future<void> _attachRemoteScreen(MediaStream stream) async {
    if (stream.getVideoTracks().isEmpty) return;
    final renderer = _remoteScreenRenderer ?? RTCVideoRenderer();
    if (_remoteScreenRenderer == null) {
      await renderer.initialize();
      _remoteScreenRenderer = renderer;
    }
    renderer.srcObject = stream;
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
        await track.stop().catchError((_) {});
      }
      await stream.dispose();
    }
    _screenSender = null;
    _screenStream = null;
  }

  Future<void> _stopMediaTracks() async {
    final streams = <MediaStream>[];
    final localStream = _localStream;
    final remoteStream = _remoteAudioRenderer?.srcObject;
    if (localStream != null) streams.add(localStream);
    if (remoteStream != null) streams.add(remoteStream);
    for (final stream in streams) {
      for (final track in stream.getTracks()) {
        track.enabled = false;
        await track.stop().catchError((_) {});
      }
    }
    final peerConnection = _peerConnection;
    if (peerConnection != null) {
      final senders = await peerConnection.getSenders().catchError(
        (_) => <RTCRtpSender>[],
      );
      for (final sender in senders) {
        final track = sender.track;
        if (track == null) continue;
        track.enabled = false;
        await track.stop().catchError((_) {});
      }
    }
  }

  Future<void> _activateCallAudio() async {
    if (!_isIOS) return;
    try {
      await _audioSession.invokeMethod<void>('activateCallAudio');
    } catch (_) {}
  }

  Future<void> _deactivateCallAudio() async {
    if (!_isIOS) return;
    try {
      await _audioSession.invokeMethod<void>('deactivateCallAudio');
    } catch (_) {}
  }

  Future<void> _prepareMobileAudio() async {
    if (!_isMobile) return;
    if (_isAndroid) {
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.communication,
      ).catchError((_) {});
    }
    await Helper.ensureAudioSession().catchError((_) {});
  }

  Future<void> _setSpeakerphoneOnButPreferBluetooth() async {
    if (!_isMobile) return;
    await Helper.setSpeakerphoneOnButPreferBluetooth().catchError((_) {});
  }

  Future<void> _clearAndroidCommunicationDevice() async {
    if (!_isAndroid) return;
    await Helper.clearAndroidCommunicationDevice().catchError((_) {});
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
    if (opusPayloads.isEmpty) return sdp;
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
