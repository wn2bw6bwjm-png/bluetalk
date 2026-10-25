import CoreBluetooth
import Foundation

/// iOS side of the cross-platform BLE transport (Android <-> iPhone).
///
/// It speaks the SAME GATT protocol as the Android `BleMeshEngine`:
///   service  6E8A0001-5D3C-4C8E-9F4B-7A1D2C3E4F50
///   RX  ...0002  (central writes without response  -> Android peripheral)
///   TX  ...0003  (peripheral notifies               -> iOS central)
///
/// Visibility: the iPhone also ADVERTISES the BlueTalk service (no GATT
/// service behind it, nobody connects to it) so Android phones list it as a
/// nearby device immediately. Its local name is `BTK`; iPhones recognise each
/// other by it and never try to connect to one another over BLE.
///
/// Connection rule (chosen so no duplicate links ever form and so it works
/// while the iPhone is in the background):
///   * the iPhone is ALWAYS the central towards Android phones and connects to
///     every peripheral that advertises our service (only Androids do);
///   * Android never initiates towards an untagged device (iPhones cannot put
///     manufacturer data in their advertisement); Android phones tag their
///     advertisement with 0xFFFF manufacturer data, used only between Androids;
///   * two iPhones do NOT connect over BLE (they use Multipeer while both are
///     in the foreground). iPhone <-> iPhone has no background path.
///
/// Background: the app declares `bluetooth-central` and uses state
/// restoration, so iOS may relaunch it for pending BLE events. This is
/// best-effort: iOS throttles background scanning, never restarts an app the
/// user force-quit, and gives no delivery guarantee.
///
/// Reports events using the bridge protocol documented in
/// `mesh_core/lib/src/networking/native_transport.dart`.
final class BleCentralEngine: NSObject {
    static let serviceUUID = CBUUID(string: "6E8A0001-5D3C-4C8E-9F4B-7A1D2C3E4F50")
    static let rxUUID = CBUUID(string: "6E8A0002-5D3C-4C8E-9F4B-7A1D2C3E4F50")
    static let txUUID = CBUUID(string: "6E8A0003-5D3C-4C8E-9F4B-7A1D2C3E4F50")
    static let restoreID = "dev.meshchat.ble.central"
    static let iosMarkerName = "BTK"
    static let connectTimeout: TimeInterval = 15
    static let reconnectDelay: TimeInterval = 3

    private final class Link {
        let peripheral: CBPeripheral
        var rx: CBCharacteristic?
        var tx: CBCharacteristic?
        var ready = false
        var mtu = 20
        var pending: [(Data, (String?) -> Void)] = []
        init(_ p: CBPeripheral) { peripheral = p }
        var id: String { "c:\(peripheral.identifier.uuidString)" }
    }

    private let emit: ([String: Any?]) -> Void
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    /// Peripherals that turned out not to speak our protocol (stop retrying).
    private var ignored = Set<UUID>()
    private var lastDiscoveredEmit: [UUID: Date] = [:]
    private var running = false
    private var links: [UUID: Link] = [:]
    private var announced = Set<UUID>()

    init(emit: @escaping ([String: Any?]) -> Void) {
        self.emit = emit
        super.init()
    }

    private func log(_ m: String) { emit(["t": "log", "message": m]) }

    // MARK: public API (called on the main thread)

