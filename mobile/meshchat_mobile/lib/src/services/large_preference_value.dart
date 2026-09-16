import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_transfer_payload_store.dart';

// Keep only a small reference in browser localStorage; media lives in IndexedDB.
class LargePreferenceValue {
  LargePreferenceValue({FileTransferPayloadStore? payloads, bool? usePayloads})
    : _payloads = payloads ?? FileTransferPayloadStore(),
      _usePayloads = usePayloads ?? kIsWeb;

  final FileTransferPayloadStore _payloads;
  final bool _usePayloads;

  Future<String?> read(SharedPreferences prefs, String key) async {
    if (!_usePayloads) return prefs.getString(key);
    final reference = prefs.getString('$key:blob');
    if (reference == null) return prefs.getString(key);
    final bytes = await _payloads.readChunk(reference, 0, 0x7fffffff);
    return bytes.isEmpty ? null : utf8.decode(bytes);
  }

  Future<void> write(SharedPreferences prefs, String key, String value) async {
    if (!_usePayloads) {
      await prefs.setString(key, value);
      return;
    }
    final reference = await _payloads.write(
      'large_preferences',
      key,
      utf8.encode(value),
    );
    await prefs.setString('$key:blob', reference);
    await prefs.remove(key);
  }

  Future<void> remove(SharedPreferences prefs, String key) async {
    final reference = prefs.getString('$key:blob');
    if (_usePayloads && reference != null) await _payloads.delete(reference);
    await prefs.remove('$key:blob');
    await prefs.remove(key);
  }
}
