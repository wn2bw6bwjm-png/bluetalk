import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';

/// TEST-ONLY in-memory transport pair. It exists purely so the protocol logic
/// can be exercised in unit tests; it is not part of the shipped app, which
/// only uses real BLE / Multipeer transports.
class LinkedTransport implements PeerTransport {
  LinkedTransport(this.name, {this.kind = TransportKind.ble});

  final String name;
  @override
  final TransportKind kind;

  LinkedTransport? peer;
  bool connected = false;

  /// Every packet that crossed this transport (what a relay/eavesdropper sees).
  final List<Uint8List> sent = [];

  final StreamController<TransportEvent> _ctrl = StreamController.broadcast();

  LinkId get _link => LinkId(kind, peer!.name);

  @override
  Stream<TransportEvent> get events => _ctrl.stream;

  @override
  Iterable<LinkId> get links => connected ? [_link] : const [];

  static (LinkedTransport, LinkedTransport) pair(String a, String b) {
    final x = LinkedTransport(a);
    final y = LinkedTransport(b);
    x.peer = y;
    y.peer = x;
    return (x, y);
  }

  /// Brings the link up on both sides.
  Future<void> connect() async {
    connected = true;
    peer!.connected = true;
    _ctrl.add(LinkEstablished(_link));
    peer!._ctrl.add(LinkEstablished(peer!._link));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> disconnect() async {
    connected = false;
    peer!.connected = false;
    _ctrl.add(LinkLost(_link));
    peer!._ctrl.add(LinkLost(peer!._link));
  }

  /// Reports a nearby (not yet connected) device, like a radio scan would.
  void discover({int? rssi}) => _ctrl.add(PeerDiscovered(_link, rssi: rssi));

  /// Delivers raw bytes to this transport as if received from the peer.
  void inject(Uint8List bytes) => _ctrl.add(PacketReceived(_link, bytes));

  @override
  Future<void> send(LinkId link, Uint8List packet) async {
    if (!connected) throw StateError('link down');
    sent.add(Uint8List.fromList(packet));
    peer!._ctrl.add(PacketReceived(peer!._link, Uint8List.fromList(packet)));
  }

  @override
  Future<void> start({String? advertisedName}) async {}

  @override
  Future<void> stop() async {}
}
