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
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Local, opt-in companion transport. No ADB or remote shell is used here.
 * TV side of the phone remote: hosts a TCP listener (found by mDNS or a UDP beacon) and an
 * optional Bluetooth RFCOMM listener, runs the pairing handshake, then executes the phone's
 * allowlisted commands on the main thread. Wire format: one JSON object per line ([readFrame]).
 */
object CompanionReceiver {
    /** RFCOMM service UUID the phone connects to over Bluetooth. */
    val uuid: UUID = UUID.fromString("c6f0857a-50aa-4b65-9230-888184401761")
    // Discovery and persisted pairing identifiers are protocol compatibility keys.
    /** mDNS / DNS-SD service type advertised for LAN discovery. */
    const val serviceType = "_zangetsu-remote._tcp."
    private val main = Handler(Looper.getMainLooper())
    /** Background threads for accept loops and per-connection reads; commands hop to [main]. */
    private val workers = Executors.newCachedThreadPool()
    /** Caps concurrent client connections at four. */
    private val slots = Semaphore(4)
    private val random = SecureRandom()
    private var server: ServerSocket? = null
    private var discoverySocket: java.net.DatagramSocket? = null
    /** UDP port that answers "ZANGETSU_DISCOVER_V1" probes when mDNS is blocked. */
    const val discoveryPort = 41285
    private var bluetooth: BluetoothServerSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var nsd: NsdManager? = null
    /** Open client transports, closed together on [stop] or [forgetPhones]. */
    private val connections = java.util.concurrent.CopyOnWriteArrayList<Closeable>()
    /** Bumped by [stop]; work started under an older value drops out instead of acting. */
    private var generation = 0
    /** PIN pairing attempts in the current one-minute window (limit 10). */
    private var attempts = 0
    private var attemptWindowEnd = 0L
    /** Persisted pairing state: device ID, QR secret, PIN, port, and remembered client tokens. */
    private var pairingPrefs: android.content.SharedPreferences? = null
    /** Stable ID the phone uses to recognise this TV across reconnects. */
    var deviceId = ""; private set
    /** Six-digit manual pairing code shown on the TV; empty while not hosting. */
    var pin = ""; private set
    /** 256-bit hex secret embedded in the TV's pairing QR code. */
    var qrSecret = ""; private set
    /** User-visible TV name sent to the phone after pairing. */
    var deviceName = android.os.Build.MODEL; private set
    /** TCP port the listener is bound to; 0 while not hosting. */
    var port = 0; private set
    /** Human-readable Bluetooth listener state for the settings screen. */
    var bluetoothStatus = "Bluetooth off"; private set
    /** Flutter channel used to forward catalogue and keyboard requests to Dart; set by MainActivity. */
    var channel: MethodChannel? = null
    /** Current main activity, used for key events and system volume when no player is open. */
    var activity: Activity? = null
    /** Last playback/catalogue error reported to the phone in the "state" reply. */
    var catalogueError: String? = null
    /** Selected TV text box pushed from Dart (phone keyboard v1); written on the main thread. */
    @Volatile var keyboard: JSONObject? = null
    /** Phone keyboard commands that are forwarded to the Dart TvKeyboardBridge. */
    val keyboardActions = setOf("keyboardOpen", "keyboardInput", "keyboardSubmit", "keyboardDismiss")
    /** True while the TCP listener is running. */
    val hosting get() = server != null

