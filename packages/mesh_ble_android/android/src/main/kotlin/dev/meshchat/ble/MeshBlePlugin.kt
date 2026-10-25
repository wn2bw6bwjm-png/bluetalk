package dev.meshchat.ble

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter adapter for [BleMeshEngine]. Channel contract (see
 * `mesh_core/.../native_transport.dart`):
 *
 *   MethodChannel "mesh/ble":        start, stop, send, disconnect, missingPermissions,
 *                                    startForeground, stopForeground,
 *                                    isIgnoringBatteryOptimizations, requestIgnoreBatteryOptimizations
 *   EventChannel  "mesh/ble/events": discovered / up / down / chunk / error maps
 */
class MeshBlePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var engine: BleMeshEngine? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "mesh/ble")
        events = EventChannel(binding.binaryMessenger, "mesh/ble/events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        appContext = binding.applicationContext
        engine = BleMeshEngine(binding.applicationContext) { event -> sink?.success(event) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engine?.stop()
        engine = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val e = engine ?: return result.error("no_engine", "Engine not attached", null)
        when (call.method) {
            "missingPermissions" -> result.success(e.missingPermissions())
            "start" -> {
                val error = e.start()
                if (error == null) result.success(null) else result.error("start_failed", error, null)
            }
            "stop" -> {
                e.stop()
                result.success(null)
            }
            "send" -> {
                val link = call.argument<String>("link")
                val data = call.argument<ByteArray>("data")
                if (link == null || data == null) {
                    result.error("bad_args", "link and data are required", null)
                } else {
                    e.send(link, data) { ok, err ->
                        if (ok) result.success(null) else result.error("send_failed", err, null)
                    }
                }
            }
            // Background keep-alive helpers (Android only; mitigations, not guarantees)
            "startForeground" -> {
                appContext?.let { MeshForegroundService.start(it) }
                result.success(null)
            }
            "stopForeground" -> {
                appContext?.let { MeshForegroundService.stop(it) }
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> {
                val ctx = appContext
                val pm = ctx?.getSystemService(Context.POWER_SERVICE) as? PowerManager
                result.success(pm?.isIgnoringBatteryOptimizations(ctx?.packageName ?: "") ?: false)
            }
            "requestIgnoreBatteryOptimizations" -> {
                val ctx = appContext
                if (ctx == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                    result.success(null)
                } else {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:${ctx.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        ctx.startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("unavailable", "Cannot open battery settings: ${e.message}", null)
                    }
                }
            }
            "disconnect" -> {
                call.argument<String>("link")?.let { e.disconnect(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
