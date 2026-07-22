package com.lagradost.cloudstream3.ui.library

/**
 * Clean-room stub of CloudStream's [ListSorting] (app module, not in the bundled
 * `:library`). Referenced only as the type of `SyncAPI.LibraryMetadata.supportedListSorting`
 * (which our stubs return empty), so the constant set just needs to exist.
 */
enum class ListSorting {
    Query,
    RatingHigh,
    RatingLow,
    UpdatedNew,
    UpdatedOld,
    AlphabeticalA,
    AlphabeticalZ,
    ReleaseDateNew,
    ReleaseDateOld,
}
