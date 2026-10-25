import 'dart:typed_data';

import '../core/bytes_util.dart';
import 'local_identity.dart';
import 'secret_store.dart';

/// Creates, loads and (on explicit request) destroys the local identity.
///
/// First launch: generates fresh random seeds, derives both key pairs, stores
/// the seeds in the [SecretStore]. Later launches: loads them back, so the
/// peer ID is stable across restarts.
class IdentityService {
  IdentityService(this._store);

  static const String storageKey = 'mesh.identity.v1';

  final SecretStore _store;
  LocalIdentity? _cached;

  /// Returns the existing identity or creates one. Idempotent.
  Future<LocalIdentity> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    final stored = await _store.read(storageKey);
    if (stored != null && stored.length == 64) {
      final id = await LocalIdentity.fromSeeds(
        Uint8List.sublistView(stored, 0, 32),
        Uint8List.sublistView(stored, 32, 64),
      );
      return _cached = id;
    }

    final signSeed = randomBytes(32);
    final agreeSeed = randomBytes(32);
    final id = await LocalIdentity.fromSeeds(signSeed, agreeSeed);
    await _store.write(storageKey, concatBytes([signSeed, agreeSeed]));
    return _cached = id;
  }

  /// Irreversibly deletes the identity ("panic wipe" / reset). A new
  /// identity (new peer ID) is created on the next [loadOrCreate].
  Future<void> wipe() async {
    _cached = null;
    await _store.delete(storageKey);
  }
}
