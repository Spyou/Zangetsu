import 'hls.dart';
import 'subtitle_language.dart';

/// Pure track/subtitle decisions for the TV ExoPlayer player. Device-free and
/// unit-tested. Several functions mirror logic that currently lives inside
/// PlayerCubit; they are duplicated here (not shared) to keep the phone player
/// untouched, and unify in SP1d.

/// One audio or text track as reported by the native player.
class TvTrack {
  const TvTrack({
    required this.id,
    required this.language,
    this.label,
    this.selected = false,
  });
  final String id; // "<groupIndex>:<trackIndex>"
  final String language;
  final String? label;
  final bool selected;
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

class TvCaptionStyle {
  const TvCaptionStyle({
    required this.scale,
    required this.fgColor,
    required this.bgColor,
    required this.edge,
    required this.position,
    this.fontFamily = '',
  });
  final double scale;
  final int fgColor; // ARGB
  final int bgColor; // ARGB
  final bool edge;
  final double position; // bottom-padding fraction 0..1
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

/// Maps a bundled subtitle-font family to its asset path (see pubspec fonts).
String? subtitleFontAsset(String family) {
  const map = {
    'Inter': 'assets/fonts/Inter.ttf',
    'Poppins': 'assets/fonts/Poppins-Regular.ttf',
    'Roboto': 'assets/fonts/Roboto-Regular.ttf',
    'Open Sans': 'assets/fonts/OpenSans-Regular.ttf',
    'Lato': 'assets/fonts/Lato-Regular.ttf',
    'Montserrat': 'assets/fonts/Montserrat-Regular.ttf',
    'Nunito': 'assets/fonts/Nunito-Regular.ttf',
    'Rubik': 'assets/fonts/Rubik-Regular.ttf',
    'Noto Sans': 'assets/fonts/NotoSans-Regular.ttf',
    'Source Sans 3': 'assets/fonts/SourceSans3-Regular.ttf',
  };
  return map[family];
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
  required int position,
  required String font,
}) {
  final o = bgOpacity.clamp(0.0, 1.0);
  final bgA = (o * 255).round();
  return TvCaptionStyle(
    scale: scale,
    fgColor: parseSubtitleColor(colorHex),
    bgColor: bgA << 24, // alpha-black window box
    edge: o <= 0.0, // outline for readability when there's no box
    position: ((100 - position).clamp(0, 100)) / 100.0,
    fontFamily: font,
  );
}
