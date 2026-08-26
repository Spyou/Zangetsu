import 'hls.dart';
import 'subtitle_language.dart';

/// Pure track/subtitle decisions for the TV ExoPlayer player. Device-free and
/// unit-tested. Several functions mirror logic that currently lives inside
/// PlayerCubit; they are duplicated here (not shared) to keep the phone player
/// untouched, and unify in SP1d.

/// One audio, text or video track as reported by the native player.
class TvTrack {
  const TvTrack({
    required this.id,
    required this.language,
    this.label,
    this.selected = false,
    this.height,
  });
  final String id; // "<groupIndex>:<trackIndex>"
  final String language;
  final String? label;
  final bool selected;

  /// Vertical resolution, video renditions only — null for audio and text.
  /// This is the decoded format's own height, so it's measured rather than
  /// whatever a provider claimed the stream was.
  final int? height;
}

/// A side-loaded (source-provided) subtitle handed to the native player.
class TvSubtitleConfig {
  const TvSubtitleConfig({
    required this.url,
    required this.lang,
    this.label,
    required this.mime,
  });
  final String url;
  final String lang;
  final String? label;
  final String mime;

  Map<String, dynamic> toMap() =>
      {'url': url, 'lang': lang, 'label': label, 'mime': mime};
}

enum TvSubAction { off, auto, select, download }

class TvSubDecision {
  const TvSubDecision(this.action, {this.track, this.language});
  final TvSubAction action;
  final TvTrack? track; // for select
  final Language? language; // for download
}

/// Media3 [CaptionStyleCompat] edge-type constants.
const int kTvEdgeNone = 0;
const int kTvEdgeOutline = 1;
const int kTvEdgeDropShadow = 2;
const int kTvEdgeRaised = 3;
const int kTvEdgeDepressed = 4;

/// TV Captions Styling edge picker: (pref id, label, Media3 edge type).
const List<(String, String, int)> kTvCaptionEdgeTypes = [
  ('none', 'None', kTvEdgeNone),
  ('outline', 'Outline', kTvEdgeOutline),
  ('shadow', 'Drop Shadow', kTvEdgeDropShadow),
  ('raised', 'Raised', kTvEdgeRaised),
  ('depressed', 'Depressed', kTvEdgeDepressed),
];

/// Text-colour swatches for TV Captions Styling (#RRGGBBAA → label).
const List<(String, String)> kTvCaptionColors = [
  ('#FFFFFFFF', 'White'),
  ('#FFFF00FF', 'Yellow'),
  ('#00E5FFFF', 'Cyan'),
  ('#7CFC00FF', 'Green'),
  ('#FF6B6BFF', 'Red'),
  ('#000000FF', 'Black'),
];

/// Font size buckets for TV Captions Styling.
const List<(String, double)> kTvCaptionSizes = [
  ('Small', 0.8),
  ('Medium', 1.0),
  ('Large', 1.3),
];

/// Background opacity buckets for TV Captions Styling.
const List<(String, double)> kTvCaptionBackgrounds = [
  ('Off', 0.0),
  ('Light', 0.25),
  ('Medium', 0.5),
  ('Strong', 0.75),
];

/// Vertical position buckets (PlaybackPrefs subtitlePosition 0–100).
const List<(String, int)> kTvCaptionPositions = [
  ('Low', 95),
  ('Middle', 70),
  ('High', 40),
];

/// Maps a [PlaybackPrefs.subtitleOutlineType] id to a Media3 edge type.
/// Phone-only presets (`soft` / `glow` / `bold`) fall back to outline.
int tvEdgeTypeFromOutlinePref(String outlineType) {
  switch (outlineType) {
    case 'none':
      return kTvEdgeNone;
    case 'shadow':
      return kTvEdgeDropShadow;
    case 'raised':
      return kTvEdgeRaised;
    case 'depressed':
      return kTvEdgeDepressed;
    case 'outline':
    case 'soft':
    case 'glow':
    case 'bold':
    default:
      return kTvEdgeOutline;
  }
}

