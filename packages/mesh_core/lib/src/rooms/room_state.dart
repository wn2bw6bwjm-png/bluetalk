import 'dart:typed_data';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../identity/peer_identity.dart';
import 'permissions.dart';
import 'room_event.dart';

class Channel {
  const Channel({
    required this.id,
    required this.name,
    this.description = '',
    this.icon = '',
    this.color,
  });

  final Uint8List id;
  final String name;
  final String description;
  final String icon;
  final int? color;

  String get idHex => toHex(id);

  Channel copyWith(
          {String? name, String? description, String? icon, int? color}) =>
      Channel(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        icon: icon ?? this.icon,
        color: color ?? this.color,
      );
}

class Member {
  const Member(this.identity, this.role);
  final PeerIdentity identity;
  final Role role;
  String get peerIdHex => identity.peerIdHex;
}

class RejectedEvent {
  const RejectedEvent(this.eventId, this.reason);
  final Uint8List eventId;
  final String reason;
  @override
  String toString() => '${toHex(eventId).substring(0, 8)}: $reason';
}

/// The materialised state of a room: the result of replaying its signed
/// event set in the total order (lamport, eventId).
///
/// Conflict resolution is therefore deterministic on every device:
///  * concurrent edits of the same field  -> the later event in the total
///    order wins (last-writer-wins, ties broken by event ID);
///  * an event is valid only if its author held the needed permission *at its
///    position in that order*, so backdating cannot bypass permissions and a
///    demotion that sorts before an action invalidates that action;
///  * invalid events are skipped (and listed in [rejected]) identically
///    everywhere.
class RoomState {
  RoomState._({
    required this.roomId,
    required this.ownerId,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    required this.isPublic,
    required this.deleted,
    required this.channels,
    required this.members,
    required this.rejected,
    required this.maxLamport,
    required this.exists,
  });

  final Uint8List roomId;
  final Uint8List? ownerId;
  final String name;
  final String description;
  final String icon;
  final int? color;
  final bool isPublic;
  final bool deleted;

  /// False until a valid roomCreate was applied.
  final bool exists;
  final Map<String, Channel> channels;
  final Map<String, Member> members;
  final List<RejectedEvent> rejected;
  final int maxLamport;

  String get roomIdHex => toHex(roomId);

  Role? roleOf(Uint8List peerId) => members[toHex(peerId)]?.role;
  bool isMember(Uint8List peerId) => members.containsKey(toHex(peerId));

  bool can(Uint8List peerId, Permission p) {
    if (deleted) return false;
    final r = roleOf(peerId);
    return r != null && permissionsOf(r).contains(p);
  }

  /// May [actor] post to [channelId]?
  bool canSend(Uint8List actor, Uint8List channelId) =>
      !deleted &&
      channels.containsKey(toHex(channelId)) &&
      can(actor, Permission.sendMessages);

  /// May [actor] delete a message written by [messageAuthor]?
  bool canDeleteMessage(Uint8List actor, Uint8List messageAuthor) {
    if (!isMember(actor)) return false;
    if (constantTimeEquals(actor, messageAuthor)) return true;
    return can(actor, Permission.deleteMessages);
  }

  static RoomState empty(Uint8List roomId) => RoomState._(
        roomId: roomId,
        ownerId: null,
        name: '',
        description: '',
        icon: '',
        color: null,
        isPublic: false,
        deleted: false,
        channels: const {},
        members: const {},
        rejected: const [],
        maxLamport: 0,
        exists: false,
      );

  /// Replays [events] (any order, duplicates ignored) into a state.
  static RoomState replay(Uint8List roomId, Iterable<RoomEvent> events) {
    final byId = <String, RoomEvent>{};
    for (final e in events) {
      if (toHex(e.roomId) == toHex(roomId)) byId[e.idHex] = e;
    }
    final sorted = byId.values.toList()..sort(RoomEvent.compare);

    final s = _Builder(roomId);
    for (final e in sorted) {
      s.maxLamport = e.lamport > s.maxLamport ? e.lamport : s.maxLamport;
      final reason = s.apply(e);
      if (reason != null) s.rejected.add(RejectedEvent(e.id, reason));
    }
    return s.build();
  }
}

