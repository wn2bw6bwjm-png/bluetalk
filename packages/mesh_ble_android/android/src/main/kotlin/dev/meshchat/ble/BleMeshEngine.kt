package dev.meshchat.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.security.SecureRandom
import java.util.UUID

/**
 * Raw BLE byte pipe for the mesh messenger.
 *
 * Every device plays BOTH GATT roles at once:
 *  - Peripheral: advertises the mesh service and accepts writes/notifications.
 *  - Central: scans for the mesh service and connects to other devices.
 *
 * Two devices that see each other would otherwise connect twice (once per
 * direction). To avoid that, each advertises a random 8-byte per-session tag
 * and only the device with the SMALLER tag acts as central towards the other.
 * (The tag is random, not the peer ID, so passive observers cannot track a
 * user by their advertisements.)
 *
 * This class knows nothing about the protocol: it only moves chunks. It
 * reports events through [emit] using the bridge protocol documented in
 * `mesh_core/lib/src/networking/native_transport.dart`.
 *
 * Threading: every public method must be called on the main thread. Binder
 * callbacks from the Bluetooth stack are re-posted to the main looper, so all
 * state is touched from one thread only.
 *
 * Known platform limits (also in README): Android throttles scanning (5 starts
 * per 30 s), caps concurrent GATT connections (~7 typical), and aggressively
 * restricts BLE in the background unless a foreground service is running.
 */
