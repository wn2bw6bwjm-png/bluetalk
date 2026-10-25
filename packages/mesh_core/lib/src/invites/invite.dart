import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../identity/local_identity.dart';
import '../identity/peer_identity.dart';

enum InviteKind {
  /// "Here is my identity" - lets another device encrypt to you right away.
  contact(1),

  /// Invitation to join a room.
  room(2);

  const InviteKind(this.wire);
  final int wire;
  static InviteKind? fromWire(int v) {
    for (final k in InviteKind.values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// A signed, serverless invitation, passed as a QR code or text
/// (`mesh1:<base64url CBOR>`), by hand or over a nearby connection.
///
/// It proves *who* issued it (Ed25519 over a domain-separated layout) and until
/// when it is valid. It grants nothing by itself: the issuer's device checks
/// when it is redeemed that the issuer still has the right to add members and
/// that the single-use [nonce] was not used before.
class Invite {
  Invite({
    required this.kind,
    required this.inviterKeys,
    required this.name,
    required this.expiresAtMs,
    required this.nonce,
    required this.signature,
    this.roomId,
    this.roomName,
  });

  static const String scheme = 'mesh1:';
  static const String _domain = 'mesh/v1/invite';
  static const int maxEncodedLength = 1200; // comfortably fits one QR code

  final InviteKind kind;

  /// signPub ‖ agreePub of the issuer.
  final Uint8List inviterKeys;
  final String name;
  final Uint8List? roomId;
  final String? roomName;
  final int expiresAtMs;
  final Uint8List nonce;
  final Uint8List signature;

  String get nonceHex => toHex(nonce);
  PeerIdentity get inviter => PeerIdentity.fromKeysSync(inviterKeys);

  static Uint8List _signing({
    required InviteKind kind,
    required Uint8List keys,
    required String name,
    required Uint8List? roomId,
    required String? roomName,
    required int expiresAtMs,
    required Uint8List nonce,
  }) {
    List<int> lp(String s) {
      final b = utf8.encode(s);
      return [...u16(b.length), ...b];
    }

    return concatBytes([
      _domain.codeUnits,
      [kind.wire],
      keys,
      lp(name),
      [roomId != null ? 1 : 0],
      if (roomId != null) roomId,
      lp(roomName ?? ''),
      u64(expiresAtMs),
      nonce,
    ]);
  }

  static Future<Invite> create({
    required LocalIdentity issuer,
    required InviteKind kind,
    required String name,
    Duration validFor = const Duration(hours: 24),
    Uint8List? roomId,
    String? roomName,
    int? nowMs,
  }) async {
    if (kind == InviteKind.room && roomId == null) {
      throw ArgumentError('Room invites need a roomId');
    }
    final keys = concatBytes(
        [issuer.public.signPublicKey, issuer.public.agreePublicKey]);
    final expires = (nowMs ?? DateTime.now().millisecondsSinceEpoch) +
        validFor.inMilliseconds;
    final nonce = randomBytes(kIdLength);
    final cleanName = _clean(name, 32);
    final cleanRoom = roomName == null ? null : _clean(roomName, 64);
    final sig = await issuer.sign(_signing(
      kind: kind,
      keys: keys,
      name: cleanName,
      roomId: roomId,
      roomName: cleanRoom,
      expiresAtMs: expires,
      nonce: nonce,
    ));
    return Invite(
      kind: kind,
      inviterKeys: keys,
      name: cleanName,
      roomId: roomId,
      roomName: cleanRoom,
      expiresAtMs: expires,
      nonce: nonce,
      signature: sig,
    );
  }

  static String _clean(String s, int max) {
    final c = s.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '').trim();
    return c.length > max ? c.substring(0, max) : c;
  }

  /// Checks signature and expiry. Returns the issuer's identity.
  Future<PeerIdentity> verify({int? nowMs}) async {
    final who = inviter;
    final ok = await who.verify(
      _signing(
        kind: kind,
        keys: inviterKeys,
        name: name,
        roomId: roomId,
        roomName: roomName,
        expiresAtMs: expiresAtMs,
        nonce: nonce,
      ),
      signature,
    );
    if (!ok) throw const SignatureException('Invalid invite signature');
    if ((nowMs ?? DateTime.now().millisecondsSinceEpoch) > expiresAtMs) {
      throw const ReplayException('Invite expired');
    }
    return who;
  }

  // ─────────────────────────────── encoding ───────────────────────────────

  Uint8List toBytes() => Uint8List.fromList(cbor.encode(CborValue({
        0: kind.wire,
        1: inviterKeys,
        2: name,
        if (roomId != null) 3: roomId,
        if (roomName != null) 4: roomName,
        5: expiresAtMs,
        6: nonce,
        7: signature,
      })));

  /// `mesh1:` + unpadded base64url. Suitable for a QR code or copy/paste.
  String toText() =>
      '$scheme${base64Url.encode(toBytes()).replaceAll('=', '')}';

  static Invite fromBytes(Uint8List bytes) {
    final Object? raw;
    try {
      raw = cbor.decode(bytes).toObject();
    } catch (e) {
      throw InvalidPacketException('Malformed invite: $e');
    }
    if (raw is! Map) throw const InvalidPacketException('Invite must be a map');
    final Map<dynamic, dynamic> m = raw;
    Uint8List b(int k, int len) {
      final v = m[k];
      if (v is! List<int> || v.length != len) {
        throw InvalidPacketException('Bad invite field $k');
      }
      return Uint8List.fromList(v);
    }

    final kind = m[0] is int ? InviteKind.fromWire(m[0] as int) : null;
    if (kind == null) throw const InvalidPacketException('Unknown invite kind');
    final name = m[2];
    if (name is! String || name.length > 32) {
      throw const InvalidPacketException('Bad invite name');
    }
    final roomName = m[4];
    if (roomName != null && (roomName is! String || roomName.length > 64)) {
      throw const InvalidPacketException('Bad room name');
    }
    final exp = m[5];
    if (exp is! int || exp < 0) {
      throw const InvalidPacketException('Bad expiry');
    }
    final roomId = m.containsKey(3) ? b(3, kIdLength) : null;
    if (kind == InviteKind.room && roomId == null) {
      throw const InvalidPacketException('Room invite without room');
    }
    return Invite(
      kind: kind,
      inviterKeys: b(1, 64),
      name: name,
      roomId: roomId,
      roomName: roomName as String?,
      expiresAtMs: exp,
      nonce: b(6, kIdLength),
      signature: b(7, 64),
    );
  }

  /// Like [fromText] but returns null instead of throwing (for chat bubbles
  /// that merely want to know whether a message carries an invite).
  static Invite? tryFromText(String text) {
    final t = text.trim();
    if (!t.startsWith(scheme)) return null;
    try {
      return fromText(t);
    } on MeshException {
      return null;
    }
  }

  static Invite fromText(String text) {
    final t = text.trim();
    if (!t.startsWith(scheme) || t.length > maxEncodedLength) {
      throw const InvalidPacketException('Not a mesh invite');
    }
    final body = t.substring(scheme.length);
    try {
      final padded = body.padRight((body.length + 3) ~/ 4 * 4, '=');
      return fromBytes(Uint8List.fromList(base64Url.decode(padded)));
    } on FormatException {
      throw const InvalidPacketException('Invite is not valid base64url');
    }
  }
}
