import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/sqlite_init.dart';

Uint8List id([int seed = 0]) =>
    Uint8List.fromList(List.generate(16, (i) => (i + seed * 7) & 0xFF));

Future<PeerIdentity> newPeer() async =>
    (await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32))).public;

StoredMessage msg(
  int n, {
  String text = 'hello',
  Uint8List? sender,
  bool outgoing = false,
  Uint8List? conv,
  int ts = 1000,
  bool unread = false,
}) =>
    StoredMessage(
      msgId: id(n),
      sender: sender ?? id(100),
      convKind: ConvKind.direct,
      convId: conv ?? id(100),
      text: text,
      ts: ts + n,
      outgoing: outgoing,
      unread: unread,
    );

void main() {
  setUpAll(initSqliteForTests);
  late MeshDatabase db;
  setUp(() => db = MeshDatabase.openInMemory());
  tearDown(() => db.close());

  group('migrations', () {
    test('fresh database is created at the latest version', () {
      expect(db.schemaVersion, MeshDatabase.latestVersion);
      final tables = db.db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'settings',
          'peers',
          'rooms',
          'channels',
          'members',
          'room_events',
          'messages',
          'reactions',
          'outbox',
          'seen_packets',
          'used_invites',
          'message_fts',
        ]),
      );
    });

    test('v1 -> v2 keeps data and makes OLD messages searchable', () {
      final raw = sqlite3.openInMemory();
      final v1 = MeshDatabase.wrap(raw, upTo: 1);
      expect(v1.schemaVersion, 1);
      MessageStoreRaw.insertLegacy(raw, 'старое сообщение про горы');
      MessageStoreRaw.insertLegacy(raw, 'old message about lakes', n: 2);
      // (the FTS table does not exist yet)
      expect(
        () => raw.select("SELECT * FROM message_fts"),
        throwsA(isA<SqliteException>()),
      );
      // upgrade the same connection
      final upgraded = MeshDatabase.wrap(raw);
      expect(upgraded.schemaVersion, MeshDatabase.latestVersion);
      final store = MessageStore(upgraded);
      expect(store.search('гор').single.message.text, contains('горы'));
      expect(store.search('lakes').single.message.text, contains('lakes'));
      expect(raw.select('SELECT COUNT(*) c FROM messages').first['c'], 2);
    });

    test('v2 -> v3 adds profile columns and keeps existing peers', () async {
      final raw = sqlite3.openInMemory();
      MeshDatabase.wrap(raw, upTo: 2);
      final peer = await newPeer();
      raw.execute(
        'INSERT INTO peers(peer_id, keys, name, first_seen, last_seen) VALUES (?,?,?,?,?)',
        [
          peer.peerId,
          Uint8List.fromList([...peer.signPublicKey, ...peer.agreePublicKey]),
          'Old Friend',
          1,
          2,
        ],
      );
      final up = MeshDatabase.wrap(raw);
      expect(up.schemaVersion, MeshDatabase.latestVersion);
      final store = PeerStore(up);
      final p = store.get(peer.peerId)!;
      expect(p.name, 'Old Friend');
      expect(p.status, isNull);
      store.upsert(peer, status: 'hiking', bio: 'I like trails');
      expect(store.get(peer.peerId)!.status, 'hiking');
      expect(store.get(peer.peerId)!.bio, 'I like trails');
      store.upsert(peer); // later sighting without profile keeps it
      expect(store.get(peer.peerId)!.status, 'hiking');
    });

    test('v3 -> v4 adds the relayed flag; old queue rows stay pending', () {
      final raw = sqlite3.openInMemory();
      MeshDatabase.wrap(raw, upTo: 3);
      raw.execute(
        'INSERT INTO outbox(msg_id, dest, content, tracked, created_at, '
        'next_attempt_at, expires_at) VALUES (?,?,?,?,?,?,?)',
        [
          id(1),
          id(9),
          Uint8List.fromList([1]),
          1,
          1,
          1,
          99999999999
        ],
      );
      final up = MeshDatabase.wrap(raw);
      expect(up.schemaVersion, 4);
      final o = OutboxStore(up);
      expect(o.pendingCount(), 1);
      expect(o.statusOf(id(1)), MsgStatus.queued);
      expect(o.markRelayed(id(1), id(9)), isTrue);
      expect(o.statusOf(id(1)), MsgStatus.relayed);
    });

    test('opening twice is idempotent', () {
      final again = MeshDatabase.wrap(db.db);
      expect(again.schemaVersion, MeshDatabase.latestVersion);
    });

    test('a database from a NEWER app version is refused, untouched', () {
      final raw = sqlite3.openInMemory();
      raw.execute('PRAGMA user_version = 999');
      expect(() => MeshDatabase.wrap(raw), throwsStateError);
    });

    test('transaction rolls back everything on error', () {
      final s = SettingsStore(db);
      expect(
        () => db.transaction(() {
          s.set('a', '1');
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(s.get('a'), isNull);
    });

    test('foreign tables only hold public key material (no private keys)', () {
      final cols = db.db
          .select("SELECT name FROM pragma_table_info('peers')")
          .map((r) => r['name'] as String)
          .toList();
      expect(cols.any((c) => c.contains('private') || c.contains('seed')),
          isFalse);
    });
  });

  group('settings and theme', () {
    test('typed settings and theme persistence', () {
      final s = SettingsStore(db);
      expect(s.getBool('read_receipts', fallback: true), isTrue);
      s.setBool('read_receipts', false);
      expect(s.getBool('read_receipts', fallback: true), isFalse);
      s.theme = const AppThemeSettings(
              mode: ThemeModeSetting.amoled, presetId: 'cyberpunk')
          .withRoomColor('ab', 0xFF112233);
      expect(s.theme.mode, ThemeModeSetting.amoled);
      expect(s.theme.colorForRoom('ab'), 0xFF112233);
    });
  });

  group('peers', () {
    test('upsert keeps the name when later seen without one', () async {
      final p = PeerStore(db);
      final a = await newPeer();
      p.upsert(a, name: 'Alice');
      p.upsert(a);
      expect(p.get(a.peerId)!.name, 'Alice');
      expect(p.get(a.peerId)!.identity, a);
    });

    test('block / mute / verified flags', () async {
      final p = PeerStore(db);
      final a = await newPeer();
      p.upsert(a);
      expect(p.isBlocked(a.peerId), isFalse);
      p.setBlocked(a.peerId, true);
      p.setMuted(a.peerId, true);
      p.setVerified(a.peerId, true);
      final s = p.get(a.peerId)!;
      expect([s.blocked, s.muted, s.verified], [true, true, true]);
      expect(p.blocked().length, 1);
      p.setBlocked(a.peerId, false);
      expect(p.isBlocked(a.peerId), isFalse);
    });

    test('search by name and by peer-ID prefix; wildcards are literal',
        () async {
      final p = PeerStore(db);
      final a = await newPeer(), b = await newPeer();
      p.upsert(a, name: 'Alice Ковалёва');
      p.upsert(b, name: 'Bob');
      expect(p.search('ковал').single.identity, a);
      expect(p.search('BOB').single.identity, b);
      expect(p.search(a.peerIdHex.substring(0, 6)).single.identity, a);
      expect(p.search('%'), isEmpty);
      expect(p.search('_'), isEmpty);
    });

    test('directory survives a restart', () async {
      final p = PeerStore(db);
      final dir = StoredPeerDirectory(p);
      final a = await newPeer();
      dir.remember(a);
      final dir2 = StoredPeerDirectory(PeerStore(db)); // "new process"
      expect(dir2.lookup(a.peerId), a);
    });
  });

  group('messages', () {
    late MessageStore m;
    setUp(() => m = MessageStore(db));

    test('insert is idempotent per (msgId, sender)', () {
      expect(m.insert(msg(1)), isTrue);
      expect(m.insert(msg(1)), isFalse);
      expect(m.list(ConvKind.direct, id(100)).length, 1);
    });

    test('same msgId from a different sender is a different message', () {
      m.insert(msg(1, sender: id(100)));
      expect(m.insert(msg(1, sender: id(101), conv: id(101))), isTrue);
    });

    test('only the author can edit; deleted messages cannot be edited', () {
      m.insert(msg(1, text: 'orig'));
      expect(m.applyEdit(id(1), id(101), 'hacked'), isFalse);
      expect(m.get(id(1), id(100))!.text, 'orig');
      expect(m.applyEdit(id(1), id(100), 'edited'), isTrue);
      expect(m.get(id(1), id(100))!.edited, isTrue);
      m.applyDelete(id(1), id(100));
      expect(m.applyEdit(id(1), id(100), 'zombie'), isFalse);
    });

    test('delete leaves a tombstone, wipes text and reactions', () {
      m.insert(msg(1, text: 'secret'));
      m.addReaction(id(1), id(5), '👍');
      expect(m.applyDelete(id(1), id(100)), isTrue);
      final d = m.get(id(1), id(100))!;
      expect([d.deleted, d.text], [true, '']);
      expect(m.reactions(id(1)), isEmpty);
      expect(m.search('secret'), isEmpty);
    });

    test('reactions: add, dedupe, remove, group by emoji', () {
      m.insert(msg(1));
      m.addReaction(id(1), id(5), '👍');
      m.addReaction(id(1), id(5), '👍');
      m.addReaction(id(1), id(6), '👍');
      m.addReaction(id(1), id(6), '❤️');
      final r = m.reactions(id(1));
      expect(r['👍']!.length, 2);
      expect(r['❤️']!.length, 1);
      m.removeReaction(id(1), id(5), '👍');
      expect(m.reactions(id(1))['👍']!.length, 1);
    });

    test('status only moves forward: sent < relayed < delivered < read', () {
      m.insert(msg(1, sender: id(200), outgoing: true));
      m.setStatus(id(1), MsgStatus.sent);
      m.setStatus(id(1), MsgStatus.relayed);
      m.setStatus(
          id(1), MsgStatus.sent); // late retry must not hide the receipt
      expect(m.get(id(1), id(200))!.status, MsgStatus.relayed);
      m.setStatus(id(1), MsgStatus.queued);
      expect(m.get(id(1), id(200))!.status, MsgStatus.relayed);
      m.setStatus(id(1), MsgStatus.delivered);
      m.setStatus(id(1), MsgStatus.relayed);
      expect(m.get(id(1), id(200))!.status, MsgStatus.delivered);
    });

    test('a failed message may still be revived by a late receipt/ack', () {
      m.insert(msg(2, sender: id(200), outgoing: true));
      m.setStatus(id(2), MsgStatus.failed);
      m.setStatus(id(2), MsgStatus.delivered);
      expect(m.get(id(2), id(200))!.status, MsgStatus.delivered);
    });

    test('status never downgrades after delivery', () {
      m.insert(msg(1, sender: id(200), outgoing: true));
      m.setStatus(id(1), MsgStatus.sent);
      m.setStatus(id(1), MsgStatus.delivered);
      m.setStatus(id(1), MsgStatus.sent); // late, must be ignored
      m.setStatus(id(1), MsgStatus.failed); // must be ignored
      expect(m.get(id(1), id(200))!.status, MsgStatus.delivered);
      m.setStatus(id(1), MsgStatus.read);
      expect(m.get(id(1), id(200))!.status, MsgStatus.read);
      m.setStatus(id(1), MsgStatus.delivered);
      expect(m.get(id(1), id(200))!.status, MsgStatus.read);
    });

    test('unread counters and read marking return the ids for receipts', () {
      m.insert(msg(1, unread: true));
      m.insert(msg(2, unread: true));
      m.insert(msg(3, outgoing: true, sender: id(200)));
      expect(m.unreadCount(ConvKind.direct, id(100)), 2);
      final read = m.markConversationRead(ConvKind.direct, id(100));
      expect(read.map((e) => e.idHex).toSet(), {toHex(id(1)), toHex(id(2))});
      expect(m.unreadCount(ConvKind.direct, id(100)), 0);
      expect(m.markConversationRead(ConvKind.direct, id(100)), isEmpty);
    });

    test('conversation list is ordered by recency with last message', () {
      m.insert(msg(1, conv: id(100), ts: 1000));
      m.insert(msg(2, conv: id(101), sender: id(101), ts: 5000, unread: true));
      final c = m.conversations(ConvKind.direct);
      expect(c.first.convId, id(101));
      expect(c.first.unread, 1);
      expect(c.last.convId, id(100));
    });

    test('history paging', () {
      for (var i = 1; i <= 30; i++) {
        m.insert(msg(i, text: 'm$i'));
      }
      final page = m.list(ConvKind.direct, id(100), limit: 10);
      expect(page.map((e) => e.text).first, 'm21');
      expect(page.last.text, 'm30');
      final older =
          m.list(ConvKind.direct, id(100), limit: 10, before: page.first.ts);
      expect(older.last.text, 'm20');
    });

    group('search (local FTS5 only)', () {
      test('finds Latin and Cyrillic by prefix, case-insensitively', () {
        m.insert(msg(1, text: 'Встреча в горах завтра'));
        m.insert(msg(2, text: 'Hello Mountain trip'));
        expect(m.search('ГОР').single.message.idHex, toHex(id(1)));
        expect(m.search('mount').single.message.idHex, toHex(id(2)));
        expect(m.search('trip hello').length, 1); // both words
        expect(m.search('nothing here'), isEmpty);
      });

      test('edits update the index, deletes remove it', () {
        m.insert(msg(1, text: 'alpha'));
        expect(m.search('alpha'), hasLength(1));
        m.applyEdit(id(1), id(100), 'omega');
        expect(m.search('alpha'), isEmpty);
        expect(m.search('omega'), hasLength(1));
      });

      test('hostile input cannot break or alter the query', () {
        m.insert(msg(1, text: 'plain words here'));
        for (final q in [
          '"',
          '*',
          '" OR 1=1 --',
          'NEAR(a b)',
          'text:plain',
          '(',
          ')',
          "'",
          'a AND',
          '-plain',
          '^plain',
          '   ',
          '',
        ]) {
          expect(() => m.search(q), returnsNormally, reason: q);
        }
        expect(m.search('"'), isEmpty);
        // operators are neutralised: NOT is just another required word
        expect(m.search('NOT plain'), isEmpty);
        expect(m.search('plain words'), hasLength(1));
      });

      test('snippets highlight the hit', () {
        m.insert(msg(1, text: 'the quick brown fox'));
        expect(m.search('brown').single.snippet, contains('[brown]'));
      });
    });
  });

  group('outbox', () {
    late OutboxStore o;
    setUp(() => o = OutboxStore(db));
    final content = Uint8List.fromList([1, 2, 3]);

    test('due rows respect retry time; attempts are counted', () {
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      expect(o.due(1000), hasLength(1));
      o.recordAttempt(o.due(1000).single.id, nextAttemptAt: 5000);
      expect(o.due(2000), isEmpty);
      expect(o.due(5000).single.attempts, 1);
    });

    test('enqueue is idempotent per (message, recipient)', () {
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      expect(o.pendingCount(), 1);
    });

    test('acknowledge ends retries and drives status to delivered', () {
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      expect(o.statusOf(id(1)), MsgStatus.queued);
      o.recordAttempt(o.due(1000).single.id, nextAttemptAt: 9000);
      expect(o.statusOf(id(1)), MsgStatus.sent);
      expect(o.acknowledge(id(1), id(9)), isTrue);
      expect(o.statusOf(id(1)), MsgStatus.delivered);
      expect(o.due(99999), isEmpty);
      expect(o.acknowledge(id(1), id(9)), isFalse); // second ack: no-op
    });

    test('group message is delivered only when EVERY recipient acked', () {
      for (final d in [9, 10, 11]) {
        o.enqueue(msgId: id(1), dest: id(d), content: content, nowMs: 1000);
      }
      o.acknowledge(id(1), id(9));
      o.acknowledge(id(1), id(10));
      expect(o.statusOf(id(1)), MsgStatus.sent);
      o.acknowledge(id(1), id(11));
      expect(o.statusOf(id(1)), MsgStatus.delivered);
    });

    test('expiry marks unacked messages failed, keeps acked ones', () {
      o.enqueue(
          msgId: id(1),
          dest: id(9),
          content: content,
          nowMs: 1000,
          ttl: const Duration(milliseconds: 500));
      expect(o.expire(2000), [id(1)]);
      expect(o.statusOf(id(1)), MsgStatus.failed);
      expect(o.due(2000), isEmpty);
    });

    test('releaseFor makes a deferred row due when the peer reappears', () {
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      o.defer(o.due(1000).single.id, 60000);
      expect(o.due(2000), isEmpty);
      o.releaseFor(id(9), 2000);
      expect(o.due(2000), hasLength(1));
    });

    test('relayed: receipt marks pending rows only; ack still wins', () {
      o.enqueue(msgId: id(1), dest: id(9), content: content, nowMs: 1000);
      o.recordAttempt(o.due(1000).single.id, nextAttemptAt: 9000);
      expect(o.statusOf(id(1)), MsgStatus.sent);
      expect(o.markRelayed(id(1), id(9)), isTrue);
      expect(o.markRelayed(id(1), id(9)), isFalse); // idempotent
      expect(o.markRelayed(id(1), id(77)), isFalse); // unknown destination
      expect(o.statusOf(id(1)), MsgStatus.relayed);
      o.acknowledge(id(1), id(9));
      expect(o.statusOf(id(1)), MsgStatus.delivered);
      expect(o.markRelayed(id(1), id(9)), isFalse); // too late
    });

    test('group message: any relayed recipient shows relayed until all ack',
        () {
      for (final d in [9, 10]) {
        o.enqueue(msgId: id(1), dest: id(d), content: content, nowMs: 1000);
      }
      o.markRelayed(id(1), id(9));
      expect(o.statusOf(id(1)), MsgStatus.relayed);
      o.acknowledge(id(1), id(9));
      expect(o.statusOf(id(1)), MsgStatus.sent); // the other one is pending
      o.acknowledge(id(1), id(10));
      expect(o.statusOf(id(1)), MsgStatus.delivered);
    });

    test('control rows are deleted on ack and not part of chat status', () {
      o.enqueue(
          msgId: id(2),
          dest: id(9),
          content: content,
          tracked: false,
          nowMs: 1);
      expect(o.statusOf(id(2)), isNull);
      o.acknowledge(id(2), id(9));
      expect(o.pendingCount(), 0);
    });
  });

  group('rooms store', () {
    test('events persist; state is rebuilt identically after reload', () async {
      final me =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final author = await RoomAuthor.createRoom(me,
          name: 'Hikers', icon: '⛰', color: 0xFF2E7D32, isPublic: true);
      await author.addChannel('trails', description: 'routes');
      final store = RoomStore(db);
      store.saveEvents(author.log.events);
      store.materialize(author.log.state, me.peerId, 5000);

      final reloaded = RoomLog(author.log.roomId);
      for (final e in store.loadEvents(author.log.roomId)) {
        await reloaded.add(e);
      }
      expect(reloaded.state.name, 'Hikers');
      expect(reloaded.state.channels.length, 2);
      expect(reloaded.length, author.log.length);

      final r = store.room(author.log.roomId)!;
      expect([r.name, r.icon, r.color, r.isPublic, r.active],
          ['Hikers', '⛰', 0xFF2E7D32, true, true]);
      expect(store.channels(r.roomId).map((c) => c.name),
          containsAll(['general', 'trails']));
      expect(store.members(r.roomId).single.role, Role.owner);
    });

    test('mute flags survive re-materialisation; removed channels vanish',
        () async {
      final me =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final author = await RoomAuthor.createRoom(me, name: 'R');
      final extra = await author.addChannel('extra');
      final store = RoomStore(db);
      store.saveEvents(author.log.events);
      store.materialize(author.log.state, me.peerId, 1);
      final cid =
          Uint8List.fromList((extra.data[K.channelId] as List).cast<int>());
      store.setRoomMuted(author.log.roomId, true);
      store.setChannelMuted(author.log.roomId, cid, true);

      await author.update(name: 'Renamed');
      store.materialize(author.log.state, me.peerId, 2);
      expect(store.room(author.log.roomId)!.muted, isTrue);
      expect(store.isChannelMuted(cid), isTrue);

      await author.deleteChannel(cid);
      store.materialize(author.log.state, me.peerId, 3);
      expect(store.channels(author.log.roomId).length, 1);
    });

    test('losing membership marks the room inactive but keeps it', () async {
      final owner =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final guest =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final author = await RoomAuthor.createRoom(owner, name: 'R');
      await author.addMember(guest.public);
      final store = RoomStore(db);
      store.materialize(author.log.state, guest.peerId, 1);
      expect(store.room(author.log.roomId)!.active, isTrue);
      await author.removeMember(guest.peerId);
      store.materialize(author.log.state, guest.peerId, 2);
      expect(store.room(author.log.roomId)!.active, isFalse);
    });

    test('search finds rooms and channels by name/description, literally',
        () async {
      final me =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final a = await RoomAuthor.createRoom(me, name: 'Photography club');
      await a.addChannel('Landscape', description: 'wide shots');
      final store = RoomStore(db);
      store.saveEvents(a.log.events);
      store.materialize(a.log.state, me.peerId, 1);
      expect(store.search('photo').single.$1.name, 'Photography club');
      final hit = store.search('landsc').single;
      expect(hit.$2!.name, 'Landscape');
      expect(store.search('%'), isEmpty);
    });
  });

  group('replay cache + invites', () {
    test('persisted replay entries are restored; expired ones dropped', () {
      final s = SeenStore(db);
      s.save('a', 5000);
      s.save('b', 100);
      expect(s.load(1000), {'a': 5000});
      s.prune(6000);
      expect(s.load(0), isEmpty);
    });

    test('a replay guard restored after restart rejects the old packet',
        () async {
      final a = await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final b = await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final now = DateTime.now().millisecondsSinceEpoch;
      final seen = SeenStore(db);
      final dirB = InMemoryPeerDirectory();
      var guard = ReplayGuard(onAdmit: seen.save);
      var sb = SessionService(identity: b, directory: dirB, replayGuard: guard);
      final sa =
          SessionService(identity: a, directory: InMemoryPeerDirectory());
      final pkt = await sa.sealDirect(
          recipient: b.public,
          content: const MessageContent.text('x'),
          includeKeys: true);
      await sb.openDirect(pkt);
      // restart: brand new guard + session, state reloaded from SQLite
      guard = ReplayGuard(onAdmit: seen.save)
        ..restore(seen.load(now), nowMs: now);
      sb = SessionService(identity: b, directory: dirB, replayGuard: guard);
      await expectLater(sb.openDirect(pkt), throwsA(isA<ReplayException>()));
    });

    test('an invite nonce can be consumed once', () {
      final inv = InviteStore(db);
      expect(inv.consume(id(1), 1), isTrue);
      expect(inv.consume(id(1), 2), isFalse);
      expect(inv.consume(id(2), 2), isTrue);
    });
  });

  group('persistence across restarts (file database)', () {
    test('messages and queue survive closing and reopening the file', () {
      final dir = Directory.systemTemp.createTempSync('mesh_db_');
      final path = '${dir.path}/mesh.db';
      try {
        var d = MeshDatabase.openFile(path);
        MessageStore(d).insert(msg(1, text: 'persist me'));
        OutboxStore(d).enqueue(
            msgId: id(1),
            dest: id(9),
            content: Uint8List.fromList([7]),
            nowMs: 1000);
        d.close();

        d = MeshDatabase.openFile(path);
        expect(MessageStore(d).search('persist'), hasLength(1));
        expect(OutboxStore(d).pendingCount(), 1);
        expect(OutboxStore(d).due(1000).single.content, [7]);
        d.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

/// Inserts a v1-shaped row directly (as an older app version would have).
class MessageStoreRaw {
  static void insertLegacy(Database raw, String text, {int n = 1}) {
    raw.execute(
      'INSERT INTO messages(msg_id, sender, conv_kind, conv_id, text, ts, outgoing) '
      'VALUES (?,?,?,?,?,?,?)',
      [id(n), id(100), 1, id(100), text, 1000 + n, 0],
    );
  }
}
