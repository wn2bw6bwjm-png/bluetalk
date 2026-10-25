import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../core/bytes_util.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../identity/local_identity.dart';
import '../identity/peer_directory.dart';
import '../identity/peer_identity.dart';
import '../protocol/mesh_packet.dart';
import '../protocol/packet_signer.dart';
import '../protocol/packet_type.dart';
import '../protocol/packet_verifier.dart';
import '../protocol/replay_guard.dart';
import 'encryption_service.dart';
import 'key_exchange_service.dart';
import 'message_content.dart';
import 'sealed_payload.dart';

/// A verified, decrypted direct message.
class OpenedMessage {
  OpenedMessage({
    required this.messageId,
    required this.sender,
    required this.content,
    required this.timestampMs,
    this.roomId,
  });
  final Uint8List? roomId;
  final Uint8List messageId;
  final PeerIdentity sender;
  final MessageContent content;
  final int timestampMs;
}

/// A verified identity announcement.
class Announcement {
  Announcement(
    this.identity,
    this.displayName, [
    this.publicRooms = const [],
    this.status,
    this.bio,
  ]);
  final PeerIdentity identity;
  final String? displayName;

  /// Optional short status line and bio the peer chose to share (<=64 / <=200
  /// chars, control characters stripped).
  final String? status;
  final String? bio;

  /// Public rooms the announcer offers to join (id + name only).
  final List<RoomAdvert> publicRooms;
}

/// A public room advertised inside an announce. Contains no member data.
class RoomAdvert {
  const RoomAdvert(this.roomId, this.name);
  final Uint8List roomId;
  final String name;
}

/// Orchestrates one device's secure messaging:
///
///   seal:  encrypt (KeyExchange + Encryption) → sign (PacketSigner)
///   open:  check destination → verify signature → replay admit → decrypt
///
/// Order on receive is deliberate: cheap checks first, signature before the
/// replay cache is touched (no cache poisoning by forgeries), AEAD last.
class SessionService {
  SessionService({
    required LocalIdentity identity,
    required PeerDirectory directory,
    KeyExchangeService? keyExchange,
    EncryptionService? encryption,
    ReplayGuard? replayGuard,
    int Function()? clock,
  })  : _identity = identity,
        _directory = directory,
        _keyExchange = keyExchange ?? KeyExchangeService(),
        _encryption = encryption ?? EncryptionService(),
        _replay = replayGuard ?? ReplayGuard(),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _signer = PacketSigner(identity, clock: clock),
        _verifier = PacketVerifier(directory);

  final LocalIdentity _identity;
  final PeerDirectory _directory;
  final KeyExchangeService _keyExchange;
  final EncryptionService _encryption;
  final ReplayGuard _replay;
  final int Function() _clock;
  final PacketSigner _signer;
  final PacketVerifier _verifier;

  static const int maxDisplayNameLength = 32;

  PeerIdentity get self => _identity.public;
  ReplayGuard get replayGuard => _replay;
  PeerDirectory get directory => _directory;

  /// Authenticates the sender of any packet WITHOUT consuming it (no replay
  /// admission, no decryption). Relays use this before forwarding.
  Future<PeerIdentity> authenticate(MeshPacket packet) =>
      _verifier.verify(packet);

  // ───────────────────────── direct messages ─────────────────────────

