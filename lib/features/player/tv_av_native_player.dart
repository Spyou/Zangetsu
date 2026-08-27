import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/download/hls_downloader.dart';
import '../../core/di/injector.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_font_stage.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/subtitle_encode_skew.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import 'subtitle_font_service.dart';

/// Launches the Apple TV native player over `zangetsu/tv_player`.
///
/// Uses AVKit [TvSystemPlayerViewController] (`playerMode: system`) with
/// transport menus, Episodes tab, and Up Next.
///
/// Channel contract mirrors Android [TvNativePlayer] on `zangetsu/tv_player`:
///  - Dart → native `launch` / `setFillerInfo`
///  - native → Dart `resolveEpisode` / `saveProgress` / prefs / skips / subs
///
/// Resolution and persistence stay in Dart. No torrent / DRM / volume boost
/// on Apple TV.
class TvAvNativePlayer {
  static const _ch = MethodChannel('zangetsu/tv_player');
  static bool _handlerBound = false;

  static Future<List<VideoSource>> Function(String episodeUrl)? _resolve;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String? _skipTitle;
  static List<SubtitleSearchResult> _subResults = const [];
  static String _category = 'sub';
  static ResumeStore? _resume;
  static double _subtitleSkewSeconds = 0;
  static double _subtitleSkewAfterSeconds = 0;

  static void _rememberSkew(VideoSource src) {
    _subtitleSkewSeconds = src.subtitleSkewSeconds ?? 0;
    _subtitleSkewAfterSeconds = src.subtitleSkewAfterSeconds ?? 0;
    if (_subtitleSkewSeconds.abs() >= 0.05) {
      debugPrint(
        '[zangetsu-sub-timing] pack skew '
        '${_subtitleSkewSeconds.toStringAsFixed(3)}s after '
        '${_subtitleSkewAfterSeconds.toStringAsFixed(3)}s',
      );
    }
  }
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
    if (!Platform.isIOS) return false;
    if (startIndex < 0 || startIndex >= episodes.length) return false;

