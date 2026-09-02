import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'media_detail.dart';
import 'provider_info.dart';

part 'media_item.g.dart';

/// One row in a search / browse listing. The video-native analogue of
/// Sozo Read's `BookItem`.
@JsonSerializable()
class MediaItem extends Equatable {
  final String id;
  final String title;

  /// Optional romanized / English alternative title. Null when the source
  /// doesn't provide one; UI falls back to [title].
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;

  /// Wide 16:9 art (AniList `bannerImage` / TMDB `backdrop_path`), for the
  /// home hero. Null outside Z Mode — every existing source keeps rendering
  /// its hero from [cover], exactly as before this field existed.
  final String? banner;
  final String url;
  final ProviderType type;
  final String sourceId;
  /// Release quality the source claims for this title — "4K", "HD", "CAM"…
  /// Shown as a poster badge. CloudStream is the only ecosystem that reports
  /// one, and plenty of its providers leave it unset, so null is the norm.
  ///
  /// Deliberately not serialized: it's a browse-time hint, not something My
  /// List needs to remember, and keeping it out means the stored shape (and
  /// the generated (de)serializer) is untouched.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? quality;

  /// "SUB", "DUB" or "SUB DUB" — what an anime listing offers, for the poster
  /// badge. CloudStream anime sources only; null everywhere else, which is the
  /// normal case rather than a failure.
  final String? dubBadge;

  final int? subCount;
  final int? dubCount;

  /// MyAnimeList id, when the source exposes it (anime). Carried so tracker
  /// sync (AniList) can match this title without re-fetching the detail.
  final int? malId;

  /// TMDB id (movies/series) for Simkl tracking; [tmdbIsTv] selects namespace.
  final int? tmdbId;
  final bool tmdbIsTv;

  /// IMDb id (e.g. `tt1234567`) for Simkl tracking when no TMDB id is exposed.
  final String? imdbId;

  /// Which metadata catalogue this title came from, stamped when it is saved.
  ///
  /// A saved title keeps the provider that gave it to you: change your
  /// Settings pick later and your list still opens each entry where it came
  /// from. It cannot be inferred afterwards — AniList and MAL both key on
  /// `mal:`, TMDB and Simkl both on `tmdb:` — so it is recorded at save time.
  /// Null on anything saved before this existed, and on source titles, which
  /// carry their real source in [sourceId] already.
  final String? savedFrom;

  /// When this was saved, in millis since epoch. Stamped alongside
  /// [savedFrom].
  ///
  /// "Recently added" used to trust the order the Hive box iterated in, which
  /// is not a record of anything: a cloud restore repopulates the box in
  /// whatever order the rows come back, and deletions perturb what is left.
  /// Null on entries saved before this existed — those keep store order,
  /// after everything that does have a date.
  final int? savedAtMs;

  /// Genres, when the source provides them on the search/browse item itself
  /// (Mihon/Aniyomi carry these; most sources don't and this stays empty).
  /// Drives the search screen's genre filter — see [MediaDetail.genres] for
  /// the on-demand detail equivalent.
  final List<String> genres;

  /// Publication status, when the source provides it on the search/browse item
  /// itself (Mihon/Aniyomi carry it — same `status` field already parsed for
  /// [MediaDetail.status], now also carried on the list item). Null — NOT
  /// [MediaStatus.unknown] — means "this source didn't say", so an explicitly
  /// reported "unknown" status and "no data at all" stay distinguishable;
  /// see [mediaItemFromSManga]/[mediaItemFromSAnime] for the mapping. Drives
  /// the search screen's Status filter, which self-hides when nothing in the
  /// current results carries one.
  final MediaStatus? status;

