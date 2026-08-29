/// Search index for settings that live *inside* a sub-page.
///
/// The entry list in `settings_screen.dart` only knows about the ~26 category
/// rows, so "Search settings" could only ever return a folder: typing
/// "autoplay" surfaced **Playback**, not the *Autoplay next episode* toggle,
/// and anything nobody had hand-typed into a `keywords` string (e.g. "anime4k")
/// returned "No settings match" despite being a real setting.
///
/// Each leaf below names one row a sub-page renders. A search result built from
/// it shows the setting's own title with its category underneath, and opens the
/// page that owns it — the parent entry supplies the icon and the tap.
///
/// `settings_search_index_test.dart` reads the sub-page sources and fails if a
/// rendered setting is missing here, so this can't quietly rot as settings are
/// added.
library;

class SettingsLeaf {
  const SettingsLeaf(this.title, this.parent, {this.keywords = ''});

  /// The row's label, spelled exactly as its sub-page renders it.
  final String title;

  /// Title of the top-level entry that opens the page holding this setting.
  final String parent;

  /// Extra terms that never render — synonyms and abbreviations people type
  /// instead of the label ("pip", "op", "subs").
  final String keywords;

  bool matches(String q) =>
      '$title $parent $keywords'.toLowerCase().contains(q);
}

