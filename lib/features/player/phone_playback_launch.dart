import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_encode_skew.dart';
import '../../core/playback/subtitle_font_stage.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tracker/tracker_hub.dart';
import 'subtitle_font_service.dart';
import 'subtitle_style.dart';

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

String phoneSubtitleMime(String? format, String url) {
  final f = (format ?? '').toLowerCase();
  final u = url.toLowerCase();
  if (f == 'vtt' || f == 'webvtt') return 'text/vtt';
  if (f == 'ass' || f == 'ssa') return 'text/x-ssa';
  if (f == 'ttml' || f == 'dfxp') return 'application/ttml+xml';
  if (f == 'srt' || f == 'subrip') return 'application/x-subrip';
  if (u.contains('.vtt')) return 'text/vtt';
  if (u.contains('.ass') || u.contains('.ssa')) return 'text/x-ssa';
  if (u.contains('.ttml') || u.contains('.dfxp')) {
    return 'application/ttml+xml';
  }
  if (u.contains('.srt')) return 'application/x-subrip';
  return 'text/vtt';
}

/// The provider's own name, else the quality, else a number — never blank.
String phoneMirrorLabel(VideoSource src, int i) {
  final l = src.label?.trim();
  if (l != null && l.isNotEmpty) return l;
  final q = src.quality?.trim();
  if (q != null && q.isNotEmpty) return q;
  return 'Server ${i + 1}';
}

Map<String, dynamic> _phoneSubtitlePayload(VideoSource source) {
  return <String, dynamic>{
    'subUrls': [for (final s in source.subtitles) s.url],
    'subLangs': [for (final s in source.subtitles) s.lang],
    'subLabels': [for (final s in source.subtitles) s.label ?? s.lang],
    'subFormats': [for (final s in source.subtitles) s.format ?? ''],
    'subDefaults': [for (final s in source.subtitles) s.isDefault],
  };
}

Map<String, dynamic> phoneSourceMap(VideoSource source, int index) {
  return <String, dynamic>{
    'label': phoneMirrorLabel(source, index),
    'url': source.url,
    'headers': source.headers ?? const <String, String>{},
    'mimeType': ?phoneMimeFor(source),
    'quality': source.quality ?? '',
    'kind': source.kind.name,
    'audioLang': source.audioLang ?? '',
    ..._phoneSubtitlePayload(source),
  };
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
  required int subtitleEdgeColor,
  required String subtitlePreference,
  required bool autoResume,
  required bool keepScreenOn,
  required bool autoplayNext,
  required int seekSeconds,
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
    ..._phoneSubtitlePayload(source),
    'accentColor': accentColor,
    'softwareDecoding': softwareDecoding,
    'defaultSpeed': defaultSpeed,
    ...bufferParams,
    'autoResume': autoResume,
    'keepScreenOn': keepScreenOn,
    'autoplayNext': autoplayNext,
    'seekSeconds': seekSeconds,
    'subtitleScale': subtitleScale,
    'subtitleFgColor': subtitleFgColor,
    'subtitleBgColor': subtitleBgColor,
    'subtitleEdgeType': subtitleEdgeType,
    'subtitleEdgeColor': subtitleEdgeColor,
    'subtitlePreference': subtitlePreference,
    'subtitleFontPath': ?subtitleFontPath,
  };
}

Future<void> phoneScrobbleOnLaunch({
  required Episode episode,
  required List<Episode> episodes,
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  bool peek = false,
}) async {
  if (peek) return;
  final number = episode.number;
  if (number == null ||
      !number.isFinite ||
      number <= 0 ||
      number != number.truncateToDouble()) {
    return;
  }
  if (!sl.isRegistered<TrackerHub>()) return;
  unawaited(
    sl<TrackerHub>().scrobble(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      episode: number.toInt(),
      season: episode.season,
      seasonEpisode: seasonEpisodeOf(episodes, episode),
    ),
  );
}

typedef PhoneSourcesPoll =
    Future<({List<VideoSource> sources, bool done})> Function(
      String episodeUrl,
    );