  const MediaItem({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    this.banner,
    required this.url,
    required this.type,
    required this.sourceId,
    this.quality,
    this.dubBadge,
    this.subCount,
    this.dubCount,
    this.savedFrom,
    this.savedAtMs,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.genres = const [],
    this.status,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) =>
      _$MediaItemFromJson(json);
  Map<String, dynamic> toJson() => _$MediaItemToJson(this);

  MediaItem copyWith({
    String? sourceId,
    int? subCount,
    int? dubCount,
    int? malId,
    int? tmdbId,
    String? imdbId,
    String? savedFrom,
    int? savedAtMs,
  }) => MediaItem(
    id: id,
    title: title,
    englishTitle: englishTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    banner: banner,
    url: url,
    type: type,
    sourceId: sourceId ?? this.sourceId,
    quality: quality,
    dubBadge: dubBadge,
    subCount: subCount ?? this.subCount,
    dubCount: dubCount ?? this.dubCount,
    malId: malId ?? this.malId,
    tmdbId: tmdbId ?? this.tmdbId,
    tmdbIsTv: tmdbIsTv,
    imdbId: imdbId ?? this.imdbId,
    savedFrom: savedFrom ?? this.savedFrom,
    savedAtMs: savedAtMs ?? this.savedAtMs,
  );

  @override
  List<Object?> get props => [
    savedFrom,
    id,
    title,
    englishTitle,
    cover,
    coverHeaders,
    banner,
    url,
    type,
    sourceId,
    quality,
    subCount,
    dubCount,
    malId,
    tmdbId,
    tmdbIsTv,
    imdbId,
    genres,
    status,
  ];
}

/// Decorations source catalogues routinely bolt onto a title — a year,
/// season/part/episode markers, "Watch ... Online" wrapper words, quality or
/// audio tags — that carry no identifying information. [titleMatches] strips
/// these from both sides before comparing, so "Reacher" matches "Reacher
/// (2022)" / "Reacher Season 1" / "Watch Reacher Online" without loosening
/// the check itself: it's still whole-string equality afterwards, never
/// containment, so "The Reluctant Preacher" (no decorations to strip) still
/// misses "Reacher".
final RegExp _titleDecorations = RegExp(
  r'\b(?:'
  r'(?:19|20)\d{2}' // year: 2022, 2026...
  r'|s\d{1,2}(?:e\d{1,3})?' // s01, s01e02
  r'|season\s*\d+|part\s*\d+|episode\s*\d+'
  r'|watch|online|full\s*movie|free'
  r'|dual\s*audio|multi\s*audio'
  r'|\d{3,4}p|4k|hd|cam|hdrip|webrip|bluray'
  r')\b',
  caseSensitive: false,
);

String _stripTitleDecorations(String s) => s.replaceAll(_titleDecorations, ' ');

/// Whether [m] is the title being looked for: same MAL id, or a normalized
/// title (or English title) equal to [wanted] or [altTitle] once decorations
/// (see [_stripTitleDecorations]) are stripped from both sides. This is the
/// acceptance rule [bestTitleMatch] ranks by, exposed so callers that must
/// reject its fallback-to-first-result can apply the same test.
bool titleMatches(
  MediaItem m,
  String wanted, {
  String? altTitle,
  int? wantedMalId,
}) {
  if (wantedMalId != null && m.malId != null && m.malId == wantedMalId) {
    return true;
  }
  final wants = <String>{
    normalizeTitle(_stripTitleDecorations(wanted)),
    if (altTitle != null && altTitle.isNotEmpty)
      normalizeTitle(_stripTitleDecorations(altTitle)),
  }..removeWhere((s) => s.isEmpty);
  final title = normalizeTitle(_stripTitleDecorations(m.title));
  final english = m.englishTitle == null
      ? null
      : normalizeTitle(_stripTitleDecorations(m.englishTitle!));
  return wants.contains(title) || (english != null && wants.contains(english));
}

/// Pick the search result that best matches a tapped relation / work. Prefers a
/// [MediaItem.malId] match (exact + unique), then an exact normalized match on
/// EITHER the English [wanted] or the Romaji [altTitle] against the result's
/// title/englishTitle, else the first result.
///
/// The alt title matters because metadata APIs return English titles while many
/// sources index by Romaji — tapping "Mushoku Tensei: Jobless Reincarnation
/// Season 2 Part 2" must still find the source's "Mushoku Tensei II: Isekai
/// Ittara Honki Dasu Part 2". Returns null only when [results] is empty.
///
/// The malId pass and the title pass stay separate (rather than one loop
/// calling [titleMatches] once per item) so a malId match anywhere in
/// [results] still wins over a title match on an earlier item.
MediaItem? bestTitleMatch(
  List<MediaItem> results,
  String wanted, {
  String? altTitle,
  int? wantedMalId,
}) {
  if (results.isEmpty) return null;
  if (wantedMalId != null) {
    for (final m in results) {
      if (m.malId != null && m.malId == wantedMalId) return m;
    }
  }
  for (final m in results) {
    if (titleMatches(m, wanted, altTitle: altTitle)) return m;
  }
  return results.first;
}

/// Accented letters folded to their plain form. Stripping non-alphanumerics
/// DELETES an accent rather than folding it, so "Pokémon" became `pokmon` and
/// could never equal a source's "Pokemon" (`pokemon`) — the same title, never
/// matching. Only the Latin-1 range that actually shows up in titles.
const Map<String, String> _foldedLetters = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Lowercase + strip non-alphanumerics, for tolerant title comparison.
///
/// Two things happen before the strip, both for the same reason: the strip
/// DELETES what it doesn't understand, which silently turns a title into
/// something that can never equal the same title written slightly differently.
///
///  - `&` is spelled out, because sources write it both ways ("Above & Below"
///    vs "Above and Below"); dropping it gives `abovebelow` vs `aboveandbelow`.
///  - Accents are folded (see [_foldedLetters]); dropping them gives `pokmon`.
String normalizeTitle(String s) {
  var out = s.toLowerCase().replaceAll(RegExp(r'[&＆﹠]'), 'and');
  _foldedLetters.forEach((accented, plain) {
    if (out.contains(accented)) out = out.replaceAll(accented, plain);
  });
  return out.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
