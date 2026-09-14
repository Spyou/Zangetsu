import 'package:flutter/foundation.dart';

import '../anilist/anilist_api.dart';
import '../metadata/episode_metadata_service.dart';

/// One season of a franchise, as the Relations tab draws it.
///
/// [malId] and [anilistId] are the whole point: a season stays its own
/// catalogue title, with its own tracker entry, its own Continue Watching row
/// and its own progress. This is a shortcut between those titles, never a
/// merge of them — scrobbling an episode against the wrong one would corrupt
/// somebody's list.
@immutable
class SeasonEntry {
  const SeasonEntry({
    required this.number,
    required this.title,
    this.anilistId,
    this.malId,
    this.cover,
    this.episodes,
    this.isCurrent = false,
  });

  /// The real season number where AniZip knows it, otherwise 1-based position
  /// in the chain. Never anything AniList reports — it has no season number.
  /// See [SeasonChain._numbered].
  final int number;
  final String title;
  final int? anilistId;
  final int? malId;
  final String? cover;
  final int? episodes;

  /// The title the viewer is looking at right now.
  final bool isCurrent;
}

/// Builds the ordered list of seasons around a title.
///
/// AniList and MAL have no season number: every season is a separate title,
/// linked only by PREQUEL/SEQUEL. So the order has to be walked, and the
/// number is the position once it is.
///
/// A hop costs one request ([AniListApi.seasonNeighbours] keeps it small), so
/// the walk is bounded at both ends and the whole chain is cached for the
/// session. Nothing here runs until the Relations tab asks.
class SeasonChain {
  SeasonChain(this._api, this._meta);

  final AniListApi _api;

  /// Supplies the REAL season number per title. AniList has none — see
  /// [_numbered].
  final EpisodeMetadataService _meta;

  /// Chains already built this session, keyed by the AniList id asked for.
  /// Every member of a chain maps to the same list, so opening season 3 after
  /// season 1 costs nothing.
  final Map<int, List<SeasonEntry>> _cache = {};

  /// Franchises can be long (Monogatari), but a viewer scanning posters cannot
  /// use thirty of them, and each one is a request. Eight covers essentially
  /// every ordinary series.
  static const int maxSeasons = 8;

  /// Formats that are a SEASON rather than something else attached to the
  /// franchise. A film or a recap special is related, but numbering it
  /// "Season 4" is worse than leaving it in Related where it already sits.
  static const Set<String> _seasonFormats = {'TV', 'TV_SHORT', 'ONA'};

  static bool _isSeason(String? format) =>
      format == null || _seasonFormats.contains(format);

  /// The seasons around [anilistId], in order, or an empty list when the title
  /// has no prequel and no sequel — which is most of them, and which the UI
  /// reads as "draw no Seasons section".
  Future<List<SeasonEntry>> of({
    required int anilistId,
    required String currentTitle,
    int? currentMalId,
    String? currentCover,
    int? currentEpisodes,
  }) async {
    final hit = _cache[anilistId];
    if (hit != null) return hit;

    // Walk backwards first: the head of the chain is season 1, and numbering
    // cannot start until it is known.
    final before = await _walk(anilistId, 'PREQUEL');
    final after = await _walk(anilistId, 'SEQUEL');
    if (before.isEmpty && after.isEmpty) {
      _cache[anilistId] = const [];
      return const [];
    }

    final ordered = [
      ...before.reversed,
      (
        id: anilistId,
        idMal: currentMalId,
        title: currentTitle,
        cover: currentCover,
        episodes: currentEpisodes,
      ),
      ...after,
    ];

    final seasons = await _numbered(ordered, anilistId);
    if (seasons.isEmpty) {
      _cache[anilistId] = const [];
      return const [];
    }
    // Cache under every member, so the chain is built once per franchise
    // rather than once per season the viewer opens.
    for (final s in seasons) {
      if (s.anilistId != null) _cache[s.anilistId!] = seasons;
    }
    debugPrint(
      '[seasons] $anilistId → ${seasons.length} seasons '
      '(${seasons.map((s) => s.number).join(",")})',
    );
    return seasons;
  }

