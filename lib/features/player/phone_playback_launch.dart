import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/theme/app_colors.dart';

/// Container → MIME hint. A tokenised url carries no extension, so without an
/// explicit MIME ExoPlayer builds the wrong MediaSource and never starts.
String? phoneMimeFor(VideoSource source) {
  final u = source.url.toLowerCase();
  if (source.container == SourceContainer.hls || u.contains('.m3u8')) {
    return 'application/x-mpegURL';
  }
  if (u.contains('.mpd')) return 'application/dash+xml';
  if (u.contains('.mp4')) return 'video/mp4';
  return null;
}

/// Everything [PhonePlayerActivity] needs for one launch, as a flat map.
///
/// Flat on purpose: the Kotlin side reads each value straight off the method
/// call, and [bufferParams] is spread in rather than nested so BufferPresets
/// can read it without knowing this function exists.
Map<String, dynamic> phonePlayerArgs({
  required VideoSource source,
  required int positionMs,
  required String title,
  required String episodeLabel,
  required List<String> episodeLabels,
  required int startIndex,
  required int accentColor,
  required bool softwareDecoding,
  required double defaultSpeed,
  required Map<String, dynamic> bufferParams,
  required double subtitleScale,
  required int subtitleFgColor,
  required int subtitleBgColor,
  required int subtitleEdgeType,
  String? subtitleFontPath,
}) {
  final mime = phoneMimeFor(source);
  return <String, dynamic>{
    'url': source.url,
    'headers': source.headers ?? const <String, String>{},
    'mimeType': ?mime,
    'positionMs': positionMs,
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeLabels': episodeLabels,
    'episodeCount': episodeLabels.length,
    'startIndex': startIndex,
    'subUrls': [for (final s in source.subtitles) s.url],
    'subLangs': [for (final s in source.subtitles) s.lang],
    // Fall back to the language so the picker never shows a blank row.
    'subLabels': [for (final s in source.subtitles) s.label ?? s.lang],
    'accentColor': accentColor,
    'softwareDecoding': softwareDecoding,
    'defaultSpeed': defaultSpeed,
    ...bufferParams,
    'subtitleScale': subtitleScale,
    'subtitleFgColor': subtitleFgColor,
    'subtitleBgColor': subtitleBgColor,
    'subtitleEdgeType': subtitleEdgeType,
    'subtitleFontPath': ?subtitleFontPath,
  };
}

/// Opens the native phone player for [episodes] starting at [startIndex].
///
/// Same argument list as the TV launcher so the call site barely changes, but
/// a separate function with its own behaviour: it is laid out for touch, it
/// rotates, and it says so on screen when it has to change source.
Future<void> launchPhonePlayback({
  required BuildContext context,
  required String sourceId,
  required List<Episode> episodes,
  required int startIndex,
  required ResumeStore resume,
  required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  String? showUrl,
  String? showTitle,
  String? cover,
  Map<String, String>? coverHeaders,
  String category = 'sub',
  List<String> availableCategories = const [],
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
}) async {
  await PhoneNativePlayer.play(
    sourceId: sourceId,
    episodes: episodes,
    startIndex: startIndex,
    resume: resume,
    resolveSources: resolveSources,
    showUrl: showUrl,
    showTitle: showTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    category: category,
    availableCategories: availableCategories,
    malId: malId,
    scrobbleTitle: scrobbleTitle,
    tmdbId: tmdbId,
    tmdbIsTv: tmdbIsTv,
  );
}

/// Drives [PhonePlayerActivity] over `zangetsu/phone_player`.
///
/// Resolution and persistence stay in Dart; the Activity is only a player.
/// Only one player is on screen at a time, so plain statics hold the session.
class PhoneNativePlayer {
  static const _ch = MethodChannel('zangetsu/phone_player');
  static bool _handlerBound = false;

  /// Completes when the Activity reports it closed, carrying the final
  /// position, duration and episode index.
  static Completer<Map<String, dynamic>?>? _closed;

