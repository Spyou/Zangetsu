import 'package:equatable/equatable.dart';

/// Where a person page's data comes from (and which query to run).
enum PersonSource { anilistCharacter, anilistStaff, tmdb }

/// A tappable reference to a person page — an anime character or voice
/// actor/staff (AniList), or a movie/TV person (TMDB). Carried on
/// [CastMember] so a cast card can open the person's page, and used for links
/// between pages (a character's voice actors, etc.). Runtime-only.
class PersonRef extends Equatable {
  const PersonRef({
    required this.id,
    required this.source,
    required this.name,
    this.photo,
  });

  final int id;
  final PersonSource source;

  /// Shown as the page title while the full profile loads.
  final String name;

  /// Shown as the hero image while the full profile loads.
  final String? photo;

  @override
  List<Object?> get props => [id, source, name, photo];
}

/// A fully-loaded person profile shown on the person page.
class PersonProfile extends Equatable {
  const PersonProfile({
    required this.name,
    this.nativeName,
    this.photo,
    this.description,
    this.subtitle,
    this.works = const [],
    this.related = const [],
  });

  final String name;
  final String? nativeName;
  final String? photo;

  /// Bio / description. May carry light HTML/markdown from AniList — the page
  /// strips tags and renders it as plain text.
  final String? description;

  /// Small line under the name, e.g. "Voice Actor" / "Acting".
  final String? subtitle;

  /// Media this person appears in / worked on.
  final List<PersonWork> works;

  /// Linked people (e.g. a character's voice actors) shown as tappable chips.
  final List<PersonRef> related;

  @override
  List<Object?> get props =>
      [name, nativeName, photo, description, subtitle, works, related];
}

/// One media entry on a person page (a role / appearance). Tapping opens the
/// title in the active source (searched by [title], like the Relations tab).
class PersonWork extends Equatable {
  const PersonWork({
    required this.title,
    this.romaji,
    this.cover,
    this.subtitle,
    this.malId,
  });

  final String title;

  /// Romaji title (AniList works), so a tap also matches Romaji-indexed sources.
  final String? romaji;

  final String? cover;

  /// e.g. the character voiced, the job, or the role.
  final String? subtitle;

  /// MAL id (AniList works) — the reliable signal for opening the exact title
  /// on the source. Null for TMDB works (matched by title instead).
  final int? malId;

  @override
  List<Object?> get props => [title, romaji, cover, subtitle, malId];
}
