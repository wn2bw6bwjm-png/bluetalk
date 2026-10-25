import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/errors.dart';
import 'encryption_service.dart';

/// Binary layout of the `payload` field of a direct-message packet:
///
///   ephemeralPublicKey (32) ‖ nonce (12) ‖ cipherText (n) ‖ mac (16)
///
/// Relays treat this as opaque bytes.
class SealedPayload {
  SealedPayload(this.ephemeralPublicKey, this.blob);

  final Uint8List ephemeralPublicKey;
  final EncryptedBlob blob;

  static const int minLength =
      32 + EncryptionService.nonceLength + EncryptionService.macLength;

  Uint8List encode() => concatBytes([
        ephemeralPublicKey,
        blob.nonce,
        blob.cipherText,
        blob.mac,
      ]);

  static SealedPayload decode(Uint8List bytes) {
    if (bytes.length < minLength) {
      throw const InvalidPacketException('Sealed payload too short');
    }
    const n = EncryptionService.nonceLength;
    const m = EncryptionService.macLength;
    return SealedPayload(
      Uint8List.fromList(bytes.sublist(0, 32)),
      EncryptedBlob(
        Uint8List.fromList(bytes.sublist(32, 32 + n)),
        Uint8List.fromList(bytes.sublist(32 + n, bytes.length - m)),
        Uint8List.fromList(bytes.sublist(bytes.length - m)),
      ),
    );
  }
}