String tvCaptionSizeLabel(double scale) {
  final nearest = kTvCaptionSizes.reduce(
    (a, b) => (a.$2 - scale).abs() <= (b.$2 - scale).abs() ? a : b,
  );
  return nearest.$1;
}

String tvCaptionColorLabel(String colorHex) {
  final want = colorHex.toUpperCase();
  for (final (hex, label) in kTvCaptionColors) {
    if (hex == want) return label;
  }
  return 'Custom';
}

String tvCaptionBgLabel(double opacity) {
  final nearest = kTvCaptionBackgrounds.reduce(
    (a, b) => (a.$2 - opacity).abs() <= (b.$2 - opacity).abs() ? a : b,
  );
  return nearest.$1;
}

String tvCaptionEdgeLabel(String outlineType) {
  final type = tvEdgeTypeFromOutlinePref(outlineType);
  for (final (_, label, t) in kTvCaptionEdgeTypes) {
    if (t == type) return label;
  }
  return 'Outline';
}

String tvCaptionPositionLabel(int position) {
  final nearest = kTvCaptionPositions.reduce(
    (a, b) => (a.$2 - position).abs() <= (b.$2 - position).abs() ? a : b,
  );
  return nearest.$1;
}

String tvCaptionFontLabel(String font) => font.isEmpty ? 'Default' : font;

class TvCaptionStyle {
  const TvCaptionStyle({
    required this.scale,
    required this.fgColor,
    required this.bgColor,
    required this.edge,
    this.fontFamily = '',
    this.edgeType = kTvEdgeOutline,
  });
  final double scale;
  final int fgColor; // ARGB
  final int bgColor; // ARGB

  /// Legacy: true when [edgeType] is not [kTvEdgeNone].
  final bool edge;

  /// Media3 CaptionStyleCompat edge type.
  final int edgeType;
  final String fontFamily;
}

/// mirrors PlayerCubit._episodeUrl; unify in SP1d.
String tvEpisodeUrl(String url, String category) {
  if (category == 'dub' && url.contains('/sub/')) {
    return url.replaceFirst('/sub/', '/dub/');
  }
  if (category == 'sub' && url.contains('/dub/')) {
    return url.replaceFirst('/dub/', '/sub/');
  }
  return url;
}

/// ExoPlayer needs the correct MIME for side-loaded subtitles or they don't
/// parse. Prefer the provider's [format], else sniff the [url] extension.
String subtitleMime(String? format, {String url = ''}) {
  final f = (format ?? '').toLowerCase();
  final u = url.toLowerCase();
  if (f == 'vtt' || f == 'webvtt' || u.contains('.vtt')) return 'text/vtt';
  if (f == 'ass' || f == 'ssa' || u.contains('.ass') || u.contains('.ssa')) {
    return 'text/x-ssa';
  }
  if (f == 'ttml' || f == 'dfxp' || u.contains('.ttml')) {
    return 'application/ttml+xml';
  }
  return 'application/x-subrip';
}

int qualityHeight(String quality) {
  final s = quality.toLowerCase();
  if (s.contains('2160') || s.contains('4k')) return 2160;
  if (s.contains('4320') || s.contains('8k')) return 4320;
  final m = RegExp(r'(\d{3,4})').firstMatch(s);
  return m != null ? int.parse(m.group(1)!) : 0;
}

/// mirrors PlayerCubit._applyDefaultQuality (HLS branch); unify in SP1d.
/// [variants] must be sorted high→low (as fetchHlsVariants returns).
HlsVariant? decideDefaultQuality({
  required List<HlsVariant> variants,
  required String pref,
}) {
  if (variants.isEmpty) return null;
  if (pref.isEmpty || pref == 'auto') return null;
  if (pref == 'highest') return variants.first;
  final want = qualityHeight(pref);
  if (want <= 0) return null;
  for (final v in variants) {
    if (qualityHeight(v.quality) == want) return v;
  }
  final atOrAbove =
      variants.where((v) => qualityHeight(v.quality) >= want).toList();
  if (atOrAbove.isNotEmpty) return atOrAbove.last; // smallest >= want
  return variants.first; // all below want → highest available
}

