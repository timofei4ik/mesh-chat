import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _databaseName = 'meshchat_file_transfer_payloads';
const _storeName = 'payloads';
Future<web.IDBDatabase>? _database;

Future<web.IDBDatabase> _openDatabase() {
  return _database ??= (() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      database.createObjectStore(_storeName);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.complete(request.result as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(request.error?.message ?? 'IndexedDB open failed'),
        );
      }
    }).toJS;
    return completer.future;
  })();
}

Future<JSAny?> _waitForRequest(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) {
    if (!completer.isCompleted) completer.complete(request.result);
  }).toJS;
  request.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError(request.error?.message ?? 'IndexedDB request failed'),
      );
    }
  }).toJS;
  return completer.future;
}

Future<String> writeFileTransferPayload(
  String sessionKey,
  String transferId,
  Uint8List bytes,
) async {
  final reference =
      'idb:${base64Url.encode(utf8.encode('$sessionKey\u0000$transferId'))}';
  final database = await _openDatabase();
  final transaction = database.transaction(_storeName.toJS, 'readwrite');
  final store = transaction.objectStore(_storeName);
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS);
  await _waitForRequest(store.put(blob, reference.toJS));
  return reference;
}

Future<Uint8List> readFileTransferPayloadChunk(
  String reference,
  int offset,
  int length,
) async {
  if (reference.isEmpty || offset < 0 || length <= 0) return Uint8List(0);
  final database = await _openDatabase();
  final transaction = database.transaction(_storeName.toJS, 'readonly');
  final result = await _waitForRequest(
    transaction.objectStore(_storeName).get(reference.toJS),
  );
  if (result == null || !result.isA<web.Blob>()) return Uint8List(0);
  final blob = result as web.Blob;
  if (offset >= blob.size) return Uint8List(0);
  final end = (offset + length).clamp(0, blob.size);
  final buffer = await blob.slice(offset, end).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

Future<bool> fileTransferPayloadExists(String reference) async {
  if (reference.isEmpty) return false;
  final database = await _openDatabase();
  final transaction = database.transaction(_storeName.toJS, 'readonly');
  final result = await _waitForRequest(
    transaction.objectStore(_storeName).get(reference.toJS),
  );
  return result != null;
}

Future<void> deleteFileTransferPayload(String reference) async {
  if (reference.isEmpty) return;
  final database = await _openDatabase();
  final transaction = database.transaction(_storeName.toJS, 'readwrite');
  await _waitForRequest(
    transaction.objectStore(_storeName).delete(reference.toJS),
  );
}
