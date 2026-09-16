import 'dart:convert';

import 'package:flutter/foundation.dart';

Future<String> encodeBackgroundJson(Object? value) =>
    compute(jsonEncode, value);

Future<dynamic> decodeBackgroundJson(String value) => value.length < 256 * 1024
    ? Future.value(jsonDecode(value))
    : compute(jsonDecode, value);

Future<Uint8List> encodeBackgroundUtf8(String value) =>
    value.length < 256 * 1024
    ? Future.value(utf8.encode(value))
    : compute(_encodeUtf8, value);

Future<String> decodeBackgroundUtf8(Uint8List value) =>
    value.length < 256 * 1024
    ? Future.value(utf8.decode(value))
    : compute(_decodeUtf8, value);

Uint8List _encodeUtf8(String value) => utf8.encode(value);
String _decodeUtf8(Uint8List value) => utf8.decode(value);

Future<Map<String, dynamic>> decodeBackgroundPacket(Uint8List bytes) =>
    compute(_decodePacket, bytes);

Map<String, dynamic> _decodePacket(Uint8List bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
