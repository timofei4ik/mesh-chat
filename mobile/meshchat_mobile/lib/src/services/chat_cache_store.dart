import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../models/session.dart';
import 'app_database_path.dart';

class ChatCacheStore {
  static const _maxMessagesPerThread = 500;
  static const _maxWebMessagesPerThread = 80;
  static const _maxSqlitePayloadChars = 900 * 1024;
  static const _maxCachedFileHex = 420 * 1024;
  static const _maxCachedWebFileHex = 220 * 1024;
  static const _maxCachedWebAvatar = 260 * 1024;
  static const _dbName = 'meshchat_cache.db';
  static const _cacheDigestVersion = 1;
  static Database? _database;

  Future<void> load(
    Session session,
    Map<String, Profile> profiles,
    Map<String, ChatThread> threads,
    Map<String, ChatThread> groups,
  ) async {
    if (kIsWeb) {
      await _loadLegacy(session, profiles, threads, groups);
      return;
    }

    final db = await _db();
    await _migrateLegacy(session, db);
    final sessionKey = _key(session);
    await db.delete(
      'chat_threads',
      where: 'session_key=? AND length(payload)>?',
      whereArgs: [sessionKey, _maxSqlitePayloadChars],
    );
    final rows = await db.query(
      'chat_threads',
      where: 'session_key=?',
      whereArgs: [sessionKey],
    );
    for (final row in rows) {
      final payload = row['payload']?.toString() ?? '';
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final thread = ChatThread.fromJson(Map<String, dynamic>.from(decoded));
        _putThread(thread, profiles, threads, groups);
      } catch (_) {
        // Ignore one broken cached thread instead of dropping the whole cache.
      }
    }
  }

  Future<void> save(Session? session, Iterable<ChatThread> threads) async {
    if (session == null) return;
    if (kIsWeb) {
      await _saveLegacy(session, threads);
      return;
    }

    final db = await _db();
    final sessionKey = _key(session);
    final prepared = <String, Map<String, Object>>{};
    for (final thread in threads) {
      var trimmed = _trimThread(thread);
      final threadKey = trimmed.storageKey;
      if (threadKey.isEmpty) continue;
      var payload = jsonEncode(trimmed.toJson());
      if (payload.length > _maxSqlitePayloadChars) {
        trimmed = _trimThread(thread, minimal: true);
        payload = jsonEncode(trimmed.toJson());
      }
      if (payload.length > _maxSqlitePayloadChars) continue;
      prepared[threadKey] = {
        'session_key': sessionKey,
        'thread_key': threadKey,
        'is_group': trimmed.isGroup ? 1 : 0,
        'updated_at': (trimmed.lastMessage?.createdAt ?? DateTime.now())
            .millisecondsSinceEpoch,
        'payload': payload,
      };
    }
    await db.transaction((transaction) async {
      final existingRows = await transaction.query(
        'chat_threads',
        columns: ['thread_key'],
        where: 'session_key=?',
        whereArgs: [sessionKey],
      );
      final currentKeys = prepared.keys.toSet();
      for (final row in existingRows) {
        final threadKey = row['thread_key']?.toString() ?? '';
        if (threadKey.isNotEmpty && !currentKeys.contains(threadKey)) {
          await transaction.delete(
            'chat_threads',
            where: 'session_key=? AND thread_key=?',
            whereArgs: [sessionKey, threadKey],
          );
        }
      }
      for (final row in prepared.values) {
        await transaction.insert(
          'chat_threads',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    final digest = await _sqliteDigest(db, sessionKey);
    await db.rawUpdate(
      '''
      UPDATE chat_sync_state
      SET cache_digest=?, digest_version=?, thread_count=?, updated_at=?
      WHERE session_key=?
      ''',
      [
        digest,
        _cacheDigestVersion,
        prepared.length,
        DateTime.now().millisecondsSinceEpoch,
        sessionKey,
      ],
    );
  }

  Future<void> clear(Session? session) async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(session));
    await prefs.remove(_syncKey(session));
    await prefs.remove(_digestKey(session));
    if (kIsWeb) return;
    final db = await _db();
    await db.transaction((transaction) async {
      await transaction.delete(
        'chat_threads',
        where: 'session_key=?',
        whereArgs: [_key(session)],
      );
      await transaction.delete(
        'chat_sync_state',
        where: 'session_key=?',
        whereArgs: [_key(session)],
      );
    });
  }

  Future<int?> loadSyncCursor(Session session) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final cursor = prefs.getInt(_syncKey(session));
      final expected = prefs.getString(_digestKey(session));
      if (cursor == null || expected == null || expected.isEmpty) return null;
      final actual = await _webDigest(session, prefs);
      return expected == actual ? cursor : null;
    }
    final db = await _db();
    final rows = await db.query(
      'chat_sync_state',
      columns: ['cursor', 'cache_digest'],
      where: 'session_key=?',
      whereArgs: [_key(session)],
      limit: 1,
    );
    if (rows.isEmpty ||
        (rows.first['cache_digest']?.toString() ?? '').isEmpty) {
      return null;
    }
    final expected = rows.first['cache_digest']?.toString() ?? '';
    final actual = await _sqliteDigest(db, _key(session));
    if (expected != actual) return null;
    return int.tryParse(rows.first['cursor']?.toString() ?? '');
  }

  Future<CacheIntegrityReport> inspectIntegrity(Session session) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final cursor = prefs.getInt(_syncKey(session));
      final expected = prefs.getString(_digestKey(session)) ?? '';
      if (cursor == null || expected.isEmpty) {
        return const CacheIntegrityReport.unverified();
      }
      final actual = await _webDigest(session, prefs);
      return CacheIntegrityReport(
        verified: expected == actual,
        hasCheckpoint: true,
        expectedDigest: expected,
        actualDigest: actual,
      );
    }
    final db = await _db();
    final rows = await db.query(
      'chat_sync_state',
      columns: ['cache_digest'],
      where: 'session_key=?',
      whereArgs: [_key(session)],
      limit: 1,
    );
    final expected = rows.isEmpty
        ? ''
        : rows.first['cache_digest']?.toString() ?? '';
    if (expected.isEmpty) return const CacheIntegrityReport.unverified();
    final actual = await _sqliteDigest(db, _key(session));
    return CacheIntegrityReport(
      verified: expected == actual,
      hasCheckpoint: true,
      expectedDigest: expected,
      actualDigest: actual,
    );
  }

  Future<void> saveSyncCursor(Session session, int cursor) async {
    if (cursor < 0) return;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final digest = await _webDigest(session, prefs);
      await prefs.setInt(_syncKey(session), cursor);
      await prefs.setString(_digestKey(session), digest);
      return;
    }
    final db = await _db();
    final digest = await _sqliteDigest(db, _key(session));
    final threadCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM chat_threads WHERE session_key=?',
            [_key(session)],
          ),
        ) ??
        0;
    await db.insert('chat_sync_state', {
      'session_key': _key(session),
      'cursor': cursor,
      'cache_digest': digest,
      'digest_version': _cacheDigestVersion,
      'thread_count': threadCount,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteThread(Session? session, ChatThread thread) async {
    if (session == null) return;
    if (kIsWeb) return;
    final db = await _db();
    final threadKey = thread.storageKey;
    if (threadKey.isEmpty) {
      await _deleteBrokenGroupThread(session, db, thread);
      return;
    }
    await db.delete(
      'chat_threads',
      where: 'session_key=? AND thread_key=?',
      whereArgs: [_key(session), threadKey],
    );
  }

  Future<void> _deleteBrokenGroupThread(
    Session session,
    Database db,
    ChatThread thread,
  ) async {
    final sessionKey = _key(session);
    final rows = await db.query(
      'chat_threads',
      columns: ['thread_key', 'payload'],
      where: 'session_key=? AND is_group=1',
      whereArgs: [sessionKey],
    );
    final batch = db.batch();
    for (final row in rows) {
      final threadKey = row['thread_key']?.toString() ?? '';
      final payload = row['payload']?.toString() ?? '';
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final cached = ChatThread.fromJson(Map<String, dynamic>.from(decoded));
        final sameBrokenGroup =
            cached.groupId.isEmpty &&
            (identical(cached, thread) ||
                cached.profile.nodeId == thread.profile.nodeId ||
                (cached.groupName.isNotEmpty &&
                    cached.groupName == thread.groupName));
        if (sameBrokenGroup && threadKey.isNotEmpty) {
          batch.delete(
            'chat_threads',
            where: 'session_key=? AND thread_key=?',
            whereArgs: [sessionKey, threadKey],
          );
        }
      } catch (_) {
        // Leave unrelated broken rows alone; the next full cache save can trim them.
      }
    }
    await batch.commit(noResult: true);
  }

  Future<CacheStats> stats(Session? session) async {
    if (session == null) {
      return const CacheStats();
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyBytes = utf8
        .encode(prefs.getString(_key(session)) ?? '')
        .length;

    if (kIsWeb) {
      return CacheStats(threads: 0, messages: 0, bytes: legacyBytes);
    }

    final db = await _db();
    final rows = await db.query(
      'chat_threads',
      columns: ['payload'],
      where: 'session_key=?',
      whereArgs: [_key(session)],
    );

    var messages = 0;
    var bytes = legacyBytes;
    for (final row in rows) {
      final payload = row['payload']?.toString() ?? '';
      bytes += utf8.encode(payload).length;
      try {
        final decoded = jsonDecode(payload);
        final rawMessages = decoded is Map ? decoded['messages'] : null;
        if (rawMessages is List) messages += rawMessages.length;
      } catch (_) {
        // Ignore broken rows in stats; clear() can remove them if needed.
      }
    }

    return CacheStats(threads: rows.length, messages: messages, bytes: bytes);
  }

  Future<Database> _db() async {
    final existing = _database;
    if (existing != null) return existing;
    final path = await appDatabasePath(_dbName);
    _database = await openDatabase(
      path,
      version: 4,
      onCreate: (db, _) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await _createSyncStateTable(db);
        }
        if (oldVersion < 3) {
          await _createSyncStateTable(db);
          await db.delete('chat_sync_state');
        }
        if (oldVersion < 4) await _ensureSyncStateColumns(db);
      },
      onOpen: (db) async {
        await _createSyncStateTable(db);
        await _ensureSyncStateColumns(db);
      },
    );
    return _database!;
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_threads(
        session_key TEXT NOT NULL,
        thread_key TEXT NOT NULL,
        is_group INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        payload TEXT NOT NULL,
        PRIMARY KEY(session_key, thread_key)
      )
      ''');
    await _createSyncStateTable(db);
  }

  Future<void> _createSyncStateTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_sync_state(
        session_key TEXT PRIMARY KEY,
        cursor INTEGER NOT NULL,
        cache_digest TEXT NOT NULL DEFAULT '',
        digest_version INTEGER NOT NULL DEFAULT 0,
        thread_count INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
      ''');
  }

  Future<void> _ensureSyncStateColumns(Database db) async {
    final columns = {
      for (final row in await db.rawQuery('PRAGMA table_info(chat_sync_state)'))
        row['name']?.toString() ?? '',
    };
    if (!columns.contains('cache_digest')) {
      await db.execute(
        "ALTER TABLE chat_sync_state ADD COLUMN cache_digest TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!columns.contains('digest_version')) {
      await db.execute(
        'ALTER TABLE chat_sync_state ADD COLUMN digest_version INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!columns.contains('thread_count')) {
      await db.execute(
        'ALTER TABLE chat_sync_state ADD COLUMN thread_count INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  Future<String> _sqliteDigest(Database db, String sessionKey) async {
    final rows = await db.query(
      'chat_threads',
      columns: ['thread_key', 'is_group', 'payload'],
      where: 'session_key=?',
      whereArgs: [sessionKey],
      orderBy: 'thread_key ASC',
    );
    final canonical = StringBuffer('meshchat-cache-v$_cacheDigestVersion\n');
    for (final row in rows) {
      canonical
        ..write(row['thread_key']?.toString() ?? '')
        ..write('\u0000')
        ..write(row['is_group']?.toString() ?? '0')
        ..write('\u0000')
        ..write(row['payload']?.toString() ?? '')
        ..write('\n');
    }
    return _sha256Hex(utf8.encode(canonical.toString()));
  }

  Future<String> _webDigest(Session session, SharedPreferences prefs) async {
    final raw = prefs.getString(_key(session)) ?? '';
    return _sha256Hex(
      utf8.encode('meshchat-cache-v$_cacheDigestVersion\n$raw'),
    );
  }

  Future<String> _sha256Hex(List<int> bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _migrateLegacy(Session session, Database db) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(session);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return;
    final existing = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM chat_threads WHERE session_key=?',
        [key],
      ),
    );
    if ((existing ?? 0) > 0) {
      await prefs.remove(key);
      return;
    }

    final profiles = <String, Profile>{};
    final threads = <String, ChatThread>{};
    final groups = <String, ChatThread>{};
    await _loadLegacy(session, profiles, threads, groups);
    await save(session, [...threads.values, ...groups.values]);
    await prefs.remove(key);
  }

  Future<void> _loadLegacy(
    Session session,
    Map<String, Profile> profiles,
    Map<String, ChatThread> threads,
    Map<String, ChatThread> groups,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(session));
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      final rawThreads = decoded is Map ? decoded['threads'] : null;
      if (rawThreads is! List) return;
      for (final rawThread in rawThreads.whereType<Map>()) {
        final thread = ChatThread.fromJson(
          Map<String, dynamic>.from(rawThread),
        );
        _putThread(thread, profiles, threads, groups);
      }
    } catch (_) {
      await prefs.remove(_key(session));
    }
  }

  Future<void> _saveLegacy(
    Session session,
    Iterable<ChatThread> threads,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'version': 3,
      'threads': threads
          .map((thread) => _trimThread(thread, forWeb: true).toJson())
          .toList(),
    };
    final key = _key(session);
    try {
      await prefs.setString(key, jsonEncode(payload));
      await _refreshWebDigestIfCheckpointed(session, prefs);
    } catch (_) {
      await prefs.remove(key);
      final minimalPayload = {
        'version': 3,
        'threads': threads
            .map((thread) => _trimThread(thread, forWeb: true, minimal: true))
            .toList()
            .map((thread) => thread.toJson())
            .toList(),
      };
      try {
        await prefs.setString(key, jsonEncode(minimalPayload));
        await _refreshWebDigestIfCheckpointed(session, prefs);
      } catch (_) {
        await prefs.remove(key);
      }
    }
  }

  Future<void> _refreshWebDigestIfCheckpointed(
    Session session,
    SharedPreferences prefs,
  ) async {
    if (prefs.getInt(_syncKey(session)) == null) return;
    await prefs.setString(
      _digestKey(session),
      await _webDigest(session, prefs),
    );
  }

  void _putThread(
    ChatThread thread,
    Map<String, Profile> profiles,
    Map<String, ChatThread> threads,
    Map<String, ChatThread> groups,
  ) {
    if (thread.profile.nodeId.isEmpty) return;
    if (thread.isGroup) {
      if (thread.groupId.isNotEmpty) groups[thread.groupId] = thread;
    } else {
      profiles[thread.profile.nodeId] = thread.profile;
      final key = thread.threadId.isNotEmpty
          ? thread.threadId
          : thread.profile.nodeId;
      threads[key] = thread;
    }
  }

  ChatThread _trimThread(
    ChatThread thread, {
    bool forWeb = false,
    bool minimal = false,
  }) {
    final maxMessages = minimal
        ? 20
        : forWeb
        ? _maxWebMessagesPerThread
        : _maxMessagesPerThread;
    final messages = thread.messages.length > maxMessages
        ? thread.messages.sublist(thread.messages.length - maxMessages)
        : List.of(thread.messages);
    final cachedMessages = messages
        .map(
          (message) => forWeb
              ? _trimMessageForWeb(message)
              : _trimMessageForCache(message),
        )
        .toList();
    final profile =
        forWeb && thread.profile.avatarData.length > _maxCachedWebAvatar
        ? thread.profile.copyWith(avatarData: '')
        : thread.profile;
    final trimmed = ChatThread(
      profile: profile,
      messages: cachedMessages,
      isGroup: thread.isGroup,
      isChannel: thread.isChannel,
      threadId: thread.threadId,
      chatKind: thread.chatKind,
      accessCode: thread.accessCode,
      groupId: thread.groupId,
      groupName: thread.groupName,
      members: List.of(thread.members),
      ownerNode: thread.ownerNode,
      admins: List.of(thread.admins),
      groupKeyId: thread.groupKeyId,
      groupKeyData: thread.groupKeyData,
      pinnedMessageIds: List.of(thread.pinnedMessageIds),
      draft: thread.draft,
      archived: thread.archived,
      pinned: thread.pinned,
      muted: thread.muted,
    );
    trimmed.unread = thread.unread;
    return trimmed;
  }

  ChatMessage _trimMessageForWeb(ChatMessage message) {
    return _trimFileMessage(message, _maxCachedWebFileHex);
  }

  ChatMessage _trimMessageForCache(ChatMessage message) {
    return _trimFileMessage(message, _maxCachedFileHex);
  }

  ChatMessage _trimFileMessage(ChatMessage message, int maxFileHex) {
    if (message.kind != ChatMessageKind.file &&
        message.kind != ChatMessageKind.sticker) {
      return message;
    }
    final keepFileData =
        message.fileData.length <= maxFileHex &&
        (message.kind == ChatMessageKind.sticker ||
            _isImageName(message.fileName) ||
            _isAudioName(message.fileName));
    return message.copyWith(fileData: keepFileData ? message.fileData : '');
  }

  bool _isImageName(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool _isAudioName(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus') ||
        lower.endsWith('.flac');
  }

  String _key(Session session) {
    return 'chat_cache_${session.login}_${session.nodeId}';
  }

  String _syncKey(Session session) => '${_key(session)}_sync_cursor_v3';

  String _digestKey(Session session) => '${_key(session)}_cache_digest_v1';
}

class CacheIntegrityReport {
  const CacheIntegrityReport({
    required this.verified,
    required this.hasCheckpoint,
    this.expectedDigest = '',
    this.actualDigest = '',
  });

  const CacheIntegrityReport.unverified()
    : verified = true,
      hasCheckpoint = false,
      expectedDigest = '',
      actualDigest = '';

  final bool verified;
  final bool hasCheckpoint;
  final String expectedDigest;
  final String actualDigest;
}

class CacheStats {
  const CacheStats({this.threads = 0, this.messages = 0, this.bytes = 0});

  final int threads;
  final int messages;
  final int bytes;
}
