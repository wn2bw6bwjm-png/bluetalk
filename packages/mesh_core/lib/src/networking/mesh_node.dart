import 'dart:async';
import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../crypto/message_content.dart';
import '../crypto/session_service.dart';
import '../identity/peer_identity.dart';
import '../protocol/mesh_packet.dart';
import '../protocol/packet_codec.dart';
import '../protocol/packet_type.dart';
import 'mesh_router.dart';
import 'peer_transport.dart';

/// Events for the application layer.
sealed class MeshEvent {
  const MeshEvent();
}

/// A BlueTalk device was seen by the radio but is not (yet) connected or
/// identified. Its name and identity arrive in a signed announce after the
/// connection is up; until then only the link handle and signal are known.
class DeviceSeen extends MeshEvent {
  const DeviceSeen(this.link, this.rssi);
  final LinkId link;
  final int? rssi;
}

/// A directly connected (hop 0) authenticated neighbour.
class PeerOnline extends MeshEvent {
  const PeerOnline(
    this.identity,
    this.displayName,
    this.link, [
    this.publicRooms = const [],
    this.status,
    this.bio,
  ]);
  final PeerIdentity identity;
  final String? displayName;
  final LinkId link;
  final List<RoomAdvert> publicRooms;
  final String? status;
  final String? bio;
}

/// A peer learned through relays (not directly connected).
class PeerReachable extends MeshEvent {
  const PeerReachable(
    this.identity,
    this.displayName,
    this.hops, [
    this.publicRooms = const [],
    this.status,
    this.bio,
  ]);
  final PeerIdentity identity;
  final String? displayName;
  final int hops;
  final List<RoomAdvert> publicRooms;
  final String? status;
  final String? bio;
}

class PeerOffline extends MeshEvent {
  const PeerOffline(this.peerId);
  final Uint8List peerId;
}

class MessageReceived extends MeshEvent {
  const MessageReceived(this.message, {required this.hops});
  final OpenedMessage message;

  /// Relays the packet passed through (0 = direct).
  final int hops;
}

/// Emitted only when a cryptographically verified ack from the final
/// recipient arrived.
class MessageDelivered extends MeshEvent {
  const MessageDelivered(this.messageId, this.by);
  final Uint8List messageId;
  final PeerIdentity by;
}

/// A direct neighbour attested (signed receipt) that it verified and forwarded
/// our message [messageId] towards [finalDestination]. This is an attestation
/// by that neighbour, not proof that later hops forwarded it or that the
/// recipient got it - only [MessageDelivered] proves delivery.
class RelayConfirmed extends MeshEvent {
  const RelayConfirmed(this.messageId, this.finalDestination, this.by);
  final Uint8List messageId;
  final Uint8List finalDestination;
  final PeerIdentity by;
}

/// This node forwarded somebody else's packet (diagnostics / "Relayed").
class PacketRelayed extends MeshEvent {
  const PacketRelayed(this.packet, this.toLinks);
  final MeshPacket packet;
  final List<LinkId> toLinks;
}

/// A received packet was dropped (diagnostics; never shown as a message).
class PacketDropped extends MeshEvent {
  const PacketDropped(this.reason, this.link);
  final MeshException reason;
  final LinkId link;
}

/// Mesh node: direct delivery plus verified store-and-forward relaying.
///
/// Receive pipeline for every packet:
///   decode (strict) → by type:
///     announce        verify → learn route → (hop 0: PeerOnline | else
///                     PeerReachable) → forward while ttl > 0
///     direct/ack for us   open (verify, replay, decrypt) → learn route
///     direct/ack for others   RELAY: ttl > 0 → verify signature → dedupe →
///                     rate limit → forward to route link or flood (never back
///                     on the arrival link)
///
/// Relays never decrypt: they hold neither the recipient's private key nor
/// the ephemeral secret.
class MeshNode {
  MeshNode({
    required SessionService session,
    required List<PeerTransport> transports,
    String? displayName,
    MeshRouter? router,
    this.announceInterval,
    this.senderFilter,
    this.advertProvider,
    this.status,
    this.bio,
  })  : _session = session,
        _transports = transports,
        _displayName = displayName,
        _router = router ?? MeshRouter();

