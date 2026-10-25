import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/errors.dart';

/// ChaCha20-Poly1305 (RFC 8439) AEAD from `package:cryptography`.
/// Nothing custom: this class only wires inputs and normalises errors.
class EncryptionService {
  EncryptionService();

  final Chacha20 _aead = Chacha20.poly1305Aead();

  static const int nonceLength = 12;
  static const int macLength = 16;

  Future<EncryptedBlob> encrypt({
    required List<int> plaintext,
    required SecretKey key,
    required List<int> aad,
  }) async {
    // A fresh random 96-bit nonce per message. Keys are single-use anyway
    // (ephemeral DH per message), so nonce reuse under one key cannot occur.
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: _aead.newNonce(),
      aad: aad,
    );
    return EncryptedBlob(
      Uint8List.fromList(box.nonce),
      Uint8List.fromList(box.cipherText),
      Uint8List.fromList(box.mac.bytes),
    );
  }

  Future<Uint8List> decrypt({
    required EncryptedBlob blob,
    required SecretKey key,
    required List<int> aad,
  }) async {
    try {
      final clear = await _aead.decrypt(
        SecretBox(blob.cipherText, nonce: blob.nonce, mac: Mac(blob.mac)),
        secretKey: key,
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const DecryptionException('Authentication failed');
    }
  }
}

class EncryptedBlob {
  EncryptedBlob(this.nonce, this.cipherText, this.mac);
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;
}
