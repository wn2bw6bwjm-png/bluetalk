import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';

import 'linked_transport.dart';
import 'sqlite_init.dart';

/// TEST-ONLY multi-device harness: real MeshEngine + real SQLite per node,
/// connected by in-memory links. Nothing here ships in the app.
class Node {
  Node(this.name, this.identity, this.db, this.transports, this.engine);
  final String name;
  final LocalIdentity identity;
  final MeshDatabase db;
  final List<LinkedTransport> transports;
  final MeshEngine engine;
  final List<EngineEvent> events = [];

  PeerIdentity get pub => identity.public;
  Uint8List get id => pub.peerId;
  List<T> of<T extends EngineEvent>() => events.whereType<T>().toList();
}

class Net {
  Net() {
    initSqliteForTests();
  }

  final Map<String, Node> nodes = {};
  final List<(String, String, LinkedTransport, LinkedTransport)> links = [];
  final Map<String, List<LinkedTransport>> _pending = {};

  void link(String a, String b) {
    final (x, y) = LinkedTransport.pair('$a>$b', '$b>$a');
    _pending.putIfAbsent(a, () => []).add(x);
    _pending.putIfAbsent(b, () => []).add(y);
    links.add((a, b, x, y));
  }

  Future<void> build({
    Set<String> names = const {},
    Map<String, (String, String)> profiles = const {},
  }) async {
    final all = {..._pending.keys, ...names};
    for (final n in all) {
      final id =
          await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
      final db = MeshDatabase.openInMemory();
      final ts = _pending[n] ?? <LinkedTransport>[];
      final engine = MeshEngine(
        identity: id,
        database: db,
        transports: ts,
        displayName: n,
        status: profiles[n]?.$1,
        bio: profiles[n]?.$2,
        announceInterval: null,
        outboxInterval: const Duration(hours: 1),
      );
      final node = Node(n, id, db, ts, engine);
      engine.events.listen(node.events.add);
      nodes[n] = node;
    }
    for (final n in nodes.values) {
      await n.engine.start();
    }
  }

  Node operator [](String n) => nodes[n]!;

  LinkedTransport _side(String a, String b) {
    for (final (x, y, tx, ty) in links) {
      if (x == a && y == b) return tx;
      if (x == b && y == a) return ty;
    }
    throw ArgumentError('no link $a-$b');
  }

  Future<void> connect(String a, String b) async {
    await _side(a, b).connect();
    await settle();
  }

  Future<void> disconnect(String a, String b) async {
    await _side(a, b).disconnect();
    await settle();
  }

  Future<void> connectAll() async {
    for (final (_, _, x, _) in links) {
      await x.connect();
    }
    await settle(80);
  }

  /// Teach [who] another node's identity (as scanning a contact invite does).
  void introduce(String who, String other) {
    this[who].engine.peers.upsert(this[other].pub, name: other);
    this[who].engine.directory.remember(this[other].pub);
  }

  Future<void> stop() async {
    for (final n in nodes.values) {
      await n.engine.stop();
      n.db.close();
    }
  }
}

Future<void> settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Polls until [cond] is true (the engine works asynchronously through
/// microtasks and timers); fails with [what] after [timeout].
Future<void> eventually(
  FutureOr<bool> Function() cond, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for $what');
}
