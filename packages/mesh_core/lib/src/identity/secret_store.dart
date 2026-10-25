import 'dart:typed_data';

/// Storage for private key material.
///
/// Production implementation (Flutter app): `flutter_secure_storage`
/// (Android Keystore-backed EncryptedSharedPreferences / iOS Keychain).
/// The core never writes private keys anywhere else.
abstract interface class SecretStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> delete(String key);
}
