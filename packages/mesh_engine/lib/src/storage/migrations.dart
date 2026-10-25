/// Ordered schema migrations. `PRAGMA user_version` stores the applied
/// version; each migration runs in ONE transaction together with the version
/// bump, so a crash never leaves a half-migrated database.
///
/// Rules: never edit a released migration; add a new one. Migrations must be
/// forward-only and keep existing data.
class Migration {
  const Migration(this.version, this.statements);
  final int version;
  final List<String> statements;
}

const List<Migration> migrations = [
  // ───────────────────────────── v1: base schema ─────────────────────────────
  Migration(1, [
    // key/value application settings (theme json, privacy toggles, ...)
    '''CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )''',
    // Known peers/users. Public keys only - private keys are NEVER stored here
    // (they live in the platform secure store).
    '''CREATE TABLE peers (
      peer_id    BLOB PRIMARY KEY,
      keys       BLOB NOT NULL,
      name       TEXT,
      verified   INTEGER NOT NULL DEFAULT 0,
      blocked    INTEGER NOT NULL DEFAULT 0,
      muted      INTEGER NOT NULL DEFAULT 0,
      first_seen INTEGER NOT NULL,
      last_seen  INTEGER NOT NULL
    )''',
    // Rooms/channels/members are a materialised view of the signed event log.
    '''CREATE TABLE rooms (
      room_id     BLOB PRIMARY KEY,
      name        TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      icon        TEXT NOT NULL DEFAULT '',
      color       INTEGER,
      is_public   INTEGER NOT NULL DEFAULT 0,
      deleted     INTEGER NOT NULL DEFAULT 0,
      active      INTEGER NOT NULL DEFAULT 1,
      muted       INTEGER NOT NULL DEFAULT 0,
      updated_at  INTEGER NOT NULL
    )''',
    '''CREATE TABLE channels (
      room_id     BLOB NOT NULL,
      channel_id  BLOB NOT NULL,
      name        TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      icon        TEXT NOT NULL DEFAULT '',
      color       INTEGER,
      muted       INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (room_id, channel_id)
    )''',
    '''CREATE TABLE members (
      room_id BLOB NOT NULL,
      peer_id BLOB NOT NULL,
      role    INTEGER NOT NULL,
      keys    BLOB NOT NULL,
      PRIMARY KEY (room_id, peer_id)
    )''',
    '''CREATE TABLE room_events (
      event_id BLOB PRIMARY KEY,
      room_id  BLOB NOT NULL,
      lamport  INTEGER NOT NULL,
      data     BLOB NOT NULL
    )''',
    'CREATE INDEX idx_room_events_room ON room_events(room_id)',
    // conv_kind: 1 = direct chat (conv_id = other peer), 2 = room channel.
    '''CREATE TABLE messages (
      msg_id    BLOB NOT NULL,
      sender    BLOB NOT NULL,
      conv_kind INTEGER NOT NULL,
      conv_id   BLOB NOT NULL,
      room_id   BLOB,
      text      TEXT NOT NULL,
      reply_to  BLOB,
      ts        INTEGER NOT NULL,
      outgoing  INTEGER NOT NULL,
      status    INTEGER NOT NULL DEFAULT 0,
      edited    INTEGER NOT NULL DEFAULT 0,
      deleted   INTEGER NOT NULL DEFAULT 0,
      unread    INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (msg_id, sender)
    )''',
    'CREATE INDEX idx_messages_conv ON messages(conv_kind, conv_id, ts)',
    'CREATE INDEX idx_messages_id ON messages(msg_id)',
    '''CREATE TABLE reactions (
      msg_id  BLOB NOT NULL,
      reactor BLOB NOT NULL,
      emoji   TEXT NOT NULL,
      PRIMARY KEY (msg_id, reactor, emoji)
    )''',
    // Persistent send queue. One row per (message, recipient).
    // state: 0 pending, 1 acknowledged, 2 expired.
    '''CREATE TABLE outbox (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      msg_id          BLOB NOT NULL,
      dest            BLOB NOT NULL,
      room_id         BLOB,
      content         BLOB NOT NULL,
      tracked         INTEGER NOT NULL DEFAULT 1,
      created_at      INTEGER NOT NULL,
      attempts        INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL,
      expires_at      INTEGER NOT NULL,
      state           INTEGER NOT NULL DEFAULT 0,
      UNIQUE (msg_id, dest)
    )''',
    'CREATE INDEX idx_outbox_due ON outbox(state, next_attempt_at)',
    // Replay-protection cache, persisted so a restart cannot re-admit packets.
    '''CREATE TABLE seen_packets (
      key     TEXT PRIMARY KEY,
      expires INTEGER NOT NULL
    )''',
    // Single-use invite nonces already redeemed on this device.
    '''CREATE TABLE used_invites (
      nonce   BLOB PRIMARY KEY,
      used_at INTEGER NOT NULL
    )''',
  ]),

  // ──────────────────────── v2: local full-text search ────────────────────────
  Migration(2, [
    // External-content FTS5 index over message text. Existing rows are indexed
    // by the 'rebuild' command, so upgrading a v1 database keeps search working.
    '''CREATE VIRTUAL TABLE message_fts USING fts5(
      text,
      content='messages',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 2'
    )''',
    '''CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO message_fts(rowid, text) VALUES (new.rowid, new.text);
    END''',
    '''CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
      INSERT INTO message_fts(message_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
    END''',
    '''CREATE TRIGGER messages_au AFTER UPDATE OF text ON messages BEGIN
      INSERT INTO message_fts(message_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
      INSERT INTO message_fts(rowid, text) VALUES (new.rowid, new.text);
    END''',
    "INSERT INTO message_fts(message_fts) VALUES ('rebuild')",
  ]),

  // ──────────────── v3: peer profile (status line and bio) ────────────────
  Migration(3, [
    'ALTER TABLE peers ADD COLUMN status TEXT',
    'ALTER TABLE peers ADD COLUMN bio TEXT',
  ]),

  // ───────────── v4: relay attestations on outbox rows ("Relayed") ─────────────
  Migration(4, [
    'ALTER TABLE outbox ADD COLUMN relayed INTEGER NOT NULL DEFAULT 0',
  ]),
];
