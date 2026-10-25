import 'dart:typed_data';

/// Physical/link technology behind a [PeerTransport].
enum TransportKind {
  /// Bluetooth Low Energy (GATT). Android + iOS, cross-platform.
  ble,

  /// Apple Multipeer Connectivity. iOS ↔ iOS only.
  multipeer,

  /// Android Wi-Fi Aware / Wi-Fi Direct class transports. Android ↔ Android.
  wifiDirect,
}

/// Opaque handle of a connected neighbour on one transport. Only meaningful
/// to the transport that produced it.
class LinkId {
  const LinkId(this.transport, this.value);
  final TransportKind transport;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is LinkId && other.transport == transport && other.value == value;

  @override
  int get hashCode => Object.hash(transport, value);

  @override
  String toString() => '${transport.name}:$value';
}

/// Events a transport reports upward. Transports never interpret packets.
sealed class TransportEvent {
  const TransportEvent();
}

/// A nearby device was seen (not necessarily connected).
class PeerDiscovered extends TransportEvent {
  const PeerDiscovered(this.link, {this.advertisedName, this.rssi});
  final LinkId link;
  final String? advertisedName;
  final int? rssi;
}

/// A bidirectional byte channel to a neighbour is ready.
class LinkEstablished extends TransportEvent {
  const LinkEstablished(this.link);
  final LinkId link;
}

class LinkLost extends TransportEvent {
  const LinkLost(this.link);
  final LinkId link;
}

/// One complete packet (already reassembled by the transport) arrived.
class PacketReceived extends TransportEvent {
  const PacketReceived(this.link, this.bytes);
  final LinkId link;
  final Uint8List bytes;
}

/// A transport moves opaque packets between directly connected devices.
///
/// Contract:
///  * [send] delivers one whole packet or throws; the transport is
///    responsible for fragmenting to the link MTU and reassembling.
///  * No packet parsing, routing or encryption happens here.
///  * Implementations must be real radio/network transports. In-memory test
///    doubles live under `test/` and are never shipped.
abstract interface class PeerTransport {
  TransportKind get kind;

  Stream<TransportEvent> get events;

  /// Start advertising + scanning. Idempotent.
  Future<void> start({String? advertisedName});

  Future<void> stop();

  /// Currently established links.
  Iterable<LinkId> get links;

  Future<void> send(LinkId link, Uint8List packet);
}