/// Preferred-subtitle decision over the current text tracks (source subs are
/// side-loaded and appear here too). mirrors PlayerCubit._tryApplySubPref.
TvSubDecision decideSubtitle({
  required List<TvTrack> textTracks,
  required String pref,
}) {
  if (pref == 'off') return const TvSubDecision(TvSubAction.off);
  if (pref.isEmpty) return const TvSubDecision(TvSubAction.auto);
  final lang = languageByPref(pref);
  if (lang == null) return const TvSubDecision(TvSubAction.auto);
  for (final t in textTracks) {
    if (matchesSourceLang(t.language, lang) ||
        (t.label != null && matchesSourceLang(t.label!, lang))) {
      return TvSubDecision(TvSubAction.select, track: t);
    }
  }
  return TvSubDecision(TvSubAction.download, language: lang);
}

/// Maps a subtitle-font family to its `.ttf` filename under `sub_fonts/`
/// (and under `assets/fonts/` for APK-bundled families).
String? subtitleFontFileName(String family) {
  const map = {
    'Inter': 'Inter.ttf',
    'Poppins': 'Poppins-Regular.ttf',
    'Roboto': 'Roboto-Regular.ttf',
    'Open Sans': 'OpenSans-Regular.ttf',
    'Lato': 'Lato-Regular.ttf',
    'Montserrat': 'Montserrat-Regular.ttf',
    'Nunito': 'Nunito-Regular.ttf',
    'Rubik': 'Rubik-Regular.ttf',
    'Noto Sans': 'NotoSans-Regular.ttf',
    'Source Sans 3': 'SourceSans3-Regular.ttf',
  };
  return map[family];
}

/// Asset path for fonts that ship in the APK (see pubspec `flutter: fonts:`).
/// Download-on-demand families return null — stage them from `sub_fonts/` after
/// [SubtitleFontService.ensure].
String? subtitleFontAsset(String family) {
  switch (family) {
    case 'Inter':
      return 'assets/fonts/Inter.ttf';
    case 'Noto Sans':
      return 'assets/fonts/NotoSans-Regular.ttf';
    default:
      return null;
  }
}

/// PlaybackPrefs stores the subtitle colour as `#RRGGBBAA` (default
/// `#FFFFFFFF`). Convert to an Android ARGB int; garbage → opaque white.
int parseSubtitleColor(String hex) {
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = '${h}FF';
  if (h.length != 8 || int.tryParse(h, radix: 16) == null) return 0xFFFFFFFF;
  final rgb = h.substring(0, 6);
  final a = h.substring(6, 8);
  return int.parse('$a$rgb', radix: 16);
}

TvCaptionStyle captionStyleFromPrefs({
  required double scale,
  required String colorHex,
  required double bgOpacity,
  required String font,
  String? outlineType,
}) {
  final o = bgOpacity.clamp(0.0, 1.0);
  final bgA = (o * 255).round();
  // Explicit outline pref wins; otherwise keep the legacy heuristic (outline
  // when there's no background box so text stays readable on busy scenes).
  final edgeType = outlineType != null
      ? tvEdgeTypeFromOutlinePref(outlineType)
      : (o <= 0.0 ? kTvEdgeOutline : kTvEdgeNone);
  return TvCaptionStyle(
    scale: scale,
    fgColor: parseSubtitleColor(colorHex),
    bgColor: bgA << 24, // alpha-black window box
    edge: edgeType != kTvEdgeNone,
    edgeType: edgeType,
    fontFamily: font,
  );
}
