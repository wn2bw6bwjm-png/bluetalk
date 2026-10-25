import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

/// TEST-ONLY bridge. Two of them are wired back-to-back and enforce a chunk
/// size limit the way a BLE stack enforces the ATT MTU.
class FakeBridge implements NativeBridge {
  FakeBridge(this.name, {required this.mtu});
  final String name;
  final int mtu;
  FakeBridge? peer;
  final StreamController<Map<String, Object?>> _ctrl =
      StreamController.broadcast();
  final List<Map<String, Object?>> calls = [];
  int maxChunkSeen = 0;

  @override
  Stream<Map<String, Object?>> get events => _ctrl.stream;

  @override
  Future<void> invoke(String method, Map<String, Object?> args) async {
    calls.add({'m': method, ...args});
    if (method == 'send') {
      final data = args['data'] as Uint8List;
      if (data.length > mtu) throw StateError('chunk exceeds MTU');
      if (data.length > maxChunkSeen) maxChunkSeen = data.length;
      // asynchronous delivery, like a radio
      scheduleMicrotask(() => peer!._ctrl
          .add({'t': 'chunk', 'link': peer!._linkName, 'data': data}));
    }
  }

  String get _linkName => 'link-to-$name';
  void emit(Map<String, Object?> e) => _ctrl.add(e);
  void linkUp() => _ctrl.add({'t': 'up', 'link': _linkName, 'mtu': mtu});
  void linkDown() => _ctrl.add({'t': 'down', 'link': _linkName});
}

void main() {
  late FakeBridge ba, bb;
  late NativeTransport ta, tb;
  late List<TransportEvent> ea, eb;

  setUp(() async {
    ba = FakeBridge('a', mtu: 23 - 3); // worst-case BLE
    bb = FakeBridge('b', mtu: 23 - 3);
    ba.peer = bb;
    bb.peer = ba;
    ta = NativeTransport(kind: TransportKind.ble, bridge: ba);
    tb = NativeTransport(kind: TransportKind.ble, bridge: bb);
    ea = [];
    eb = [];
    ta.events.listen(ea.add);
    tb.events.listen(eb.add);
    await ta.start(advertisedName: 'A');
    await tb.start();
    ba.linkUp();
    bb.linkUp();
    await Future<void>.delayed(Duration.zero);
  });

  Future<Uint8List> nextPacket(List<TransportEvent> log, int count) async {
    for (var i = 0; i < 200; i++) {
      final p = log.whereType<PacketReceived>().toList();
      if (p.length >= count) return p[count - 1].bytes;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw TimeoutException('no packet');
  }

  test('start is forwarded to the bridge with the advertised name', () {
    expect(ba.calls.first, {'m': 'start', 'name': 'A'});
  });

  test('link up is surfaced and listed', () {
    expect(ea.whereType<LinkEstablished>().length, 1);
    expect(ta.links.single, LinkId(TransportKind.ble, 'link-to-a'));
  });

  test('a large packet crosses a 20-byte-MTU link intact', () async {
    final packet =
        Uint8List.fromList(List.generate(3000, (i) => (i * 7 + 3) & 0xFF));
    await ta.send(ta.links.single, packet);
    expect(await nextPacket(eb, 1), packet);
    expect(ba.maxChunkSeen, lessThanOrEqualTo(20));
  });

  test('concurrent sends are serialized: no interleaving corruption', () async {
    final p1 = Uint8List.fromList(List.filled(900, 1));
    final p2 = Uint8List.fromList(List.filled(1100, 2));
    final link = ta.links.single;
    await Future.wait([ta.send(link, p1), ta.send(link, p2)]);
    final got = [await nextPacket(eb, 1), await nextPacket(eb, 2)];
    expect(got, containsAll([p1, p2]));
  });

  test('garbage chunk is ignored; link and later packets keep working',
      () async {
    bb.emit({'t': 'chunk', 'link': 'link-to-b', 'data': Uint8List(3)});
    final packet = Uint8List.fromList(List.filled(50, 9));
    await ta.send(ta.links.single, packet);
    expect(await nextPacket(eb, 1), packet);
  });

  test('link down is surfaced; sending afterwards fails', () async {
    final link = ta.links.single;
    ba.linkDown();
    await Future<void>.delayed(Duration.zero);
    expect(ea.whereType<LinkLost>().length, 1);
    expect(ta.links, isEmpty);
    await expectLater(ta.send(link, Uint8List(10)), throwsStateError);
  });

  test('native log and error lines are exposed on the logs stream', () async {
    final lines = <String>[];
    ta.logs.listen(lines.add);
    ba.emit({'t': 'log', 'message': 'scanning started'});
    ba.emit({'t': 'error', 'message': 'Bluetooth is turned off'});
    ba.emit({'t': 'log', 'message': 5}); // malformed: ignored
    await Future<void>.delayed(Duration.zero);
    expect(lines,
        ['[ble] scanning started', '[ble] ERROR: Bluetooth is turned off']);
  });

  test('discovery events carry name and rssi', () async {
    ba.emit({'t': 'discovered', 'link': 'x', 'name': 'Bob', 'rssi': -60});
    await Future<void>.delayed(Duration.zero);
    final d = ea.whereType<PeerDiscovered>().single;
    expect(d.advertisedName, 'Bob');
    expect(d.rssi, -60);
  });

  test('unknown / malformed native events are ignored', () async {
    ba.emit({'t': 'nonsense'});
    ba.emit({'t': 'up', 'link': 5, 'mtu': 'x'});
    ba.emit({'t': 'up', 'link': 'tiny', 'mtu': 4});
    await Future<void>.delayed(Duration.zero);
    expect(ta.links.length, 1); // only the original link
  });

  test('stop notifies LinkLost for every open link and tells native', () async {
    await ta.stop();
    await Future<void>.delayed(Duration.zero);
    expect(ea.whereType<LinkLost>().length, 1);
    expect(ba.calls.last['m'], 'stop');
  });
}
