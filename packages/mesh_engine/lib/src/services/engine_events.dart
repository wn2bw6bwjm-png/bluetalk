import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';

import '../storage/stores.dart';

/// The caller lacks the room permission for the requested change.
class PermissionDeniedException extends MeshException {
  const PermissionDeniedException(super.message);
}

/// Unknown room / channel / peer / message.
class NotFoundException extends MeshException {
  const NotFoundException(super.message);
}

/// Notifications for the UI layer. The UI re-reads from the stores; events
/// only say what changed.
sealed class EngineEvent {
  const EngineEvent();
}

class MessagesChanged extends EngineEvent {
  const MessagesChanged(this.kind, this.convId);
  final ConvKind kind;
  final Uint8List convId;
}

class MessageStatusChanged extends EngineEvent {
  const MessageStatusChanged(this.msgId);
  final Uint8List msgId;
}

class PeersChanged extends EngineEvent {
  const PeersChanged();
}

class RoomsChanged extends EngineEvent {
  const RoomsChanged(this.roomId);
  final Uint8List roomId;
}

/// Public rooms currently advertised by nearby peers changed.
class NearbyRoomsChanged extends EngineEvent {
  const NearbyRoomsChanged();
}

/// A message arrived that should raise a local notification (not from a
/// blocked sender, not in a muted conversation).
class IncomingNotification extends EngineEvent {
  const IncomingNotification({
    required this.title,
    required this.body,
    required this.kind,
    required this.convId,
  });
  final String title;
  final String body;
  final ConvKind kind;
  final Uint8List convId;
}

/// A nearby public room offered by a connected peer.
class NearbyRoom {
  const NearbyRoom(this.roomId, this.name, this.via);
  final Uint8List roomId;
  final String name;
  final PeerIdentity via;
}

class SearchResults {
  const SearchResults(this.peers, this.rooms, this.messages);
  final List<StoredPeer> peers;
  final List<(StoredRoom, StoredChannel?)> rooms;
  final List<SearchHit> messages;
  bool get isEmpty => peers.isEmpty && rooms.isEmpty && messages.isEmpty;
}

/// A BlueTalk device found by the radio that is not connected/identified yet.
class NearbyDevice {
  const NearbyDevice(this.linkId, this.rssi, this.seenAtMs);
  final String linkId;
  final int? rssi;
  final int seenAtMs;
}

/// The list of unidentified nearby devices changed.
class NearbyDevicesChanged extends EngineEvent {
  const NearbyDevicesChanged();
}
