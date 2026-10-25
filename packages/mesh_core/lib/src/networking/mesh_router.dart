import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/errors.dart';
import '../protocol/mesh_packet.dart';
import '../protocol/replay_guard.dart';
import 'peer_transport.dart';

/// A learned way to reach a peer.
class RouteEntry {
  RouteEntry(this.link, this.hops, this.learnedAtMs);
  final LinkId link;

  /// Hops to the destination (1 = direct neighbour).
  final int hops;
  final int learnedAtMs;
}

/// Store-and-forward routing decisions. Pure logic, no I/O.
///
/// Strategy: **signed controlled flooding with a route cache**.
///  * A relay forwards a packet only after verifying its signature, and only
///    once: duplicates are detected per (senderId, messageId).
///  * Never forwards back on the link it arrived on; with the duplicate cache
///    this prevents routing loops (A→B→A, triangles).
///  * Each forward consumes one TTL; packets with ttl 0 are not forwarded.
///  * If a route to the destination was learned from verified traffic
///    (announce or earlier packets) the packet goes to that one link; otherwise
///    it is flooded to all other links.
///  * Per-arrival-link token bucket limits how much one neighbour can make us
///    transmit.
///
/// Limitations (documented): flooding costs airtime in dense networks; routes
/// are soft state (expire after [routeTtl]) and are learned from
/// *authenticated* senders only, but a relay can still lie about hop counts.
class MeshRouter {
  MeshRouter({
    int Function()? clock,
    this.routeTtl = const Duration(minutes: 5),
    this.maxRoutes = 512,
    this.ratePerSecond = 20,
    this.burst = 40,
    ReplayGuard? seen,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _seen = seen ?? ReplayGuard(perAttempt: true);

  final int Function() _clock;
  final Duration routeTtl;
  final int maxRoutes;
  final double ratePerSecond;
  final int burst;

  final ReplayGuard _seen;
  final Map<String, RouteEntry> _routes = {};
  final Map<LinkId, _Bucket> _buckets = {};

  int get routeCount => _routes.length;

  /// Remember a packet we originated so that when it comes back around a loop
  /// it is recognised and dropped.
  void markOwn(MeshPacket p) {
    try {
      _seen.admit(p, nowMs: _clock());
    } on ReplayException {
      // already known: fine
    }
  }

  /// Duplicate / age check for a packet we are about to relay. Throws
  /// [ReplayException] when it was already relayed (or is stale).
  void admitForRelay(MeshPacket p) => _seen.admit(p, nowMs: _clock());

  /// Records that [peerId] is reachable through [link] in [hops] hops. Call
  /// only with data from verified packets.
  void learn(Uint8List peerId, LinkId link, int hops) {
    final key = toHex(peerId);
    final now = _clock();
    final existing = _routes[key];
    // Keep a strictly better (shorter) fresh route; refresh equal ones.
    if (existing != null &&
        now - existing.learnedAtMs < routeTtl.inMilliseconds &&
        existing.hops < hops) {
      return;
    }
    if (!_routes.containsKey(key) && _routes.length >= maxRoutes) {
      final oldest = _routes.entries
          .reduce((a, b) => a.value.learnedAtMs <= b.value.learnedAtMs ? a : b);
      _routes.remove(oldest.key);
    }
    _routes[key] = RouteEntry(link, hops, now);
  }

  RouteEntry? routeTo(Uint8List peerId) {
    final e = _routes[toHex(peerId)];
    if (e == null) return null;
    if (_clock() - e.learnedAtMs > routeTtl.inMilliseconds) {
      _routes.remove(toHex(peerId));
      return null;
    }
    return e;
  }

  /// A link went down: forget every route through it.
  void forgetLink(LinkId link) {
    _routes.removeWhere((_, e) => e.link == link);
    _buckets.remove(link);
  }

  /// Links the packet should be sent on. [arrival] is excluded (loop
  /// protection); null for locally originated packets.
  List<LinkId> targets(
    Uint8List destination,
    Iterable<LinkId> allLinks, {
    LinkId? arrival,
  }) {
    final usable = allLinks.where((l) => l != arrival).toList();
    final route = routeTo(destination);
    if (route != null && usable.contains(route.link)) return [route.link];
    return usable;
  }

  /// Token bucket per arrival link. Throws [RateLimitedException] when empty.
  void checkRate(LinkId arrival) {
    final now = _clock();
    final b =
        _buckets.putIfAbsent(arrival, () => _Bucket(burst.toDouble(), now));
    final elapsed = (now - b.at) / 1000.0;
    b.tokens = (b.tokens + elapsed * ratePerSecond).clamp(0, burst.toDouble());
    b.at = now;
    if (b.tokens < 1) {
      throw const RateLimitedException('Forwarding rate limit exceeded');
    }
    b.tokens -= 1;
  }
}

class _Bucket {
  _Bucket(this.tokens, this.at);
  double tokens;
  int at;
}
