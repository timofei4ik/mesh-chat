import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class EncryptionUnavailableException implements Exception {
  const EncryptionUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MeshCrypto {
  static const encryptedPrefix = 'MCENC1:';
  static const groupPrefix = 'MCGRP1:';
  static const groupBinaryPrefix = [77, 67, 71, 66, 73, 78, 49, 58];
  static const _iterations = 300000;
  static const _publicKeyLength = 32;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _maxTextEnvelopeBytes = 8 * 1024 * 1024;
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _keyPair;
  List<int>? _identitySeed;
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

    await _initializeFromSeed(privateBytes);
  }

  Future<String> createIdentityRecovery(
    String login,
    String newPassword,
  ) async {
    final seed = _identitySeed;
    if (seed == null || seed.length != 32) {
      throw StateError('Encryption identity is not initialized');
    }
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final wrappingKey = await _recoveryKey(newPassword, salt);
    final box = await _aes.encrypt(
      seed,
      secretKey: wrappingKey,
      nonce: nonce,
      aad: _recoveryAad(login),
    );
    return jsonEncode({
      'v': 1,
      'i': _iterations,
      's': _encode(salt),
      'n': _encode(nonce),
      'c': _encode(box.cipherText),
      'm': _encode(box.mac.bytes),
    });
  }

  Future<bool> initializeFromIdentityRecovery(
    String login,
    String password,
    String recovery,
  ) async {
    try {
      final decoded = jsonDecode(recovery);
      if (decoded is! Map || decoded['v'] != 1 || decoded['i'] != _iterations) {
        return false;
      }
      final salt = _decode(decoded['s']?.toString() ?? '');
      final nonce = _decode(decoded['n']?.toString() ?? '');
      final cipherText = _decode(decoded['c']?.toString() ?? '');
      final mac = _decode(decoded['m']?.toString() ?? '');
      if (salt.length != 16 ||
          nonce.length != 12 ||
          cipherText.length != 32 ||
          mac.length != 16) {
        return false;
      }
      final seed = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: await _recoveryKey(password, salt),
        aad: _recoveryAad(login),
      );
      if (seed.length != 32) return false;
      await _initializeFromSeed(seed);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _initializeFromSeed(List<int> seed) async {
    final seedCopy = List<int>.from(seed);
    _identitySeed = seedCopy;
    _keyPair = await _x25519.newKeyPairFromSeed(seedCopy);
    final key = await _keyPair!.extractPublicKey();
    publicKey = _encode(key.bytes);
  }

  Future<SecretKey> _recoveryKey(String password, List<int> salt) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }

  List<int> _recoveryAad(String login) =>
      utf8.encode('meshchat-e2ee-recovery-v1:${login.trim().toLowerCase()}');

  Future<String> encryptText(String recipientPublicKey, String text) async {
    if (_keyPair == null) {
      throw const EncryptionUnavailableException(
        'Encryption identity is not initialized',
      );
    }
    if (!_isValidPublicKey(recipientPublicKey)) {
      throw const EncryptionUnavailableException(
        'Recipient encryption key is unavailable',
      );
    }
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
      if (value.length > _maxTextEnvelopeBytes) {
        throw const FormatException('Encrypted message is too large');
      }
      final payload =
          jsonDecode(
                utf8.decode(_decode(value.substring(encryptedPrefix.length))),
              )
              as Map<String, dynamic>;
      if (payload['v'] != 1) {
        throw const FormatException('Unsupported encrypted message version');
      }
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
    _validateGroupKey(groupKey);
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
      _validateGroupKey(groupKey);
      final payload = _decode(value.substring(groupPrefix.length));
      if (payload.length < _nonceLength + _macLength) {
        throw const FormatException('Invalid encrypted group message');
      }
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
    _validateGroupKey(groupKey);
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
    _validateGroupKey(groupKey);
    final payload = data.sublist(groupBinaryPrefix.length);
    if (payload.length < _nonceLength + _macLength) {
      throw const FormatException('Invalid encrypted group file');
    }
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
    if (!_isValidPublicKey(recipientPublicKey)) {
      throw const EncryptionUnavailableException(
        'Recipient encryption key is invalid',
      );
    }
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
    final ephemeralBytes = _decode(sealed['e']?.toString() ?? '');
    final nonce = _decode(sealed['n']?.toString() ?? '');
    final combined = _decode(sealed['c']?.toString() ?? '');
    if (ephemeralBytes.length != _publicKeyLength ||
        nonce.length != _nonceLength ||
        combined.length < _macLength ||
        combined.length > _maxTextEnvelopeBytes) {
      throw const FormatException('Invalid encrypted message envelope');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: SimplePublicKey(
        ephemeralBytes,
        type: KeyPairType.x25519,
      ),
    );
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('meshchat-e2ee-v1'),
    );
    final box = SecretBox(
      combined.sublist(0, combined.length - 16),
      nonce: nonce,
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

  static bool _isValidPublicKey(String value) {
    if (value.isEmpty || value.length > 128) return false;
    try {
      return _decode(value).length == _publicKeyLength;
    } catch (_) {
      return false;
    }
  }

  static void _validateGroupKey(List<int> key) {
    if (key.length != 32) {
      throw const FormatException('Invalid group encryption key');
    }
  }

  static bool _hasPrefix(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}
