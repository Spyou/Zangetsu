import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/episode.dart';

/// A provider flag stays usable when the metadata lookup is unavailable.
bool isFillerEpisode(
  Episode episode,
  Set<int> fillerEps, {
  int? fallbackNumber,
}) => episode.filler || fillerEps.contains(episode.number ?? fallbackNumber);

/// Next episode index when advancing. When [autoSkipFiller] is on and
/// the source or metadata marks an episode as filler, skips consecutive fillers, but
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
  // Listed by the catalogue, but nothing has it yet — an episode that has not
  // aired is not a next episode. Advancing to it hands the viewer a button
  // that can only fail, and autoplay would roll into a dead end at the end of
  // every season currently airing. See [Episode.unavailable].
  if (!episodes[immediate].available) return null;
  if (!autoSkipFiller) return immediate;
  var target = immediate;
  while (target < episodes.length &&
      isFillerEpisode(episodes[target], fillerEps)) {
    target++;
  }
  // Skipping filler must not skip INTO something unplayable either.
  if (target >= episodes.length || !episodes[target].available) {
    return immediate;
  }
  return target;
}

/// Fetches filler episode numbers by MyAnimeList ID from Tenrai.
class FillerService {
  FillerService._(this._dio);

  @visibleForTesting
  FillerService.withClient(this._dio);

  static final FillerService instance = FillerService._(
    Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    ),
  );

  final Dio _dio;

  final Map<int, Set<int>> _cache = {};
  final Map<int, Future<Set<int>>> _inflight = {};

  /// Returns known filler episode numbers. Only complete responses are cached.
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
          'https://api.tenrai.org/v1/anime/$malId/episodes',
          queryParameters: {'page': page, 'filler': true},
        );
        // Dio may hand back a parsed Map OR a raw JSON String — handle both.
        final raw = resp.data;
        final body = raw is Map
            ? raw
            : (raw is String ? jsonDecode(raw) as Map : const {});
        final data = body['data'];
        final pagination = body['pagination'];
        final last = pagination is Map ? pagination['last_visible_page'] : null;
        if (data is! List || last is! int || last < 0) break;
        for (final e in data) {
          if (e is Map && e['filler'] == true) {
            final n = (e['mal_id'] as num?)?.toInt();
            if (n != null) fillers.add(n);
          }
        }
        if (page >= last) {
          return _cache[malId] = Set.unmodifiable(fillers);
        }
        page++;
        // Space pages to stay within Tenrai's public per-minute limit.
        await Future<void>.delayed(const Duration(milliseconds: 550));
      }
    } catch (_) {
      // Partial results help this view without hiding the failure in cache.
    }
    return fillers;
  }
}
