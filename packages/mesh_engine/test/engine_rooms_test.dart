import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

RoomState? st(Node n, Uint8List room) => n.engine.roomState(room);

String fp(RoomState s) => [
      s.name,
      s.description,
      s.icon,
      s.color,
      s.isPublic,
      s.deleted,
      (s.channels.values.map((c) => '${c.idHex}:${c.name}').toList()..sort())
          .join(','),
      (s.members.values.map((m) => '${m.peerIdHex}:${m.role.name}').toList()
            ..sort())
          .join(','),
    ].join('|');

bool member(Node n, Uint8List room, Node who) =>
    st(n, room)?.isMember(who.id) ?? false;

void main() {
  group('rooms over the mesh (A owner, B admin, C member)', () {
    late Net net;
    late Uint8List room;

    setUp(() async {
      // A – B – C : A and C never talk directly.
      net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      await eventually(
          () =>
              net['A'].engine.directory.lookup(net['C'].id) != null &&
              net['C'].engine.directory.lookup(net['A'].id) != null,
          what: 'identities learned through announces');
      room = await net['A'].engine.createRoom(
          name: 'Hikers',
          description: 'Trail chat',
          icon: '⛰',
          color: 0xFF2E7D32);
      await net['A'].engine.addMember(room, net['B'].pub, role: Role.admin);
      await eventually(() => member(net['B'], room, net['B']),
          what: 'B joined');
      await net['A'].engine.addMember(room, net['C'].pub); // via relay B
      await eventually(() => member(net['C'], room, net['C']),
          what: 'C joined via relay');
    });
    tearDown(() => net.stop());

    test('creating a room gives every member the same state', () async {
      await eventually(
          () =>
              fp(st(net['A'], room)!) == fp(st(net['B'], room)!) &&
              fp(st(net['A'], room)!) == fp(st(net['C'], room)!),
          what: 'convergence');
      final s = st(net['C'], room)!;
      expect(s.name, 'Hikers');
      expect(s.icon, '⛰');
      expect(s.color, 0xFF2E7D32);
      expect(s.roleOf(net['A'].id), Role.owner);
      expect(s.roleOf(net['B'].id), Role.admin);
      expect(s.roleOf(net['C'].id), Role.member);
      expect(s.channels.values.single.name, 'general');
      // persisted too
      expect(net['C'].engine.roomStore.room(room)!.name, 'Hikers');
      expect(net['C'].engine.roomStore.members(room).length, 3);
    });

    test('scenario 5: rename / channels / roles sync to all devices', () async {
      await net['A']
          .engine
          .updateRoom(room, name: 'Mountain Club', color: 0xFF1565C0);
      final trails = await net['B']
          .engine
          .addChannel(room, 'trails', description: 'routes');
      await net['A'].engine.setRole(room, net['C'].id, Role.admin);
      await eventually(() {
        final f = fp(st(net['A'], room)!);
        return fp(st(net['B'], room)!) == f &&
            fp(st(net['C'], room)!) == f &&
            st(net['C'], room)!.name == 'Mountain Club' &&
            st(net['A'], room)!.channels.containsKey(toHex(trails)) &&
            st(net['A'], room)!.roleOf(net['C'].id) == Role.admin;
      }, what: 'all three converge');
      expect(net['C'].engine.roomStore.channels(room).map((c) => c.name),
          containsAll(['general', 'trails']));
    });

    test('permissions are enforced locally with clear errors', () async {
      // C is a plain member
      await expectLater(net['C'].engine.updateRoom(room, name: 'x'),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(net['C'].engine.addChannel(room, 'spam'),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(net['C'].engine.deleteRoom(room),
          throwsA(isA<PermissionDeniedException>()));
      // B is admin: may edit, may NOT promote or delete the room
      await net['B'].engine.updateRoom(room, name: 'By admin');
      await expectLater(net['B'].engine.setRole(room, net['C'].id, Role.admin),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(net['B'].engine.deleteRoom(room),
          throwsA(isA<PermissionDeniedException>()));
      await eventually(() => st(net['A'], room)!.name == 'By admin');
    });

    test('a forged room event from a non-member is rejected by receivers',
        () async {
      // C builds an owner-level event locally (bypassing the API check)…
      final log = net['C'].engine.roomState(room)!;
      expect(log.can(net['C'].id, Permission.manageRoom), isFalse);
      final evil = await RoomEvent.create(
        author: net['C'].identity,
        roomId: room,
        type: RoomEventType.roomUpdate,
        lamport: 99,
        data: {K.name: 'HACKED'},
      );
      await net['C'].engine.node.sendContent(
            net['A'].pub,
            MessageContent.control(MessageContent.kindRoomEvents,
                blobs: [evil.encode()]),
            roomId: room,
          );
      await settle(200);
      expect(
          st(net['A'], room)!.name, 'Hikers'); // reducer rejects: no permission
      expect(
          st(net['A'], room)!
              .rejected
              .any((r) => r.reason.contains('manageRoom')),
          isTrue);
    });

    test('removing a member: their room becomes inactive, they stop receiving',
        () async {
      await net['A'].engine.removeMember(room, net['C'].id);
      await eventually(
          () => net['C'].engine.roomStore.room(room)!.active == false,
          what: 'C notified of removal');
      await net['A'].engine.updateRoom(room, name: 'After removal');
      await settle(200);
      expect(st(net['C'], room)!.name, isNot('After removal'));
      expect(st(net['B'], room)!.name, 'After removal'); // B still syncs
    });

    test('group messages reach every member; delivery needs all acks',
        () async {
      final ch = st(net['A'], room)!.channels.values.first.id;
      await eventually(() => st(net['C'], room)!.channels.isNotEmpty);
      final m =
          await net['A'].engine.sendRoomMessage(room, ch, 'hello everyone');
      await eventually(
          () =>
              net['A'].engine.messages.get(m.msgId, net['A'].id)!.status ==
              MsgStatus.delivered,
          what: 'both acks');
      for (final n in ['B', 'C']) {
        final l = net[n].engine.messages.list(ConvKind.channel, ch);
        expect(l.single.text, 'hello everyone', reason: n);
        expect(l.single.roomId, room);
        expect(l.single.sender, net['A'].id);
      }
    });

    test(
        'moderation: admin deletes a member\'s message, member cannot delete admin\'s',
        () async {
      final ch = st(net['A'], room)!.channels.values.first.id;
      await eventually(() => st(net['C'], room)!.channels.isNotEmpty);
      final bad =
          await net['C'].engine.sendRoomMessage(room, ch, 'rude message');
      await eventually(
          () => net['B'].engine.messages.list(ConvKind.channel, ch).isNotEmpty);
      // admin B removes it everywhere
      final onB = net['B'].engine.messages.list(ConvKind.channel, ch).single;
      await net['B'].engine.deleteMessage(onB);
      await eventually(
          () =>
              net['A'].engine.messages.get(bad.msgId, net['C'].id)?.deleted ==
                  true &&
              net['C'].engine.messages.get(bad.msgId, net['C'].id)!.deleted,
          what: 'moderated delete');
      // member C cannot delete admin B's message
      final ok = await net['B'].engine.sendRoomMessage(room, ch, 'admin note');
      await eventually(
          () => net['C'].engine.messages.get(ok.msgId, net['B'].id) != null);
      final onC = net['C'].engine.messages.get(ok.msgId, net['B'].id)!;
      await expectLater(net['C'].engine.deleteMessage(onC),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('room messages: reactions and edits stay scoped to the room',
        () async {
      final ch = st(net['A'], room)!.channels.values.first.id;
      await eventually(() => st(net['C'], room)!.channels.isNotEmpty);
      final m = await net['A'].engine.sendRoomMessage(room, ch, 'teh trail');
      await eventually(
          () => net['C'].engine.messages.get(m.msgId, net['A'].id) != null);
      await net['A'].engine.editMessage(
          net['A'].engine.messages.get(m.msgId, net['A'].id)!, 'the trail');
      final onC = net['C'].engine.messages.get(m.msgId, net['A'].id)!;
      await net['C'].engine.react(onC, '🥾');
      await eventually(
          () =>
              net['C'].engine.messages.get(m.msgId, net['A'].id)!.text ==
                  'the trail' &&
              net['A'].engine.messages.reactions(m.msgId)['🥾']?.length == 1,
          what: 'edit+reaction');
    });

    test('non-members cannot post into a room', () async {
      final ch = st(net['A'], room)!.channels.values.first.id;
      await net['A'].engine.removeMember(room, net['C'].id);
      await eventually(
          () => st(net['A'], room)!.isMember(net['C'].id) == false);
      await eventually(
          () => net['C'].engine.roomStore.room(room)!.active == false);
      await expectLater(
          net['C'].engine.sendRoomMessage(room, ch, 'still here?'),
          throwsA(isA<PermissionDeniedException>()));
      // even a hand-crafted packet is ignored by members
      await net['C'].engine.node.sendContent(
            net['A'].pub,
            MessageContent.text('sneaky', channelId: ch),
            roomId: room,
          );
      await settle(200);
      expect(net['A'].engine.messages.list(ConvKind.channel, ch), isEmpty);
    });

    test('room mute / channel mute silence notifications but keep messages',
        () async {
      final ch = st(net['A'], room)!.channels.values.first.id;
      await eventually(() => st(net['C'], room)!.channels.isNotEmpty);
      net['C'].engine.muteChannel(room, ch);
      await net['A'].engine.sendRoomMessage(room, ch, 'psst');
      await eventually(
          () => net['C'].engine.messages.list(ConvKind.channel, ch).isNotEmpty);
      expect(net['C'].of<IncomingNotification>(), isEmpty);
      net['C'].engine.muteChannel(room, ch, muted: false);
      await net['A'].engine.sendRoomMessage(room, ch, 'ping');
      await eventually(() => net['C'].of<IncomingNotification>().isNotEmpty,
          what: 'notification');
    });

    test('deleting the room freezes it on every device', () async {
      await net['A'].engine.deleteRoom(room);
      await eventually(
          () => st(net['C'], room)!.deleted && st(net['B'], room)!.deleted);
      expect(net['C'].engine.roomStore.room(room)!.deleted, isTrue);
    });

    test('search finds rooms and channels by name', () async {
      await net['A']
          .engine
          .addChannel(room, 'Photography', description: 'summit shots');
      final r = net['A'].engine.search('photog');
      expect(r.rooms.any((x) => x.$2?.name == 'Photography'), isTrue);
      expect(net['A'].engine.search('hikers').rooms.first.$1.name, 'Hikers');
    });
  });

  group('scenario 5b: partition and heal (anti-entropy)', () {
    test('concurrent edits on both sides of a split converge after reconnect',
        () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      await eventually(
          () => net['A'].engine.directory.lookup(net['C'].id) != null);
      final room = await net['A'].engine.createRoom(name: 'Split');
      await net['A'].engine.addMember(room, net['B'].pub, role: Role.admin);
      await net['A'].engine.addMember(room, net['C'].pub);
      await eventually(() =>
          member(net['C'], room, net['C']) && member(net['B'], room, net['B']));

      await net.disconnect('B', 'C'); // C is cut off
      await net['A']
          .engine
          .updateRoom(room, name: 'FromA', description: 'owner edit');
      await net['B'].engine.addChannel(room, 'made-by-b');
      await eventually(() =>
          st(net['B'], room)!.name == 'FromA' &&
          st(net['B'], room)!.channels.length == 2);
      expect(st(net['C'], room)!.name, 'Split'); // C missed everything
      expect(st(net['C'], room)!.channels.length, 1);

      await net.connect('B', 'C'); // heal: PeerOnline triggers offer/want
      await eventually(() {
        final f = fp(st(net['A'], room)!);
        return fp(st(net['B'], room)!) == f && fp(st(net['C'], room)!) == f;
      }, what: 'C catches up', timeout: const Duration(seconds: 8));
      expect(st(net['C'], room)!.name, 'FromA');
      expect(st(net['C'], room)!.channels.length, 2);
      await net.stop();
    });

    test('truly concurrent renames resolve identically everywhere', () async {
      final net = Net()
        ..link('A', 'B')
        ..link('B', 'C');
      await net.build();
      await net.connectAll();
      await eventually(
          () => net['A'].engine.directory.lookup(net['C'].id) != null);
      final room = await net['A'].engine.createRoom(name: 'Race');
      await net['A'].engine.addMember(room, net['B'].pub, role: Role.admin);
      await net['A'].engine.addMember(room, net['C'].pub);
      await eventually(() => member(net['C'], room, net['C']));
      // Cut A off from B, then both admins rename concurrently.
      await net.disconnect('A', 'B');
      await net['A'].engine.updateRoom(room, name: 'Owner says');
      await net['B'].engine.updateRoom(room, name: 'Admin says');
      await settle(100);
      await net.connect('A', 'B');
      await eventually(() {
        final f = fp(st(net['A'], room)!);
        return fp(st(net['B'], room)!) == f && fp(st(net['C'], room)!) == f;
      }, what: 'deterministic winner', timeout: const Duration(seconds: 8));
      expect(['Owner says', 'Admin says'], contains(st(net['A'], room)!.name));
      await net.stop();
    });
  });

  group('invites (no server links)', () {
    late Net net;
    late Uint8List room;
    setUp(() async {
      net = Net()
        ..link('A', 'B')
        ..link('A', 'C');
      await net.build();
      room = await net['A'].engine.createRoom(name: 'Private club');
    });
    tearDown(() => net.stop());

    test('room invite: B scans it, connects, and is added automatically',
        () async {
      final invite = await net['A'].engine.createRoomInvite(room);
      expect(invite.toText(), startsWith('mesh1:'));
      await net['B'].engine.redeemInvite(invite.toText()); // offline: queued
      expect(net['B'].engine.outbox.pendingCount(), 1);
      await net.connect('A', 'B');
      await eventually(
          () =>
              member(net['B'], room, net['B']) &&
              member(net['A'], room, net['B']),
          what: 'joined by invite');
      expect(st(net['B'], room)!.name, 'Private club');
      expect(net['B'].engine.roomStore.room(room)!.active, isTrue);
    });

    test('an invite is single-use', () async {
      final invite = await net['A'].engine.createRoomInvite(room);
      await net['B'].engine.redeemInvite(invite.toText());
      await net['C'].engine.redeemInvite(invite.toText());
      await net.connect('A', 'B');
      await eventually(() => member(net['A'], room, net['B']));
      await net.connect('A', 'C');
      await settle(300);
      expect(member(net['A'], room, net['C']), isFalse);
      expect(net['C'].engine.roomState(room), isNull);
    });

    test('expired, forged and foreign invites are refused', () async {
      final expired = await Invite.create(
        issuer: net['A'].identity,
        kind: InviteKind.room,
        name: 'A',
        roomId: room,
        roomName: 'Private club',
        validFor: const Duration(seconds: 1),
        nowMs: 1000,
      );
      await expectLater(net['B'].engine.redeemInvite(expired.toText()),
          throwsA(isA<ReplayException>()));
      final good = await net['A'].engine.createRoomInvite(room);
      final forged = Invite(
        kind: good.kind,
        inviterKeys: good.inviterKeys,
        name: 'A',
        roomId: randomBytes(16), // different room, same signature
        roomName: good.roomName,
        expiresAtMs: good.expiresAtMs,
        nonce: good.nonce,
        signature: good.signature,
      );
      await expectLater(net['B'].engine.redeemInvite(forged.toText()),
          throwsA(isA<SignatureException>()));
      await expectLater(
          net['B'].engine.redeemInvite('https://example.com/join'),
          throwsA(isA<InvalidPacketException>()));
      await expectLater(net['A'].engine.redeemInvite(good.toText()),
          throwsArgumentError); // own invite
    });

    test('members without manageMembers cannot create invites', () async {
      await net['A'].engine.addMember(room, net['B'].pub);
      net.introduce('B', 'A');
      await net.connect('A', 'B');
      await eventually(() => member(net['B'], room, net['B']));
      await expectLater(net['B'].engine.createRoomInvite(room),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('an invite whose issuer lost the right is useless', () async {
      await net['A'].engine.addMember(room, net['B'].pub, role: Role.admin);
      net.introduce('B', 'A');
      await net.connect('A', 'B');
      await eventually(() => member(net['B'], room, net['B']));
      final invite = await net['B'].engine.createRoomInvite(room); // B is admin
      await net['A'].engine.setRole(room, net['B'].id, Role.member); // demoted
      await eventually(
          () => st(net['B'], room)!.roleOf(net['B'].id) == Role.member);
      await net['C'].engine.redeemInvite(invite.toText());
      await net.connect('A', 'C'); // C reaches A, but the invite was B's
      await net.connect('A', 'B');
      await settle(300);
      expect(member(net['A'], room, net['C']), isFalse);
    });

    test('contact invite adds the contact so messages can be sent', () async {
      final card = await net['A'].engine.createContactInvite();
      final who = await net['B'].engine.redeemInvite(card.toText());
      expect(who, net['A'].pub);
      expect(net['B'].engine.peers.get(net['A'].id)!.name, 'A');
      await net.connect('A', 'B');
      final m = await net['B']
          .engine
          .sendDirect(net['A'].pub, 'hello via contact card');
      await eventually(() =>
          net['B'].engine.messages.get(m.msgId, net['B'].id)!.status ==
          MsgStatus.delivered);
    });
  });

  group('public rooms', () {
    test('a nearby peer sees the advertised room and can join it', () async {
      final net = Net()..link('A', 'B');
      await net.build();
      final room = await net['A']
          .engine
          .createRoom(name: 'Open campfire', isPublic: true);
      final priv =
          await net['A'].engine.createRoom(name: 'Secret', isPublic: false);
      await net.connectAll();
      await eventually(() => net['B'].engine.nearbyRooms.isNotEmpty,
          what: 'advert');
      expect(net['B'].engine.nearbyRooms.single.name, 'Open campfire');
      expect(
          net['B'].engine.nearbyRooms.any((r) => r.name == 'Secret'), isFalse);

      await net['B'].engine.joinPublicRoom(net['B'].engine.nearbyRooms.single);
      await eventually(
          () =>
              member(net['B'], room, net['B']) &&
              member(net['A'], room, net['B']),
          what: 'joined public room');
      expect(st(net['B'], room)!.roleOf(net['B'].id), Role.member);
      expect(net['B'].engine.nearbyRooms, isEmpty); // already a member now
      // The private room never leaked to B.
      expect(net['B'].engine.roomState(priv), isNull);
      await net.stop();
    });

    test('joining a private room without an invite is impossible', () async {
      final net = Net()..link('A', 'B');
      await net.build();
      final priv = await net['A'].engine.createRoom(name: 'Secret');
      await net.connectAll();
      // B forges a join request for the private room.
      await net['B'].engine.node.sendContent(
            net['A'].pub,
            const MessageContent.control(MessageContent.kindJoinRequest),
            roomId: priv,
          );
      await settle(300);
      expect(net['B'].engine.roomState(priv), isNull);
      expect(member(net['A'], priv, net['B']), isFalse);
      await net.stop();
    });
  });

  group('groups', () {
    test('createGroup makes a private room with the given members', () async {
      final net = Net()
        ..link('A', 'B')
        ..link('A', 'C');
      await net.build();
      await net.connectAll();
      final g = await net['A']
          .engine
          .createGroup('Family', [net['B'].pub, net['C'].pub]);
      await eventually(
          () => member(net['B'], g, net['C']) && member(net['C'], g, net['B']),
          what: 'group members everywhere');
      final ch = st(net['A'], g)!.channels.values.single.id;
      final m = await net['B'].engine.sendRoomMessage(g, ch, 'dinner at 7?');
      await eventually(
          () =>
              net['A'].engine.messages.list(ConvKind.channel, ch).length == 1 &&
              net['C'].engine.messages.list(ConvKind.channel, ch).length == 1 &&
              net['B'].engine.messages.get(m.msgId, net['B'].id)!.status ==
                  MsgStatus.delivered,
          what: 'group delivery');
      await net.stop();
    });
  });

  group('restart', () {
    test('rooms and members are restored from the database', () async {
      final net = Net()..link('A', 'B');
      await net.build();
      await net.connectAll();
      final room = await net['A'].engine.createRoom(name: 'Persisted');
      await net['A'].engine.addMember(room, net['B'].pub);
      await eventually(() => member(net['B'], room, net['B']));

      // Re-create B's engine on the SAME database ("app restart").
      final b = net['B'];
      await b.engine.stop();
      final reborn = MeshEngine(
          identity: b.identity,
          database: b.db,
          transports: const [],
          announceInterval: null,
          outboxInterval: const Duration(hours: 1));
      expect(reborn.roomState(room)!.name, 'Persisted');
      expect(reborn.roomState(room)!.isMember(b.id), isTrue);
      expect(reborn.roomStore.members(room).length, 2);
      await reborn.stop();
      await net['A'].engine.stop();
      net['A'].db.close();
    });
  });
}
