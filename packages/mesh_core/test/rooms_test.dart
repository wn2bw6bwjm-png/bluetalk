import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Actor owner, admin, alice, bob, mallory;
  late RoomAuthor room; // owned by `owner`

  setUp(() async {
    owner = await makeActor();
    admin = await makeActor();
    alice = await makeActor();
    bob = await makeActor();
    mallory = await makeActor();
    room = await RoomAuthor.createRoom(owner.identity,
        name: 'Hikers',
        description: 'Trail chat',
        icon: '⛰',
        color: 0xFF2E7D32);
  });

  RoomAuthor as_(Actor a) => RoomAuthor(a.identity, room.log);
  RoomState st() => room.log.state;

  group('creation', () {
    test('creator becomes owner; default channel exists', () {
      expect(st().exists, isTrue);
      expect(st().name, 'Hikers');
      expect(st().roleOf(owner.pub.peerId), Role.owner);
      expect(st().channels.values.single.name, 'general');
      expect(st().isPublic, isFalse);
      expect(st().color, 0xFF2E7D32);
    });

    test('roomId commits to the owner: nobody else can create that room',
        () async {
      // Mallory replays the owner's create data under her own key.
      final create =
          room.log.events.firstWhere((e) => e.type == RoomEventType.roomCreate);
      final forged = await RoomEvent.create(
        author: mallory.identity,
        roomId: room.log.roomId,
        type: RoomEventType.roomCreate,
        lamport: 0,
        data: {
          ...create.data,
          K.nonce:
              Uint8List.fromList((create.data[K.nonce] as List).cast<int>()),
        },
      );
      final log = RoomLog(room.log.roomId);
      await log.add(forged);
      expect(log.state.exists, isFalse);
      expect(log.state.rejected.single.reason, contains('commit'));
    });
  });

  group('permissions matrix', () {
    setUp(() async {
      await room.addMember(admin.pub, role: Role.admin);
      await room.addMember(alice.pub);
    });

    test('owner/admin/member roles are as specified', () {
      expect(st().can(owner.pub.peerId, Permission.deleteRoom), isTrue);
      expect(st().can(owner.pub.peerId, Permission.manageRoles), isTrue);
      expect(st().can(admin.pub.peerId, Permission.manageChannels), isTrue);
      expect(st().can(admin.pub.peerId, Permission.manageRoles), isFalse);
      expect(st().can(admin.pub.peerId, Permission.deleteRoom), isFalse);
      expect(st().can(alice.pub.peerId, Permission.sendMessages), isTrue);
      expect(st().can(alice.pub.peerId, Permission.manageRoom), isFalse);
      expect(st().can(mallory.pub.peerId, Permission.sendMessages), isFalse);
    });

    test('admin may edit room, channels and add members', () async {
      final a = as_(admin);
      await a.update(name: 'Hikers+', color: 0xFF000000);
      final ch = await a.addChannel('trails');
      await a.addMember(bob.pub);
      expect(st().name, 'Hikers+');
      expect(st().channels.length, 2);
      expect(st().isMember(bob.pub.peerId), isTrue);
      expect(st().rejected, isEmpty);
      expect(ch.type, RoomEventType.channelCreate);
    });

    test('member cannot change anything', () async {
      final m = as_(alice);
      await m.update(name: 'hacked');
      await m.addChannel('spam');
      await m.addMember(bob.pub);
      await m.setRole(alice.pub.peerId, Role.admin);
      expect(st().name, 'Hikers');
      expect(st().channels.length, 1);
      expect(st().isMember(bob.pub.peerId), isFalse);
      expect(st().roleOf(alice.pub.peerId), Role.member);
      expect(st().rejected.length, 4);
    });

    test('admin cannot promote, remove admins/owner, or delete the room',
        () async {
      final a = as_(admin);
      await a.addMember(bob.pub, role: Role.admin); // needs manageRoles
      await a.removeMember(owner.pub.peerId);
      await a.deleteRoom();
      expect(st().isMember(bob.pub.peerId), isFalse);
      expect(st().isMember(owner.pub.peerId), isTrue);
      expect(st().deleted, isFalse);
      expect(st().rejected.length, 3);
    });

    test('admin can remove a member but not another admin', () async {
      await room.addMember(bob.pub, role: Role.admin);
      final a = as_(admin);
      await a.removeMember(alice.pub.peerId);
      await a.removeMember(bob.pub.peerId);
      expect(st().isMember(alice.pub.peerId), isFalse);
      expect(st().isMember(bob.pub.peerId), isTrue);
    });

    test('owner promotes and demotes; role changes take effect', () async {
      await room.setRole(alice.pub.peerId, Role.admin);
      expect(st().can(alice.pub.peerId, Permission.manageRoom), isTrue);
      await room.setRole(alice.pub.peerId, Role.member);
      expect(st().can(alice.pub.peerId, Permission.manageRoom), isFalse);
    });

    test('owner cannot leave or be demoted', () async {
      await room.leave();
      await room.setRole(owner.pub.peerId, Role.member);
      expect(st().roleOf(owner.pub.peerId), Role.owner);
    });

    test('members may leave', () async {
      await as_(alice).leave();
      expect(st().isMember(alice.pub.peerId), isFalse);
    });

    test('deleting the room freezes it', () async {
      await room.deleteRoom();
      await room.update(name: 'after');
      expect(st().deleted, isTrue);
      expect(st().name, 'Hikers');
      expect(st().canSend(alice.pub.peerId, st().channels.values.first.id),
          isFalse);
    });

    test('message deletion rights: author or deleteMessages permission', () {
      final s = st();
      expect(s.canDeleteMessage(alice.pub.peerId, alice.pub.peerId), isTrue);
      expect(s.canDeleteMessage(alice.pub.peerId, owner.pub.peerId), isFalse);
      expect(s.canDeleteMessage(admin.pub.peerId, alice.pub.peerId), isTrue);
      expect(
          s.canDeleteMessage(mallory.pub.peerId, mallory.pub.peerId), isFalse);
    });
  });

  group('public vs private join', () {
    test('private room: self-join is rejected', () async {
      await as_(mallory).join();
      expect(st().isMember(mallory.pub.peerId), isFalse);
    });

    test('public room: anyone can join as member, never as admin', () async {
      await room.update(isPublic: true);
      await as_(alice).join();
      expect(st().roleOf(alice.pub.peerId), Role.member);
      await as_(mallory).addMember(mallory.pub, role: Role.admin);
      expect(st().isMember(mallory.pub.peerId), isFalse);
    });

    test('a member cannot add keys that do not match the peer id', () async {
      final e = await RoomEvent.create(
        author: owner.identity,
        roomId: room.log.roomId,
        type: RoomEventType.memberAdd,
        lamport: room.log.nextLamport,
        data: {
          K.peerId: alice.pub.peerId,
          K.keys: Uint8List.fromList(
              [...mallory.pub.signPublicKey, ...mallory.pub.agreePublicKey]),
          K.role: Role.member.wire,
        },
      );
      await room.log.add(e);
      expect(st().isMember(alice.pub.peerId), isFalse);
      expect(st().rejected.last.reason, contains('match'));
    });
  });

  group('channels', () {
    test('create, update, delete', () async {
      final c = await room.addChannel('gear', icon: '🎒', color: 0xFF1565C0);
      final id = c.data[K.channelId] as List<int>;
      final cid = Uint8List.fromList(id);
      await room.updateChannel(cid,
          name: 'equipment', description: 'what to bring');
      final ch = st().channels[toHex(cid)]!;
      expect(ch.name, 'equipment');
      expect(ch.icon, '🎒');
      expect(ch.description, 'what to bring');
      await room.deleteChannel(cid);
      expect(st().channels.containsKey(toHex(cid)), isFalse);
    });

    test('duplicate channel id and unknown channel updates are rejected',
        () async {
      final cid = randomBytes(16);
      await room.addChannel('x', channelId: cid);
      await room.addChannel('y', channelId: cid);
      await room.updateChannel(randomBytes(16), name: 'ghost');
      expect(st().channels.length, 2);
      expect(st().rejected.length, 2);
    });
  });

  group('scenario 5: metadata sync / conflict resolution', () {
    test('replay is independent of arrival order (shuffled 50x)', () async {
      await room.addMember(admin.pub, role: Role.admin);
      await room.addMember(alice.pub);
      final a = as_(admin);
      await a.update(name: 'Alpha');
      await as_(owner).update(name: 'Beta');
      await a.addChannel('one');
      await as_(alice).update(name: 'nope'); // invalid
      final all = room.log.events.toList();
      final reference = _fingerprint(st());
      final rnd = Random(42);
      for (var i = 0; i < 50; i++) {
        final shuffled = [...all]..shuffle(rnd);
        final s = RoomState.replay(room.log.roomId, shuffled);
        expect(_fingerprint(s), reference);
      }
    });

    test('three devices exchanging events converge to the same state',
        () async {
      // Device 1 (owner) creates; devices 2 and 3 learn the log.
      await room.addMember(admin.pub, role: Role.admin);
      await room.addMember(alice.pub);
      final d1 = room.log;
      final d2 = RoomLog(d1.roomId);
      final d3 = RoomLog(d1.roomId);
      for (final e in d1.events) {
        await d2.add(e);
        await d3.add(e);
      }
      // Concurrent edits while partitioned:
      final e2 = await RoomAuthor(admin.identity, d2).update(name: 'From D2');
      final e3 = await RoomAuthor(owner.identity, d3).update(name: 'From D3');
      final ch = await RoomAuthor(admin.identity, d2).addChannel('d2-channel');
      // Heal: everyone gets everything, in different orders.
      for (final e in [e3, ch, e2]) {
        await d1.add(e);
      }
      for (final e in [ch, e2, e3]) {
        await d3.add(e);
      }
      for (final e in [e3, e2, ch]) {
        await d2.add(e);
      }
      final f1 = _fingerprint(d1.state);
      expect(_fingerprint(d2.state), f1);
      expect(_fingerprint(d3.state), f1);
      // Concurrent rename: the later event in (lamport, id) order wins.
      final winner = RoomEvent.compare(e2, e3) > 0 ? 'From D2' : 'From D3';
      expect(d1.state.name, winner);
      expect(d1.state.channels.values.map((c) => c.name),
          containsAll(['general', 'd2-channel']));
    });

    test('anti-entropy: missingFrom / wantedFrom move exactly what is lacking',
        () async {
      await room.addMember(alice.pub);
      final other = RoomLog(room.log.roomId);
      final first = room.log.events.take(2).toList();
      for (final e in first) {
        await other.add(e);
      }
      final send = room.log.missingFrom(other.ids);
      expect(send.length, room.log.length - 2);
      expect(room.log.wantedFrom(other.ids), isEmpty);
      expect(other.wantedFrom(room.log.ids).length, room.log.length - 2);
      for (final e in send) {
        await other.add(e);
      }
      expect(_fingerprint(other.state), _fingerprint(room.log.state));
    });

    test('duplicate events are idempotent', () async {
      final e = room.log.events.first;
      expect(await room.log.add(e), isFalse);
    });

    test('backdating cannot bypass permissions', () async {
      await room.addMember(alice.pub); // alice is a plain member
      // Alice forges an admin action with lamport 1 (before she was added).
      final forged = await RoomEvent.create(
        author: alice.identity,
        roomId: room.log.roomId,
        type: RoomEventType.roomUpdate,
        lamport: 1,
        data: {K.name: 'backdated'},
      );
      await room.log.add(forged);
      expect(st().name, 'Hikers');
      expect(
          st().rejected.any((r) =>
              r.reason.contains('manageRoom') ||
              r.reason.contains('not created')),
          isTrue);
    });

    test('an action that sorts after the author was removed is invalid',
        () async {
      await room.addMember(admin.pub, role: Role.admin);
      final removal = await room.removeMember(admin.pub.peerId);
      final late = await RoomEvent.create(
        author: admin.identity,
        roomId: room.log.roomId,
        type: RoomEventType.roomUpdate,
        lamport: removal.lamport + 1,
        data: {K.name: 'ex-admin'},
      );
      await room.log.add(late);
      expect(st().name, 'Hikers');
    });
  });

  group('integrity', () {
    test('tampered event data fails signature verification', () async {
      final e = room.log.events.last;
      final bad = RoomEvent(
        id: e.id,
        roomId: e.roomId,
        authorKeys: e.authorKeys,
        type: e.type,
        lamport: e.lamport,
        timestampMs: e.timestampMs,
        dataBytes: RoomEvent.encodeData(
            {K.channelId: randomBytes(16), K.name: 'evil'}),
        signature: e.signature,
      );
      await expectLater(RoomLog(room.log.roomId).add(bad),
          throwsA(isA<SignatureException>()));
    });

    test('event for another room is refused', () async {
      final other = await RoomAuthor.createRoom(alice.identity, name: 'Other');
      await expectLater(room.log.add(other.log.events.first),
          throwsA(isA<InvalidPacketException>()));
    });

    test('wire round-trip preserves signature validity', () async {
      for (final e in room.log.events) {
        final back = RoomEvent.decode(e.encode());
        await back.verify();
        expect(back.idHex, e.idHex);
      }
    });

    test('garbage and oversized events are rejected on decode', () {
      expect(() => RoomEvent.decode(randomBytes(100)),
          throwsA(isA<InvalidPacketException>()));
      expect(() => RoomEvent.decode(Uint8List(kMaxPayloadBytes + 1)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('log size is bounded', () async {
      final log = RoomLog(room.log.roomId, maxEvents: 30);
      for (final e in room.log.events) {
        await log.add(e);
      }
      final author = RoomAuthor(owner.identity, log);
      await expectLater(() async {
        for (var i = 0; i < 40; i++) {
          await author.update(description: 'n$i');
        }
      }(), throwsA(isA<InvalidPacketException>()));
      expect(log.length, 30);
    });
  });
}

String _fingerprint(RoomState s) => [
      s.name,
      s.description,
      s.icon,
      s.color,
      s.isPublic,
      s.deleted,
      (s.channels.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) =>
              '${e.key}:${e.value.name}:${e.value.description}:${e.value.icon}')
          .join(','),
      (s.members.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '${e.key}:${e.value.role.name}')
          .join(','),
      s.rejected.map((r) => toHex(r.eventId)).toList()..sort(),
    ].join('|');
