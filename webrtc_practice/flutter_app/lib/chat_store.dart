import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class ChatStore {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'azhar_chat.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE conversations (
            peer_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            last_text TEXT NOT NULL,
            last_ts INTEGER NOT NULL,
            unread INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            from_me INTEGER NOT NULL,
            text TEXT NOT NULL,
            ts INTEGER NOT NULL,
            status INTEGER NOT NULL
          )
        ''');
        await _createV3Tables(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 3) {
          await _createV3Tables(db);
        }
      },
    );
    return _db!;
  }

  Future<List<Conversation>> loadConversations() async {
    final rows = await (await _database).query(
      'conversations',
      orderBy: 'last_ts DESC',
    );
    return [
      for (final row in rows)
        Conversation(
          peerId: row['peer_id'] as String,
          roomId: row['room_id'] as String,
          lastText: row['last_text'] as String,
          lastTs: row['last_ts'] as int,
          unread: row['unread'] as int,
        ),
    ];
  }

  Future<List<ChatMessage>> loadMessages(String roomId) async {
    final rows = await (await _database).query(
      'messages',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'ts ASC',
    );
    return [
      for (final row in rows)
        ChatMessage(
          id: row['id'] as String,
          roomId: row['room_id'] as String,
          peerId: row['peer_id'] as String,
          fromMe: (row['from_me'] as int) == 1,
          text: row['text'] as String,
          ts: row['ts'] as int,
          status: MessageStatus.values[(row['status'] as int?) ?? 0],
        ),
    ];
  }

  Future<void> upsertConversation(Conversation chat) async {
    await (await _database).insert('conversations', {
      'peer_id': chat.peerId,
      'room_id': chat.roomId,
      'last_text': chat.lastText,
      'last_ts': chat.lastTs,
      'unread': chat.unread,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertMessage(ChatMessage message) async {
    await (await _database).insert('messages', {
      'id': message.id,
      'room_id': message.roomId,
      'peer_id': message.peerId,
      'from_me': message.fromMe ? 1 : 0,
      'text': message.text,
      'ts': message.ts,
      'status': message.status.index,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> updateMessageStatus(String id, MessageStatus status) async {
    await (await _database).update(
      'messages',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _createV3Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS calls (
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        video INTEGER NOT NULL,
        outgoing INTEGER NOT NULL,
        outcome INTEGER NOT NULL,
        ts INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS status_views (
        status_id TEXT PRIMARY KEY
      )
    ''');
  }

  Future<List<CallRecord>> loadCalls() async {
    final rows = await (await _database).query('calls', orderBy: 'ts DESC');
    return [
      for (final row in rows)
        CallRecord(
          id: row['id'] as String,
          peerId: row['peer_id'] as String,
          video: (row['video'] as int) == 1,
          outgoing: (row['outgoing'] as int) == 1,
          outcome: CallOutcome.values[(row['outcome'] as int?) ?? 0],
          ts: row['ts'] as int,
          durationMs: (row['duration_ms'] as int?) ?? 0,
        ),
    ];
  }

  Future<void> insertCall(CallRecord record) async {
    await (await _database).insert('calls', {
      'id': record.id,
      'peer_id': record.peerId,
      'video': record.video ? 1 : 0,
      'outgoing': record.outgoing ? 1 : 0,
      'outcome': record.outcome.index,
      'ts': record.ts,
      'duration_ms': record.durationMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateCall(CallRecord record) async {
    await (await _database).update(
      'calls',
      {
        'outcome': record.outcome.index,
        'duration_ms': record.durationMs,
      },
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  Future<Set<String>> loadViewedStatusIds() async {
    final rows = await (await _database).query('status_views');
    return {for (final row in rows) row['status_id'] as String};
  }

  Future<void> markStatusViewed(String statusId) async {
    await (await _database).insert('status_views', {
      'status_id': statusId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> clearUnread(String peerId) async {
    await (await _database).update(
      'conversations',
      {'unread': 0},
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }
}
