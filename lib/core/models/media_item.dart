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
    required this.url,
    required this.type,
    required this.sourceId,
    this.quality,
    this.dubBadge,
    this.subCount,
    this.dubCount,
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
  }) => MediaItem(
    id: id,
    title: title,
    englishTitle: englishTitle,
    cover: cover,
    coverHeaders: coverHeaders,
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
  );

  @override
  List<Object?> get props => [
    id,
    title,
    englishTitle,
    cover,
    coverHeaders,
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

/// Pick the search result that best matches a tapped relation / work. Prefers a
/// [MediaItem.malId] match (exact + unique), then an exact normalized match on
/// EITHER the English [wanted] or the Romaji [altTitle] against the result's
/// title/englishTitle, else the first result.
///
/// The alt title matters because metadata APIs return English titles while many
/// sources index by Romaji — tapping "Mushoku Tensei: Jobless Reincarnation
/// Season 2 Part 2" must still find the source's "Mushoku Tensei II: Isekai
/// Ittara Honki Dasu Part 2". Returns null only when [results] is empty.
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
  final wants = <String>{
    normalizeTitle(wanted),
    if (altTitle != null && altTitle.isNotEmpty) normalizeTitle(altTitle),
  }..removeWhere((s) => s.isEmpty);
  for (final m in results) {
    if (wants.contains(normalizeTitle(m.title)) ||
        (m.englishTitle != null &&
            wants.contains(normalizeTitle(m.englishTitle!)))) {
      return m;
    }
  }
  return results.first;
}

/// Lowercase + strip non-alphanumerics, for tolerant title comparison.
String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
