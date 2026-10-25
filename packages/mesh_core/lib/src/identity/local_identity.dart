import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'peer_identity.dart';

/// The device's own identity: two key pairs plus the derived public identity.
///
/// * Ed25519 — signs every packet (authentication, integrity).
/// * X25519 — receives end-to-end encrypted messages.
///
/// Instances are created only by `IdentityService`; private seeds never leave
/// this object except through [exportSeeds] (used solely to persist into the
/// `SecretStore`).
class LocalIdentity {
  LocalIdentity._(this._signKeyPair, this._agreeKeyPair, this.public);

  static Future<LocalIdentity> fromSeeds(
    Uint8List signSeed,
    Uint8List agreeSeed,
  ) async {
    if (signSeed.length != 32 || agreeSeed.length != 32) {
      throw ArgumentError('Seeds must be 32 bytes');
    }
    final sign = await Ed25519().newKeyPairFromSeed(signSeed);
    final agree = await X25519().newKeyPairFromSeed(agreeSeed);
    final signPub = await sign.extractPublicKey();
    final agreePub = await agree.extractPublicKey();
    final identity = await PeerIdentity.fromPublicKeys(
      signPublicKey: Uint8List.fromList(signPub.bytes),
      agreePublicKey: Uint8List.fromList(agreePub.bytes),
    );
    return LocalIdentity._(sign, agree, identity);
  }

  final SimpleKeyPair _signKeyPair;
  final SimpleKeyPair _agreeKeyPair;

  /// Public, shareable half.
  final PeerIdentity public;

  Uint8List get peerId => public.peerId;

  /// Signs [message] with the Ed25519 private key.
  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _signKeyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// X25519 key agreement with a remote public key. Returns the raw shared
  /// secret (must be run through HKDF before use as a key).
  Future<Uint8List> agree(List<int> remoteAgreePublicKey) async {
    final secret = await X25519().sharedSecretKey(
      keyPair: _agreeKeyPair,
      remotePublicKey: SimplePublicKey(
        remoteAgreePublicKey,
        type: KeyPairType.x25519,
      ),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  /// Exposes the private seeds for persistence in the secure store ONLY.
  Future<({Uint8List signSeed, Uint8List agreeSeed})> exportSeeds() async {
    return (
      signSeed: Uint8List.fromList(await _signKeyPair.extractPrivateKeyBytes()),
      agreeSeed:
          Uint8List.fromList(await _agreeKeyPair.extractPrivateKeyBytes()),
    );
  }
}
