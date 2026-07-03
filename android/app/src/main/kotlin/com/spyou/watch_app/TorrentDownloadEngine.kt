package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.libtorrent4j.Priority
import org.libtorrent4j.SessionManager
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import java.io.File
import java.net.URL
import java.util.Collections

/**
 * Native torrent DOWNLOAD engine (offline save — Phase 2). Completely separate
 * from [TorrentEngine] (streaming): its own persistent [SessionManager], its own
 * channels. Downloads the largest video file of a torrent to a real temp dir and
 * reports progress; the SAF copy to the user's folder + foreground service +
 * fast-resume are layered on in later tasks.
 *
 * Channel `com.spyou.watch_app/torrent_download`:
 *   enqueue {id, uri, saveTreeUri, allowMobileData} -> null
 *   pause/resume/cancel {id} -> null
 * Events `.../torrent_download/events`:
 *   {id, status, progress, peers, downSpeedBps, filePath?, error?}
 *   status in queued|downloading|copying|done|failed|paused
 */
class TorrentDownloadEngine(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val method = MethodChannel(messenger, "com.spyou.watch_app/torrent_download")
    private val events = EventChannel(messenger, "com.spyou.watch_app/torrent_download/events")
    private val main = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var session: SessionManager? = null
    private val handles = Collections.synchronizedMap(HashMap<String, TorrentHandle>())
    private val saveTree = Collections.synchronizedMap(HashMap<String, String?>())
    private val done = Collections.synchronizedSet(HashSet<String>())
    // Torrents accepted while >= MAX_ACTIVE are running.
    private data class Pending(val id: String, val uri: String, val saveTreeUri: String?)
    private val pending = Collections.synchronizedList(ArrayList<Pending>())
    @Volatile private var poller: Thread? = null

    init {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueue" -> {
                    val id = call.argument<String>("id")
                    val uri = call.argument<String>("uri")
                    val tree = call.argument<String>("saveTreeUri")
                    val allowMobile = call.argument<Boolean>("allowMobileData") ?: false
                    if (id.isNullOrBlank() || uri.isNullOrBlank()) {
                        result.error("bad_args", "id + uri required", null)
                    } else if (isMetered() && !allowMobile) {
                        result.error("wifi_only", "Torrents are set to Wi-Fi only", null)
                    } else {
                        enqueue(id, uri, tree)
                        result.success(null)
                    }
                }
                "pause" -> { call.argument<String>("id")?.let(::pause); result.success(null) }
                "resume" -> { call.argument<String>("id")?.let(::resume); result.success(null) }
                "cancel" -> { call.argument<String>("id")?.let(::cancel); result.success(null) }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
            override fun onCancel(args: Any?) { eventSink = null }
        })
    }

    private fun isMetered(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? android.net.ConnectivityManager
        return cm?.isActiveNetworkMetered == true
    }

    private fun emit(
        id: String, status: String, progress: Double = 0.0, peers: Int = 0,
        downSpeed: Long = 0, filePath: String? = null, error: String? = null,
    ) = main.post {
        eventSink?.success(
            mapOf(
                "id" to id, "status" to status, "progress" to progress,
                "peers" to peers, "downSpeedBps" to downSpeed,
                "filePath" to filePath, "error" to error,
            ),
        )
    }

    private fun ensureSession(): SessionManager {
        var s = session
        if (s == null) {
            s = SessionManager()
            s.start()
            session = s
            startPoller()
        }
        return s
    }

    @Synchronized
    private fun enqueue(id: String, uri: String, treeUri: String?) {
        saveTree[id] = treeUri
        if (handles.size >= MAX_ACTIVE) {
            pending.add(Pending(id, uri, treeUri))
            emit(id, "queued")
            return
        }
        startDownload(id, uri)
    }

    private fun ensureService() {
        try {
            ContextCompat.startForegroundService(
                context, Intent(context, TorrentDownloadService::class.java),
            )
        } catch (_: Throwable) {}
    }

    private fun maybeStopService() {
        if (handles.isEmpty() && pending.isEmpty()) {
            try {
                context.stopService(Intent(context, TorrentDownloadService::class.java))
            } catch (_: Throwable) {}
        }
    }

    private fun startDownload(id: String, uri: String) {
        emit(id, "downloading")
        ensureService()
        Thread {
            try {
                val s = ensureSession()
                val saveDir = File(context.filesDir, "torrent_downloads/$id").apply { mkdirs() }
                val ti: TorrentInfo = if (uri.startsWith("magnet:", true)) {
                    val data = s.fetchMagnet(uri, 60, saveDir)
                        ?: throw IllegalStateException("no_metadata")
                    TorrentInfo(data)
                } else {
                    TorrentInfo(URL(uri).readBytes())
                }
                s.download(ti, saveDir)
                var h: TorrentHandle? = null
                val deadline = System.currentTimeMillis() + 20_000
                while ((h == null || !h.isValid) && System.currentTimeMillis() < deadline) {
                    h = s.find(ti.infoHash())
                    if (h == null || !h.isValid) Thread.sleep(200)
                }
                val handle = h?.takeIf { it.isValid } ?: throw IllegalStateException("no_handle")

                // Download ONLY the largest video file (full file, all pieces).
                val files = ti.files()
                var idx = -1; var best = -1L
                for (i in 0 until files.numFiles()) {
                    val name = files.fileName(i).lowercase()
                    if (VIDEO_EXTS.any { name.endsWith(it) } && files.fileSize(i) > best) {
                        best = files.fileSize(i); idx = i
                    }
                }
                if (idx < 0) throw IllegalStateException("no_video_in_torrent")
                for (i in 0 until files.numFiles()) {
                    handle.filePriority(i, if (i == idx) Priority.DEFAULT else Priority.IGNORE)
                }
                handle.resume()
                handles[id] = handle
            } catch (t: Throwable) {
                emit(id, "failed", error = t.message)
                cleanup(id)
                startNext()
            }
        }.also { it.isDaemon = true }.start()
    }

    /** One shared 1s poller: emits progress for active handles, detects completion. */
    private fun startPoller() {
        if (poller != null) return
        poller = Thread {
            while (session != null) {
                try {
                    val snapshot = synchronized(handles) { HashMap(handles) }
                    for ((id, h) in snapshot) {
                        if (!h.isValid || done.contains(id)) continue
                        val st = h.status()
                        if (st.isFinished || st.isSeeding) {
                            done.add(id)
                            onComplete(id, h)
                        } else {
                            emit(
                                id, "downloading",
                                progress = st.progress().toDouble(),
                                peers = st.numPeers(),
                                downSpeed = st.downloadRate().toLong(),
                            )
                        }
                    }
                    Thread.sleep(1_000)
                } catch (_: Throwable) { /* keep polling */ }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    /** Target file finished. (Task 6 adds the SAF copy; here we surface the temp
     *  file path and stop seeding.) */
    private fun onComplete(id: String, h: TorrentHandle) {
        try {
            emit(id, "copying", progress = 1.0)
            val ti = h.torrentFile()
            val files = ti.files()
            var idx = 0; var best = -1L
            for (i in 0 until files.numFiles()) {
                val name = files.fileName(i).lowercase()
                if (VIDEO_EXTS.any { name.endsWith(it) } && files.fileSize(i) > best) {
                    best = files.fileSize(i); idx = i
                }
            }
            val saveDir = File(context.filesDir, "torrent_downloads/$id")
            val file = File(saveDir, files.filePath(idx))
            h.pause() // stop seeding once the file is complete

            // Copy into the user's chosen SAF folder (libtorrent can't write to
            // a content:// tree directly); leave the temp in app storage if the
            // user has no custom folder set.
            val treeUri = saveTree[id]
            val finalPath = if (treeUri != null) {
                val uri = copyToTree(file, treeUri, file.name)
                try { saveDir.deleteRecursively() } catch (_: Throwable) {}
                uri
            } else {
                file.absolutePath
            }
            saveTree.remove(id)
            emit(id, "done", progress = 1.0, filePath = finalPath)
        } catch (t: Throwable) {
            emit(id, "failed", error = t.message) // temp kept for a retry
        } finally {
            handles.remove(id)
            startNext()
        }
    }

    /** Stream [src] into the SAF tree [treeUri] as [name]; returns the child
     *  content:// URI. Uses DocumentsContract only (no extra dependency). */
    private fun copyToTree(src: File, treeUri: String, name: String): String {
        val tree = android.net.Uri.parse(treeUri)
        val dirDocId = android.provider.DocumentsContract.getTreeDocumentId(tree)
        val dirUri = android.provider.DocumentsContract
            .buildDocumentUriUsingTree(tree, dirDocId)
        val mime = when {
            name.endsWith(".mkv", true) -> "video/x-matroska"
            name.endsWith(".webm", true) -> "video/webm"
            name.endsWith(".avi", true) -> "video/x-msvideo"
            else -> "video/mp4"
        }
        val childUri = android.provider.DocumentsContract.createDocument(
            context.contentResolver, dirUri, mime, name,
        ) ?: throw IllegalStateException("could not create file in folder")
        context.contentResolver.openOutputStream(childUri)?.use { out ->
            src.inputStream().use { it.copyTo(out, 1 shl 16) }
        } ?: throw IllegalStateException("could not open output")
        return childUri.toString()
    }

    private fun pause(id: String) {
        try { handles[id]?.pause() } catch (_: Throwable) {}
        emit(id, "paused")
    }

    private fun resume(id: String) {
        val h = handles[id]
        if (h != null) {
            try { h.resume() } catch (_: Throwable) {}
            emit(id, "downloading")
        } else {
            // Was queued or not yet started — try to start it now.
            startNext()
        }
    }

    private fun cancel(id: String) {
        pending.removeAll { it.id == id }
        val h = handles.remove(id)
        if (h != null) {
            try { session?.remove(h) } catch (_: Throwable) {}
        }
        cleanup(id)
        startNext()
    }

    private fun cleanup(id: String) {
        done.remove(id)
        saveTree.remove(id)
        try { File(context.filesDir, "torrent_downloads/$id").deleteRecursively() } catch (_: Throwable) {}
    }

    @Synchronized
    private fun startNext() {
        if (handles.size >= MAX_ACTIVE) return
        val next = synchronized(pending) {
            if (pending.isEmpty()) null else pending.removeAt(0)
        }
        if (next == null) {
            maybeStopService() // nothing left to run → release the process
            return
        }
        startDownload(next.id, next.uri)
    }

    companion object {
        private const val MAX_ACTIVE = 2
        private val VIDEO_EXTS =
            listOf(".mp4", ".mkv", ".avi", ".webm", ".mov", ".m4v", ".ts", ".flv")
    }
}