/// Every setting reachable one level below the category rows.
const settingsLeaves = <SettingsLeaf>[
  // Playback → PlaybackSettingsScreen
  SettingsLeaf('Default quality', 'Playback', keywords: 'resolution 1080p 720p'),
  SettingsLeaf('Default audio', 'Playback', keywords: 'sub dub language'),
  SettingsLeaf('Default audio (anime sub/dub)', 'Playback', keywords: 'sub dub'),
  SettingsLeaf('Default speed', 'Playback', keywords: 'playback rate faster'),
  SettingsLeaf('Video decoder', 'Playback', keywords: 'hardware software codec'),
  SettingsLeaf('Video renderer', 'Playback', keywords: 'output gpu vulkan'),
  SettingsLeaf('Anime4K Enhancement', 'Playback', keywords: 'upscale shader glsl'),
  SettingsLeaf('Anime4K GPU tier', 'Playback', keywords: 'upscale shader quality'),
  SettingsLeaf('Default player', 'Playback', keywords: 'external mpv exoplayer vlc'),
  SettingsLeaf('Player controls', 'Playback', keywords: 'buttons reorder hide bar'),
  SettingsLeaf('Resume playback', 'Playback', keywords: 'continue where left off'),
  SettingsLeaf('Ask before jumping', 'Playback', keywords: 'confirm resume'),
  SettingsLeaf('Auto-add to My List', 'Playback', keywords: 'library watchlist'),
  SettingsLeaf('Auto-track', 'Playback', keywords: 'scrobble anilist mal simkl'),
  SettingsLeaf('Close confirmation', 'Playback', keywords: 'exit confirm'),
  SettingsLeaf('Autoplay next episode', 'Playback', keywords: 'auto play continue'),
  SettingsLeaf('Auto-skip filler episodes', 'Playback', keywords: 'filler jikan'),
  SettingsLeaf('Autoplay trailer', 'Playback', keywords: 'auto play preview detail'),
  SettingsLeaf('Play trailers in HD', 'Playback', keywords: 'trailer 1080p quality'),
  SettingsLeaf('Skip intro button', 'Playback', keywords: 'opening op ending ed'),
  SettingsLeaf('Auto-skip opening', 'Playback', keywords: 'op intro'),
  SettingsLeaf('Auto-skip recap', 'Playback', keywords: 'previously on'),
  SettingsLeaf('Auto-skip ending', 'Playback', keywords: 'ed outro credits'),
  SettingsLeaf('MegaSkip button', 'Playback', keywords: 'jump forward'),
  SettingsLeaf('MegaSkip duration', 'Playback', keywords: 'jump forward seconds'),
  SettingsLeaf('Keep screen on', 'Playback', keywords: 'wakelock awake display'),
  SettingsLeaf('Native TV player', 'Playback', keywords: 'exoplayer tv android'),
  SettingsLeaf('Software audio (Dolby/DTS)', 'Playback', keywords: 'passthrough ac3'),
  SettingsLeaf('Seek preview (online)', 'Playback', keywords: 'thumbnails scrub'),
  SettingsLeaf('Auto picture-in-picture', 'Playback', keywords: 'pip floating window'),
  SettingsLeaf('Player info overlay', 'Playback', keywords: 'stats debug hud'),
  SettingsLeaf('Show quality label', 'Playback', keywords: 'resolution badge 1080p'),
  SettingsLeaf('Double-tap skip', 'Playback', keywords: 'seek seconds gesture'),
  SettingsLeaf('Gesture controls', 'Playback', keywords: 'swipe brightness volume'),
  SettingsLeaf('Swipe to seek', 'Playback', keywords: 'drag scrub gesture'),
  SettingsLeaf('Hold for 2× speed', 'Playback', keywords: 'long press fast'),
  SettingsLeaf('Video buffer size', 'Playback', keywords: 'cache memory mb'),
  SettingsLeaf('Video buffer length', 'Playback', keywords: 'cache seconds'),
  SettingsLeaf('Clear image & video cache', 'Playback', keywords: 'storage free space'),
  SettingsLeaf('Styled subtitles (libass)', 'Playback', keywords: 'ass ssa styling'),
  SettingsLeaf('Subtitle style', 'Playback', keywords: 'subs font colour outline size'),
  SettingsLeaf('Subtitle language', 'Playback', keywords: 'subs preferred language'),
  SettingsLeaf('OpenSubtitles API key', 'Playback', keywords: 'subs download account'),
  SettingsLeaf('Auto-download subtitles', 'Playback', keywords: 'subs opensubtitles'),
  SettingsLeaf('Auto-translate subtitles', 'Playback', keywords: 'subs translate google'),
  SettingsLeaf('Translate subtitles to', 'Playback', keywords: 'subs language translate'),

  // Reading → ReaderSettingsScreen
  SettingsLeaf('Reading mode', 'Reader', keywords: 'manga direction webtoon'),
  SettingsLeaf('Fit', 'Reader', keywords: 'width height page scale'),
  SettingsLeaf('Crop borders', 'Reader', keywords: 'trim margins whitespace'),
  SettingsLeaf('Double-page (landscape)', 'Reader', keywords: 'spread facing pages'),
  SettingsLeaf('Preload pages', 'Reader', keywords: 'ahead buffer manga'),
  SettingsLeaf('Tap zones', 'Reader', keywords: 'tapping regions navigation'),
  SettingsLeaf('Orientation lock', 'Reader', keywords: 'rotate portrait landscape'),
  SettingsLeaf('Keep screen on', 'Reader', keywords: 'wakelock awake display'),
  SettingsLeaf('Background', 'Reader', keywords: 'colour theme page'),
  SettingsLeaf('Colour filter', 'Reader', keywords: 'tint warmth night'),
  SettingsLeaf('Theme', 'Reader', keywords: 'novel colour sepia dark'),
  SettingsLeaf('Font', 'Reader', keywords: 'novel typeface family'),
  SettingsLeaf('Font size', 'Reader', keywords: 'novel text bigger smaller'),
  SettingsLeaf('Line height', 'Reader', keywords: 'novel leading spacing'),
  SettingsLeaf('Paragraph spacing', 'Reader', keywords: 'novel gap'),
  SettingsLeaf('Margin', 'Reader', keywords: 'novel padding edge'),
  SettingsLeaf('Justify text', 'Reader', keywords: 'novel align'),
  SettingsLeaf('Text direction', 'Reader', keywords: 'novel rtl ltr'),
  SettingsLeaf('Paginated', 'Reader', keywords: 'novel pages scroll book'),

  // Interface → AppearanceScreen
  SettingsLeaf('Material You', 'Appearance', keywords: 'wallpaper colours dynamic theme'),
  SettingsLeaf('Pure black background', 'Appearance', keywords: 'oled amoled dark'),
  SettingsLeaf('Poster badges', 'Appearance', keywords: 'quality sub dub badge'),
  SettingsLeaf('Animate lists', 'Appearance', keywords: 'fade scroll animation'),
  SettingsLeaf('Animation style', 'Appearance', keywords: 'transition motion'),

  // Advanced → PrivacySettingsScreen
  SettingsLeaf('Incognito mode', 'Privacy', keywords: 'private pause history tracking'),
  SettingsLeaf('Show NSFW sources', 'Privacy', keywords: 'adult 18+ nsfw'),
  SettingsLeaf('Enable NSFW sources', 'Privacy', keywords: 'adult 18+ aniyomi'),

  // Downloads → StorageSettingsScreen
  SettingsLeaf('Clear image cache', 'Storage', keywords: 'free space covers'),
  SettingsLeaf('Clear provider cache', 'Storage', keywords: 'free space js sources'),

  // Downloads → DownloadLocationScreen
  SettingsLeaf('Choose folder…', 'Downloads', keywords: 'location saf path storage'),
  SettingsLeaf('Reset to default', 'Downloads', keywords: 'location folder path'),
];
