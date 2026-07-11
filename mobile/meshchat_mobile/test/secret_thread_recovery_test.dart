import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/session.dart';

void main() {
  test('secret chat id is stable across account devices', () async {
    final expectedId = await _secretId(
      'meshchat-secret-v2',
      'alice',
      'bob',
      'quiet-room',
    );
    final controller = AppController()
      ..session = const Session(
        serverUrl: 'wss://example.test/ws',
        serverToken: 'token',
        login: 'Alice',
        password: 'password',
        publicUsername: 'alice',
        nodeId: 'alice-new-device',
      );
    final peer = const Profile(
      nodeId: 'bob-new-device',
      displayName: 'Bob',
      accountLogin: 'Bob',
      nodeAliases: ['bob-old-device', 'bob-new-device'],
    );
    final expected = ChatThread(
      profile: peer,
      threadId: expectedId,
      chatKind: 'secret',
    );
    controller.threads[expectedId] = expected;

    final restored = await controller.ensureSecretThread(
      peer,
      ' Quiet   Room ',
    );

    expect(restored, same(expected));
    expect(restored.threadId, expectedId);
  });

  test('legacy secret chat is found through old node aliases', () async {
    final legacyId = await _secretId(
      'meshchat-secret-v1',
      'alice-old-device',
      'bob-old-device',
      'legacy-code',
    );
    final controller = AppController()
      ..session = const Session(
        serverUrl: 'wss://example.test/ws',
        serverToken: 'token',
        login: 'Alice',
        password: 'password',
        publicUsername: 'alice',
        nodeId: 'alice-new-device',
      );
    controller.profiles['alice-new-device'] = const Profile(
      nodeId: 'alice-new-device',
      displayName: 'Alice',
      accountLogin: 'alice',
      nodeAliases: ['alice-old-device', 'alice-new-device'],
    );
    const peer = Profile(
      nodeId: 'bob-new-device',
      displayName: 'Bob',
      accountLogin: 'bob',
      nodeAliases: ['bob-old-device', 'bob-new-device'],
    );
    final expected = ChatThread(
      profile: peer,
      threadId: legacyId,
      chatKind: 'secret',
    );
    controller.threads[legacyId] = expected;

    final restored = await controller.ensureSecretThread(peer, 'legacy-code');

    expect(restored, same(expected));
    expect(restored.threadId, legacyId);
  });

  test('profile account identity and aliases survive serialization', () {
    const profile = Profile(
      nodeId: 'device-new',
      displayName: 'Alice',
      accountLogin: 'alice',
      nodeAliases: ['device-old', 'device-new'],
      avatarData: 'avatar-payload',
    );

    final restored = Profile.fromJson(profile.toJson());

    expect(restored.accountLogin, 'alice');
    expect(restored.nodeAliases, ['device-old', 'device-new']);
    expect(restored.avatarData, 'avatar-payload');
  });
}

Future<String> _secretId(
  String version,
  String firstIdentity,
  String secondIdentity,
  String code,
) async {
  final identities = [firstIdentity, secondIdentity]..sort();
  final digest = await Sha256().hash(
    utf8.encode('$version:${identities.join(':')}:$code'),
  );
  return 'secret:${base64Url.encode(digest.bytes).replaceAll('=', '')}';
}
