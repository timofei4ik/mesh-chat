import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/session.dart';
import 'app_database_path.dart';

enum MutationOutboxState {
  queued,
  sent;

  static MutationOutboxState parse(Object? value) =>
      value?.toString() == sent.name ? sent : queued;
}

class MutationOutboxEntry {
  const MutationOutboxEntry({
    required this.outboxId,
    required this.operationId,
    required this.packet,
    required this.createdAt,
    this.attempts = 0,
    this.state = MutationOutboxState.queued,
    this.lastAttemptAt,
    this.lastError = '',
  });

  final String outboxId;
  final String operationId;
  final Map<String, dynamic> packet;
  final DateTime createdAt;
  final int attempts;
  final MutationOutboxState state;
  final DateTime? lastAttemptAt;
  final String lastError;

  factory MutationOutboxEntry.fromJson(Map<String, dynamic> json) {
    final rawPacket = json['packet'];
    return MutationOutboxEntry(
      outboxId: json['outbox_id']?.toString() ?? '',
      operationId: json['operation_id']?.toString() ?? '',
      packet: rawPacket is Map
          ? Map<String, dynamic>.from(rawPacket)
          : const <String, dynamic>{},
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      attempts: int.tryParse(json['attempts']?.toString() ?? '') ?? 0,
      state: MutationOutboxState.parse(json['state']),
      lastAttemptAt: DateTime.tryParse(
        json['last_attempt_at']?.toString() ?? '',
      )?.toUtc(),
      lastError: json['last_error']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'outbox_id': outboxId,
    'operation_id': operationId,
    'packet': packet,
    'created_at': createdAt.toUtc().toIso8601String(),
    'attempts': attempts,
    'state': state.name,
    'last_attempt_at': lastAttemptAt?.toUtc().toIso8601String(),
    'last_error': lastError,
  };

  MutationOutboxEntry copyWith({
    int? attempts,
    MutationOutboxState? state,
    DateTime? lastAttemptAt,
    bool clearLastAttemptAt = false,
    String? lastError,
  }) => MutationOutboxEntry(
    outboxId: outboxId,
    operationId: operationId,
    packet: packet,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    state: state ?? this.state,
    lastAttemptAt: clearLastAttemptAt
        ? null
        : lastAttemptAt ?? this.lastAttemptAt,
    lastError: lastError ?? this.lastError,
  );
}

class MutationOutboxStore {
  static const _databaseName = 'meshchat_mutation_outbox.db';
  static const _preferencesPrefix = 'meshchat_mutation_outbox_v1:';
  static Database? _database;

  Future<List<MutationOutboxEntry>> load(Session session) async {
    if (kIsWeb) return _loadWeb(session);
    final db = await _db();
    final rows = await db.query(
      'mutation_outbox',
      where: 'session_key=?',
      whereArgs: [_sessionKey(session)],
      orderBy: 'created_at ASC, outbox_id ASC',
    );
    return rows
        .map(
          (row) => MutationOutboxEntry.fromJson({
            'outbox_id': row['outbox_id'],
            'operation_id': row['operation_id'],
            'packet': _decodePacket(row['packet_json']),
            'created_at': row['created_at'],
            'attempts': row['attempts'],
            'state': row['state'],
            'last_attempt_at': row['last_attempt_at'],
            'last_error': row['last_error'],
          }),
        )
        .where(_isValid)
        .toList();
  }

