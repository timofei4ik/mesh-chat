import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

class CallService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  web.HTMLAudioElement? _remoteAudioElement;
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
    _remoteAudioElement?.srcObject = null;
    _remoteAudioElement?.remove();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioElement = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
    _speakerEnabled = true;
    _pendingRemoteCandidates.clear();
  }

  Future<void> _resetCurrentConnectionOnly() async {
    _remoteAudioElement?.srcObject = null;
    _remoteAudioElement?.remove();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _remoteAudioElement = null;
    _localStream = null;
    _peerConnection = null;
    _localMuted = false;
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
      'audio': true,
      'video': false,
    });
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
    audio.play().toDart.catchError((_) => null);
  }
}
