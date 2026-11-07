package com.spyou.watch_app

import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel

/** Download-only sheet: selecting a server never calls the playback channel methods. */
internal class PhoneWatchDownloadSheet(
    context: Context,
    private val channel: MethodChannel,
    private val session: Long,
    private val index: Int,
    private val title: String,
    private val accent: Int,
    data: Map<String, Any?>,
    private val downloadIcon: android.graphics.drawable.Drawable? = null,
) : Dialog(context, android.R.style.Theme_DeviceDefault_Dialog_NoActionBar) {
    private val surface = ((data["downloadSurface"] ?: data["surface"]) as? Number)?.toInt() ?: 0xFF202024.toInt()
    private val secondary = (data["secondary"] as? Number)?.toInt() ?: 0xFFBDBDC6.toInt()
    private lateinit var categories: LinearLayout
    private lateinit var body: LinearLayout
    private var request = 0
    private var submitting = false
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + .5f).toInt()
    private fun shape(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    private fun text(value: String, size: Float, color: Int = Color.WHITE) = TextView(context).apply {
        text = value; textSize = size; setTextColor(color)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(12), dp(20), dp(20))
            background = shape(surface, 20).apply { val r = dp(20).toFloat(); cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f) }
        }
        root.addView(View(context).apply { background = shape(secondary, 2) },
            LinearLayout.LayoutParams(dp(40), dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(14) })
        root.addView(text(context.getString(R.string.phone_player_watch_download_choose), 22f).apply { typeface = Typeface.DEFAULT_BOLD })
        root.addView(text(title, 13f, secondary).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(4), 0, dp(12)) })
        categories = LinearLayout(context)
        root.addView(categories)
        body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(context).apply { addView(body) }
        root.addView(scroll)
        setContentView(root)
        setCanceledOnTouchOutside(true)
        window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(.54f)
            setGravity(Gravity.BOTTOM)
        }
    }

    override fun show() {
        super.show()
        window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        load(null)
    }

    override fun dismiss() { request++; super.dismiss() }

    private fun invoke(method: String, args: Map<String, Any?>, result: (Any?) -> Unit) {
        val expected = request
        channel.invokeMethod(method, mapOf("sessionId" to session, "index" to index) + args,
            object : MethodChannel.Result {
                override fun success(value: Any?) { if (isShowing && expected == request) result(value) }
                override fun error(code: String, message: String?, details: Any?) { if (isShowing && expected == request) failed() }
                override fun notImplemented() { if (isShowing && expected == request) failed() }
            })
    }

    private fun failed() {
        submitting = false
        body.removeAllViews()
        body.addView(text(context.getString(R.string.phone_player_watch_download_failed), 14f, secondary))
    }

    private fun load(category: String?) {
        request++
        (body.parent as ScrollView).layoutParams = (body.parent as ScrollView).layoutParams.apply { height = ViewGroup.LayoutParams.WRAP_CONTENT }
        body.removeAllViews()
        body.addView(ProgressBar(context).apply { indeterminateTintList = android.content.res.ColorStateList.valueOf(accent) },
            LinearLayout.LayoutParams(dp(26), dp(26)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(28); bottomMargin = dp(28) })
        invoke("watchDownloadOptions", if (category == null) emptyMap() else mapOf("category" to category)) { raw ->
            val data = raw as? Map<*, *> ?: run { failed(); return@invoke }
            body.removeAllViews()
            categories.removeAllViews()
            val status = data["status"] as? String
            if (status != null) {
                val paused = status == "paused"
                action(context.getString(if (paused) R.string.phone_player_watch_download_resume else R.string.phone_player_watch_download_pause)) {
                    manage(if (paused) "resume" else "pause")
                }
                action(context.getString(R.string.phone_player_watch_download_cancel)) { manage("cancel") }
                return@invoke
            }
            val cuts = (data["categories"] as? List<*>)?.filterIsInstance<String>().orEmpty()
            if (cuts.size > 1) for (cut in cuts) {
                val selected = cut == data["category"]
                categories.addView(text(if (cut == "dub") "DUB" else "SUB", 14f, if (selected) Color.BLACK else Color.WHITE).apply {
                    gravity = Gravity.CENTER; setPadding(dp(16), 0, dp(16), 0)
                    background = shape(if (selected) accent else Color.TRANSPARENT, 20)
                    isClickable = true; isFocusable = true
                    setOnClickListener { if (!submitting && !selected) load(cut) }
                }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(40)).apply { marginEnd = dp(8); bottomMargin = dp(12) })
            }
            val sources = (data["sources"] as? List<*>)?.filterIsInstance<Map<*, *>>().orEmpty()
            if (sources.isEmpty()) body.addView(text(context.getString(R.string.phone_player_watch_download_empty), 14f, secondary))
            for ((sourceIndex, source) in sources.withIndex()) {
                val label = (source["label"] as? String).orEmpty().ifBlank { "Server ${sourceIndex + 1}" }
                val quality = (source["quality"] as? String).orEmpty()
                val kind = if (source["mimeType"] == "application/x-mpegURL") "HLS" else "Direct"
                action(label, listOf(quality, kind).filter { it.isNotBlank() }.joinToString(" · "), true) {
                    if (submitting) return@action
                    submitting = true
                    invoke("watchDownloadChoose", mapOf("token" to data["token"], "source" to sourceIndex)) { ok ->
                        if (ok == true) {
                            Toast.makeText(context, R.string.phone_player_watch_download_added, Toast.LENGTH_SHORT).show()
                            dismiss()
                        } else failed()
                    }
                }
            }
            body.post {
                if (isShowing) {
                    val max = (context.resources.displayMetrics.heightPixels * .6).toInt()
                    val scroll = body.parent as ScrollView
                    scroll.layoutParams = scroll.layoutParams.apply { height = if (body.height > max) max else ViewGroup.LayoutParams.WRAP_CONTENT }
                }
            }
        }
    }

    private fun action(label: String, subtitle: String? = null, download: Boolean = false, click: () -> Unit) {
        body.addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(14), dp(8), dp(14))
            if (download) addView(ImageView(context).apply {
                setImageDrawable(downloadIcon?.constantState?.newDrawable(context.resources)?.mutate())
                setColorFilter(accent)
            }, LinearLayout.LayoutParams(dp(24), dp(24)).apply { marginEnd = dp(16) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(text(label, 15f))
                if (subtitle != null) addView(text(subtitle, 13f, secondary))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            background = android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf((accent and 0xFFFFFF) or 0x24000000), null, shape(Color.WHITE, 12))
            isClickable = true; isFocusable = true; setOnClickListener { click() }
        })
    }

    private fun manage(action: String) {
        if (submitting) return
        submitting = true
        invoke("watchDownloadAction", mapOf("action" to action)) { if (it == true) dismiss() else failed() }
    }
}
