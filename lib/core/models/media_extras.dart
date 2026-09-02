import 'package:equatable/equatable.dart';

import 'person.dart';

/// One cast/crew entry shown in the Detail screen's Cast tab. Fetched at runtime
/// from a metadata API (AniList for anime, TMDB for movie/TV) — never persisted,
/// so it carries no JSON serialization.
class CastMember extends Equatable {
  const CastMember({required this.name, this.role, this.photo, this.person});

  /// The person (actor / voice actor) or, for anime, the character.
  final String name;

  /// Secondary line — the character played, the voice actor, or a job title.
  final String? role;

  /// Headshot / portrait URL, when the source provides one.
  final String? photo;

  /// Link to the person page behind [name] — the character (anime) or the
  /// actor (movie/TV). Null for source-supplied cast that carries no id, so
  /// those cards stay non-tappable.
  final PersonRef? person;

  @override
  List<Object?> get props => [name, role, photo, person];
}

/// A related title (sequel, prequel, side story, recommendation) shown in the
/// Detail screen's Relations tab. Carries ids so a tap can find the title in the
/// active source. Runtime-only — not persisted.
class MediaRelation extends Equatable {
  const MediaRelation({
    required this.title,
    this.romaji,
    this.cover,
    this.relation,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.isReading = false,
  });

  final String title;

  /// The Romaji title (anime), kept so a tap can also match sources that index
  /// by Romaji instead of the English [title]. Null for TMDB relations.
  final String? romaji;

  final String? cover;

  /// Human label for the link, e.g. "Sequel", "Side Story", "Recommended".
  final String? relation;

  /// True when this points at a MANGA or NOVEL rather than something watched.
  ///
  /// A manga's relations reach into anime for its adaptation and back again,
  /// so the row mixes both — and the two cannot be opened the same way. Kept
  /// from AniList's `type` on the node, which was read for filtering and then
  /// dropped.
  final bool isReading;

  /// MAL's id, in the catalogue [isReading] names — MAL numbers its manga and
  /// its anime separately, so this means nothing without that flag.
  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;

  @override
  List<Object?> get props => [
    title,
    romaji,
    cover,
    relation,
    malId,
    tmdbId,
    tmdbIsTv,
    isReading,
  ];
}