  /// [messageId] lets the outbox retry the SAME logical message (same ID, new
  /// timestamp) so receivers and acks can correlate it. [roomId] scopes the
  /// packet to a room (covered by the signature).
  Future<MeshPacket> sealDirect({
    required PeerIdentity recipient,
    required MessageContent content,
    int ttl = kDefaultTtl,
    bool includeKeys = false,
    Uint8List? messageId,
    Uint8List? roomId,
  }) async {
    final sending = await _keyExchange.deriveForSending(
      recipient: recipient,
      senderId: _identity.peerId,
    );

    // The AAD must be known before encryption, but it contains the message ID
    // and timestamp, so we fix those first and build the packet around them.
    final id = messageId ?? randomBytes(kIdLength);
    final timestamp = _clock();
    final aad = _aad(
      type: PacketType.directMessage,
      messageId: id,
      senderId: _identity.peerId,
      destinationId: recipient.peerId,
      timestampMs: timestamp,
    );

    final blob = await _encryption.encrypt(
      plaintext: content.encode(),
      key: sending.key,
      aad: aad,
    );
    final payload = SealedPayload(sending.ephemeralPublicKey, blob).encode();
    if (payload.length > kMaxPayloadBytes) {
      throw const InvalidPacketException('Message too large');
    }

    // Use the same clock value that went into the AAD.
    return PacketSigner(_identity, clock: () => timestamp).create(
      type: PacketType.directMessage,
      payload: payload,
      destinationId: recipient.peerId,
      roomId: roomId,
      ttl: ttl,
      includeKeys: includeKeys,
      messageId: id,
    );
  }

  Future<OpenedMessage> openDirect(MeshPacket packet) async {
    _expectType(packet, PacketType.directMessage);
    final dest = packet.destinationId;
    if (dest == null || !constantTimeEquals(dest, _identity.peerId)) {
      throw const NotForUsException('Packet is addressed to another peer');
    }
    final sender = await _verifier.verify(packet);
    _replay.admit(packet, nowMs: _clock());
    _directory.remember(sender);

    final sealed = SealedPayload.decode(packet.payload);
    final key = await _keyExchange.deriveForReceiving(
      me: _identity,
      ephemeralPublicKey: sealed.ephemeralPublicKey,
      senderId: packet.senderId,
    );
    final clear = await _encryption.decrypt(
      blob: sealed.blob,
      key: key,
      aad: packet.aadBytes(),
    );
    return OpenedMessage(
      messageId: packet.messageId,
      sender: sender,
      content: MessageContent.decode(clear),
      timestampMs: packet.timestampMs,
      roomId: packet.roomId,
    );
  }

  // ───────────────────────────── announce ────────────────────────────

  static const int maxAdverts = 3;
  static const int maxStatusLength = 64;
  static const int maxBioLength = 200;

  Future<MeshPacket> createAnnounce({
    String? displayName,
    int ttl = 2,
    List<RoomAdvert> publicRooms = const [],
    String? status,
    String? bio,
  }) {
    final name = _sanitizeName(displayName);
    final st = _sanitizeText(status, maxStatusLength);
    final bi = _sanitizeText(bio, maxBioLength);
    final payload = Uint8List.fromList(
      cbor.encode(CborValue({
        0: name,
        if (st != null) 2: st,
        if (bi != null) 3: bi,
        if (publicRooms.isNotEmpty)
          1: [
            for (final r in publicRooms.take(maxAdverts))
              [r.roomId, _sanitizeName(r.name) ?? ''],
          ],
      })),
    );
    return _signer.create(
      type: PacketType.announce,
      payload: payload,
      ttl: ttl,
      includeKeys: true,
    );
  }

  Future<Announcement> acceptAnnounce(MeshPacket packet) async {
    _expectType(packet, PacketType.announce);
    if (packet.senderKeys == null) {
      throw const InvalidPacketException('Announce must carry public keys');
    }
    final sender = await _verifier.verify(packet);
    _replay.admit(packet, nowMs: _clock());

    String? name;
    String? status;
    String? bio;
    final rooms = <RoomAdvert>[];
    try {
      final raw = cbor.decode(packet.payload).toObject();
      if (raw is Map) {
        if (raw[0] is String) name = _sanitizeName(raw[0] as String);
        if (raw[2] is String) {
          status = _sanitizeText(raw[2] as String, maxStatusLength);
        }
        if (raw[3] is String) {
          bio = _sanitizeText(raw[3] as String, maxBioLength);
        }
        final list = raw[1];
        if (list is List) {
          for (final item in list.take(maxAdverts)) {
            if (item is List &&
                item.length == 2 &&
                item[0] is List<int> &&
                (item[0] as List<int>).length == kIdLength &&
                item[1] is String) {
              rooms.add(RoomAdvert(
                Uint8List.fromList(item[0] as List<int>),
                _sanitizeName(item[1] as String) ?? '',
              ));
            }
          }
        }
      }
    } catch (_) {
      throw const InvalidPacketException('Malformed announce payload');
    }
    _directory.remember(sender);
    return Announcement(sender, name, rooms, status, bio);
  }

