import 'dart:typed_data';

import 'incoming_file_staging_store_stub.dart'
    if (dart.library.io) 'incoming_file_staging_store_io.dart'
    as platform;

String? incomingFileStagingDirectoryOverrideForTesting;

class IncomingFileStagingStore {
  static const maximumChunkCount = 100000;

  Future<Uint8List?> putChunk({
    required String sessionKey,
    required String fileId,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List bytes,
  }) {
    if (sessionKey.isEmpty ||
        fileId.isEmpty ||
        chunkIndex < 0 ||
        totalChunks <= 0 ||
        totalChunks > maximumChunkCount ||
        chunkIndex >= totalChunks ||
        bytes.isEmpty) {
      throw const FormatException('Invalid incoming file chunk');
    }
    return platform.stageIncomingFileChunk(
      sessionKey,
      fileId,
      chunkIndex,
      totalChunks,
      bytes,
      incomingFileStagingDirectoryOverrideForTesting,
    );
  }

  Future<void> delete(String sessionKey, String fileId) =>
      platform.deleteIncomingFileStage(
        sessionKey,
        fileId,
        incomingFileStagingDirectoryOverrideForTesting,
      );
}
