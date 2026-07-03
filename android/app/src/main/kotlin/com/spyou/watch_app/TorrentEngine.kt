package com.spyou.watch_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import fi.iki.elonen.NanoHTTPD
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.libtorrent4j.Priority
import org.libtorrent4j.SessionManager
import org.libtorrent4j.TorrentFlags
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.URL

/**
 * Native torrent streaming engine (Phase 1).
 *
 * Streams a magnet/.torrent by downloading pieces in playback order and
 * serving the largest video file over a local HTTP server that mpv opens.
 * One active stream at a time (Phase 1). Everything is inert until Dart calls
 * `startStream`; the session is created lazily and torn down on `stopStream`.
 *
 * Channel protocol (com.spyou.watch_app/torrent):
 *   startStream {uri}       -> {id, localUrl}   (returns once head-buffered)
 *   stopStream  {id}        -> null
 * Events (com.spyou.watch_app/torrent/events):
 *   {id, state, bufferPct, peers, downSpeedBps, error?}
 *   state in finding|buffering|ready|error
 */
class TorrentEngine(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val method = MethodChannel(messenger, "com.spyou.watch_app/torrent")
    private val events = EventChannel(messenger, "com.spyou.watch_app/torrent/events")
    private val main = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null

    // Single active session/stream (Phase 1).
    private var session: SessionManager? = null
    private var handle: TorrentHandle? = null
    private var server: StreamServer? = null
    private var activeId: String? = null
    private var poller: Thread? = null
    @Volatile private var stopped = false

    init {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "ping" -> result.success("ok")
                "startStream" -> {
                    val uri = call.argument<String>("uri")
                    val allowMobileData = call.argument<Boolean>("allowMobileData") ?: false
                    if (uri.isNullOrBlank()) {
                        result.error("bad_args", "uri required", null)
                    } else {
                        startStream(uri, allowMobileData, result)
                    }
                }
                "stopStream" -> {
                    stopStream(call.argument<String>("id"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })
    }

    private fun emit(map: Map<String, Any?>) {
        main.post { eventSink?.success(map) }
    }

    private fun emitState(
        id: String,
        state: String,
        bufferPct: Double = 0.0,
        peers: Int = 0,
        downSpeed: Long = 0,
        error: String? = null,
    ) = emit(
        mapOf(
            "id" to id,
            "state" to state,
            "bufferPct" to bufferPct,
            "peers" to peers,
            "downSpeedBps" to downSpeed,
            "error" to error,
        ),
    )

    private fun startStream(
        uri: String,
        allowMobileData: Boolean,
        result: MethodChannel.Result,
    ) {
        // Wi-Fi gate: refuse on a metered network unless the user opted in.
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? android.net.ConnectivityManager
        if (cm != null && cm.isActiveNetworkMetered && !allowMobileData) {
            result.error(
                "wifi_only",
                "Torrents are set to Wi-Fi only",
                null,
            )
            return
        }
        // Everything network/IO happens off the platform thread.
        Thread {
            try {
                stopInternal() // one stream at a time
                stopped = false

                val s = SessionManager()
                s.start()
                session = s

                val saveDir = File(context.cacheDir, "torrents").apply { mkdirs() }

                // Resolve metadata: a magnet fetches it from peers; a .torrent
                // url is downloaded directly. libtorrent4j's download() needs a
                // TorrentInfo, so metadata comes first.
                val ti: TorrentInfo = if (uri.startsWith("magnet:", ignoreCase = true)) {
                    val data = s.fetchMagnet(uri, 45, saveDir)
                        ?: throw IllegalStateException("no_metadata")
                    TorrentInfo(data)
                } else {
                    TorrentInfo(URL(uri).readBytes())
                }
                val id = ti.infoHash().toString()
                activeId = id
                emitState(id, "finding")

                s.download(ti, saveDir)

                // Grab the handle once it's valid.
                var found: TorrentHandle? = null
                val hDeadline = System.currentTimeMillis() + 15_000
                while ((found == null || !found.isValid) &&
                    System.currentTimeMillis() < hDeadline && !stopped
                ) {
                    found = s.find(ti.infoHash())
                    if (found == null || !found.isValid) Thread.sleep(200)
                }
                val h = found?.takeIf { it.isValid } ?: throw IllegalStateException("no_handle")
                handle = h

                // Sequential download for smooth streaming.
                h.setFlags(TorrentFlags.SEQUENTIAL_DOWNLOAD)

                // Pick the largest video file; download only it.
                val files = ti.files()
                var fileIndex = -1
                var bestSize = -1L
                for (i in 0 until files.numFiles()) {
                    val name = files.fileName(i).lowercase()
                    val isVideo = VIDEO_EXTS.any { name.endsWith(it) }
                    if (isVideo && files.fileSize(i) > bestSize) {
                        bestSize = files.fileSize(i)
                        fileIndex = i
                    }
                }
                if (fileIndex < 0) throw IllegalStateException("no_video_in_torrent")
                for (i in 0 until files.numFiles()) {
                    h.filePriority(i, if (i == fileIndex) Priority.DEFAULT else Priority.IGNORE)
                }

                val pieceLen = ti.pieceLength().toLong()
                val fileOffset = files.fileOffset(fileIndex)
                val fileSize = files.fileSize(fileIndex)
                val fullPath = File(saveDir, files.filePath(fileIndex))
                val firstPiece = (fileOffset / pieceLen).toInt()
                val lastPiece = ((fileOffset + fileSize - 1) / pieceLen).toInt()

                emitState(id, "buffering")
                // Prioritise the HEAD so playback starts quickly, AND the TAIL:
                // MKV (SubsPlease) keeps its seek index (Cues/SeekHead) — and MP4
                // its moov atom — near the END of the file, which the player reads
                // right after opening. Without the tail, seeking never works and the
                // player stalls waiting for an index that only arrives after a full
                // sequential download. Piece deadlines fetch these from peers ASAP,
                // ahead of the in-order body.
                val headPieces = minOf(8, lastPiece - firstPiece + 1)
                for (p in firstPiece until firstPiece + headPieces) {
                    h.piecePriority(p, Priority.TOP_PRIORITY)
                    h.setPieceDeadline(p, 2000 + (p - firstPiece) * 400)
                }
                val tailPieces = minOf(4, lastPiece - firstPiece + 1)
                for (p in (lastPiece - tailPieces + 1)..lastPiece) {
                    if (p >= firstPiece) {
                        h.piecePriority(p, Priority.TOP_PRIORITY)
                        h.setPieceDeadline(p, 3000)
                    }
                }
                // Progress poller.
                poller = Thread {
                    while (!stopped) {
                        try {
                            val st = h.status()
                            emitState(
                                id,
                                if (h.havePiece(firstPiece)) "ready" else "buffering",
                                bufferPct = st.progress().toDouble(),
                                peers = st.numPeers(),
                                downSpeed = st.downloadRate().toLong(),
                            )
                            Thread.sleep(1_000)
                        } catch (_: Throwable) {
                            break
                        }
                    }
                }.also { it.isDaemon = true; it.start() }

                // Wait for the head buffer before returning a playable url.
                val bufDeadline = System.currentTimeMillis() + 60_000
                while (!h.havePiece(firstPiece) && System.currentTimeMillis() < bufDeadline && !stopped) {
                    Thread.sleep(300)
                }
                if (stopped) throw IllegalStateException("stopped")

                val srv = StreamServer(h, fullPath, fileOffset, fileSize, pieceLen)
                srv.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true)
                server = srv
                val localUrl = "http://127.0.0.1:${srv.listeningPort}/stream"

                emitState(id, "ready", peers = h.status().numPeers())
                main.post { result.success(mapOf("id" to id, "localUrl" to localUrl)) }
            } catch (e: Throwable) {
                val id = activeId ?: ""
                emitState(id, "error", error = e.message)
                stopInternal()
                main.post { result.error("torrent_error", e.message, null) }
            }
        }.also { it.isDaemon = true }.start()
    }

    private fun stopStream(id: String?) {
        Thread { stopInternal() }.also { it.isDaemon = true }.start()
    }

    private fun stopInternal() {
        stopped = true
        try { server?.stop() } catch (_: Throwable) {}
        server = null
        try {
            val s = session
            val h = handle
            if (s != null && h != null) s.remove(h)
        } catch (_: Throwable) {}
        try { session?.stop() } catch (_: Throwable) {}
        // Delete buffered pieces.
        try { File(context.cacheDir, "torrents").deleteRecursively() } catch (_: Throwable) {}
        handle = null
        session = null
        activeId = null
        poller = null
    }

    /**
     * Serves the target file over HTTP with Range support. A range request
     * bumps the covering pieces' priority and blocks (polling havePiece) until
     * the requested bytes are downloaded, so mpv can seek anywhere.
     */
    private inner class StreamServer(
        private val h: TorrentHandle,
        private val file: File,
        private val fileOffset: Long,
        private val fileSize: Long,
        private val pieceLen: Long,
    ) : NanoHTTPD("127.0.0.1", 0) {

        override fun serve(session: IHTTPSession): Response {
            val rangeHeader = session.headers["range"]
            var start = 0L
            var end = fileSize - 1
            if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
                val spec = rangeHeader.substring(6).split("-")
                start = spec.getOrNull(0)?.toLongOrNull() ?: 0L
                end = spec.getOrNull(1)?.toLongOrNull() ?: (fileSize - 1)
            }
            if (start < 0) start = 0
            if (end >= fileSize) end = fileSize - 1
            val length = end - start + 1

            val stream = PieceInputStream(start, end)
            val status = if (rangeHeader != null) Response.Status.PARTIAL_CONTENT else Response.Status.OK
            val res = newFixedLengthResponse(status, "video/mp4", stream, length)
            res.addHeader("Accept-Ranges", "bytes")
            if (rangeHeader != null) {
                res.addHeader("Content-Range", "bytes $start-$end/$fileSize")
            }
            return res
        }

        private val lastPieceIdx = ((fileOffset + fileSize - 1) / pieceLen).toInt()

        /** Blocks per-piece until the bytes it covers are downloaded. */
        private inner class PieceInputStream(start: Long, private val end: Long) : InputStream() {
            private var pos = start

            // mpv abandons a range connection when the user seeks; NanoHTTPD then
            // closes this stream. Without noticing, the serving thread would stay
            // blocked in [ensure] until its target piece lands — piling up threads
            // on rapid fast-forward. This flag lets an abandoned read bail at once.
            @Volatile
            private var closed = false
            private val raf = RandomAccessFile(file, "r").also { it.seek(start) }

            private fun ensure(bytePosInFile: Long) {
                val piece = ((fileOffset + bytePosInFile) / pieceLen).toInt()
                if (h.havePiece(piece)) return
                // Deadline-request the target piece + a small read-ahead window so a
                // SEEK fetches those pieces from peers immediately, OVERRIDING the
                // in-order sequential download. Without deadlines a forward seek has
                // to wait for every intervening piece first (the "finding peers on
                // fast-forward" the user saw).
                val window = 6
                for (p in piece..minOf(piece + window, lastPieceIdx)) {
                    h.piecePriority(p, Priority.TOP_PRIORITY)
                    h.setPieceDeadline(p, 500 + (p - piece) * 350)
                }
                while (!stopped && !closed && !h.havePiece(piece)) {
                    Thread.sleep(120)
                }
            }

            override fun read(): Int {
                if (pos > end || closed) return -1
                ensure(pos)
                if (closed) return -1
                raf.seek(pos)
                val b = raf.read()
                if (b >= 0) pos++
                return b
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (pos > end || closed) return -1
                ensure(pos)
                if (closed) return -1
                // Read only within the current piece to keep piece-blocking tight.
                val pieceEnd = ((fileOffset + pos) / pieceLen + 1) * pieceLen - fileOffset
                val maxHere = minOf(len.toLong(), pieceEnd - pos, end - pos + 1).toInt()
                raf.seek(pos)
                val n = raf.read(b, off, maxHere.coerceAtLeast(1))
                if (n > 0) pos += n
                return n
            }

            override fun close() {
                closed = true
                try { raf.close() } catch (_: Throwable) {}
            }
        }
    }

    companion object {
        private val VIDEO_EXTS = listOf(".mp4", ".mkv", ".avi", ".webm", ".mov", ".m4v", ".ts", ".flv")
    }
}
