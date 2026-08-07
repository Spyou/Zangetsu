import 'dart:convert';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/episode.dart';
import '../models/provider_info.dart';

/// One episode's fetched extras. Any field may be null (source lacked it).
typedef EpisodeMeta = ({
  String? title,
  String? overview,
  String? image,
  double? rating,
  int? runtime,
  String? airDate,
});

/// Per-episode title / synopsis / still / rating / runtime for the episode list.
/// Best-effort: every method returns an empty map on any error/timeout and
/// never throws. Anime uses AniZip (by MAL id — a separate API, unaffected by
/// AniList throttling); movie-source TV series use one TMDB season call.
/// Results are cached in memory for the session AND on disk (Hive) so a
/// re-opened title fills in instantly instead of popping in again.
class EpisodeMetadataService {
  EpisodeMetadataService(this._dio);

  final Dio _dio;
  static const String _tmdbBase = 'https://api.themoviedb.org/3';
  static const String _tmdbImg = 'https://image.tmdb.org/t/p/w300';
  static const String boxName = 'episode_meta';

  final Map<int, Map<int, EpisodeMeta>> _animeCache = {};
  final Map<String, Map<int, EpisodeMeta>> _tvCache = {};
  // In-flight requests, so a prefetch (fired at tap time) and the later
  // enrichment call share ONE request instead of hitting the network twice.
  final Map<int, Future<Map<int, EpisodeMeta>>> _animeInflight = {};
  final Map<String, Future<Map<int, EpisodeMeta>>> _tvInflight = {};

  /// Fetch (or prefetch) anime episode metadata by MAL id. Cached in memory +
  /// on disk; concurrent callers share the in-flight request. Fire-and-forget
  /// safe — never throws.
  Future<Map<int, EpisodeMeta>> animeEpisodeMeta(int malId) {
    final memo = _animeCache[malId];
    if (memo != null) return Future.value(memo);
    return _animeInflight.putIfAbsent(malId, () {
      final f = _fetchAnime(malId);
      f.whenComplete(() => _animeInflight.remove(malId));
      return f;
    });
  }

  Future<Map<int, EpisodeMeta>> _fetchAnime(int malId) async {
    final disk = await _readDisk('a:$malId');
    if (disk != null) return _animeCache[malId] = parseAniZip(disk);
    try {
      final res = await _dio
          .get<dynamic>(
            'https://api.ani.zip/mappings?mal_id=$malId',
            options: Options(validateStatus: (s) => s != null && s < 500),
          )
          .timeout(const Duration(seconds: 6));
      final out = parseAniZip(res.data);
      if (out.isNotEmpty) await _writeDisk('a:$malId', res.data);
      return _animeCache[malId] = out;
    } catch (_) {
      return const {};
    }
  }

  Future<Map<int, EpisodeMeta>> tvEpisodeMeta(int tmdbId, int season) {
    final key = '$tmdbId:$season';
    final memo = _tvCache[key];
    if (memo != null) return Future.value(memo);
    return _tvInflight.putIfAbsent(key, () {
      final f = _fetchTv(tmdbId, season, key);
      f.whenComplete(() => _tvInflight.remove(key));
      return f;
    });
  }

  Future<Map<int, EpisodeMeta>> _fetchTv(
    int tmdbId,
    int season,
    String key,
  ) async {
    final disk = await _readDisk('t:$key');
    if (disk != null) return _tvCache[key] = parseTmdbSeason(disk);
    try {
      final res = await _dio
          .get<dynamic>(
            '$_tmdbBase/tv/$tmdbId/season/$season',
            options: Options(validateStatus: (s) => s != null && s < 500),
          )
          .timeout(const Duration(seconds: 6));
      final out = parseTmdbSeason(res.data);
      if (out.isNotEmpty) await _writeDisk('t:$key', res.data);
      return _tvCache[key] = out;
    } catch (_) {
      return const {};
    }
  }

