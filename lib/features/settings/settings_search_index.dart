/// Search index for settings that live *inside* a sub-page.
///
/// The entry list in `settings_screen.dart` only knows about the ~26 category
/// rows, so "Search settings" could only ever return a folder: typing
/// "autoplay" surfaced **Playback**, not the *Autoplay next episode* toggle,
/// and anything nobody had hand-typed into a `keywords` string (e.g. "anime4k")
/// returned "No settings match" despite being a real setting.
///
/// Each leaf names one row a sub-page renders. A search result built from it
/// shows the setting's own title with its category underneath, and opens the
/// page that owns it — [parentId] points at the category row supplying the icon
/// and the tap.
///
/// **Titles are read through [AppLocalizations], not stored as text**, so the
/// results are in the reader's language and a search in that language matches.
/// Referencing the getter also means a renamed ARB key fails to compile rather
/// than silently dropping a setting out of search.
///
/// `settings_search_index_test.dart` reads the sub-page sources and fails when
/// a rendered setting isn't indexed, so this can't quietly rot.
library;

import '../../l10n/app_localizations.dart';

/// Category rows that own a sub-page with searchable settings inside.
abstract final class LeafParent {
  static const playback = 'playback';
  static const reader = 'reader';
  static const appearance = 'appearance';
  static const privacy = 'privacy';
  static const storage = 'storage';
  static const downloads = 'downloads';
}

class SettingsLeaf {
  const SettingsLeaf(this.parentId, this.title, {this.keywords = ''});

  /// Which category row opens the page holding this setting.
  final String parentId;

  /// The row's label, read from the active translations.
  final String Function(AppLocalizations) title;

  /// Extra terms that never render — synonyms and abbreviations people type
  /// instead of the label ("pip", "op", "subs"). English only: they widen an
  /// English search, while the localized [title] carries every other language.
  final String keywords;

  bool matches(String q, AppLocalizations l10n) =>
      '${title(l10n)} $keywords'.toLowerCase().contains(q);
}

