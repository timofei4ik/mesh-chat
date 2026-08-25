import 'dart:typed_data';

final Map<String, _MemoryStage> _stages = <String, _MemoryStage>{};

Future<Uint8List?> stageIncomingFileChunk(
  String sessionKey,
  String fileId,
  int chunkIndex,
  int totalChunks,
  Uint8List bytes,
  String? directoryOverride,
) async {
  final key = '$sessionKey\u0000$fileId';
  var stage = _stages[key];
  if (stage == null || stage.totalChunks != totalChunks) {
    stage = _MemoryStage(totalChunks);
    _stages[key] = stage;
  }
  stage.chunks[chunkIndex] = Uint8List.fromList(bytes);
  if (stage.chunks.length != totalChunks) return null;
  final builder = BytesBuilder(copy: false);
  for (var index = 0; index < totalChunks; index++) {
    final chunk = stage.chunks[index];
    if (chunk == null) return null;
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> deleteIncomingFileStage(
  String sessionKey,
  String fileId,
  String? directoryOverride,
) async {
  _stages.remove('$sessionKey\u0000$fileId');
}

class _MemoryStage {
  _MemoryStage(this.totalChunks);

  final int totalChunks;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
}