  final SessionService _session;
  final List<PeerTransport> _transports;
  final String? _displayName;
  final MeshRouter _router;

  /// Periodic re-announce so peers that connect later still learn us.
  /// `null` disables the timer (announce still happens on every new link).
  final Duration? announceInterval;

  /// Return false to drop a verified message from this sender without
  /// delivering or acknowledging it (used for blocked contacts).
  final bool Function(PeerIdentity sender)? senderFilter;

  /// Public rooms to advertise in announces.
  final List<RoomAdvert> Function()? advertProvider;

  /// Profile fields announced to neighbours (optional).
  final String? status;
  final String? bio;

  final PacketCodec _codec = const PacketCodec();
  final StreamController<MeshEvent> _events = StreamController.broadcast();
  final List<StreamSubscription<TransportEvent>> _subs = [];
  Timer? _announceTimer;

  /// Latest verified announce per peer, kept so a neighbour that connects
  /// later (late join) still learns peers that announced before it arrived.
  final Map<String, MeshPacket> _announceCache = {};
  static const int _maxAnnounceCache = 128;

  final Map<LinkId, PeerTransport> _transportOf = {};
  final Map<String, LinkId> _linkByPeer = {}; // direct neighbours
  final Map<LinkId, String> _peerByLink = {};

  Stream<MeshEvent> get events => _events.stream;
  SessionService get session => _session;
  MeshRouter get router => _router;

  /// True when [peerId] is an authenticated direct neighbour right now.
  bool isConnected(Uint8List peerId) => _linkByPeer.containsKey(toHex(peerId));

  /// The radio link of a direct neighbour (its transport kind is shown in the
  /// Nearby list), or null.
  LinkId? directLink(Uint8List peerId) => _linkByPeer[toHex(peerId)];

  /// True when a fresh route (direct or via relays) to [peerId] is known.
  bool isReachable(Uint8List peerId) =>
      isConnected(peerId) || _router.routeTo(peerId) != null;

  /// Number of established radio links (for status displays).
  int get linkCount => _transportOf.length;

  /// Currently established links (all transports).
  Iterable<LinkId> get links => _transportOf.keys;

  Future<void> start() async {
    for (final t in _transports) {
      _subs.add(t.events.listen((e) => unawaited(_onTransportEvent(t, e))));
      await t.start(advertisedName: _displayName);
    }
    final every = announceInterval;
    if (every != null) {
      _announceTimer = Timer.periodic(every, (_) => unawaited(announceNow()));
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final t in _transports) {
      await t.stop();
    }
    await _events.close();
  }

  /// Broadcasts a signed announce to all neighbours (ttl 1: neighbours relay
  /// it once, so peers two hops away learn this identity too).
  Future<void> announceNow() async {
    if (_transportOf.isEmpty) return;
    final announce = await _session.createAnnounce(
      displayName: _displayName,
      ttl: 1,
      publicRooms: advertProvider?.call() ?? const [],
      status: status,
      bio: bio,
    );
    _router.markOwn(announce);
    for (final link in _transportOf.keys.toList()) {
      await _safeWrite(link, announce);
    }
  }

  /// Sends an end-to-end encrypted text. Works for direct neighbours and, via
  /// relays, for any peer whose public keys are known (learned from an
  /// announce or exchanged out of band). Returns the message ID, used to
  /// correlate [MessageDelivered].
  Future<Uint8List> sendText(
    PeerIdentity recipient,
    String text, {
    Uint8List? replyTo,
    int ttl = kDefaultTtl,
  }) =>
      sendContent(
        recipient,
        MessageContent.text(text, replyTo: replyTo),
        ttl: ttl,
      );

