import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../identity/local_identity.dart';
import '../identity/peer_identity.dart';

enum RoomEventType {
  roomCreate(1),
  roomUpdate(2),
  roomDelete(3),
  channelCreate(4),
  channelUpdate(5),
  channelDelete(6),
  memberAdd(7),
  memberRemove(8),
  roleSet(9);

  const RoomEventType(this.wire);
  final int wire;

  static RoomEventType? fromWire(int v) {
    for (final t in RoomEventType.values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}

/// Field keys inside [RoomEvent.data].
class K {
  static const int nonce = 0; // roomCreate
  static const int name = 1;
  static const int description = 2;
  static const int icon = 3;
  static const int color = 4;
  static const int isPublic = 5;
  static const int channelId = 0; // channel events
  static const int peerId = 0; // member / role events
  static const int keys = 1; // memberAdd
  static const int role = 2; // memberAdd / roleSet(1)
}

/// One signed, immutable change to a room. A room is the deterministic replay
/// of its set of events (see `RoomState.replay`), which makes the state
/// converge on every device regardless of the order events arrive in.
///
/// The author signs a canonical byte layout (not CBOR) over: domain, id,
/// roomId, authorId, type, lamport, timestamp and the raw [dataBytes].
class RoomEvent {
  RoomEvent({
    required this.id,
    required this.roomId,
    required this.authorKeys,
    required this.type,
    required this.lamport,
    required this.timestampMs,
    required this.dataBytes,
    required this.signature,
  });

  static const String _domain = 'mesh/v1/room-event';
  static const int maxDataBytes = 2048;

  final Uint8List id;
  final Uint8List roomId;

  /// signPub ‖ agreePub (64 bytes); authorId is derived from them.
  final Uint8List authorKeys;
  final RoomEventType type;

  /// Logical clock: author's highest seen lamport + 1.
  final int lamport;
  final int timestampMs;

  /// CBOR-encoded map of the type-specific fields.
  final Uint8List dataBytes;
  final Uint8List signature;

  String get idHex => toHex(id);
  String get roomIdHex => toHex(roomId);

  Future<PeerIdentity> author() => PeerIdentity.fromPublicKeys(
        signPublicKey: Uint8List.sublistView(authorKeys, 0, 32),
        agreePublicKey: Uint8List.sublistView(authorKeys, 32, 64),
      );

  Map<int, Object?> get data {
    final raw = cbor.decode(dataBytes).toObject();
    if (raw is! Map) throw const InvalidPacketException('Bad event data');
    return {
      for (final e in raw.entries)
        if (e.key is int) e.key as int: e.value,
    };
  }

  static Uint8List encodeData(Map<int, Object?> data) {
    final out = Uint8List.fromList(cbor.encode(CborValue(data)));
    if (out.length > maxDataBytes) {
      throw const InvalidPacketException('Room event data too large');
    }
    return out;
  }

  Uint8List _signingBytes(Uint8List authorId) => concatBytes([
        _domain.codeUnits,
        id,
        roomId,
        authorId,
        [type.wire],
        u64(lamport),
        u64(timestampMs),
        u32(dataBytes.length),
        dataBytes,
      ]);

  static Future<RoomEvent> create({
    required LocalIdentity author,
    required Uint8List roomId,
    required RoomEventType type,
    required int lamport,
    required Map<int, Object?> data,
    int? timestampMs,
  }) async {
    final id = randomBytes(kIdLength);
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final dataBytes = encodeData(data);
    final keys = concatBytes(
        [author.public.signPublicKey, author.public.agreePublicKey]);
    final unsigned = RoomEvent(
      id: id,
      roomId: roomId,
      authorKeys: keys,
      type: type,
      lamport: lamport,
      timestampMs: ts,
      dataBytes: dataBytes,
      signature: Uint8List(64),
    );
    final sig = await author.sign(unsigned._signingBytes(author.peerId));
    return RoomEvent(
      id: id,
      roomId: roomId,
      authorKeys: keys,
      type: type,
      lamport: lamport,
      timestampMs: ts,
      dataBytes: dataBytes,
      signature: sig,
    );
  }

  /// Verifies that the signature belongs to the key embedded in the event.
  /// Returns the author's identity or throws [SignatureException].
  Future<PeerIdentity> verify() async {
    final a = await author();
    final ok = await a.verify(_signingBytes(a.peerId), signature);
    if (!ok) throw const SignatureException('Invalid room event signature');
    return a;
  }

  // ───────────────────────────── wire format ─────────────────────────────

  Uint8List encode() => Uint8List.fromList(cbor.encode(CborValue({
        0: id,
        1: roomId,
        2: authorKeys,
        3: type.wire,
        4: lamport,
        5: timestampMs,
        6: dataBytes,
        7: signature,
      })));

  static RoomEvent decode(Uint8List bytes) {
    if (bytes.length > kMaxPayloadBytes) {
      throw const InvalidPacketException('Room event too large');
    }
    final Object? raw;
    try {
      raw = cbor.decode(bytes).toObject();
    } catch (e) {
      throw InvalidPacketException('Malformed room event: $e');
    }
    if (raw is! Map) throw const InvalidPacketException('Event must be a map');
    final Map<dynamic, dynamic> m = raw;
    Uint8List b(int k, int len) {
      final v = m[k];
      if (v is! List<int> || (len >= 0 && v.length != len)) {
        throw InvalidPacketException('Bad event field $k');
      }
      return Uint8List.fromList(v);
    }

    int n(int k) {
      final v = m[k];
      if (v is! int || v < 0) {
        throw InvalidPacketException('Bad event field $k');
      }
      return v;
    }

    final type = RoomEventType.fromWire(n(3));
    if (type == null) throw const InvalidPacketException('Unknown event type');
    final data = b(6, -1);
    if (data.length > maxDataBytes) {
      throw const InvalidPacketException('Event data too large');
    }
    return RoomEvent(
      id: b(0, kIdLength),
      roomId: b(1, kIdLength),
      authorKeys: b(2, 64),
      type: type,
      lamport: n(4),
      timestampMs: n(5),
      dataBytes: data,
      signature: b(7, 64),
    );
  }

  /// Total order used for replay: lamport first, then event ID bytes.
  static int compare(RoomEvent a, RoomEvent b) {
    if (a.lamport != b.lamport) return a.lamport.compareTo(b.lamport);
    for (var i = 0; i < kIdLength; i++) {
      final d = a.id[i] - b.id[i];
      if (d != 0) return d;
    }
    return 0;
  }

  static Uint8List deriveRoomIdSync(Uint8List ownerId, Uint8List nonce) {
    final d = hash.sha256
        .convert(concatBytes(['mesh/v1/room-id'.codeUnits, ownerId, nonce]))
        .bytes;
    return Uint8List.fromList(d.sublist(0, kIdLength));
  }

  /// Deterministic room ID: only the creator can produce a valid create event
  /// for it, because it commits to the owner's peer ID.
  static Future<Uint8List> deriveRoomId(
      Uint8List ownerId, Uint8List nonce) async {
    final h = await Sha256().hash(
      concatBytes(['mesh/v1/room-id'.codeUnits, ownerId, nonce]),
    );
    return Uint8List.fromList(h.bytes.sublist(0, kIdLength));
  }
}
