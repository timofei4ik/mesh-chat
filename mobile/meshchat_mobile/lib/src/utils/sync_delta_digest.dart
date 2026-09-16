import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

Future<String> syncDeltaDigest(List<Map<String, dynamic>> envelopes) =>
    compute(_digest, envelopes);

Future<String> _digest(List<Map<String, dynamic>> envelopes) async {
  final canonical = jsonEncode(_canonical(envelopes));
  final digest = await Sha256().hash(utf8.encode(canonical));
  return digest.bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList(growable: false);
  return value;
}
