import 'dart:async';

import 'package:dio/dio.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/media_item.dart';
import '../stremio/stremio_ref.dart';
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
  TitleLogoService(this._dio, {this.addonLogoFor});
  final Dio _dio;
  final Future<String?> Function(MediaItem)? addonLogoFor;

  static const String _boxName = 'logo_cache';

  final Map<String, String> _mem = {}; // '' = known "no logo"
  final Set<String> _failedAddonLogos = {};
  final Map<String, Future<String?>> _stremioLookups = {};
  Future<void> _posterLogoQueue = Future<void>.value();
  Box<String>? _boxRef;
  Box<String> get _box => _boxRef ??= Hive.box<String>(_boxName);

  /// Open the persisted cache. Call once in initDependencies before use.
  ///
  /// Resilient: a half-written frame (e.g. the app was killed mid-cache) can make
  /// the box fail — or hang — to open, which would trap the whole app on the
  /// splash. The logo cache is disposable, so on any failure/timeout we wipe it
  /// from disk and reopen fresh instead of blocking boot.
  static Future<void> init() async {
    try {
      await openBoxSafely<String>(_boxName).timeout(const Duration(seconds: 6));
    } catch (_) {
      try {
        await Hive.deleteBoxFromDisk(_boxName);
      } catch (_) {}
      try {
        await openBoxSafely<String>(_boxName);
      } catch (_) {}
    }
  }

  /// Warm logos for the hero carousel up front — SEQUENTIALLY (one TMDB lookup
  /// chain at a time), so it never bursts requests at TMDB (which would trip its
  /// connection-reset rate limit) nor competes for the network all at once. By
  /// the time a banner rotates in, its logo is already cached → no pop-in.
  Future<void> prefetch(List<MediaItem> items) async {
    for (final it in items) {
      if (it.sourceId == stremioSourceId && _imageUrl(it.titleLogo) == null) {
        continue;
      }
      try {
        await logoFor(it);
      } catch (_) {
        /* best-effort */
      }
    }
  }

  Future<String?> logoFor(MediaItem item) async {
    if (item.sourceId != stremioSourceId) return _tmdbLogoFor(item);
    final key = '${item.id}|${item.titleLogo ?? ''}';
    return _stremioLookups.putIfAbsent(
      key,
      () => _stremioLogoFor(item).whenComplete(() {
        _stremioLookups.remove(key);
      }),
    );
  }

  Future<String?> _stremioLogoFor(MediaItem item) async {
    final addonKey = 'stremio-title:${item.id}';
    final cached =
        _mem[addonKey] ??
        (Hive.isBoxOpen(_boxName) ? _box.get(addonKey) : null);
    var addonLogo = _imageUrl(item.titleLogo) ?? cached;
    if (addonLogo == null && addonLogoFor != null) {
      try {
        addonLogo = _imageUrl(
          await addonLogoFor!(item).timeout(const Duration(seconds: 5)),
        );
      } catch (_) {
        // Missing addon metadata still permits the existing TMDB fallback.
      }
    }
    if (addonLogo != null && !_failedAddonLogos.contains(addonLogo)) {
      _mem[addonKey] = addonLogo;
      if (cached != addonLogo && Hive.isBoxOpen(_boxName)) {
        try {
          await _box.put(addonKey, addonLogo);
        } catch (_) {
          // A disposable cache must not hide an available logo.
        }
      }
      return addonLogo;
    }
    return _tmdbLogoFor(item);
  }

  /// Only a failed addon image may trigger the TMDB fallback.
  Future<String?> fallbackFor(MediaItem item, String failedUrl) async {
    if (item.sourceId != stremioSourceId) return null;
    final key = 'stremio-title:${item.id}';
    final addonLogo =
        _imageUrl(item.titleLogo) ??
        _mem[key] ??
        (Hive.isBoxOpen(_boxName) ? _box.get(key) : null);
    if (addonLogo != failedUrl) return null;
    _failedAddonLogos.add(failedUrl);
    final fallback = await logoFor(item);
    return fallback == failedUrl ? null : fallback;
  }

  static String? _imageUrl(String? value) {
    final text = value?.trim();
    final uri = text == null ? null : Uri.tryParse(text);
    return uri != null &&
            uri.host.isNotEmpty &&
            (uri.scheme == 'https' || uri.scheme == 'http')
        ? text
        : null;
  }

  static String _key(MediaItem item) => item.tmdbId != null
      ? 'id:${item.tmdbId}:${item.tmdbIsTv}'
      : 'q:${(item.englishTitle ?? item.title).toLowerCase()}';

  Future<String?> _tmdbLogoFor(MediaItem item) async {
    final key = _key(item);

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

  /// Poster grids can build many cards at once. Keep their opt-in logo
  /// lookups sequential so a large grid doesn't burst TMDB requests.
  Future<String?> logoForPoster(MediaItem item) async {
    final previous = _posterLogoQueue;
    final done = Completer<void>();
    _posterLogoQueue = done.future;
    await previous;
    try {
      return await logoFor(item);
    } finally {
      done.complete();
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
