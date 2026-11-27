package com.spyou.watch_app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.Closeable
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors

/**
 * Phone side of the "phone as TV remote" feature: owns the Wi-Fi / Bluetooth companion sockets
 * to the TV receiver ([CompanionReceiver]), pairing, TV discovery and the Bluetooth HID link.
 * Transport only; the companion UI lives in the app's Flutter settings and calls [handle] over
 * the method channel. One instance lives for the whole application (see [attach]).
 */
class RemoteCompanionBridge(activity: Activity) {
    companion object {
        /** The application-wide bridge, created by the first [attach]. */
        var shared: RemoteCompanionBridge? = null; private set
        /** Reuses the application connection while replacing the weak reference to the visible activity. */
        fun attach(activity: Activity): RemoteCompanionBridge = (shared ?: RemoteCompanionBridge(activity).also { shared = it }).also {
            it.ui = java.lang.ref.WeakReference(activity)
        }
    }
    /** Weak reference to the visible activity, so the bridge never leaks a destroyed screen. */
    private var ui = java.lang.ref.WeakReference(activity)
    /** Application context used for sockets, prefs and services; safe to keep for the app's life. */
    private val context = activity.applicationContext
    /** The visible activity, needed for permission prompts and settings screens; throws if none. */
    private val activity: Activity get() = ui.get() ?: error("Open Zangetsu to change this setting.")
    /** True while any transport is opening; stops the maintenance loop from starting another. */
    @Volatile private var connecting = false
    /** When the last companion request went out; the loop only polls state after 1.5 s of quiet. */
    @Volatile private var lastRequest = android.os.SystemClock.elapsedRealtime()
    /** Drives the 2-second maintenance tick that keeps saved TV links alive. */
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    /** Last time the 15-second reconnect / Bluetooth check ran (main thread only). */
    private var lastMaintenance = 0L
    /** True while a background state poll is in flight, so polls never pile up. */
    private var backgroundPoll = false
    /**
     * Maintenance loop, every 2 s on the main thread, only while auto-connect or the Bluetooth remote is enabled: every 15 s it
     * restores Bluetooth / Wi-Fi links and reconnects, and while idle it polls the TV for state.
     */
    init {
        scheduler.scheduleWithFixedDelay({ main.post {
            if (!prefs.getBoolean("autoConnect", false) && !prefs.getBoolean("hidEnabled", false)) return@post
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastMaintenance >= 15000) {
            lastMaintenance = now
            ensureBluetooth()
            keepStandbyAlive()
            if (prefs.getBoolean("autoConnect", false) && links["Wi-Fi"] == null && !opening.contains("Wi-Fi") && !prefs.getString("address", "").isNullOrEmpty()) {
                connect(MethodCall("connect", mapOf("address" to prefs.getString("address", ""), "background" to true)), silent)
            }
            if (connecting) return@post
            if (!paired) {
                handle(MethodCall("reconnect", null), object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(code: String, message: String?, details: Any?) {}
                    override fun notImplemented() {}
                })
            }
            }
            if (paired && !backgroundPoll && now - lastRequest > 1500) {
                backgroundPoll = true
                handle(MethodCall("command", JSONObject().put("action", "state").toString()), object : MethodChannel.Result {
                    override fun success(result: Any?) { backgroundPoll = false }
                    override fun error(code: String, message: String?, details: Any?) { backgroundPoll = false }
                    override fun notImplemented() { backgroundPoll = false }
                })
            }
        } }, 2, 2, java.util.concurrent.TimeUnit.SECONDS)
    }
    /** Drops the activity reference only when the departing activity still owns it. */
    fun detach(owner: Activity) { if (ui.get() === owner) ui.clear() }
    /** Main-thread handler; channel results and shared state changes are posted here. */
    private val main = Handler(Looper.getMainLooper())
    /** Serial executor for companion request/response exchanges and LAN discovery. */
    private val worker = Executors.newSingleThreadExecutor()
    /** Bumped on every disconnect; work started under an older value drops its result. */
    @Volatile private var generation = 0
    /** The running NSD browse, or null when no TV search is active. */
    private var discovery: NsdManager.DiscoveryListener? = null
    /** Flutter result waiting for the current TV search. */
    private var discoveryResult: MethodChannel.Result? = null
    /** Held during discovery so the Wi-Fi chip delivers mDNS / broadcast replies. */
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null
    /** Saved pairing: TV id, address, per-TV token, HID address and auto-connect flags. */
    private val prefs = context.getSharedPreferences("companion_pairing", Activity.MODE_PRIVATE)
    /** True when at least one authenticated companion link is open. */
    private val paired get() = links.values.any { it.alive }
    /**
     * Requests waiting on a silent reconnect after a failed exchange. The worker counts one up before
     * it drops the failed link, so requests queued behind it already see the reconnect; [recoverCompanion]
     * counts it down on the main thread when it finishes.
     */
    private val recovering = java.util.concurrent.atomic.AtomicInteger()
    /** True while a link is up or a silent reconnect is running, so the session still reads as connected. */
    private val linked get() = paired || recovering.get() > 0
    /** Display name the TV reported when it paired. */
    private var name = "TV"
    /** The link companion requests prefer: Bluetooth when open, otherwise Wi-Fi. */
    private val transport get() = if (links["Bluetooth"]?.alive == true) "Bluetooth" else "Wi-Fi"

    /**
     * Dispatches the Flutter channel contract and converts transport failures into structured errors.
     * Called on the main thread by MainActivity's method channel (and by the maintenance loop).
     * Phone-side methods talk to the TV; `receiver*` methods run this device as the TV receiver.
     */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "restoreReceiver" -> {
                    if (prefs.getBoolean("receiverEnabled", false)) {
                        CompanionReceiver.start(activity)
                        runCatching { CompanionReceiver.startBluetooth(activity) }
                    }
                    result.success(null)
                }
                "connectionState" -> result.success(mapOf("connected" to (linked || RemoteConnectionService.instance?.isConnected() == true), "companion" to linked, "hid" to (RemoteConnectionService.instance?.isConnected() == true), "bluetoothDetail" to (RemoteConnectionService.instance?.detail ?: "Link Bluetooth in Manage"), "wifi" to (links["Wi-Fi"]?.alive == true), "bluetoothCompanion" to (links["Bluetooth"]?.alive == true), "saved" to (prefs.getBoolean("autoConnect", false) || prefs.getBoolean("hidEnabled", false)),
                    "name" to (if(paired) name else prefs.getString("hidName", prefs.getString("name", "TV"))), "transport" to transport, "remoteMode" to prefs.getBoolean("remoteMode", false)))
                "remoteMode" -> { prefs.edit().putBoolean("remoteMode", call.arguments == true).apply(); result.success(null) }
                "reconnect" -> {
                    ensureBluetooth()
                    if (!prefs.getBoolean("autoConnect", false) && prefs.getBoolean("hidEnabled", false)) { result.success(null); return }
                    check(prefs.getBoolean("autoConnect", false)) { "Pair a TV first." }
                    // A silent reconnect is already running; it finishes the job.
                    if (recovering.get() > 0) { result.success(null); return }
                    connect(MethodCall("connect", mapOf("address" to prefs.getString("address", ""),
                        "background" to true, "pin" to "")), object : MethodChannel.Result {
                        override fun success(value: Any?) = result.success(value)
                        // A reconnect of this link is already running, so this one is not an error.
                        override fun error(code: String, message: String?, details: Any?) = if (code == "connecting") result.success(null) else result.error(code, message, details)
                        override fun notImplemented() = result.notImplemented()
                    })
                }
                "receiverForget" -> { CompanionReceiver.forgetPhones(); result.success(receiverState()) }
                "receiverStream" -> result.success(TvPlayerActivity.active?.companionStream())
                "receiverSkipPrefs" -> { TvPlayerActivity.active?.companionSkipPrefs(JSONObject(call.arguments as Map<*, *>)); result.success(null) }
                "receiverClosePlayer" -> { TvPlayerActivity.active?.finish(); result.success(null) }
                // Dart pushes the selected TV text box (JSON) or null; state replies embed it.
                "receiverKeyboard" -> {
                    CompanionReceiver.keyboard = (call.arguments as? String)?.let { runCatching { JSONObject(it) }.getOrNull() }
                    result.success(null)
                }
                "scanPairing" -> scanPairing(result)
                "lastAddress" -> result.success(prefs.getString("address", ""))
                "receiverState" -> result.success(receiverState())
                "receiverStart" -> { CompanionReceiver.start(activity); runCatching { CompanionReceiver.startBluetooth(activity) }; result.success(receiverState()) }
                "receiverStop" -> { CompanionReceiver.disable(); result.success(receiverState()) }
                "receiverRenew" -> { CompanionReceiver.renewPin(); result.success(receiverState()) }
                "receiverBluetooth" -> if (bluetoothAllowed(result)) {
                    CompanionReceiver.start(activity); CompanionReceiver.startBluetooth(activity); result.success(receiverState())
                }
                "bluetoothSettings" -> { activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)); result.success(null) }
                "bluetoothDevices" -> if (bluetoothAllowed(result)) {
                    val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
                    check(adapter?.isEnabled == true) { "Turn Bluetooth on in Android settings first." }
                    result.success(adapter!!.bondedDevices.map { mapOf("name" to (it.name ?: it.address), "address" to it.address) })
                }
                "discover" -> discover(result)
                "connect" -> connect(call, result)
                "disconnect" -> { disconnectAll(); result.success(null) }
                "forget" -> { disconnectAll(); prefs.edit().clear().apply(); result.success(null) }
                "command" -> sendCompanion(JSONObject(call.arguments as String), result)
                "control" -> controls.control(JSONObject(call.arguments as String), result)
                "remoteScreen" -> { controls.screenActive = call.arguments == true; if (!controls.screenActive) controls.release(); result.success(null) }
                "linkBluetooth" -> if (bluetoothAllowed(result)) {
                    val address = call.arguments as String
                    val id = prefs.getString("deviceId", "")!!
                    val device = context.getSystemService(BluetoothManager::class.java)!!.adapter.bondedDevices.singleOrNull { it.address == address } ?: error("Pair this TV in Android Bluetooth settings first.")
                    linkHid(device); result.success(null)
                }
                "bluetoothScan" -> if (scanAllowed(result)) {
                    val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
                    check(adapter?.isEnabled == true) { "Turn Bluetooth on in Android settings first." }
                    registerScanReceiver()
                    runCatching { adapter!!.cancelDiscovery() }
                    scanFound.clear()
                    adapter!!.bondedDevices.forEach { scanFound[it.address] = it }
                    scanning = adapter.startDiscovery()
                    result.success(null)
                }
                "bluetoothScanResults" -> result.success(mapOf("scanning" to scanning, "devices" to scanDevices()))
                "bluetoothScanStop" -> { stopScan(); result.success(null) }
                "bluetoothPair" -> if (scanAllowed(result)) pairDevice(call.arguments as String, result)
                "enableBluetoothRemote" -> if (bluetoothAllowed(result)) { ensureBluetooth(); result.success(null) }
                "pairBluetooth" -> if (bluetoothAllowed(result)) {
                    if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE), 813)
                        result.error("permission", "Allow Nearby devices, then choose Pair Bluetooth again.", null); return
                    }
                    prefs.edit().putBoolean("hidEnabled", true).apply(); startService()
                    activity.startActivity(Intent(android.bluetooth.BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).putExtra(android.bluetooth.BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { connecting = false; result.error("companion", e.message, null) }
    }

    /** Launcher registered for the current QR scan; unregistered as soon as the scan ends. */
    private var scanLauncher: androidx.activity.result.ActivityResultLauncher<com.journeyapps.barcodescanner.ScanOptions>? = null
    /** Flutter result waiting for the current QR scan. */
    private var scanResult: MethodChannel.Result? = null

    /**
     * Opens the ZXing scanner for the TV pairing QR. Replies with the QR text, null when the
     * user backs out, or a permission error when camera access was refused. The scanner screen
     * asks for the camera permission itself.
     */
    private fun scanPairing(result: MethodChannel.Result) {
        val unavailable = "QR scanner unavailable. Use the TV address and code instead."
        val host = activity as? androidx.activity.ComponentActivity
        if (host == null) { result.error("scan", unavailable, null); return }
        // A scan still waiting (e.g. its screen was lost) ends as a cancel before the new one starts.
        scanResult?.success(null); scanResult = null
        scanLauncher?.unregister(); scanLauncher = null
        val options = com.journeyapps.barcodescanner.ScanOptions()
            .setDesiredBarcodeFormats(com.journeyapps.barcodescanner.ScanOptions.QR_CODE)
            .setPrompt("Scan the QR code shown on the TV")
            .setBeepEnabled(false)
            .setOrientationLocked(true)
        val launcher = host.activityResultRegistry.register("zangetsu.pairingQr", com.journeyapps.barcodescanner.ScanContract()) { scan ->
            val pending = scanResult
            scanResult = null
            scanLauncher?.unregister(); scanLauncher = null
            when {
                scan.contents != null -> pending?.success(scan.contents)
                context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ->
                    pending?.error("permission", "Allow camera access to scan the TV QR code, or use the TV address and code instead.", null)
                else -> pending?.success(null)
            }
        }
        scanLauncher = launcher
        scanResult = result
        try {
            launcher.launch(options)
        } catch (e: Exception) {
            scanResult = null
            launcher.unregister(); scanLauncher = null
            result.error("scan", unavailable, null)
        }
    }

    /** Returns pairing UI metadata without exposing remembered client credentials. */
    private fun receiverState() = mapOf("hosting" to CompanionReceiver.hosting, "pin" to CompanionReceiver.pin,
        "address" to CompanionReceiver.addresses(), "deviceId" to CompanionReceiver.deviceId, "qr" to CompanionReceiver.qrSecret, "bluetooth" to CompanionReceiver.bluetoothStatus)

    /** Requests Nearby devices permission before accessing bonded devices or radio state. */
    private fun bluetoothAllowed(result: MethodChannel.Result): Boolean {
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 812)
            result.error("permission", "Allow Nearby devices, then select Bluetooth again.", null)
            return false
        }
        return true
    }

    /** Requests the permissions Bluetooth discovery needs (Nearby devices on 12+, location on 11 and older). */
    private fun scanAllowed(result: MethodChannel.Result): Boolean {
        val needed = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (needed.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) return true
        activity.requestPermissions(needed, 814)
        result.error("permission", "Allow Nearby devices, then choose Pair a new Bluetooth TV again.", null)
        return false
    }

    /** Saves a bonded TV as the HID host and restarts the remote service on it (shared by link and pair). */
    private fun linkHid(device: BluetoothDevice) {
        val address = device.address
        val id = prefs.getString("deviceId", "")!!
        controls.release()
        RemoteConnectionService.instance?.stopRemote()
        prefs.edit().putString("hid.$id", address).putString("hidAddress", address).putString("hidName", device.name ?: "TV").putBoolean("hidEnabled", true).apply()
        startService(); ensureBluetooth()
    }

    // Bluetooth search state. Touched only on the main thread (method channel + receiver).
    private val scanFound = linkedMapOf<String, BluetoothDevice>()
    private var scanning = false
    private var scanReceiver: BroadcastReceiver? = null
    private var scanStopRequested = false
    private var pairResult: MethodChannel.Result? = null
    private var pairAddress: String? = null
    private var pairSawBonding = false
    private var pairTimeout: Runnable? = null

    /** Reads the device from a Bluetooth broadcast, using the typed API on Android 14+. */
    @Suppress("DEPRECATION")
    private fun deviceExtra(intent: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= 34) intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        else intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)

    /** Registers the discovery / bond receiver once; system broadcasts need RECEIVER_EXPORTED on 33+. */
    private fun registerScanReceiver() {
        scanStopRequested = false
        if (scanReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND, BluetoothDevice.ACTION_NAME_CHANGED -> deviceExtra(intent)?.let { scanFound[it.address] = it }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> scanning = false
                    BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                        val device = deviceExtra(intent) ?: return
                        if (scanFound.containsKey(device.address)) scanFound[device.address] = device
                        if (device.address != pairAddress) return
                        when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                            BluetoothDevice.BOND_BONDING -> pairSawBonding = true
                            BluetoothDevice.BOND_BONDED -> finishPair(device, null)
                            BluetoothDevice.BOND_NONE -> if (pairSawBonding) finishPair(null, "The TV did not accept pairing. Check the code on the TV and try again.")
                        }
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND); addAction(BluetoothDevice.ACTION_NAME_CHANGED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED); addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED) else context.registerReceiver(receiver, filter)
        scanReceiver = receiver
    }

    /** Removes the discovery / bond receiver if it is registered. */
    private fun unregisterScanReceiver() {
        scanReceiver?.let { r -> runCatching { context.unregisterReceiver(r) } }
        scanReceiver = null
    }

    /** Stops discovery; the receiver stays only while a pairing still waits for the TV. */
    private fun stopScan() {
        runCatching { context.getSystemService(BluetoothManager::class.java)?.adapter?.cancelDiscovery() }
        scanning = false
        scanStopRequested = true
        if (pairResult == null) unregisterScanReceiver()
    }

    /** Lists found devices, TVs first, then already-paired ones, then by name. */
    private fun scanDevices(): List<Map<String, Any>> {
        val tvWords = listOf("tv", "android tv", "chromecast", "shield", "fire")
        return scanFound.values.mapNotNull { d ->
            val name = runCatching { d.name }.getOrNull()
            val lower = name?.lowercase() ?: ""
            val major = runCatching { d.bluetoothClass?.majorDeviceClass }.getOrNull()
            val tv = major == BluetoothClass.Device.Major.AUDIO_VIDEO || tvWords.any { lower.contains(it) }
            if (name.isNullOrBlank() && !tv) return@mapNotNull null
            val bond = runCatching { d.bondState }.getOrDefault(BluetoothDevice.BOND_NONE)
            mapOf("name" to (name?.takeIf { it.isNotBlank() } ?: d.address), "address" to d.address,
                "bonded" to (bond == BluetoothDevice.BOND_BONDED), "tv" to tv,
                "bonding" to (bond == BluetoothDevice.BOND_BONDING || d.address == pairAddress))
        }.sortedWith(compareBy<Map<String, Any>>({ it["tv"] != true }, { it["bonded"] != true }, { (it["name"] as String).lowercase() }))
    }

    /** Bonds with the chosen TV (the TV shows a code to confirm), then links it as the HID host. */
    private fun pairDevice(address: String, result: MethodChannel.Result) {
        pairResult?.let { pending ->
            // The sheet was reopened while the same TV still waits for its code: hand the wait to the new request.
            check(address == pairAddress) { "Already pairing with another TV. Wait a minute, then try again." }
            pairResult = result
            pending.error("companion", "Pairing moved to a newer request.", null)
            return
        }
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        check(adapter?.isEnabled == true) { "Turn Bluetooth on in Android settings first." }
        runCatching { adapter!!.cancelDiscovery() }
        scanning = false
        val device = adapter!!.getRemoteDevice(address)
        if (device.bondState == BluetoothDevice.BOND_BONDED) { linkHid(device); result.success(mapOf("name" to (device.name ?: "TV"), "address" to address)); return }
        val keepStop = scanStopRequested
        registerScanReceiver(); scanStopRequested = keepStop
        pairResult = result; pairAddress = address; pairSawBonding = device.bondState == BluetoothDevice.BOND_BONDING
        val timeout = Runnable { finishPair(null, "Pairing timed out. Keep the TV on its Bluetooth screen and try again.") }
        pairTimeout = timeout; main.postDelayed(timeout, 60000)
        // Answer through finishPair only, so handle()'s catch can never reply a second time.
        try {
            if (!pairSawBonding && !device.createBond()) finishPair(null, "The TV did not accept pairing. Check the code on the TV and try again.")
        } catch (e: Exception) { finishPair(null, e.message ?: "Pairing failed. Try again.") }
    }

    /** Answers the pending pair request exactly once and releases its timer. */
    private fun finishPair(device: BluetoothDevice?, error: String?) {
        val result = pairResult ?: return
        pairResult = null; pairAddress = null; pairSawBonding = false
        pairTimeout?.let { main.removeCallbacks(it) }; pairTimeout = null
        if (scanStopRequested) unregisterScanReceiver()
        if (device == null) { result.error("companion", error, null); return }
        try {
            linkHid(device)
            result.success(mapOf("name" to (device.name ?: "TV"), "address" to device.address))
        } catch (e: Exception) { result.error("companion", e.message, null) }
    }

    /** Reports authenticated companion availability independently of system HID navigation. */
    fun isCompanionConnected() = paired
    /** Open authenticated companion links keyed by transport ("Wi-Fi" / "Bluetooth"). */
    private val links = java.util.concurrent.ConcurrentHashMap<String, CompanionSocket>()
    /** Transports currently connecting, so one transport never opens twice at once. */
    private val opening = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    /** Runs blocking connect + pairing handshakes, one thread per transport. */
    private val connectors = Executors.newCachedThreadPool()
    /** Decides per button whether input goes over HID or the companion link. */
    private val controls by lazy { RemoteControls(this, context) }
    /** Releases input immediately when the owning screen loses focus. */
    fun releaseControl() = controls.release()
    /** Delegates hardware volume only while the remote screen is active. */
    fun hardwareVolume(event: android.view.KeyEvent) = controls.hardwareVolume(event)
    /** Routes background notification input through the same foreground control policy. */
    fun notificationControl(action: String) = controls.notification(action)
    /** Opts out of automatic reconnect and closes companion plus HID connections. */
    fun disconnectAll() {
        controls.release()
        prefs.edit().putBoolean("autoConnect", false).putBoolean("hidEnabled", false).putBoolean("remoteMode", false).apply()
        disconnect()
        context.stopService(Intent(context, RemoteConnectionService::class.java))
    }
    /** Starts the Android foreground owner before enabling persistent remote controls. */
    private fun startService() {
        val intent = Intent(context, RemoteConnectionService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }
    /** Restores a verified bonded-device association without guessing between ambiguous TVs. */
    private fun ensureBluetooth() {
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) return
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        if (!adapter.isEnabled) return
        val id = prefs.getString("deviceId", "")!!
        var address = prefs.getString("hid.$id", null)
        val verified = address != null
        if (id.isEmpty()) address = prefs.getString("hidAddress", null)
        if (address == null && id.isNotEmpty()) {
            val names = setOf(prefs.getString("name", ""), prefs.getString("bluetoothName", ""))
            val matches = adapter.bondedDevices.filter { it.name != null && it.name in names }
            if (matches.size == 1) address = matches.single().address
        }
        if (address == null) return
        if (!verified && id.isNotEmpty()) {
            if (!opening.contains("Bluetooth")) connect(MethodCall("connect", mapOf("bluetooth" to address, "expectedId" to id, "background" to true)), silent)
            return
        }
        prefs.edit().putString("hid.$id", address).putString("hidAddress", address).putBoolean("hidEnabled", true).apply()
        startService()
        RemoteConnectionService.instance?.ensure()
        if (links["Bluetooth"] == null && !opening.contains("Bluetooth") && id.isNotEmpty()) {
            connect(MethodCall("connect", mapOf("bluetooth" to address, "expectedId" to id, "background" to true)), silent)
        }
    }
    /** Discards the reply; used for background reconnects nobody on screen waits for. */
    private val silent = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) {}
        override fun notImplemented() {}
    }
    /**
     * Selects one authenticated transport per request; failure never replays it on the fallback.
     * [command] is a JSON object with an `action`; the TV's JSON reply goes to [result] as a string
     * on the main thread. A failed exchange closes that link, quietly reopens the saved link, and
     * retries the command once only when it is read-only (see [recoverCompanion]). If the retry
     * fails too, no second reconnect runs: the link is reported as lost, the same as the iPhone's
     * AppleCompanion._exchange. A request that finds no link while that reconnect runs was never
     * sent, so it waits for the reconnect and is sent once.
     */
    fun sendCompanion(command: JSONObject, result: MethodChannel.Result) = sendCompanion(command, result, generation, false)

    /** Actions that only read from the TV, so sending them twice can never do something twice. */
    private val retryableActions = setOf("state", "catalogues", "search", "detail", "handoffSnapshot", "handoffSources", "handoffValidate")

    /**
     * Runs one exchange on the preferred link. [gen] is the connection generation the request
     * started under; [retried] is true for the single retry after a reconnect.
     */
    private fun sendCompanion(command: JSONObject, result: MethodChannel.Result, gen: Int, retried: Boolean) {
        worker.execute {
            // Select exactly once. Never retry a possibly delivered action on another link.
            val route = links["Bluetooth"]?.takeIf { it.alive } ?: links["Wi-Fi"]?.takeIf { it.alive }
            if (route == null) {
                // Nothing went out yet, so even a key press is safe to send once on the new link.
                if (!retried && recovering.get() > 0) { recovering.incrementAndGet(); main.post { recoverCompanion(command, result, gen, false, null, sent = false) } }
                else main.post { result.error("connection", "The TV companion is disconnected.", null) }
                return@execute
            }
            val timeout = Runnable { route.close() }
            main.postDelayed(timeout, if (command.optString("action") == "state") 4000 else 90000)
            try {
                check(gen == generation) { "Connection changed" }
                lastRequest = android.os.SystemClock.elapsedRealtime()
                val response = route.exchange(command)
                check(gen == generation) { "Connection changed" }
                main.post {
                    main.removeCallbacks(timeout)
                    if (response.has("active")) controls.updateState(response)
                    result.success(response.toString())
                }
            } catch (e: Exception) {
                // The failed link is dead from here on; it is never reused mid-frame.
                route.close()
                recovering.incrementAndGet()
                val kind = links.entries.firstOrNull { it.value === route }?.key
                links.entries.removeIf { it.value === route }
                android.util.Log.w("ZangetsuRemote", "Companion ${command.optString("action")} failed", e)
                main.post { main.removeCallbacks(timeout); recoverCompanion(command, result, gen, retried, kind, sent = true) }
            }
        }
    }

    /**
     * Main thread, after a failed exchange on the [kind] link. Reopens that link with the remembered
     * token (the same path the maintenance loop uses) so the session stays connected, then retries a
     * read-only [command] once. Key presses, playback and keyboard commands are never sent again; they
     * get an error asking to try again. [sent] is false for a request that never reached the TV;
     * it is sent once on the new link whatever it is. A failed retry ([retried]) skips the
     * reconnect and reports the companion as unavailable, as does a failed reconnect. The caller
     * has already counted this request into [recovering]; it is counted out once, when it finishes.
     */
    private fun recoverCompanion(command: JSONObject, result: MethodChannel.Result, gen: Int, retried: Boolean, kind: String?, sent: Boolean) {
        val retry = !retried && (!sent || command.optString("action") in retryableActions)
        var done = false
        val finish = finish@{ up: Boolean ->
            if (done) return@finish
            done = true
            recovering.decrementAndGet()
            if (!up || retried || gen != generation) {
                controls.clearState()
                result.error("connection", "Zangetsu companion unavailable. Bluetooth TV controls remain available when connected.", null)
            } else if (retry) sendCompanion(command, result, gen, true)
            else result.error("connection", "The TV did not confirm that. Try again.", null)
        }
        if (retried || gen != generation || !prefs.getBoolean("autoConnect", false)) { finish(false); return }
        if (paired) { finish(true); return }
        val id = prefs.getString("deviceId", "") ?: ""
        // Without Nearby devices permission a Bluetooth reopen would prompt; use Wi-Fi then.
        val mayUseBluetooth = Build.VERSION.SDK_INT < 31 || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        val bluetooth = if (kind == "Bluetooth" && mayUseBluetooth) prefs.getString("hid.$id", null) else null
        val address = prefs.getString("address", "") ?: ""
        val args = when {
            bluetooth != null && id.isNotEmpty() -> mapOf("bluetooth" to bluetooth, "expectedId" to id, "background" to true)
            address.isNotEmpty() -> mapOf("address" to address, "background" to true)
            else -> { finish(false); return }
        }
        val opened = if (args.containsKey("bluetooth")) "Bluetooth" else "Wi-Fi"
        try {
            connect(MethodCall("connect", args), object : MethodChannel.Result {
                override fun success(value: Any?) { finish(paired) }
                override fun error(code: String, message: String?, details: Any?) {
                    // Another reconnect of this link is already running: wait for it instead.
                    if (code == "connecting") awaitLink(opened, android.os.SystemClock.elapsedRealtime() + 12000, finish) else finish(false)
                }
                override fun notImplemented() { finish(false) }
            })
        } catch (_: Exception) { connecting = opening.isNotEmpty(); finish(false) }
    }

    /** Main thread: checks every 250 ms until [kind] stops opening or [deadline] passes, then reports whether a link is up. */
    private fun awaitLink(kind: String, deadline: Long, done: (Boolean) -> Unit) {
        if (paired || !opening.contains(kind) || android.os.SystemClock.elapsedRealtime() > deadline) { done(paired); return }
        main.postDelayed({ awaitLink(kind, deadline, done) }, 250)
    }
    /** Probes idle fallback sockets with read-only state requests, never playback actions. */
    private fun keepStandbyAlive() {
        if (links["Bluetooth"]?.alive != true) return
        val standby = links["Wi-Fi"]?.takeIf { it.alive } ?: return
        if (android.os.SystemClock.elapsedRealtime() - standby.lastActivity < 14000) return
        worker.execute {
            if (!standby.alive || links["Wi-Fi"] !== standby) return@execute
            val timeout = Runnable { standby.close() }
            main.postDelayed(timeout, 4000)
            try { standby.exchange(JSONObject().put("action", "state")) }
            catch (_: Exception) { standby.close(); links.remove("Wi-Fi", standby) }
            finally { main.removeCallbacks(timeout) }
        }
    }
    /**
     * Authenticates each transport independently before adding it to the active receiver mapping.
     * Args: `address` (host:port) or `bluetooth` (MAC), plus `pin` / `qr` for a first pairing,
     * `expectedId` to insist on a known TV and `background` for silent reconnects. Handshake:
     * TV challenge (nonce + ECDH key) -> phone hello with proof -> TV `paired` reply with its proof.
     */
    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val pin = call.argument<String>("pin") ?: ""
        val qr = call.argument<String>("qr") ?: ""
        require(pin.isEmpty() || pin.matches(Regex("[0-9]{6}"))) { "Enter the TV code or scan its QR." }
        require(qr.isEmpty() || qr.matches(Regex("[a-f0-9]{64}"))) { "Invalid QR code." }
        val bluetooth = call.argument<String>("bluetooth")
        val kind = if (bluetooth == null) "Wi-Fi" else "Bluetooth"
        if (!opening.add(kind)) { result.error("connecting", "Already connecting $kind", null); return }
        if (bluetooth != null && !bluetoothAllowed(result)) { opening.remove(kind); return }
        val background = call.argument<Boolean>("background") == true
        if (!background && (pin.isNotEmpty() || qr.isNotEmpty())) {
            // Changing the paired TV must also release the old system remote.
            prefs.edit().putBoolean("autoConnect", false).putBoolean("hidEnabled", false).apply()
            controls.release(); RemoteConnectionService.instance?.stopRemote(); disconnect()
        }
        val gen = generation
        connecting = true
        connectors.execute {
            var socket: Closeable? = null
            var timer: Runnable? = null
            try {
                val streams = if (bluetooth != null) {
                    val bt = context.getSystemService(BluetoothManager::class.java)!!.adapter.getRemoteDevice(bluetooth).createRfcommSocketToServiceRecord(CompanionReceiver.uuid)
                    socket = bt
                    timer = Runnable { runCatching { bt.close() } }; main.postDelayed(timer!!, 10000)
                    bt.connect(); bt.inputStream to bt.outputStream
                } else {
                    val address = call.argument<String>("address") ?: prefs.getString("address", "")!!
                    val parts = address.split(":")
                    require(parts.size == 2 && (parts[1].toIntOrNull() ?: 0) in 1..65535) { "Enter the TV address shown in settings." }
                    val tcp = Socket().apply { tcpNoDelay = true; soTimeout = 95000 }; socket = tcp
                    timer = Runnable { runCatching { tcp.close() } }; main.postDelayed(timer!!, 10000)
                    tcp.connect(InetSocketAddress(parts[0], parts[1].toInt()), 7000)
                    tcp.inputStream to tcp.outputStream
                }
                val link = CompanionSocket(socket!!, streams.first, streams.second)
                val challenge = CompanionReceiver.readFrame(link.reader)
                check(challenge.optString("type") == "challenge") { "Unsupported TV receiver" }
                check(challenge.optInt("version") == CompanionReceiver.pairingVersion) { CompanionReceiver.oldTvError }
                val id = challenge.getString("deviceId")
                val expected = call.argument<String>("expectedId") ?: if (pin.isEmpty() && qr.isEmpty()) prefs.getString("deviceId", null) else null
                check(expected == null || id == expected) { "This is a different TV. Scan it before connecting." }
                val clientId = prefs.getString("clientId", null) ?: java.util.UUID.randomUUID().toString().also { prefs.edit().putString("clientId", it).apply() }
                val mode = if (qr.isNotEmpty()) "qr" else if (pin.isNotEmpty()) "pin" else "remembered"
                val secret = if (qr.isNotEmpty()) qr else if (pin.isNotEmpty()) pin else prefs.getString("token.$id", null)
                check(!secret.isNullOrEmpty()) { "Scan this TV once to connect." }
                val pairSecret = secret!!
                val nonce = challenge.optString("nonce")
                val tvKey = challenge.optString("key")
                check(nonce.matches(CompanionReceiver.noncePattern) && tvKey.matches(CompanionReceiver.pairingKeyPattern)) { "Unsupported TV receiver" }
                // Both sides derive the remembered token by ECDH, so the TV never sends it in the clear.
                // Both public keys go into the proofs, so a key swapped on the network makes both proofs fail.
                val pairingKey = if (mode != "remembered") CompanionReceiver.newPairingKey() else null
                val clientKey = pairingKey?.let { CompanionReceiver.pairingKeyHex(it) } ?: ""
                val hello = JSONObject().put("version", CompanionReceiver.pairingVersion).put("clientId", clientId).put("mode", mode)
                    .put("proof", CompanionReceiver.pairingProof(pairSecret, "phone", mode, nonce, tvKey, clientKey, clientId))
                if (pairingKey != null) hello.put("key", clientKey)
                link.writer.write(hello.toString()); link.writer.newLine(); link.writer.flush()
                val reply = CompanionReceiver.readFrame(link.reader)
                check(reply.optString("type") == "paired") { reply.optString("error", "Scan the TV again.") }
                // The TV proves it holds the same secret and saw the same keys before anything it sent is trusted.
                check(!reply.has("token") && CompanionReceiver.proofMatches(
                    CompanionReceiver.pairingProof(pairSecret, "tv", mode, nonce, tvKey, clientKey, clientId), reply.optString("proof"),
                )) { "The TV could not prove its identity. Scan it again." }
                check(gen == generation) { "Connection cancelled" }
                val connectedName = reply.optString("name", "TV")
                val edit = prefs.edit().putBoolean("autoConnect", true).putString("deviceId", id).putString("name", connectedName)
                    .putString("bluetoothName", reply.optString("bluetoothName", connectedName))
                if (bluetooth == null) edit.putString("address", call.argument<String>("address") ?: prefs.getString("address", ""))
                else edit.putString("hid.$id", bluetooth).putString("hidAddress", bluetooth).putBoolean("hidEnabled", true)
                if (pairingKey != null)
                    edit.putString("token.$id", CompanionReceiver.pairingToken(CompanionReceiver.pairingShared(pairingKey, tvKey), nonce, clientId))
                main.post {
                    timer?.let(main::removeCallbacks); opening.remove(kind); connecting = opening.isNotEmpty()
                    if (gen != generation) { link.close(); result.error("connection", "Connection changed", null); return@post }
                    name = connectedName; edit.apply(); links.put(kind, link)?.close()
                    startService(); ensureBluetooth(); result.success(null)
                }
            } catch (e: Exception) {
                runCatching { socket?.close() }
                main.post { timer?.let(main::removeCallbacks); opening.remove(kind); connecting = opening.isNotEmpty(); result.error("connection", e.message, null) }
            }
        }
    }
    /** Combines bounded NSD and LAN discovery and releases the multicast lock on completion. */
    private fun discover(result: MethodChannel.Result) {
        check(discoveryResult == null) { "Already searching for TVs." }
        val nsd = context.getSystemService(NsdManager::class.java)
        val found = linkedMapOf<String, String>()
        discoveryResult = result
        runCatching {
            multicastLock = context.getSystemService(android.net.wifi.WifiManager::class.java)
                .createMulticastLock("zangetsu-discovery").apply { setReferenceCounted(false); acquire() }
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { finishDiscovery(emptyList()) } }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val host = info.host?.hostAddress ?: return
                        main.post {
                            found[info.serviceName] = "$host:${info.port}"
                            if (!paired && info.attributes["deviceId"]?.toString(Charsets.UTF_8) == prefs.getString("deviceId", null)) {
                                prefs.edit().putString("address", "$host:${info.port}").apply()
                            }
                        }
                    }
                })
            }
        }
        discovery = listener
        worker.execute {
            runCatching {
                java.net.DatagramSocket().use { udp ->
                    udp.broadcast = true; udp.soTimeout = 500
                    val message = "ZANGETSU_DISCOVER_V1".toByteArray(Charsets.UTF_8)
                    val addresses = java.net.NetworkInterface.getNetworkInterfaces().toList()
                        .flatMap { it.interfaceAddresses }.mapNotNull { it.broadcast }.toMutableSet()
                    addresses.add(java.net.InetAddress.getByName("255.255.255.255"))
                    for (address in addresses) runCatching {
                        udp.send(java.net.DatagramPacket(message, message.size, address, CompanionReceiver.discoveryPort))
                    }
                    val deadline = android.os.SystemClock.elapsedRealtime() + 3000
                    while (android.os.SystemClock.elapsedRealtime() < deadline) {
                        try {
                            val packet = java.net.DatagramPacket(ByteArray(1024), 1024)
                            udp.receive(packet)
                            val data = JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                            if (data.optString("service") != "zangetsu-remote") continue
                            val port = data.optInt("port")
                            if (port !in 1..65535) continue
                            val host = "${packet.address.hostAddress}:$port"
                            main.post {
                                if (discovery === listener) found["${data.optString("name", "TV")} · $host"] = host
                                if (!paired && data.optString("deviceId") == prefs.getString("deviceId", null)) prefs.edit().putString("address", host).apply()
                            }
                        } catch (_: java.net.SocketTimeoutException) { /* bounded receive */ }
                    }
                }
            }
        }
        try { nsd.discoverServices(CompanionReceiver.serviceType, NsdManager.PROTOCOL_DNS_SD, listener) }
        catch (e: Exception) { finishDiscovery(emptyList()); return }
        main.postDelayed({ if (discovery === listener) finishDiscovery(found.map { mapOf("name" to it.key, "address" to it.value) }) }, 4000)
    }

    /** Completes discovery once and releases browser/timeout resources. */
    private fun finishDiscovery(items: List<Map<String, String>>) {
        runCatching { multicastLock?.release() }; multicastLock = null
        discovery?.let { runCatching { context.getSystemService(NsdManager::class.java).stopServiceDiscovery(it) } }
        discovery = null
        discoveryResult?.success(items); discoveryResult = null
    }

    /** Invalidates in-flight connection work before clearing sockets and playback state. */
    private fun disconnect() { generation++; links.values.forEach { it.close() }; links.clear(); controls.clearState() }
    /** Stops executors and discovery when the application-owned bridge is disposed. */
    fun close() { finishPair(null, "Pairing cancelled."); stopScan(); connectors.shutdownNow(); scheduler.shutdownNow(); disconnect(); finishDiscovery(emptyList()); worker.shutdownNow() }
}
