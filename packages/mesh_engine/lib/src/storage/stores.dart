import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

Uint8List _bytes(Object? v) => Uint8List.fromList((v as List).cast<int>());
Uint8List? _bytesOrNull(Object? v) => v == null ? null : _bytes(v);

// ════════════════════════════════ settings ═════════════════════════════════

class SettingsStore {
  SettingsStore(this._d);
  final MeshDatabase _d;

  String? get(String key) {
    final r = _d.db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void set(String key, String value) => _d.db.execute(
        'INSERT INTO settings(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  void remove(String key) =>
      _d.db.execute('DELETE FROM settings WHERE key = ?', [key]);

  bool getBool(String key, {bool fallback = false}) {
    final v = get(key);
    return v == null ? fallback : v == '1';
  }

  void setBool(String key, bool v) => set(key, v ? '1' : '0');

  AppThemeSettings get theme => AppThemeSettings.fromJsonString(get('theme'));
  set theme(AppThemeSettings t) => set('theme', t.toJsonString());
}

// ═════════════════════════════════ peers ═══════════════════════════════════

class StoredPeer {
  const StoredPeer({
    required this.identity,
    required this.name,
    required this.verified,
    required this.blocked,
    required this.muted,
    required this.firstSeen,
    required this.lastSeen,
    this.status,
    this.bio,
  });
  final PeerIdentity identity;
  final String? name;
  final String? status;
  final String? bio;
  final bool verified;
  final bool blocked;
  final bool muted;
  final int firstSeen;
  final int lastSeen;

  String get title => name ?? 'Peer ${identity.shortId}';
}

class PeerStore {
  PeerStore(this._d, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final MeshDatabase _d;
  final int Function() _clock;

  StoredPeer _row(Row r) => StoredPeer(
        identity: PeerIdentity.fromKeysSync(_bytes(r['keys'])),
        name: r['name'] as String?,
        verified: r['verified'] == 1,
        blocked: r['blocked'] == 1,
        muted: r['muted'] == 1,
        firstSeen: r['first_seen'] as int,
        lastSeen: r['last_seen'] as int,
        status: r['status'] as String?,
        bio: r['bio'] as String?,
      );

  /// Records / refreshes a peer. A null [name] never erases a known name.
  void upsert(PeerIdentity id, {String? name, String? status, String? bio}) {
    final now = _clock();
    _d.db.execute(
      'INSERT INTO peers(peer_id, keys, name, status, bio, first_seen, last_seen) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(peer_id) DO UPDATE SET '
      'name = COALESCE(excluded.name, name), '
      'status = COALESCE(excluded.status, status), '
      'bio = COALESCE(excluded.bio, bio), '
      'last_seen = excluded.last_seen',
      [
        id.peerId,
        Uint8List.fromList([...id.signPublicKey, ...id.agreePublicKey]),
        name,
        status,
        bio,
        now,
        now,
      ],
    );
  }

  StoredPeer? get(Uint8List peerId) {
    final r = _d.db.select('SELECT * FROM peers WHERE peer_id = ?', [peerId]);
    return r.isEmpty ? null : _row(r.first);
  }

  List<StoredPeer> all() => [
        for (final r
            in _d.db.select('SELECT * FROM peers ORDER BY last_seen DESC'))
          _row(r),
      ];

  List<StoredPeer> blocked() => [
        for (final r in _d.db.select('SELECT * FROM peers WHERE blocked = 1'))
          _row(r),
      ];

  bool isBlocked(Uint8List peerId) {
    final r =
        _d.db.select('SELECT blocked FROM peers WHERE peer_id = ?', [peerId]);
    return r.isNotEmpty && r.first['blocked'] == 1;
  }

  bool isMuted(Uint8List peerId) {
    final r =
        _d.db.select('SELECT muted FROM peers WHERE peer_id = ?', [peerId]);
    return r.isNotEmpty && r.first['muted'] == 1;
  }

  void setBlocked(Uint8List id, bool v) => _flag('blocked', id, v);
  void setMuted(Uint8List id, bool v) => _flag('muted', id, v);

  /// The user compared fingerprints out of band and confirms this identity.
  void setVerified(Uint8List id, bool v) => _flag('verified', id, v);

  void _flag(String col, Uint8List id, bool v) => _d.db
      .execute('UPDATE peers SET $col = ? WHERE peer_id = ?', [v ? 1 : 0, id]);

  /// Local search by name or peer-ID prefix. Matching is done in Dart because
  /// SQLite's lower()/LIKE only fold ASCII, which would break Cyrillic etc.
  List<StoredPeer> search(String query, {int limit = 30}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hex = q.replaceAll(RegExp(r'[^0-9a-f]'), '');
    final out = <StoredPeer>[];
    for (final p in all()) {
      final byName = (p.name ?? '').toLowerCase().contains(q);
      final byId = hex.isNotEmpty && p.identity.peerIdHex.startsWith(hex);
      if (byName || byId) out.add(p);
      if (out.length >= limit) break;
    }
    return out;
  }
}

/// [PeerDirectory] backed by the peers table with an in-memory cache, so the
/// crypto layer can look up keys synchronously and the data survives restarts.
class StoredPeerDirectory implements PeerDirectory {
  StoredPeerDirectory(this._peers) {
    for (final p in _peers.all()) {
      _cache[p.identity.peerIdHex] = p.identity;
    }
  }
  final PeerStore _peers;
  final Map<String, PeerIdentity> _cache = {};

  @override
  PeerIdentity? lookup(Uint8List peerId) => _cache[toHex(peerId)];

  @override
  void remember(PeerIdentity identity) {
    final isNew = !_cache.containsKey(identity.peerIdHex);
    _cache[identity.peerIdHex] = identity;
    if (isNew) _peers.upsert(identity);
  }

  @override
  Iterable<PeerIdentity> get all => _cache.values;
}

// ═══════════════════════════════ messages ══════════════════════════════════

enum MsgStatus {
  /// Waiting in the outbox: no attempt has reached a link yet.
  queued(0),

  /// Handed to a link at least once. NOT proof of delivery.
  sent(1),

  /// A direct neighbour attested with a signed receipt that it verified and
  /// forwarded the message. Still NOT proof of delivery.
  relayed(5),

  /// Every recipient returned a verified signed ack.
  delivered(2),

  /// The recipient's read receipt was verified.
  read(3),

  /// Expired in the outbox without an ack.
  failed(4);

  const MsgStatus(this.code);
  final int code;
  static MsgStatus of(int c) =>
      MsgStatus.values.firstWhere((s) => s.code == c, orElse: () => queued);
}

enum ConvKind {
  direct(1),
  channel(2);

  const ConvKind(this.code);
  final int code;
  static ConvKind of(int c) => c == 2 ? channel : direct;
}

class StoredMessage {
  const StoredMessage({
    required this.msgId,
    required this.sender,
    required this.convKind,
    required this.convId,
    this.roomId,
    required this.text,
    this.replyTo,
    required this.ts,
    required this.outgoing,
    this.status = MsgStatus.queued,
    this.edited = false,
    this.deleted = false,
    this.unread = false,
  });

  final Uint8List msgId;
  final Uint8List sender;
  final ConvKind convKind;
  final Uint8List convId;
  final Uint8List? roomId;
  final String text;
  final Uint8List? replyTo;
  final int ts;
  final bool outgoing;
  final MsgStatus status;
  final bool edited;
  final bool deleted;
  final bool unread;

  String get idHex => toHex(msgId);
}

class ConversationSummary {
  const ConversationSummary(this.convKind, this.convId, this.last, this.unread);
  final ConvKind convKind;
  final Uint8List convId;
  final StoredMessage last;
  final int unread;
}

class SearchHit {
  const SearchHit(this.message, this.snippet);
  final StoredMessage message;
  final String snippet;
}

class MessageStore {
  MessageStore(this._d);
  final MeshDatabase _d;

  StoredMessage _row(Row r) => StoredMessage(
        msgId: _bytes(r['msg_id']),
        sender: _bytes(r['sender']),
        convKind: ConvKind.of(r['conv_kind'] as int),
        convId: _bytes(r['conv_id']),
        roomId: _bytesOrNull(r['room_id']),
        text: r['text'] as String,
        replyTo: _bytesOrNull(r['reply_to']),
        ts: r['ts'] as int,
        outgoing: r['outgoing'] == 1,
        status: MsgStatus.of(r['status'] as int),
        edited: r['edited'] == 1,
        deleted: r['deleted'] == 1,
        unread: r['unread'] == 1,
      );

  /// Inserts a message; returns false if (msgId, sender) already exists.
  bool insert(StoredMessage m) {
    _d.db.execute(
      'INSERT OR IGNORE INTO messages(msg_id, sender, conv_kind, conv_id, '
      'room_id, text, reply_to, ts, outgoing, status, unread) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [
        m.msgId,
        m.sender,
        m.convKind.code,
        m.convId,
        m.roomId,
        m.text,
        m.replyTo,
        m.ts,
        m.outgoing ? 1 : 0,
        m.status.code,
        m.unread ? 1 : 0,
      ],
    );
    return _d.db.updatedRows > 0;
  }

  StoredMessage? get(Uint8List msgId, Uint8List sender) {
    final r = _d.db.select(
        'SELECT * FROM messages WHERE msg_id = ? AND sender = ?',
        [msgId, sender]);
    return r.isEmpty ? null : _row(r.first);
  }

  /// All messages with this ID (normally one; IDs are unique per sender).
  List<StoredMessage> byId(Uint8List msgId) => [
        for (final r
            in _d.db.select('SELECT * FROM messages WHERE msg_id = ?', [msgId]))
          _row(r),
      ];

  List<StoredMessage> list(
    ConvKind kind,
    Uint8List convId, {
    int limit = 200,
    int? before,
  }) {
    final rows = _d.db.select(
      'SELECT * FROM (SELECT rowid AS rid, * FROM messages WHERE conv_kind = ? '
      'AND conv_id = ? AND (? IS NULL OR ts < ?) ORDER BY ts DESC, rowid DESC '
      'LIMIT ?) ORDER BY ts ASC, rid ASC',
      [kind.code, convId, before, before, limit],
    );
    return [for (final r in rows) _row(r)];
  }

  /// Sets the status of an OWN message. Progress only moves forward:
  /// queued < sent < relayed < delivered < read. A late "sent" never hides a
  /// relay receipt or an ack, and an acknowledged message can no longer be
  /// marked failed.
  void setStatus(Uint8List msgId, MsgStatus s) {
    final r = _d.db.select(
        'SELECT status FROM messages WHERE msg_id = ? AND outgoing = 1',
        [msgId]);
    if (r.isEmpty) return;
    final cur = MsgStatus.of(r.first['status'] as int);
    int rank(MsgStatus x) => switch (x) {
          MsgStatus.queued => 0,
          MsgStatus.sent => 1,
          MsgStatus.relayed => 2,
          MsgStatus.delivered => 3,
          MsgStatus.read => 4,
          MsgStatus.failed => -1,
        };
    final confirmed = rank(cur) >= 3;
    if (s == MsgStatus.failed) {
      if (confirmed) return; // acked messages cannot fail
    } else if (rank(s) <= rank(cur) && cur != MsgStatus.failed) {
      return; // never move backwards
    }
    _d.db.execute(
        'UPDATE messages SET status = ? WHERE msg_id = ? AND outgoing = 1',
        [s.code, msgId]);
  }

  /// Edit: only the original author may edit, never a deleted message.
  bool applyEdit(Uint8List msgId, Uint8List author, String text) {
    _d.db.execute(
      'UPDATE messages SET text = ?, edited = 1 '
      'WHERE msg_id = ? AND sender = ? AND deleted = 0',
      [text, msgId, author],
    );
    return _d.db.updatedRows > 0;
  }

  /// Marks a message deleted and wipes its text (tombstone). [author] is the
  /// message's original sender; callers verify that the requester may delete
  /// it (author, or a moderator with deleteMessages) before calling.
  bool applyDelete(Uint8List msgId, Uint8List author) {
    _d.db.execute(
      "UPDATE messages SET text = '', deleted = 1 WHERE msg_id = ? AND sender = ?",
      [msgId, author],
    );
    final ok = _d.db.updatedRows > 0;
    if (ok) _d.db.execute('DELETE FROM reactions WHERE msg_id = ?', [msgId]);
    return ok;
  }

  // reactions

  void addReaction(Uint8List msgId, Uint8List reactor, String emoji) =>
      _d.db.execute(
          'INSERT OR IGNORE INTO reactions(msg_id, reactor, emoji) VALUES (?,?,?)',
          [msgId, reactor, emoji]);

  void removeReaction(Uint8List msgId, Uint8List reactor, String emoji) =>
      _d.db.execute(
          'DELETE FROM reactions WHERE msg_id = ? AND reactor = ? AND emoji = ?',
          [msgId, reactor, emoji]);

  /// emoji -> reactor peer-ID hex list
  Map<String, List<String>> reactions(Uint8List msgId) {
    final out = <String, List<String>>{};
    for (final r in _d.db.select(
        'SELECT reactor, emoji FROM reactions WHERE msg_id = ? ORDER BY emoji',
        [msgId])) {
      (out[r['emoji'] as String] ??= []).add(toHex(_bytes(r['reactor'])));
    }
    return out;
  }

  // read state

  int unreadCount(ConvKind kind, Uint8List convId) => _d.db.select(
        'SELECT COUNT(*) c FROM messages WHERE conv_kind=? AND conv_id=? AND unread=1',
        [kind.code, convId],
      ).first['c'] as int;

  /// Marks incoming messages read locally; returns their IDs (for receipts).
  List<StoredMessage> markConversationRead(ConvKind kind, Uint8List convId) {
    final rows = _d.db.select(
      'SELECT * FROM messages WHERE conv_kind=? AND conv_id=? AND unread=1',
      [kind.code, convId],
    );
    _d.db.execute(
      'UPDATE messages SET unread = 0 WHERE conv_kind=? AND conv_id=? AND unread=1',
      [kind.code, convId],
    );
    return [for (final r in rows) _row(r)];
  }

  /// A verified read receipt from [reader] for our own message.
  void markReadByRecipient(Uint8List msgId) => _d.db.execute(
      'UPDATE messages SET status = 3 WHERE msg_id = ? AND outgoing = 1 AND status < 4',
      [msgId]);

  List<ConversationSummary> conversations(ConvKind kind) {
    final rows = _d.db.select(
      'SELECT conv_id, MAX(ts) mx FROM messages WHERE conv_kind = ? GROUP BY conv_id '
      'ORDER BY mx DESC',
      [kind.code],
    );
    final out = <ConversationSummary>[];
    for (final r in rows) {
      final id = _bytes(r['conv_id']);
      final last = list(kind, id, limit: 1);
      if (last.isEmpty) continue;
      out.add(ConversationSummary(kind, id, last.last, unreadCount(kind, id)));
    }
    return out;
  }

  // search

  /// Full-text search over local messages only (FTS5, prefix match per word).
  List<SearchHit> search(String query, {int limit = 50}) {
    final match = _ftsQuery(query);
    if (match == null) return const [];
    final rows = _d.db.select(
      "SELECT m.*, snippet(message_fts, 0, '[', ']', '…', 8) AS snip "
      'FROM message_fts JOIN messages m ON m.rowid = message_fts.rowid '
      'WHERE message_fts MATCH ? AND m.deleted = 0 '
      'ORDER BY m.ts DESC LIMIT ?',
      [match, limit],
    );
    return [for (final r in rows) SearchHit(_row(r), r['snip'] as String)];
  }

  /// Turns free user input into a safe FTS5 expression: each word becomes a
  /// quoted prefix term, so operators/quotes in the input cannot break or
  /// alter the query.
  static String? _ftsQuery(String input) {
    final words = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(input)
        .map((m) => m.group(0)!)
        .toList();
    if (words.isEmpty) return null;
    return words.map((w) => '"$w"*').join(' ');
  }
}

// ══════════════════════════════════ outbox ═════════════════════════════════

class OutboxRow {
  const OutboxRow({
    required this.id,
    required this.msgId,
    required this.dest,
    required this.roomId,
    required this.content,
    required this.tracked,
    required this.attempts,
  });
  final int id;
  final Uint8List msgId;
  final Uint8List dest;
  final Uint8List? roomId;
  final Uint8List content;

  /// Tracked rows belong to a visible chat message (status is derived from
  /// them); untracked rows are control traffic (room sync, receipts, ...).
  final bool tracked;
  final int attempts;
}

/// Persistent, restart-safe send queue.
class OutboxStore {
  OutboxStore(this._d);
  final MeshDatabase _d;

  static const Duration defaultTtl = Duration(days: 7);

  void enqueue({
    required Uint8List msgId,
    required Uint8List dest,
    Uint8List? roomId,
    required Uint8List content,
    bool tracked = true,
    required int nowMs,
    Duration ttl = defaultTtl,
  }) {
    _d.db.execute(
      'INSERT OR IGNORE INTO outbox(msg_id, dest, room_id, content, tracked, '
      'created_at, next_attempt_at, expires_at) VALUES (?,?,?,?,?,?,?,?)',
      [
        msgId,
        dest,
        roomId,
        content,
        tracked ? 1 : 0,
        nowMs,
        nowMs,
        nowMs + ttl.inMilliseconds,
      ],
    );
  }

  /// Pending rows whose retry time has come.
  List<OutboxRow> due(int nowMs, {int limit = 100}) => [
        for (final r in _d.db.select(
          'SELECT * FROM outbox WHERE state = 0 AND next_attempt_at <= ? '
          'AND expires_at > ? ORDER BY id LIMIT ?',
          [nowMs, nowMs, limit],
        ))
          OutboxRow(
            id: r['id'] as int,
            msgId: _bytes(r['msg_id']),
            dest: _bytes(r['dest']),
            roomId: _bytesOrNull(r['room_id']),
            content: _bytes(r['content']),
            tracked: r['tracked'] == 1,
            attempts: r['attempts'] as int,
          ),
      ];

  void recordAttempt(int id, {required int nextAttemptAt}) => _d.db.execute(
      'UPDATE outbox SET attempts = attempts + 1, next_attempt_at = ? WHERE id = ?',
      [nextAttemptAt, id]);

  /// Delays a row without counting an attempt (no route right now).
  void defer(int id, int nextAttemptAt) => _d.db.execute(
      'UPDATE outbox SET next_attempt_at = ? WHERE id = ?',
      [nextAttemptAt, id]);

  /// Make every pending row for [dest] due immediately (peer came online).
  void releaseFor(Uint8List dest, int nowMs) => _d.db.execute(
      'UPDATE outbox SET next_attempt_at = ? WHERE dest = ? AND state = 0 '
      'AND next_attempt_at > ?',
      [nowMs, dest, nowMs]);

  void releaseAll(int nowMs) => _d.db.execute(
      'UPDATE outbox SET next_attempt_at = ? WHERE state = 0 AND next_attempt_at > ?',
      [nowMs, nowMs]);

  /// A verified ack arrived. Control rows are removed, tracked ones kept as
  /// acknowledged (for status aggregation).
  bool acknowledge(Uint8List msgId, Uint8List dest) {
    _d.db.execute(
        'UPDATE outbox SET state = 1 WHERE msg_id = ? AND dest = ? AND state = 0',
        [msgId, dest]);
    final changed = _d.db.updatedRows > 0;
    _d.db.execute(
        'DELETE FROM outbox WHERE msg_id = ? AND dest = ? AND tracked = 0',
        [msgId, dest]);
    return changed;
  }

  /// A direct neighbour attested it forwarded this message towards [dest].
  /// Only meaningful for rows still pending.
  bool markRelayed(Uint8List msgId, Uint8List dest) {
    _d.db.execute(
        'UPDATE outbox SET relayed = 1 WHERE msg_id = ? AND dest = ? '
        'AND state = 0 AND relayed = 0',
        [msgId, dest]);
    return _d.db.updatedRows > 0;
  }

  /// Marks overdue pending rows expired; returns affected message IDs.
  List<Uint8List> expire(int nowMs) {
    final ids = [
      for (final r in _d.db.select(
          'SELECT DISTINCT msg_id FROM outbox WHERE state = 0 AND expires_at <= ?',
          [nowMs]))
        _bytes(r['msg_id']),
    ];
    _d.db.execute(
        'UPDATE outbox SET state = 2 WHERE state = 0 AND expires_at <= ?',
        [nowMs]);
    _d.db.execute('DELETE FROM outbox WHERE state = 2 AND tracked = 0');
    return ids;
  }

  int pendingCount() =>
      _d.db.select('SELECT COUNT(*) c FROM outbox WHERE state = 0').first['c']
          as int;

  /// Derived status of an own message from its recipients' rows.
  MsgStatus? statusOf(Uint8List msgId) {
    final rows = _d.db.select(
        'SELECT state, attempts, relayed FROM outbox WHERE msg_id = ? AND tracked = 1',
        [msgId]);
    if (rows.isEmpty) return null;
    final acked = rows.where((r) => r['state'] == 1).length;
    if (acked == rows.length) return MsgStatus.delivered;
    final pending = rows.where((r) => r['state'] == 0).toList();
    if (pending.isEmpty && acked == 0) return MsgStatus.failed;
    if (pending.isEmpty) return MsgStatus.delivered; // rest expired, some acked
    final relayed = pending.any((r) => r['relayed'] == 1);
    if (relayed) return MsgStatus.relayed;
    final attempted = rows.any((r) => (r['attempts'] as int) > 0);
    return (attempted || acked > 0) ? MsgStatus.sent : MsgStatus.queued;
  }

  /// Prunes finished rows older than [olderThanMs] to keep the table small.
  void vacuum(int olderThanMs) => _d.db.execute(
      'DELETE FROM outbox WHERE state != 0 AND created_at < ?', [olderThanMs]);
}

// ═══════════════════════════════════ rooms ═════════════════════════════════

class StoredRoom {
  const StoredRoom({
    required this.roomId,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    required this.isPublic,
    required this.deleted,
    required this.active,
    required this.muted,
  });
  final Uint8List roomId;
  final String name;
  final String description;
  final String icon;
  final int? color;
  final bool isPublic;
  final bool deleted;

  /// False once the local user is no longer a member (kicked / left).
  final bool active;
  final bool muted;
  String get idHex => toHex(roomId);
}

class StoredChannel {
  const StoredChannel(this.roomId, this.channelId, this.name, this.description,
      this.icon, this.color, this.muted);
  final Uint8List roomId;
  final Uint8List channelId;
  final String name;
  final String description;
  final String icon;
  final int? color;
  final bool muted;
}

class RoomStore {
  RoomStore(this._d);
  final MeshDatabase _d;

  /// Persists newly accepted events (idempotent).
  void saveEvents(Iterable<RoomEvent> events) {
    for (final e in events) {
      _d.db.execute(
          'INSERT OR IGNORE INTO room_events(event_id, room_id, lamport, data) '
          'VALUES (?,?,?,?)',
          [e.id, e.roomId, e.lamport, e.encode()]);
    }
  }

  List<RoomEvent> loadEvents(Uint8List roomId) => [
        for (final r in _d.db.select(
            'SELECT data FROM room_events WHERE room_id = ? ORDER BY lamport',
            [roomId]))
          RoomEvent.decode(_bytes(r['data'])),
      ];

  List<Uint8List> roomIds() => [
        for (final r in _d.db
            .select('SELECT room_id FROM rooms ORDER BY updated_at DESC'))
          _bytes(r['room_id']),
      ];

  /// Rewrites the materialised tables from [state]. Local-only flags (mute)
  /// are preserved. [me] decides whether the room is still active.
  void materialize(RoomState state, Uint8List me, int nowMs) {
    final id = state.roomId;
    _d.db.execute(
      'INSERT INTO rooms(room_id, name, description, icon, color, is_public, '
      'deleted, active, updated_at) VALUES (?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(room_id) DO UPDATE SET name=excluded.name, '
      'description=excluded.description, icon=excluded.icon, color=excluded.color, '
      'is_public=excluded.is_public, deleted=excluded.deleted, '
      'active=excluded.active, updated_at=excluded.updated_at',
      [
        id,
        state.name,
        state.description,
        state.icon,
        state.color,
        state.isPublic ? 1 : 0,
        state.deleted ? 1 : 0,
        state.isMember(me) ? 1 : 0,
        nowMs,
      ],
    );
    final keep = <Uint8List>[];
    for (final c in state.channels.values) {
      keep.add(c.id);
      _d.db.execute(
        'INSERT INTO channels(room_id, channel_id, name, description, icon, color) '
        'VALUES (?,?,?,?,?,?) ON CONFLICT(room_id, channel_id) DO UPDATE SET '
        'name=excluded.name, description=excluded.description, '
        'icon=excluded.icon, color=excluded.color',
        [id, c.id, c.name, c.description, c.icon, c.color],
      );
    }
    final existing =
        _d.db.select('SELECT channel_id FROM channels WHERE room_id = ?', [id]);
    final keepHex = keep.map(toHex).toSet();
    for (final r in existing) {
      final cid = _bytes(r['channel_id']);
      if (!keepHex.contains(toHex(cid))) {
        _d.db.execute(
            'DELETE FROM channels WHERE room_id = ? AND channel_id = ?',
            [id, cid]);
      }
    }
    _d.db.execute('DELETE FROM members WHERE room_id = ?', [id]);
    for (final m in state.members.values) {
      _d.db.execute(
        'INSERT INTO members(room_id, peer_id, role, keys) VALUES (?,?,?,?)',
        [
          id,
          m.identity.peerId,
          m.role.wire,
          Uint8List.fromList(
              [...m.identity.signPublicKey, ...m.identity.agreePublicKey]),
        ],
      );
    }
  }

  StoredRoom? room(Uint8List roomId) {
    final r = _d.db.select('SELECT * FROM rooms WHERE room_id = ?', [roomId]);
    return r.isEmpty ? null : _room(r.first);
  }

  List<StoredRoom> rooms() => [
        for (final r
            in _d.db.select('SELECT * FROM rooms ORDER BY updated_at DESC'))
          _room(r),
      ];

  StoredRoom _room(Row r) => StoredRoom(
        roomId: _bytes(r['room_id']),
        name: r['name'] as String,
        description: r['description'] as String,
        icon: r['icon'] as String,
        color: r['color'] as int?,
        isPublic: r['is_public'] == 1,
        deleted: r['deleted'] == 1,
        active: r['active'] == 1,
        muted: r['muted'] == 1,
      );

  List<StoredChannel> channels(Uint8List roomId) => [
        for (final r in _d.db.select(
            'SELECT * FROM channels WHERE room_id = ? ORDER BY rowid',
            [roomId]))
          StoredChannel(
            _bytes(r['room_id']),
            _bytes(r['channel_id']),
            r['name'] as String,
            r['description'] as String,
            r['icon'] as String,
            r['color'] as int?,
            r['muted'] == 1,
          ),
      ];

  List<Member> members(Uint8List roomId) => [
        for (final r in _d.db
            .select('SELECT * FROM members WHERE room_id = ?', [roomId]))
          Member(PeerIdentity.fromKeysSync(_bytes(r['keys'])),
              Role.fromWire(r['role'] as int) ?? Role.member),
      ];

  void setRoomMuted(Uint8List roomId, bool v) => _d.db.execute(
      'UPDATE rooms SET muted = ? WHERE room_id = ?', [v ? 1 : 0, roomId]);

  void setChannelMuted(Uint8List roomId, Uint8List channelId, bool v) =>
      _d.db.execute(
          'UPDATE channels SET muted = ? WHERE room_id = ? AND channel_id = ?',
          [v ? 1 : 0, roomId, channelId]);

  bool isChannelMuted(Uint8List channelId) {
    final r = _d.db.select(
        'SELECT c.muted cm, r.muted rm FROM channels c JOIN rooms r '
        'ON r.room_id = c.room_id WHERE c.channel_id = ?',
        [channelId]);
    return r.isNotEmpty && (r.first['cm'] == 1 || r.first['rm'] == 1);
  }

  /// Local search over room and channel names/descriptions (Unicode-aware).
  List<(StoredRoom, StoredChannel?)> search(String query, {int limit = 30}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    bool hit(String a, String b) =>
        a.toLowerCase().contains(q) || b.toLowerCase().contains(q);
    final out = <(StoredRoom, StoredChannel?)>[];
    for (final r in rooms()) {
      if (hit(r.name, r.description)) out.add((r, null));
      for (final c in channels(r.roomId)) {
        if (hit(c.name, c.description)) out.add((r, c));
      }
      if (out.length >= limit) break;
    }
    return out;
  }
}

// ═══════════════════════ replay cache + used invites ═══════════════════════

class SeenStore {
  SeenStore(this._d);
  final MeshDatabase _d;

  void save(String key, int expires) => _d.db.execute(
      'INSERT OR REPLACE INTO seen_packets(key, expires) VALUES (?, ?)',
      [key, expires]);

  Map<String, int> load(int nowMs) => {
        for (final r in _d.db.select(
            'SELECT key, expires FROM seen_packets WHERE expires > ?', [nowMs]))
          r['key'] as String: r['expires'] as int,
      };

  void prune(int nowMs) =>
      _d.db.execute('DELETE FROM seen_packets WHERE expires <= ?', [nowMs]);
}

class InviteStore {
  InviteStore(this._d);
  final MeshDatabase _d;

  /// Atomically marks [nonce] as used. Returns false if it already was.
  bool consume(Uint8List nonce, int nowMs) {
    _d.db.execute(
        'INSERT OR IGNORE INTO used_invites(nonce, used_at) VALUES (?, ?)',
        [nonce, nowMs]);
    return _d.db.updatedRows > 0;
  }
}
