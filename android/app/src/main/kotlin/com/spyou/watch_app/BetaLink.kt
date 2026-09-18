package com.spyou.watch_app

import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedReader
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Local, opt-in companion transport. No ADB or remote shell is used here. */
object BetaLink {
    val uuid: UUID = UUID.fromString("c6f0857a-50aa-4b65-9230-888184401761")
    const val serviceType = "_zangetsubeta._tcp."
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()
    private val slots = Semaphore(4)
    private val random = SecureRandom()
    private var server: ServerSocket? = null
    private var discoverySocket: java.net.DatagramSocket? = null
    const val discoveryPort = 41285
    private var bluetooth: BluetoothServerSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var nsd: NsdManager? = null
    private val connections = java.util.concurrent.CopyOnWriteArrayList<Closeable>()
    private var generation = 0
    private var attempts = 0
    private var attemptWindowEnd = 0L
    private var pairingPrefs: android.content.SharedPreferences? = null
    var deviceId = ""; private set
    var pin = ""; private set
    var qrSecret = ""; private set
    var deviceName = android.os.Build.MODEL; private set
    var port = 0; private set
    var bluetoothStatus = "Bluetooth off"; private set
    var channel: MethodChannel? = null
    var activity: Activity? = null
    var catalogueError: String? = null
    val hosting get() = server != null

