import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../identity/local_identity.dart';
import '../identity/peer_identity.dart';

/// Result of sender-side key derivation.
class SendingKey {
  SendingKey(this.key, this.ephemeralPublicKey);
  final SecretKey key;

  /// Goes into the packet so the recipient can derive the same key.
  final Uint8List ephemeralPublicKey;
}

/// X25519 key agreement + HKDF-SHA256 (both from `package:cryptography`).
///
/// Scheme ("ephemeral-static" ECDH, as in libsodium sealed boxes / Noise `N`):
///
///   * Sender creates a fresh X25519 key pair for EVERY message.
///   * shared = X25519(ephemeralPriv, recipientAgreePub)
///   * key    = HKDF-SHA256(ikm: shared,
///                          salt: ephemeralPub ‖ recipientAgreePub,
///                          info: label ‖ senderId ‖ recipientId)
///
/// It needs no round trip, which is what store-and-forward to an offline
/// recipient requires. Sender authenticity comes from the Ed25519 packet
/// signature. Limitation (documented): no forward secrecy against later
/// compromise of the *recipient's* long-term X25519 key.
class KeyExchangeService {
  KeyExchangeService();

  final X25519 _x25519 = X25519();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  Future<SendingKey> deriveForSending({
    required PeerIdentity recipient,
    required Uint8List senderId,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephPub = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipient.agreePublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final key = await _expand(
      shared: Uint8List.fromList(await shared.extractBytes()),
      ephemeralPublicKey: Uint8List.fromList(ephPub.bytes),
      recipientAgreePublicKey: recipient.agreePublicKey,
      senderId: senderId,
      recipientId: recipient.peerId,
    );
    return SendingKey(key, Uint8List.fromList(ephPub.bytes));
  }

  Future<SecretKey> deriveForReceiving({
    required LocalIdentity me,
    required Uint8List ephemeralPublicKey,
    required Uint8List senderId,
  }) async {
    if (ephemeralPublicKey.length != 32) {
      throw const InvalidPacketException('Bad ephemeral key length');
    }
    final shared = await me.agree(ephemeralPublicKey);
    return _expand(
      shared: shared,
      ephemeralPublicKey: ephemeralPublicKey,
      recipientAgreePublicKey: me.public.agreePublicKey,
      senderId: senderId,
      recipientId: me.peerId,
    );
  }

  Future<SecretKey> _expand({
    required Uint8List shared,
    required Uint8List ephemeralPublicKey,
    required Uint8List recipientAgreePublicKey,
    required Uint8List senderId,
    required Uint8List recipientId,
  }) {
    // Low-order public keys make X25519 output all zeros: reject.
    if (shared.every((b) => b == 0)) {
      throw const InvalidPacketException('Degenerate key agreement');
    }
    return _hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: concatBytes([ephemeralPublicKey, recipientAgreePublicKey]),
      info: concatBytes([kKdfInfoDirect.codeUnits, senderId, recipientId]),
    );
  }
}
