import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hash;

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';

/// Public half of an identity: what other peers learn and store.
///
/// The [peerId] is *derived* from both public keys, so a peer ID can never be
/// claimed together with somebody else's keys: anyone can recompute it.
class PeerIdentity {
  PeerIdentity._(this.signPublicKey, this.agreePublicKey, this.peerId);

  /// Builds a [PeerIdentity] and derives the peer ID. Both keys must be
  /// exactly 32 bytes.
  static Future<PeerIdentity> fromPublicKeys({
    required Uint8List signPublicKey,
    required Uint8List agreePublicKey,
  }) async {
    if (signPublicKey.length != 32 || agreePublicKey.length != 32) {
      throw const InvalidPacketException('Public keys must be 32 bytes');
    }
    final id = await derivePeerId(signPublicKey, agreePublicKey);
    return PeerIdentity._(
      Uint8List.fromList(signPublicKey),
      Uint8List.fromList(agreePublicKey),
      id,
    );
  }

  /// Synchronous variants for pure reducers (same math as the async ones).
  static Uint8List derivePeerIdSync(Uint8List keys64) {
    final d = hash.sha256
        .convert(concatBytes([kPeerIdDomain.codeUnits, keys64]))
        .bytes;
    return Uint8List.fromList(d.sublist(0, kIdLength));
  }

  static PeerIdentity fromKeysSync(Uint8List keys64) => PeerIdentity._(
        Uint8List.fromList(keys64.sublist(0, 32)),
        Uint8List.fromList(keys64.sublist(32, 64)),
        derivePeerIdSync(keys64),
      );

  /// Ed25519 public key (verifies signatures).
  final Uint8List signPublicKey;

  /// X25519 public key (receives end-to-end encrypted messages).
  final Uint8List agreePublicKey;

  /// 16-byte peer ID = SHA-256(domain || signPub || agreePub)[0..16].
  final Uint8List peerId;

  String get peerIdHex => toHex(peerId);

  /// Short human-readable ID, e.g. for UI lists.
  String get shortId => peerIdHex.substring(0, 8);

  /// Full SHA-256 over the public keys, formatted for out-of-band
  /// comparison ("A1B2 C3D4 ..."). Users compare this on both devices to
  /// authenticate each other (QR / reading aloud).
  Future<String> fingerprint() async {
    final h = await _fullHash(signPublicKey, agreePublicKey);
    final hex = toHex(h).toUpperCase();
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      groups.add(hex.substring(i, i + 4));
    }
    return groups.join(' ');
  }

  static Future<Uint8List> derivePeerId(
    Uint8List signPub,
    Uint8List agreePub,
  ) async {
    final h = await _fullHash(signPub, agreePub);
    return Uint8List.fromList(h.sublist(0, kIdLength));
  }

  static Future<List<int>> _fullHash(
    List<int> signPub,
    List<int> agreePub,
  ) async {
    final hash = await Sha256().hash(concatBytes([
      kPeerIdDomain.codeUnits,
      signPub,
      agreePub,
    ]));
    return hash.bytes;
  }

  /// Verifies an Ed25519 signature made by this identity.
  Future<bool> verify(List<int> message, List<int> signature) {
    return Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signPublicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PeerIdentity &&
      const ListEquality<int>().equals(peerId, other.peerId);

  @override
  int get hashCode => const ListEquality<int>().hash(peerId);

  @override
  String toString() => 'PeerIdentity($shortId)';
}
