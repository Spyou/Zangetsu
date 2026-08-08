@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject

class SMangaImpl : SManga {

    override lateinit var url: String

    override lateinit var title: String

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
