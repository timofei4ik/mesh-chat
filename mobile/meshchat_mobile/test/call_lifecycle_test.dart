import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/services/call_service.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

void main() {
  group('group signal isolation', () {
    test(
      'direct answer from another authenticated peer device remains valid',
      () {
        final direct = ActiveCall(
          callId: 'current',
          peer: Profile(
            nodeId: 'old-device',
            displayName: 'Alice',
            accountLogin: 'alice',
          ),
          status: CallStatus.outgoing,
          incoming: false,
          startedAt: DateTime(2026),
        );
        expect(
          direct.acceptsSignal({
            'call_id': 'current',
            'source_node': 'new-device',
            'sender_login': 'alice',
          }),
          isTrue,
        );
        expect(
          direct.acceptsSignal({
            'call_id': 'old',
            'source_node': 'new-device',
            'sender_login': 'alice',
          }),
          isFalse,
        );
      },
    );
    final call = ActiveCall(
      callId: 'current',
      peer: Profile(nodeId: 'host', displayName: 'Host'),
      status: CallStatus.active,
      incoming: true,
      startedAt: DateTime(2026),
      isGroup: true,
      groupId: 'group',
      groupMembers: ['guest-a', 'guest-b'],
    );
    test('old call end and unknown sources cannot affect current call', () {
      expect(
        call.acceptsSignal({'call_id': 'old', 'source_node': 'host'}),
        isFalse,
      );
      expect(
        call.acceptsSignal({'call_id': 'current', 'source_node': 'outsider'}),
        isFalse,
      );
      expect(
        call.acceptsSignal({'call_id': 'current', 'source_node': 'host'}),
        isTrue,
      );
      expect(
        call.copyWith(status: CallStatus.ended).acceptsSignal({
          'call_id': 'current',
          'source_node': 'host',
        }),
        isFalse,
      );
    });
    test(
      'guest captions are allowed but guest end cannot hang up host link',
      () {
        final packet = {
          'call_id': 'current',
          'source_node': 'guest-b',
          'group_id': 'group',
        };
        expect(call.acceptsSignal(packet, caption: true), isTrue);
        expect(call.acceptsSignal(packet), isFalse);
        expect(
          call.acceptsSignal({...packet, 'group_id': 'other'}, caption: true),
          isFalse,
        );
      },
    );
  });
  group('caption updates', () {
    CallCaptionLine line({
      String source = 'guest-a',
      String text = 'Hello',
      bool finalText = true,
      int revision = 2,
      String translation = '',
    }) => CallCaptionLine(
      id: 'phrase',
      sourceNode: source,
      speaker: source,
      text: text,
      isFinal: finalText,
      updatedAt: DateTime(2026),
      revision: revision,
      translation: translation,
    );
    test('late partial never replaces a final translation', () {
      final complete = line(translation: 'Bonjour');
      expect(
        identical(
          complete.mergeUpdate(line(finalText: false, revision: 3)),
          complete,
        ),
        isTrue,
      );
    });
    test('out of order final revisions are ignored', () {
      final complete = line(revision: 5, text: 'Hello everyone');
      expect(complete.mergeUpdate(line(revision: 4)).text, 'Hello everyone');
    });
    test('duplicate source text preserves already received translation', () {
      expect(
        line(translation: 'Bonjour').mergeUpdate(line(revision: 3)).translation,
        'Bonjour',
      );
    });
    test('changed phrase does not retain an unrelated translation', () {
      expect(
        line(
          translation: 'Bonjour',
        ).mergeUpdate(line(text: 'Goodbye', revision: 3)).translation,
        isEmpty,
      );
    });
    test('same caption id from different speakers is not merged', () {
      final other = line(source: 'guest-b', text: 'Another speaker');
      expect(identical(line().mergeUpdate(other), other), isTrue);
    });
  });
  test(
    'ICE candidates wait until the remote description is installed',
    () async {
      final peer = _FakePeerConnection();
      final service = CallService.withPeerConnection(peer);
      await service.addIceCandidate({'candidate': 'early', 'sdpMLineIndex': 0});
      expect(peer.candidates, isEmpty);
      final answer = service.applyAnswer('remote-answer');
      await service.addIceCandidate({
        'candidate': 'during-sdp',
        'sdpMLineIndex': 0,
      });
      expect(peer.candidates, isEmpty);
      peer.descriptionGate.complete();
      await answer;
      expect(peer.candidates, ['early', 'during-sdp']);
      await service.addIceCandidate({'candidate': 'ready', 'sdpMLineIndex': 0});
      expect(peer.candidates, ['early', 'during-sdp', 'ready']);
    },
  );
  group('call lifecycle', () {
    test('supports ringing through connected to ended', () {
      expect(
        isValidCallTransition(CallStatus.ringing, CallStatus.connecting),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.connecting, CallStatus.active),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.active, CallStatus.ended),
        isTrue,
      );
    });

    test('supports reconnect and rejects resurrection after end', () {
      expect(
        isValidCallTransition(CallStatus.active, CallStatus.connecting),
        isTrue,
      );
      expect(
        isValidCallTransition(CallStatus.ended, CallStatus.active),
        isFalse,
      );
    });
  });

  group('call quality', () {
    test('rates direct healthy audio as excellent', () {
      const quality = CallQualitySnapshot(
        roundTripTimeMs: 45,
        jitterMs: 8,
        packetLossPercent: 0.2,
        route: 'direct',
      );
      expect(quality.qualityLevel, 3);
    });

    test('rates high loss TURN audio as poor', () {
      const quality = CallQualitySnapshot(
        roundTripTimeMs: 510,
        jitterMs: 110,
        packetLossPercent: 12,
        route: 'turn',
      );
      expect(quality.qualityLevel, 1);
    });
  });
}

class _FakePeerConnection extends Fake implements RTCPeerConnection {
  final descriptionGate = Completer<void>();
  final candidates = <String?>[];
  bool ready = false;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await descriptionGate.future;
    ready = true;
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (!ready) throw StateError('Remote description is missing');
    candidates.add(candidate.candidate);
  }
}
