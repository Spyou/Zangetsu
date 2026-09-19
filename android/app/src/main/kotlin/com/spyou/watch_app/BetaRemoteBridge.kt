package com.spyou.watch_app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Intent
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

/** Transport only. The companion UI lives in the app's Flutter settings. */
class BetaRemoteBridge(activity: Activity) {
    companion object {
        var shared: BetaRemoteBridge? = null; private set
        fun attach(activity: Activity): BetaRemoteBridge = (shared ?: BetaRemoteBridge(activity).also { shared = it }).also {
            it.ui = java.lang.ref.WeakReference(activity)
        }
    }
    private var ui = java.lang.ref.WeakReference(activity)
    private val context = activity.applicationContext
    private val activity: Activity get() = ui.get() ?: error("Open Zangetsu to change this setting.")
    @Volatile private var connecting = false
    @Volatile private var lastRequest = android.os.SystemClock.elapsedRealtime()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private var lastMaintenance = 0L
    private var backgroundPoll = false
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
    fun detach(owner: Activity) { if (ui.get() === owner) ui.clear() }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var generation = 0
    private var discovery: NsdManager.DiscoveryListener? = null
    private var discoveryResult: MethodChannel.Result? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null
    private val prefs = context.getSharedPreferences("beta_pairing", Activity.MODE_PRIVATE)
    private val paired get() = links.values.any { it.alive }
    private var name = "TV"
    private val transport get() = if (links["Bluetooth"]?.alive == true) "Bluetooth" else "Wi-Fi"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "restoreReceiver" -> {
                    if (prefs.getBoolean("receiverEnabled", false)) {
                        BetaLink.start(activity)
                        runCatching { BetaLink.startBluetooth(activity) }
                    }
                    result.success(null)
                }
                "connectionState" -> result.success(mapOf("connected" to (paired || BetaConnectionService.instance?.isConnected() == true), "companion" to paired, "hid" to (BetaConnectionService.instance?.isConnected() == true), "bluetoothDetail" to (BetaConnectionService.instance?.detail ?: "Link Bluetooth in Manage"), "wifi" to (links["Wi-Fi"]?.alive == true), "bluetoothCompanion" to (links["Bluetooth"]?.alive == true), "saved" to (prefs.getBoolean("autoConnect", false) || prefs.getBoolean("hidEnabled", false)),
                    "name" to (if(paired) name else prefs.getString("hidName", prefs.getString("name", "TV"))), "transport" to transport, "remoteMode" to prefs.getBoolean("remoteMode", false)))
                "remoteMode" -> { prefs.edit().putBoolean("remoteMode", call.arguments == true).apply(); result.success(null) }
                "reconnect" -> {
                    ensureBluetooth()
                    if (!prefs.getBoolean("autoConnect", false) && prefs.getBoolean("hidEnabled", false)) { result.success(null); return }
                    check(prefs.getBoolean("autoConnect", false)) { "Pair a TV first." }
                    connect(MethodCall("connect", mapOf("address" to prefs.getString("address", ""),
                        "background" to true, "pin" to "")), result)
                }
                "receiverForget" -> { BetaLink.forgetPhones(); result.success(receiverState()) }
                "receiverStream" -> result.success(TvPlayerActivity.active?.betaStream())
                "receiverSkipPrefs" -> { TvPlayerActivity.active?.betaSkipPrefs(JSONObject(call.arguments as Map<*, *>)); result.success(null) }
                "receiverClosePlayer" -> { TvPlayerActivity.active?.finish(); result.success(null) }
                "scanPairing" -> {
                    val options = com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions.Builder()
                        .setBarcodeFormats(com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE).enableAutoZoom().build()
                    com.google.mlkit.vision.codescanner.GmsBarcodeScanning.getClient(activity, options).startScan()
                        .addOnSuccessListener { result.success(it.rawValue) }
                        .addOnCanceledListener { result.success(null) }
                        .addOnFailureListener { result.error("scan", "QR scanner unavailable. Use the TV address and code instead.", null) }
                }
                "lastAddress" -> result.success(prefs.getString("address", ""))
                "receiverState" -> result.success(receiverState())
                "receiverStart" -> { BetaLink.start(activity); runCatching { BetaLink.startBluetooth(activity) }; result.success(receiverState()) }
                "receiverStop" -> { BetaLink.disable(); result.success(receiverState()) }
                "receiverRenew" -> { BetaLink.renewPin(); result.success(receiverState()) }
                "receiverBluetooth" -> if (bluetoothAllowed(result)) {
                    BetaLink.start(activity); BetaLink.startBluetooth(activity); result.success(receiverState())
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
                    controls.release()
                    BetaConnectionService.instance?.stopRemote()
                    prefs.edit().putString("hid.$id", address).putString("hidAddress", address).putString("hidName", device.name ?: "TV").putBoolean("hidEnabled", true).apply()
                    startService(); ensureBluetooth(); result.success(null)
                }
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

    private fun receiverState() = mapOf("hosting" to BetaLink.hosting, "pin" to BetaLink.pin,
        "address" to BetaLink.addresses(), "deviceId" to BetaLink.deviceId, "qr" to BetaLink.qrSecret, "bluetooth" to BetaLink.bluetoothStatus)

