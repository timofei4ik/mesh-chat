import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class MeshCrypto {
  static const encryptedPrefix = 'MCENC1:';
  static const groupPrefix = 'MCGRP1:';
  static const groupBinaryPrefix = [77, 67, 71, 66, 73, 78, 49, 58];
  static const _iterations = 300000;
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _keyPair;
  String publicKey = '';

  Future<void> initialize(String login, String password) async {
    final saltHash = await Sha256().hash(
      utf8.encode('meshchat-e2ee-identity:${login.trim().toLowerCase()}'),
    );
    final privateBytes =
        await Pbkdf2(
              macAlgorithm: Hmac.sha256(),
              iterations: _iterations,
              bits: 256,
            )
            .deriveKey(
              secretKey: SecretKey(utf8.encode(password)),
              nonce: saltHash.bytes,
            )
            .then((key) => key.extractBytes());

    _keyPair = await _x25519.newKeyPairFromSeed(privateBytes);
    final key = await _keyPair!.extractPublicKey();
    publicKey = _encode(key.bytes);
  }

  Future<String> encryptText(String recipientPublicKey, String text) async {
    if (recipientPublicKey.isEmpty || _keyPair == null) return text;
    final bytes = utf8.encode(text);
    final payload = {
      'v': 1,
      'to': await _seal(recipientPublicKey, bytes),
      'from': await _seal(publicKey, bytes),
    };
    return encryptedPrefix + _encode(utf8.encode(jsonEncode(payload)));
  }

  Future<String> decryptText(String value) async {
    if (!value.startsWith(encryptedPrefix) || _keyPair == null) return value;
    try {
      final payload =
          jsonDecode(
                utf8.decode(_decode(value.substring(encryptedPrefix.length))),
              )
              as Map<String, dynamic>;
      for (final field in const ['to', 'from']) {
        final sealed = payload[field];
        if (sealed is! Map) continue;
        try {
          return utf8.decode(await _open(Map<String, dynamic>.from(sealed)));
        } catch (_) {
          // Try another envelope copy.
        }
      }
    } catch (_) {
      // Fall through to placeholder.
    }
    return '[Зашифрованное сообщение: ключ недоступен]';
  }

  List<int> generateGroupKey() => _randomBytes(32);

  Future<String> wrapGroupKey(
    String recipientPublicKey,
    List<int> groupKey,
  ) async {
    if (recipientPublicKey.isEmpty) return '';
    return encryptText(recipientPublicKey, _encode(groupKey));
  }

  Future<List<int>?> unwrapGroupKey(String envelope) async {
    if (envelope.isEmpty) return null;
    final value = await decryptText(envelope);
    if (value.startsWith('[')) return null;
    try {
      return _decode(value);
    } catch (_) {
      return null;
    }
  }

  Future<String> encryptGroupText(List<int> groupKey, String text) async {
    final nonce = _randomBytes(12);
    final box = await _aes.encrypt(
      utf8.encode(text),
      secretKey: SecretKey(groupKey),
      nonce: nonce,
      aad: utf8.encode('meshchat-group-v1'),
    );
    return groupPrefix +
        _encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<String> decryptGroupText(List<int>? groupKey, String value) async {
    if (groupKey == null || !value.startsWith(groupPrefix)) return value;
    try {
      final payload = _decode(value.substring(groupPrefix.length));
      final box = SecretBox(
        payload.sublist(12, payload.length - 16),
        nonce: payload.sublist(0, 12),
        mac: Mac(payload.sublist(payload.length - 16)),
      );
      return utf8.decode(
        await _aes.decrypt(
          box,
          secretKey: SecretKey(groupKey),
          aad: utf8.encode('meshchat-group-v1'),
        ),
      );
    } catch (_) {
      return '[Зашифрованное сообщение: ошибка расшифровки]';
    }
  }

  Future<List<int>> encryptGroupBytes(
    List<int> groupKey,
    List<int> data,
  ) async {
    final nonce = _randomBytes(12);
    final box = await _aes.encrypt(
      data,
      secretKey: SecretKey(groupKey),
      nonce: nonce,
      aad: utf8.encode('meshchat-group-file-v1'),
    );
    return [
      ...groupBinaryPrefix,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
  }

  Future<List<int>> decryptGroupBytes(
    List<int>? groupKey,
    List<int> data,
  ) async {
    if (groupKey == null || !_hasPrefix(data, groupBinaryPrefix)) return data;
    final payload = data.sublist(groupBinaryPrefix.length);
    final box = SecretBox(
      payload.sublist(12, payload.length - 16),
      nonce: payload.sublist(0, 12),
      mac: Mac(payload.sublist(payload.length - 16)),
    );
    return _aes.decrypt(
      box,
      secretKey: SecretKey(groupKey),
      aad: utf8.encode('meshchat-group-file-v1'),
    );
  }

  Future<Map<String, String>> _seal(
    String recipientPublicKey,
    List<int> plaintext,
  ) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        _decode(recipientPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('meshchat-e2ee-v1'),
    );
    final nonce = _randomBytes(12);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode('meshchat-e2ee-v1'),
    );
    return {
      'e': _encode(ephemeralPublic.bytes),
      'n': _encode(nonce),
      'c': _encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  Future<List<int>> _open(Map<String, dynamic> sealed) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: SimplePublicKey(
        _decode(sealed['e'].toString()),
        type: KeyPairType.x25519,
      ),
    );
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('meshchat-e2ee-v1'),
    );
    final combined = _decode(sealed['c'].toString());
    final box = SecretBox(
      combined.sublist(0, combined.length - 16),
      nonce: _decode(sealed['n'].toString()),
      mac: Mac(combined.sublist(combined.length - 16)),
    );
    return _aes.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode('meshchat-e2ee-v1'),
    );
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static String _encode(List<int> bytes) => base64Url.encode(bytes);

  static List<int> _decode(String value) {
    final padding = (4 - value.length % 4) % 4;
    return base64Url.decode(value + ('=' * padding));
  }

  static bool _hasPrefix(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}