    /** Lists usable LAN addresses for manual pairing; loopback is not advertised. */
    fun addresses(): String = try {
        NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it is java.net.Inet4Address }
            .joinToString("\n") { "${it.hostAddress}:$port" }
    } catch (_: Exception) { "Address unavailable" }

    /**
     * Starts the opted-in TCP listener and local discovery using persistent pairing credentials.
     * Call on the main thread; no-op while already hosting. Creates the device ID, QR secret and
     * PIN on first run, reuses the saved port when free, and starts the UDP beacon and mDNS ad.
     */
    fun start(context: Context) {
        if (hosting) return
        pairingPrefs = context.getSharedPreferences("companion_pairing", Context.MODE_PRIVATE)
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
                        val reply = JSONObject().put("service", "zangetsu-remote")
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
        nsd = context.applicationContext.getSystemService(NsdManager::class.java)
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        try {
            nsd?.registerService(NsdServiceInfo().apply {
                serviceName = "Zangetsu ${android.os.Build.MODEL}"
                serviceType = CompanionReceiver.serviceType
                setPort(port)
                setAttribute("deviceId", deviceId)
            }, NsdManager.PROTOCOL_DNS_SD, registration)
        } catch (_: Exception) { /* Manual address remains available. */ }
    }

    /** Rotates the manual pairing PIN and resets attempts; saved client tokens remain valid. */
    fun renewPin() {
        pin = (100000 + random.nextInt(900000)).toString()
        pairingPrefs?.edit()?.putString("pairPin", pin)?.apply()
        attempts = 0
    }

    /**
     * Adds secure RFCOMM delivery using the same authentication and command dispatcher.
     * Throws when the TV has no adapter or Bluetooth is off; the caller shows the message.
     */
    fun startBluetooth(context: Context) {
        if (bluetooth != null) return
        // Registered first so a TV that starts with Bluetooth off still picks it up later.
        if (hosting) watchBluetooth(context.applicationContext)
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: throw IllegalStateException("This device has no Bluetooth adapter")
        check(adapter.isEnabled) { "Turn Bluetooth on in Android settings first" }
        val listener = adapter.listenUsingRfcommWithServiceRecord("Zangetsu", uuid)
        bluetooth = listener
        pairingPrefs?.edit()?.putBoolean("receiverBluetooth", true)?.apply()
        bluetoothStatus = "Bluetooth ready · pair devices in Android settings"
        val gen = generation
        workers.execute {
            try {
                while (bluetooth === listener) {
                    val socket = try { listener.accept() } catch (_: Exception) { break }
                    runCatching { serve(socket.inputStream, socket.outputStream, socket, gen) }
                }
            } finally {
                // Bluetooth off closes the listener; clear it so the next STATE_ON can start again.
                main.post {
                    if (bluetooth === listener) {
                        runCatching { listener.close() }
                        bluetooth = null
                        bluetoothStatus = "Bluetooth off"
                    }
                }
            }
        }
    }

    /** Bluetooth on/off listener registered by [watchBluetooth]; removed in [stop]. */
    private var bluetoothWatcher: android.content.BroadcastReceiver? = null
    /** Context [bluetoothWatcher] was registered with, needed to unregister it. */
    private var watcherContext: Context? = null

    /** Restarts the RFCOMM listener when Bluetooth comes back on while the receiver is hosting. */
    private fun watchBluetooth(app: Context) {
        if (bluetoothWatcher != null) return
        val watcher = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context, intent: android.content.Intent) {
                val state = intent.getIntExtra(android.bluetooth.BluetoothAdapter.EXTRA_STATE, -1)
                if (state != android.bluetooth.BluetoothAdapter.STATE_ON) return
                if (!hosting || pairingPrefs?.getBoolean("receiverBluetooth", false) != true) return
                // The accept loop clears its state via a main-thread post; run after it.
                main.post { if (hosting && bluetooth == null) runCatching { startBluetooth(app) } }
            }
        }
        val filter = android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED)
        runCatching {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                app.registerReceiver(watcher, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                app.registerReceiver(watcher, filter)
            }
            bluetoothWatcher = watcher
            watcherContext = app
        }
    }

    /** Closes listeners and active clients and invalidates outstanding receiver work. */
    fun stop() {
        runCatching { discoverySocket?.close() }; discoverySocket = null
        generation++
        runCatching { server?.close() }; server = null
        runCatching { bluetooth?.close() }; bluetooth = null
        bluetoothWatcher?.let { w -> runCatching { watcherContext?.unregisterReceiver(w) } }; bluetoothWatcher = null; watcherContext = null
        registration?.let { runCatching { nsd?.unregisterService(it) } }; registration = null; nsd = null
        connections.forEach { runCatching { it.close() } }; connections.clear()
        pin = ""; port = 0; bluetoothStatus = "Bluetooth off"
        keyboard = null
    }

    /** Revokes client credentials and rotates pairing secrets before another pairing attempt. */
    fun forgetPhones() {
        qrSecret = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        pairingPrefs?.edit()?.remove("clients")?.putString("qrSecret", qrSecret)?.apply()
        renewPin()
        connections.forEach { runCatching { it.close() } }
    }
    /** Persists receiver opt-out so application startup cannot silently restart it. */
    fun disable() { pairingPrefs?.edit()?.putBoolean("receiverEnabled", false)?.apply(); stop() }

    /** HMAC-SHA256 of [message] keyed by [code], as lowercase hex. Pairing proofs go through [pairingProof]. */
    fun proof(code: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(code.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    /**
     * Pairing protocol version. Version 2 binds both ECDH public keys into the proofs; version-1 proofs are refused.
     * Limits (see companionPairingVersion in Dart): only the pairing and remembered token are protected. Frames
     * after "paired" have no encryption or per-message MAC, so an active attacker can relay the handshake and then
     * inject commands for that session. PIN mode can be brute-forced offline from one observed proof; QR is the
     * recommended pairing. Fixing these needs a per-frame session MAC and a PAKE for PIN.
     */
    const val pairingVersion = 2
    /** Error the TV sends to a phone speaking an older pairing version. */
    const val oldPhoneError = "Update Zangetsu on this phone to pair with the TV."
    /** Error the phone shows when the TV speaks an older pairing version. */
    const val oldTvError = "Update Zangetsu on the TV to pair with this phone."

    /** Pairing nonce sent by the TV: 32 random bytes as lowercase hex. */
    val noncePattern = Regex("[0-9a-f]{64}")

    /**
     * The exact pairing transcript both sides MAC, matching companionTranscript in Dart byte for byte.
     * Every field has a fixed alphabet checked before use, so '|' cannot appear inside one. Keys are the
     * exact hex strings sent on the wire; [clientKey] is empty for a remembered reconnect. [label] is
     * "phone" for the phone's proof and "tv" for the TV's answer, so neither replays as the other.
     */
    fun pairingTranscript(label: String, mode: String, nonce: String, tvKey: String, clientKey: String, clientId: String): String =
        "zangetsu-pair-v$pairingVersion|$label|$mode|$nonce|$tvKey|$clientKey|$clientId"

    /** HMAC proof over [pairingTranscript] with the pairing secret (QR secret, PIN, or remembered token). */
    fun pairingProof(secret: String, label: String, mode: String, nonce: String, tvKey: String, clientKey: String, clientId: String): String =
        proof(secret, pairingTranscript(label, mode, nonce, tvKey, clientKey, clientId))

    /** Constant-time comparison of two proofs; never returns early on a differing byte. */
    fun proofMatches(a: String, b: String): Boolean {
        val x = a.toByteArray(Charsets.UTF_8)
        val y = b.toByteArray(Charsets.UTF_8)
        var difference = x.size xor y.size
        for (i in x.indices) difference = difference or (x[i].toInt() xor (if (i < y.size) y[i].toInt() else 0))
        return difference == 0
    }

    /** Uncompressed P-256 public key in lowercase hex: "04" + X + Y. */
    val pairingKeyPattern = Regex("04[0-9a-f]{128}")

    /** Ephemeral P-256 key pair used once per pairing to agree on the remembered token. */
    fun newPairingKey(): java.security.KeyPair = java.security.KeyPairGenerator.getInstance("EC").apply {
        initialize(java.security.spec.ECGenParameterSpec("secp256r1"), random)
    }.generateKeyPair()

    /** Encodes the public half as an uncompressed point, matching the Dart CompanionKey. */
    fun pairingKeyHex(pair: java.security.KeyPair): String {
        val w = (pair.public as java.security.interfaces.ECPublicKey).w
        fun fixed(n: java.math.BigInteger): ByteArray {
            val b = n.toByteArray()
            return if (b.size >= 32) b.copyOfRange(b.size - 32, b.size) else ByteArray(32 - b.size) + b
        }
        return (byteArrayOf(4) + fixed(w.affineX) + fixed(w.affineY)).joinToString("") { "%02x".format(it) }
    }

    /** ECDH over P-256; returns the shared X coordinate as 64 hex chars. Throws on an invalid peer key. */
    fun pairingShared(pair: java.security.KeyPair, peerHex: String): String {
        require(peerHex.matches(pairingKeyPattern)) { "Invalid pairing key" }
        val bytes = ByteArray(65) { peerHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val point = java.security.spec.ECPoint(
            java.math.BigInteger(1, bytes.copyOfRange(1, 33)),
            java.math.BigInteger(1, bytes.copyOfRange(33, 65)),
        )
        val params = (pair.public as java.security.interfaces.ECPublicKey).params
        val peer = java.security.KeyFactory.getInstance("EC").generatePublic(java.security.spec.ECPublicKeySpec(point, params))
        val agreement = javax.crypto.KeyAgreement.getInstance("ECDH")
        agreement.init(pair.private)
        agreement.doPhase(peer, true)
        return agreement.generateSecret().joinToString("") { "%02x".format(it) }
    }

    /** Derives the remembered-client token from the ECDH secret; both sides compute it, so it is never sent. */
    fun pairingToken(shared: String, nonce: String, clientId: String): String =
        proof(shared, "zangetsu-token|$nonce|$clientId")

    /** Largest reply the phone accepts from a paired TV: source lists with subtitles can pass 256 Ki. */
    const val replyLimit = 8 * 1024 * 1024

    // A hard frame limit prevents a peer from allocating an unbounded readLine.
    /**
     * Reads one bounded JSON line, rejecting disconnects and oversized input.
     * Shared by both sides; blocks the calling thread. Throws EOFException on disconnect and
     * IllegalArgumentException past [limit] characters (256 Ki by default; the phone allows
     * [replyLimit] for replies from an already paired TV).
     */
    fun readFrame(reader: BufferedReader, limit: Int = 262144): JSONObject {
        val line = StringBuilder()
        while (line.length < limit) {
            val c = reader.read()
            if (c == -1) throw java.io.EOFException()
            if (c == 10) return JSONObject(line.toString())
            line.append(c.toChar())
        }
        throw IllegalArgumentException("Message too large")
    }

    /**
     * Authenticates a client before accepting monotonic request IDs; limits concurrent connections.
     * Runs on a worker thread. Handshake: TV sends "challenge" (nonce, version, key), phone answers
     * "hello" (mode qr/pin/remembered, clientId, key, proof), TV replies "paired" with its own proof.
     * Then each command {id, action, ...} gets one reply carrying the same id. [gen] ties it to one
     * [start]; a later [stop] ends the loop.
     */
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
                val pairingKey = newPairingKey()
                val tvKey = pairingKeyHex(pairingKey)
                send(JSONObject().put("type", "challenge").put("nonce", nonce).put("version", pairingVersion)
                    .put("deviceId", deviceId).put("name", android.os.Build.MODEL).put("key", tvKey))
                val hello = readFrame(reader)
                if (hello.optInt("version") != pairingVersion) {
                    // A version-1 phone proves only the nonce, which does not cover the ECDH keys.
                    send(JSONObject().put("error", oldPhoneError))
                    return@execute
                }
                val clientId = hello.optString("clientId").takeIf { it.matches(Regex("[a-zA-Z0-9-]{16,64}")) }
                val mode = hello.optString("mode")
                val remembered = mode == "remembered"
                // QR and PIN pairing need the phone's ECDH key; a remembered reconnect sends none.
                val clientKey = if (remembered) "" else hello.optString("key").takeIf { it.matches(pairingKeyPattern) }
                // The secret is picked strictly by mode so no mode can fall through to the rate-limited PIN.
                val secret = synchronized(this) {
                    val clients = JSONObject(pairingPrefs?.getString("clients", "{}") ?: "{}")
                    val expected = when (mode) {
                        "remembered" -> clientId?.let { clients.optString(it) } ?: ""
                        "qr" -> qrSecret
                        "pin" -> pin
                        else -> ""
                    }
                    if (SystemClock.elapsedRealtime() > attemptWindowEnd) { attempts = 0; attemptWindowEnd = SystemClock.elapsedRealtime() + 60000 }
                    if (mode == "pin") attempts++
                    expected.takeIf {
                        it.isNotEmpty() && (mode != "pin" || attempts <= 10) && clientId != null && clientKey != null &&
                            proofMatches(pairingProof(it, "phone", mode, nonce, tvKey, clientKey, clientId), hello.optString("proof"))
                    }
                }
                if (secret == null || clientId == null || clientKey == null || gen != generation) {
                    send(JSONObject().put("error", "Pairing details do not match. Scan the TV QR, or wait a minute after repeated incorrect codes."))
                    return@execute
                }
                main.removeCallbacks(timeout)
                main.postDelayed(timeout, 95000)
                if (connection is Socket) connection.soTimeout = 95000
                // Mutual proof over the same transcript: the phone checks it before trusting this TV.
                val paired = JSONObject().put("type", "paired").put("deviceId", deviceId).put("name", deviceName).put("bluetoothName", deviceName)
                    .put("proof", pairingProof(secret, "tv", mode, nonce, tvKey, clientKey, clientId))
                if (!remembered) {
                    // Both sides derive the token by ECDH, so it never crosses the wire.
                    val token = pairingToken(pairingShared(pairingKey, clientKey), nonce, clientId)
                    synchronized(this) {
                        val clients = JSONObject(pairingPrefs?.getString("clients", "{}") ?: "{}")
                        if (clients.length() >= 10 && !clients.has(clientId)) clients.remove(clients.keys().next())
                        clients.put(clientId, token)
                        pairingPrefs?.edit()?.putString("clients", clients.toString())?.apply()
                    }
                }
                // A 6-digit PIN can be brute-forced from an observed proof, so a used PIN is retired.
                // The 256-bit QR secret cannot, and stays valid so the QR on screen keeps working.
                if (mode == "pin") synchronized(this) { renewPin() }
                send(paired)
                // Commands below are not encrypted or MACed per frame; increasing IDs only stop
                // plain replays, not an active attacker on the link (see pairingVersion).
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

    /** Copy of the pushed text box, only while the app (not the player) is in front. */
    private fun keyboardSnapshot(): Any =
        if (CompanionVisibility.foreground && !CompanionVisibility.playerForeground) keyboard?.let { JSONObject(it.toString()) } ?: JSONObject.NULL
        else JSONObject.NULL

    /** Keyboard reply used when no text box can take phone input right now. */
    private fun keyboardRefused() = JSONObject().put("ok", false).put("keyboard", JSONObject.NULL)

    /**
     * Runs only allowlisted app/player actions on the main thread and returns one result.
     * Catalogue and keyboard actions go to Dart over [channel]; key, volume and player actions
     * run natively. [done] is called exactly once, with {"error": ...} on failure.
     */
    private fun dispatch(command: JSONObject, done: (JSONObject) -> Unit) {
        try {
            val action = command.optString("action")
            val player = TvPlayerActivity.active
            if (action == "closePlayer") {
                player?.finish()
                done(JSONObject().put("ok", true))
            } else if (action == "state") {
                done((player?.companionState() ?: JSONObject().put("active", false).put("title", "Choose something to watch on TV").put("playbackError", catalogueError ?: JSONObject.NULL))
                    .put("appForeground", CompanionVisibility.foreground).put("playerForeground", CompanionVisibility.playerForeground)
                    .put("keyboardVersion", 1).put("keyboard", keyboardSnapshot()))
            } else if (action in keyboardActions) {
                // Phone keyboard v1: TvKeyboardBridge answers {ok, keyboard}; never an error key.
                val bridge = channel
                if (bridge == null || !CompanionVisibility.foreground || CompanionVisibility.playerForeground) {
                    done(keyboardRefused())
                } else {
                    bridge.invokeMethod("request", command.toString(), object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            done((result as? String)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: keyboardRefused())
                        }
                        override fun error(code: String, message: String?, details: Any?) { done(keyboardRefused()) }
                        override fun notImplemented() { done(keyboardRefused()) }
                    })
                }
            } else if (action == "systemVolume" || action == "systemMute") {
                val audio = (activity ?: player ?: error("TV unavailable")).getSystemService(android.media.AudioManager::class.java)
                audio.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, if (action == "systemMute") android.media.AudioManager.ADJUST_TOGGLE_MUTE else if (command.optInt("direction") > 0) android.media.AudioManager.ADJUST_RAISE else android.media.AudioManager.ADJUST_LOWER, android.media.AudioManager.FLAG_SHOW_UI)
                done(JSONObject().put("ok", true))
            } else if (action == "key") {
                check(CompanionVisibility.foreground) { "Use Bluetooth remote controls outside Zangetsu." }
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
                player.companionCommand(command)
                done(player.companionState().put("ok", true))
            }
        } catch (e: Exception) { done(JSONObject().put("error", e.message ?: "Command failed")) }
    }
}
