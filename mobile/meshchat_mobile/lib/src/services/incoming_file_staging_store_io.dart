import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<Uint8List?> stageIncomingFileChunk(
  String sessionKey,
  String fileId,
  int chunkIndex,
  int totalChunks,
  Uint8List bytes,
  String? directoryOverride,
) async {
  final directory = await _transferDirectory(
    sessionKey,
    fileId,
    directoryOverride,
  );
  await directory.create(recursive: true);
  final totalFile = File(p.join(directory.path, 'total'));
  if (await totalFile.exists()) {
    final storedTotal = int.tryParse(await totalFile.readAsString());
    if (storedTotal != totalChunks) {
      await directory.delete(recursive: true);
      await directory.create(recursive: true);
    }
  }
  if (!await totalFile.exists()) {
    await _writeAtomic(totalFile, utf8.encode(totalChunks.toString()));
  }

  final chunk = File(
    p.join(directory.path, chunkIndex.toString().padLeft(8, '0')),
  );
  await _writeAtomic(chunk, bytes);

  final chunks = <File>[];
  for (var index = 0; index < totalChunks; index++) {
    final candidate = File(
      p.join(directory.path, index.toString().padLeft(8, '0')),
    );
    if (!await candidate.exists()) return null;
    chunks.add(candidate);
  }
  final builder = BytesBuilder(copy: false);
  for (final candidate in chunks) {
    builder.add(await candidate.readAsBytes());
  }
  return builder.takeBytes();
}

Future<void> deleteIncomingFileStage(
  String sessionKey,
  String fileId,
  String? directoryOverride,
) async {
  if (sessionKey.isEmpty || fileId.isEmpty) return;
  final directory = await _transferDirectory(
    sessionKey,
    fileId,
    directoryOverride,
  );
  if (await directory.exists()) await directory.delete(recursive: true);
}

Future<void> _writeAtomic(File target, List<int> bytes) async {
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
}

Future<Directory> _transferDirectory(
  String sessionKey,
  String fileId,
  String? directoryOverride,
) async {
  final support = directoryOverride == null
      ? await getApplicationSupportDirectory()
      : Directory(directoryOverride);
  final sessionHash = await _digest(sessionKey);
  final fileHash = await _digest(fileId);
  return Directory(
    p.join(support.path, 'meshchat_incoming_files', sessionHash, fileHash),
  );
}

Future<String> _digest(String value) async {
  final digest = await Sha256().hash(utf8.encode(value));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
