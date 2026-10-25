import 'package:flutter/services.dart';
import 'package:mesh_core/mesh_core.dart';

/// [NativeBridge] backed by Flutter platform channels. [prefix] is
/// `mesh/ble` (Android) or `mesh/multipeer` (iOS); events use `$prefix/events`.
class MethodChannelBridge implements NativeBridge {
  MethodChannelBridge(String prefix)
      : _method = MethodChannel(prefix),
        _events = EventChannel('$prefix/events');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Future<void> invoke(String method, Map<String, Object?> args) =>
      _method.invokeMethod<void>(method, args);

  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .map((dynamic e) => Map<String, Object?>.from(e as Map));
}
