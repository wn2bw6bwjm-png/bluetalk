import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../core/constants.dart';
import '../core/errors.dart';
import 'mesh_packet.dart';
import 'packet_type.dart';

/// CBOR wire codec (RFC 8949) for [MeshPacket].
///
/// A packet is a CBOR map with small unsigned-integer keys (compact):
///
/// | key | field          | CBOR type            |
/// |-----|----------------|----------------------|
/// | 0   | version        | uint                 |
/// | 1   | type           | uint                 |
/// | 2   | messageId      | bytes(16)            |
/// | 3   | senderId       | bytes(16)            |
/// | 4   | destinationId  | bytes(16) or null    |
/// | 5   | roomId         | bytes(16) or null    |
/// | 6   | timestampMs    | uint                 |
/// | 7   | ttl            | uint                 |
/// | 8   | hopCount       | uint                 |
/// | 9   | payload        | bytes                |
/// | 10  | signature      | bytes(64)            |
/// | 11  | senderKeys     | bytes(64) or absent  |
///
/// Decoding is strict: unknown keys, wrong types, wrong lengths, trailing
/// bytes and non-minimal encodings are all rejected with
/// [InvalidPacketException].
class PacketCodec {
  const PacketCodec();

  Uint8List encode(MeshPacket p) {
    final map = <int, Object?>{
      0: p.version,
      1: p.type.wire,
      2: p.messageId,
      3: p.senderId,
      4: p.destinationId,
      5: p.roomId,
      6: p.timestampMs,
      7: p.ttl,
      8: p.hopCount,
      9: p.payload,
      10: p.signature,
      if (p.senderKeys != null) 11: p.senderKeys,
    };
    final out = Uint8List.fromList(cbor.encode(CborValue(map)));
    if (out.length > kMaxPacketBytes) {
      throw const InvalidPacketException('Encoded packet exceeds maximum size');
    }
    return out;
  }

  MeshPacket decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kMaxPacketBytes) {
      throw const InvalidPacketException('Packet size out of range');
    }

    final Object? raw;
    try {
      final value = cbor.decode(bytes);
      // Reject trailing garbage / non-canonical encodings: a valid packet
      // re-encodes to exactly the same number of bytes.
      if (cbor.encode(value).length != bytes.length) {
        throw const InvalidPacketException('Non-canonical or trailing bytes');
      }
      raw = value.toObject();
    } on InvalidPacketException {
      rethrow;
    } catch (e) {
      throw InvalidPacketException('Malformed CBOR: $e');
    }
    if (raw is! Map) {
      throw const InvalidPacketException('Top-level value must be a map');
    }

    const known = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
    for (final k in raw.keys) {
      if (k is! int || !known.contains(k)) {
        throw InvalidPacketException('Unknown or invalid map key: $k');
      }
    }

    final version = _uint(raw, 0);
    if (version != kProtocolVersion) {
      throw InvalidPacketException('Unsupported protocol version $version');
    }
    final type = PacketType.fromWire(_uint(raw, 1));
    if (type == null) {
      throw const InvalidPacketException('Unknown packet type');
    }
    final ttl = _uint(raw, 7);
    final hop = _uint(raw, 8);
    if (ttl > kMaxTtl || hop > kMaxTtl) {
      throw const InvalidPacketException('TTL / hop count out of range');
    }
    final payload = _bytes(raw, 9, max: kMaxPayloadBytes);
    return MeshPacket(
      version: version,
      type: type,
      messageId: _bytes(raw, 2, exact: kIdLength),
      senderId: _bytes(raw, 3, exact: kIdLength),
      destinationId: _optBytes(raw, 4, exact: kIdLength),
      roomId: _optBytes(raw, 5, exact: kIdLength),
      timestampMs: _uint(raw, 6),
      ttl: ttl,
      hopCount: hop,
      payload: payload,
      signature: _bytes(raw, 10, exact: 64),
      senderKeys: _optBytes(raw, 11, exact: 64),
    );
  }

  static int _uint(Map<dynamic, dynamic> m, int k) {
    final v = m[k];
    if (v is! int || v < 0) {
      throw InvalidPacketException('Field $k must be an unsigned integer');
    }
    return v;
  }

  static Uint8List _bytes(
    Map<dynamic, dynamic> m,
    int k, {
    int? exact,
    int? max,
  }) {
    final v = m[k];
    if (v is! List<int>) {
      throw InvalidPacketException('Field $k must be a byte string');
    }
    if (exact != null && v.length != exact) {
      throw InvalidPacketException('Field $k must be $exact bytes');
    }
    if (max != null && v.length > max) {
      throw InvalidPacketException('Field $k exceeds $max bytes');
    }
    return Uint8List.fromList(v);
  }

  static Uint8List? _optBytes(
    Map<dynamic, dynamic> m,
    int k, {
    required int exact,
  }) {
    if (!m.containsKey(k) || m[k] == null) return null;
    return _bytes(m, k, exact: exact);
  }
}
