import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Actor alice;
  late Actor bob;
  late Actor relay;

  setUp(() async {
    alice = await makeActor();
    bob = await makeActor();
    relay = await makeActor();
    alice.directory.remember(bob.pub);
  });

  Future<MeshPacket> send(String text, {Actor? to}) => alice.session.sealDirect(
        recipient: (to ?? bob).pub,
        content: MessageContent(text: text),
        includeKeys: true,
      );

  group('end-to-end encryption', () {
    test('recipient decrypts and authenticates the sender', () async {
      final p = await send('Привет, mesh! 🔐');
      final opened = await bob.session.openDirect(p);
      expect(opened.content.text, 'Привет, mesh! 🔐');
      expect(opened.sender, alice.pub);
      expect(opened.messageId, p.messageId);
    });

    test('reply reference survives the round trip', () async {
      final target = randomBytes(16);
      final p = await alice.session.sealDirect(
        recipient: bob.pub,
        content: MessageContent(text: 're', replyTo: target),
        includeKeys: true,
      );
      final opened = await bob.session.openDirect(p);
      expect(opened.content.replyTo, target);
    });

    test('plaintext never appears in the packet', () async {
      const secret = 'TOP-SECRET-PLAINTEXT-123';
      final p = await send(secret);
      final wire = const PacketCodec().encode(p);
      expect(_contains(wire, utf8.encode(secret)), isFalse);
      expect(_contains(p.payload, utf8.encode(secret)), isFalse);
    });

    test('same text twice yields different ciphertexts (fresh keys/nonces)',
        () async {
      final a = await send('same');
      final b = await send('same');
      expect(a.payload, isNot(b.payload));
      expect(a.messageId, isNot(b.messageId));
    });
  });

  group('relay / third party cannot read', () {
    test('relay holding the exact bytes cannot open the message', () async {
      const secret = 'meet at 5pm';
      final onWire = const PacketCodec().encode(await send(secret));
      // The relay decodes + even verifies the packet (it must, to forward).
      final seenByRelay = const PacketCodec().decode(onWire);
      expect(
          await PacketVerifier(relay.directory).verify(seenByRelay), alice.pub);
      // …but cannot decrypt: it is not the addressee.
      await expectLater(relay.session.openDirect(seenByRelay),
          throwsA(isA<NotForUsException>()));
      expect(_contains(onWire, utf8.encode(secret)), isFalse);
    });

    test('relay re-addressing the packet to itself breaks the signature',
        () async {
      final p = await send('private');
      final hijacked = MeshPacket(
        type: p.type,
        messageId: p.messageId,
        senderId: p.senderId,
        destinationId: relay.pub.peerId, // <- changed
        timestampMs: p.timestampMs,
        ttl: p.ttl,
        payload: p.payload,
        signature: p.signature,
        senderKeys: p.senderKeys,
      );
      await expectLater(relay.session.openDirect(hijacked),
          throwsA(isA<SignatureException>()));
    });

    test('even with the recipient-side derivation, wrong key cannot decrypt',
        () async {
      final p = await send('private');
      final sealed = SealedPayload.decode(p.payload);
      final wrongKey = await KeyExchangeService().deriveForReceiving(
        me: relay.identity,
        ephemeralPublicKey: sealed.ephemeralPublicKey,
        senderId: p.senderId,
      );
      await expectLater(
        EncryptionService()
            .decrypt(blob: sealed.blob, key: wrongKey, aad: p.aadBytes()),
        throwsA(isA<DecryptionException>()),
      );
    });
  });

  group('integrity', () {
    test('modified ciphertext is rejected (signature)', () async {
      final p = await send('x');
      final bad = Uint8List.fromList(p.payload)..[p.payload.length - 1] ^= 1;
      final tampered = MeshPacket(
        type: p.type,
        messageId: p.messageId,
        senderId: p.senderId,
        destinationId: p.destinationId,
        timestampMs: p.timestampMs,
        ttl: p.ttl,
        payload: bad,
        signature: p.signature,
        senderKeys: p.senderKeys,
      );
      await expectLater(
          bob.session.openDirect(tampered), throwsA(isA<SignatureException>()));
    });

    test('AEAD alone also rejects a ciphertext moved to another header',
        () async {
      final p = await send('x');
      final sealed = SealedPayload.decode(p.payload);
      final key = await KeyExchangeService().deriveForReceiving(
        me: bob.identity,
        ephemeralPublicKey: sealed.ephemeralPublicKey,
        senderId: p.senderId,
      );
      final otherAad = Uint8List.fromList(p.aadBytes())..[3] ^= 1;
      await expectLater(
        EncryptionService().decrypt(blob: sealed.blob, key: key, aad: otherAad),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('truncated sealed payload is rejected', () async {
      expect(() => SealedPayload.decode(Uint8List(10)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('oversized message is refused before sending', () async {
      await expectLater(
        alice.session.sealDirect(
          recipient: bob.pub,
          content: MessageContent(text: 'x' * (kMaxPayloadBytes + 100)),
        ),
        throwsA(isA<InvalidPacketException>()),
      );
    });

    test('a degenerate (all-zero) X25519 point is refused', () async {
      await expectLater(
        KeyExchangeService().deriveForReceiving(
          me: bob.identity,
          ephemeralPublicKey: Uint8List(32), // low-order point
          senderId: alice.pub.peerId,
        ),
        throwsA(isA<InvalidPacketException>()),
      );
    });
  });

  group('replay at the session level', () {
    test('delivering the same packet twice yields one message', () async {
      final p = await send('once');
      await bob.session.openDirect(p);
      await expectLater(
          bob.session.openDirect(p), throwsA(isA<ReplayException>()));
    });

    test('a message older than the window is refused', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = await makeActor(clock: () => now);
      final recv = await makeActor(
          clock: () => now + const Duration(hours: 25).inMilliseconds);
      final p = await old.session.sealDirect(
        recipient: recv.pub,
        content: const MessageContent(text: 'stale'),
        includeKeys: true,
      );
      await expectLater(
          recv.session.openDirect(p), throwsA(isA<ReplayException>()));
    });
  });

  group('announce / ack', () {
    test('announce is accepted and teaches the receiver the sender keys',
        () async {
      final a = await alice.session.createAnnounce(displayName: '  Alice\n');
      final res = await bob.session.acceptAnnounce(a);
      expect(res.identity, alice.pub);
      expect(res.displayName, 'Alice'); // sanitized
      expect(bob.directory.lookup(alice.pub.peerId), alice.pub);
    });

    test('display name is sanitized and capped', () async {
      final a = await alice.session
          .createAnnounce(displayName: 'A\u0000\u0007${'z' * 100}');
      final res = await bob.session.acceptAnnounce(a);
      expect(res.displayName!.length, SessionService.maxDisplayNameLength);
      expect(res.displayName, isNot(contains('\u0000')));
    });

    test('announce without keys is rejected', () async {
      final a = await alice.session.createAnnounce();
      final stripped = MeshPacket(
        type: a.type,
        messageId: a.messageId,
        senderId: a.senderId,
        timestampMs: a.timestampMs,
        ttl: a.ttl,
        payload: a.payload,
        signature: a.signature,
      );
      await expectLater(bob.session.acceptAnnounce(stripped),
          throwsA(isA<InvalidPacketException>()));
    });

    test('ack proves delivery only when signed by the real recipient',
        () async {
      final p = await send('hi');
      final opened = await bob.session.openDirect(p);
      final ack = await bob.session.createAck(opened);
      alice.directory.remember(bob.pub);
      expect(await alice.session.acceptAck(ack), p.messageId);
    });

    test('forged ack from a third party for someone else is rejected',
        () async {
      final p = await send('hi');
      final opened = await bob.session.openDirect(p);
      final ack = await bob.session.createAck(opened);
      // The relay cannot make an ack for Alice appear to come from Bob.
      final forged = MeshPacket(
        type: ack.type,
        messageId: ack.messageId,
        senderId: ack.senderId,
        destinationId: ack.destinationId,
        timestampMs: ack.timestampMs,
        ttl: ack.ttl,
        payload: randomBytes(16), // different acked id
        signature: ack.signature,
      );
      alice.directory.remember(bob.pub);
      await expectLater(
          alice.session.acceptAck(forged), throwsA(isA<SignatureException>()));
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