  static Future<List<VideoSource>> Function(String episodeUrl)? _resolve;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String _category = 'sub';
  static ResumeStore? _resume;

  /// Returns false when the episode could not be resolved or the Activity
  /// would not start. No UI of its own — the caller surfaces that.
  static Future<bool> play({
    required String sourceId,
    required List<Episode> episodes,
    required int startIndex,
    required ResumeStore resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
    resolveSources,
    String? showUrl,
    String? showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String category = 'sub',
    List<String> availableCategories = const [],
    int? malId,
    String? scrobbleTitle,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (startIndex < 0 || startIndex >= episodes.length) return false;
    _resolve = resolveSources;
    _episodes = episodes;
    _sourceId = sourceId;
    _showUrl = showUrl;
    _showId = showUrl ?? sourceId;
    _showTitle = showTitle ?? '';
    _cover = cover;
    _coverHeaders = coverHeaders;
    _malId = malId;
    _category = category;
    _resume = resume;
    if (!_handlerBound) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerBound = true;
    }

    final ep = _episodes[startIndex];
    final src = await _resolveSource(ep);
    if (src == null) return false;

    final prefs = sl<PlaybackPrefs>();
    final mark = resume.get(sourceId, _showId, ep.id);
    final args = phonePlayerArgs(
      source: src,
      positionMs: mark?.position.inMilliseconds ?? 0,
      title: _showTitle,
      episodeLabel: _episodeLabel(ep),
      episodeLabels: [for (final e in _episodes) _episodeLabel(e)],
      startIndex: startIndex,
      accentColor: AppColors.accent.toARGB32(),
      softwareDecoding: false,
      defaultSpeed: prefs.defaultSpeed,
      bufferParams: prefs.exoBufferParams,
      subtitleScale: prefs.subtitleScale,
      subtitleFgColor: 0xFFFFFFFF,
      subtitleBgColor: 0x00000000,
      subtitleEdgeType: 1,
    );

    _closed = Completer<Map<String, dynamic>?>();
    final launched = await _ch.invokeMethod<bool>('launch', args) ?? false;
    if (!launched) {
      _closed = null;
      return false;
    }
    // Resolves when the Activity is destroyed; Task 7 uses the payload.
    await _closed!.future;
    return true;
  }

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'resolveEpisode':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return null;
        final ep = _episodes[index];
        final src = await _resolveSource(ep);
        if (src == null) return null;
        final mark = _resume?.get(_sourceId, _showId, ep.id);
        return {
          'url': src.url,
          'headers': src.headers ?? const <String, String>{},
          'mimeType': ?phoneMimeFor(src),
          'positionMs': mark?.position.inMilliseconds ?? 0,
          'episodeLabel': _episodeLabel(ep),
          'subUrls': [for (final s in src.subtitles) s.url],
          'subLangs': [for (final s in src.subtitles) s.lang],
          'subLabels': [for (final s in src.subtitles) s.label ?? s.lang],
        };
      case 'playerClosed':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        _closed?.complete(args);
        _closed = null;
        return null;
    }
    return null;
  }

  static Future<VideoSource?> _resolveSource(
    Episode ep, {
    String? category,
  }) async {
    final cat = category ?? _category;
    try {
      final sources = await _resolve!(tvEpisodeUrl(ep.url, cat));
      return pickDefault(
        sources,
        prefer: cat == 'dub' ? AudioKind.dub : AudioKind.sub,
      );
    } catch (e) {
      debugPrint('[PhoneNativePlayer] resolve failed · $e');
      return null;
    }
  }

  static String _episodeLabel(Episode ep) {
    final n = ep.number;
    final base = n == null ? '' : 'Episode ${n % 1 == 0 ? n.toInt() : n}';
    // Episode.title is non-nullable (episode.dart:31) but can be empty.
    final t = ep.title.trim();
    if (t.isEmpty) return base;
    return base.isEmpty ? t : '$base · $t';
  }
}
