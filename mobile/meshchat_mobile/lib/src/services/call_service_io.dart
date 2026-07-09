import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
  bool _localMuted = false;
  bool _speakerEnabled = true;
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];

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
  }) async {
    await _preparePeerConnection(onIceCandidate: onIceCandidate);
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await _peerConnection!.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  Future<String> acceptIncoming({
    required String remoteOfferSdp,
    required void Function(Map<String, dynamic> candidate) onIceCandidate,
  }) async {
    await _preparePeerConnection(onIceCandidate: onIceCandidate);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(remoteOfferSdp, 'offer'),
    );
    await _flushPendingRemoteCandidates();
    final answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await _peerConnection!.setLocalDescription(answer);
    return answer.sdp ?? '';
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
    await _stopMediaTracks();
    _remoteAudioRenderer?.srcObject = null;
    await _remoteAudioRenderer?.dispose();
    await _localStream?.dispose();
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioRenderer = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    _speakerEnabled = true;
    _pendingRemoteCandidates.clear();
    await _deactivateCallAudio();
    await _clearAndroidCommunicationDevice();
  }

  Future<void> _resetCurrentConnectionOnly() async {
    await _stopMediaTracks();
    _remoteAudioRenderer?.srcObject = null;
    await _remoteAudioRenderer?.dispose();
    await _localStream?.dispose();
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioRenderer = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
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
  }) async {
    await _resetCurrentConnectionOnly();
    await _activateCallAudio();
    await _prepareMobileAudio();
    final peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
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
      if (event.track.kind != 'audio' || event.streams.isEmpty) return;
      _attachRemoteAudio(event.streams.first);
    };
    peerConnection.onAddStream = _attachRemoteAudio;

    final stream = await navigator.mediaDevices.getUserMedia(
      _mediaConstraints(),
    );
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
    if (_selectedAudioInputId.isNotEmpty) {
      audio['deviceId'] = {'exact': _selectedAudioInputId};
    }
    return {'audio': audio, 'video': false};
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