    _resolve = resolveSources;
    _episodes = await _enrichEpisodes(
      episodes,
      malId: malId,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      anime: scrobbleTitle != null || malId != null,
    );
    _sourceId = sourceId;
    _showUrl = showUrl;
    _showId = showUrl ?? sourceId;
    _showTitle = showTitle ?? '';
    _cover = cover;
    _coverHeaders = coverHeaders;
    _malId = malId;
    _skipTitle = scrobbleTitle;
    _category = category;
    _resume = resume;
    if (!_handlerBound) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerBound = true;
    }

    final ep = _episodes[startIndex];
    final src = await _resolveSource(ep);
    if (src == null) return false;
    _rememberSkew(src);
    // Magnets / torrents are not streamed on Apple TV.
    if (src.url.toLowerCase().startsWith('magnet:') ||
        src.url.toLowerCase().endsWith('.torrent')) {
      return false;
    }
    debugPrint(
      '[zangetsu-sub-timing] launch cat=$category quality=${src.quality} '
      'kind=${src.kind} container=${src.container.name} '
      'subs=${src.subtitles.length} '
      'delayPrefs=${sl<PlaybackPrefs>().subtitleDelaySeconds.toStringAsFixed(3)} '
      'url=${src.url}',
    );
    for (var i = 0; i < src.subtitles.length; i++) {
      final s = src.subtitles[i];
      debugPrint(
        '[zangetsu-sub-timing] sourceSub[$i] default=${s.isDefault} '
        'lang=${s.lang} label=${s.label} fmt=${s.format} url=${s.url}',
      );
    }

    final prefs = sl<PlaybackPrefs>();
    final subStyle = captionStyleFromPrefs(
      scale: prefs.subtitleScale,
      colorHex: prefs.subtitleColorHex,
      bgOpacity: prefs.subtitleBgOpacity,
      font: prefs.subtitleFont,
      outlineType: prefs.subtitleOutlineType,
    );
    final subFontPath = await () async {
      await SubtitleFontService.instance.ensure(prefs.subtitleFont);
      return stageSubtitleFont(prefs.subtitleFont);
    }();

    final mark = resume.get(sourceId, _showId, ep.id);
    _announceWatching(
      ep,
      positionMs: mark?.position.inMilliseconds ?? 0,
      durationMs: mark?.duration.inMilliseconds ?? 0,
    );

    final warm = malId != null
        ? FillerService.instance.peekCache(malId)
        : null;
    final fillerFlags = _fillerFlags(_episodes, warm ?? const {});
    if (malId != null) {
      unawaited(
        FillerService.instance.fillerEpisodes(malId).then((s) async {
          if (s.isEmpty && warm == null) return;
          try {
            await _ch.invokeMethod<void>('setFillerInfo', {
              'fillerFlags': _fillerFlags(_episodes, s),
              'autoSkipFiller': prefs.autoSkipFiller,
            });
          } catch (_) {}
        }),
      );
    }

    Map<String, dynamic>? res;
    try {
      res = await _ch.invokeMapMethod<String, dynamic>('launch', {
        ..._streamPayload(src, mark?.position.inMilliseconds ?? 0),
        'playerMode': 'system',
        'title': _showTitle,
        'episodeLabel': _episodeLabel(ep),
        'episodeLabels': [for (final e in _episodes) _episodeLabel(e)],
        'episodeCount': _episodes.length,
        'startIndex': startIndex,
        'category': category,
        'availableCategories': availableCategories,
        'accentColor': AppColors.accent.toARGB32(),
        'defaultSpeed': prefs.defaultSpeed,
        'subtitleScale': subStyle.scale,
        'subtitleFgColor': subStyle.fgColor,
        'subtitleBgColor': subStyle.bgColor,
        'subtitleEdge': subStyle.edge,
        'subtitleEdgeType': subStyle.edgeType,
        'subtitleColorHex': prefs.subtitleColorHex,
        'subtitleOutlineType': prefs.subtitleOutlineType,
        'subtitleFontFamily': prefs.subtitleFont,
        'subtitlePositionPref': prefs.subtitlePosition,
        'subtitleBgOpacity': prefs.subtitleBgOpacity,
        'subtitleDelaySeconds': prefs.subtitleDelaySeconds,
        'subtitleFontPath': ?subFontPath,
        'subtitleApiKeySet': prefs.subtitleApiKey.trim().isNotEmpty,
        'megaSkip': prefs.megaSkip,
        'megaSkipSeconds': prefs.megaSkipSeconds,
        'skipIntro': prefs.skipIntro,
        'autoSkipOp': prefs.autoSkipOp,
        'autoSkipEd': prefs.autoSkipEd,
        'autoSkipRecap': prefs.autoSkipRecap,
        'autoSkipFiller': prefs.autoSkipFiller,
        'fillerFlags': fillerFlags,
      });
    } on PlatformException catch (e) {
      debugPrint('[TvAvNativePlayer] launch failed: $e');
      _announceBrowsing();
      return false;
    } on MissingPluginException {
      debugPrint('[TvAvNativePlayer] native player plugin missing');
      _announceBrowsing();
      return false;
    }

    final index = (res?['episodeIndex'] as num?)?.toInt() ?? startIndex;
    final posMs = (res?['positionMs'] as num?)?.toInt() ?? 0;
    final durMs = (res?['durationMs'] as num?)?.toInt() ?? 0;
    _saveProgress(index, posMs, durMs);
    _announceBrowsing();
    return true;
  }

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'resolveEpisode':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final category = (args['category'] as String?) ?? _category;
        if (index < 0 || index >= _episodes.length) return null;
        final ep = _episodes[index];
        final src = await _resolveSource(ep, category: category);
        if (src == null) return null;
        _rememberSkew(src);
        if (src.url.toLowerCase().startsWith('magnet:') ||
            src.url.toLowerCase().endsWith('.torrent')) {
          return null;
        }
        _category = category;
        final mark = _resume?.get(_sourceId, _showId, ep.id);
        _announceWatching(
          ep,
          positionMs: mark?.position.inMilliseconds ?? 0,
          durationMs: mark?.duration.inMilliseconds ?? 0,
        );
        return {
          ..._streamPayload(src, mark?.position.inMilliseconds ?? 0),
          'episodeLabel': _episodeLabel(ep),
        };
      case 'saveProgress':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final posMs = (args['positionMs'] as num?)?.toInt() ?? 0;
        final durMs = (args['durationMs'] as num?)?.toInt() ?? 0;
        _saveProgress(index, posMs, durMs);
        if (index >= 0 && index < _episodes.length) {
          _announceWatching(
            _episodes[index],
            positionMs: posMs,
            durationMs: durMs,
            playing: args['playing'] as bool? ?? true,
          );
        }
        return null;
      case 'setCategory':
        final cat = (call.arguments as Map)['category'] as String?;
        if (cat != null) {
          _category = cat;
          if (_showUrl != null) {
            await sl<TitlePrefsStore>().setCategory(_sourceId, _showUrl!, cat);
          }
        }
        return null;
      case 'setSubtitleScale':
        final s = (call.arguments as Map)['scale'] as num?;
        if (s != null) await sl<PlaybackPrefs>().setSubtitleScale(s.toDouble());
        return null;
      case 'setSubtitleColorHex':
        final hex = (call.arguments as Map)['hex'] as String?;
        if (hex != null) await sl<PlaybackPrefs>().setSubtitleColorHex(hex);
        return null;
      case 'setSubtitleBgOpacity':
        final o = (call.arguments as Map)['opacity'] as num?;
        if (o != null) {
          await sl<PlaybackPrefs>().setSubtitleBgOpacity(o.toDouble());
        }
        return null;
      case 'setSubtitleOutlineType':
        final t = (call.arguments as Map)['type'] as String?;
        if (t != null) await sl<PlaybackPrefs>().setSubtitleOutlineType(t);
        return null;
      case 'setSubtitleFont':
        final f = (call.arguments as Map)['font'] as String?;
        if (f != null) await sl<PlaybackPrefs>().setSubtitleFont(f);
        return null;
      case 'setSubtitlePosition':
        final p = (call.arguments as Map)['position'] as num?;
        if (p != null) await sl<PlaybackPrefs>().setSubtitlePosition(p.toInt());
        return null;
      case 'setDefaultSpeed':
        final s = (call.arguments as Map)['speed'] as num?;
        if (s != null) await sl<PlaybackPrefs>().setDefaultSpeed(s.toDouble());
        return null;
      case 'setSubtitleDelay':
        final d = (call.arguments as Map)['seconds'] as num?;
        if (d != null) {
          await sl<PlaybackPrefs>().setSubtitleDelaySeconds(d.toDouble());
        }
        return null;
      case 'stageSubtitleFont':
        final font = (call.arguments as Map)['font'] as String? ?? '';
        if (font.isEmpty) return null;
        await SubtitleFontService.instance.ensure(font);
        return await stageSubtitleFont(font);
      case 'searchSubtitles':
        final pref = sl<PlaybackPrefs>().subtitlePreference;
        final lang = (pref.isEmpty || pref == 'off') ? 'en' : pref;
        try {
          _subResults = await SubtitleSearchService().search(
            _showTitle,
            language: lang,
          );
        } catch (_) {
          _subResults = const [];
        }
        return [
          for (final r in _subResults) {'name': r.name, 'language': r.language},
        ];
      case 'downloadSubtitle':
        final idx = ((call.arguments as Map)['index'] as num?)?.toInt() ?? -1;
        if (idx < 0 || idx >= _subResults.length) return null;
        try {
          final r = _subResults[idx];
          final path = await SubtitleSearchService().download(r);
          return {
            'path': path,
            'language': r.language,
            'name': r.name,
            'format': r.format,
          };
        } catch (_) {
          return null;
        }
      case 'fetchSubtitle':
        // Native AVKit loads provider/online cue files through Dart so we get
        // the same Dio/headers path that Android Exo uses (many hosts 403
        // bare URLSession).
        final args = (call.arguments as Map).cast<String, dynamic>();
        final url = args['url'] as String?;
        if (url == null || url.isEmpty) return null;
        debugPrint('[zangetsu-sub-timing] fetchSubtitle GET $url');
        final hdrs = <String, String>{};
        final rawH = args['headers'];
        if (rawH is Map) {
          rawH.forEach((k, v) => hdrs['$k'] = '$v');
        }
        try {
          final dio = Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.plain,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/122.0.0.0 Safari/537.36',
                ...hdrs,
              },
            ),
          );
          final res = await dio.get<String>(url);
          final text = res.data;
          if (text == null || text.trim().isEmpty) {
            debugPrint('[zangetsu-sub-timing] fetchSubtitle empty response');
            return null;
          }
          var out = text;
          if (_subtitleSkewSeconds.abs() >= 0.05) {
            var skew = _subtitleSkewSeconds;
            var after = _subtitleSkewAfterSeconds;
            // Blend pack intro.end delta with VTT-OP-gap delta. Marker-only
            // (~13s) ran a few seconds late; gap-only (~9s) a few seconds early.
            final playingIntroEnd = after + skew;
            final gapOnly = refineSubtitleSkewWithVttGap(
              vttText: text,
              playingIntroEnd: playingIntroEnd,
            );
            if (gapOnly != null) {
              final blended = (skew + gapOnly.seconds) / 2;
              debugPrint(
                '[zangetsu-sub-timing] fetchSubtitle blend pack skew '
                'markers=${skew.toStringAsFixed(3)}s gap=${gapOnly.seconds.toStringAsFixed(3)}s '
                '→ ${blended.toStringAsFixed(3)}s '
                '(VTT OP resume ${gapOnly.afterSeconds.toStringAsFixed(3)}s, '
                'intro.end ${playingIntroEnd.toStringAsFixed(3)}s)',
              );
              skew = blended;
              // Keep marker `after` so title cards between pack intro.end and
              // first post-OP cue also shift.
              _subtitleSkewSeconds = skew;
            }
            out = applySubtitleSkewToText(
              text,
              skewSeconds: skew,
              afterSeconds: after,
            );
            debugPrint(
              '[zangetsu-sub-timing] fetchSubtitle applied pack skew '
              '${skew.toStringAsFixed(3)}s after ${after.toStringAsFixed(3)}s',
            );
          }
          debugPrint(
            '[zangetsu-sub-timing] fetchSubtitle OK ${out.length} chars',
          );
          return {'text': out};
        } catch (e) {
          debugPrint('[zangetsu-sub-timing] fetchSubtitle failed: $e');
          return null;
        }
      case 'probeHlsEpoch':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final url = args['url'] as String?;
        if (url == null || url.isEmpty) {
          return {'seconds': 0.0, 'reason': 'missing url'};
        }
        final hdrs = <String, String>{};
        final rawH = args['headers'];
        if (rawH is Map) {
          rawH.forEach((k, v) => hdrs['$k'] = '$v');
        }
        return _probeHlsEpoch(url, hdrs);
      case 'probeVttEncodeSkew':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final streamUrl = args['streamUrl'] as String? ?? '';
        final subtitleUrl = args['subtitleUrl'] as String? ?? '';
        final streamDuration = (args['streamDuration'] as num?)?.toDouble() ?? 0;
        final hdrs = <String, String>{};
        final rawH = args['headers'];
        if (rawH is Map) {
          rawH.forEach((k, v) => hdrs['$k'] = '$v');
        }
        return _probeVttEncodeSkew(streamUrl, subtitleUrl, streamDuration, hdrs);
      case 'subtitleTimingLog':
        final msg = (call.arguments as Map?)?['message'] as String?;
        if (msg != null) debugPrint('[zangetsu-sub-timing] $msg');
        return null;
      case 'sourcesFor':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final category = (args['category'] as String?) ?? _category;
        if (index < 0 || index >= _episodes.length) return const <Map>[];
        try {
          final sources = await _resolve!(
            tvEpisodeUrl(_episodes[index].url, category),
          );
          return [
            for (var i = 0; i < sources.length; i++)
              {..._srcMap(sources[i]), 'label': _srcLabel(sources[i], i)},
          ];
        } catch (_) {
          return const <Map>[];
        }
      case 'skipsFor':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final durMs = (args['durationMs'] as num?)?.toInt() ?? 0;
        if (_skipTitle == null || index < 0 || index >= _episodes.length) {
          return const <Map>[];
        }
        final ep = _episodes[index];
        final epNo = ep.number?.toInt() ?? (index + 1);
        try {
          final skips = await sl<SkipService>().skipTimes(
            title: _skipTitle!,
            episode: epNo,
            duration: Duration(milliseconds: durMs),
          );
          return [
            for (final s in skips)
              {
                'start': s.start.inMilliseconds,
                'end': s.end.inMilliseconds,
                'type': s.type,
              },
          ];
        } catch (_) {
          return const <Map>[];
        }
    }
    return null;
  }

  static String _srcLabel(VideoSource src, int i) {
    final l = src.label?.trim();
    if (l != null && l.isNotEmpty) return l;
    final q = src.quality?.trim();
    if (q != null && q.isNotEmpty) return q;
    return 'Server ${i + 1}';
  }

  static Map<String, dynamic> _srcMap(VideoSource src) => {
    'url': src.url,
    'headers': src.headers ?? const <String, String>{},
    'mimeType': _mimeFor(src),
    'quality': src.quality ?? '',
    'subtitleSkewSeconds': src.subtitleSkewSeconds ?? 0.0,
    'subtitleSkewAfterSeconds': src.subtitleSkewAfterSeconds ?? 0.0,
    'subtitles': [
      for (final s in src.subtitles)
        {
          'url': s.url,
          'lang': s.lang,
          'label': s.label ?? s.lang,
          'format': s.format ?? '',
        },
    ],
  };

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
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _streamPayload(VideoSource src, int positionMs) =>
      {..._srcMap(src), 'positionMs': positionMs};

  static void _saveProgress(int index, int posMs, int durMs) {
    if (index < 0 || index >= _episodes.length || durMs <= 0 || posMs <= 0) {
      return;
    }
    final ep = _episodes[index];
    _resume?.save(
      _sourceId,
      _showId,
      ep.id,
      Duration(milliseconds: posMs),
      Duration(milliseconds: durMs),
    );
    sl<WatchHistory>().save(
      HistoryEntry(
        sourceId: _sourceId,
        showId: _showId,
        showTitle: _showTitle,
        cover: _cover,
        coverHeaders: _coverHeaders,
        showUrl: _showUrl ?? '',
        category: _category,
        episodeId: ep.id,
        episodeNumber: ep.number,
        episodeUrl: ep.url,
        position: Duration(milliseconds: posMs),
        duration: Duration(milliseconds: durMs),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        malId: _malId,
      ),
      flush: true,
    );
    debugPrint('[TvAvNativePlayer] saved ep=${ep.id} pos=$posMs');
  }

  static void _announceWatching(
    Episode ep, {
    int positionMs = 0,
    int durationMs = 0,
    bool playing = true,
  }) {
    if (_showTitle.isEmpty || !sl.isRegistered<DiscordRpc>()) return;
    if (durationMs <= 0) return;
    unawaited(
      sl<DiscordRpc>().setWatching(
        title: _showTitle,
        episodeLabel: discordEpisodeLabel(ep),
        posterUrl: _cover,
        position: Duration(milliseconds: positionMs),
        duration: Duration(milliseconds: durationMs),
        playing: playing,
      ),
    );
  }

  static void _announceBrowsing() {
    if (!sl.isRegistered<DiscordRpc>()) return;
    sl<DiscordRpc>().clear(delay: DiscordRpc.playerExitClearDelay);
  }

  static String _episodeLabel(Episode ep) => episodePresenceDetails(ep) ?? '';

  static List<bool> _fillerFlags(List<Episode> episodes, Set<int> fillers) {
    if (fillers.isEmpty) return List<bool>.filled(episodes.length, false);
    return [for (final e in episodes) fillers.contains(e.number?.toInt())];
  }

  static const Duration _metaWait = Duration(seconds: 2);

  static Future<List<Episode>> _enrichEpisodes(
    List<Episode> episodes, {
    int? malId,
    int? tmdbId,
    bool tmdbIsTv = false,
    bool anime = false,
  }) async {
    if (!sl.isRegistered<EpisodeMetadataService>()) return episodes;
    try {
      return await sl<EpisodeMetadataService>()
          .enrich(
            episodes: episodes,
            type: anime ? ProviderType.anime : ProviderType.movie,
            malId: malId,
            tmdbId: tmdbId,
            tmdbIsTv: tmdbIsTv,
          )
          .timeout(_metaWait);
    } catch (_) {
      return episodes;
    }
  }

  static String? _mimeFor(VideoSource src) {
    final u = src.url.toLowerCase();
    if (src.container == SourceContainer.hls || u.contains('.m3u8')) {
      return 'application/x-mpegURL';
    }
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.contains('.mp4')) return 'video/mp4';
    return null;
  }

  static const _cdnUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  /// Media-timeline origin for HLS sideloaded VTT mapping.
  /// Returns `{seconds, reason}` from fMP4 tfdt, MPEG-TS PTS, or EXT-X-START.
  static Future<Map<String, dynamic>> _probeHlsEpoch(
    String url,
    Map<String, String> headers,
  ) async {
    debugPrint('[zangetsu-sub-timing] HLS epoch probe GET $url');
    try {
      final textDio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.plain,
          headers: {'User-Agent': _cdnUserAgent, ...headers},
        ),
      );
      var playlistUrl = url;
      var text = (await textDio.get<String>(playlistUrl)).data;
      if (text == null || text.trim().isEmpty) {
        return {'seconds': 0.0, 'reason': 'playlist fetch failed'};
      }
      if (hlsPlaylistIsMaster(text)) {
        final next = hlsFirstUriLine(text);
        if (next == null) {
          return {'seconds': 0.0, 'reason': 'no variant URI'};
        }
        playlistUrl = Uri.parse(playlistUrl).resolve(next).toString();
        debugPrint('[zangetsu-sub-timing] HLS epoch variant $playlistUrl');
        text = (await textDio.get<String>(playlistUrl)).data;
        if (text == null || text.trim().isEmpty) {
          return {'seconds': 0.0, 'reason': 'variant fetch failed'};
        }
      }
      if (hlsPlaylistIsEncrypted(text)) {
        return {'seconds': 0.0, 'reason': 'encrypted segments'};
      }
      final startTag = hlsExtXStartOffset(text);
      final mapUri = hlsExtXMapUri(text);
      final segments = hlsMediaSegments(text, max: 4096);
      debugPrint(
        '[zangetsu-sub-timing] HLS tags ${hlsPlaylistTagSummary(text)}',
      );
      if (segments.isEmpty) {
        return {'seconds': 0.0, 'reason': 'no segment URI'};
      }
      final discPad = hlsLeadingDiscontinuitySeconds(segments);
      final dateRange = hlsDateRangeDuration(text);
      final totalExtinf = segments.fold<double>(0, (a, s) => a + s.duration);
      final firstExtinf = segments
          .take(12)
          .map((s) => s.duration.toStringAsFixed(3))
          .join(',');
      final discIdx = [
        for (var i = 0; i < segments.length; i++)
          if (segments[i].discontinuity) i,
      ];
      debugPrint(
        '[zangetsu-sub-timing] HLS media nSeg=${segments.length} '
        'sumEXTINF=${totalExtinf.toStringAsFixed(3)}s '
        'START=${startTag?.toStringAsFixed(3) ?? "-"} '
        'discPad=${discPad?.toStringAsFixed(3) ?? "-"} '
        'discAt=${discIdx.isEmpty ? "none" : discIdx.join(",")} '
        'dateRange=${dateRange?.toStringAsFixed(3) ?? "-"} '
        'firstEXTINF=[$firstExtinf]',
      );

      Future<Uint8List?> fetchPrefix(String u) async {
        try {
          final bytesDio = Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.bytes,
              validateStatus: (code) => code != null && code >= 200 && code < 400,
              headers: {
                'User-Agent': _cdnUserAgent,
                'Range': 'bytes=0-1048575',
                ...headers,
              },
            ),
          );
          final res = await bytesDio.get<List<int>>(u);
          final raw = res.data;
          if (raw == null || raw.isEmpty) return null;
          return Uint8List.fromList(raw);
        } on DioException catch (e) {
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch fetch ${e.response?.statusCode ?? e.type} $u',
          );
          return null;
        } catch (e) {
          debugPrint('[zangetsu-sub-timing] HLS epoch fetch error $e');
          return null;
        }
      }

      bool looksLikeAdUrl(String u) {
        final lower = u.toLowerCase();
        return lower.contains('ad-site') ||
            lower.contains('ibyteimg.com') ||
            lower.contains('/ads/') ||
            lower.contains('advert') ||
            lower.contains('preroll');
      }

      Uint8List? initBytes;
      if (mapUri != null) {
        final initUrl = Uri.parse(playlistUrl).resolve(mapUri).toString();
        debugPrint('[zangetsu-sub-timing] HLS epoch init $initUrl');
        initBytes = await fetchPrefix(initUrl);
      }

      final toFetch = <int>{};
      var elapsed = 0.0;
      for (var i = 0; i < segments.length; i++) {
        final abs = Uri.parse(playlistUrl).resolve(segments[i].uri).toString();
        if (looksLikeAdUrl(abs)) {
          elapsed += segments[i].duration;
          continue;
        }
        if (toFetch.isEmpty) toFetch.add(i); // first non-ad
        if (elapsed >= 11 && elapsed <= 20) toFetch.add(i);
        elapsed += segments[i].duration;
      }
      // Prefer a few early content segments even if the first is an ad.
      for (var i = 0; i < segments.length && toFetch.length < 4; i++) {
        final abs = Uri.parse(playlistUrl).resolve(segments[i].uri).toString();
        if (!looksLikeAdUrl(abs)) toFetch.add(i);
      }

      MpegTsInspect? firstInspect;
      double? ptsMinusPlaylist;
      double? firstEpoch;
      var probedFirstContent = false;
      for (final idx in toFetch.toList()..sort()) {
        final seg = segments[idx];
        final segUrl = Uri.parse(playlistUrl).resolve(seg.uri).toString();
        debugPrint('[zangetsu-sub-timing] HLS epoch segment[$idx] $segUrl');
        final segBytes = await fetchPrefix(segUrl);
        if (segBytes == null || segBytes.isEmpty) continue;
        debugPrint(
          '[zangetsu-sub-timing] HLS epoch magic[$idx] ${hlsSegmentMagic(segBytes)} '
          '(${segBytes.length}B)',
        );
        final media = hlsUnwrapSegment(segBytes) ??
            (initBytes != null ? hlsUnwrapSegment(initBytes) : null);
        if (media == null) continue;
        if (!identical(media, segBytes)) {
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch unwrapped[$idx] '
            '+${segBytes.length - media.length}B prefix → ${hlsSegmentMagic(media)}',
          );
        }
        final unwrappedInit = initBytes == null
            ? null
            : (hlsUnwrapSegment(initBytes) ?? initBytes);

        if (isoLooksLikeFmp4(media) ||
            (unwrappedInit != null && isoLooksLikeFmp4(unwrappedInit))) {
          final t = fmp4BaseMediaTimeSeconds(unwrappedInit ?? media, media);
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch fMP4[$idx] '
            'tfdt=${t?.toStringAsFixed(3) ?? "none"}s',
          );
          if (t != null && t >= 8 && t <= 30) {
            return {'seconds': t, 'reason': 'fMP4 tfdt'};
          }
        }

        final inspect = mpegTsInspect(media);
        debugPrint('[zangetsu-sub-timing] HLS epoch TS[$idx] ${inspect.summary}');
        if (inspect.ptsSamples.isNotEmpty) {
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch PTS samples[$idx] '
            '${inspect.ptsSamples.map((t) => t.toStringAsFixed(3)).join(",")}',
          );
        }
        firstInspect ??= inspect;
        var playlistT = 0.0;
        for (var j = 0; j < idx; j++) {
          playlistT += segments[j].duration;
        }
        final origin = inspect.videoPts ?? inspect.audioPts;
        if (origin != null) {
          final delta = origin - playlistT;
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch pts-playlist[$idx] '
            'pts=${origin.toStringAsFixed(3)} playlist=${playlistT.toStringAsFixed(3)} '
            'delta=${delta.toStringAsFixed(3)}',
          );
          if (delta >= 8 && delta <= 30) {
            ptsMinusPlaylist ??= delta;
          }
        }
        if (!probedFirstContent) {
          probedFirstContent = true;
          final tsEpoch = inspect.epoch;
          debugPrint(
            '[zangetsu-sub-timing] HLS epoch candidate[$idx] '
            '${tsEpoch == null ? "none (clocks ~0, not Apple padding)" : "${tsEpoch.toStringAsFixed(3)}s ${inspect.summary}"}',
          );
          firstEpoch = tsEpoch;
        }
      }

      if (firstEpoch != null) {
        return {
          'seconds': firstEpoch,
          'reason': 'MPEG-TS ${firstInspect?.summary}',
        };
      }

      if (ptsMinusPlaylist != null) {
        return {
          'seconds': ptsMinusPlaylist,
          'reason': 'PTS−playlist ${ptsMinusPlaylist.toStringAsFixed(3)}s',
        };
      }
      if (discPad != null) {
        return {'seconds': discPad, 'reason': 'EXT-X-DISCONTINUITY bumper'};
      }
      if (dateRange != null) {
        return {'seconds': dateRange, 'reason': 'EXT-X-DATERANGE'};
      }
      if (startTag != null && startTag.abs() >= 8 && startTag.abs() <= 30) {
        return {'seconds': startTag.abs(), 'reason': 'EXT-X-START'};
      }
      debugPrint(
        '[zangetsu-sub-timing] HLS epoch none — media clock ~0, '
        'playlist ${totalExtinf.toStringAsFixed(3)}s, '
        '${firstInspect?.summary ?? "no TS"}',
      );
      return {
        'seconds': 0.0,
        'reason': 'TS ${firstInspect?.summary ?? "no inspect"}',
      };
    } catch (e) {
      final short = e is DioException
          ? 'HTTP ${e.response?.statusCode ?? e.type.name}'
          : '$e';
      debugPrint('[zangetsu-sub-timing] HLS epoch probe failed: $short');
      return {'seconds': 0.0, 'reason': 'probe failed: $short'};
    }
  }

  /// When sidecar VTT lives under a different CDN encode folder than the
  /// playing HLS, align EXTINF sequences to find *leading* content only.
  /// Raw duration delta is usually extra credits at the tail — do not apply it.
  static Future<Map<String, dynamic>> _probeVttEncodeSkew(
    String streamUrl,
    String subtitleUrl,
    double streamDuration,
    Map<String, String> headers,
  ) async {
    final videoId = hlsCdnEncodeId(streamUrl);
    final subId = hlsCdnEncodeId(subtitleUrl);
    debugPrint(
      '[zangetsu-sub-timing] encode ids video=${videoId ?? "-"} '
      'sub=${subId ?? "-"} streamDur=${streamDuration.toStringAsFixed(3)}',
    );
    if (videoId == null || subId == null) {
      return {'seconds': 0.0, 'reason': 'no encode ids in URLs'};
    }
    if (videoId == subId) {
      debugPrint('[zangetsu-sub-timing] encode ids match — same pack');
      return {'seconds': 0.0, 'reason': 'same encode'};
    }

    final textDio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
        headers: {'User-Agent': _cdnUserAgent, ...headers},
      ),
    );

    Future<String?> getText(String url, String label) async {
      debugPrint('[zangetsu-sub-timing] $label GET $url');
      try {
        final res = await textDio.get<String>(url);
        final code = res.statusCode ?? 0;
        final text = res.data;
        if (code >= 400 || text == null || text.trim().isEmpty) {
          debugPrint('[zangetsu-sub-timing] $label HTTP $code $url');
          return null;
        }
        return text;
      } catch (e) {
        debugPrint('[zangetsu-sub-timing] $label failed $url: $e');
        return null;
      }
    }

    Future<Map<String, String>> collectMedia(
      String seed,
      String label,
    ) async {
      final out = <String, String>{};

      Future<void> ingest(String url, String body) async {
        if (hlsPlaylistIsMaster(body)) {
          debugPrint(
            '[zangetsu-sub-timing] $label master '
            '${hlsPlaylistPreview(body, maxLines: 16)}',
          );
          for (final v in hlsVariantUrisOrdered(body, url)) {
            if (out.containsKey(v)) continue;
            final nested = await getText(v, '$label variant');
            if (nested == null || hlsPlaylistIsMaster(nested)) continue;
            out[v] = nested;
          }
          return;
        }
        out[url] = body;
      }

      final seedBody = await getText(seed, label);
      if (seedBody != null) await ingest(seed, seedBody);
      final master = seed.replaceFirst(RegExp(r'[^/]+$'), 'master.m3u8');
      if (master != seed) {
        final masterBody = await getText(master, '$label master');
        if (masterBody != null) await ingest(master, masterBody);
      }
      return out;
    }

    void logFingerprints(String label, Map<String, String> playlists) {
      if (playlists.isEmpty) {
        debugPrint('[zangetsu-sub-timing] $label: none');
        return;
      }
      for (final e in playlists.entries) {
        final name = Uri.tryParse(e.key)?.pathSegments.last ?? e.key;
        final segs = hlsMediaSegments(e.value, max: 8192);
        debugPrint(
          '[zangetsu-sub-timing] $label $name ${hlsExtinfFingerprint(segs)}',
        );
      }
    }

    final playingMaps = await collectMedia(streamUrl, 'playing playlist');
    logFingerprints('playing', playingMaps);
    if (playingMaps.isEmpty) {
      return {'seconds': 0.0, 'reason': 'playing playlist unreachable'};
    }

    final swapped = hlsCdnSwapEncode(streamUrl, subId);
    final vttMaster = swapped == null
        ? null
        : swapped.replaceFirst(RegExp(r'[^/]+$'), 'master.m3u8');
    debugPrint(
      '[zangetsu-sub-timing] VTT encode differs from video — probing '
      'sibling playlists (all renditions)',
    );
    final vttSeed = swapped ?? vttMaster;
    if (vttSeed == null) {
      return {'seconds': 0.0, 'reason': 'VTT-encode playlist unreachable'};
    }
    final vttMaps = await collectMedia(vttSeed, 'VTT-encode playlist');
    logFingerprints('VTT-encode', vttMaps);
    if (vttMaps.isEmpty) {
      return {'seconds': 0.0, 'reason': 'VTT-encode playlist unreachable'};
    }

    final hits = <String, double>{};
    for (final play in playingMaps.entries) {
      final playName = Uri.tryParse(play.key)?.pathSegments.last ?? play.key;
      final playDurs = [
        for (final s in hlsMediaSegments(play.value, max: 8192)) s.duration,
      ];
      final playDur = playDurs.fold<double>(0, (a, b) => a + b);
      for (final vtt in vttMaps.entries) {
        final vttName = Uri.tryParse(vtt.key)?.pathSegments.last ?? vtt.key;
        final vttDurs = [
          for (final s in hlsMediaSegments(vtt.value, max: 8192)) s.duration,
        ];
        final vttDur = vttDurs.fold<double>(0, (a, b) => a + b);
        final lead = hlsLeadingExtinfSkew(playDurs, vttDurs);
        final delta = playDur - vttDur;
        debugPrint(
          '[zangetsu-sub-timing] EXTINF pair $playName vs $vttName '
          'skew=${lead == null ? "no-match" : "${lead.toStringAsFixed(3)}s"} '
          'durDelta=${delta.toStringAsFixed(3)}s',
        );
        if (lead != null) hits['$playName|$vttName'] = lead;
      }
    }

    final inRange = hits.entries
        .where((e) => e.value.abs() >= 8 && e.value.abs() <= 30)
        .toList();
    if (inRange.length == 1) {
      final lead = inRange.first.value;
      return {
        'seconds': lead,
        'reason': 'EXTINF leading ${lead.toStringAsFixed(3)}s '
            'via ${inRange.first.key}',
      };
    }
    if (inRange.length > 1) {
      final values = inRange.map((e) => e.value).toList();
      final same = values.every((v) => (v - values.first).abs() < 0.2);
      if (same) {
        return {
          'seconds': values.first,
          'reason': 'EXTINF leading ${values.first.toStringAsFixed(3)}s '
              '(${inRange.length} pairs)',
        };
      }
      debugPrint(
        '[zangetsu-sub-timing] EXTINF leading ambiguous: '
        '${inRange.map((e) => "${e.key}=${e.value.toStringAsFixed(3)}").join("; ")}',
      );
    }

    final zero = hits.values.where((v) => v.abs() < 0.2).length;
    return {
      'seconds': 0.0,
      'reason': hits.isEmpty
          ? 'no EXTINF alignment across renditions'
          : zero > 0
              ? 'EXTINF aligned at start on $zero pair(s); '
                  'duration gap is tail — not applied'
              : 'no 8–30s EXTINF leading skew',
    };
  }
}