  /// Turns the walked chain into numbered seasons.
  ///
  /// AniList files a split cour as two titles, so chain position said "5
  /// seasons" for a show with three — and labelled Mushoku Tensei II as
  /// "Season 3". AniZip stamps both halves of a cour with the same real season
  /// number, so asking it per title collapses them.
  ///
  /// All-or-nothing on purpose: if any entry is unmapped, the whole list falls
  /// back to position numbering. Mixing the two would put a real "Season 2"
  /// next to a guessed one and there would be no way to tell which was which.
  Future<List<SeasonEntry>> _numbered(
    List<({int id, int? idMal, String title, String? cover, int? episodes})>
        ordered,
    int currentAnilistId,
  ) async {
    SeasonEntry entry(
      int n,
      ({int id, int? idMal, String title, String? cover, int? episodes}) e,
      bool current,
    ) => SeasonEntry(
      number: n,
      title: e.title,
      anilistId: e.id,
      malId: e.idMal,
      cover: e.cover,
      episodes: e.episodes,
      isCurrent: current,
    );

    final real = <int, int>{}; // chain index -> AniZip season
    for (var i = 0; i < ordered.length; i++) {
      final mal = ordered[i].idMal;
      if (mal == null) break;
      final n = await _meta.animeSeasonNumber(mal);
      if (n == null) break;
      real[i] = n;
    }

    if (real.length != ordered.length) {
      debugPrint(
        '[seasons] only ${real.length}/${ordered.length} mapped — '
        'numbering by position',
      );
      return [
        for (var i = 0; i < ordered.length; i++)
          entry(i + 1, ordered[i], ordered[i].id == currentAnilistId),
      ];
    }

    // One card per real season. Two cours of season 2 are one card; the OTHER
    // cour stays in Related, where it reads as "Part 2" and is still reachable.
    final byNumber = <int, int>{}; // season -> chain index chosen
    for (var i = 0; i < ordered.length; i++) {
      final n = real[i]!;
      final chosen = byNumber[n];
      // Prefer whichever entry the viewer is actually on, so "you are here"
      // lands on the right card; otherwise the first cour, which is where a
      // season starts.
      if (chosen == null || ordered[i].id == currentAnilistId) {
        byNumber[n] = i;
      }
    }
    final numbers = byNumber.keys.toList()..sort();
    return [
      for (final n in numbers)
        entry(n, ordered[byNumber[n]!], ordered[byNumber[n]!].id == currentAnilistId),
    ];
  }

  /// Follows [relation] from [startId] until it runs out, loops, or hits the
  /// cap. Returns nearest-first.
  Future<List<({int id, int? idMal, String title, String? cover, int? episodes})>>
      _walk(int startId, String relation) async {
    final out = <({int id, int? idMal, String title, String? cover, int? episodes})>[];
    // A franchise CAN link back on itself (a sequel whose prequel is a
    // different entry than the one you came from). Without this the walk
    // would loop until the cap every time.
    final seen = <int>{startId};
    var id = startId;
    while (out.length < maxSeasons) {
      final List<({String relation, int id, int? idMal, String? format,
          String title, String? cover, int? episodes})> neighbours;
      try {
        neighbours = await _api.seasonNeighbours(id);
      } catch (e) {
        debugPrint('[seasons] walk $relation stopped at $id: $e');
        break;
      }
      final next = neighbours
          .where((n) => n.relation == relation && _isSeason(n.format))
          .where((n) => !seen.contains(n.id))
          .firstOrNull;
      if (next == null) break;
      seen.add(next.id);
      out.add((
        id: next.id,
        idMal: next.idMal,
        title: next.title,
        cover: next.cover,
        episodes: next.episodes,
      ));
      id = next.id;
    }
    return out;
  }
}
