package com.spyou.watch_app.cast

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/**
 * Google-hosted media receiver — no custom (paid/hosted) receiver.
 *
 * Uses "A12D4273" (the Default Media Receiver WITH DRM) instead of the bare
 * default (CC1AD845). This is the receiver ExoPlayer's cast extension — and
 * apps like AniLab — default to; it tends to handle adaptive (HLS) streams more
 * robustly across TVs. Still free + Google-hosted (no App ID to register).
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId("A12D4273")
            .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
