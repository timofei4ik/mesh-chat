import 'dart:convert';
import 'dart:typed_data';

final Map<String, Uint8List> _payloads = <String, Uint8List>{};

Future<String> writeFileTransferPayload(
  String sessionKey,
  String transferId,
  Uint8List bytes,
) async {
  final reference =
      'memory:${base64Url.encode(utf8.encode('$sessionKey\u0000$transferId'))}';
  _payloads[reference] = Uint8List.fromList(bytes);
  return reference;
}

Future<Uint8List> readFileTransferPayloadChunk(
  String reference,
  int offset,
  int length,
) async {
  final bytes = _payloads[reference];
  if (bytes == null || offset < 0 || length <= 0 || offset >= bytes.length) {
    return Uint8List(0);
  }
  final end = (offset + length).clamp(0, bytes.length);
  return Uint8List.fromList(bytes.sublist(offset, end));
}

Future<bool> fileTransferPayloadExists(String reference) async =>
    _payloads.containsKey(reference);

Future<void> deleteFileTransferPayload(String reference) async {
  _payloads.remove(reference);
}
