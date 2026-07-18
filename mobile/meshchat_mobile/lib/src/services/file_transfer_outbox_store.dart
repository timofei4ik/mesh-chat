import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/session.dart';
import 'app_database_path.dart';
import 'file_transfer_payload_store.dart';

class FileTransferOutboxEntry {
  const FileTransferOutboxEntry({
    required this.transferId,
    required this.operationId,
    required this.fileId,
    required this.destinationNode,
    required this.packet,
    required this.payloadReference,
    required this.sizeBytes,
    required this.sha256,
    required this.chunkSize,
    required this.totalChunks,
    required this.createdAt,
    this.acknowledgedChunks = const <int>{},
    this.status = 'queued',
    this.lastError = '',
    this.attempts = 0,
  });

  final String transferId;
  final String operationId;
  final String fileId;
  final String destinationNode;
  final Map<String, dynamic> packet;
  final String payloadReference;
  final int sizeBytes;
  final String sha256;
  final int chunkSize;
  final int totalChunks;
  final DateTime createdAt;
  final Set<int> acknowledgedChunks;
  final String status;
  final String lastError;
  final int attempts;

  bool get isComplete => status == 'complete';
  bool get isFailed => status == 'failed';
  double get progress => totalChunks <= 0
      ? 0
      : (acknowledgedChunks.length / totalChunks).clamp(0.0, 1.0);

  FileTransferOutboxEntry copyWith({
    String? payloadReference,
    Set<int>? acknowledgedChunks,
    String? status,
    String? lastError,
    int? attempts,
  }) => FileTransferOutboxEntry(
    transferId: transferId,
    operationId: operationId,
    fileId: fileId,
    destinationNode: destinationNode,
    packet: packet,
    payloadReference: payloadReference ?? this.payloadReference,
    sizeBytes: sizeBytes,
    sha256: sha256,
    chunkSize: chunkSize,
    totalChunks: totalChunks,
    createdAt: createdAt,
    acknowledgedChunks: acknowledgedChunks ?? this.acknowledgedChunks,
    status: status ?? this.status,
    lastError: lastError ?? this.lastError,
    attempts: attempts ?? this.attempts,
  );

  factory FileTransferOutboxEntry.fromJson(Map<String, dynamic> json) {
    final packet = json['packet'];
    final acknowledged = json['acknowledged_chunks'];
    return FileTransferOutboxEntry(
      transferId: json['transfer_id']?.toString() ?? '',
      operationId: json['operation_id']?.toString() ?? '',
      fileId: json['file_id']?.toString() ?? '',
      destinationNode: json['destination_node']?.toString() ?? '',
      packet: packet is Map
          ? Map<String, dynamic>.from(packet)
          : const <String, dynamic>{},
      payloadReference: json['payload_reference']?.toString() ?? '',
      sizeBytes: int.tryParse(json['size_bytes']?.toString() ?? '') ?? 0,
      sha256: json['sha256']?.toString() ?? '',
      chunkSize: int.tryParse(json['chunk_size']?.toString() ?? '') ?? 0,
      totalChunks: int.tryParse(json['total_chunks']?.toString() ?? '') ?? 0,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      acknowledgedChunks: acknowledged is List
          ? acknowledged
                .map((value) => int.tryParse(value.toString()))
                .whereType<int>()
                .toSet()
          : const <int>{},
      status: json['status']?.toString() ?? 'queued',
      lastError: json['last_error']?.toString() ?? '',
      attempts: int.tryParse(json['attempts']?.toString() ?? '') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'transfer_id': transferId,
    'operation_id': operationId,
    'file_id': fileId,
    'destination_node': destinationNode,
    'packet': packet,
    'payload_reference': payloadReference,
    'size_bytes': sizeBytes,
    'sha256': sha256,
    'chunk_size': chunkSize,
    'total_chunks': totalChunks,
    'created_at': createdAt.toUtc().toIso8601String(),
    'acknowledged_chunks': acknowledgedChunks.toList()..sort(),
    'status': status,
    'last_error': lastError,
    'attempts': attempts,
  };
}

class FileTransferOutboxStore {
  FileTransferOutboxStore({
    FileTransferPayloadStore? payloadStore,
    this.databaseName = 'meshchat_file_transfer_outbox.db',
  }) : _payloadStore = payloadStore ?? FileTransferPayloadStore(),
       assert(databaseName != '');

  static const _preferencesPrefix = 'meshchat_file_transfer_outbox_v1:';
  static final Map<String, Database> _databases = <String, Database>{};

  final FileTransferPayloadStore _payloadStore;
  final String databaseName;

