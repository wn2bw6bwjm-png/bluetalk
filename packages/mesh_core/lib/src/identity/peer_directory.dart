import 'dart:typed_data';

import '../core/bytes_util.dart';
import 'peer_identity.dart';

/// Lookup of known peers' public identities (trust-on-first-use cache).
///
/// Because a peer ID is a hash of the public keys, a stored entry can never be
/// "swapped" by an attacker for the same ID — the only attack is the first
/// contact (TOFU), which users close by comparing fingerprints out of band.
abstract interface class PeerDirectory {
  PeerIdentity? lookup(Uint8List peerId);
  void remember(PeerIdentity identity);
  Iterable<PeerIdentity> get all;
}

/// In-memory implementation. The storage layer wraps/hydrates this from the
/// local database; the logic itself needs no I/O.
class InMemoryPeerDirectory implements PeerDirectory {
  final Map<String, PeerIdentity> _byId = {};

  @override
  PeerIdentity? lookup(Uint8List peerId) => _byId[toHex(peerId)];

  @override
  void remember(PeerIdentity identity) {
    _byId[identity.peerIdHex] = identity;
  }

  @override
  Iterable<PeerIdentity> get all => _byId.values;
}