/// Opens the native phone player for [episodes] starting at [startIndex].
///
/// Same argument list as the TV launcher so the call site barely changes, but
/// a separate function with its own behaviour: it is laid out for touch, it
/// rotates, and it says so on screen when it has to change source.
Future<bool> launchPhonePlayback({
  required BuildContext context,
  required String sourceId,
  required List<Episode> episodes,
  required int startIndex,
  required ResumeStore resume,
  required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  PhoneSourcesPoll? pollSources,
  int resumePosition = 0,
  bool peek = false,
  String? showUrl,
  String? showTitle,
  String? cover,
  Map<String, String>? coverHeaders,
  String category = 'sub',
  List<String> availableCategories = const [],
  WatchHistory? history,
  VideoSource? initialSource,
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
}) async {
  return PhoneNativePlayer.play(
    sourceId: sourceId,
    episodes: episodes,
    startIndex: startIndex,
    resume: resume,
    resolveSources: resolveSources,
    pollSources: pollSources,
    resumePosition: resumePosition,
    peek: peek,
    showUrl: showUrl,
    showTitle: showTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    category: category,
    availableCategories: availableCategories,
    history: history,
    initialSource: initialSource,
    malId: malId,
    scrobbleTitle: scrobbleTitle,
    tmdbId: tmdbId,
    tmdbIsTv: tmdbIsTv,
    imdbId: imdbId,
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
  static PhoneSourcesPoll? _pollSources;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String? _scrobbleTitle;
  static int? _tmdbId;
  static bool _tmdbIsTv = false;
  static String? _imdbId;
  static String _category = 'sub';
  static ResumeStore? _resume;
  static WatchHistory? _history;
  static bool _autoResume = true;
  static bool _peek = false;

  /// Returns false when the episode could not be resolved or the Activity
  /// would not start. No UI of its own — the caller surfaces that.
  static Future<bool> play({
    required String sourceId,
    required List<Episode> episodes,
    required int startIndex,
    required ResumeStore resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
    resolveSources,
    PhoneSourcesPoll? pollSources,
    int resumePosition = 0,
    bool peek = false,
    String? showUrl,
    String? showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String category = 'sub',
    List<String> availableCategories = const [],
    WatchHistory? history,
    VideoSource? initialSource,
    int? malId,
    String? scrobbleTitle,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
  }) async {
    if (startIndex < 0 || startIndex >= episodes.length) return false;
    _resolve = resolveSources;
    _pollSources = pollSources;
    _peek = peek;
    _episodes = episodes;
    _sourceId = sourceId;
    _showUrl = showUrl;
    _showId = showUrl ?? sourceId;
    _showTitle = showTitle ?? '';
    _cover = cover;
    _coverHeaders = coverHeaders;
    _malId = malId;
    _scrobbleTitle = scrobbleTitle;
    _tmdbId = tmdbId;
    _tmdbIsTv = tmdbIsTv;
    _imdbId = imdbId;
    _category = category;
    _resume = resume;
    _history = history;
    if (!_handlerBound) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerBound = true;
    }

    final ep = _episodes[startIndex];
    final prefs = sl<PlaybackPrefs>();
    _autoResume = prefs.autoResume;
    final sources = initialSource == null
        ? await _resolveSources(ep)
        : [initialSource];
    if (sources.isEmpty) return false;
    final preparedSources = await _prepareSources(sources);
    if (preparedSources.isEmpty) return false;
    final src = initialSource == null
        ? _pickSource(preparedSources)
        : preparedSources.first;
    if (src == null) return false;
    final subFontPath = await _stageSubtitleFont(prefs.subtitleFont);
    final startPosition = _autoResume
        ? (resumePosition > 0 ? resumePosition : _resumePosition(ep))
        : 0;
    final args = phonePlayerArgs(
      source: src,
      positionMs: startPosition,
      title: _showTitle,
      episodeLabel: _episodeLabel(ep),
      episodeLabels: [for (final e in _episodes) _episodeLabel(e)],
      startIndex: startIndex,
      accentColor: AppColors.accent.toARGB32(),
      softwareDecoding: prefs.videoDecoder == 'sw',
      defaultSpeed: prefs.defaultSpeed,
      bufferParams: prefs.exoBufferParams,
      subtitleScale: prefs.subtitleScale,
      subtitleFgColor: parseSubtitleHex(
        prefs.subtitleColorHex,
        opacity: prefs.subtitleTextOpacity,
      ).toARGB32(),
      subtitleBgColor: parseSubtitleHex(
        '#000000',
        opacity: prefs.subtitleBgOpacity,
      ).toARGB32(),
      subtitleEdgeType: tvEdgeTypeFromOutlinePref(prefs.subtitleOutlineType),
      subtitleEdgeColor: parseSubtitleHex(
        prefs.subtitleOutlineColorHex,
      ).toARGB32(),
      subtitlePreference: prefs.subtitlePreference,
      autoResume: prefs.autoResume,
      keepScreenOn: prefs.keepScreenOn,
      autoplayNext: prefs.autoplayNext,
      seekSeconds: prefs.seekSeconds,
      subtitleFontPath: subFontPath,
    );

    _closed = Completer<Map<String, dynamic>?>();
    final launched = await _ch.invokeMethod<bool>('launch', args) ?? false;
    if (!launched) {
      _closed = null;
      return false;
    }
    unawaited(
      phoneScrobbleOnLaunch(
        episode: ep,
        episodes: _episodes,
        malId: _malId,
        scrobbleTitle: _scrobbleTitle,
        tmdbId: _tmdbId,
        tmdbIsTv: _tmdbIsTv,
        imdbId: _imdbId,
        peek: _peek,
      ),
    );
    await _closed!.future;
    return true;
  }

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'resolveEpisode':
        final args = _callArgs(call);
        final index = (args?['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return null;
        return _resolveEpisode(index);
      case 'sourcesFor':
        final args = _callArgs(call);
        final index = (args?['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return const <Map>[];
        final sources = await _resolveSources(
          _episodes[index],
          preferPolled: true,
        );
        final prepared = await _prepareSources(sources);
        return [
          for (var i = 0; i < prepared.length; i++)
            phoneSourceMap(prepared[i], i),
        ];
      case 'saveProgress':
        await _saveProgress(_callArgs(call), flush: true);
        return null;
      case 'playerClosed':
        final args = _callArgs(call);
        await _saveProgress(args, flush: true);
        if (_closed?.isCompleted == false) _closed!.complete(args);
        _closed = null;
        return null;
    }
    return null;
  }

  static Map<String, dynamic>? _callArgs(MethodCall call) {
    final raw = call.arguments;
    return raw is Map ? raw.cast<String, dynamic>() : null;
  }

  static Future<Map<String, dynamic>?> _resolveEpisode(int index) async {
    final ep = _episodes[index];
    final sources = await _resolveSources(ep);
    final prepared = await _prepareSources(sources);
    final src = _pickSource(prepared);
    if (src == null) return null;
    return {
      ...phoneSourceMap(src, _indexOfSource(prepared, src)),
      'positionMs': _resumePosition(ep),
      'episodeLabel': _episodeLabel(ep),
    };
  }

  static VideoSource? _pickSource(List<VideoSource> sources) => pickDefault(
    sources,
    prefer: _category == 'dub' ? AudioKind.dub : AudioKind.sub,
  );

  static int _indexOfSource(List<VideoSource> sources, VideoSource target) {
    final index = sources.indexWhere((source) => source.url == target.url);
    return index < 0 ? 0 : index;
  }

  static Future<List<VideoSource>> _resolveSources(
    Episode ep, {
    bool preferPolled = false,
  }) async {
    final url = tvEpisodeUrl(ep.url, _category);
    if (preferPolled && _pollSources != null) {
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        var latest = const <VideoSource>[];
        while (true) {
          final polled = await _pollSources!(url);
          latest = polled.sources;
          if (polled.done || DateTime.now().isAfter(deadline)) {
            if (latest.isNotEmpty) return latest;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      } catch (e) {
        debugPrint('[PhoneNativePlayer] poll failed · $e');
      }
    }
    try {
      return await _resolve!(url);
    } catch (e) {
      debugPrint('[PhoneNativePlayer] resolve failed · $e');
      return const [];
    }
  }

  static Future<List<VideoSource>> _prepareSources(
    List<VideoSource> sources,
  ) async {
    final prepared = <VideoSource>[];
    for (final source in sources) {
      if ((source.subtitleSkewSeconds ?? 0).abs() < 0.05) {
        prepared.add(source);
      } else {
        prepared.add(await materializeSkewedSubtitles(source));
      }
    }
    return prepared;
  }

  static Future<String?> _stageSubtitleFont(String family) async {
    if (family.isEmpty) return null;
    if (!await SubtitleFontService.instance.ensure(family)) return null;
    return stageSubtitleFont(family);
  }

  static int _resumePosition(Episode ep) {
    if (!_autoResume) return 0;
    return _resume?.get(_sourceId, _showId, ep.id)?.position.inMilliseconds ??
        0;
  }

  static Future<void> _saveProgress(
    Map<String, dynamic>? args, {
    required bool flush,
  }) async {
    if (args == null || _peek) return;
    final index = (args['index'] ?? args['episodeIndex']) as num?;
    final position = args['positionMs'] as num?;
    final duration = args['durationMs'] as num?;
    if (index == null || position == null) return;
    final i = index.toInt();
    if (i < 0 || i >= _episodes.length) return;
    final positionMs = position.toInt().clamp(0, 1 << 62);
    final durationMs = duration?.toInt().clamp(0, 1 << 62) ?? 0;
    if (durationMs <= 0 && positionMs <= 0) return;
    final ep = _episodes[i];
    await _resume?.save(
      _sourceId,
      _showId,
      ep.id,
      Duration(milliseconds: positionMs),
      Duration(milliseconds: durationMs),
    );
    final history = _history;
    if (history != null && _showTitle.isNotEmpty) {
      unawaited(
        history.save(
          HistoryEntry(
            sourceId: _sourceId,
            showId: _showId,
            showTitle: _showTitle,
            cover: _cover,
            coverHeaders: _coverHeaders,
            thumbnail: ep.thumbnail,
            showUrl: _showUrl ?? '',
            category: _category,
            episodeId: ep.id,
            episodeNumber: ep.number,
            episodeUrl: ep.url,
            position: Duration(milliseconds: positionMs),
            duration: Duration(milliseconds: durationMs),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            malId: _malId,
          ),
          flush: flush,
        ),
      );
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
