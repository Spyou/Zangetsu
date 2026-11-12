package com.spyou.watch_app

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

@UnstableApi
internal object PhonePlaybackCache {
    private const val MB = 1024L * 1024L
    private var cache: SimpleCache? = null
    private var database: StandaloneDatabaseProvider? = null
    private var limit = 0L
    private var users = 0

    fun nativeLimitMb(context: Context): Int {
        if (Build.VERSION.SDK_INT < 27) return 0
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        return (minOf(memory.totalMem / 8, memory.availMem / 4, 512 * MB) / MB)
            .toInt().let { it / 32 * 32 }.coerceAtLeast(0)
    }

    fun supports(url: String, mime: String?): Boolean {
        val uri = Uri.parse(url)
        return (uri.scheme == "http" || uri.scheme == "https") &&
            Util.inferContentTypeForUriAndMimeType(uri, mime) == C.CONTENT_TYPE_OTHER
    }

    fun keyFor(url: String, headers: Map<String, String>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fun add(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.size).array())
            digest.update(bytes)
        }
        add(url)
        headers.entries.sortedBy { it.key.lowercase(Locale.ROOT) }.forEach {
            add(it.key.lowercase(Locale.ROOT)); add(it.value)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    fun acquire(context: Context, requestedBytes: Long, reserveFreeSpace: Boolean = true): Cache {
        val directory = File(context.cacheDir, "phone_playback_cache")
        val available = context.cacheDir.usableSpace + (cache?.cacheSpace ?: 0L)
        val bytes = if (reserveFreeSpace) minOf(requestedBytes, (available - 512 * MB).coerceAtLeast(0))
            else requestedBytes
        if (bytes <= 0) throw IOException("Not enough space for playback cache")
        if (cache != null && bytes != limit && users == 0) {
            cache?.release()
            cache = null
            database?.close()
            database = null
        }
        if (cache == null) {
            val provider = StandaloneDatabaseProvider(context.applicationContext)
            try {
                cache = SimpleCache(directory, LeastRecentlyUsedCacheEvictor(bytes), provider)
                cache!!.checkInitialization()
                database = provider
                limit = bytes
            } catch (error: Exception) {
                cache?.release()
                cache = null
                provider.close()
                throw error
            }
        }
        users++
        return cache!!
    }

    @Synchronized
    fun prepare(context: Context, requestedBytes: Long) {
        if (cache == null && File(context.cacheDir, "phone_playback_cache").exists()) {
            acquire(context, requestedBytes, reserveFreeSpace = false)
            release()
        }
    }

    @Synchronized fun release() { if (users > 0) users-- }
    @Synchronized fun sizeBytes(): Long = cache?.cacheSpace ?: 0L

    @Synchronized
    fun clear(): Boolean {
        if (users > 0) return false
        val current = cache ?: return true
        current.keys.toList().forEach { current.removeResource(it) }
        return true
    }

    fun factory(
        upstream: DataSource.Factory,
        url: String,
        headers: Map<String, String>,
        diskCache: Cache?,
        nativeBytes: Int,
    ): DataSource.Factory {
        if (diskCache == null && nativeBytes <= 0) return upstream
        val buffered: DataSource.Factory = if (diskCache == null) upstream else CacheDataSource.Factory()
            .setCache(diskCache)
            .setUpstreamDataSourceFactory(upstream)
            .setCacheKeyFactory { keyFor(it.uri.toString(), headers) }
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        return DataSource.Factory {
            val plain = upstream.createDataSource()
            val cached = if (nativeBytes > 0) NativeReadAheadDataSource(buffered, nativeBytes)
                else buffered.createDataSource()
            object : DataSource {
                private var active: DataSource = plain
                override fun open(spec: DataSpec): Long {
                    active = if (spec.uri.toString() == url) cached else plain
                    val request = if (active === cached) spec.buildUpon()
                        .setFlags(spec.flags or DataSpec.FLAG_DONT_CACHE_IF_LENGTH_UNKNOWN).build() else spec
                    return active.open(request)
                }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int = active.read(buffer, offset, length)
                override fun close() = active.close()
                override fun getUri(): Uri? = active.uri
                override fun getResponseHeaders(): Map<String, List<String>> = active.responseHeaders
                override fun addTransferListener(listener: TransferListener) {
                    plain.addTransferListener(listener); cached.addTransferListener(listener)
                }
            }
        }
    }
}
