import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/topology.dart';

bool _contains(List<List<int>> packets, List<int> needle) {
  for (final p in packets) {
    for (var i = 0; i + needle.length <= p.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (p[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
  }
  return false;
}

void main() {
  deviceSeenTests();
  relayReceiptTests();
  presenceTests();
  retryThroughRelayTests();
  group('A ↔ B ↔ C (no direct A–C link)', () {
    late Topology t;

    setUp(() async {
      t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
    });
    tearDown(() => t.stop());

    test('announces are relayed once: A and C learn each other at 2 hops', () {
      final seenByC = t['C'].of<PeerReachable>();
      expect(seenByC.map((e) => e.identity), contains(t['A'].pub));
      expect(seenByC.firstWhere((e) => e.identity == t['A'].pub).hops, 1);
      // …and are NOT directly connected
      expect(t['C'].of<PeerOnline>().map((e) => e.identity),
          isNot(contains(t['A'].pub)));
      expect(t['A'].of<PeerReachable>().map((e) => e.identity),
          contains(t['C'].pub));
    });

    test('scenario 1: A sends to C through B; C decrypts, A gets verified ack',
        () async {
      final id = await t['A'].node.sendText(t['C'].pub, 'hello C via B');
      await settle();

      final got = t['C'].of<MessageReceived>();
      expect(got.length, 1);
      expect(got.single.message.content.text, 'hello C via B');
      expect(got.single.message.sender, t['A'].pub);
      expect(got.single.hops, 1); // exactly one relay

      final delivered = t['A'].of<MessageDelivered>();
      expect(delivered.length, 1);
      expect(delivered.single.messageId, id);
      expect(delivered.single.by, t['C'].pub);

      // B relayed, but never surfaced a message to its own user.
      expect(t['B'].of<PacketRelayed>(), isNotEmpty);
      expect(t['B'].of<MessageReceived>(), isEmpty);
    });

    test('scenario 6: the relay never sees plaintext', () async {
      const secret = 'ONLY-FOR-C-7731';
      await t['A'].node.sendText(t['C'].pub, secret);
      await settle();
      expect(t['C'].of<MessageReceived>().single.message.content.text, secret);
      // Everything B received from A and sent to C, and the reverse:
      final needle = utf8.encode(secret);
      expect(_contains(t['A'].wire, needle), isFalse);
      expect(_contains(t['B'].wire, needle), isFalse);
      expect(_contains(t['C'].wire, needle), isFalse);
    });

    test('scenario 2: re-sending a captured packet creates no duplicate',
        () async {
      await t['A'].node.sendText(t['C'].pub, 'once');
      await settle();
      final captured = t['A'].transports.first.sent.firstWhere((b) =>
          const PacketCodec().decode(b).type == PacketType.directMessage);

      // Attacker replays the same bytes into B twice.
      final toB = t['A'].transports.first.peer!;
      toB.inject(captured);
      toB.inject(captured);
      await settle();

      expect(t['C'].of<MessageReceived>().length, 1);
      final dropsAtB = t['B'].of<PacketDropped>().map((d) => d.reason);
      expect(dropsAtB.whereType<ReplayException>().length,
          greaterThanOrEqualTo(2));
    });

    test('forged packet is not forwarded', () async {
      await t['A'].node.sendText(t['C'].pub, 'real');
      await settle();
      final before = t['C'].events.length;
      final real = t['A'].transports.first.sent.firstWhere((b) =>
          const PacketCodec().decode(b).type == PacketType.directMessage);
      final p = const PacketCodec().decode(real);
      final forged = MeshPacket(
        type: p.type,
        messageId:
            randomBytes(16), // fresh ID so dedupe cannot hide the forgery
        senderId: p.senderId,
        destinationId: p.destinationId,
        timestampMs: p.timestampMs,
        ttl: p.ttl,
        payload: p.payload,
        signature: p.signature, // signature no longer matches
        senderKeys: p.senderKeys,
      );
      t['A'].transports.first.peer!.inject(const PacketCodec().encode(forged));
      await settle();
      expect(t['C'].events.length, before);
      expect(t['B'].of<PacketDropped>().map((d) => d.reason),
          contains(isA<SignatureException>()));
    });

    test('route cache: reply goes back directly, B is not flooded', () async {
      await t['C'].node.sendText(t['A'].pub, 'ping');
      await settle();
      expect(t['A'].of<MessageReceived>().single.message.content.text, 'ping');
      expect(t['C'].of<MessageDelivered>().length, 1);
    });
  });

  group('scenario 3: loops', () {
    test('A → B → A: relay never sends back on the arrival link', () async {
      final t = Topology()..link('A', 'B');
      await t.build();
      await t.connectAll();
      final ghost = await makeGhost(); // known to A, but nobody can reach it
      t['A'].actor.directory.remember(ghost);
      await t['A'].node.sendText(ghost, 'to nobody');
      await settle();
      // B received it, has no other link, so it must not echo it back.
      expect(t['B'].of<PacketRelayed>(), isEmpty);
      final echoes = t['A'].events.whereType<PacketDropped>();
      expect(echoes, isEmpty);
      await t.stop();
    });

    test('triangle A–B–C–A: flooding is bounded and duplicates are dropped',
        () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C')
        ..link('C', 'A');
      await t.build();
      await t.connectAll();
      final ghost = await makeGhost();
      t['A'].actor.directory.remember(ghost);

      // Count only data packets: relay receipts are one-hop attestations and
      // are not part of any flood.
      int total() => t.nodes.values
          .map((n) => n.wire
              .where((b) =>
                  const PacketCodec().decode(Uint8List.fromList(b)).type ==
                  PacketType.directMessage)
              .length)
          .reduce((a, b) => a + b);
      final before = total();
      await t['A'].node.sendText(ghost, 'loop test');
      await settle(100);

      // A→B, A→C, B→C, C→B. Anything further would be a loop.
      expect(total() - before, lessThanOrEqualTo(4));
      // The second copy reaching B or C is recognised as a duplicate.
      final dups = [
        ...t['B'].of<PacketDropped>(),
        ...t['C'].of<PacketDropped>()
      ].map((d) => d.reason);
      expect(dups, contains(isA<ReplayException>()));
      // Nobody ever echoed the packet back to its origin.
      expect(t['A'].of<PacketDropped>(), isEmpty);
      await t.stop();
    });

    test('a packet that does come back to its origin is dropped as own',
        () async {
      final t = Topology()..link('A', 'B');
      await t.build();
      await t.connectAll();
      final ghost = await makeGhost();
      t['A'].actor.directory.remember(ghost);
      await t['A'].node.sendText(ghost, 'boomerang');
      await settle();
      final out = t['A'].transports.first.sent.firstWhere((b) =>
          const PacketCodec().decode(b).type == PacketType.directMessage);
      // Simulate a misbehaving neighbour bouncing it back.
      t['A'].transports.first.inject(out);
      await settle();
      expect(t['A'].of<PacketDropped>().map((d) => d.reason),
          contains(isA<ReplayException>()));
      await t.stop();
    });
  });

  group('TTL and flooding limits', () {
    test('a packet with ttl 1 reaches 2 hops but not 3', () async {
      // A – B – C – D
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C')
        ..link('C', 'D');
      await t.build();
      await t.connectAll();
      t.introduce('A', 'D');
      // ttl 1: B may forward once (ttl→0); C must not forward further.
      await t['A'].node.sendText(t['D'].pub, 'short-lived', ttl: 1);
      await settle();
      expect(t['D'].of<MessageReceived>(), isEmpty);
      expect(t['C'].of<PacketDropped>().map((d) => d.reason),
          contains(isA<TtlExpiredException>()));
      await t.stop();
    });

    test('with the default TTL the same packet crosses 3 hops', () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C')
        ..link('C', 'D');
      await t.build();
      await t.connectAll();
      t.introduce('A', 'D');
      await t['A'].node.sendText(t['D'].pub, 'long-lived');
      await settle(80);
      final got = t['D'].of<MessageReceived>();
      expect(got.length, 1);
      expect(got.single.hops, 2);
      expect(t['A'].of<MessageDelivered>().length, 1);
      await t.stop();
    });

    test('route cache: with a known route the side branch is not flooded',
        () async {
      //  A – B – C
      //      |
      //      D (leaf)
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C')
        ..link('B', 'D');
      await t.build();
      await t.connectAll();
      final dBefore = t['D'].wire.length + t['D'].events.length;
      await t['A'].node.sendText(t['C'].pub, 'unicast please');
      await settle();
      expect(t['C'].of<MessageReceived>().length, 1);
      // D only ever saw announces, never the message.
      expect(t['D'].of<PacketDropped>(), isEmpty);
      expect(t['D'].events.whereType<MessageReceived>(), isEmpty);
      expect(t['D'].wire.length + t['D'].events.length,
          lessThanOrEqualTo(dBefore + 1));
      await t.stop();
    });

    test('unknown route is flooded to all other links', () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C')
        ..link('B', 'D');
      await t.build();
      await t.connectAll();
      final ghost = await makeGhost();
      t['A'].actor.directory.remember(ghost);
      await t['A'].node.sendText(ghost, 'who is out there');
      await settle();
      final relayed = t['B'].of<PacketRelayed>().single;
      expect(relayed.toLinks.length, 2); // C and D, not back to A
      await t.stop();
    });
  });

  group('rate limiting and route table', () {
    test('router drops forwarding beyond the burst budget', () {
      var now = 0;
      final r = MeshRouter(clock: () => now, burst: 3, ratePerSecond: 1);
      const link = LinkId(TransportKind.ble, 'x');
      r.checkRate(link);
      r.checkRate(link);
      r.checkRate(link);
      expect(() => r.checkRate(link), throwsA(isA<RateLimitedException>()));
      now += 2000; // two tokens refill
      r.checkRate(link);
      r.checkRate(link);
      expect(() => r.checkRate(link), throwsA(isA<RateLimitedException>()));
    });

    test('routes expire, prefer shorter paths and are dropped with the link',
        () async {
      var now = 1000;
      final r =
          MeshRouter(clock: () => now, routeTtl: const Duration(seconds: 10));
      final peer = randomBytes(16);
      const l1 = LinkId(TransportKind.ble, 'l1');
      const l2 = LinkId(TransportKind.ble, 'l2');
      r.learn(peer, l1, 3);
      r.learn(peer, l2, 5); // worse: ignored
      expect(r.routeTo(peer)!.link, l1);
      r.learn(peer, l2, 2); // better: replaces
      expect(r.routeTo(peer)!.link, l2);
      r.forgetLink(l2);
      expect(r.routeTo(peer), isNull);
      r.learn(peer, l1, 1);
      now += 11000;
      expect(r.routeTo(peer), isNull); // expired
    });

    test('route table is bounded', () {
      final r = MeshRouter(maxRoutes: 4);
      const l = LinkId(TransportKind.ble, 'l');
      for (var i = 0; i < 20; i++) {
        r.learn(randomBytes(16), l, 1);
      }
      expect(r.routeCount, lessThanOrEqualTo(4));
    });

    test('targets never include the arrival link', () {
      final r = MeshRouter();
      const a = LinkId(TransportKind.ble, 'a');
      const b = LinkId(TransportKind.ble, 'b');
      expect(r.targets(randomBytes(16), [a, b], arrival: a), [b]);
    });
  });

  group('link loss', () {
    test('losing the next-hop link makes sends fail instead of vanishing',
        () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
      await t.links.first.$1.disconnect();
      await settle();
      await expectLater(t['A'].node.sendText(t['C'].pub, 'x'),
          throwsA(isA<NoRouteException>()));
      await t.stop();
    });
  });
}

