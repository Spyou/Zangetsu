package com.spyou.watch_app

import org.json.JSONObject
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

/**
 * One authenticated transport; sequences and failures never cross transports.
 * Phone side of the link: wraps a TCP or Bluetooth socket that already finished the pairing
 * handshake with [CompanionReceiver] on the TV, and sends one newline-delimited JSON command at a time.
 */
class CompanionSocket(val socket: Closeable, input: InputStream, output: OutputStream) : Closeable {
    /** Reads the TV's newline-delimited JSON replies. */
    val reader = input.bufferedReader()
    /** Writes newline-delimited JSON commands to the TV. */
    val writer = output.bufferedWriter()
    /** Last request ID sent; the TV refuses any ID that does not increase. */
    private var sequence = 0L
    /** Elapsed-realtime of the last [exchange], used to judge whether the link is idle. */
    @Volatile var lastActivity = android.os.SystemClock.elapsedRealtime(); private set
    /** False once [close] ran or the link failed; a dead link is never reused. */
    @Volatile var alive = true
    /**
     * Serializes request IDs per transport; never retries an uncertain command on another link.
     * Stamps [request] with the next ID, writes it, and blocks the calling (background) thread
     * until the matching reply arrives. Throws if the link is closed or the reply ID differs.
     */
    @Synchronized fun exchange(request: JSONObject): JSONObject {
        check(alive) { "Connection closed" }
        lastActivity = android.os.SystemClock.elapsedRealtime()
        val command = JSONObject(request.toString()).put("id", ++sequence)
        writer.write(command.toString()); writer.newLine(); writer.flush()
        val response = CompanionReceiver.readFrame(reader)
        check(response.optLong("id") == sequence) { "Unexpected TV response" }
        return response
    }
    /** Marks the link unusable before closing its underlying socket. */
    override fun close() { alive = false; runCatching { socket.close() } }
}