    private fun bluetoothAllowed(result: MethodChannel.Result): Boolean {
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 812)
            result.error("permission", "Allow Nearby devices, then select Bluetooth again.", null)
            return false
        }
        return true
    }

    fun isCompanionConnected() = paired
    private val links = java.util.concurrent.ConcurrentHashMap<String, BetaSocket>()
    private val opening = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val connectors = Executors.newCachedThreadPool()
    private val controls by lazy { BetaControls(this, context) }
    fun releaseControl() = controls.release()
    fun hardwareVolume(event: android.view.KeyEvent) = controls.hardwareVolume(event)
    fun notificationControl(action: String) = controls.notification(action)
    fun disconnectAll() {
        controls.release()
        prefs.edit().putBoolean("autoConnect", false).putBoolean("hidEnabled", false).putBoolean("remoteMode", false).apply()
        disconnect()
        context.stopService(Intent(context, BetaConnectionService::class.java))
    }
    private fun startService() {
        val intent = Intent(context, BetaConnectionService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }
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
        BetaConnectionService.instance?.ensure()
        if (links["Bluetooth"] == null && !opening.contains("Bluetooth") && id.isNotEmpty()) {
            connect(MethodCall("connect", mapOf("bluetooth" to address, "expectedId" to id, "background" to true)), silent)
        }
    }
    private val silent = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) {}
        override fun notImplemented() {}
    }
    fun sendCompanion(command: JSONObject, result: MethodChannel.Result) {
        val gen = generation
        worker.execute {
            // Select exactly once. Never retry a possibly delivered action on another link.
            val route = links["Bluetooth"]?.takeIf { it.alive } ?: links["Wi-Fi"]?.takeIf { it.alive }
            if (route == null) { main.post { result.error("connection", "The TV companion is disconnected.", null) }; return@execute }
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
                route.close()
                links.entries.removeIf { it.value === route }
                android.util.Log.w("ZangetsuRemote", "Companion ${command.optString("action")} failed", e)
                main.post { main.removeCallbacks(timeout); controls.clearState(); result.error("connection", "Zangetsu companion unavailable. Bluetooth TV controls remain available when connected.", null) }
            }
        }
    }
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
            controls.release(); BetaConnectionService.instance?.stopRemote(); disconnect()
        }
        val gen = generation
        connecting = true
        connectors.execute {
            var socket: Closeable? = null
            var timer: Runnable? = null
            try {
                val streams = if (bluetooth != null) {
                    val bt = context.getSystemService(BluetoothManager::class.java)!!.adapter.getRemoteDevice(bluetooth).createRfcommSocketToServiceRecord(BetaLink.uuid)
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
                val link = BetaSocket(socket!!, streams.first, streams.second)
                val challenge = BetaLink.readFrame(link.reader)
                check(challenge.optString("type") == "challenge" && challenge.optInt("version") == 1) { "Unsupported TV receiver" }
                val id = challenge.getString("deviceId")
                val expected = call.argument<String>("expectedId") ?: if (pin.isEmpty() && qr.isEmpty()) prefs.getString("deviceId", null) else null
                check(expected == null || id == expected) { "This is a different TV. Scan it before connecting." }
                val clientId = prefs.getString("clientId", null) ?: java.util.UUID.randomUUID().toString().also { prefs.edit().putString("clientId", it).apply() }
                val mode = if (qr.isNotEmpty()) "qr" else if (pin.isNotEmpty()) "pin" else "remembered"
                val secret = if (qr.isNotEmpty()) qr else if (pin.isNotEmpty()) pin else prefs.getString("token.$id", null)
                check(!secret.isNullOrEmpty()) { "Scan this TV once to connect." }
                val hello = JSONObject().put("clientId", clientId).put("mode", mode).put("proof", BetaLink.proof(secret!!, challenge.getString("nonce")))
                link.writer.write(hello.toString()); link.writer.newLine(); link.writer.flush()
                val reply = BetaLink.readFrame(link.reader)
                check(reply.optString("type") == "paired") { reply.optString("error", "Scan the TV again.") }
                check(gen == generation) { "Connection cancelled" }
                val connectedName = reply.optString("name", "TV")
                val edit = prefs.edit().putBoolean("autoConnect", true).putString("deviceId", id).putString("name", connectedName)
                    .putString("bluetoothName", reply.optString("bluetoothName", connectedName))
                if (bluetooth == null) edit.putString("address", call.argument<String>("address") ?: prefs.getString("address", ""))
                else edit.putString("hid.$id", bluetooth).putString("hidAddress", bluetooth).putBoolean("hidEnabled", true)
                if (reply.has("token")) edit.putString("token.$id", reply.getString("token"))
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
                        udp.send(java.net.DatagramPacket(message, message.size, address, BetaLink.discoveryPort))
                    }
                    val deadline = android.os.SystemClock.elapsedRealtime() + 3000
                    while (android.os.SystemClock.elapsedRealtime() < deadline) {
                        try {
                            val packet = java.net.DatagramPacket(ByteArray(1024), 1024)
                            udp.receive(packet)
                            val data = JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                            if (data.optString("service") != "zangetsu-beta") continue
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
        try { nsd.discoverServices(BetaLink.serviceType, NsdManager.PROTOCOL_DNS_SD, listener) }
        catch (e: Exception) { finishDiscovery(emptyList()); return }
        main.postDelayed({ if (discovery === listener) finishDiscovery(found.map { mapOf("name" to it.key, "address" to it.value) }) }, 4000)
    }

    private fun finishDiscovery(items: List<Map<String, String>>) {
        runCatching { multicastLock?.release() }; multicastLock = null
        discovery?.let { runCatching { context.getSystemService(NsdManager::class.java).stopServiceDiscovery(it) } }
        discovery = null
        discoveryResult?.success(items); discoveryResult = null
    }

    private fun disconnect() { generation++; links.values.forEach { it.close() }; links.clear(); controls.clearState() }
    fun close() { connectors.shutdownNow(); scheduler.shutdownNow(); disconnect(); finishDiscovery(emptyList()); worker.shutdownNow() }
}