/// A well-formed identity that is not attached to any node.
Future<PeerIdentity> makeGhost() async {
  final id = await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
  return id.public;
}

void retryThroughRelayTests() {
  test('a retry of the same message id (new timestamp) passes a relay',
      () async {
    final t = Topology()
      ..link('A', 'B')
      ..link('B', 'C');
    await t.build();
    await t.connectAll();
    final mid = randomBytes(16);
    await t['A'].node.sendContent(
        t['C'].pub, const MessageContent.text('first'),
        messageId: mid);
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 5)); // new ms
    await t['A'].node.sendContent(
        t['C'].pub, const MessageContent.text('first'),
        messageId: mid);
    await settle();
    // C delivered once (second is a duplicate for the final recipient) but
    // the relay forwarded both attempts.
    expect(t['C'].of<MessageReceived>().length, 1);
    expect(
        t['B']
            .of<PacketRelayed>()
            .where((e) => e.packet.type == PacketType.directMessage)
            .length,
        2);
    await t.stop();
  });
}

void presenceTests() {
  test('isConnected / isReachable reflect links and learned routes', () async {
    final t = Topology()
      ..link('A', 'B')
      ..link('B', 'C');
    await t.build();
    await t.connectAll();
    expect(t['A'].node.isConnected(t['B'].pub.peerId), isTrue);
    expect(t['A'].node.isConnected(t['C'].pub.peerId), isFalse);
    expect(t['A'].node.isReachable(t['C'].pub.peerId), isTrue); // via B
    expect(t['A'].node.linkCount, 1);
    await t.links.first.$1.disconnect();
    await settle();
    expect(t['A'].node.isConnected(t['B'].pub.peerId), isFalse);
    expect(t['A'].node.isReachable(t['C'].pub.peerId), isFalse);
    await t.stop();
  });
}

