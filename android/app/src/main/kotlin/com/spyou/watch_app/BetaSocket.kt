package com.spyou.watch_app

import org.json.JSONObject
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

/** One authenticated transport; sequences and failures never cross transports. */
class BetaSocket(val socket: Closeable, input: InputStream, output: OutputStream) : Closeable {
    val reader = input.bufferedReader()
    val writer = output.bufferedWriter()
    private var sequence = 0L
    @Volatile var lastActivity = android.os.SystemClock.elapsedRealtime(); private set
    @Volatile var alive = true
    @Synchronized fun exchange(request: JSONObject): JSONObject {
        check(alive) { "Connection closed" }
        lastActivity = android.os.SystemClock.elapsedRealtime()
        val command = JSONObject(request.toString()).put("id", ++sequence)
        writer.write(command.toString()); writer.newLine(); writer.flush()
        val response = BetaLink.readFrame(reader)
        check(response.optLong("id") == sequence) { "Unexpected TV response" }
        return response
    }
    override fun close() { alive = false; runCatching { socket.close() } }
}