@SuppressLint("MissingPermission") // checked in hasPermissions() before start()
class BleMeshEngine(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("6e8a0001-5d3c-4c8e-9f4b-7a1d2c3e4f50")
        val RX_UUID: UUID = UUID.fromString("6e8a0002-5d3c-4c8e-9f4b-7a1d2c3e4f50") // central -> peripheral
        val TX_UUID: UUID = UUID.fromString("6e8a0003-5d3c-4c8e-9f4b-7a1d2c3e4f50") // peripheral -> central
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** 0xFFFF is the Bluetooth SIG "reserved for testing" company ID. */
        const val MANUFACTURER_ID = 0xFFFF
        /**
         * 4 bytes so the tag fits into the MAIN advertisement next to the 128-bit
         * service UUID (flags 3 + uuid 18 + manufacturer 8 = 29 <= 31). It used to
         * live in the scan response, which some phones never deliver to the
         * scanner, so neither side recognised the other.
         */
        const val TAG_LENGTH = 4
        const val DESIRED_MTU = 247
        const val ATT_OVERHEAD = 3
        const val CONNECT_TIMEOUT_MS = 12_000L
        const val RECONNECT_BACKOFF_MS = 4_000L

        fun requiredPermissions(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
    }

    private val main = Handler(Looper.getMainLooper())

    /** Diagnostic line shown in the app's "Radio log" (Settings -> Network). */
    private fun log(msg: String) {
        main.post { emit(mapOf("t" to "log", "message" to msg)) }
    }
    private val random = SecureRandom()

    private var manager: BluetoothManager? = null
    private var adapter: BluetoothAdapter? = null
    private var running = false
    private var tag = ByteArray(TAG_LENGTH)

    // Peripheral role
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private val serverMtu = HashMap<String, Int>()
    private val peripheralLinks = HashMap<String, PeripheralLink>()

    // Central role
    private var scanner: BluetoothLeScanner? = null
    private val centralLinks = HashMap<String, CentralLink>()
    private val connecting = HashMap<String, BluetoothGatt>()
    private val lastAttempt = HashMap<String, Long>()
    private val seen = HashSet<String>()
    private val lastDiscoveredEmit = HashMap<String, Long>()

    // ───────────────────────────── public API ─────────────────────────────

    fun missingPermissions(): List<String> = requiredPermissions().filter {
        context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
    }

    /** Returns null on success, otherwise a human-readable error. */
    fun start(): String? {
        if (running) return null
        val missing = missingPermissions()
        if (missing.isNotEmpty()) return "Missing permissions: ${missing.joinToString()}"
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return "Bluetooth service unavailable"
        val ad = mgr.adapter ?: return "No Bluetooth adapter"
        if (!ad.isEnabled) return "Bluetooth is turned off"
        manager = mgr
        adapter = ad

        tag = ByteArray(TAG_LENGTH).also { random.nextBytes(it) }
        running = true
        log("start: sdk=${Build.VERSION.SDK_INT} model=${Build.MODEL} tag=${tag.joinToString("") { "%02x".format(it) }}")
        log("bluetooth on, advertiser=${ad.bluetoothLeAdvertiser != null}, scanner=${ad.bluetoothLeScanner != null}")
        startGattServer()
        startScanning()
        return null
    }

    fun stop() {
        if (!running) return
        running = false
        try { scanner?.stopScan(scanCallback) } catch (_: Exception) {}
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        scanner = null
        advertiser = null

        for (l in centralLinks.values.toList()) l.close("stopped")
        for (g in connecting.values.toList()) try { g.close() } catch (_: Exception) {}
        connecting.clear()
        centralLinks.clear()
        for (l in peripheralLinks.values.toList()) l.close("stopped")
        peripheralLinks.clear()
        serverMtu.clear()
        try { gattServer?.close() } catch (_: Exception) {}
        gattServer = null
        seen.clear()
        lastDiscoveredEmit.clear()
        lastAttempt.clear()
    }

    /** Writes one chunk. [done] is called exactly once with (ok, error). */
    fun send(linkId: String, data: ByteArray, done: (Boolean, String?) -> Unit) {
        val link = centralLinks.values.firstOrNull { it.id == linkId }
            ?: peripheralLinks.values.firstOrNull { it.id == linkId }
        if (link == null || !link.ready) {
            done(false, "Unknown or not ready link: $linkId")
            return
        }
        if (data.size > link.mtu - ATT_OVERHEAD) {
            done(false, "Chunk of ${data.size} bytes exceeds ${link.mtu - ATT_OVERHEAD}")
            return
        }
        link.enqueue(data, done)
    }

    fun disconnect(linkId: String) {
        centralLinks.values.firstOrNull { it.id == linkId }?.close("disconnect requested")
        peripheralLinks.values.firstOrNull { it.id == linkId }?.close("disconnect requested")
    }

    // ──────────────────────── common link write queue ────────────────────────

    private class Pending(val data: ByteArray, val done: (Boolean, String?) -> Unit)

    /**
     * BLE stacks accept ONE outstanding write/notification per connection, so
     * every link serialises its chunks and completes each caller when the
     * stack confirms the previous one.
     */
    private abstract inner class Link(val address: String, val id: String) {
        var mtu = 23
        var ready = false
        private val queue = ArrayDeque<Pending>()
        private var busy = false

        /** Start an asynchronous write. Return false if it could not start. */
        protected abstract fun startWrite(data: ByteArray): Boolean

        fun enqueue(data: ByteArray, done: (Boolean, String?) -> Unit) {
            queue.addLast(Pending(data, done))
            pump()
        }

        private fun pump() {
            if (busy) return
            val next = queue.firstOrNull() ?: return
            busy = true
            val started = try { startWrite(next.data) } catch (e: Exception) { false }
            if (!started) {
                queue.removeFirst()
                busy = false
                next.done(false, "Write could not be started")
                pump()
            }
        }

        /** Called by the stack callback when the outstanding write finished. */
        fun onWriteComplete(ok: Boolean) {
            val finished = queue.removeFirstOrNull()
            busy = false
            finished?.done?.invoke(ok, if (ok) null else "Write failed")
            pump()
        }

        protected fun failAll(reason: String) {
            while (true) {
                val p = queue.removeFirstOrNull() ?: break
                p.done(false, reason)
            }
            busy = false
        }

        abstract fun close(reason: String)
    }

    // ───────────────────────────── peripheral role ─────────────────────────────

    private inner class PeripheralLink(val device: BluetoothDevice) :
        Link(device.address, "p:${device.address}") {

        override fun startWrite(data: ByteArray): Boolean {
            val server = gattServer ?: return false
            val tx = txCharacteristic ?: return false
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(device, tx, false, data) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    tx.value = data
                    server.notifyCharacteristicChanged(device, tx, false)
                }
            }
        }

        override fun close(reason: String) {
            failAll(reason)
            if (ready) {
                ready = false
                emit(mapOf("t" to "down", "link" to id))
            }
            peripheralLinks.remove(address)
            try { gattServer?.cancelConnection(device) } catch (_: Exception) {}
        }
    }

    private fun startGattServer() {
        val server = manager!!.openGattServer(context, serverCallback)
        if (server == null) {
            emit(mapOf("t" to "error", "message" to "openGattServer failed"))
            return
        }
        gattServer = server

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val rx = BluetoothGattCharacteristic(
            RX_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val tx = BluetoothGattCharacteristic(
            TX_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        tx.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        service.addCharacteristic(rx)
        service.addCharacteristic(tx)
        txCharacteristic = tx
        // Advertising starts in onServiceAdded.
        server.addService(service)
    }

    private fun startAdvertising() {
        val ad = adapter ?: return
        val adv = ad.bluetoothLeAdvertiser
        if (adv == null) {
            emit(mapOf("t" to "error", "message" to "BLE advertising not supported on this device"))
            return
        }
        advertiser = adv
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false) // names are exchanged after connect, in a signed announce
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .addManufacturerData(MANUFACTURER_ID, tag)
            .build()
        adv.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            log("advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            log("advertising FAILED code=$errorCode (1=data too large, 2=too many advertisers, 3=already started, 4=internal, 5=not supported)")
            main.post {
                emit(mapOf("t" to "error", "message" to "Advertising failed (code $errorCode)"))
            }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            log("gatt service added, status=$status")
            main.post { if (running && status == BluetoothGatt.GATT_SUCCESS) startAdvertising() }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            log("server: ${device.address} state=$newState status=$status")
            main.post {
                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    serverMtu.remove(device.address)
                    peripheralLinks[device.address]?.close("disconnected")
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post {
                serverMtu[device.address] = mtu
                peripheralLinks[device.address]?.mtu = mtu
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            main.post {
                if (descriptor.uuid == CCCD_UUID && descriptor.characteristic.uuid == TX_UUID) {
                    val enable = value != null &&
                        value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    if (enable) {
                        val link = peripheralLinks.getOrPut(device.address) { PeripheralLink(device) }
                        link.mtu = serverMtu[device.address] ?: 23
                        if (!link.ready) {
                            link.ready = true
                            log("link UP ${link.id} chunk=${link.mtu - ATT_OVERHEAD}")
                            emit(mapOf("t" to "up", "link" to link.id, "mtu" to link.mtu - ATT_OVERHEAD))
                        }
                    } else {
                        peripheralLinks[device.address]?.close("notifications disabled")
                    }
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            main.post {
                val link = peripheralLinks[device.address]
                if (characteristic.uuid == RX_UUID && value != null && link != null && link.ready) {
                    emit(mapOf("t" to "chunk", "link" to link.id, "data" to value))
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                peripheralLinks[device.address]?.onWriteComplete(status == BluetoothGatt.GATT_SUCCESS)
            }
        }
    }

    // ───────────────────────────── central role ─────────────────────────────

    private inner class CentralLink(val gatt: BluetoothGatt, val rx: BluetoothGattCharacteristic) :
        Link(gatt.device.address, "c:${gatt.device.address}") {

        override fun startWrite(data: ByteArray): Boolean {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    rx, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    rx.value = data
                    gatt.writeCharacteristic(rx)
                }
            }
        }

        override fun close(reason: String) {
            failAll(reason)
            if (ready) {
                ready = false
                emit(mapOf("t" to "down", "link" to id))
            }
            centralLinks.remove(address)
            try { gatt.disconnect() } catch (_: Exception) {}
            try { gatt.close() } catch (_: Exception) {}
        }
    }

    private fun startScanning() {
        val sc = adapter?.bluetoothLeScanner
        if (sc == null) {
            emit(mapOf("t" to "error", "message" to "BLE scanner unavailable"))
            return
        }
        scanner = sc
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY) // foreground; see README for power trade-offs
            .build()
        sc.startScan(filters, settings, scanCallback)
        log("scanning started (filter: service uuid)")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { handleScanResult(result) }
        }

        override fun onScanFailed(errorCode: Int) {
            log("scan FAILED code=$errorCode (1=already started, 2=app registration failed, 3=internal, 4=unsupported, 5=out of hw resources, 6=scanning too frequently)")
            main.post { emit(mapOf("t" to "error", "message" to "Scan failed (code $errorCode)")) }
        }
    }

    private fun handleScanResult(result: ScanResult) {
        if (!running) return
        val address = result.device.address
        val remoteTag = result.scanRecord?.getManufacturerSpecificData(MANUFACTURER_ID)
        val firstSight = seen.add(address)
        // Keep the app's "devices found" list fresh (it expires entries after 30 s).
        val nowMs = System.currentTimeMillis()
        val emitDiscovered = nowMs - (lastDiscoveredEmit[address] ?: 0L) >= 3000L
        if (emitDiscovered) lastDiscoveredEmit[address] = nowMs

        if (remoteTag == null || remoteTag.size != TAG_LENGTH) {
            // No tag: an iPhone (it cannot put manufacturer data into its
            // advertisement) - the iPhone connects to us, we do not initiate.
            if (firstSight) {
                log("found $address rssi=${result.rssi} WITHOUT tag -> assume iPhone, waiting for it to connect")
            }
            if (emitDiscovered) emit(mapOf("t" to "discovered", "link" to "c:$address", "rssi" to result.rssi))
            return
        }
        if (remoteTag.contentEquals(tag)) return // our own advertisement
        if (emitDiscovered) {
            emit(mapOf("t" to "discovered", "link" to "c:$address", "rssi" to result.rssi))
        }

        // Only the device with the smaller tag initiates, so there is one link per pair.
        if (compareUnsigned(tag, remoteTag) >= 0) {
            if (firstSight) log("found $address rssi=${result.rssi}: remote tag is smaller, waiting for IT to connect")
            return
        }
        if (centralLinks.containsKey(address) || connecting.containsKey(address)) return
        val now = System.currentTimeMillis()
        if (now - (lastAttempt[address] ?: 0L) < RECONNECT_BACKOFF_MS) return
        lastAttempt[address] = now
        log("found $address rssi=${result.rssi}: our tag is smaller -> connecting")
        connect(result.device)
    }

    private fun connect(device: BluetoothDevice) {
        val address = device.address
        log("connectGatt $address")
        val gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            ?: return
        connecting[address] = gatt
        main.postDelayed({
            // Give up on connections that never become ready.
            val stuck = connecting[address]
            if (stuck != null && stuck === gatt) {
                connecting.remove(address)
                try { gatt.disconnect() } catch (_: Exception) {}
                try { gatt.close() } catch (_: Exception) {}
            }
        }, CONNECT_TIMEOUT_MS)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                val address = gatt.device.address
                log("client: $address state=$newState status=$status (status 133 = generic GATT error, usually retried automatically)")
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    // Order matters: MTU first, then service discovery (never in parallel).
                    if (!gatt.requestMtu(DESIRED_MTU)) gatt.discoverServices()
                } else {
                    connecting.remove(address)
                    val link = centralLinks[address]
                    if (link != null) link.close("disconnected") else try { gatt.close() } catch (_: Exception) {}
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                log("client: mtu=$mtu status=$status")
                pendingMtu[gatt.device.address] = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
                gatt.discoverServices()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val service = gatt.getService(SERVICE_UUID)
                log("client: services discovered status=$status, mesh service found=${service != null}")
                val rx = service?.getCharacteristic(RX_UUID)
                val tx = service?.getCharacteristic(TX_UUID)
                if (status != BluetoothGatt.GATT_SUCCESS || rx == null || tx == null) {
                    abandon(gatt)
                    return@post
                }
                gatt.setCharacteristicNotification(tx, true)
                val cccd = tx.getDescriptor(CCCD_UUID)
                if (cccd == null) { abandon(gatt); return@post }
                val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                        BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    run {
                        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        gatt.writeDescriptor(cccd)
                    }
                }
                if (!started) abandon(gatt)
                else pendingRx[gatt.device.address] = rx
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                val address = gatt.device.address
                log("client: notifications enabled status=$status")
                val rx = pendingRx.remove(address)
                if (status != BluetoothGatt.GATT_SUCCESS || rx == null) {
                    abandon(gatt)
                    return@post
                }
                connecting.remove(address)
                val link = CentralLink(gatt, rx)
                link.mtu = pendingMtu.remove(address) ?: 23
                link.ready = true
                centralLinks[address] = link
                log("link UP ${link.id} chunk=${link.mtu - ATT_OVERHEAD}")
                            emit(mapOf("t" to "up", "link" to link.id, "mtu" to link.mtu - ATT_OVERHEAD))
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            main.post {
                centralLinks[gatt.device.address]?.onWriteComplete(status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        // API 33+
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            deliver(gatt, characteristic, value)
        }

        // API < 33
        @Deprecated("Replaced by the overload with value in API 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            deliver(gatt, characteristic, value.copyOf())
        }

        private fun deliver(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid != TX_UUID) return
            main.post {
                val link = centralLinks[gatt.device.address]
                if (link != null && link.ready) {
                    emit(mapOf("t" to "chunk", "link" to link.id, "data" to value))
                }
            }
        }
    }

    private val pendingMtu = HashMap<String, Int>()
    private val pendingRx = HashMap<String, BluetoothGattCharacteristic>()

    private fun abandon(gatt: BluetoothGatt) {
        val address = gatt.device.address
        connecting.remove(address)
        pendingMtu.remove(address)
        pendingRx.remove(address)
        try { gatt.disconnect() } catch (_: Exception) {}
        try { gatt.close() } catch (_: Exception) {}
    }

    private fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val d = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (d != 0) return d
        }
        return a.size - b.size
    }
}
