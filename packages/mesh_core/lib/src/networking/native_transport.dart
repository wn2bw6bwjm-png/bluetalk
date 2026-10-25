import 'dart:async';
import 'dart:typed_data';

import '../core/errors.dart';
import 'fragmenter.dart';
import 'peer_transport.dart';

/// Thin boundary to platform code (Kotlin / Swift). The Flutter app provides a
/// `MethodChannel`/`EventChannel` implementation; tests provide a fake.
///
/// ## Bridge protocol (native ⇄ Dart)
///
/// Calls (Dart → native):
///  * `start`  {name: String?}            begin advertising + scanning
///  * `stop`   {}                         tear everything down
///  * `send`   {link: String, data: Uint8List}
///             write ONE chunk (≤ the `mtu` reported for that link); the future
///             completes when the platform accepted/wrote it (back-pressure)
///  * `disconnect` {link: String}
///
/// Events (native → Dart), each a map with key `t`:
///  * `discovered` {link, name?, rssi?}
///  * `up`         {link, mtu}            link ready; `mtu` = max chunk bytes
///  * `down`       {link}
///  * `chunk`      {link, data}           one received chunk
///  * `error`      {message}
///  * `log`        {message}              diagnostic line for the app's radio log
abstract interface class NativeBridge {
  Future<void> invoke(String method, Map<String, Object?> args);
  Stream<Map<String, Object?>> get events;
}

/// [PeerTransport] on top of a [NativeBridge].
///
/// All protocol-independent link work lives here in Dart so it is unit-tested:
/// per-link MTU, fragmentation, reassembly, ordered sends. Native code only
/// moves raw chunks.
class NativeTransport implements PeerTransport {
  NativeTransport({required this.kind, required NativeBridge bridge})
      : _bridge = bridge;

  @override
  final TransportKind kind;
  final NativeBridge _bridge;

  final StreamController<TransportEvent> _events = StreamController.broadcast();
  final StreamController<String> _logs = StreamController.broadcast();
  final Map<String, _Link> _links = {};
  StreamSubscription<Map<String, Object?>>? _sub;
  bool _started = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  /// Human-readable diagnostics from the native layer (what it found, why it
  /// did or did not connect, GATT status codes). Shown in the app's radio log.
  Stream<String> get logs => _logs.stream;

  @override
  Iterable<LinkId> get links => _links.values.map((l) => l.id);

  @override
  Future<void> start({String? advertisedName}) async {
    if (_started) return;
    _started = true;
    _sub = _bridge.events.listen(_onNative, onError: (Object _) {});
    await _bridge.invoke('start', {'name': advertisedName});
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _bridge.invoke('stop', const {});
    await _sub?.cancel();
    _sub = null;
    for (final l in _links.values) {
      _events.add(LinkLost(l.id));
    }
    _links.clear();
  }

  @override
  Future<void> send(LinkId link, Uint8List packet) async {
    final l = _links[link.value];
    if (l == null) throw StateError('Link ${link.value} is not established');
    // Serialize per link so chunks of two packets never interleave.
    final run = l.tail.then((_) => _sendNow(l, packet));
    l.tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _sendNow(_Link l, Uint8List packet) async {
    final chunks = l.fragmenter.split(packet, mtu: l.mtu);
    for (final c in chunks) {
      if (!_links.containsKey(l.id.value)) {
        throw StateError('Link lost while sending');
      }
      await _bridge.invoke('send', {'link': l.id.value, 'data': c});
    }
  }

  void _onNative(Map<String, Object?> e) {
    final link = e['link'];
    switch (e['t']) {
      case 'log':
        final m = e['message'];
        if (m is String) _logs.add('[${kind.name}] $m');
      case 'error':
        final m = e['message'];
        if (m is String) _logs.add('[${kind.name}] ERROR: $m');
      case 'discovered':
        if (link is String) {
          _events.add(PeerDiscovered(
            LinkId(kind, link),
            advertisedName: e['name'] as String?,
            rssi: e['rssi'] as int?,
          ));
        }
      case 'up':
        final mtu = e['mtu'];
        if (link is String && mtu is int && mtu > Fragmenter.headerLength) {
          final l = _Link(LinkId(kind, link), mtu);
          _links[link] = l;
          _events.add(LinkEstablished(l.id));
        }
      case 'down':
        final l = link is String ? _links.remove(link) : null;
        if (l != null) _events.add(LinkLost(l.id));
      case 'chunk':
        final data = e['data'];
        final l = link is String ? _links[link] : null;
        if (l == null || data is! List<int>) return;
        try {
          final packet = l.reassembler.add(Uint8List.fromList(data));
          if (packet != null) _events.add(PacketReceived(l.id, packet));
        } on InvalidPacketException {
          // Malformed chunk from a neighbour: drop it, keep the link.
        }
    }
  }
}

class _Link {
  _Link(this.id, this.mtu);
  final LinkId id;
  final int mtu;
  final Fragmenter fragmenter = Fragmenter();
  final Reassembler reassembler = Reassembler();
  Future<void> tail = Future.value();
}