  Future<void> put(Session session, MutationOutboxEntry entry) async {
    if (!_isValid(entry)) return;
    if (kIsWeb) {
      final entries = await _loadWeb(session);
      final index = entries.indexWhere(
        (candidate) => candidate.outboxId == entry.outboxId,
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
    await db.insert('mutation_outbox', {
      'session_key': _sessionKey(session),
      'outbox_id': entry.outboxId,
      'operation_id': entry.operationId,
      'packet_json': jsonEncode(entry.packet),
      'created_at': entry.createdAt.toUtc().toIso8601String(),
      'attempts': entry.attempts,
      'state': entry.state.name,
      'last_attempt_at': entry.lastAttemptAt?.toUtc().toIso8601String(),
      'last_error': entry.lastError,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markSent(
    Session session,
    String outboxId, {
    DateTime? attemptedAt,
  }) async {
    if (outboxId.isEmpty) return;
    final sentAt = (attemptedAt ?? DateTime.now()).toUtc();
    if (kIsWeb) {
      final entries = await _loadWeb(session);
      final index = entries.indexWhere((entry) => entry.outboxId == outboxId);
      if (index < 0) return;
      entries[index] = entries[index].copyWith(
        attempts: entries[index].attempts + 1,
        state: MutationOutboxState.sent,
        lastAttemptAt: sentAt,
        lastError: '',
      );
      await _saveWeb(session, entries);
      return;
    }
    final db = await _db();
    await db.rawUpdate(
      '''
      UPDATE mutation_outbox
      SET attempts=attempts+1,
          state=?,
          last_attempt_at=?,
          last_error=''
      WHERE session_key=? AND outbox_id=?
      ''',
      [
        MutationOutboxState.sent.name,
        sentAt.toIso8601String(),
        _sessionKey(session),
        outboxId,
      ],
    );
  }

  Future<void> markAttempt(Session session, String outboxId) =>
      markSent(session, outboxId);

  Future<void> markQueued(
    Session session,
    String outboxId, {
    String error = '',
  }) async {
    if (outboxId.isEmpty) return;
    if (kIsWeb) {
      final entries = await _loadWeb(session);
      final index = entries.indexWhere((entry) => entry.outboxId == outboxId);
      if (index < 0) return;
      entries[index] = entries[index].copyWith(
        state: MutationOutboxState.queued,
        lastError: error,
      );
      await _saveWeb(session, entries);
      return;
    }
    final db = await _db();
    await db.rawUpdate(
      '''
      UPDATE mutation_outbox
      SET state=?, last_error=?
      WHERE session_key=? AND outbox_id=?
      ''',
      [MutationOutboxState.queued.name, error, _sessionKey(session), outboxId],
    );
  }

  Future<void> delete(Session session, String outboxId) async {
    if (outboxId.isEmpty) return;
    if (kIsWeb) {
      final entries = await _loadWeb(session)
        ..removeWhere((entry) => entry.outboxId == outboxId);
      await _saveWeb(session, entries);
      return;
    }
    final db = await _db();
    await db.delete(
      'mutation_outbox',
      where: 'session_key=? AND outbox_id=?',
      whereArgs: [_sessionKey(session), outboxId],
    );
  }

  Future<bool> hasOperation(Session session, String operationId) async {
    if (operationId.isEmpty) return false;
    if (kIsWeb) {
      return (await _loadWeb(
        session,
      )).any((entry) => entry.operationId == operationId);
    }
    final db = await _db();
    final rows = await db.rawQuery(
      '''
      SELECT 1
      FROM mutation_outbox
      WHERE session_key=? AND operation_id=?
      LIMIT 1
      ''',
      [_sessionKey(session), operationId],
    );
    return rows.isNotEmpty;
  }

  static String sessionKey(Session session) => _sessionKey(session);

  static String _sessionKey(Session session) =>
      '${session.serverUrl.trim().toLowerCase()}|'
      '${session.login.trim().toLowerCase()}';

  static bool _isValid(MutationOutboxEntry entry) =>
      entry.outboxId.isNotEmpty &&
      entry.operationId.isNotEmpty &&
      entry.packet.isNotEmpty;

  static Map<String, dynamic> _decodePacket(Object? raw) {
    try {
      final decoded = jsonDecode(raw?.toString() ?? '');
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<Database> _db() async {
    final existing = _database;
    if (existing != null) return existing;
    final path = await appDatabasePath(_databaseName);
    _database = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE mutation_outbox(
            session_key TEXT NOT NULL,
            outbox_id TEXT NOT NULL,
            operation_id TEXT NOT NULL,
            packet_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'queued',
            last_attempt_at TEXT,
            last_error TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(session_key, outbox_id)
          )
          ''');
        await db.execute('''
          CREATE INDEX idx_mutation_outbox_operation
          ON mutation_outbox(session_key, operation_id)
          ''');
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE mutation_outbox ADD COLUMN state TEXT NOT NULL DEFAULT 'queued'",
          );
          await db.execute(
            'ALTER TABLE mutation_outbox ADD COLUMN last_attempt_at TEXT',
          );
          await db.execute(
            "ALTER TABLE mutation_outbox ADD COLUMN last_error TEXT NOT NULL DEFAULT ''",
          );
        }
      },
    );
    return _database!;
  }

  Future<List<MutationOutboxEntry>> _loadWeb(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_webKey(session));
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final entries = decoded
          .whereType<Map>()
          .map(
            (item) =>
                MutationOutboxEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .where(_isValid)
          .toList();
      entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return entries;
    } catch (_) {
      await prefs.remove(_webKey(session));
      return [];
    }
  }

  Future<void> _saveWeb(
    Session session,
    List<MutationOutboxEntry> entries,
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

  static String _webKey(Session session) {
    final encoded = base64Url.encode(utf8.encode(_sessionKey(session)));
    return '$_preferencesPrefix$encoded';
  }
}
