/// Curated Zangetsu (JS-provider) repo entries for the "Add repo" dialog —
/// mirrors [kRecommendedAniyomiRepos] (aniyomi_recommended_repos.dart) for
/// the JS-provider ecosystem. Nothing here is pre-installed or added on
/// launch; it's a suggestion inside the add-repo dialog only. Tapping an
/// entry fills in the URL field — the user still presses "Add" themselves,
/// same as pasting a URL by hand.
///
/// Empty by design right now. The Sozo Read manga/novel pack used to be
/// suggested here, but those sources are search-only — no popular/latest — so
/// picking one left Home with nothing to render. Manga is served by Mihon
/// extensions instead; novel support is planned as its own extension path.
/// Users can still paste any repo URL by hand; only the suggestion is gone.
const List<({String name, String desc, String url})>
kRecommendedZangetsuRepos = [];
