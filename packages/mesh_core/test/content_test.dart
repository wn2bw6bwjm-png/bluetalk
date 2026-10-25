import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/topology.dart';

void main() {
  final id = Uint8List.fromList(List.generate(16, (i) => i));

  group('MessageContent kinds', () {
    MessageContent rt(MessageContent c) => MessageContent.decode(c.encode());

    test('text with reply and channel', () {
      final c = rt(MessageContent.text('hi', replyTo: id, channelId: id));
      expect(c.kind, MessageContent.kindText);
      expect(c.text, 'hi');
      expect(c.replyTo, id);
      expect(c.channelId, id);
    });

    test('reaction add/remove, edit, delete, read', () {
      final r = rt(MessageContent.reaction(id, '👍'));
      expect(r.kind, MessageContent.kindReaction);
      expect(r.text, '👍');
      expect(r.add, isTrue);
      expect(r.targetId, id);
      expect(rt(MessageContent.reaction(id, '👍', add: false)).add, isFalse);
      final e = rt(MessageContent.edit(id, 'fixed'));
      expect((e.kind, e.text), (MessageContent.kindEdit, 'fixed'));
      expect(rt(MessageContent.delete(id)).kind, MessageContent.kindDelete);
      expect(rt(MessageContent.read([id, id])).blobs.length, 2);
    });

    test('control messages carry blobs', () {
      final c = rt(MessageContent.control(MessageContent.kindRoomEvents,
          blobs: [Uint8List(5), Uint8List(7)]));
      expect(c.blobs.map((b) => b.length), [5, 7]);
    });

    test('malformed content is rejected', () {
      expect(() => MessageContent.decode(Uint8List.fromList([0xff])),
          throwsA(isA<DecryptionException>()));
      // reaction without target
      final bad =
          const MessageContent(kind: MessageContent.kindReaction, text: 'x')
              .encode();
      expect(() => MessageContent.decode(bad),
          throwsA(isA<DecryptionException>()));
      // unknown kind
      final unk = const MessageContent(kind: 99).encode();
      expect(() => MessageContent.decode(unk),
          throwsA(isA<DecryptionException>()));
    });
  });

  group('session extensions', () {
    test('same messageId can be re-sealed with a fresh timestamp', () async {
      final a = await makeActor();
      final b = await makeActor();
      final mid = randomBytes(16);
      final p1 = await a.session.sealDirect(
          recipient: b.pub,
          content: const MessageContent.text('x'),
          messageId: mid);
      final p2 = await a.session.sealDirect(
          recipient: b.pub,
          content: const MessageContent.text('x'),
          messageId: mid);
      expect(p1.messageId, mid);
      expect(p2.messageId, mid);
      expect(p1.payload, isNot(p2.payload)); // fresh ephemeral key
    });

    test('roomId is part of the signed header', () async {
      final a = await makeActor();
      final b = await makeActor();
      final room = randomBytes(16);
      final p = await a.session.sealDirect(
          recipient: b.pub,
          content: const MessageContent.text('x'),
          roomId: room,
          includeKeys: true);
      expect(p.roomId, room);
      final stripped = MeshPacket(
        type: p.type,
        messageId: p.messageId,
        senderId: p.senderId,
        destinationId: p.destinationId,
        roomId: randomBytes(16), // moved to another room
        timestampMs: p.timestampMs,
        ttl: p.ttl,
        payload: p.payload,
        signature: p.signature,
        senderKeys: p.senderKeys,
      );
      await expectLater(
          b.session.openDirect(stripped), throwsA(isA<SignatureException>()));
    });
  });

  group('announce profile', () {
    test('status and bio travel in the signed announce and are sanitised',
        () async {
      final a = await makeActor();
      final b = await makeActor();
      final pkt = await a.session.createAnnounce(
        displayName: 'A',
        status: 'on the \u0000trail',
        bio: 'x' * 500,
      );
      final got = await b.session.acceptAnnounce(pkt);
      expect(got.status, 'on the trail');
      expect(got.bio!.length, SessionService.maxBioLength);
      // absent fields stay absent
      final plain = await a.session.createAnnounce(displayName: 'A');
      final p2 = await makeActor();
      final got2 = await p2.session.acceptAnnounce(plain);
      expect(got2.status, isNull);
      expect(got2.bio, isNull);
    });

    test('Invite.tryFromText never throws', () async {
      final a = await makeActor();
      final inv = await Invite.create(
          issuer: a.identity, kind: InviteKind.contact, name: 'A');
      expect(Invite.tryFromText(inv.toText()), isNotNull);
      expect(Invite.tryFromText('hello'), isNull);
      expect(Invite.tryFromText('mesh1:%%%'), isNull);
    });
  });

  group('duplicate delivery re-acks', () {
    test('a retried message is acknowledged again but not delivered twice',
        () async {
      final t = Topology()..link('A', 'B');
      await t.build();
      await t.connectAll();
      final mid = randomBytes(16);
      // First attempt delivered.
      final p1 = await t['A'].actor.session.sealDirect(
          recipient: t['B'].pub,
          content: const MessageContent.text('retry me'),
          includeKeys: true,
          messageId: mid);
      final link = t['A'].transports.first;
      link.peer!.inject(const PacketCodec().encode(p1));
      await settle();
      expect(t['B'].of<MessageReceived>().length, 1);
      final acksBefore = t['B']
          .transports
          .first
          .sent
          .where((b) => const PacketCodec().decode(b).type == PacketType.ack)
          .length;
      // A never saw the ack; retries the SAME message id with a new timestamp.
      final p2 = await t['A'].actor.session.sealDirect(
          recipient: t['B'].pub,
          content: const MessageContent.text('retry me'),
          includeKeys: true,
          messageId: mid);
      link.peer!.inject(const PacketCodec().encode(p2));
      await settle();
      expect(t['B'].of<MessageReceived>().length, 1); // still one message
      final acksAfter = t['B']
          .transports
          .first
          .sent
          .where((b) => const PacketCodec().decode(b).type == PacketType.ack)
          .length;
      expect(acksAfter, acksBefore + 1); // but acked again
      await t.stop();
    });
  });
}
