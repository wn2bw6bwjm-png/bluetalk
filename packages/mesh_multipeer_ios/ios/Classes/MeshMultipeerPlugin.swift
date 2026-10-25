import Flutter
import UIKit

/// One method channel + one event channel. Converts `Data` payloads to
/// `FlutterStandardTypedData` so Dart receives `Uint8List`.
private final class Endpoint: NSObject, FlutterStreamHandler {
    var sink: FlutterEventSink?

    func dispatch(_ event: [String: Any?]) {
        var out: [String: Any] = [:]
        for (k, v) in event {
            if let data = v as? Data {
                out[k] = FlutterStandardTypedData(bytes: data)
            } else if let v = v {
                out[k] = v
            }
        }
        sink?(out)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

/// Registers both iOS transports. Channel contract (see
/// `mesh_core/lib/src/networking/native_transport.dart`):
///
///   "mesh/multipeer" + "mesh/multipeer/events"  Multipeer Connectivity (iPhone <-> iPhone)
///   "mesh/ble"       + "mesh/ble/events"        CoreBluetooth central   (iPhone <-> Android)
///
/// Both use start, stop, send, disconnect and the same event maps.
public class MeshMultipeerPlugin: NSObject, FlutterPlugin {
    private let mpc = Endpoint()
    private let ble = Endpoint()
    private var multipeer: MultipeerEngine?
    private var central: BleCentralEngine?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MeshMultipeerPlugin()
        let messenger = registrar.messenger()

        let mpcMethods = FlutterMethodChannel(name: "mesh/multipeer", binaryMessenger: messenger)
        FlutterEventChannel(name: "mesh/multipeer/events", binaryMessenger: messenger)
            .setStreamHandler(instance.mpc)
        mpcMethods.setMethodCallHandler { [weak instance] call, result in
            instance?.handleMultipeer(call, result)
        }

        let bleMethods = FlutterMethodChannel(name: "mesh/ble", binaryMessenger: messenger)
        FlutterEventChannel(name: "mesh/ble/events", binaryMessenger: messenger)
            .setStreamHandler(instance.ble)
        bleMethods.setMethodCallHandler { [weak instance] call, result in
            instance?.handleBle(call, result)
        }

        instance.multipeer = MultipeerEngine { [weak instance] e in instance?.mpc.dispatch(e) }
        instance.central = BleCentralEngine { [weak instance] e in instance?.ble.dispatch(e) }
    }

    // MARK: Multipeer

    private func handleMultipeer(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let engine = multipeer else {
            result(FlutterError(code: "no_engine", message: "Engine not attached", details: nil))
            return
        }
        switch call.method {
        case "start":
            engine.start()
            result(nil)
        case "stop":
            engine.stop()
            result(nil)
        case "send":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String,
                  let data = args["data"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "bad_args", message: "link and data are required", details: nil))
                return
            }
            if let error = engine.send(link: link, data: data.data) {
                result(FlutterError(code: "send_failed", message: error, details: nil))
            } else {
                result(nil)
            }
        case "disconnect":
            if let args = call.arguments as? [String: Any], let link = args["link"] as? String {
                engine.disconnect(link: link)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: BLE (CoreBluetooth)

    private func handleBle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let engine = central else {
            result(FlutterError(code: "no_engine", message: "Engine not attached", details: nil))
            return
        }
        switch call.method {
        case "start":
            engine.start()
            result(nil)
        case "stop":
            engine.stop()
            result(nil)
        case "send":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String,
                  let data = args["data"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "bad_args", message: "link and data are required", details: nil))
                return
            }
            engine.send(link: link, data: data.data) { error in
                if let error = error {
                    result(FlutterError(code: "send_failed", message: error, details: nil))
                } else {
                    result(nil)
                }
            }
        case "disconnect":
            if let args = call.arguments as? [String: Any], let link = args["link"] as? String {
                engine.disconnect(link: link)
            }
            result(nil)
        // Android-only helpers are harmless no-ops here.
        case "startForeground", "stopForeground", "requestIgnoreBatteryOptimizations":
            result(nil)
        case "isIgnoringBatteryOptimizations":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
