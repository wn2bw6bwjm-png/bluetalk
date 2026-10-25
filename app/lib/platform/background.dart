import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android keep-alive helpers (foreground service + battery optimisation).
/// All of this is best effort: it makes background operation more likely, it
/// can NOT guarantee it. On iOS these are no-ops (iOS offers no equivalent;
/// the app relies on the Bluetooth background mode instead).
class BackgroundKeepAlive {
  static const MethodChannel _ch = MethodChannel('mesh/ble');

  bool get supported => Platform.isAndroid;

  Future<void> start() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('startForeground');
    } on PlatformException {
      // Notification permission missing etc.: the radio still works in the
      // foreground, so do not fail the app.
    }
  }

  Future<void> stop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('stopForeground');
    } on PlatformException {
      // ignore
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!supported) return true;
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } on PlatformException {
      // ignore
    }
  }
}
