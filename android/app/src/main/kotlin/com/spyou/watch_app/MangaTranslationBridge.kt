package com.spyou.watch_app

import android.content.Context
import android.graphics.Rect
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallClient
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.tasks.Task
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

internal enum class MangaOcrScript {
    LATIN,
    CHINESE,
    DEVANAGARI,
    JAPANESE,
    KOREAN,
}

internal class MangaTranslationBridgeException(
    val code: String,
    message: String,
    val details: Any? = null,
    cause: Throwable? = null,
) : Exception(message, cause)

/** Keeps coroutine cancellation out of ordinary platform-error mapping. */
internal fun rethrowIfCancellation(error: Throwable) {
    if (error is kotlinx.coroutines.CancellationException) throw error
}

internal fun googleTaskFailure(isCanceled: Boolean, failure: Exception?): Throwable =
    if (isCanceled || failure is kotlinx.coroutines.CancellationException) {
        MangaTranslationBridgeException(
            code = "platform_task_cancelled",
            message = "Google Play services or ML Kit cancelled the operation.",
            details = mapOf("exception" to "CancellationException"),
            cause = failure,
        )
    } else {
        failure ?: IllegalStateException("Google task failed without an exception.")
    }

private val DIRECT_TASK_COMPLETION_EXECUTOR = Executor { command -> command.run() }

/** Awaits a Google task without blocking; task cancellation is an operation error unless our job was cancelled. */
internal suspend fun <T> awaitGoogleTask(task: Task<T>): T =
    suspendCancellableCoroutine { continuation ->
        task.addOnCompleteListener(DIRECT_TASK_COMPLETION_EXECUTOR) { completed ->
            if (!continuation.isActive) return@addOnCompleteListener
            when {
                completed.isSuccessful -> continuation.resume(completed.result)
                else -> continuation.resumeWithException(
                    googleTaskFailure(completed.isCanceled, completed.exception),
                )
            }
        }
    }

/** Applies the bridge-owned deadline only to OCR-module availability polling. */
internal suspend fun awaitOcrModuleReady(
    timeoutMillis: Long,
    pollIntervalMillis: Long,
    isAvailable: suspend () -> Boolean,
) {
    val ready = withTimeoutOrNull(timeoutMillis) {
        while (!isAvailable()) delay(pollIntervalMillis)
        true
    }
    if (ready != true) {
        throw MangaTranslationBridgeException(
            code = "model_download_failed",
            message = "Timed out waiting for the OCR recognition module to become available.",
        )
    }
}

/** Bounds a user-confirmed translation-model download; only this deadline becomes a bridge error. */
internal suspend fun awaitTranslationModelDownloads(
    timeoutMillis: Long,
    download: suspend () -> Unit,
) {
    val completed = withTimeoutOrNull(timeoutMillis) {
        download()
        true
    }
    if (completed != true) {
        throw MangaTranslationBridgeException(
            code = "model_download_failed",
            message = "Timed out waiting for translation models to download.",
        )
    }
}

/** Preserves the first bridge error in a wrapped cause chain before unwrapping platform failures. */
internal fun Throwable.asBridgeError(
    fallbackCode: String = "platform_error",
): MangaTranslationBridgeException {
    var root: Throwable = this
    val seen = mutableSetOf<Throwable>()
    while (seen.add(root)) {
        if (root is MangaTranslationBridgeException) return root
        val cause = root.cause ?: break
        root = cause
    }
    return MangaTranslationBridgeException(
        code = fallbackCode,
        message = root.message ?: "Android manga translation failed.",
        details = mapOf("exception" to root.javaClass.simpleName),
        cause = root,
    )
}

