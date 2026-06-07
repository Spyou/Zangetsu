import 'package:equatable/equatable.dart';

/// One cast/crew entry shown in the Detail screen's Cast tab. Fetched at runtime
/// from a metadata API (AniList for anime, TMDB for movie/TV) — never persisted,
/// so it carries no JSON serialization.
class CastMember extends Equatable {
  const CastMember({required this.name, this.role, this.photo});

  /// The person (actor / voice actor) or, for anime, the character.
  final String name;

  /// Secondary line — the character played, the voice actor, or a job title.
  final String? role;

  /// Headshot / portrait URL, when the source provides one.
  final String? photo;

  @override
  List<Object?> get props => [name, role, photo];
}

/// A related title (sequel, prequel, side story, recommendation) shown in the
/// Detail screen's Relations tab. Carries ids so a tap can find the title in the
/// active source. Runtime-only — not persisted.
class MediaRelation extends Equatable {
  const MediaRelation({
    required this.title,
    this.cover,
    this.relation,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
  });

  final String title;
  final String? cover;

  /// Human label for the link, e.g. "Sequel", "Side Story", "Recommended".
  final String? relation;

  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;

  @override
  List<Object?> get props => [title, cover, relation, malId, tmdbId, tmdbIsTv];
}
