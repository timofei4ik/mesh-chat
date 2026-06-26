import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class CallService {
  static const _audioSession = MethodChannel('meshchat/audio_session');

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer? _remoteAudioRenderer;
  bool _localMuted = false;
  bool _speakerEnabled = true;
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];

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
    await Helper.clearAndroidCommunicationDevice().catchError((_) {});
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
    await Helper.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    ).catchError((_) {});
    await Helper.ensureAudioSession().catchError((_) {});
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

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
      await peerConnection.addTrack(track, stream);
    }
    await Helper.setSpeakerphoneOnButPreferBluetooth().catchError((_) {});
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
      await Helper.setMicrophoneMute(muted, track).catchError((_) {});
    }
  }

  bool get isMuted => _localMuted;

  Future<void> setSpeakerEnabled(bool enabled) async {
    _speakerEnabled = enabled;
    await _activateCallAudio();
    await Helper.setSpeakerphoneOn(enabled).catchError((_) {});
    if (enabled) {
      await Helper.setSpeakerphoneOnButPreferBluetooth().catchError((_) {});
    } else {
      await Helper.clearAndroidCommunicationDevice().catchError((_) {});
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
    try {
      await _audioSession.invokeMethod<void>('activateCallAudio');
    } catch (_) {}
  }

  Future<void> _deactivateCallAudio() async {
    try {
      await _audioSession.invokeMethod<void>('deactivateCallAudio');
    } catch (_) {}
  }
}
