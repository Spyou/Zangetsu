import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'episode.g.dart';

/// A scanlation group name fit to show, or null when there isn't really one.
///
/// Sources don't reliably use an empty string for "no group": one Mihon source
/// sets the field to a single ZERO WIDTH SPACE (U+200B). Dart's `trim()` won't
/// touch it — Unicode doesn't call it whitespace — so it survives as a
/// non-empty name and renders as an invisible chip and a stray leading `·` on
/// every chapter row. Strip the invisible characters first, then decide.
///
/// Use this for DISPLAY only. `episodeFromSChapter` folds the RAW value into
/// the chapter id to keep two groups' releases apart, and normalising there
/// would rewrite existing ids and lose people's read progress.
String? scanlatorLabel(String? raw) {
  if (raw == null) return null;
  // Zero-width space/non-joiner/joiner, BOM, and the LTR/RTL marks — all
  // invisible, all things sources leave lying around in a "blank" field.
  final cleaned = raw.replaceAll(RegExp(r'[\u200B-\u200F\uFEFF]'), '').trim();
  return cleaned.isEmpty ? null : cleaned;
}

/// One episode within a series. The video-native analogue of Sozo Read's
/// `Chapter` — same wire keys (`id/title/number/url/date`) plus two video
/// extras.
@JsonSerializable()
class Episode extends Equatable {
  final String id;
  final String title;
  final double? number;
  final String url;
  final String? date;
  final String? thumbnail;

  @JsonKey(defaultValue: false)
  final bool filler;

  /// Season number when the source reports one per episode (CloudStream does).
  /// Null for sources that don't — season is then derived from the title
  /// prefix. Not serialized: the detail screen always fetches episodes fresh,
  /// so this never needs to survive a JSON round-trip.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final int? season;

  /// Per-episode synopsis (AniZip/TMDB); null when unknown. Not serialized —
  /// episodes are always fetched fresh, like [season].
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? description;

  /// Real episode title from AniZip/TMDB, shown when the source only gives a
  /// generic "Episode N". Not serialized.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? metaTitle;

  /// Which scanlation group released this chapter (manga; a couple of novel
  /// sources too). Null for anime and for sources that don't say.
  ///
  /// Several groups routinely release the SAME chapter number, which is why a
  /// chapter list can show 1, 1, 2, 2 — they're genuinely different chapters,
  /// not duplicates. The group was already folded into [id] to keep their read
  /// progress apart; this is the same value kept as a display field so the row
  /// can name it and the list can filter by it. Not serialized, like [season].
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? scanlator;

  /// Per-episode rating (0–10, AniZip/TMDB) and runtime in minutes. Not
  /// serialized — filled fresh on each detail load, like [description].
  @JsonKey(includeFromJson: false, includeToJson: false)
  final double? rating;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final int? runtimeMinutes;

  /// A short, already-worded reason this can't be played yet — "Airs 12 Sep",
  /// "Not out yet", "Not on HiAnime" — or null when there's nothing to say.
  ///
  /// One string rather than a flag plus a cause, because only the catalogue
  /// layer can tell those cases apart and the UI has nothing to add. The
  /// wording is deliberately precise about WHAT WE CHECKED: when the tracker
  /// knows the episode hasn't aired we say so, and otherwise we name the one
  /// source we asked rather than claiming that nothing anywhere has it —
  /// [MetadataRepository.detail] only ever asks the matched source. Finding
  /// out about the rest is the 23-second sweep this avoids; the viewer can
  /// still ask for it from the row.
  ///
  /// Not serialized, like [season]: episode lists are always fetched fresh.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? unavailable;

  /// False only when something concrete is known to be in the way. True
  /// whenever we don't know, which includes every source-supplied list and
  /// every title with no source matched yet.
  bool get available => unavailable == null;

  const Episode({
    required this.id,
    required this.title,
    this.number,
    required this.url,
    this.date,
    this.thumbnail,
    this.filler = false,
    this.season,
    this.scanlator,
    this.description,
    this.metaTitle,
    this.rating,
    this.runtimeMinutes,
    this.unavailable,
  });

  factory Episode.fromJson(Map<String, dynamic> json) =>
      _$EpisodeFromJson(json);
  Map<String, dynamic> toJson() => _$EpisodeToJson(this);

  Episode copyWith({
    String? description,
    String? metaTitle,
    String? thumbnail,
    String? date,
    double? rating,
    int? runtimeMinutes,
    String? unavailable,
  }) => Episode(
        id: id,
        title: title,
        number: number,
        url: url,
        date: date ?? this.date,
        thumbnail: thumbnail ?? this.thumbnail,
        filler: filler,
        season: season,
        scanlator: scanlator,
        description: description ?? this.description,
        metaTitle: metaTitle ?? this.metaTitle,
        rating: rating ?? this.rating,
        runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
        unavailable: unavailable ?? this.unavailable,
      );

  @override
  List<Object?> get props => [
        id,
        title,
        number,
        url,
        date,
        thumbnail,
        filler,
        season,
        scanlator,
        description,
        metaTitle,
        rating,
        runtimeMinutes,
        unavailable,
      ];
}
