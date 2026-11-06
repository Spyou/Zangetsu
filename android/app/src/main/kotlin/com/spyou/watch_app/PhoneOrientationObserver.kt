package com.spyou.watch_app

import android.content.Context
import android.content.res.Configuration
import android.view.OrientationEventListener

/** Reports settled physical turns even while a player temporarily locks the display. */
internal class PhoneOrientationObserver(
    context: Context,
    private val onTurn: (Int) -> Unit,
) : OrientationEventListener(context) {
    private var last: Int? = null

    override fun onOrientationChanged(orientation: Int) {
        val next = when (orientation) {
            in 0..25, in 155..205, in 335..359 -> Configuration.ORIENTATION_PORTRAIT
            in 65..115, in 245..295 -> Configuration.ORIENTATION_LANDSCAPE
            else -> return
        }
        if (last == next) return
        last = next
        onTurn(next)
    }
}
