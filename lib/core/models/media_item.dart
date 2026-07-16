import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

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

  const MediaItem({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    required this.url,
    required this.type,
    required this.sourceId,
    this.subCount,
    this.dubCount,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
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
    subCount,
    dubCount,
    malId,
    tmdbId,
    tmdbIsTv,
    imdbId,
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
        (m.englishTitle != null && wants.contains(normalizeTitle(m.englishTitle!)))) {
      return m;
    }
  }
  return results.first;
}

/// Lowercase + strip non-alphanumerics, for tolerant title comparison.
String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