class _Builder {
  _Builder(this.roomId);

  final Uint8List roomId;
  bool exists = false;
  bool deleted = false;
  Uint8List? ownerId;
  String name = '';
  String description = '';
  String icon = '';
  int? color;
  bool isPublic = false;
  int maxLamport = 0;
  final Map<String, Channel> channels = {};
  final Map<String, Member> members = {};
  final List<RejectedEvent> rejected = [];

  RoomState build() => RoomState._(
        roomId: roomId,
        ownerId: ownerId,
        name: name,
        description: description,
        icon: icon,
        color: color,
        isPublic: isPublic,
        deleted: deleted,
        channels: Map.unmodifiable(channels),
        members: Map.unmodifiable(members),
        rejected: List.unmodifiable(rejected),
        maxLamport: maxLamport,
        exists: exists,
      );

  Role? _role(String peerHex) => members[peerHex]?.role;

  bool _has(String peerHex, Permission p) {
    final r = _role(peerHex);
    return r != null && permissionsOf(r).contains(p);
  }

  static String? _str(Object? v, {int max = 64}) {
    if (v == null) return null;
    if (v is! String) return null;
    final c = v.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '').trim();
    return c.length > max ? c.substring(0, max) : c;
  }

  static bool _isId(Object? v) => v is List<int> && v.length == kIdLength;

  /// Returns null when applied, otherwise the rejection reason.
  String? apply(RoomEvent e) {
    final Map<int, Object?> d;
    try {
      d = e.data;
    } catch (_) {
      return 'unreadable data';
    }
    final authorId = PeerIdentity.derivePeerIdSync(e.authorKeys);
    final author = toHex(authorId);

    if (e.type == RoomEventType.roomCreate) return _create(e, d, authorId);
    if (!exists) return 'room not created yet';
    if (deleted) return 'room deleted';

    switch (e.type) {
      case RoomEventType.roomCreate:
        return 'unreachable';
      case RoomEventType.roomUpdate:
        if (!_has(author, Permission.manageRoom)) return 'no manageRoom';
        final n = _str(d[K.name]);
        if (n != null && n.isNotEmpty) name = n;
        description = _str(d[K.description], max: 256) ?? description;
        icon = _str(d[K.icon], max: 16) ?? icon;
        if (d[K.color] is int) color = d[K.color] as int;
        if (d[K.isPublic] is bool) isPublic = d[K.isPublic] as bool;
        return null;
      case RoomEventType.roomDelete:
        if (!_has(author, Permission.deleteRoom)) return 'no deleteRoom';
        deleted = true;
        return null;
      case RoomEventType.channelCreate:
        if (!_has(author, Permission.manageChannels)) {
          return 'no manageChannels';
        }
        if (!_isId(d[K.channelId])) return 'bad channel id';
        final id = Uint8List.fromList((d[K.channelId] as List).cast<int>());
        final n = _str(d[K.name]);
        if (n == null || n.isEmpty) return 'channel needs a name';
        if (channels.containsKey(toHex(id))) return 'channel exists';
        if (channels.length >= 32) return 'too many channels';
        channels[toHex(id)] = Channel(
          id: id,
          name: n,
          description: _str(d[K.description], max: 256) ?? '',
          icon: _str(d[K.icon], max: 16) ?? '',
          color: d[K.color] is int ? d[K.color] as int : null,
        );
        return null;
      case RoomEventType.channelUpdate:
        if (!_has(author, Permission.manageChannels)) {
          return 'no manageChannels';
        }
        if (!_isId(d[K.channelId])) return 'bad channel id';
        final key = toHex((d[K.channelId] as List).cast<int>());
        final ch = channels[key];
        if (ch == null) return 'unknown channel';
        final n = _str(d[K.name]);
        channels[key] = ch.copyWith(
          name: (n != null && n.isNotEmpty) ? n : null,
          description: _str(d[K.description], max: 256),
          icon: _str(d[K.icon], max: 16),
          color: d[K.color] is int ? d[K.color] as int : null,
        );
        return null;
      case RoomEventType.channelDelete:
        if (!_has(author, Permission.manageChannels)) {
          return 'no manageChannels';
        }
        if (!_isId(d[K.channelId])) return 'bad channel id';
        final key = toHex((d[K.channelId] as List).cast<int>());
        if (channels.remove(key) == null) return 'unknown channel';
        return null;
      case RoomEventType.memberAdd:
        return _memberAdd(e, d, author);
      case RoomEventType.memberRemove:
        return _memberRemove(d, author);
      case RoomEventType.roleSet:
        if (!_has(author, Permission.manageRoles)) return 'no manageRoles';
        if (!_isId(d[K.peerId])) return 'bad peer id';
        final target = toHex((d[K.peerId] as List).cast<int>());
        final m = members[target];
        if (m == null) return 'not a member';
        if (m.role == Role.owner) return 'cannot change owner';
        final r = d[K.keys] is int ? Role.fromWire(d[K.keys] as int) : null;
        if (r == null || r == Role.owner) return 'invalid role';
        members[target] = Member(m.identity, r);
        return null;
    }
  }

  String? _create(RoomEvent e, Map<int, Object?> d, Uint8List authorId) {
    if (exists) return 'room already created';
    final nonce = d[K.nonce];
    if (nonce is! List<int> || nonce.length != kIdLength) return 'bad nonce';
    final expected =
        RoomEvent.deriveRoomIdSync(authorId, Uint8List.fromList(nonce));
    if (!constantTimeEquals(expected, roomId)) {
      return 'roomId does not commit to author';
    }
    final n = _str(d[K.name]);
    if (n == null || n.isEmpty) return 'room needs a name';
    final identity = PeerIdentity.fromKeysSync(e.authorKeys);
    exists = true;
    ownerId = authorId;
    name = n;
    description = _str(d[K.description], max: 256) ?? '';
    icon = _str(d[K.icon], max: 16) ?? '';
    color = d[K.color] is int ? d[K.color] as int : null;
    isPublic = d[K.isPublic] == true;
    members[toHex(authorId)] = Member(identity, Role.owner);
    return null;
  }

  String? _memberAdd(RoomEvent e, Map<int, Object?> d, String author) {
    if (!_isId(d[K.peerId])) return 'bad peer id';
    final keys = d[K.keys];
    if (keys is! List<int> || keys.length != 64) return 'bad keys';
    final target = Uint8List.fromList((d[K.peerId] as List).cast<int>());
    final derived = PeerIdentity.derivePeerIdSync(Uint8List.fromList(keys));
    if (!constantTimeEquals(derived, target)) {
      return 'keys do not match peer id';
    }
    final targetHex = toHex(target);
    if (members.containsKey(targetHex)) return 'already a member';
    if (members.length >= 256) return 'room is full';
    final role = d[K.role] is int ? Role.fromWire(d[K.role] as int) : null;
    if (role == null || role == Role.owner) return 'invalid role';

    if (author == targetHex) {
      // Self-join: only public rooms, always as plain member.
      if (!isPublic) return 'room is private';
      if (role != Role.member) return 'self-join must be member';
    } else {
      if (!_has(author, Permission.manageMembers)) return 'no manageMembers';
      if (role == Role.admin && !_has(author, Permission.manageRoles)) {
        return 'no manageRoles';
      }
    }
    members[targetHex] =
        Member(PeerIdentity.fromKeysSync(Uint8List.fromList(keys)), role);
    return null;
  }

  String? _memberRemove(Map<int, Object?> d, String author) {
    if (!_isId(d[K.peerId])) return 'bad peer id';
    final target = toHex((d[K.peerId] as List).cast<int>());
    final m = members[target];
    if (m == null) return 'not a member';
    if (m.role == Role.owner) return 'owner cannot be removed or leave';
    if (author == target) {
      members.remove(target); // leave
      return null;
    }
    if (!_has(author, Permission.manageMembers)) return 'no manageMembers';
    final ar = _role(author)!;
    if (ar.rank <= m.role.rank) return 'cannot remove equal or higher rank';
    members.remove(target);
    return null;
  }
}
