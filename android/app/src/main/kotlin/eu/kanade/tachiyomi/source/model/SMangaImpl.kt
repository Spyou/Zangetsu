@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject

class SMangaImpl : SManga {

    override lateinit var url: String

    // Defaulted, NOT lateinit — deliberately different from upstream Mihon.
    //
    // We hand extensions a stub carrying only `url` (MihonBridge's getDetails
    // and getChapters), and an extension's parser is free to READ title before
    // it writes one. Reading an uninitialised lateinit throws, which killed the
    // whole details call with "lateinit property title has not been
    // initialized" and left that manga permanently unopenable.
    //
    // SAnimeImpl in this same tree already defaults title to "", which is why
    // only manga ever hit this. Nothing checks ::title.isInitialized, and
    // MihonJson already treats an unset title as "" — so the lateinit bought
    // nothing but a crash.
    override var title: String = ""

    override var thumbnail_url: String? = null

    override var artist: String? = null

    override var author: String? = null

    override var status: Int = 0

    override var description: String? = null

    override var genre: String? = null

    override var update_strategy: UpdateStrategy = UpdateStrategy.ALWAYS_UPDATE

    override var initialized: Boolean = false

    // Upstream default is `JsonObject.EMPTY`, a `mihon.core.common.extensions` helper this
    // project doesn't vendor (part of Mihon's KMP core-common module, not extensions-lib).
    // An empty JsonObject either way — no ABI difference, `memo` is still `var memo: JsonObject`.
    override var memo: JsonObject = JsonObject(emptyMap())
}
