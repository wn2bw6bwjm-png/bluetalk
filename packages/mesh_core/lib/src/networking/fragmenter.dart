import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';

/// Splits a packet into chunks that fit a small link MTU (BLE: typically
/// 20–512 bytes) and reassembles them on the other side.
///
/// Chunk wire format (6-byte header, big-endian):
///   seq (u16) ‖ index (u16) ‖ count (u16) ‖ data
///
/// `seq` identifies the packet within one sender→receiver direction of one
/// link; it wraps at 65536.
class Fragmenter {
  Fragmenter();

  static const int headerLength = 6;
  int _seq = 0;

  /// [mtu] is the maximum number of bytes of ONE chunk including header.
  List<Uint8List> split(Uint8List packet, {required int mtu}) {
    if (mtu <= headerLength) {
      throw ArgumentError('MTU must exceed the $headerLength-byte header');
    }
    if (packet.isEmpty || packet.length > kMaxPacketBytes) {
      throw const InvalidPacketException('Packet size out of range');
    }
    final dataPerChunk = mtu - headerLength;
    final count = (packet.length + dataPerChunk - 1) ~/ dataPerChunk;
    if (count > 0xFFFF) {
      throw const InvalidPacketException('Too many fragments');
    }
    final seq = _seq;
    _seq = (_seq + 1) & 0xFFFF;

    final chunks = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * dataPerChunk;
      final end = (start + dataPerChunk).clamp(0, packet.length);
      chunks.add(concatBytes([
        u16(seq),
        u16(i),
        u16(count),
        Uint8List.sublistView(packet, start, end),
      ]));
    }
    return chunks;
  }
}

/// Reassembles chunks of ONE link direction. Defensive by design: bounded
/// memory, bounded number of partial packets, stale partials are dropped.
class Reassembler {
  Reassembler({
    this.maxPartials = 4,
    this.partialTimeout = const Duration(seconds: 15),
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int maxPartials;
  final Duration partialTimeout;
  final int Function() _clock;
  final Map<int, _Partial> _partials = {};

  /// Feeds one chunk. Returns the complete packet when the last missing chunk
  /// arrived, otherwise `null`. Malformed chunks throw
  /// [InvalidPacketException]; callers should drop them.
  Uint8List? add(Uint8List chunk) {
    if (chunk.length <= Fragmenter.headerLength) {
      throw const InvalidPacketException('Chunk too short');
    }
    final bd = ByteData.sublistView(chunk);
    final seq = bd.getUint16(0);
    final index = bd.getUint16(2);
    final count = bd.getUint16(4);
    if (count == 0 || index >= count) {
      throw const InvalidPacketException('Bad chunk index/count');
    }
    final data = Uint8List.sublistView(chunk, Fragmenter.headerLength);

    final now = _clock();
    _partials.removeWhere(
      (_, p) => now - p.startedAt > partialTimeout.inMilliseconds,
    );

    if (count == 1) return Uint8List.fromList(data);

    var partial = _partials[seq];
    if (partial == null) {
      if (_partials.length >= maxPartials) {
        // Evict the oldest partial to make room (bounded memory).
        final oldest = _partials.entries
            .reduce((a, b) => a.value.startedAt <= b.value.startedAt ? a : b);
        _partials.remove(oldest.key);
      }
      partial = _partials[seq] = _Partial(count, now);
    }
    if (partial.count != count) {
      _partials.remove(seq);
      throw const InvalidPacketException('Inconsistent fragment count');
    }
    if (partial.chunks[index] == null) {
      partial.chunks[index] = Uint8List.fromList(data);
      partial.received++;
      partial.bytes += data.length;
      if (partial.bytes > kMaxPacketBytes) {
        _partials.remove(seq);
        throw const InvalidPacketException('Reassembled packet too large');
      }
    }
    if (partial.received < count) return null;

    _partials.remove(seq);
    return concatBytes(partial.chunks.cast<Uint8List>());
  }
}

class _Partial {
  _Partial(this.count, this.startedAt) : chunks = List.filled(count, null);
  final int count;
  final int startedAt;
  final List<Uint8List?> chunks;
  int received = 0;
  int bytes = 0;
}