/// Every setting reachable one level below the category rows.
final settingsLeaves = <SettingsLeaf>[
  // Playback → PlaybackSettingsScreen
  SettingsLeaf(LeafParent.playback, (l) => l.defaultQuality, keywords: 'resolution 1080p 720p'),
  SettingsLeaf(LeafParent.playback, (l) => l.defaultAudio, keywords: 'sub dub language'),
  SettingsLeaf(LeafParent.playback, (l) => l.defaultAudioAnimeSubDub, keywords: 'sub dub'),
  SettingsLeaf(LeafParent.playback, (l) => l.defaultSpeed, keywords: 'playback rate faster'),
  SettingsLeaf(LeafParent.playback, (l) => l.videoDecoder, keywords: 'hardware software codec'),
  SettingsLeaf(LeafParent.playback, (l) => l.videoRenderer, keywords: 'output gpu vulkan'),
  SettingsLeaf(LeafParent.playback, (l) => l.anime4kEnhancement, keywords: 'upscale shader glsl anime4k'),
  SettingsLeaf(LeafParent.playback, (l) => l.anime4kGPUTier, keywords: 'upscale shader quality anime4k'),
  SettingsLeaf(LeafParent.playback, (l) => l.defaultPlayer, keywords: 'external mpv exoplayer vlc'),
  SettingsLeaf(LeafParent.playback, (l) => l.playerControls, keywords: 'buttons reorder hide bar'),
  SettingsLeaf(LeafParent.playback, (l) => l.resumePlayback, keywords: 'continue where left off'),
  SettingsLeaf(LeafParent.playback, (l) => l.askBeforeJumping, keywords: 'confirm resume'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoAddToMyList, keywords: 'library watchlist'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoTrack, keywords: 'scrobble anilist mal simkl'),
  SettingsLeaf(LeafParent.playback, (l) => l.closeConfirmation, keywords: 'exit confirm'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoplayNextEpisode, keywords: 'auto play continue'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoSkipFillerEpisodes, keywords: 'filler jikan'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoplayTrailer, keywords: 'auto play preview detail'),
  SettingsLeaf(LeafParent.playback, (l) => l.playTrailersInHD, keywords: 'trailer 1080p quality'),
  SettingsLeaf(LeafParent.playback, (l) => l.skipIntroButton, keywords: 'opening op ending ed'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoSkipOpening, keywords: 'op intro'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoSkipRecap, keywords: 'previously on'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoSkipEnding, keywords: 'ed outro credits'),
  SettingsLeaf(LeafParent.playback, (l) => l.megaskipButton, keywords: 'jump forward megaskip'),
  SettingsLeaf(LeafParent.playback, (l) => l.megaSkipDuration, keywords: 'jump forward seconds megaskip'),
  SettingsLeaf(LeafParent.playback, (l) => l.keepScreenOn, keywords: 'wakelock awake display'),
  SettingsLeaf(LeafParent.playback, (l) => l.nativeTVPlayer, keywords: 'exoplayer tv android'),
  SettingsLeaf(LeafParent.playback, (l) => l.softwareAudioDolbyDTS, keywords: 'passthrough ac3 dolby dts'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoPictureInPicture, keywords: 'pip floating window'),
  SettingsLeaf(LeafParent.playback, (l) => l.playerInfoOverlay, keywords: 'stats debug hud'),
  SettingsLeaf(LeafParent.playback, (l) => l.showQualityLabel, keywords: 'resolution badge 1080p'),
  SettingsLeaf(LeafParent.playback, (l) => l.doubleTapSkip, keywords: 'seek seconds gesture'),
  SettingsLeaf(LeafParent.playback, (l) => l.gestureControls, keywords: 'swipe brightness volume'),
  SettingsLeaf(LeafParent.playback, (l) => l.swipeToSeek, keywords: 'drag scrub gesture'),
  SettingsLeaf(LeafParent.playback, (l) => l.holdFor2Speed, keywords: 'long press fast 2x'),
  SettingsLeaf(LeafParent.playback, (l) => l.videoBufferSize, keywords: 'cache memory mb'),
  SettingsLeaf(LeafParent.playback, (l) => l.videoBufferLength, keywords: 'cache seconds'),
  SettingsLeaf(LeafParent.playback, (l) => l.clearImageVideoCache, keywords: 'storage free space'),
  SettingsLeaf(LeafParent.playback, (l) => l.styledSubtitlesLibass, keywords: 'ass ssa styling subs libass'),
  SettingsLeaf(LeafParent.playback, (l) => l.subtitleStyle, keywords: 'subs font colour outline size'),
  SettingsLeaf(LeafParent.playback, (l) => l.subtitleLanguage, keywords: 'subs preferred language'),
  SettingsLeaf(LeafParent.playback, (l) => l.opensubtitlesAPIKey, keywords: 'subs download account opensubtitles'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoDownloadSubtitles, keywords: 'subs opensubtitles'),
  SettingsLeaf(LeafParent.playback, (l) => l.autoTranslateSubtitles, keywords: 'subs translate google'),
  SettingsLeaf(LeafParent.playback, (l) => l.translateSubtitlesTo, keywords: 'subs language translate'),

  // Reading → ReaderSettingsScreen
  SettingsLeaf(LeafParent.reader, (l) => l.readingMode, keywords: 'manga direction webtoon'),
  SettingsLeaf(LeafParent.reader, (l) => l.fit, keywords: 'width height page scale'),
  SettingsLeaf(LeafParent.reader, (l) => l.cropBorders, keywords: 'trim margins whitespace'),
  SettingsLeaf(LeafParent.reader, (l) => l.doublePageLandscape, keywords: 'spread facing pages'),
  SettingsLeaf(LeafParent.reader, (l) => l.preloadPages, keywords: 'ahead buffer manga'),
  SettingsLeaf(LeafParent.reader, (l) => l.tapZones, keywords: 'tapping regions navigation'),
  SettingsLeaf(LeafParent.reader, (l) => l.orientationLock, keywords: 'rotate portrait landscape'),
  SettingsLeaf(LeafParent.reader, (l) => l.keepScreenOn, keywords: 'wakelock awake display'),
  SettingsLeaf(LeafParent.reader, (l) => l.background, keywords: 'colour theme page'),
  SettingsLeaf(LeafParent.reader, (l) => l.colourFilter, keywords: 'tint warmth night'),
  SettingsLeaf(LeafParent.reader, (l) => l.theme, keywords: 'novel colour sepia dark'),
  SettingsLeaf(LeafParent.reader, (l) => l.font, keywords: 'novel typeface family'),
  SettingsLeaf(LeafParent.reader, (l) => l.fontSize, keywords: 'novel text bigger smaller'),
  SettingsLeaf(LeafParent.reader, (l) => l.lineHeight, keywords: 'novel leading spacing'),
  SettingsLeaf(LeafParent.reader, (l) => l.paragraphSpacing, keywords: 'novel gap'),
  SettingsLeaf(LeafParent.reader, (l) => l.margin, keywords: 'novel padding edge'),
  SettingsLeaf(LeafParent.reader, (l) => l.justifyText, keywords: 'novel align'),
  SettingsLeaf(LeafParent.reader, (l) => l.textDirection, keywords: 'novel rtl ltr'),
  SettingsLeaf(LeafParent.reader, (l) => l.paginated, keywords: 'novel pages scroll book'),

  // Interface → AppearanceScreen
  SettingsLeaf(LeafParent.appearance, (l) => l.materialYou, keywords: 'wallpaper colours dynamic theme'),
  SettingsLeaf(LeafParent.appearance, (l) => l.pureBlackBackground, keywords: 'oled amoled dark'),
  SettingsLeaf(LeafParent.appearance, (l) => l.posterBadges, keywords: 'quality sub dub badge'),
  SettingsLeaf(LeafParent.appearance, (l) => l.animateLists, keywords: 'fade scroll animation'),
  SettingsLeaf(LeafParent.appearance, (l) => l.animationStyle, keywords: 'transition motion'),

  // Advanced → PrivacySettingsScreen
  SettingsLeaf(LeafParent.privacy, (l) => l.incognitoMode, keywords: 'private pause history tracking'),
  SettingsLeaf(LeafParent.privacy, (l) => l.showNSFWSources, keywords: 'adult 18+ nsfw'),
  SettingsLeaf(LeafParent.privacy, (l) => l.enableNSFWSources2, keywords: 'adult 18+ nsfw aniyomi'),

  // Downloads → StorageSettingsScreen
  SettingsLeaf(LeafParent.storage, (l) => l.clearImageCache, keywords: 'free space covers'),
  SettingsLeaf(LeafParent.storage, (l) => l.clearProviderCache, keywords: 'free space js sources'),

  // Downloads → DownloadLocationScreen
  SettingsLeaf(LeafParent.downloads, (l) => l.chooseFolder, keywords: 'location saf path storage'),
  SettingsLeaf(LeafParent.downloads, (l) => l.resetToDefault, keywords: 'location folder path'),
];
