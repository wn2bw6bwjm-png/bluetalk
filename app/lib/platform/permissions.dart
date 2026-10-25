import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

/// Requests the runtime permissions the radio transports need.
/// Returns null when everything required is granted, else a user-facing reason.
Future<String?> ensureRadioPermissions() async {
  if (Platform.isAndroid) {
    // Android 12+: BLUETOOTH_SCAN/ADVERTISE/CONNECT. Android 6-11: location
    // (the OS requires it for BLE scanning; the app never reads a position).
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    bool ok(Permission p) => results[p]?.isGranted ?? false;
    final btOk = ok(Permission.bluetoothScan) &&
        ok(Permission.bluetoothAdvertise) &&
        ok(Permission.bluetoothConnect);
    if (!btOk && !ok(Permission.locationWhenInUse)) {
      return 'Bluetooth permission is required to find nearby devices.';
    }
  }
  // iOS shows the Local Network / Bluetooth prompts itself on first use.
  return null;
}
