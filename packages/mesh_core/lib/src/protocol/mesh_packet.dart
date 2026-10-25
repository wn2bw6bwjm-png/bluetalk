import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import 'packet_type.dart';

/// One protocol data unit.
///
/// Immutable fields (covered by the signature): version, type, messageId,
/// senderId, destinationId, roomId, timestamp, payload.
///
/// Mutable-in-transit fields (NOT signed, relays change them): [ttl] and
/// [hopCount]. Consequence: a malicious relay can shorten the lifetime of a
/// packet (denial of delivery) but cannot alter content or sender; this is
/// the standard trade-off of signed flooding and is documented in the README.
///
/// [senderKeys] (sign‖agree public keys, 64 bytes) is optional; it lets a
/// receiver that has never seen the sender verify the packet immediately.
/// It is authenticated indirectly: the sender ID must equal the hash of it.
class MeshPacket {
  MeshPacket({
    this.version = kProtocolVersion,
    required this.type,
    required this.messageId,
    required this.senderId,
    this.destinationId,
    this.roomId,
    required this.timestampMs,
    required this.ttl,
    this.hopCount = 0,
    required this.payload,
    required this.signature,
    this.senderKeys,
  });

  final int version;
  final PacketType type;
  final Uint8List messageId;
  final Uint8List senderId;

  /// `null` = broadcast (e.g. announce).
  final Uint8List? destinationId;

  /// Room / channel scope (used from the rooms stage on).
  final Uint8List? roomId;
  final int timestampMs;
  final int ttl;
  final int hopCount;
  final Uint8List payload;
  final Uint8List signature;
  final Uint8List? senderKeys;

  String get messageIdHex => toHex(messageId);
  bool get isBroadcast => destinationId == null;

  /// Copy as forwarded by a relay: one hop consumed.
  MeshPacket forwarded() => copyWith(ttl: ttl - 1, hopCount: hopCount + 1);

  MeshPacket copyWith({int? ttl, int? hopCount}) => MeshPacket(
        version: version,
        type: type,
        messageId: messageId,
        senderId: senderId,
        destinationId: destinationId,
        roomId: roomId,
        timestampMs: timestampMs,
        ttl: ttl ?? this.ttl,
        hopCount: hopCount ?? this.hopCount,
        payload: payload,
        signature: signature,
        senderKeys: senderKeys,
      );

  /// Canonical byte string that is signed / verified.
  ///
  /// Deliberately NOT CBOR: a fixed length-delimited layout has exactly one
  /// valid encoding, so signature verification never depends on a CBOR
  /// encoder's canonicalisation behaviour.
  ///
  /// Layout: domain ‖ version(1) ‖ type(1) ‖ messageId(16) ‖ senderId(16) ‖
  /// flags(1) ‖ [dest(16)] ‖ [room(16)] ‖ timestamp(8) ‖ payloadLen(4) ‖ payload
  Uint8List signingBytes() => buildSigningBytes(
        version: version,
        type: type,
        messageId: messageId,
        senderId: senderId,
        destinationId: destinationId,
        roomId: roomId,
        timestampMs: timestampMs,
        payload: payload,
      );

  static Uint8List buildSigningBytes({
    required int version,
    required PacketType type,
    required Uint8List messageId,
    required Uint8List senderId,
    required Uint8List? destinationId,
    required Uint8List? roomId,
    required int timestampMs,
    required Uint8List payload,
  }) {
    final flags = (destinationId != null ? 1 : 0) | (roomId != null ? 2 : 0);
    return concatBytes([
      kSignDomainPacket.codeUnits,
      [version, type.wire],
      messageId,
      senderId,
      [flags],
      if (destinationId != null) destinationId,
      if (roomId != null) roomId,
      u64(timestampMs),
      u32(payload.length),
      payload,
    ]);
  }

  /// Associated data for AEAD: binds the ciphertext to the packet header so a
  /// ciphertext cannot be re-wrapped into another packet.
  Uint8List aadBytes() => concatBytes([
        [version, type.wire],
        messageId,
        senderId,
        destinationId ?? Uint8List(0),
        u64(timestampMs),
      ]);

  @override
  bool operator ==(Object other) =>
      other is MeshPacket &&
      other.version == version &&
      other.type == type &&
      const ListEquality<int>().equals(other.messageId, messageId) &&
      const ListEquality<int>().equals(other.senderId, senderId) &&
      const ListEquality<int>().equals(other.destinationId, destinationId) &&
      const ListEquality<int>().equals(other.roomId, roomId) &&
      other.timestampMs == timestampMs &&
      other.ttl == ttl &&
      other.hopCount == hopCount &&
      const ListEquality<int>().equals(other.payload, payload) &&
      const ListEquality<int>().equals(other.signature, signature) &&
      const ListEquality<int>().equals(other.senderKeys, senderKeys);

  @override
  int get hashCode => Object.hash(
        type,
        const ListEquality<int>().hash(messageId),
        const ListEquality<int>().hash(senderId),
        timestampMs,
        ttl,
        hopCount,
      );

  @override
  String toString() =>
      'MeshPacket(${type.name} id=${messageIdHex.substring(0, 8)} '
      'ttl=$ttl hop=$hopCount)';
}
