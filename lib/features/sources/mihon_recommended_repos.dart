/// Curated Mihon extension repository entries for the "Add Mihon repo"
/// dialog.  These are community-maintained repos that may move or be taken
/// down due to DMCA notices — users can always paste a custom URL via the
/// manual input field.  Empty by default: nothing is pre-installed.
const List<({String name, String desc, String url})> kRecommendedMihonRepos = [
  (
    name: 'Keiyoushi',
    desc: 'The main community manga repo — 1,300+ sources across many languages',
    // Base URL for the repo; index.json is appended by MihonRepo.fetchIndex.
    url: 'https://raw.githubusercontent.com/keiyoushi/extensions/repo',
  ),
];