/** Delivers at most one MethodChannel result, on the supplied main-thread dispatcher. */
internal class MangaTranslationOnceResult(
    private val result: MethodChannel.Result,
    private val dispatchToMain: (() -> Unit) -> Unit,
) {
    private val replied = AtomicBoolean(false)

    fun success(value: Any?) = deliver {
        result.success(if (value === Unit) null else value)
    }

    fun error(code: String, message: String, details: Any?) =
        deliver { result.error(code, message, details) }

    private fun deliver(action: () -> Unit) {
        if (replied.compareAndSet(false, true)) dispatchToMain(action)
    }
}

/** Maps the app's canonical language catalog to ML Kit's OCR script clients. */
internal object MangaOcrScriptMapping {
    private val languageCodesByScript = mapOf(
        MangaOcrScript.LATIN to setOf(
            "af", "sq", "az", "eu", "bs", "ca", "ceb", "co", "hr", "cs",
            "da", "nl", "en", "eo", "et", "tl", "fi", "fr", "fy", "gl",
            "de", "ht", "ha", "haw", "hmn", "hu", "is", "ig", "id", "ga",
            "it", "jv", "rw", "ku", "la", "lv", "lt", "lb", "mg", "ms",
            "mt", "mi", "no", "ny", "pl", "pt", "ro", "sm", "gd", "st",
            "sn", "sk", "sl", "so", "es", "su", "sw", "sv", "tr", "tk",
            "uz", "vi", "cy", "xh", "yo", "zu", "ace", "ach", "ban",
            "bem", "bik", "din", "fj", "ilo", "kha", "kri", "lus", "mos",
            "pap", "scn", "tum", "war", "mak",
        ),
        MangaOcrScript.CHINESE to setOf("zh"),
        MangaOcrScript.DEVANAGARI to setOf(
            "hi", "mr", "ne", "awa", "bho", "doi", "dty", "gom", "mai", "sa",
        ),
        MangaOcrScript.JAPANESE to setOf("ja"),
        MangaOcrScript.KOREAN to setOf("ko"),
    )

    val supportedLanguageCodes: Set<String> = languageCodesByScript.values.flatten().toSet()

    fun forLanguage(languageCode: String): MangaOcrScript {
        val normalizedCode = languageCode.trim().replace('_', '-').lowercase(Locale.ROOT)
            .substringBefore('-')
        return languageCodesByScript.entries.firstOrNull { normalizedCode in it.value }?.key
            ?: throw MangaTranslationBridgeException(
                code = "unsupported_source_language",
                message = "Android OCR does not support the source script for '$languageCode'.",
            )
    }
}

