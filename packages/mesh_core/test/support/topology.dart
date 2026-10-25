import 'dart:async';

import 'package:mesh_core/mesh_core.dart';

import 'fixtures.dart';
import 'linked_transport.dart';

/// TEST-ONLY: a named node plus its event log and transports.
class TNode {
  TNode(this.name, this.actor, this.node, this.transports) {
    node.events.listen(events.add);
  }
  final String name;
  final Actor actor;
  final MeshNode node;
  final List<LinkedTransport> transports;
  final List<MeshEvent> events = [];

  PeerIdentity get pub => actor.pub;
  List<T> of<T extends MeshEvent>() => events.whereType<T>().toList();

  /// All raw packets this node ever wrote to any neighbour.
  List<List<int>> get wire => [for (final t in transports) ...t.sent];
}

/// Builds nodes and wires them with in-memory links. Never shipped.
class Topology {
  final Map<String, TNode> nodes = {};
  final Map<String, List<LinkedTransport>> _pending = {};
  final List<(LinkedTransport, LinkedTransport)> links = [];

  /// Declare a link; endpoints are created lazily.
  void link(String a, String b) {
    final (x, y) = LinkedTransport.pair('$a>$b', '$b>$a');
    _pending.putIfAbsent(a, () => []).add(x);
    _pending.putIfAbsent(b, () => []).add(y);
    links.add((x, y));
  }

  Future<void> build({MeshRouter Function()? router}) async {
    for (final e in _pending.entries) {
      final actor = await makeActor();
      final node = MeshNode(
        session: actor.session,
        transports: e.value,
        displayName: e.key,
        router: router?.call(),
      );
      nodes[e.key] = TNode(e.key, actor, node, e.value);
    }
    for (final n in nodes.values) {
      await n.node.start();
    }
  }

  TNode operator [](String name) => nodes[name]!;

  /// Brings every link up and lets announces propagate.
  Future<void> connectAll() async {
    for (final (x, _) in links) {
      await x.connect();
    }
    await settle();
  }

  /// Teach [who] the public keys of [other] (as a QR/invite exchange would).
  void introduce(String who, String other) =>
      this[who].actor.directory.remember(this[other].pub);

  Future<void> stop() async {
    for (final n in nodes.values) {
      await n.node.stop();
    }
  }
}

/// Lets in-flight (microtask-scheduled) deliveries finish.
Future<void> settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
