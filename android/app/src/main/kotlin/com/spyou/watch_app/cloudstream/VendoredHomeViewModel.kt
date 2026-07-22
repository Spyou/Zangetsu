package com.lagradost.cloudstream3.ui.home

import com.lagradost.cloudstream3.utils.DataStoreHelper

/**
 * Stub of CloudStream's app-module `HomeViewModel`. Some plugins call the
 * companion's `getResumeWatching()` to fold the user's resume feed into their
 * homepage; we return null (no resume feed is exposed to plugins here). Additive
 * — only previously-failing plugins reference it.
 */
class HomeViewModel {
    companion object {
        suspend fun getResumeWatching(): List<DataStoreHelper.ResumeWatchingResult>? = null
    }
}
