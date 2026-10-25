import 'dart:async';
import 'dart:convert';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/linked_transport.dart';

/// Collects events and lets a test await the next one of a given type.
class EventLog {
  EventLog(Stream<MeshEvent> s) {
    s.listen((e) {
      all.add(e);
      for (final w in List.of(_waiters)) {
        w(e);
      }
    });
  }
  final List<MeshEvent> all = [];
  final List<void Function(MeshEvent)> _waiters = [];

  Future<T> next<T extends MeshEvent>() {
    final c = Completer<T>();
    void w(MeshEvent e) {
      if (e is T && !c.isCompleted) c.complete(e);
    }

    _waiters.add(w);
    return c.future.timeout(const Duration(seconds: 5));
  }
}

void main() {
  late Actor alice, bob;
  late LinkedTransport tA, tB;
  late MeshNode nodeA, nodeB;
  late EventLog logA, logB;

  setUp(() async {
    alice = await makeActor();
    bob = await makeActor();
    final (a, b) = LinkedTransport.pair('alice', 'bob');
    tA = a;
    tB = b;
    nodeA = MeshNode(
        session: alice.session, transports: [tA], displayName: 'Alice');
    nodeB =
        MeshNode(session: bob.session, transports: [tB], displayName: 'Bob');
    logA = EventLog(nodeA.events);
    logB = EventLog(nodeB.events);
    await nodeA.start();
    await nodeB.start();
  });

  tearDown(() async {
    await nodeA.stop();
    await nodeB.stop();
  });

  Future<void> connect() async {
    final onA = logA.next<PeerOnline>();
    final onB = logB.next<PeerOnline>();
    await tA.connect();
    await Future.wait([onA, onB]);
  }

  test('connecting exchanges signed announces; peers learn each other',
      () async {
    final onA = logA.next<PeerOnline>();
    final onB = logB.next<PeerOnline>();
    await tA.connect();
    final seenByA = await onA;
    final seenByB = await onB;
    expect(seenByA.identity, bob.pub);
    expect(seenByA.displayName, 'Bob');
    expect(seenByB.identity, alice.pub);
    expect(seenByB.displayName, 'Alice');
  });

  test('A → B: encrypted text is delivered, then a verified ack arrives',
      () async {
    await connect();
    final got = logB.next<MessageReceived>();
    final delivered = logA.next<MessageDelivered>();

    final id = await nodeA.sendText(bob.pub, 'привет от A');

    final m = (await got).message;
    expect(m.content.text, 'привет от A');
    expect(m.sender, alice.pub);
    final d = await delivered;
    expect(d.messageId, id);
    expect(d.by, bob.pub);
  });

  test('what crosses the wire contains no plaintext', () async {
    await connect();
    final got = logB.next<MessageReceived>();
    const secret = 'WIRE-SECRET-XYZ';
    await nodeA.sendText(bob.pub, secret);
    await got;
    final joined = tA.sent.expand((b) => b).toList();
    expect(_find(joined, utf8.encode(secret)), isFalse);
  });

  test('a replayed copy of the packet does not create a second message',
      () async {
    await connect();
    final got = logB.next<MessageReceived>();
    await nodeA.sendText(bob.pub, 'once');
    await got;

    final messagePacket = tA.sent.firstWhere((b) {
      return const PacketCodec().decode(b).type == PacketType.directMessage;
    });
    final dropped = logB.next<PacketDropped>();
    tB.inject(messagePacket); // attacker re-sends captured bytes
    final d = await dropped;
    expect(d.reason, isA<ReplayException>());
    expect(logB.all.whereType<MessageReceived>().length, 1);
  });

  test('garbage bytes are dropped without crashing the node', () async {
    await connect();
    final dropped = logB.next<PacketDropped>();
    tB.inject(randomBytes(200));
    expect((await dropped).reason, isA<InvalidPacketException>());
    // still functional afterwards
    final got = logB.next<MessageReceived>();
    await nodeA.sendText(bob.pub, 'still works');
    expect((await got).message.content.text, 'still works');
  });

  test('sending to a peer without a live link fails with NoRoute', () async {
    await expectLater(
        nodeA.sendText(bob.pub, 'x'), throwsA(isA<NoRouteException>()));
  });

  test('link loss is reported as PeerOffline and sending then fails', () async {
    await connect();
    final off = logA.next<PeerOffline>();
    await tA.disconnect();
    expect((await off).peerId, bob.pub.peerId);
    await expectLater(
        nodeA.sendText(bob.pub, 'x'), throwsA(isA<NoRouteException>()));
  });

  test('a forged announce claiming another identity is rejected', () async {
    final mallory = await makeActor();
    final forged = await mallory.session.createAnnounce(displayName: 'Alice');
    // Mallory swaps in Alice's sender ID but cannot fix the signature/keys.
    final p = MeshPacket(
      type: forged.type,
      messageId: forged.messageId,
      senderId: alice.pub.peerId,
      timestampMs: forged.timestampMs,
      ttl: 1,
      payload: forged.payload,
      signature: forged.signature,
      senderKeys: forged.senderKeys,
    );
    final dropped = logB.next<PacketDropped>();
    tB.inject(const PacketCodec().encode(p));
    expect((await dropped).reason, isA<SignatureException>());
    expect(bob.directory.lookup(alice.pub.peerId), isNull);
  });
}

bool _find(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
