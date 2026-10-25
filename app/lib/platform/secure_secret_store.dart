import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_core/mesh_core.dart';

/// Private keys live in the platform secure store: Android Keystore-backed
/// encrypted preferences / iOS Keychain. Nothing else ever holds them.
class SecureSecretStore implements SecretStore {
  SecureSecretStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          // Not synced to iCloud, readable only after first unlock.
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String key) async {
    final v = await _storage.read(key: key);
    return v == null ? null : base64Decode(v);
  }

  @override
  Future<void> write(String key, Uint8List value) =>
      _storage.write(key: key, value: base64Encode(value));

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
