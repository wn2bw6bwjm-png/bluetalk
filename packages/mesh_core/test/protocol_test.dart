import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  const codec = PacketCodec();
  late Actor alice;
  late Actor bob;
  late MeshPacket sample;

  setUp(() async {
    alice = await makeActor();
    bob = await makeActor();
    alice.directory.remember(bob.pub);
    sample = await alice.session.sealDirect(
      recipient: bob.pub,
      content: const MessageContent(text: 'hello'),
      includeKeys: true,
    );
  });

  group('serialization', () {
    test('round-trips every field', () {
      final back = codec.decode(codec.encode(sample));
      expect(back, sample);
      expect(back.senderKeys, isNotNull);
      expect(back.destinationId, bob.pub.peerId);
    });

    test('round-trips broadcast packet (null destination / room)', () async {
      final a = await alice.session.createAnnounce(displayName: 'Alice');
      final back = codec.decode(codec.encode(a));
      expect(back.destinationId, isNull);
      expect(back.roomId, isNull);
      expect(back, a);
    });

    test('is CBOR: top level is a map with integer keys', () {
      final raw = cbor.decode(codec.encode(sample)).toObject() as Map;
      expect(raw.keys.every((k) => k is int), isTrue);
      expect(raw[0], kProtocolVersion);
    });

    test('forwarded() consumes one hop but keeps the signed content', () {
      final f = sample.forwarded();
      expect(f.ttl, sample.ttl - 1);
      expect(f.hopCount, 1);
      expect(f.signingBytes(), sample.signingBytes());
    });
  });

  group('strict validation', () {
    test('rejects empty and oversized input', () {
      expect(() => codec.decode(Uint8List(0)),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(Uint8List(kMaxPacketBytes + 1)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects random garbage', () {
      for (var i = 0; i < 50; i++) {
        final junk = randomBytes(1 + i * 5);
        expect(() => codec.decode(junk), throwsA(isA<InvalidPacketException>()),
            reason: 'garbage #$i');
      }
    });

    test('rejects trailing bytes', () {
      final bytes = codec.encode(sample);
      final padded = Uint8List.fromList([...bytes, 0]);
      expect(
          () => codec.decode(padded), throwsA(isA<InvalidPacketException>()));
    });

    Map<int, Object?> fields() => {
          0: 1,
          1: 2,
          2: Uint8List(16),
          3: Uint8List(16),
          4: null,
          5: null,
          6: 1000,
          7: 3,
          8: 0,
          9: Uint8List(4),
          10: Uint8List(64),
        };
    Uint8List enc(Map<int, Object?> m) =>
        Uint8List.fromList(cbor.encode(CborValue(m)));

    test('baseline hand-built map decodes', () {
      expect(codec.decode(enc(fields())).ttl, 3);
    });

    test('rejects unsupported protocol version', () {
      expect(() => codec.decode(enc(fields()..[0] = 2)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects unknown packet type', () {
      expect(() => codec.decode(enc(fields()..[1] = 99)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects unknown map keys', () {
      expect(() => codec.decode(enc(fields()..[42] = 1)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects wrong ID / signature / key lengths', () {
      expect(() => codec.decode(enc(fields()..[2] = Uint8List(15))),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[3] = Uint8List(17))),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[10] = Uint8List(63))),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[11] = Uint8List(63))),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects wrong field types and negative numbers', () {
      expect(() => codec.decode(enc(fields()..[6] = 'x')),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[6] = -1)),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[9] = 'text')),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects TTL / hop count above the protocol maximum', () {
      expect(() => codec.decode(enc(fields()..[7] = kMaxTtl + 1)),
          throwsA(isA<InvalidPacketException>()));
      expect(() => codec.decode(enc(fields()..[8] = kMaxTtl + 1)),
          throwsA(isA<InvalidPacketException>()));
    });

    test('rejects payload above the maximum', () {
      expect(
          () => codec
              .decode(enc(fields()..[9] = Uint8List(kMaxPayloadBytes + 1))),
          throwsA(isA<InvalidPacketException>()));
    });
  });

  group('signatures', () {
    PacketVerifier verifierFor(Actor receiver) =>
        PacketVerifier(receiver.directory);

    test('valid packet verifies and returns the sender identity', () async {
      final who = await verifierFor(bob).verify(sample); // keys embedded
      expect(who, alice.pub);
    });

    test('flipping any signed field invalidates the signature', () async {
      final tweaks = <String, MeshPacket Function(MeshPacket)>{
        'payload': (p) => _rebuild(p, payload: _flip(p.payload)),
        'timestamp': (p) => _rebuild(p, timestampMs: p.timestampMs + 1),
        'messageId': (p) => _rebuild(p, messageId: _flip(p.messageId)),
        'destination': (p) =>
            _rebuild(p, destinationId: _flip(p.destinationId!)),
        'type': (p) => _rebuild(p, type: PacketType.ack),
        'signature': (p) => _rebuild(p, signature: _flip(p.signature)),
      };
      for (final e in tweaks.entries) {
        await expectLater(
          verifierFor(bob).verify(e.value(sample)),
          throwsA(isA<SignatureException>()),
          reason: 'tampered ${e.key}',
        );
      }
    });

    test('ttl and hopCount are NOT signed: relays may change them', () async {
      final relayed = sample.forwarded().forwarded();
      expect(await verifierFor(bob).verify(relayed), alice.pub);
    });

    test('senderId that does not match the embedded keys is rejected',
        () async {
      final mallory = await makeActor();
      // Mallory claims to be Alice but ships her own keys.
      final forged = await mallory.session.sealDirect(
        recipient: bob.pub,
        content: const MessageContent(text: 'I am Alice'),
        includeKeys: true,
      );
      final spoofed = _rebuild(forged, senderId: alice.pub.peerId);
      await expectLater(
        verifierFor(bob).verify(spoofed),
        throwsA(isA<SignatureException>()),
      );
    });

    test('unknown sender without embedded keys is reported as such', () async {
      final carol = await makeActor();
      final noKeys = await carol.session.sealDirect(
        recipient: bob.pub,
        content: const MessageContent(text: 'hi'),
      );
      await expectLater(
        verifierFor(bob).verify(noKeys),
        throwsA(isA<UnknownSenderException>()),
      );
    });
  });

  group('replay protection', () {
    MeshPacket at(int ts, {PacketType t = PacketType.directMessage}) =>
        MeshPacket(
          type: t,
          messageId: randomBytes(16),
          senderId: Uint8List(16),
          timestampMs: ts,
          ttl: 3,
          payload: Uint8List(1),
          signature: Uint8List(64),
        );

    test('the same packet is admitted exactly once', () {
      final g = ReplayGuard();
      final p = at(1000);
      g.admit(p, nowMs: 1000);
      expect(() => g.admit(p, nowMs: 1001), throwsA(isA<ReplayException>()));
      // A relayed copy (different ttl/hop) is the same message.
      expect(() => g.admit(p.forwarded(), nowMs: 1002),
          throwsA(isA<ReplayException>()));
    });

    test('rejects too-old and future-dated packets', () {
      final g = ReplayGuard();
      final now = 10 * 86400 * 1000;
      expect(() => g.admit(at(now - 25 * 3600 * 1000), nowMs: now),
          throwsA(isA<ReplayException>()));
      expect(() => g.admit(at(now + 6 * 60 * 1000), nowMs: now),
          throwsA(isA<ReplayException>()));
      // small skew into the future is tolerated
      g.admit(at(now + 60 * 1000), nowMs: now);
    });

    test('announces expire much faster than stored messages', () {
      final g = ReplayGuard();
      final now = 10 * 86400 * 1000;
      final old = now - 30 * 60 * 1000;
      expect(() => g.admit(at(old, t: PacketType.announce), nowMs: now),
          throwsA(isA<ReplayException>()));
      g.admit(at(old), nowMs: now); // direct message, 30 min old: fine
    });

    test('memory is bounded', () {
      final g = ReplayGuard(maxEntries: 10);
      for (var i = 0; i < 100; i++) {
        g.admit(at(1000), nowMs: 1000);
      }
      expect(g.size, lessThanOrEqualTo(10));
    });

    test('forged packets cannot poison the cache (verify happens first)',
        () async {
      final guard = ReplayGuard();
      final alice2 = await makeActor();
      final bob2 = await makeActor(replay: guard);
      alice2.directory.remember(bob2.pub);
      final good = await alice2.session.sealDirect(
        recipient: bob2.pub,
        content: const MessageContent(text: 'real'),
        includeKeys: true,
      );
      final forged = _rebuild(good, signature: _flip(good.signature));
      await expectLater(
          bob2.session.openDirect(forged), throwsA(isA<SignatureException>()));
      expect(guard.size, 0);
      // The genuine packet with the same ID still gets through.
      final opened = await bob2.session.openDirect(good);
      expect(opened.content.text, 'real');
    });
  });
}

Uint8List _flip(Uint8List b) => Uint8List.fromList(b)..[0] ^= 0x01;

MeshPacket _rebuild(
  MeshPacket p, {
  PacketType? type,
  Uint8List? messageId,
  Uint8List? senderId,
  Uint8List? destinationId,
  int? timestampMs,
  Uint8List? payload,
  Uint8List? signature,
}) =>
    MeshPacket(
      type: type ?? p.type,
      messageId: messageId ?? p.messageId,
      senderId: senderId ?? p.senderId,
      destinationId: destinationId ?? p.destinationId,
      roomId: p.roomId,
      timestampMs: timestampMs ?? p.timestampMs,
      ttl: p.ttl,
      hopCount: p.hopCount,
      payload: payload ?? p.payload,
      signature: signature ?? p.signature,
      senderKeys: p.senderKeys,
    );
