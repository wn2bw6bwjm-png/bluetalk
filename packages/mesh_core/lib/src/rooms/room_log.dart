import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../identity/local_identity.dart';
import '../identity/peer_identity.dart';
import 'permissions.dart';
import 'room_event.dart';
import 'room_state.dart';

/// All known signed events of ONE room. Adding an event verifies its
/// signature; the materialised [state] is the deterministic replay.
class RoomLog {
  RoomLog(this.roomId, {this.maxEvents = defaultMaxEvents});

  /// Memory/DoS bound per room.
  static const int defaultMaxEvents = 5000;
  final int maxEvents;

  final Uint8List roomId;
  final Map<String, RoomEvent> _events = {};
  RoomState? _cache;

  Iterable<RoomEvent> get events => _events.values;
  Set<String> get ids => _events.keys.toSet();
  int get length => _events.length;

  RoomState get state => _cache ??= RoomState.replay(roomId, _events.values);

  /// Lamport value a new local event must use.
  int get nextLamport => state.maxLamport + 1;

  /// Verifies and stores [e]. Returns true when it was new. Throws
  /// [SignatureException] / [InvalidPacketException] for bad events, which
  /// callers must drop.
  Future<bool> add(RoomEvent e) async {
    if (!constantTimeEquals(e.roomId, roomId)) {
      throw const InvalidPacketException('Event belongs to another room');
    }
    if (_events.containsKey(e.idHex)) return false;
    if (_events.length >= maxEvents) {
      throw const InvalidPacketException('Room event log is full');
    }
    await e.verify();
    _events[e.idHex] = e;
    _cache = null;
    return true;
  }

  /// Adds an event that was already verified when it was first stored (used
  /// when reloading our own database, to avoid re-verifying every signature).
  /// NEVER use for data received from the network.
  void addTrusted(RoomEvent e) {
    if (constantTimeEquals(e.roomId, roomId) && _events.length < maxEvents) {
      _events[e.idHex] = e;
      _cache = null;
    }
  }

  /// Independent copy (used to evaluate incoming events before committing).
  RoomLog copy() {
    final c = RoomLog(roomId, maxEvents: maxEvents);
    for (final e in _events.values) {
      c.addTrusted(e);
    }
    return c;
  }

  /// Events the other side does not have (given the IDs it listed).
  List<RoomEvent> missingFrom(Set<String> theirIds) => [
        for (final e in _events.values)
          if (!theirIds.contains(e.idHex)) e
      ];

  /// IDs we lack out of [theirIds].
  Set<String> wantedFrom(Set<String> theirIds) =>
      theirIds.difference(_events.keys.toSet());
}

/// Creates properly formed events for the local user and records them in the
/// log. The reducer re-validates them like any foreign event, so a local user
/// without a permission simply produces an event that is rejected everywhere.
class RoomAuthor {
  RoomAuthor(this.me, this.log);

  final LocalIdentity me;
  final RoomLog log;

  static Future<RoomAuthor> createRoom(
    LocalIdentity me, {
    required String name,
    String description = '',
    String icon = '',
    int? color,
    bool isPublic = false,
    String? firstChannel = 'general',
  }) async {
    final nonce = randomBytes(kIdLength);
    final roomId = await RoomEvent.deriveRoomId(me.peerId, nonce);
    final author = RoomAuthor(me, RoomLog(roomId));
    await author._emit(RoomEventType.roomCreate, {
      K.nonce: nonce,
      K.name: name,
      K.description: description,
      K.icon: icon,
      if (color != null) K.color: color,
      K.isPublic: isPublic,
    });
    if (firstChannel != null) await author.addChannel(firstChannel);
    return author;
  }

  Future<RoomEvent> _emit(RoomEventType t, Map<int, Object?> data) async {
    final e = await RoomEvent.create(
      author: me,
      roomId: log.roomId,
      type: t,
      lamport: log.nextLamport,
      data: data,
    );
    await log.add(e);
    return e;
  }

  Future<RoomEvent> update({
    String? name,
    String? description,
    String? icon,
    int? color,
    bool? isPublic,
  }) =>
      _emit(RoomEventType.roomUpdate, {
        if (name != null) K.name: name,
        if (description != null) K.description: description,
        if (icon != null) K.icon: icon,
        if (color != null) K.color: color,
        if (isPublic != null) K.isPublic: isPublic,
      });

  Future<RoomEvent> deleteRoom() => _emit(RoomEventType.roomDelete, {});

  Future<RoomEvent> addChannel(
    String name, {
    String description = '',
    String icon = '',
    int? color,
    Uint8List? channelId,
  }) =>
      _emit(RoomEventType.channelCreate, {
        K.channelId: channelId ?? randomBytes(kIdLength),
        K.name: name,
        K.description: description,
        K.icon: icon,
        if (color != null) K.color: color,
      });

  Future<RoomEvent> updateChannel(
    Uint8List channelId, {
    String? name,
    String? description,
    String? icon,
    int? color,
  }) =>
      _emit(RoomEventType.channelUpdate, {
        K.channelId: channelId,
        if (name != null) K.name: name,
        if (description != null) K.description: description,
        if (icon != null) K.icon: icon,
        if (color != null) K.color: color,
      });

  Future<RoomEvent> deleteChannel(Uint8List channelId) =>
      _emit(RoomEventType.channelDelete, {K.channelId: channelId});

  static Uint8List _keys(PeerIdentity p) =>
      concatBytes([p.signPublicKey, p.agreePublicKey]);

  Future<RoomEvent> addMember(PeerIdentity who, {Role role = Role.member}) =>
      _emit(RoomEventType.memberAdd, {
        K.peerId: who.peerId,
        K.keys: _keys(who),
        K.role: role.wire,
      });

  /// Public rooms: the local user joins themselves.
  Future<RoomEvent> join() => addMember(me.public);

  Future<RoomEvent> removeMember(Uint8List peerId) =>
      _emit(RoomEventType.memberRemove, {K.peerId: peerId});

  Future<RoomEvent> leave() => removeMember(me.peerId);

  Future<RoomEvent> setRole(Uint8List peerId, Role role) =>
      _emit(RoomEventType.roleSet, {K.peerId: peerId, K.keys: role.wire});
}
