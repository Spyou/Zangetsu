package com.lagradost.cloudstream3.ui

/**
 * Clean-room stub of CloudStream's [SyncWatchType] (app module, not in the bundled
 * `:library`). Matches the real enum's arity (internalId, stringRes, iconRes) and
 * constants; the two res-id args are dummied to 0 (plugins only read `stringRes`,
 * never resolve it). Referenced by SyncAPI.AbstractSyncStatus and by plugins.
 */
enum class SyncWatchType(val internalId: Int, val stringRes: Int, val iconRes: Int) {
    NONE(-1, 0, 0),
    WATCHING(0, 0, 0),
    COMPLETED(1, 0, 0),
    ONHOLD(2, 0, 0),
    DROPPED(3, 0, 0),
    PLANTOWATCH(4, 0, 0),
    REWATCHING(5, 0, 0);

    companion object {
        fun fromInternalId(id: Int?) = entries.find { it.internalId == id } ?: NONE
    }
}
