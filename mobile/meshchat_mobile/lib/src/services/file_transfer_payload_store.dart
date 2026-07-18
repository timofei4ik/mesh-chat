import 'dart:typed_data';

import 'file_transfer_payload_store_stub.dart'
    if (dart.library.io) 'file_transfer_payload_store_io.dart'
    if (dart.library.js_interop) 'file_transfer_payload_store_web.dart'
    as platform;

class FileTransferPayloadStore {
  Future<String> write(String sessionKey, String transferId, Uint8List bytes) =>
      platform.writeFileTransferPayload(sessionKey, transferId, bytes);

  Future<Uint8List> readChunk(String reference, int offset, int length) =>
      platform.readFileTransferPayloadChunk(reference, offset, length);

  Future<bool> exists(String reference) =>
      platform.fileTransferPayloadExists(reference);

  Future<void> delete(String reference) =>
      platform.deleteFileTransferPayload(reference);
}
