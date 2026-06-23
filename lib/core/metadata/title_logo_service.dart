import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/media_item.dart';
import 'tmdb.dart';

/// Best-effort TMDB "title logo" (the stylized title-art PNG) for a hero item,
/// so the banner can show the logo instead of plain text — CloudStream-style.
/// Resolves by tmdbId when the item has one, else a title search.
///
/// Two-level cache so the logo doesn't "pop in" every time:
///  - in-memory (per session),
///  - Hive ([_boxName], persisted) — keyed by tmdbId/title, value = logo URL
///    ('' means "this title genuinely has no logo", so we don't re-search it).
/// Only RESOLVED results are cached; a network error (e.g. a TMDB reset) is NOT
/// cached, so a later attempt can still succeed once TMDB is reachable. Any
/// failure yields null → the banner keeps its text title.
class TitleLogoService {
  TitleLogoService(this._dio);
  final Dio _dio;

  static const String _boxName = 'logo_cache';

  final Map<String, String> _mem = {}; // '' = known "no logo"
  Box<String>? _boxRef;
  Box<String> get _box => _boxRef ??= Hive.box<String>(_boxName);

  /// Open the persisted cache. Call once in initDependencies before use.
  static Future<void> init() async {
    await Hive.openBox<String>(_boxName);
  }

  /// Warm logos for the hero carousel up front — SEQUENTIALLY (one TMDB lookup
  /// chain at a time), so it never bursts requests at TMDB (which would trip its
  /// connection-reset rate limit) nor competes for the network all at once. By
  /// the time a banner rotates in, its logo is already cached → no pop-in.
  Future<void> prefetch(List<MediaItem> items) async {
    for (final it in items) {
      try {
        await logoFor(it);
      } catch (_) {/* best-effort */}
    }
  }

  Future<String?> logoFor(MediaItem item) async {
    final key = item.tmdbId != null
        ? 'id:${item.tmdbId}:${item.tmdbIsTv}'
        : 'q:${(item.englishTitle ?? item.title).toLowerCase()}';

    final cached = _mem[key] ?? _box.get(key);
    if (cached != null) {
      _mem[key] = cached;
      return cached.isEmpty ? null : cached;
    }

    try {
      final url = await _resolve(item).timeout(const Duration(seconds: 5));
      // Cache the resolved result (a URL, or '' for a genuine "no logo").
      final value = url ?? '';
      _mem[key] = value;
      await _box.put(key, value);
      return url;
    } catch (_) {
      // Network error (e.g. a TMDB reset) — do NOT cache, so a later attempt
      // (this session or a future launch) can still resolve the logo.
      return null;
    }
  }

  Future<String?> _resolve(MediaItem item) async {
    int? id = item.tmdbId;
    var isTv = item.tmdbIsTv;
    if (id == null) {
      final q = (item.englishTitle ?? item.title).trim();
      if (q.isEmpty) return null;
      final s = await _dio.get<dynamic>(
        '${Tmdb.base}/search/multi',
        queryParameters: {'query': q},
        options: Options(validateStatus: (c) => c != null && c < 500),
      );
      final results = (s.data is Map) ? s.data['results'] : null;
      if (results is! List) return null;
      for (final r in results) {
        if (r is! Map) continue;
        final mt = r['media_type'];
        if (mt == 'movie' || mt == 'tv') {
          id = (r['id'] as num?)?.toInt();
          isTv = mt == 'tv';
          break;
        }
      }
      if (id == null) return null;
    }
    final kind = isTv ? 'tv' : 'movie';
    final imgs = await _dio.get<dynamic>(
      '${Tmdb.base}/$kind/$id/images',
      queryParameters: {'include_image_language': 'en,null'},
      options: Options(validateStatus: (c) => c != null && c < 500),
    );
    final logos = (imgs.data is Map) ? imgs.data['logos'] : null;
    if (logos is! List || logos.isEmpty) return null;
    // Prefer an English logo; else the first available.
    Map<dynamic, dynamic>? best;
    for (final l in logos) {
      if (l is! Map) continue;
      if (l['iso_639_1'] == 'en') {
        best = l;
        break;
      }
      best ??= l;
    }
    final path = best?['file_path'] as String?;
    if (path == null || path.isEmpty) return null;
    return '${Tmdb.img}/w500$path';
  }
}