    fun addresses(): String = try {
        NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it is java.net.Inet4Address }
            .joinToString("\n") { "${it.hostAddress}:$port" }
    } catch (_: Exception) { "Address unavailable" }

    fun start(context: Context) {
        if (hosting) return
        pairingPrefs = context.getSharedPreferences("beta_pairing", Context.MODE_PRIVATE)
        deviceName = android.provider.Settings.Global.getString(context.contentResolver, "device_name") ?: android.os.Build.MODEL
        qrSecret = pairingPrefs!!.getString("qrSecret", null) ?: ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }.also { pairingPrefs!!.edit().putString("qrSecret", it).apply() }
        deviceId = pairingPrefs!!.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
            pairingPrefs!!.edit().putString("deviceId", it).apply()
        }
        pairingPrefs!!.edit().putBoolean("receiverEnabled", true).apply()
        pin = pairingPrefs!!.getString("pairPin", null) ?: (100000 + random.nextInt(900000)).toString().also { pairingPrefs!!.edit().putString("pairPin", it).apply() }
        val savedPort = pairingPrefs!!.getInt("port", 0)
        server = runCatching { ServerSocket(savedPort) }.getOrElse { ServerSocket(0) }.apply { reuseAddress = true }
        port = server!!.localPort
        pairingPrefs!!.edit().putInt("port", port).apply()
        // Some hotspots suppress mDNS. A small UDP beacon provides a second
        // discovery path; pairing still requires the TV's private code.
        runCatching {
            val udp = java.net.DatagramSocket(null).apply {
                reuseAddress = true
                bind(InetSocketAddress(discoveryPort))
            }
            discoverySocket = udp
            workers.execute {
                val bytes = ByteArray(128)
                while (!udp.isClosed) {
                    try {
                        val packet = java.net.DatagramPacket(bytes, bytes.size)
                        udp.receive(packet)
                        if (String(packet.data, 0, packet.length, Charsets.UTF_8) != "ZANGETSU_DISCOVER_V1") continue
                        val reply = JSONObject().put("service", "zangetsu-beta")
                            .put("name", android.os.Build.MODEL).put("deviceId", deviceId).put("port", port).toString().toByteArray(Charsets.UTF_8)
                        udp.send(java.net.DatagramPacket(reply, reply.size, packet.address, packet.port))
                    } catch (_: Exception) { break }
                }
            }
        }
        val listener = server!!
        val gen = generation
        workers.execute {
            while (!listener.isClosed) {
                try {
                    val socket = listener.accept().apply { soTimeout = 15000; tcpNoDelay = true }
                    serve(socket.inputStream, socket.outputStream, socket, gen)
                } catch (_: Exception) { break }
            }
        }
        nsd = context.getSystemService(NsdManager::class.java)
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        try {
            nsd?.registerService(NsdServiceInfo().apply {
                serviceName = "Zangetsu ${android.os.Build.MODEL}"
                serviceType = BetaLink.serviceType
                setPort(port)
                setAttribute("deviceId", deviceId)
            }, NsdManager.PROTOCOL_DNS_SD, registration)
        } catch (_: Exception) { /* Manual address remains available. */ }
    }

    fun renewPin() {
        pin = (100000 + random.nextInt(900000)).toString()
        pairingPrefs?.edit()?.putString("pairPin", pin)?.apply()
        attempts = 0
    }

    fun startBluetooth(context: Context) {
        if (bluetooth != null) return
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: throw IllegalStateException("This device has no Bluetooth adapter")
        check(adapter.isEnabled) { "Turn Bluetooth on in Android settings first" }
        val listener = adapter.listenUsingRfcommWithServiceRecord("Zangetsu", uuid)
        bluetooth = listener
        pairingPrefs?.edit()?.putBoolean("receiverBluetooth", true)?.apply()
        bluetoothStatus = "Bluetooth ready · pair devices in Android settings"
        val gen = generation
        workers.execute {
            while (bluetooth === listener) {
                try {
                    val socket = listener.accept()
                    serve(socket.inputStream, socket.outputStream, socket, gen)
                } catch (_: Exception) { break }
            }
        }
    }

    fun stop() {
        runCatching { discoverySocket?.close() }; discoverySocket = null
        generation++
        runCatching { server?.close() }; server = null
        runCatching { bluetooth?.close() }; bluetooth = null
        registration?.let { runCatching { nsd?.unregisterService(it) } }; registration = null
        connections.forEach { runCatching { it.close() } }; connections.clear()
        pin = ""; port = 0; bluetoothStatus = "Bluetooth off"
    }

    fun forgetPhones() {
        qrSecret = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        pairingPrefs?.edit()?.remove("clients")?.putString("qrSecret", qrSecret)?.apply()
        renewPin()
        connections.forEach { runCatching { it.close() } }
    }
    fun disable() { pairingPrefs?.edit()?.putBoolean("receiverEnabled", false)?.apply(); stop() }

    fun proof(code: String, nonce: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(code.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal(nonce.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    // A hard frame limit prevents a peer from allocating an unbounded readLine.
    fun readFrame(reader: BufferedReader): JSONObject {
        val line = StringBuilder()
        while (line.length < 262144) {
            val c = reader.read()
            if (c == -1) throw java.io.EOFException()
            if (c == 10) return JSONObject(line.toString())
            line.append(c.toChar())
        }
        throw IllegalArgumentException("Message too large")
    }

    private fun serve(input: InputStream, output: OutputStream, connection: Closeable, gen: Int) {
        if (!slots.tryAcquire()) { connection.close(); return }
        connections.add(connection)
        workers.execute {
            val reader = input.bufferedReader(Charsets.UTF_8)
            val writer = output.bufferedWriter(Charsets.UTF_8)
            fun send(message: JSONObject) = synchronized(writer) {
                writer.write(message.toString()); writer.newLine(); writer.flush()
            }
            val timeout = Runnable { runCatching { connection.close() } }
            main.postDelayed(timeout, 15000)
            try {
                val nonce = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
                send(JSONObject().put("type", "challenge").put("nonce", nonce).put("version", 1)
                    .put("deviceId", deviceId).put("name", android.os.Build.MODEL))
                val hello = readFrame(reader)
                val clientId = hello.optString("clientId").takeIf { it.matches(Regex("[a-zA-Z0-9-]{16,64}")) }
                val remembered = hello.optString("mode") == "remembered"
                val allowed = synchronized(this) {
                    val clients = JSONObject(pairingPrefs?.getString("clients", "{}") ?: "{}")
                    val qr = hello.optString("mode") == "qr"
                    val secret = if (remembered && clientId != null) clients.optString(clientId) else if (qr) qrSecret else pin
                    if (SystemClock.elapsedRealtime() > attemptWindowEnd) { attempts = 0; attemptWindowEnd = SystemClock.elapsedRealtime() + 60000 }
                    if (!remembered && !qr) attempts++
                    secret.isNotEmpty() && (remembered || qr || attempts <= 10) &&
                        MessageDigest.isEqual(proof(secret, nonce).toByteArray(), hello.optString("proof").toByteArray())
                }
                if (!allowed || gen != generation) {
                    send(JSONObject().put("error", "Pairing details do not match. Scan the TV QR, or wait a minute after repeated incorrect codes."))
                    return@execute
                }
                main.removeCallbacks(timeout)
                main.postDelayed(timeout, 95000)
                if (connection is Socket) connection.soTimeout = 95000
                val paired = JSONObject().put("type", "paired").put("deviceId", deviceId).put("name", deviceName).put("bluetoothName", deviceName)
                if (!remembered && clientId != null) synchronized(this) {
                    val clients = JSONObject(pairingPrefs?.getString("clients", "{}") ?: "{}")
                    val token = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
                    if (clients.length() >= 10 && !clients.has(clientId)) clients.remove(clients.keys().next())
                    clients.put(clientId, token)
                    pairingPrefs?.edit()?.putString("clients", clients.toString())?.apply()
                    paired.put("token", token)
                }
                send(paired)
                var previousId = 0L

                while (gen == generation) {
                    val command = readFrame(reader)
                    main.removeCallbacks(timeout)
                    main.postDelayed(timeout, 95000)
                    val id = command.optLong("id", -1)
                    check(id > previousId) { "Repeated command" }
                    previousId = id


                    val result = java.util.concurrent.CompletableFuture<JSONObject>()
                    main.post {
                        if (gen != generation) { result.complete(JSONObject().put("error", "Disconnected")); return@post }
                        dispatch(command) { result.complete(it) }
                    }
                    val reply = result.get(90, java.util.concurrent.TimeUnit.SECONDS)
                    send(reply.put("id", id))
                }
            } catch (_: Exception) {
                // Closing a transport is the only reconnect signal. Never replay commands.
            } finally {
                main.removeCallbacks(timeout)
                runCatching { connection.close() }; connections.remove(connection); slots.release()
            }
        }
    }

    private fun dispatch(command: JSONObject, done: (JSONObject) -> Unit) {
        try {
            val action = command.optString("action")
            val player = TvPlayerActivity.active
            if (action == "closePlayer") {
                player?.finish()
                done(JSONObject().put("ok", true))
            } else if (action == "state") {
                done((player?.betaState() ?: JSONObject().put("active", false).put("title", "Choose something to watch on TV").put("playbackError", catalogueError ?: JSONObject.NULL))
                    .put("appForeground", BetaVisibility.foreground).put("playerForeground", BetaVisibility.playerForeground))
            } else if (action == "systemVolume" || action == "systemMute") {
                val audio = (activity ?: player ?: error("TV unavailable")).getSystemService(android.media.AudioManager::class.java)
                audio.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, if (action == "systemMute") android.media.AudioManager.ADJUST_TOGGLE_MUTE else if (command.optInt("direction") > 0) android.media.AudioManager.ADJUST_RAISE else android.media.AudioManager.ADJUST_LOWER, android.media.AudioManager.FLAG_SHOW_UI)
                done(JSONObject().put("ok", true))
            } else if (action == "key") {
                check(BetaVisibility.foreground) { "Use Bluetooth remote controls outside Zangetsu." }
                val key = mapOf("up" to 19, "down" to 20, "left" to 21, "right" to 22, "ok" to 23, "back" to 4, "escape" to 111, "menu" to 82)[command.optString("value")]
                    ?: error("Unknown button")
                val target = player ?: activity ?: error("TV app is not ready")
                target.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, key))
                target.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, key))
                done(JSONObject().put("ok", true))
            } else if (action in setOf("skipSettings", "catalogues", "search", "detail", "play", "handoffSnapshot", "handoffSources", "handoffValidate", "browseStatus", "openFromPhone")) {
                check(action != "handoffSnapshot" || player != null) { "Start an episode on TV first." }
                check(action != "play" || player == null) { "Close the current TV video before opening another title. Episode switching is available in the controller." }
                if (action == "play" || action == "openFromPhone") catalogueError = null
                val bridge = channel ?: error("Catalogue is not ready")
                bridge.invokeMethod("request", command.toString(), object : MethodChannel.Result {
                    override fun success(result: Any?) { done(JSONObject(result as? String ?: "{}")) }
                    override fun error(code: String, message: String?, details: Any?) { done(JSONObject().put("error", message ?: code)) }
                    override fun notImplemented() { done(JSONObject().put("error", "Catalogue is not ready")) }
                })
            } else {
                check(player != null) { "Start a video on the TV first" }
                player.betaCommand(command)
                done(player.betaState().put("ok", true))
            }
        } catch (e: Exception) { done(JSONObject().put("error", e.message ?: "Command failed")) }
    }
}
