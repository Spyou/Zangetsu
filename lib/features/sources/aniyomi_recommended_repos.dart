/// Curated Aniyomi extension repository entries for the "Add Aniyomi repo"
/// dialog.  These are community-maintained repos that may move or be taken
/// down due to DMCA notices — users can always paste a custom URL via the
/// manual input field.  Empty by default: nothing is pre-installed.
const List<({String name, String desc, String url})> kRecommendedAniyomiRepos = [
  (
    name: 'Yuzono Anime',
    desc: 'Community anime extensions — anime, donghua and more',
    // Base URL for the repo; index.min.json is appended by AniyomiRepo.fetchIndex.
    url: 'https://raw.githubusercontent.com/yuzono/anime-repo/repo',
  ),
];
