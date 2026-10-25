import 'package:mesh_core/mesh_core.dart';

import 'memory_secret_store.dart';

/// A fully wired test participant.
class Actor {
  Actor(this.identity, this.session, this.directory);
  final LocalIdentity identity;
  final SessionService session;
  final InMemoryPeerDirectory directory;
  PeerIdentity get pub => identity.public;
}

Future<Actor> makeActor({int Function()? clock, ReplayGuard? replay}) async {
  final id = await IdentityService(MemorySecretStore()).loadOrCreate();
  final dir = InMemoryPeerDirectory();
  final session = SessionService(
    identity: id,
    directory: dir,
    clock: clock,
    replayGuard: replay,
  );
  return Actor(id, session, dir);
}
