import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> writeFileTransferPayload(
  String sessionKey,
  String transferId,
  Uint8List bytes,
) async {
  final support = await getApplicationSupportDirectory();
  final digest = await Sha256().hash(
    utf8.encode('$sessionKey\u0000$transferId'),
  );
  final name = base64Url.encode(digest.bytes).replaceAll('=', '');
  final directory = Directory(p.join(support.path, 'meshchat_file_outbox'));
  await directory.create(recursive: true);
  final target = File(p.join(directory.path, '$name.bin'));
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
  return target.path;
}

Future<Uint8List> readFileTransferPayloadChunk(
  String reference,
  int offset,
  int length,
) async {
  if (reference.isEmpty || offset < 0 || length <= 0) return Uint8List(0);
  final file = File(reference);
  if (!await file.exists()) return Uint8List(0);
  final handle = await file.open(mode: FileMode.read);
  try {
    await handle.setPosition(offset);
    return Uint8List.fromList(await handle.read(length));
  } finally {
    await handle.close();
  }
}

Future<bool> fileTransferPayloadExists(String reference) async =>
    reference.isNotEmpty && File(reference).existsSync();

Future<void> deleteFileTransferPayload(String reference) async {
  if (reference.isEmpty) return;
  final file = File(reference);
  if (await file.exists()) await file.delete();
}
