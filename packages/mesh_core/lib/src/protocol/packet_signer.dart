import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../identity/local_identity.dart';
import 'mesh_packet.dart';
import 'packet_type.dart';

/// Builds and signs outgoing packets with the local Ed25519 key.
class PacketSigner {
  PacketSigner(this._identity, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LocalIdentity _identity;
  final int Function() _clock;

  Future<MeshPacket> create({
    required PacketType type,
    required Uint8List payload,
    Uint8List? destinationId,
    Uint8List? roomId,
    int ttl = kDefaultTtl,
    bool includeKeys = false,
    Uint8List? messageId,
  }) async {
    final id = messageId ?? randomBytes(kIdLength);
    final ts = _clock();
    final signature = await _identity.sign(MeshPacket.buildSigningBytes(
      version: kProtocolVersion,
      type: type,
      messageId: id,
      senderId: _identity.peerId,
      destinationId: destinationId,
      roomId: roomId,
      timestampMs: ts,
      payload: payload,
    ));
    return MeshPacket(
      type: type,
      messageId: id,
      senderId: _identity.peerId,
      destinationId: destinationId,
      roomId: roomId,
      timestampMs: ts,
      ttl: ttl,
      payload: payload,
      signature: signature,
      senderKeys: includeKeys
          ? concatBytes([
              _identity.public.signPublicKey,
              _identity.public.agreePublicKey,
            ])
          : null,
    );
  }
}
