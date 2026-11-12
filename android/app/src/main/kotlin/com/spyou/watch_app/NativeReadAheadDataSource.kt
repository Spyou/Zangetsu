package com.spyou.watch_app

import android.net.Uri
import android.os.SharedMemory
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.nio.ByteBuffer

/** Bounded read-ahead outside the Java heap, released when the source closes. */
internal class NativeReadAheadDataSource(
    private val upstreamFactory: DataSource.Factory,
    private val capacity: Int,
    private val allocate: (Int) -> ByteBuffer = { bytes ->
        SharedMemory.create("zangetsu_video_buffer", bytes).use { it.mapReadWrite() }
    },
    private val release: (ByteBuffer) -> Unit = { SharedMemory.unmap(it) },
) : DataSource {
    private class Session(val memory: ByteBuffer, val upstream: DataSource) {
        val lock = Object()
        val reader = memory.duplicate()
        var readAt = 0L
        var writeAt = 0L
        var done = false
        var closed = false
        var freed = false
        var failure: IOException? = null
        lateinit var worker: Thread
    }

    private var session: Session? = null
    private var upstream: DataSource? = null
    private val listeners = mutableListOf<TransferListener>()

    init { require(capacity > 0) }

    override fun open(spec: DataSpec): Long {
        check(upstream == null)
        val source = upstreamFactory.createDataSource()
        listeners.forEach(source::addTransferListener)
        upstream = source
        val length = source.open(spec)
        val chunk = try {
            ByteArray(minOf(capacity, 64 * 1024))
        } catch (_: OutOfMemoryError) { return length }
        val memory = try {
            allocate(capacity)
        } catch (_: Exception) {
            return length
        } catch (_: OutOfMemoryError) {
            return length
        }
        val current = Session(memory, source)
        session = current
        try {
            current.worker = Thread({ produce(current, chunk) }, "ZangetsuReadAhead").apply { isDaemon = true }
            current.worker.start()
        } catch (_: OutOfMemoryError) {
            session = null
            release(memory)
        }
        return length
    }

    private fun produce(current: Session, chunk: ByteArray) {
        try {
            val writer = current.memory.duplicate()
            while (true) {
                val amount = synchronized(current.lock) {
                    while (!current.closed && current.writeAt - current.readAt == capacity.toLong()) {
                        current.lock.wait()
                    }
                    if (current.closed) return
                    minOf(chunk.size, (capacity - (current.writeAt - current.readAt)).toInt(),
                        capacity - (current.writeAt % capacity).toInt())
                }
                val count = current.upstream.read(chunk, 0, amount)
                if (count == C.RESULT_END_OF_INPUT) return
                if (count == 0) { Thread.yield(); continue }
                synchronized(current.lock) {
                    if (current.closed) return
                    writer.position((current.writeAt % capacity).toInt())
                    writer.put(chunk, 0, count)
                    current.writeAt += count
                    current.lock.notifyAll()
                }
            }
        } catch (error: Exception) {
            synchronized(current.lock) {
                if (!current.closed) current.failure =
                    if (error is IOException) error else IOException("Read-ahead failed", error)
            }
        } finally {
            synchronized(current.lock) {
                current.done = true
                current.lock.notifyAll()
                freeIfClosed(current)
            }
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val current = session ?: return checkNotNull(upstream).read(buffer, offset, length)
        synchronized(current.lock) {
            try {
                while (!current.closed && current.writeAt == current.readAt && !current.done) {
                    current.lock.wait()
                }
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Read-ahead interrupted", error)
            }
            if (current.closed) return C.RESULT_END_OF_INPUT
            val available = current.writeAt - current.readAt
            if (available == 0L) {
                current.failure?.let { throw it }
                return C.RESULT_END_OF_INPUT
            }
            val count = minOf(length, available.toInt(), capacity - (current.readAt % capacity).toInt())
            current.reader.apply {
                position((current.readAt % capacity).toInt())
                get(buffer, offset, count)
            }
            current.readAt += count
            current.lock.notifyAll()
            return count
        }
    }

    override fun close() {
        val current = session
        session = null
        if (current != null) synchronized(current.lock) {
            current.closed = true
            current.lock.notifyAll()
            current.worker.interrupt()
            freeIfClosed(current)
        }
        val source = upstream
        upstream = null
        source?.close()
    }

    // A blocked producer may still be reading; only its exit can release that mapping.
    private fun freeIfClosed(current: Session) {
        if (current.closed && current.done && !current.freed) {
            current.freed = true
            release(current.memory)
        }
    }

    override fun getUri(): Uri? = upstream?.uri
    override fun getResponseHeaders(): Map<String, List<String>> = upstream?.responseHeaders.orEmpty()
    override fun addTransferListener(listener: TransferListener) {
        listeners.add(listener)
        upstream?.addTransferListener(listener)
    }
}
