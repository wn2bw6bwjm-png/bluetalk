import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  Uint8List data(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xFF));

  test('single-chunk packet passes through', () {
    final f = Fragmenter();
    final chunks = f.split(data(10), mtu: 100);
    expect(chunks.length, 1);
    expect(Reassembler().add(chunks.single), data(10));
  });

  test('large packet splits to MTU and reassembles in order', () {
    final f = Fragmenter();
    final packet = data(5000);
    final chunks = f.split(packet, mtu: 185);
    expect(chunks.every((c) => c.length <= 185), isTrue);
    final r = Reassembler();
    Uint8List? out;
    for (final c in chunks) {
      out = r.add(c);
    }
    expect(out, packet);
  });

  test('works with the minimum BLE MTU (20 bytes) for a max-size packet', () {
    final packet = data(kMaxPacketBytes);
    final chunks = Fragmenter().split(packet, mtu: 20);
    final r = Reassembler();
    Uint8List? out;
    for (final c in chunks) {
      out = r.add(c);
    }
    expect(out, packet);
  });

  test('out-of-order and duplicate chunks are handled', () {
    final packet = data(1000);
    final chunks = Fragmenter().split(packet, mtu: 100);
    final shuffled = [...chunks.reversed, chunks.first, chunks[3]];
    final r = Reassembler();
    final results = shuffled.map(r.add).whereType<Uint8List>().toList();
    expect(results.length, 1);
    expect(results.single, packet);
  });

  test('interleaved packets reassemble independently', () {
    final f = Fragmenter();
    final p1 = data(600), p2 = Uint8List.fromList(data(700).reversed.toList());
    final c1 = f.split(p1, mtu: 100), c2 = f.split(p2, mtu: 100);
    final r = Reassembler();
    final out = <Uint8List>[];
    for (var i = 0; i < c2.length; i++) {
      if (i < c1.length) {
        final x = r.add(c1[i]);
        if (x != null) out.add(x);
      }
      final y = r.add(c2[i]);
      if (y != null) out.add(y);
    }
    expect(out, containsAll([p1, p2]));
  });

  test('stale partial packets are discarded', () {
    var now = 0;
    final r = Reassembler(
        partialTimeout: const Duration(seconds: 5), clock: () => now);
    final chunks = Fragmenter().split(data(500), mtu: 100);
    r.add(chunks[0]);
    now = 10000;
    // The remaining chunks alone can never complete the packet any more.
    Uint8List? out;
    for (final c in chunks.skip(1)) {
      out = r.add(c);
    }
    expect(out, isNull);
  });

  test('number of partial packets is bounded', () {
    final f = Fragmenter();
    final r = Reassembler(maxPartials: 2);
    for (var i = 0; i < 20; i++) {
      r.add(f.split(data(500), mtu: 100).first); // never completes
    }
    // no exception, memory bounded; a fresh complete packet still works
    final ok = f.split(data(50), mtu: 100);
    expect(r.add(ok.single), data(50));
  });

  test('malformed chunks are rejected', () {
    final r = Reassembler();
    expect(() => r.add(Uint8List(3)), throwsA(isA<InvalidPacketException>()));
    // index >= count
    final bad = Uint8List.fromList([0, 1, 0, 5, 0, 2, 9, 9]);
    expect(() => r.add(bad), throwsA(isA<InvalidPacketException>()));
    // count = 0
    final zero = Uint8List.fromList([0, 1, 0, 0, 0, 0, 9]);
    expect(() => r.add(zero), throwsA(isA<InvalidPacketException>()));
  });

  test('inconsistent fragment count for the same seq is rejected', () {
    final r = Reassembler();
    r.add(Uint8List.fromList([0, 7, 0, 0, 0, 3, 1]));
    expect(() => r.add(Uint8List.fromList([0, 7, 0, 1, 0, 4, 1])),
        throwsA(isA<InvalidPacketException>()));
  });

  test('MTU smaller than the header is a programming error', () {
    expect(() => Fragmenter().split(data(10), mtu: 6), throwsArgumentError);
  });

  test('sequence number wraps without breaking', () {
    final f = Fragmenter();
    final r = Reassembler();
    for (var i = 0; i < 70000; i += 1000) {
      for (var j = 0; j < 1000; j++) {
        f.split(data(1), mtu: 50);
      }
      final c = f.split(data(120), mtu: 50);
      Uint8List? out;
      for (final x in c) {
        out = r.add(x);
      }
      expect(out, data(120));
    }
  });
}