    func start() {
        guard !running else { return }
        running = true
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
        )
        // Advertise only (no GATT service): makes this iPhone visible to Android.
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        running = false
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        peripheralManager = nil
        ignored.removeAll()
        lastDiscoveredEmit.removeAll()
        for l in links.values {
            failPending(l, "stopped")
            if l.ready { emit(["t": "down", "link": l.id]) }
            central?.cancelPeripheralConnection(l.peripheral)
        }
        links.removeAll()
        announced.removeAll()
        central = nil
    }

    /// Writes one chunk. `done` is called exactly once with nil or an error.
    func send(link id: String, data: Data, done: @escaping (String?) -> Void) {
        guard let l = links.values.first(where: { $0.id == id }), l.ready else {
            done("Unknown or not ready link: \(id)")
            return
        }
        if data.count > l.mtu {
            done("Chunk of \(data.count) bytes exceeds \(l.mtu)")
            return
        }
        l.pending.append((data, done))
        pump(l)
    }

    func disconnect(link id: String) {
        if let l = links.values.first(where: { $0.id == id }) {
            central?.cancelPeripheralConnection(l.peripheral)
        }
    }

    // MARK: write queue with flow control

    private func pump(_ l: Link) {
        guard l.ready, let rx = l.rx else { return }
        while let next = l.pending.first {
            // Write-without-response is flow controlled by iOS: when its queue
            // is full we must wait for peripheralIsReady(toSendWriteWithoutResponse:).
            guard l.peripheral.canSendWriteWithoutResponse else { return }
            l.pending.removeFirst()
            l.peripheral.writeValue(next.0, for: rx, type: .withoutResponse)
            next.1(nil)
        }
    }

    private func failPending(_ l: Link, _ reason: String) {
        let items = l.pending
        l.pending.removeAll()
        for (_, done) in items { done(reason) }
    }

    // MARK: helpers

    private func connect(_ p: CBPeripheral) {
        guard running, let c = central, links[p.identifier] == nil else { return }
        let l = Link(p)
        links[p.identifier] = l
        p.delegate = self
        c.connect(p, options: nil)
        // iOS never times a connect out by itself; give up and retry via scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self = self, let cur = self.links[p.identifier], cur === l, !l.ready else { return }
            self.drop(p, reconnect: false)
        }
    }

    private func drop(_ p: CBPeripheral, reconnect: Bool) {
        if let l = links.removeValue(forKey: p.identifier) {
            failPending(l, "disconnected")
            if l.ready { emit(["t": "down", "link": l.id]) }
        }
        central?.cancelPeripheralConnection(p)
        if reconnect && running {
            // A pending connect() survives backgrounding and even app
            // suspension, which is what lets iOS relaunch us when the
            // Android phone reappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
                self?.connect(p)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleCentralEngine: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("ble: central state = \(central.state.rawValue) (5 = powered on, 3 = unauthorized, 4 = powered off)")
        switch central.state {
        case .poweredOn:
            log("ble: powered on, scanning for the mesh service")
            central.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .unauthorized:
            emit(["t": "error", "message": "Bluetooth permission denied"])
        case .poweredOff:
            emit(["t": "error", "message": "Bluetooth is turned off"])
        case .unsupported:
            emit(["t": "error", "message": "Bluetooth LE is not supported on this device"])
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        // iOS relaunched the app for a BLE event: re-adopt known peripherals.
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        running = true
        self.central = central
        for p in restored {
            p.delegate = self
            if links[p.identifier] == nil {
                let l = Link(p)
                links[p.identifier] = l
                if p.state == .connected {
                    p.discoverServices([Self.serviceUUID])
                } else {
                    central.connect(p, options: nil)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Every peripheral that advertises our service is an Android phone:
        // iPhones never advertise it (they are central-only, and iPhone <->
        // iPhone uses Multipeer). So no further check is needed; in particular
        // we do NOT depend on the manufacturer tag, which iOS may not deliver
        // when it reports a device once before the scan response arrives.
        let id = peripheral.identifier
        let isOtherIPhone =
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String) == Self.iosMarkerName
        if isOtherIPhone || ignored.contains(id) { return }
        if announced.insert(id).inserted {
            log("ble: found mesh device \(id.uuidString) rssi=\(RSSI) -> connecting")
        }
        // Refresh the app's "devices found" list (entries expire after 30 s).
        let now = Date()
        if now.timeIntervalSince(lastDiscoveredEmit[id] ?? .distantPast) >= 3 {
            lastDiscoveredEmit[id] = now
            emit(["t": "discovered", "link": "c:\(id.uuidString)", "rssi": RSSI.intValue])
        }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("ble: connected, discovering services")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        drop(peripheral, reconnect: true)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        announced.remove(peripheral.identifier)
        drop(peripheral, reconnect: true)
    }
}

// MARK: - CBPeripheralDelegate

extension BleCentralEngine: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            // Not an Android BlueTalk phone (e.g. an iPhone advertising only):
            // do not try it again this session.
            ignored.insert(peripheral.identifier)
            log("ble: \(peripheral.identifier.uuidString) has no mesh service, ignoring")
            drop(peripheral, reconnect: false)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let l = links[peripheral.identifier],
              let rx = service.characteristics?.first(where: { $0.uuid == Self.rxUUID }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.txUUID }) else {
            drop(peripheral, reconnect: false)
            return
        }
        l.rx = rx
        l.tx = tx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, let l = links[peripheral.identifier] else { return }
        if error != nil || !characteristic.isNotifying {
            drop(peripheral, reconnect: false)
            return
        }
        guard !l.ready else { return }
        l.ready = true
        // Maximum payload of one write-without-response (already excludes ATT overhead).
        l.mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log("ble: link UP \(l.id) chunk=\(l.mtu)")
        emit(["t": "up", "link": l.id, "mtu": l.mtu])
        pump(l)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.txUUID,
              let l = links[peripheral.identifier], l.ready,
              let data = characteristic.value else { return }
        emit(["t": "chunk", "link": l.id, "data": data])
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let l = links[peripheral.identifier] { pump(l) }
    }
}

// MARK: - CBPeripheralManagerDelegate (advertising only)

extension BleCentralEngine: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: Self.iosMarkerName,
        ])
        log("ble: advertising the BlueTalk service (iPhone visible to Android)")
    }
}
