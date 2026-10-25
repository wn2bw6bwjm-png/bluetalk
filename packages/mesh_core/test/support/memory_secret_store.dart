import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';

/// TEST-ONLY secret store. Production uses flutter_secure_storage.
class MemorySecretStore implements SecretStore {
  final Map<String, Uint8List> data = {};

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<Uint8List?> read(String key) async => data[key];

  @override
  Future<void> write(String key, Uint8List value) async =>
      data[key] = Uint8List.fromList(value);
}
