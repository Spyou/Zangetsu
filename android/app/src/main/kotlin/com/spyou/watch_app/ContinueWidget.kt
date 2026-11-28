package com.spyou.watch_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Continue Watching home-screen widget. It only reads what Dart last wrote
 * (title, episode line, progress, a cover file); it never touches the network
 * or Hive, and refreshes only when Dart pushes an update.
 */
object ContinueWidget {
    private const val PREFS = "continue_widget"

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "zangetsu/widget").setMethodCallHandler { call, result ->
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            when (call.method) {
                "update" -> {
                    prefs.edit()
                        .putString("title", call.argument<String>("title"))
                        .putString("sub", call.argument<String>("sub"))
                        .putInt("progress", call.argument<Int>("progress") ?: 0)
                        .putString("cover", call.argument<String>("cover"))
                        .putString("source", call.argument<String>("source"))
                        .putString("show", call.argument<String>("show"))
                        .apply()
                    refresh(context)
                    result.success(null)
                }
                "clear" -> {
                    prefs.edit().clear().apply()
                    refresh(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun refresh(context: Context) {
        val mgr = AppWidgetManager.getInstance(context)
        for ((cls, small) in listOf(
            ContinueWidgetWide::class.java to false,
            ContinueWidgetSmall::class.java to true,
        )) {
            for (id in mgr.getAppWidgetIds(ComponentName(context, cls))) {
                // The launcher's own cell size decides how big this is, so size
                // the cover to the real slot rather than a guessed one.
                val o = mgr.getAppWidgetOptions(id)
                val wDp = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 110)
                val hDp = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 110)
                mgr.updateAppWidget(id, build(context, small, wDp, hDp))
            }
        }
    }

    private fun build(context: Context, small: Boolean, wDp: Int, hDp: Int): RemoteViews {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val title = prefs.getString("title", null)
        val views = RemoteViews(
            context.packageName,
            if (small) R.layout.widget_continue_small else R.layout.widget_continue_wide,
        )
        val has = !title.isNullOrEmpty()
        if (has) {
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_sub, prefs.getString("sub", ""))
            views.setProgressBar(R.id.widget_progress, 100, prefs.getInt("progress", 0), false)
            views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
            val bmp = loadCover(context, prefs.getString("cover", null), small, wDp, hDp)
            if (bmp != null) views.setImageViewBitmap(R.id.widget_cover, bmp)
            else views.setImageViewBitmap(R.id.widget_cover, null)
            val uri = Uri.Builder().scheme("zangetsu").authority("resume")
                .appendQueryParameter("s", prefs.getString("source", ""))
                .appendQueryParameter("id", prefs.getString("show", ""))
                .build()
            val open = Intent(Intent.ACTION_VIEW, uri).setClass(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, if (small) 1 else 2, open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        } else {
            views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_empty_title))
            views.setTextViewText(R.id.widget_sub, context.getString(R.string.widget_empty_sub))
            views.setViewVisibility(R.id.widget_progress, View.GONE)
            views.setImageViewBitmap(R.id.widget_cover, null)
            if (small) {
                // No cover behind the text: use the theme's own text colours
                // (white would vanish on a light surface) and drop the scrim.
                views.setViewVisibility(R.id.widget_shade, View.GONE)
                views.setTextColor(R.id.widget_title, context.getColor(R.color.w_on_surface))
                views.setTextColor(R.id.widget_sub, context.getColor(R.color.w_on_surface_variant))
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                views.setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getActivity(
                        context, 3, launch,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
        }
        return views
    }

    // One decoded cover per size, reused until the file changes: every update
    // refreshes both widget kinds, and decoding twice per push is wasted work.
    private val covers = HashMap<String, Pair<Long, Bitmap>>()

    /**
     * The cover Dart saved, decoded at roughly the size it is shown (a sampled
     * decode, so a large poster never sits fully in memory), cropped to the
     * slot's shape and rounded to match the widget. RemoteViews has a hard
     * size cap, so staying small is also what keeps the widget from failing.
     */
    private fun loadCover(context: Context, path: String?, small: Boolean, wDp: Int, hDp: Int): Bitmap? {
        if (path.isNullOrEmpty()) return null
        val file = java.io.File(path)
        if (!file.exists()) return null
        val key = "$small-$wDp-$hDp"
        val stamp = file.lastModified()
        covers[key]?.let { if (it.first == stamp) return it.second }
        return try {
            val density = context.resources.displayMetrics.density
            // Small: the whole widget. Wide: the 64dp cover slot, as tall as the
            // widget minus its padding. Capped so a huge widget can't bust the
            // RemoteViews size limit.
            val w = (minOf(if (small) wDp else 64, 320) * density).toInt()
            val h = (minOf(if (small) hDp else maxOf(hDp - 20, 40), 320) * density).toInt()
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= w && bounds.outHeight / (sample * 2) >= h) {
                sample *= 2
            }
            val src = BitmapFactory.decodeFile(
                path, BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return null
            // Centre-crop the source to the slot's aspect ratio.
            val want = w.toFloat() / h
            val have = src.width.toFloat() / src.height
            val cw = if (have > want) (src.height * want).toInt() else src.width
            val ch = if (have > want) src.height else (src.width / want).toInt()
            val crop = android.graphics.Rect(
                (src.width - cw) / 2, (src.height - ch) / 2,
                (src.width + cw) / 2, (src.height + ch) / 2,
            )
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
            val radius = context.resources.getDimension(
                if (small) R.dimen.w_radius else R.dimen.w_inner_radius,
            )
            canvas.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(src, crop, android.graphics.Rect(0, 0, w, h), paint)
            src.recycle()
            if (covers.size >= 4) covers.clear() // a resize adds a new size; keep it bounded
            covers[key] = stamp to out
            out
        } catch (_: Throwable) {
            null
        }
    }
}

class ContinueWidgetWide : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        ContinueWidget.refresh(context)

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, newOptions: android.os.Bundle,
    ) = ContinueWidget.refresh(context)
}

class ContinueWidgetSmall : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        ContinueWidget.refresh(context)

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, newOptions: android.os.Bundle,
    ) = ContinueWidget.refresh(context)
}
