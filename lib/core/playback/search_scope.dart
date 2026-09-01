/// Which index a search runs against.
///
/// This is a SCOPE, not a mode: it changes what the Search screen queries and
/// nothing else. It never touches the active source or what fills Home.
enum SearchScope {
  /// The metadata catalogue (AniList / TMDB). Results are `zm://` items.
  library,

  /// The user's installed sources — the app's original search.
  sources,
}
