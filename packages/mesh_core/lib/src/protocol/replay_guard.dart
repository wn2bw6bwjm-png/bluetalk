import 'dart:collection';

import '../core/bytes_util.dart';
import '../core/errors.dart';
import 'mesh_packet.dart';
import 'packet_type.dart';

/// Replay and duplicate protection.
///
/// A packet is admitted at most once per (senderId, messageId). Entries are
/// kept until the packet would be rejected for age anyway, so within the
/// accepted time window *every* replay is detected; outside it the timestamp
/// check rejects the packet. If the cache hits [maxEntries] the oldest entry
/// is evicted (bounded memory under flooding) — documented residual risk:
/// an attacker that can push [maxEntries] distinct valid packets inside the
/// window could re-admit an evicted one. Per-peer rate limiting (router stage)
/// bounds that.
///
/// Call only AFTER the signature was verified, so unauthenticated traffic can
/// never fill or poison the cache.
class ReplayGuard {
  ReplayGuard({
    this.maxFutureSkew = const Duration(minutes: 5),
    this.maxAgeDirect = const Duration(hours: 24),
    this.maxAgeEphemeral = const Duration(minutes: 10),
    this.maxEntries = 50000,
    this.perAttempt = false,
    this.onAdmit,
  });

  /// Tolerated clock skew into the future (devices have no shared clock).
  final Duration maxFutureSkew;

  /// Store-and-forward messages may legitimately arrive hours later.
  final Duration maxAgeDirect;

  /// Announces/acks are only meaningful when fresh.
  final Duration maxAgeEphemeral;
  final int maxEntries;

  /// When true the key also contains the packet timestamp, so a *retry* of
  /// the same logical message (same ID, fresh timestamp) is admitted while an
  /// exact copy is still a duplicate. Relays use this; final recipients do
  /// not (they must see each message ID once and re-acknowledge retries).
  final bool perAttempt;

  /// Called after a packet was admitted, with (key, expiryMs). The engine
  /// persists these so replay protection survives an app restart.
  final void Function(String key, int expiresAtMs)? onAdmit;

  /// Reloads persisted entries (call once at startup). Expired ones are
  /// ignored.
  void restore(Map<String, int> entries, {required int nowMs}) {
    for (final e in entries.entries) {
      if (e.value > nowMs) _seen[e.key] = e.value;
    }
  }

  String _key(MeshPacket p) => perAttempt
      ? '${toHex(p.senderId)}:${p.messageIdHex}:${p.timestampMs}'
      : '${toHex(p.senderId)}:${p.messageIdHex}';

  // Insertion-ordered: oldest first.
  final LinkedHashMap<String, int> _seen = LinkedHashMap();

  int get size => _seen.length;

  Duration _maxAge(PacketType t) =>
      t == PacketType.directMessage ? maxAgeDirect : maxAgeEphemeral;

  /// Throws [ReplayException] for stale, future-dated or already-seen
  /// packets; otherwise records the packet and returns normally.
  void admit(MeshPacket p, {required int nowMs}) {
    final maxAgeMs = _maxAge(p.type).inMilliseconds;
    if (p.timestampMs > nowMs + maxFutureSkew.inMilliseconds) {
      throw const ReplayException('Timestamp too far in the future');
    }
    if (nowMs - p.timestampMs > maxAgeMs) {
      throw const ReplayException('Packet too old');
    }

    _prune(nowMs);
    final key = _key(p);
    if (_seen.containsKey(key)) {
      throw const ReplayException('Duplicate packet');
    }
    if (_seen.length >= maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    // Remember until the moment the packet would be rejected as too old.
    final expiry = p.timestampMs + maxAgeMs;
    _seen[key] = expiry;
    onAdmit?.call(key, expiry);
  }

  /// Non-mutating duplicate probe (used by routers to drop before verifying).
  bool hasSeen(MeshPacket p) => _seen.containsKey(_key(p));

  void _prune(int nowMs) {
    // Expiry times are not monotonic in insertion order, so scan a bounded
    // prefix; entries beyond it are cleaned on later calls.
    var scanned = 0;
    final expired = <String>[];
    for (final e in _seen.entries) {
      if (scanned++ > 256) break;
      if (e.value < nowMs) expired.add(e.key);
    }
    expired.forEach(_seen.remove);
  }
}
