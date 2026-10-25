import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';

import '../storage/database.dart';
import '../storage/stores.dart';
import 'engine_events.dart';

part 'engine_chat.dart';
part 'engine_rooms.dart';

/// Facade over everything stateful: it wires the [MeshNode] (radio, routing,
/// crypto) to SQLite storage, the persistent outbox, chats and rooms.
///
/// The UI talks only to this class and to the read-only stores it exposes; it
/// never touches Bluetooth, native APIs or SQL.
class MeshEngine {
  MeshEngine({
    required this.identity,
    required this.database,
    required List<PeerTransport> transports,
    String? displayName,
    this.status,
    this.bio,
    int Function()? clock,
    Duration? announceInterval = const Duration(seconds: 45),
    this.outboxInterval = const Duration(seconds: 20),
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        displayName = displayName {
    settings = SettingsStore(database);
    peers = PeerStore(database, clock: _clock);
    messages = MessageStore(database);
    outbox = OutboxStore(database);
    roomStore = RoomStore(database);
    _seen = SeenStore(database);
    _invites = InviteStore(database);

    directory = StoredPeerDirectory(peers);
    final guard = ReplayGuard(onAdmit: _seen.save)
      ..restore(_seen.load(_clock()), nowMs: _clock());
    session = SessionService(
      identity: identity,
      directory: directory,
      replayGuard: guard,
      clock: _clock,
    );
    node = MeshNode(
      session: session,
      transports: transports,
      displayName: displayName,
      status: status,
      bio: bio,
      announceInterval: announceInterval,
      senderFilter: (s) => !peers.isBlocked(s.peerId),
      advertProvider: _publicRoomAdverts,
    );
    _loadRooms();
  }

  final LocalIdentity identity;
  final MeshDatabase database;
  final String? displayName;
  final String? status;
  final String? bio;
  final Duration outboxInterval;
  final int Function() _clock;

  late final SettingsStore settings;
  late final PeerStore peers;
  late final MessageStore messages;
  late final OutboxStore outbox;
  late final RoomStore roomStore;
  late final StoredPeerDirectory directory;
  late final SessionService session;
  late final MeshNode node;
  late final SeenStore _seen;
  late final InviteStore _invites;

  final StreamController<EngineEvent> _events = StreamController.broadcast();
  StreamSubscription<MeshEvent>? _nodeSub;
  Timer? _outboxTimer;
  bool _flushing = false;
  bool _flushAgain = false;
  Completer<void>? _flushDone;
  bool _stopped = false;

  /// Live room logs (event sets) keyed by room-ID hex.
  final Map<String, RoomLog> _logs = {};

  /// Devices the radio saw but that are not connected yet.
  final Map<String, NearbyDevice> _devices = {};
  static const int deviceTtlMs = 30000;

  /// Unidentified devices seen in the last 30 s (their identity only becomes
  /// known after the connection and the signed announce).
  List<NearbyDevice> get nearbyDevices {
    final cutoff = _clock() - deviceTtlMs;
    _devices.removeWhere((_, d) => d.seenAtMs < cutoff);
    return _devices.values.toList()
      ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
  }

  /// Public rooms offered by connected peers: roomIdHex -> offer.
  final Map<String, NearbyRoom> _nearbyRooms = {};

  /// Rooms we asked to join (public join / invite): events from the peer we
  /// asked are accepted even though we are not a member yet.
  final Map<String, String> _pendingJoins = {};

  Stream<EngineEvent> get events => _events.stream;

  /// Live presence, straight from the radio layer.
  bool isConnected(Uint8List peerId) => node.isConnected(peerId);
  bool isReachable(Uint8List peerId) => node.isReachable(peerId);

  /// Transport of the direct link to [peerId] (null if not directly connected).
  TransportKind? transportOf(Uint8List peerId) =>
      node.directLink(peerId)?.transport;
  int get linkCount => node.linkCount;
  PeerIdentity get self => identity.public;
  int now() => _clock();

  void _emit(EngineEvent e) {
    if (!_events.isClosed && !_stopped) _events.add(e);
  }

  // ───────────────────────────── lifecycle ─────────────────────────────

  Future<void> start() async {
    _nodeSub = node.events.listen((e) => unawaited(_onNodeEvent(e)));
    await node.start();
    _outboxTimer = Timer.periodic(outboxInterval, (_) {
      _seen.prune(_clock());
      unawaited(maintainOutbox());
    });
    unawaited(flushOutbox());
  }

  Future<void> stop() async {
    _stopped = true;
    _outboxTimer?.cancel();
    final inFlight = _flushDone;
    if (_flushing && inFlight != null) await inFlight.future;
    await _nodeSub?.cancel();
    await node.stop();
    await _events.close();
  }

  // ─────────────────────────── node events ─────────────────────────────

  Future<void> _onNodeEvent(MeshEvent e) async {
    if (_stopped) return;
    try {
      switch (e) {
        case PeerOnline(
            :final identity,
            :final link,
            :final displayName,
            :final publicRooms,
            :final status,
            :final bio
          ):
          peers.upsert(identity, name: displayName, status: status, bio: bio);
          if (_devices.remove(link.value) != null) {
            _emit(const NearbyDevicesChanged());
          }
          _noteAdverts(identity, publicRooms);
          // A new direct link can open a route to ANYONE behind it (not only
          // to this neighbour), so wake the whole queue.
          outbox.releaseAll(_clock());
          _emit(const PeersChanged());
          unawaited(_syncRoomsWith(identity));
          unawaited(flushOutbox());
        case PeerReachable(
            :final identity,
            :final displayName,
            :final publicRooms,
            :final status,
            :final bio
          ):
          peers.upsert(identity, name: displayName, status: status, bio: bio);
          _noteAdverts(identity, publicRooms);
          outbox.releaseFor(identity.peerId, _clock());
          _emit(const PeersChanged());
          unawaited(flushOutbox());
        case DeviceSeen(:final link, :final rssi):
          final fresh = !_devices.containsKey(link.value);
          _devices[link.value] = NearbyDevice(link.value, rssi, _clock());
          if (fresh) _emit(const NearbyDevicesChanged());
        case PeerOffline():
          _emit(const PeersChanged());
        case MessageReceived(:final message):
          await _onIncoming(message);
        case MessageDelivered(:final messageId, :final by):
          if (outbox.acknowledge(messageId, by.peerId)) {
            _refreshStatus(messageId);
          }
        case RelayConfirmed(
            :final messageId,
            :final finalDestination,
            :final by
          ):
          // Only a DIRECT neighbour's attestation counts, and only for
          // messages we really have pending towards that destination.
          if (node.isConnected(by.peerId) &&
              outbox.markRelayed(messageId, finalDestination)) {
            _refreshStatus(messageId);
          }
        case PacketRelayed():
        case PacketDropped():
          break;
      }
    } on MeshException {
      // A bad/hostile message must never take the engine down.
    }
  }

  // ───────────────────────────── outbox ────────────────────────────────

  static Duration _backoff(int attempts) {
    final secs = 30 * (1 << (attempts > 6 ? 6 : attempts));
    return Duration(seconds: secs > 3600 ? 3600 : secs);
  }

  /// Sends everything that is due. Safe to call at any time and from many
  /// places; overlapping calls are coalesced.
  Future<void> flushOutbox() async {
    if (_stopped) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    _flushDone = Completer<void>();
    try {
      do {
        _flushAgain = false;
        final touched = <String, Uint8List>{};
        for (final row in outbox.due(_clock())) {
          if (_stopped) return;
          final recipient = directory.lookup(row.dest);
          if (recipient == null) {
            outbox.defer(row.id, _clock() + 60000);
            continue;
          }
          try {
            await node.sendContent(
              recipient,
              MessageContent.decode(row.content),
              messageId: row.msgId,
              roomId: row.roomId,
            );
            if (_stopped) return;
            outbox.recordAttempt(
              row.id,
              nextAttemptAt:
                  _clock() + _backoff(row.attempts + 1).inMilliseconds,
            );
          } on NoRouteException {
            if (_stopped) return;
            // Not reachable right now: retried when the peer shows up
            // (releaseFor) or by the periodic timer. Not counted as an attempt.
            outbox.defer(row.id, _clock() + outboxInterval.inMilliseconds);
          } on MeshException {
            if (_stopped) return;
            outbox.defer(row.id, _clock() + 300000);
          }
          if (row.tracked) touched[toHex(row.msgId)] = row.msgId;
        }
        for (final id in touched.values) {
          _refreshStatus(id);
        }
      } while (_flushAgain);
    } finally {
      _flushing = false;
      _flushDone?.complete();
    }
  }

  /// Expires overdue rows (status -> failed) and retries what is due.
  Future<void> maintainOutbox() async {
    for (final id in outbox.expire(_clock())) {
      _refreshStatus(id);
    }
    await flushOutbox();
  }

  void _refreshStatus(Uint8List msgId) {
    final s = outbox.statusOf(msgId);
    if (s == null) return;
    messages.setStatus(msgId, s);
    _emit(MessageStatusChanged(msgId));
  }

  void _enqueue({
    required Uint8List dest,
    required MessageContent content,
    Uint8List? msgId,
    Uint8List? roomId,
    bool tracked = false,
  }) {
    outbox.enqueue(
      msgId: msgId ?? randomBytes(kIdLength),
      dest: dest,
      roomId: roomId,
      content: content.encode(),
      tracked: tracked,
      nowMs: _clock(),
    );
  }
}
