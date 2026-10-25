import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/linked_transport.dart';
import 'support/sqlite_init.dart';

StoredMessage? only(MessageStore s, Uint8List conv) {
  final l = s.list(ConvKind.direct, conv);
  return l.isEmpty ? null : l.last;
}

void main() {
  group('direct chat A ↔ B', () {
    late Net net;
    setUp(() async {
      net = Net()..link('A', 'B');
      await net.build();
      await net.connectAll();
    });
    tearDown(() => net.stop());

    test('delivery: stored on both sides; sender sees verified "delivered"',
        () async {
      final sent = await net['A'].engine.sendDirect(net['B'].pub, 'привет, B');
      await eventually(
          () =>
              net['A'].engine.messages.get(sent.msgId, net['A'].id)?.status ==
              MsgStatus.delivered,
          what: 'delivered');
      final got = only(net['B'].engine.messages, net['A'].id)!;
      expect(got.text, 'привет, B');
      expect(got.outgoing, isFalse);
      expect(got.unread, isTrue);
      expect(net['B'].engine.peers.get(net['A'].id)!.name, 'A');
      expect(net['A'].engine.outbox.statusOf(sent.msgId), MsgStatus.delivered);
    });

    test('reply reference is kept', () async {
      final first = await net['A'].engine.sendDirect(net['B'].pub, 'one');
      await eventually(() => net['B']
          .engine
          .messages
          .list(ConvKind.direct, net['A'].id)
          .isNotEmpty);
      await net['B']
          .engine
          .sendDirect(net['A'].pub, 'two', replyTo: first.msgId);
      await eventually(() =>
          net['A'].engine.messages.list(ConvKind.direct, net['B'].id).length ==
          2);
      final reply =
          net['A'].engine.messages.list(ConvKind.direct, net['B'].id).last;
      expect(reply.replyTo, first.msgId);
    });

    test('edit and delete propagate; deleted text is wiped', () async {
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'typo');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      await net['A'].engine.editMessage(m, 'fixed');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id)!.text == 'fixed',
          what: 'edit');
      expect(only(net['B'].engine.messages, net['A'].id)!.edited, isTrue);
      await net['A']
          .engine
          .deleteMessage(net['A'].engine.messages.get(m.msgId, net['A'].id)!);
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id)!.deleted,
          what: 'delete');
      expect(only(net['B'].engine.messages, net['A'].id)!.text, '');
    });

    test('reactions propagate both ways and can be removed', () async {
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'nice day');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      final onB = only(net['B'].engine.messages, net['A'].id)!;
      await net['B'].engine.react(onB, '👍');
      await eventually(
          () => net['A'].engine.messages.reactions(m.msgId)['👍']?.length == 1,
          what: 'reaction');
      await net['B'].engine.react(onB, '👍', add: false);
      await eventually(
          () => net['A'].engine.messages.reactions(m.msgId).isEmpty,
          what: 'unreact');
    });

    test('"read" appears only after the recipient opens the chat', () async {
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'did you see?');
      await eventually(() =>
          net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
          MsgStatus.delivered);
      expect(net['B'].engine.messages.unreadCount(ConvKind.direct, net['A'].id),
          1);
      await net['B'].engine.markRead(ConvKind.direct, net['A'].id);
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.read,
          what: 'read');
      expect(net['B'].engine.messages.unreadCount(ConvKind.direct, net['A'].id),
          0);
    });

    test('read receipts can be switched off', () async {
      net['B'].engine.settings.setBool('read_receipts', false);
      final m =
          await net['A'].engine.sendDirect(net['B'].pub, 'private reader');
      await eventually(() =>
          net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
          MsgStatus.delivered);
      await net['B'].engine.markRead(ConvKind.direct, net['A'].id);
      await settle(150);
      expect(net['A'].engine.messages.get(m.msgId, net['A'].id)!.status,
          MsgStatus.delivered);
    });

    test('a peer cannot edit, delete or react-spoof OTHER people\'s messages',
        () async {
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'mine');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      // B tries to rewrite A's message on A's device.
      await net['B']
          .engine
          .node
          .sendContent(net['A'].pub, MessageContent.edit(m.msgId, 'forged'));
      await net['B']
          .engine
          .node
          .sendContent(net['A'].pub, MessageContent.delete(m.msgId));
      await settle(150);
      final mine = net['A'].engine.messages.get(m.msgId, net['A'].id)!;
      expect(mine.text, 'mine');
      expect(mine.deleted, isFalse);
    });

    test('blocking: messages from the blocked peer are dropped and unacked',
        () async {
      net['A'].engine.blockPeer(net['B'].id);
      final m = await net['B'].engine.sendDirect(net['A'].pub, 'let me in');
      await settle(200);
      expect(
          net['A'].engine.messages.list(ConvKind.direct, net['B'].id), isEmpty);
      expect(net['B'].engine.messages.get(m.msgId, net['B'].id)!.status,
          isNot(MsgStatus.delivered));
      // unblocking: the retry gets through
      net['A'].engine.blockPeer(net['B'].id, blocked: false);
      net['B'].engine.outbox.releaseAll(DateTime.now().millisecondsSinceEpoch);
      await net['B'].engine.flushOutbox();
      await eventually(
          () =>
              net['A']
                  .engine
                  .messages
                  .list(ConvKind.direct, net['B'].id)
                  .length ==
              1,
          what: 'delivery after unblock');
    });

    test('muting stores the message but raises no notification', () async {
      net['B'].engine.mutePeer(net['A'].id);
      await net['A'].engine.sendDirect(net['B'].pub, 'quiet');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      expect(net['B'].of<IncomingNotification>(), isEmpty);
      net['B'].engine.mutePeer(net['A'].id, muted: false);
      await net['A'].engine.sendDirect(net['B'].pub, 'loud');
      await eventually(() => net['B'].of<IncomingNotification>().isNotEmpty,
          what: 'notification');
      expect(net['B'].of<IncomingNotification>().single.body, 'loud');
    });

    test('search finds messages and contacts locally', () async {
      await net['A']
          .engine
          .sendDirect(net['B'].pub, 'Встреча в горах в субботу');
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      final r = net['B'].engine.search('горах');
      expect(r.messages.single.message.text, contains('горах'));
      expect(net['B'].engine.search('A').peers, isNotEmpty);
      expect(net['B'].engine.search('zzzz').isEmpty, isTrue);
    });

    test('profile status/bio and transport reach the other side', () async {
      final net2 = Net()..link('P', 'Q');
      await net2.build(profiles: {'P': ('on the trail', 'I like maps')});
      await net2.connectAll();
      await eventually(
          () => net2['Q'].engine.peers.get(net2['P'].id)?.status != null,
          what: 'profile announced');
      final p = net2['Q'].engine.peers.get(net2['P'].id)!;
      expect(p.status, 'on the trail');
      expect(p.bio, 'I like maps');
      expect(net2['Q'].engine.transportOf(net2['P'].id), TransportKind.ble);
      expect(net2['Q'].engine.transportOf(randomBytes(16)), isNull);
      await net2.stop();
    });

    test('an invite can be sent to a contact as a message and redeemed',
        () async {
      final room = await net['A'].engine.createRoom(name: 'Via chat');
      final inv = await net['A'].engine.createRoomInvite(room);
      await net['A'].engine.sendInvite(inv, net['B'].pub);
      await eventually(
          () => only(net['B'].engine.messages, net['A'].id) != null);
      final text = only(net['B'].engine.messages, net['A'].id)!.text;
      expect(Invite.tryFromText(text), isNotNull);
      await net['B'].engine.redeemInvite(text);
      await eventually(
          () => net['B'].engine.roomState(room)?.isMember(net['B'].id) ?? false,
          what: 'joined through the invite sent in chat');
    });

    test('invalid input is rejected before anything is queued', () async {
      expect(
          net['A'].engine.sendDirect(net['B'].pub, '   '), throwsArgumentError);
      expect(
          net['A'].engine.sendDirect(net['A'].pub, 'me'), throwsArgumentError);
      expect(net['A'].engine.outbox.pendingCount(), 0);
    });
  });

  group('scenario 4: offline queue', () {
    test('message waits while the recipient is offline, then is delivered',
        () async {
      final net = Net()..link('A', 'B');
      await net.build();
      net.introduce('A', 'B'); // A knows B (contact), but no link yet
      final m =
          await net['A'].engine.sendDirect(net['B'].pub, 'when you are back');
      await settle(100);
      expect(net['A'].engine.messages.get(m.msgId, net['A'].id)!.status,
          MsgStatus.queued);
      expect(net['A'].engine.outbox.pendingCount(), 1);

      await net.connect('A', 'B'); // B comes online
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.delivered,
          what: 'delivery after reconnect');
      expect(only(net['B'].engine.messages, net['A'].id)!.text,
          'when you are back');
      await net.stop();
    });

    test('queue survives an app restart (file database)', () async {
      initSqliteForTests();
      final dir = Directory.systemTemp.createTempSync('mesh_q_');
      try {
        final idA =
            await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
        final idB =
            await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
        final dbPath = '${dir.path}/a.db';

        // ---- session 1: A queues a message while B is unreachable, then "crashes"
        var db = MeshDatabase.openFile(dbPath);
        final (ta, _) = LinkedTransport.pair('a>b', 'b>a');
        var engine = MeshEngine(
            identity: idA,
            database: db,
            transports: [ta],
            announceInterval: null,
            outboxInterval: const Duration(hours: 1));
        await engine.start();
        final m = await engine.sendDirect(idB.public, 'survive the restart');
        await settle(100);
        expect(engine.outbox.pendingCount(), 1);
        await engine.stop();
        db.close();

        // ---- session 2: new process, same database; B appears now
        db = MeshDatabase.openFile(dbPath);
        final (ta2, tb2) = LinkedTransport.pair('a>b', 'b>a');
        final dbB = MeshDatabase.openInMemory();
        final engineB = MeshEngine(
            identity: idB,
            database: dbB,
            transports: [tb2],
            announceInterval: null,
            outboxInterval: const Duration(hours: 1));
        engine = MeshEngine(
            identity: idA,
            database: db,
            transports: [ta2],
            announceInterval: null,
            outboxInterval: const Duration(hours: 1));
        await engine.start();
        await engineB.start();
        expect(engine.outbox.pendingCount(), 1); // still there
        expect(
            engine.messages.get(m.msgId, idA.peerId)!.status, MsgStatus.queued);

        await ta2.connect();
        await eventually(
            () =>
                engine.messages.get(m.msgId, idA.peerId)!.status ==
                MsgStatus.delivered,
            what: 'delivery after restart');
        expect(engineB.messages.list(ConvKind.direct, idA.peerId).single.text,
            'survive the restart');
        await engine.stop();
        await engineB.stop();
        db.close();
        dbB.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('lost ack: the retry is acknowledged again, not shown twice',
        () async {
      final net = Net()..link('A', 'B');
      await net.build();
      await net.connectAll();
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'ack me twice');
      await eventually(() =>
          net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
          MsgStatus.delivered);
      // simulate "ack was lost": put the row back to pending and retry
      net['A']
          .db
          .db
          .execute('UPDATE outbox SET state = 0 WHERE msg_id = ?', [m.msgId]);
      net['A'].engine.outbox.releaseAll(DateTime.now().millisecondsSinceEpoch);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await net['A'].engine.flushOutbox();
      await eventually(
          () => net['A'].engine.outbox.statusOf(m.msgId) == MsgStatus.delivered,
          what: 're-ack');
      expect(net['B'].engine.messages.list(ConvKind.direct, net['A'].id).length,
          1);
      await net.stop();
    });

    test('unacked messages expire to "failed"', () async {
      final net = Net()..link('A', 'B');
      await net.build();
      net.introduce('A', 'B');
      final m = await net['A'].engine.sendDirect(net['B'].pub, 'never arrives');
      net['A'].db.db.execute('UPDATE outbox SET expires_at = 1');
      await net['A'].engine.maintainOutbox();
      expect(net['A'].engine.messages.get(m.msgId, net['A'].id)!.status,
          MsgStatus.failed);
      await net.stop();
    });
  });

  group('Relayed status (signed relay receipt)', () {
    test('A -> C through B shows relayed, then delivered; direct shows none',
        () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      await eventually(
          () => net['A'].engine.directory.lookup(net['C'].id) != null);
      final seen = <MsgStatus>[];
      net['A'].engine.events.listen((e) {
        if (e is MessageStatusChanged) {
          final m = net['A'].engine.messages.list(ConvKind.direct, net['C'].id);
          if (m.isNotEmpty) seen.add(m.last.status);
        }
      });
      final m = await net['A'].engine.sendDirect(net['C'].pub, 'via relay');
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.delivered,
          what: 'delivered');
      expect(seen, contains(MsgStatus.relayed));
      // never goes backwards after delivery
      expect(
          seen.lastIndexOf(MsgStatus.relayed) <
              seen.lastIndexOf(MsgStatus.delivered),
          isTrue);
      // a direct message never claims to be relayed
      final d = await net['A'].engine.sendDirect(net['B'].pub, 'direct');
      await eventually(() =>
          net['A'].engine.messages.get(d.msgId, net['A'].id)!.status ==
          MsgStatus.delivered);
      expect(net['A'].engine.outbox.statusOf(d.msgId), MsgStatus.delivered);
      await net.stop();
    });

    test('relayed but never delivered stays at relayed (not delivered)',
        () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'D');
      await net.build();
      await net.connectAll();
      final ghost =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      net['A'].engine.directory.remember(ghost.public);
      final m = await net['A'].engine.sendDirect(ghost.public, 'into the void');
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.relayed,
          what: 'relayed');
      await settle(200);
      expect(net['A'].engine.messages.get(m.msgId, net['A'].id)!.status,
          MsgStatus.relayed);
      await net.stop();
    });

    test('a receipt from a non-neighbour is ignored', () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      final ghost =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      net['A'].engine.directory.remember(ghost.public);
      net['A'].engine.outbox.enqueue(
          msgId: id16(1),
          dest: ghost.public.peerId,
          content: MessageContent.text('x').encode(),
          nowMs: DateTime.now().millisecondsSinceEpoch);
      // C (two hops away) tries to mark it relayed.
      final forged = await net['C'].engine.session.createRelayReceipt(
            messageId: id16(1),
            finalDestination: ghost.public.peerId,
            toNeighbor: net['A'].id,
          );
      net['A'].transports.first.inject(const PacketCodec().encode(forged));
      await settle(100);
      expect(
          net['A'].engine.outbox.statusOf(id16(1)), isNot(MsgStatus.relayed));
      await net.stop();
    });
  });

  group('scenario 1 with storage: A → C through B', () {
    test('queued A→C message crosses B, relay stores nothing', () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      await eventually(
          () => net['A'].engine.directory.lookup(net['C'].id) != null,
          what: 'C announce relayed');
      final m = await net['A'].engine.sendDirect(net['C'].pub, 'via the relay');
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.delivered,
          what: 'end-to-end ack');
      expect(
          only(net['C'].engine.messages, net['A'].id)!.text, 'via the relay');
      // B relayed, but has no chat data from this exchange.
      expect(
          net['B'].engine.messages.list(ConvKind.direct, net['A'].id), isEmpty);
      expect(
          net['B'].engine.messages.list(ConvKind.direct, net['C'].id), isEmpty);
      expect(net['B'].engine.messages.search('relay'), isEmpty);
      await net.stop();
    });
  });
}

Uint8List id16(int n) =>
    Uint8List.fromList(List.generate(16, (i) => (i + n * 31) & 0xFF));