/** Android implementation of `AniAura/manga_translation`. */
internal class MangaTranslationBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in METHODS) {
            result.notImplemented()
            return
        }

        val reply = MangaTranslationOnceResult(result) { action -> mainHandler.post(action) }
        scope.launch {
            try {
                reply.success(dispatch(call))
            } catch (error: Throwable) {
                rethrowIfCancellation(error)
                val bridgeError = error.asBridgeError()
                reply.error(
                    bridgeError.code,
                    bridgeError.message ?: "Android manga translation failed.",
                    bridgeError.details,
                )
            }
        }
    }

    private suspend fun dispatch(call: MethodCall): Any? = when (call.method) {
        "supportedOcrLanguages" -> MangaOcrScriptMapping.supportedLanguageCodes.sorted()
        "supportedOfflineLanguages" -> supportedOfflineLanguageCodes()
        "modelStatus" -> modelStatus(
            sourceLanguage = call.requiredString("sourceLanguage"),
            targetLanguage = call.requiredString("targetLanguage"),
            engine = call.requiredString("engine"),
        )
        "downloadModels" -> downloadModels(
            sourceLanguage = call.requiredString("sourceLanguage"),
            targetLanguage = call.requiredString("targetLanguage"),
            engine = call.requiredString("engine"),
        )
        "recognize" -> recognize(
            filePath = call.requiredString("filePath"),
            sourceLanguage = call.requiredString("sourceLanguage"),
        )
        "translateTexts" -> translateTexts(
            texts = call.requiredStringList("texts"),
            sourceLanguage = call.requiredString("sourceLanguage"),
            targetLanguage = call.requiredString("targetLanguage"),
        )
        else -> null
    }

    private fun supportedOfflineLanguageCodes(): List<String> = TranslateLanguage.getAllLanguages()
        .mapNotNull(::canonicalLanguageCode)
        .distinct()
        .sorted()

    private suspend fun modelStatus(
        sourceLanguage: String,
        targetLanguage: String,
        engine: String,
    ): Map<String, Boolean> {
        requireEngine(engine)
        val ocrReady = isOcrModuleAvailable(sourceLanguage)
        if (engine == ENGINE_ONLINE) {
            return mapOf(
                "ocrReady" to ocrReady,
                "sourceTranslationReady" to true,
                "targetTranslationReady" to true,
            )
        }

        val downloadedLanguages = downloadedTranslationLanguages()
        val sourceCode = mlKitLanguage(sourceLanguage)
        val targetCode = mlKitLanguage(targetLanguage)
        return mapOf(
            "ocrReady" to ocrReady,
            "sourceTranslationReady" to (sourceCode == targetCode || sourceCode in downloadedLanguages),
            "targetTranslationReady" to (sourceCode == targetCode || targetCode in downloadedLanguages),
        )
    }

    /** Called only from the reader's explicit, confirmed model-download action. */
    private suspend fun downloadModels(
        sourceLanguage: String,
        targetLanguage: String,
        engine: String,
    ) {
        requireEngine(engine)
        installOcrModule(sourceLanguage)
        if (engine == ENGINE_ONLINE) return

        val sourceCode = mlKitLanguage(sourceLanguage)
        val targetCode = mlKitLanguage(targetLanguage)
        if (sourceCode == targetCode) return

        try {
            awaitTranslationModelDownloads(TRANSLATION_MODEL_DOWNLOAD_TIMEOUT_MS) {
                val downloaded = downloadedTranslationLanguages()
                val conditions = DownloadConditions.Builder().requireWifi().build()
                val manager = RemoteModelManager.getInstance()
                for (language in listOf(sourceCode, targetCode).distinct().filterNot(downloaded::contains)) {
                    val model = TranslateRemoteModel.Builder(language).build()
                    awaitGoogleTask(manager.download(model, conditions))
                }
            }
        } catch (error: Throwable) {
            rethrowIfCancellation(error)
            throw error.asBridgeError("model_download_failed")
        }
    }

    private suspend fun isOcrModuleAvailable(sourceLanguage: String): Boolean {
        ensureGooglePlayServices()
        val recognizer = recognizerFor(sourceLanguage)
        return try {
            awaitGoogleTask(ModuleInstall.getClient(appContext).areModulesAvailable(recognizer))
                .areModulesAvailable()
        } catch (error: Throwable) {
            rethrowIfCancellation(error)
            throw error.asBridgeError("model_status_failed")
        } finally {
            recognizer.close()
        }
    }

    private suspend fun installOcrModule(sourceLanguage: String) {
        ensureGooglePlayServices()
        val recognizer = recognizerFor(sourceLanguage)
        val moduleClient = ModuleInstall.getClient(appContext)
        try {
            if (awaitGoogleTask(moduleClient.areModulesAvailable(recognizer)).areModulesAvailable()) return

            val request = ModuleInstallRequest.newBuilder().addApi(recognizer).build()
            val response = awaitGoogleTask(moduleClient.installModules(request))
            if (response.areModulesAlreadyInstalled()) return

            // installModules reports that installation was requested, not that the
            // recognizer is ready. Poll its local availability without invoking OCR.
            awaitOcrModuleReady(MODULE_INSTALL_TIMEOUT_MS, MODULE_INSTALL_POLL_MS) {
                awaitGoogleTask(moduleClient.areModulesAvailable(recognizer)).areModulesAvailable()
            }
        } catch (error: Throwable) {
            rethrowIfCancellation(error)
            throw error.asBridgeError("model_download_failed")
        } finally {
            recognizer.close()
        }
    }

    private suspend fun recognize(filePath: String, sourceLanguage: String): Map<String, Any> {
        val file = File(filePath)
        if (!file.isFile || !file.canRead()) {
            throw MangaTranslationBridgeException(
                code = "image_read_failed",
                message = "The current manga page is not available as a readable local file.",
            )
        }

        ensureGooglePlayServices()
        val recognizer = recognizerFor(sourceLanguage)
        try {
            val image = try {
                InputImage.fromFilePath(appContext, Uri.fromFile(file))
            } catch (error: IOException) {
                throw MangaTranslationBridgeException(
                    code = "image_read_failed",
                    message = "Could not open the current manga page for OCR.",
                    cause = error,
                )
            }
            val text = try {
                awaitGoogleTask(recognizer.process(image))
            } catch (error: Throwable) {
                rethrowIfCancellation(error)
                throw error.asBridgeError("ocr_failed")
            }

            // fromFilePath reads the file's EXIF orientation and supplies it to
            // ML Kit. Use that resulting orientation for dimensions; do not rotate
            // its returned boxes a second time.
            val rotation = image.rotationDegrees
            val imageWidth = if (rotation == 90 || rotation == 270) image.height else image.width
            val imageHeight = if (rotation == 90 || rotation == 270) image.width else image.height
            if (imageWidth <= 0 || imageHeight <= 0) {
                throw MangaTranslationBridgeException(
                    code = "ocr_failed",
                    message = "The current manga page has invalid image dimensions.",
                )
            }

            val regions = text.textBlocks.mapNotNull { block ->
                val bounds = block.boundingBox ?: return@mapNotNull null
                if (block.text.isBlank()) return@mapNotNull null
                normalizedRegion(block.text, bounds, imageWidth, imageHeight)
            }
            return mapOf(
                "imageWidth" to imageWidth,
                "imageHeight" to imageHeight,
                "regions" to regions,
            )
        } finally {
            recognizer.close()
        }
    }

    private fun normalizedRegion(
        text: String,
        bounds: Rect,
        imageWidth: Int,
        imageHeight: Int,
    ): Map<String, Any> {
        val left = (bounds.left.toDouble() / imageWidth).coerceIn(0.0, 1.0)
        val top = (bounds.top.toDouble() / imageHeight).coerceIn(0.0, 1.0)
        val right = (bounds.right.toDouble() / imageWidth).coerceIn(left, 1.0)
        val bottom = (bounds.bottom.toDouble() / imageHeight).coerceIn(top, 1.0)
        return mapOf(
            "text" to text,
            "left" to left,
            "top" to top,
            "right" to right,
            "bottom" to bottom,
        )
    }

    private suspend fun translateTexts(
        texts: List<String>,
        sourceLanguage: String,
        targetLanguage: String,
    ): List<String> {
        val sourceCode = mlKitLanguage(sourceLanguage)
        val targetCode = mlKitLanguage(targetLanguage)
        if (texts.isEmpty() || sourceCode == targetCode) return texts

        val downloaded = downloadedTranslationLanguages()
        if (sourceCode !in downloaded || targetCode !in downloaded) {
            throw MangaTranslationBridgeException(
                code = "translation_model_missing",
                message = "The selected offline translation language models are not downloaded.",
            )
        }

        val translator: Translator = try {
            Translation.getClient(
                TranslatorOptions.Builder()
                    .setSourceLanguage(sourceCode)
                    .setTargetLanguage(targetCode)
                    .build(),
            )
        } catch (error: Throwable) {
            rethrowIfCancellation(error)
            throw error.asBridgeError("translation_failed")
        }

        try {
            val semaphore = Semaphore(TRANSLATION_CONCURRENCY)
            return coroutineScope {
                texts.map { text ->
                    async(Dispatchers.IO) {
                        semaphore.withPermit {
                            try {
                                awaitGoogleTask(translator.translate(text))
                            } catch (error: Throwable) {
                                rethrowIfCancellation(error)
                                throw error.asBridgeError("translation_failed")
                            }
                        }
                    }
                }.awaitAll()
            }
        } finally {
            translator.close()
        }
    }

    private suspend fun downloadedTranslationLanguages(): Set<String> = try {
        RemoteModelManager.getInstance()
            .getDownloadedModels(TranslateRemoteModel::class.java)
            .let { task -> awaitGoogleTask(task) }
            .mapNotNull { model -> canonicalLanguageCode(model.language) }
            .toSet()
    } catch (error: Throwable) {
        rethrowIfCancellation(error)
        throw error.asBridgeError("model_status_failed")
    }

    private fun recognizerFor(languageCode: String): TextRecognizer {
        val script = MangaOcrScriptMapping.forLanguage(languageCode)
        return when (script) {
            MangaOcrScript.LATIN -> TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            MangaOcrScript.CHINESE -> TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
            MangaOcrScript.DEVANAGARI -> TextRecognition.getClient(DevanagariTextRecognizerOptions.Builder().build())
            MangaOcrScript.JAPANESE -> TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
            MangaOcrScript.KOREAN -> TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
        }
    }

    private fun mlKitLanguage(languageCode: String): String {
        val normalized = canonicalLanguageCode(languageCode)
        val language = normalized?.let(TranslateLanguage::fromLanguageTag)
        return language ?: throw MangaTranslationBridgeException(
            code = "unsupported_offline_language",
            message = "ML Kit offline translation does not support '$languageCode'.",
        )
    }

    private fun ensureGooglePlayServices() {
        val status = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(appContext)
        if (status != ConnectionResult.SUCCESS) {
            throw MangaTranslationBridgeException(
                code = "missing_google_play_services",
                message = "Google Play services is required for Android text recognition.",
                details = mapOf("status" to status),
            )
        }
    }

    private fun requireEngine(engine: String) {
        if (engine != ENGINE_ONLINE && engine != ENGINE_OFFLINE) {
            throw MangaTranslationBridgeException(
                code = "invalid_argument",
                message = "Unknown translation engine '$engine'.",
            )
        }
    }

    private fun canonicalLanguageCode(languageCode: String): String? {
        val tag = languageCode.trim().replace('_', '-')
        if (tag.isEmpty()) return null
        val language = Locale.forLanguageTag(tag).language.lowercase(Locale.ROOT)
        if (language.isEmpty()) return null
        return TranslateLanguage.fromLanguageTag(language)?.lowercase(Locale.ROOT)
    }

    private fun MethodCall.requiredString(key: String): String = argument<String>(key)?.takeIf(String::isNotBlank)
        ?: throw MangaTranslationBridgeException(
            code = "invalid_argument",
            message = "Missing or invalid '$key' argument.",
        )

    private fun MethodCall.requiredStringList(key: String): List<String> {
        val values = argument<List<*>>(key)
            ?: throw MangaTranslationBridgeException(
                code = "invalid_argument",
                message = "Missing or invalid '$key' argument.",
            )
        if (values.any { it !is String }) {
            throw MangaTranslationBridgeException(
                code = "invalid_argument",
                message = "Every item in '$key' must be a string.",
            )
        }
        return values.filterIsInstance<String>()
    }

    private companion object {
        const val ENGINE_ONLINE = "online"
        const val ENGINE_OFFLINE = "offline"
        const val TRANSLATION_CONCURRENCY = 4
        const val MODULE_INSTALL_TIMEOUT_MS = 10 * 60 * 1000L
        const val MODULE_INSTALL_POLL_MS = 750L
        const val TRANSLATION_MODEL_DOWNLOAD_TIMEOUT_MS = 15 * 60 * 1000L
        val METHODS = setOf(
            "supportedOcrLanguages",
            "supportedOfflineLanguages",
            "modelStatus",
            "downloadModels",
            "recognize",
            "translateTexts",
        )
    }
}
