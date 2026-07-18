import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/mesh_crypto.dart';

void main() {
  test(
    'password recovery preserves the existing encryption identity',
    () async {
      final recipient = MeshCrypto();
      final sender = MeshCrypto();
      await recipient.initialize('eblan4k', 'old-password');
      await sender.initialize('sender', 'sender-password');

      final originalPublicKey = recipient.publicKey;
      final encrypted = await sender.encryptText(
        originalPublicKey,
        'history stays readable',
      );
      final recovery = await recipient.createIdentityRecovery(
        'eblan4k',
        'new-password',
      );

      final restored = MeshCrypto();
      expect(
        await restored.initializeFromIdentityRecovery(
          'eblan4k',
          'new-password',
          recovery,
        ),
        isTrue,
      );
      expect(restored.publicKey, originalPublicKey);
      expect(await restored.decryptText(encrypted), 'history stays readable');
    },
  );

  test('password recovery rejects the wrong password and account', () async {
    final original = MeshCrypto();
    await original.initialize('eblan4k', 'old-password');
    final recovery = await original.createIdentityRecovery(
      'eblan4k',
      'new-password',
    );

    expect(
      await MeshCrypto().initializeFromIdentityRecovery(
        'eblan4k',
        'wrong-password',
        recovery,
      ),
      isFalse,
    );
    expect(
      await MeshCrypto().initializeFromIdentityRecovery(
        'another-account',
        'new-password',
        recovery,
      ),
      isFalse,
    );
  });
}