  // ─────────────────────────────── ack ───────────────────────────────

  /// Signed receipt for [original]; only the final recipient creates one, so
  /// "Delivered" is only ever shown on a cryptographically verified ack.
  Future<MeshPacket> createAck(OpenedMessage original) {
    return _signer.create(
      type: PacketType.ack,
      payload: original.messageId,
      destinationId: original.sender.peerId,
    );
  }

  /// Ack for a message ID we already processed (the first ack may have been
  /// lost). Only call after the duplicate's signature was verified.
  Future<MeshPacket> createAckFor(Uint8List messageId, Uint8List senderPeerId) {
    return _signer.create(
      type: PacketType.ack,
      payload: messageId,
      destinationId: senderPeerId,
    );
  }

  /// Receipt (to the neighbour [toNeighbor]) that THIS node verified and
  /// forwarded the packet [messageId] addressed to [finalDestination].
  Future<MeshPacket> createRelayReceipt({
    required Uint8List messageId,
    required Uint8List finalDestination,
    required Uint8List toNeighbor,
  }) {
    return _signer.create(
      type: PacketType.relayReceipt,
      payload: concatBytes([messageId, finalDestination]),
      destinationId: toNeighbor,
      ttl: 0, // never relayed
    );
  }

  /// Verifies a relay receipt addressed to us. Returns (messageId,
  /// finalDestination, relay).
  Future<(Uint8List, Uint8List, PeerIdentity)> acceptRelayReceipt(
      MeshPacket packet) async {
    _expectType(packet, PacketType.relayReceipt);
    final dest = packet.destinationId;
    if (dest == null || !constantTimeEquals(dest, _identity.peerId)) {
      throw const NotForUsException('Receipt is addressed to another peer');
    }
    if (packet.payload.length != 2 * kIdLength) {
      throw const InvalidPacketException('Bad receipt payload');
    }
    final relay = await _verifier.verify(packet);
    _replay.admit(packet, nowMs: _clock());
    return (
      Uint8List.fromList(packet.payload.sublist(0, kIdLength)),
      Uint8List.fromList(packet.payload.sublist(kIdLength)),
      relay,
    );
  }

  /// Returns the ID of the message that was acknowledged.
  Future<Uint8List> acceptAck(MeshPacket packet) async {
    _expectType(packet, PacketType.ack);
    final dest = packet.destinationId;
    if (dest == null || !constantTimeEquals(dest, _identity.peerId)) {
      throw const NotForUsException('Ack is addressed to another peer');
    }
    if (packet.payload.length != kIdLength) {
      throw const InvalidPacketException('Bad ack payload');
    }
    await _verifier.verify(packet);
    _replay.admit(packet, nowMs: _clock());
    return packet.payload;
  }

  // ───────────────────────────── helpers ─────────────────────────────

  void _expectType(MeshPacket p, PacketType t) {
    if (p.type != t) {
      throw InvalidPacketException('Expected ${t.name}, got ${p.type.name}');
    }
  }

  static Uint8List _aad({
    required PacketType type,
    required Uint8List messageId,
    required Uint8List senderId,
    required Uint8List destinationId,
    required int timestampMs,
  }) =>
      // Must stay byte-identical to MeshPacket.aadBytes().
      concatBytes([
        [kProtocolVersion, type.wire],
        messageId,
        senderId,
        destinationId,
        u64(timestampMs),
      ]);

  static String? _sanitizeText(String? raw, int max) {
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '').trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
  }

  static String? _sanitizeName(String? raw) {
    if (raw == null) return null;
    // Strip control characters, trim, cap length.
    final cleaned = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '').trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > maxDisplayNameLength
        ? cleaned.substring(0, maxDisplayNameLength)
        : cleaned;
  }
}