  Future<FileTransferOutboxEntry> create(
    Session session, {
    required String transferId,
    required String operationId,
    required String fileId,
    required String destinationNode,
    required Map<String, dynamic> packet,
    required Uint8List bytes,
    required int chunkSize,
  }) async {
    if (bytes.isEmpty || chunkSize <= 0) {
      throw ArgumentError('File transfer payload must not be empty');
    }
    final digest = await Sha256().hash(bytes);
    final sha256 = digest.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final reference = await _payloadStore.write(
      sessionKey(session),
      operationId,
      bytes,
    );
    final entry = FileTransferOutboxEntry(
      transferId: transferId,
      operationId: operationId,
      fileId: fileId,
      destinationNode: destinationNode,
      packet: Map<String, dynamic>.from(packet)..remove('data'),
      payloadReference: reference,
      sizeBytes: bytes.length,
      sha256: sha256,
      chunkSize: chunkSize,
      totalChunks: (bytes.length + chunkSize - 1) ~/ chunkSize,
      createdAt: DateTime.now().toUtc(),
    );
    await put(session, entry);
    return entry;
  }

  Future<List<FileTransferOutboxEntry>> load(
    Session session, {
    bool includeComplete = true,
  }) async {
    final entries = kIsWeb
        ? await _loadWeb(session)
        : await _loadNative(session);
    return entries
        .where(_isValid)
        .where((entry) => includeComplete || !entry.isComplete)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<FileTransferOutboxEntry?> get(
    Session session,
    String transferId,
  ) async {
    for (final entry in await load(session)) {
      if (entry.transferId == transferId) return entry;
    }
    return null;
  }

  Future<void> put(Session session, FileTransferOutboxEntry entry) async {
    if (!_isValid(entry)) return;
    if (kIsWeb) {
      final entries = await _loadWeb(session);
      final index = entries.indexWhere(
        (candidate) => candidate.transferId == entry.transferId,
      );
      if (index < 0) {
        entries.add(entry);
      } else {
        entries[index] = entry;
      }
      await _saveWeb(session, entries);
      return;
    }
    final db = await _db();
    await db.insert('file_transfer_outbox', {
      'session_key': sessionKey(session),
      'transfer_id': entry.transferId,
      'operation_id': entry.operationId,
      'file_id': entry.fileId,
      'destination_node': entry.destinationNode,
      'packet_json': jsonEncode(entry.packet),
      'payload_reference': entry.payloadReference,
      'size_bytes': entry.sizeBytes,
      'sha256': entry.sha256,
      'chunk_size': entry.chunkSize,
      'total_chunks': entry.totalChunks,
      'acknowledged_json': jsonEncode(
        entry.acknowledgedChunks.toList()..sort(),
      ),
      'status': entry.status,
      'last_error': entry.lastError,
      'attempts': entry.attempts,
      'created_at': entry.createdAt.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> acknowledge(
    Session session,
    String transferId,
    Iterable<int> chunkIndexes, {
    bool complete = false,
  }) async {
    final entry = await get(session, transferId);
    if (entry == null) return;
    final acknowledged = <int>{...entry.acknowledgedChunks};
    for (final index in chunkIndexes) {
      if (index >= 0 && index < entry.totalChunks) acknowledged.add(index);
    }
    if (complete) {
      acknowledged.addAll(List<int>.generate(entry.totalChunks, (i) => i));
    }
    await put(
      session,
      entry.copyWith(
        acknowledgedChunks: acknowledged,
        status: complete ? 'complete' : 'sending',
        lastError: '',
      ),
    );
  }

  Future<void> resetAcknowledgements(Session session, String transferId) async {
    final entry = await get(session, transferId);
    if (entry == null || entry.payloadReference.isEmpty) return;
    await put(
      session,
      entry.copyWith(
        acknowledgedChunks: <int>{},
        status: 'queued',
        lastError: '',
      ),
    );
  }

  Future<void> markAttempt(Session session, String transferId) async {
    final entry = await get(session, transferId);
    if (entry == null) return;
    await put(
      session,
      entry.copyWith(status: 'sending', attempts: entry.attempts + 1),
    );
  }

  Future<void> markFailed(
    Session session,
    String transferId,
    String reason,
  ) async {
    final entry = await get(session, transferId);
    if (entry == null) return;
    await put(session, entry.copyWith(status: 'failed', lastError: reason));
  }

  Future<Uint8List> readChunk(FileTransferOutboxEntry entry, int chunkIndex) {
    final offset = chunkIndex * entry.chunkSize;
    final length = (entry.sizeBytes - offset).clamp(0, entry.chunkSize);
    return _payloadStore.readChunk(entry.payloadReference, offset, length);
  }

  Future<bool> payloadExists(FileTransferOutboxEntry entry) =>
      _payloadStore.exists(entry.payloadReference);

  Future<double> operationProgress(Session session, String operationId) async {
    final entries = (await load(
      session,
    )).where((entry) => entry.operationId == operationId).toList();
    if (entries.isEmpty) return 1;
    return entries.map((entry) => entry.progress).reduce((a, b) => a + b) /
        entries.length;
  }

  Future<bool> operationComplete(Session session, String operationId) async {
    final entries = (await load(
      session,
    )).where((entry) => entry.operationId == operationId).toList();
    return entries.isNotEmpty && entries.every((entry) => entry.isComplete);
  }

  Future<void> delete(Session session, String transferId) async {
    final entry = await get(session, transferId);
    if (kIsWeb) {
      final entries = await _loadWeb(session)
        ..removeWhere((item) => item.transferId == transferId);
      await _saveWeb(session, entries);
      if (entry != null &&
          entry.payloadReference.isNotEmpty &&
          !entries.any(
            (item) => item.payloadReference == entry.payloadReference,
          )) {
        await _payloadStore.delete(entry.payloadReference);
      }
      return;
    }
    final db = await _db();
    await db.delete(
      'file_transfer_outbox',
      where: 'session_key=? AND transfer_id=?',
      whereArgs: [sessionKey(session), transferId],
    );
    if (entry != null && entry.payloadReference.isNotEmpty) {
      final references = Sqflite.firstIntValue(
        await db.rawQuery(
          '''
          SELECT COUNT(*)
          FROM file_transfer_outbox
          WHERE session_key=? AND payload_reference=?
          ''',
          [sessionKey(session), entry.payloadReference],
        ),
      );
      if ((references ?? 0) == 0) {
        await _payloadStore.delete(entry.payloadReference);
      }
    }
  }

  Future<void> deleteOperation(Session session, String operationId) async {
    final entries = (await load(
      session,
    )).where((entry) => entry.operationId == operationId).toList();
    for (final entry in entries) {
      await delete(session, entry.transferId);
    }
  }

  static String sessionKey(Session session) =>
      '${session.serverUrl.trim().toLowerCase()}|'
      '${session.login.trim().toLowerCase()}';

  static bool _isValid(FileTransferOutboxEntry entry) =>
      entry.transferId.isNotEmpty &&
      entry.operationId.isNotEmpty &&
      entry.fileId.isNotEmpty &&
      entry.destinationNode.isNotEmpty &&
      entry.packet.isNotEmpty &&
      entry.sizeBytes > 0 &&
      entry.sha256.length == 64 &&
      entry.chunkSize > 0 &&
      entry.totalChunks > 0;

  Future<List<FileTransferOutboxEntry>> _loadNative(Session session) async {
    final db = await _db();
    final rows = await db.query(
      'file_transfer_outbox',
      where: 'session_key=?',
      whereArgs: [sessionKey(session)],
      orderBy: 'created_at ASC, transfer_id ASC',
    );
    return rows.map(_entryFromRow).where(_isValid).toList();
  }

  FileTransferOutboxEntry _entryFromRow(Map<String, Object?> row) =>
      FileTransferOutboxEntry.fromJson({
        'transfer_id': row['transfer_id'],
        'operation_id': row['operation_id'],
        'file_id': row['file_id'],
        'destination_node': row['destination_node'],
        'packet': _decodeMap(row['packet_json']),
        'payload_reference': row['payload_reference'],
        'size_bytes': row['size_bytes'],
        'sha256': row['sha256'],
        'chunk_size': row['chunk_size'],
        'total_chunks': row['total_chunks'],
        'acknowledged_chunks': _decodeList(row['acknowledged_json']),
        'status': row['status'],
        'last_error': row['last_error'],
        'attempts': row['attempts'],
        'created_at': row['created_at'],
      });

  Future<Database> _db() async {
    final existing = _databases[databaseName];
    if (existing != null) return existing;
    final path = await appDatabasePath(databaseName);
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (database, _) async {
        await database.execute('''
          CREATE TABLE file_transfer_outbox(
            session_key TEXT NOT NULL,
            transfer_id TEXT NOT NULL,
            operation_id TEXT NOT NULL,
            file_id TEXT NOT NULL,
            destination_node TEXT NOT NULL,
            packet_json TEXT NOT NULL,
            payload_reference TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            chunk_size INTEGER NOT NULL,
            total_chunks INTEGER NOT NULL,
            acknowledged_json TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL DEFAULT 'queued',
            last_error TEXT NOT NULL DEFAULT '',
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            PRIMARY KEY(session_key, transfer_id)
          )
          ''');
        await database.execute('''
          CREATE INDEX idx_file_transfer_operation
          ON file_transfer_outbox(session_key, operation_id)
          ''');
      },
    );
    _databases[databaseName] = db;
    return db;
  }

  Future<List<FileTransferOutboxEntry>> _loadWeb(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_webKey(session));
    if (raw == null || raw.isEmpty) return <FileTransferOutboxEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <FileTransferOutboxEntry>[];
      return decoded
          .whereType<Map>()
          .map(
            (item) => FileTransferOutboxEntry.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .where(_isValid)
          .toList();
    } catch (_) {
      await prefs.remove(_webKey(session));
      return <FileTransferOutboxEntry>[];
    }
  }

  Future<void> _saveWeb(
    Session session,
    List<FileTransferOutboxEntry> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _webKey(session);
    if (entries.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  static String _webKey(Session session) =>
      '$_preferencesPrefix${base64Url.encode(utf8.encode(sessionKey(session)))}';

  static Map<String, dynamic> _decodeMap(Object? raw) {
    try {
      final decoded = jsonDecode(raw?.toString() ?? '');
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static List<dynamic> _decodeList(Object? raw) {
    try {
      final decoded = jsonDecode(raw?.toString() ?? '');
      return decoded is List ? decoded : <dynamic>[];
    } catch (_) {
      return <dynamic>[];
    }
  }
}
