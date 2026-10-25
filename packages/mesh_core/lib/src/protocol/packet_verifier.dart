import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/errors.dart';
import '../identity/peer_directory.dart';
import '../identity/peer_identity.dart';
import 'mesh_packet.dart';

/// Authenticates the sender of a packet.
///
/// Steps: (1) obtain the sender's public keys — embedded in the packet or from
/// the [PeerDirectory]; (2) check that `senderId` equals the ID derived from
/// those keys; (3) verify the Ed25519 signature over the canonical bytes.
///
/// Relays also run this before forwarding, so unauthenticated junk is never
/// amplified through the mesh.
class PacketVerifier {
  PacketVerifier(this._directory);

  final PeerDirectory _directory;

  Future<PeerIdentity> verify(MeshPacket packet) async {
    final PeerIdentity sender;
    final keys = packet.senderKeys;
    if (keys != null) {
      final candidate = await PeerIdentity.fromPublicKeys(
        signPublicKey: Uint8List.sublistView(keys, 0, 32),
        agreePublicKey: Uint8List.sublistView(keys, 32, 64),
      );
      if (!constantTimeEquals(candidate.peerId, packet.senderId)) {
        throw const SignatureException('senderId does not match public keys');
      }
      sender = candidate;
    } else {
      final known = _directory.lookup(packet.senderId);
      if (known == null) {
        throw const UnknownSenderException('No public keys for sender');
      }
      sender = known;
    }

    final ok = await sender.verify(packet.signingBytes(), packet.signature);
    if (!ok) throw const SignatureException('Invalid signature');
    return sender;
  }
}
