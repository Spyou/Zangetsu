import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/episode.dart';

/// Next episode index when advancing. When [autoSkipFiller] is on and
/// [fillerEps] is non-empty, jumps past consecutive filler episodes — but
/// never strands the user (if everything left is filler, returns [currentIndex]
/// + 1). Returns null when there is no next episode.
///
/// Used for both autoplay and the Next control when the pref is on; pick a
/// specific episode from the list to still play filler.
int? nextAutoplayIndex({
  required int currentIndex,
  required List<Episode> episodes,
  required Set<int> fillerEps,
  required bool autoSkipFiller,
}) {
  final immediate = currentIndex + 1;
  if (immediate >= episodes.length) return null;
  if (!autoSkipFiller || fillerEps.isEmpty) return immediate;
  var target = immediate;
  while (target < episodes.length &&
      fillerEps.contains(episodes[target].number?.toInt())) {
    target++;
  }
  if (target >= episodes.length) return immediate;
  return target;
}

/// Fetches the set of FILLER episode numbers for an anime from Jikan (the MAL
/// API): `api.jikan.moe/v4/anime/{malId}/episodes` returns a `filler` boolean
/// per episode, keyed by MAL id — the same data the wider ecosystem uses. Keyed
/// by MAL id (which we already have for AniList anime), so no title-scraping.
///
/// Best-effort + cached per session: a network failure or an unlisted show just
/// yields an empty set (no badges, no skips) — never an error to the caller.
class FillerService {
  FillerService._();
  static final FillerService instance = FillerService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  final Map<int, Set<int>> _cache = {};
  final Map<int, Future<Set<int>>> _inflight = {};

  /// Filler episode NUMBERS for [malId] (cached). Empty on failure/unlisted.
  Future<Set<int>> fillerEpisodes(int malId) {
    final cached = _cache[malId];
    if (cached != null) return Future.value(cached);
    return _inflight[malId] ??= _fetch(malId).whenComplete(() {
      _inflight.remove(malId);
    });
  }

  /// Warm the in-memory cache without a network call (tests).
  @visibleForTesting
  void debugSeedCache(int malId, Set<int> fillers) {
    _cache[malId] = fillers;
  }

  /// Drop the in-memory cache (tests).
  @visibleForTesting
  void debugClearCache() {
    _cache.clear();
    _inflight.clear();
  }

  /// Synchronous peek of a warm cache entry (null if not fetched yet).
  Set<int>? peekCache(int malId) => _cache[malId];

  Future<Set<int>> _fetch(int malId) async {
    final fillers = <int>{};
    try {
      var page = 1;
      while (page <= 20) {
        // hard cap: 20 pages (2000 eps) so a bad id can't loop
        final resp = await _dio.get<dynamic>(
          'https://api.jikan.moe/v4/anime/$malId/episodes',
          queryParameters: {'page': page},
        );
        // Dio may hand back a parsed Map OR a raw JSON String — handle both.
        final raw = resp.data;
        final body = raw is Map
            ? raw
            : (raw is String ? jsonDecode(raw) as Map : const {});
        final data = (body['data'] as List?) ?? const [];
        for (final e in data) {
          if (e is Map && e['filler'] == true) {
            final n = (e['mal_id'] as num?)?.toInt();
            if (n != null) fillers.add(n);
          }
        }
        final last =
            (body['pagination']?['last_visible_page'] as num?)?.toInt() ?? page;
        if (page >= last) break;
        page++;
        // Respect Jikan's rate limit (~3 req/s) on multi-page shows.
        await Future.delayed(const Duration(milliseconds: 400));
      }
    } catch (_) {
      // keep whatever we collected (possibly empty)
    }
    _cache[malId] = fillers;
    return fillers;
  }
}
