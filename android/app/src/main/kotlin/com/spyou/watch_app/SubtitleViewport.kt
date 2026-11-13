package com.spyou.watch_app

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.ui.PlayerView

/** Keeps captions screen-aligned while the video frame changes aspect ratio. */
fun PlayerView.keepSubtitlesInViewport() {
    val subtitles = subtitleView ?: return
    if (subtitles.parent === this) return
    val parent = subtitles.parent as? ViewGroup ?: return
    val content = findViewById<View>(androidx.media3.ui.R.id.exo_content_frame) ?: return
    val contentIndex = indexOfChild(content)
    if (contentIndex < 0) return
    parent.removeView(subtitles)
    // Above the video, below the existing controls and ad overlays.
    addView(subtitles, contentIndex + 1, FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
    ))
}