void relayReceiptTests() {
  group('relay receipts ("Relayed")', () {
    test('origin gets a signed receipt from the first relay, then the ack',
        () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
      final id = await t['A'].node.sendText(t['C'].pub, 'via B');
      await settle(80);
      final rc = t['A'].of<RelayConfirmed>();
      expect(rc.length, 1);
      expect(rc.single.messageId, id);
      expect(rc.single.finalDestination, t['C'].pub.peerId);
      expect(rc.single.by, t['B'].pub);
      expect(t['A'].of<MessageDelivered>().length, 1); // and still delivered
      await t.stop();
    });

    test('no receipt for a direct hop (nothing was relayed)', () async {
      final t = Topology()..link('A', 'B');
      await t.build();
      await t.connectAll();
      await t['A'].node.sendText(t['B'].pub, 'direct');
      await settle(60);
      expect(t['A'].of<RelayConfirmed>(), isEmpty);
      expect(t['A'].of<MessageDelivered>().length, 1);
      await t.stop();
    });

    test('no receipt when the relay could not forward anywhere', () async {
      final t = Topology()..link('A', 'B'); // B has no other link
      await t.build();
      await t.connectAll();
      final ghost =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      t['A'].actor.directory.remember(ghost.public);
      await t['A'].node.sendText(ghost.public, 'nowhere to go');
      await settle(80);
      expect(t['A'].of<RelayConfirmed>(), isEmpty);
      await t.stop();
    });

    test('relayed but undeliverable: receipt arrives, ack never does',
        () async {
      // A - B - D(leaf); the recipient is a ghost.
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'D');
      await t.build();
      await t.connectAll();
      final ghost =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      t['A'].actor.directory.remember(ghost.public);
      await t['A'].node.sendText(ghost.public, 'lost in the mesh');
      await settle(80);
      expect(t['A'].of<RelayConfirmed>().length, 1);
      expect(t['A'].of<MessageDelivered>(), isEmpty);
      await t.stop();
    });

    test('a receipt is accepted only from the direct neighbour that signed it',
        () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
      // C (not a neighbour of A) forges a receipt for A and injects it on A's
      // link to B, as if B had sent it.
      final forged = await t['C'].actor.session.createRelayReceipt(
            messageId: randomBytes(16),
            finalDestination: randomBytes(16),
            toNeighbor: t['A'].pub.peerId,
          );
      t['A'].transports.first.inject(const PacketCodec().encode(forged));
      await settle(60);
      expect(t['A'].of<RelayConfirmed>(), isEmpty);
      expect(t['A'].of<PacketDropped>().map((d) => d.reason),
          contains(isA<SignatureException>()));
      await t.stop();
    });

    test('receipts for someone else are dropped, replays are dropped',
        () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
      await t['A'].node.sendText(t['C'].pub, 'once');
      await settle(80);
      final bytes = t['B'].transports.first.sent.firstWhere(
          (b) => const PacketCodec().decode(b).type == PacketType.relayReceipt);
      // replay the same receipt to A
      t['A'].transports.first.inject(bytes);
      await settle(60);
      expect(t['A'].of<RelayConfirmed>().length, 1);
      expect(t['A'].of<PacketDropped>().map((d) => d.reason),
          contains(isA<ReplayException>()));
      // the same bytes shown to C (not the addressee) are refused
      t['C'].transports.first.inject(bytes);
      await settle(60);
      expect(t['C'].of<RelayConfirmed>(), isEmpty);
      await t.stop();
    });

    test('a receipt never leaves the link it was sent on (ttl 0)', () async {
      final t = Topology()
        ..link('A', 'B')
        ..link('B', 'C');
      await t.build();
      await t.connectAll();
      await t['A'].node.sendText(t['C'].pub, 'x');
      await settle(80);
      final receipts = [
        for (final n in ['A', 'B', 'C'])
          for (final b in t[n].wire)
            if (const PacketCodec().decode(Uint8List.fromList(b)).type ==
                PacketType.relayReceipt)
              n
      ];
      expect(receipts, ['B']); // only B ever transmitted one
      await t.stop();
    });
  });
}

void deviceSeenTests() {
  test('a scanned but unconnected device is reported as DeviceSeen', () async {
    final t = Topology()..link('A', 'B');
    await t.build();
    t['A'].transports.first.discover(rssi: -61);
    await settle();
    final seen = t['A'].of<DeviceSeen>();
    expect(seen.length, 1);
    expect(seen.single.rssi, -61);
    expect(t['A'].of<PeerOnline>(), isEmpty); // not identified yet
    await t.stop();
  });
}