  /// Return [episodes] with title / synopsis / still / rating / runtime filled
  /// in, best-effort. Anime (mal id) matches by absolute episode number in one
  /// AniZip call; a movie-source TV series (tmdb id + isTv) fetches each season
  /// and matches by number within it. Any miss returns the episodes unchanged.
  Future<List<Episode>> enrich({
    required List<Episode> episodes,
    required ProviderType type,
    int? malId,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (episodes.isEmpty) return episodes;
    if (type == ProviderType.anime && malId != null) {
      final meta = await animeEpisodeMeta(malId);
      return mergeMeta(episodes, (e) => meta[_intNumber(e)]);
    }
    if (tmdbId != null && tmdbIsTv) {
      final seasons = <int>{for (final e in episodes) e.season ?? 1};
      final bySeason = <int, Map<int, EpisodeMeta>>{};
      for (final s in seasons) {
        bySeason[s] = await tvEpisodeMeta(tmdbId, s);
      }
      if (bySeason.values.every((m) => m.isEmpty)) return episodes;
      return mergeMeta(
        episodes,
        (e) => bySeason[e.season ?? 1]?[_intNumber(e)],
      );
    }
    return episodes;
  }

  // ── Disk cache (best-effort; a Hive miss/failure just falls through) ──────
  // Stores the raw API response JSON and re-parses it on read, so there's no
  // separate serialization to keep in sync with EpisodeMeta.

  Future<Box?> _box() async {
    try {
      return Hive.isBoxOpen(boxName)
          ? Hive.box(boxName)
          : await openBoxSafely(boxName);
    } catch (_) {
      return null;
    }
  }

  Future<Object?> _readDisk(String key) async {
    try {
      final s = (await _box())?.get(key) as String?;
      return s == null ? null : jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, Object? data) async {
    try {
      await (await _box())?.put(key, jsonEncode(data));
    } catch (_) {/* cache is optional */}
  }

  /// AniZip: `{ episodes: { "1": { title{en}, overview, image, rating,
  /// runtime, airDate }, ... } }`.
  static Map<int, EpisodeMeta> parseAniZip(Object? data) {
    final out = <int, EpisodeMeta>{};
    if (data is Map && data['episodes'] is Map) {
      (data['episodes'] as Map).forEach((k, v) {
        final n = int.tryParse('$k');
        if (n == null || v is! Map) return;
        final meta = _meta(
          title: _aniZipTitle(v['title']),
          overview: v['overview'],
          image: v['image'],
          rating: v['rating'],
          runtime: v['runtime'],
          airDate: v['airDate'] ?? v['airdate'],
        );
        if (meta != null) out[n] = meta;
      });
    }
    return out;
  }

  /// TMDB season: `{ episodes: [ { episode_number, name, overview, still_path,
  /// vote_average, runtime, air_date } ] }`.
  static Map<int, EpisodeMeta> parseTmdbSeason(Object? data) {
    final out = <int, EpisodeMeta>{};
    if (data is Map && data['episodes'] is List) {
      for (final e in data['episodes'] as List) {
        if (e is! Map) continue;
        final n = (e['episode_number'] as num?)?.toInt();
        if (n == null) continue;
        final still = e['still_path'] as String?;
        final meta = _meta(
          title: e['name'],
          overview: e['overview'],
          image: (still != null && still.isNotEmpty) ? '$_tmdbImg$still' : null,
          rating: e['vote_average'],
          runtime: e['runtime'],
          airDate: e['air_date'],
        );
        if (meta != null) out[n] = meta;
      }
    }
    return out;
  }

  /// AniZip stores title as a language map (`{en, x-jat, ...}`) or plain string.
  static String? _aniZipTitle(Object? title) {
    if (title is Map) {
      return (title['en'] ?? title['x-jat'] ?? title['ja']) as String?;
    }
    return title as String?;
  }

  static String? _str(Object? v) =>
      (v is String && v.trim().isNotEmpty) ? v.trim() : null;

  /// Build a record; return null when every field is empty (nothing to merge).
  static EpisodeMeta? _meta({
    Object? title,
    Object? overview,
    Object? image,
    Object? rating,
    Object? runtime,
    Object? airDate,
  }) {
    final t = _str(title);
    final o = _str(overview);
    final img = _str(image);
    // AniZip rating is a string ("8.02"); TMDB vote_average is a num.
    final r = rating is num
        ? rating.toDouble()
        : double.tryParse('${rating ?? ''}');
    final rt = runtime is num
        ? runtime.toInt()
        : int.tryParse('${runtime ?? ''}');
    final d = _str(airDate);
    final rating0 = (r != null && r > 0) ? r : null;
    final runtime0 = (rt != null && rt > 0) ? rt : null;
    if (t == null &&
        o == null &&
        img == null &&
        rating0 == null &&
        runtime0 == null &&
        d == null) {
      return null;
    }
    return (
      title: t,
      overview: o,
      image: img,
      rating: rating0,
      runtime: runtime0,
      airDate: d,
    );
  }

  /// The episode's integer number when it has one (skips half-episode 12.5s).
  static int? _intNumber(Episode e) =>
      (e.number != null && e.number! == e.number!.roundToDouble())
      ? e.number!.toInt()
      : null;
}

/// Return a copy of [eps] where each episode carries the extras from [lookup]
/// (null → unchanged). The still and air date are filled ONLY when the source
/// left them empty, so a source's own per-episode data always wins. Titles land
/// in [Episode.metaTitle]; the UI decides whether to prefer it.
List<Episode> mergeMeta(
  List<Episode> eps,
  EpisodeMeta? Function(Episode) lookup,
) {
  var changed = false;
  final out = [
    for (final e in eps)
      () {
        final m = lookup(e);
        if (m == null) return e;
        changed = true;
        final noThumb = e.thumbnail == null || e.thumbnail!.isEmpty;
        final noDate = e.date == null || e.date!.isEmpty;
        return e.copyWith(
          description: m.overview,
          metaTitle: m.title,
          thumbnail: noThumb ? m.image : null,
          date: noDate ? m.airDate : null,
          rating: m.rating,
          runtimeMinutes: m.runtime,
        );
      }(),
  ];
  return changed ? out : eps;
}
