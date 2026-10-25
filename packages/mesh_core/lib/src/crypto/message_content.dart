import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../core/constants.dart';
import '../core/errors.dart';

/// Application payload carried inside an end-to-end encrypted packet
/// (CBOR map). The room/channel scope of a message is in the signed packet
/// header (`roomId`) plus [channelId] here.
///
/// Kinds 1-5 are user-visible chat operations; kinds 10-13 are control
/// messages used by rooms (sync, join). Unknown kinds are rejected, never
/// silently ignored.
class MessageContent {
  const MessageContent({
    this.kind = kindText,
    this.text = '',
    this.replyTo,
    this.channelId,
    this.targetId,
    this.add = true,
    this.blobs = const [],
  });

  const MessageContent.text(
    String text, {
    Uint8List? replyTo,
    Uint8List? channelId,
  }) : this(text: text, replyTo: replyTo, channelId: channelId);

  const MessageContent.reaction(
    Uint8List targetId,
    String emoji, {
    bool add = true,
    Uint8List? channelId,
  }) : this(
          kind: kindReaction,
          text: emoji,
          targetId: targetId,
          add: add,
          channelId: channelId,
        );

  const MessageContent.edit(
    Uint8List targetId,
    String newText, {
    Uint8List? channelId,
  }) : this(
          kind: kindEdit,
          text: newText,
          targetId: targetId,
          channelId: channelId,
        );

  const MessageContent.delete(Uint8List targetId, {Uint8List? channelId})
      : this(kind: kindDelete, targetId: targetId, channelId: channelId);

  /// Read receipt for the listed message IDs.
  const MessageContent.read(List<Uint8List> ids)
      : this(kind: kindRead, blobs: ids);

  /// Control message carrying opaque blobs (room events, sync ids…).
  const MessageContent.control(int kind, {List<Uint8List> blobs = const []})
      : this(kind: kind, blobs: blobs);

  static const int kindText = 1;
  static const int kindReaction = 2;
  static const int kindEdit = 3;
  static const int kindDelete = 4;
  static const int kindRead = 5;
  static const int kindRoomEvents = 10;
  static const int kindSyncOffer = 11;
  static const int kindSyncWant = 12;
  static const int kindJoinRequest = 13;

  static const Set<int> _kinds = {1, 2, 3, 4, 5, 10, 11, 12, 13};
  static const int maxTextChars = 8 * 1024;
  static const int maxBlobs = 64;

  final int kind;
  final String text;
  final Uint8List? replyTo;
  final Uint8List? channelId;
  final Uint8List? targetId;
  final bool add;
  final List<Uint8List> blobs;

  bool get isChatOperation => kind >= 1 && kind <= 5;

  Uint8List encode() => Uint8List.fromList(cbor.encode(CborValue({
        0: kind,
        if (text.isNotEmpty) 1: text,
        if (replyTo != null) 2: replyTo,
        if (channelId != null) 4: channelId,
        if (targetId != null) 5: targetId,
        if (kind == kindReaction) 6: add,
        if (blobs.isNotEmpty) 7: blobs,
      })));

  static MessageContent decode(Uint8List bytes) {
    final Object? raw;
    try {
      raw = cbor.decode(bytes).toObject();
    } catch (e) {
      throw DecryptionException('Malformed content: $e');
    }
    if (raw is! Map) throw const DecryptionException('Content must be a map');
    final Map<dynamic, dynamic> m = raw;
    final kind = m[0];
    if (kind is! int || !_kinds.contains(kind)) {
      throw const DecryptionException('Unsupported content kind');
    }
    final text = m[1] ?? '';
    if (text is! String || text.length > maxTextChars) {
      throw const DecryptionException('Invalid text');
    }
    Uint8List? id(int k) {
      final v = m[k];
      if (v == null) return null;
      if (v is List<int> && v.length == kIdLength) {
        return Uint8List.fromList(v);
      }
      throw DecryptionException('Invalid id in field $k');
    }

    final blobsRaw = m[7];
    final blobs = <Uint8List>[];
    if (blobsRaw != null) {
      if (blobsRaw is! List || blobsRaw.length > maxBlobs) {
        throw const DecryptionException('Invalid blobs');
      }
      for (final b in blobsRaw) {
        if (b is! List<int> || b.length > kMaxPayloadBytes) {
          throw const DecryptionException('Invalid blob');
        }
        blobs.add(Uint8List.fromList(b));
      }
    }
    final addRaw = m[6];
    if (addRaw != null && addRaw is! bool) {
      throw const DecryptionException('Invalid flag');
    }
    final c = MessageContent(
      kind: kind,
      text: text,
      replyTo: id(2),
      channelId: id(4),
      targetId: id(5),
      add: (addRaw as bool?) ?? true,
      blobs: blobs,
    );
    // Structural requirements per kind.
    if ((kind == kindReaction || kind == kindEdit || kind == kindDelete) &&
        c.targetId == null) {
      throw const DecryptionException('Missing target');
    }
    if (kind == kindReaction && c.text.isEmpty) {
      throw const DecryptionException('Empty reaction');
    }
    return c;
  }
}
