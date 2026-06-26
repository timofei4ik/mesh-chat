import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../models/session.dart';

class ChatCacheStore {
  static const _maxMessagesPerThread = 500;
  static const _maxWebMessagesPerThread = 80;
  static const _maxCachedWebFileHex = 220 * 1024;
  static const _dbName = 'meshchat_cache.db';
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
    final rows = await db.query(
      'chat_threads',
      where: 'session_key=?',
      whereArgs: [_key(session)],
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
    final batch = db.batch();
    for (final thread in threads) {
      final trimmed = _trimThread(thread);
      final threadKey = trimmed.isGroup
          ? 'group:${trimmed.groupId}'
          : trimmed.profile.nodeId;
      if (threadKey.isEmpty) continue;
      batch.insert('chat_threads', {
        'session_key': sessionKey,
        'thread_key': threadKey,
        'is_group': trimmed.isGroup ? 1 : 0,
        'updated_at': (trimmed.lastMessage?.createdAt ?? DateTime.now())
            .millisecondsSinceEpoch,
        'payload': jsonEncode(trimmed.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> clear(Session? session) async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(session));
    if (kIsWeb) return;
    final db = await _db();
    await db.delete(
      'chat_threads',
      where: 'session_key=?',
      whereArgs: [_key(session)],
    );
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
    final path = p.join(await getDatabasesPath(), _dbName);
    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE chat_threads(
            session_key TEXT NOT NULL,
            thread_key TEXT NOT NULL,
            is_group INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            payload TEXT NOT NULL,
            PRIMARY KEY(session_key, thread_key)
          )
          ''');
      },
    );
    return _database!;
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
      'version': 2,
      'threads': threads
          .map((thread) => _trimThread(thread, forWeb: true).toJson())
          .toList(),
    };
    final key = _key(session);
    try {
      await prefs.setString(key, jsonEncode(payload));
    } catch (_) {
      await prefs.remove(key);
      final minimalPayload = {
        'version': 2,
        'threads': threads
            .map((thread) => _trimThread(thread, forWeb: true, minimal: true))
            .toList()
            .map((thread) => thread.toJson())
            .toList(),
      };
      try {
        await prefs.setString(key, jsonEncode(minimalPayload));
      } catch (_) {
        await prefs.remove(key);
      }
    }
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
      threads[thread.profile.nodeId] = thread;
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
    final cachedMessages = forWeb
        ? messages.map((message) => _trimMessageForWeb(message)).toList()
        : messages;
    final profile = forWeb
        ? thread.profile.copyWith(avatarData: '')
        : thread.profile;
    final trimmed = ChatThread(
      profile: profile,
      messages: cachedMessages,
      isGroup: thread.isGroup,
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
    if (message.kind != ChatMessageKind.file) return message;
    final keepFileData =
        message.fileData.length <= _maxCachedWebFileHex &&
        (_isImageName(message.fileName) || _isAudioName(message.fileName));
    return ChatMessage(
      id: message.id,
      senderNode: message.senderNode,
      receiverNode: message.receiverNode,
      text: message.text,
      createdAt: message.createdAt,
      kind: message.kind,
      fileName: message.fileName,
      fileData: keepFileData ? message.fileData : '',
      fileSize: message.fileSize,
      replyToMessageId: message.replyToMessageId,
      replyToText: message.replyToText,
      reactions: message.reactions,
      edited: message.edited,
      deleted: message.deleted,
      pending: message.pending,
      delivered: message.delivered,
    );
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
}

class CacheStats {
  const CacheStats({this.threads = 0, this.messages = 0, this.bytes = 0});

  final int threads;
  final int messages;
  final int bytes;
}