  /// Sends any [MessageContent]. [messageId] lets callers retry the same
  /// logical message; [roomId] scopes it to a room (signed header field).
  Future<Uint8List> sendContent(
    PeerIdentity recipient,
    MessageContent content, {
    Uint8List? messageId,
    Uint8List? roomId,
    int ttl = kDefaultTtl,
  }) async {
    final packet = await _session.sealDirect(
      recipient: recipient,
      content: content,
      includeKeys: true, // relays need the keys to verify before forwarding
      ttl: ttl,
      messageId: messageId,
      roomId: roomId,
    );
    final targets = _router.targets(recipient.peerId, _transportOf.keys);
    if (targets.isEmpty) {
      throw const NoRouteException('No connected neighbours');
    }
    _router.markOwn(packet);
    var delivered = 0;
    for (final link in targets) {
      if (await _safeWrite(link, packet)) delivered++;
    }
    if (delivered == 0) {
      throw const NoRouteException('Could not write to any link');
    }
    return packet.messageId;
  }

  // ───────────────────────────── internals ───────────────────────────

  Future<bool> _safeWrite(LinkId link, MeshPacket p) async {
    final t = _transportOf[link];
    if (t == null) return false;
    try {
      await t.send(link, _codec.encode(p));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(MeshEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Future<void> _onTransportEvent(PeerTransport t, TransportEvent e) async {
    switch (e) {
      case PeerDiscovered(:final link, :final rssi):
        _emit(DeviceSeen(link, rssi));
      case LinkEstablished(:final link):
        _transportOf[link] = t;
        final announce = await _session.createAnnounce(
          displayName: _displayName,
          ttl: 1,
          publicRooms: advertProvider?.call() ?? const [],
          status: status,
          bio: bio,
        );
        _router.markOwn(announce);
        await _safeWrite(link, announce);
        await _shareCachedAnnounces(link);
      case LinkLost(:final link):
        _transportOf.remove(link);
        _router.forgetLink(link);
        final id = _peerByLink.remove(link);
        if (id != null) {
          _linkByPeer.remove(id);
          _emit(PeerOffline(fromHex(id)));
        }
      case PacketReceived(:final link, :final bytes):
        _transportOf.putIfAbsent(link, () => t);
        await _handleBytes(link, bytes);
    }
  }

  Future<void> _handleBytes(LinkId link, Uint8List bytes) async {
    try {
      await _handlePacket(link, _codec.decode(bytes));
    } on MeshException catch (e) {
      _emit(PacketDropped(e, link));
    }
  }

  void _cacheAnnounce(String peerHex, MeshPacket p) {
    if (_announceCache.length >= _maxAnnounceCache &&
        !_announceCache.containsKey(peerHex)) {
      _announceCache.remove(_announceCache.keys.first);
    }
    _announceCache[peerHex] = p;
  }

  /// Gives a newly connected neighbour the announces we already hold (one
  /// more hop each). Stale ones are skipped; the neighbour re-verifies them.
  Future<void> _shareCachedAnnounces(LinkId link) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final maxAge = const Duration(minutes: 9).inMilliseconds;
    for (final p in _announceCache.values.toList()) {
      if (p.ttl <= 0 || now - p.timestampMs > maxAge) continue;
      if (_peerByLink[link] == toHex(p.senderId)) continue;
      await _safeWrite(link, p.forwarded());
    }
  }

  bool _isForUs(MeshPacket p) {
    final d = p.destinationId;
    return d != null && constantTimeEquals(d, _session.self.peerId);
  }

  Future<void> _handlePacket(LinkId link, MeshPacket packet) async {
    switch (packet.type) {
      case PacketType.announce:
        final a = await _session.acceptAnnounce(packet);
        _cacheAnnounce(a.identity.peerIdHex, packet);
        _router.learn(a.identity.peerId, link, packet.hopCount + 1);
        if (packet.hopCount == 0) {
          // Only a hop-0 announce proves who is on THIS link.
          _linkByPeer[a.identity.peerIdHex] = link;
          _peerByLink[link] = a.identity.peerIdHex;
          _emit(PeerOnline(
              a.identity, a.displayName, link, a.publicRooms, a.status, a.bio));
        } else {
          _emit(PeerReachable(a.identity, a.displayName, packet.hopCount,
              a.publicRooms, a.status, a.bio));
        }
        if (packet.ttl > 0) {
          await _forward(packet, arrival: link, toAll: true);
        }
      case PacketType.directMessage:
        if (!_isForUs(packet)) return _relay(link, packet);
        // Blocked senders are dropped BEFORE the packet is admitted to the
        // replay cache or acknowledged in any way (neither a first delivery
        // nor a retry may ever produce an ack for them).
        final filter = senderFilter;
        if (filter != null) {
          final who = await _session.authenticate(packet);
          if (!filter(who)) {
            throw const BlockedException('Sender is blocked');
          }
        }
        final OpenedMessage opened;
        try {
          opened = await _session.openDirect(packet);
        } on ReplayException {
          // Duplicate of a message we already accepted (its signature was
          // verified inside openDirect first). The sender is likely retrying
          // because our ack was lost: acknowledge again, deliver nothing.
          await _reAck(link, packet);
          rethrow;
        }
        _router.learn(packet.senderId, link, packet.hopCount + 1);
        _emit(MessageReceived(opened, hops: packet.hopCount));
        // Ack travels back along the arrival link (the reverse path).
        final ack = await _session.createAck(opened);
        _router.markOwn(ack);
        await _safeWrite(link, ack);
      case PacketType.relayReceipt:
        // Hop-by-hop attestation: only accepted from the direct neighbour that
        // sent it, never forwarded.
        if (!_isForUs(packet)) {
          throw const NotForUsException('Receipts are not forwarded');
        }
        final sender = _peerByLink[link];
        if (sender == null || sender != toHex(packet.senderId)) {
          throw const SignatureException('Receipt not from the link neighbour');
        }
        final (id, finalDest, relay) =
            await _session.acceptRelayReceipt(packet);
        _emit(RelayConfirmed(id, finalDest, relay));
      case PacketType.ack:
        if (!_isForUs(packet)) return _relay(link, packet);
        final id = await _session.acceptAck(packet);
        _router.learn(packet.senderId, link, packet.hopCount + 1);
        final by = _session.directory.lookup(packet.senderId)!;
        _emit(MessageDelivered(id, by));
    }
  }

  Future<void> _reAck(LinkId link, MeshPacket packet) async {
    try {
      final ack = await _session.createAckFor(
        packet.messageId,
        packet.senderId,
      );
      await _safeWrite(link, ack);
    } on MeshException {
      // best effort
    }
  }

  /// Forward somebody else's direct message / ack.
  Future<void> _relay(LinkId arrival, MeshPacket packet) async {
    if (packet.ttl <= 0) {
      throw const TtlExpiredException('TTL exhausted');
    }
    // Authenticate BEFORE amplifying anything; junk dies here.
    final sender = await _session.authenticate(packet);
    _router.admitForRelay(packet); // duplicates / stale
    _router.learn(sender.peerId, arrival, packet.hopCount + 1);
    _router.checkRate(arrival);
    final sentTo = await _forward(packet, arrival: arrival, toAll: false);
    if (sentTo.isNotEmpty && packet.type == PacketType.directMessage) {
      await _sendRelayReceipt(arrival, packet);
    }
  }

  /// Tells the neighbour we got the packet from that we verified and forwarded
  /// it. Best effort; failure never affects forwarding.
  Future<void> _sendRelayReceipt(LinkId arrival, MeshPacket packet) async {
    final neighbour = _peerByLink[arrival];
    final finalDest = packet.destinationId;
    if (neighbour == null || finalDest == null) return;
    try {
      final receipt = await _session.createRelayReceipt(
        messageId: packet.messageId,
        finalDestination: finalDest,
        toNeighbor: fromHex(neighbour),
      );
      await _safeWrite(arrival, receipt);
    } on MeshException {
      // ignore
    }
  }

  Future<List<LinkId>> _forward(
    MeshPacket packet, {
    required LinkId arrival,
    required bool toAll,
  }) async {
    final onward = packet.forwarded();
    final List<LinkId> targets;
    if (toAll || packet.destinationId == null) {
      targets = _transportOf.keys.where((l) => l != arrival).toList();
    } else {
      targets = _router.targets(
        packet.destinationId!,
        _transportOf.keys,
        arrival: arrival,
      );
    }
    final sentTo = <LinkId>[];
    for (final l in targets) {
      if (await _safeWrite(l, onward)) sentTo.add(l);
    }
    if (sentTo.isNotEmpty && packet.type != PacketType.announce) {
      _emit(PacketRelayed(onward, sentTo));
    }
    return sentTo;
  }
}
