import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_font_stage.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/torrent/torrent_service.dart';
import '../../core/torrent/torrent_util.dart';

/// Launches and services the fully-native TV player (TvPlayerActivity —
/// real-window ExoPlayer/SurfaceView) instead of the Flutter platform-view
/// player, for TVs that black-screen the embedded surface.
///
/// The channel is bidirectional on `zangetsu/tv_player`:
///  - Dart → native `launch`      : open the player with the first episode ready.
///  - native → Dart `resolveEpisode`: resolve a stream on demand (episode switch,
///                                     Next Episode) using the SAME resolver +
///                                     [pickDefault] the Flutter player uses.
///  - native → Dart `saveProgress` : persist resume + Continue Watching for an
///                                     episode (on switch and on exit).
///
/// Resolution and persistence stay entirely in Dart; nothing here touches the
/// phone (media_kit) player.
class TvNativePlayer {
  static const _ch = MethodChannel('zangetsu/tv_player');
  static bool _handlerBound = false;

  // Current session context — set on [play], read by the native→Dart handlers.
  // Only one native player is on screen at a time, so a plain static context is
  // enough (a new play() overwrites it).
  static Future<List<VideoSource>> Function(String episodeUrl)? _resolve;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String? _skipTitle; // anime title for AniSkip (null = no skips)
  static List<SubtitleSearchResult> _subResults = const []; // last online search
  static String _category = 'sub';
  static ResumeStore? _resume;
  static String? _torrentId; // active torrent stream (stopped on switch/close)

  /// Returns `false` when the episode could not be resolved or started (no
  /// sources, torrent blocked, etc.). Callers should surface that to the user;
  /// this method itself has no UI.
  static Future<bool> play({
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
  }) async {
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
    final playUrl = await _playableUrl(src.url);
    if (playUrl == null) return false; // torrent failed / Wi-Fi-only
    final mark = resume.get(sourceId, _showId, ep.id);

    // Full subtitle style, computed the SAME way as the Flutter PlatformView TV
    // player so both render identically (colour, box, outline, position, font).
    final prefs = sl<PlaybackPrefs>();
    final subStyle = captionStyleFromPrefs(
      scale: prefs.subtitleScale,
      colorHex: prefs.subtitleColorHex,
      bgOpacity: prefs.subtitleBgOpacity,
      position: prefs.subtitlePosition,
      font: prefs.subtitleFont,
    );
    final subFontPath = await stageSubtitleFont(prefs.subtitleFont);

    // Discord Rich Presence: the native Activity runs outside the Flutter
    // engine and can't reach the Dart Discord service, so announce "Watching"
    // from here — mirroring the phone player (player_controller.dart).
    // Wait for native STATE_READY when duration is unknown. Sending Watching
    // with end=null first is often the update Discord keeps (rate-limited).
    _announceWatching(
      ep,
      positionMs: mark?.position.inMilliseconds ?? 0,
      durationMs: mark?.duration.inMilliseconds ?? 0,
    );

    final res = await _ch.invokeMapMethod<String, dynamic>('launch', {
      ..._streamPayload(src, mark?.position.inMilliseconds ?? 0),
      'url': playUrl, // torrent → local stream URL; otherwise unchanged
      'title': _showTitle,
      'episodeLabel': _episodeLabel(ep),
      'episodeLabels': [for (final e in _episodes) _episodeLabel(e)],
      'episodeCount': episodes.length,
      'startIndex': startIndex,
      'category': category,
      'availableCategories': availableCategories,
      'accentColor': AppColors.accent.toARGB32(),
      'softwareDecoding': prefs.tvSoftwareDecoding,
      // Playback + subtitle-style defaults from the shared prefs.
      'defaultSpeed': prefs.defaultSpeed,
      'volumeBoost': prefs.volumeBoost,
      'subtitleScale': subStyle.scale,
      'subtitleFgColor': subStyle.fgColor,
      'subtitleBgColor': subStyle.bgColor,
      'subtitleEdge': subStyle.edge,
      'subtitlePosition': subStyle.position,
      'subtitleFontPath': ?subFontPath,
      'subtitleApiKeySet': prefs.subtitleApiKey.trim().isNotEmpty,
      'megaSkip': prefs.megaSkip,
      'megaSkipSeconds': prefs.megaSkipSeconds,
      'skipIntro': prefs.skipIntro,
      'autoSkipOp': prefs.autoSkipOp,
      'autoSkipEd': prefs.autoSkipEd,
    });

    // Player closed — stop any active torrent stream.
    _stopTorrent();
    // On close the native side returns the FINAL episode + position, so a session
    // that switched episodes saves progress against the right one.
    final index = (res?['episodeIndex'] as num?)?.toInt() ?? startIndex;
    final posMs = (res?['positionMs'] as num?)?.toInt() ?? 0;
    final durMs = (res?['durationMs'] as num?)?.toInt() ?? 0;
    _saveProgress(index, posMs, durMs);
    // Player closed → drop Watching, then restore browsing. The detail screen
    // stays mounted underneath and won't re-fire it.
    _announceBrowsing();
    return true;
  }

  /// Handles native→Dart calls while the player is on screen.
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
        final playUrl = await _playableUrl(src.url);
        if (playUrl == null) return null;
        _category = category;
        final mark = _resume?.get(_sourceId, _showId, ep.id);
        // Episode switch / Next Episode → advance the Discord "Watching" line.
        _announceWatching(
          ep,
          positionMs: mark?.position.inMilliseconds ?? 0,
          durationMs: mark?.duration.inMilliseconds ?? 0,
        );
        return {
          ..._streamPayload(src, mark?.position.inMilliseconds ?? 0),
          'url': playUrl,
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
        // The native player switched sub/dub — remember it for this title so the
        // next launch opens in the same version (mirrors the ExoPlayer player).
        final cat = (call.arguments as Map)['category'] as String?;
        if (cat != null) {
          _category = cat;
          if (_showUrl != null) {
            await sl<TitlePrefsStore>().setCategory(_sourceId, _showUrl!, cat);
          }
        }
        return null;
      case 'setSubtitleScale':
        // In-player subtitle-size change — persist so it sticks next launch.
        final s = (call.arguments as Map)['scale'] as num?;
        if (s != null) await sl<PlaybackPrefs>().setSubtitleScale(s.toDouble());
        return null;
      case 'searchSubtitles':
        // OpenSubtitles search for the current show; results cached for download.
        final pref = sl<PlaybackPrefs>().subtitlePreference;
        final lang = (pref.isEmpty || pref == 'off') ? 'en' : pref;
        try {
          _subResults = await SubtitleSearchService().search(_showTitle, language: lang);
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
      case 'resolveTorrent':
        // A magnet/.torrent picked from the Sources menu → local stream URL.
        final url = (call.arguments as Map)['url'] as String?;
        return url == null ? null : await _playableUrl(url);
      case 'sourcesFor':
        // The full mirror list for the Server/Source picker.
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final category = (args['category'] as String?) ?? _category;
        if (index < 0 || index >= _episodes.length) return const <Map>[];
        try {
          final sources = await _resolve!(tvEpisodeUrl(_episodes[index].url, category));
          return [
            for (var i = 0; i < sources.length; i++)
              {..._srcMap(sources[i]), 'label': _srcLabel(sources[i], i)},
          ];
        } catch (_) {
          return const <Map>[];
        }
      case 'skipsFor':
        // AniSkip intro/outro intervals for the current episode (anime only).
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

  /// Human label for a mirror in the Server picker: the provider's own name,
  /// else the quality, else "Server N".
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
        // The mobile Quality menu keys off per-source quality; carry it through so
        // the native Quality menu can list distinct resolutions.
        'quality': src.quality ?? '',
        // ClearKey DRM (base64url kid/key) for encrypted CENC/DASH channels; the
        // native TV player builds an ExoPlayer clearkey session when present.
        if (src.isDrm) 'drmKid': src.drmKid,
        if (src.isDrm) 'drmKey': src.drmKey,
        'subtitles': [
          for (final s in src.subtitles)
            {'url': s.url, 'lang': s.lang, 'label': s.label ?? s.lang},
        ],
      };

  static Future<VideoSource?> _resolveSource(Episode ep, {String? category}) async {
    final cat = category ?? _category;
    try {
      final sources = await _resolve!(tvEpisodeUrl(ep.url, cat));
      return pickDefault(sources, prefer: cat == 'dub' ? AudioKind.dub : AudioKind.sub);
    } catch (_) {
      return null;
    }
  }

  /// A URL ExoPlayer can play: a magnet/.torrent is streamed through the shared
  /// [TorrentService] (libtorrent → a local http:// stream) exactly like the phone
  /// player does; anything else passes through unchanged. Returns null on
  /// torrent failure / Wi-Fi-only.
  static Future<String?> _playableUrl(String url) async {
    if (!isTorrentUrl(url)) return url;
    _stopTorrent();
    try {
      final t = await sl<TorrentService>().startStream(
        url,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
      );
      _torrentId = t.id;
      return t.localUrl;
    } catch (_) {
      return null;
    }
  }

  static void _stopTorrent() {
    final id = _torrentId;
    if (id != null) {
      sl<TorrentService>().stop(id);
      _torrentId = null;
    }
  }

  static Map<String, dynamic> _streamPayload(VideoSource src, int positionMs) => {
        ..._srcMap(src),
        'positionMs': positionMs,
      };

  static void _saveProgress(int index, int posMs, int durMs) {
    if (index < 0 || index >= _episodes.length || durMs <= 0 || posMs <= 0) return;
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
    debugPrint('[TvNativePlayer] saved ep=${ep.id} pos=$posMs');
  }

  /// Push a "Watching" Discord presence (show + episode) for [ep]. The native
  /// TV Activity can't reach Discord itself, so the Dart isolate announces on
  /// launch and on every episode switch — same shape as the phone player
  /// (player_controller.dart). No-op when Discord isn't wired up / a title is
  /// missing; the service itself also drops it when disabled/incognito.
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

  /// Drop Watching when the player exits so the profile status actually
  /// disappears (the detail screen underneath will not re-fire browsing).
  static void _announceBrowsing() {
    if (!sl.isRegistered<DiscordRpc>()) return;
    sl<DiscordRpc>().clear(delay: DiscordRpc.playerExitClearDelay);
  }

  /// Top-left label under the show title, e.g. "Episode 3 · Real Name".
  static String _episodeLabel(Episode ep) =>
      episodePresenceDetails(ep) ?? '';

  /// How long playback will wait on episode-name metadata before giving up.
  /// Warm cache returns instantly; this only bites on a cold, slow fetch.
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
      // Playback waits on this (the native Activity gets its episode labels
      // once, at open), so keep it short — a cold cache on a slow TV would
      // otherwise sit on a black screen. Timing out throws into the catch
      // below and we play with the source's own titles.
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

  /// Same container→MIME hinting the Flutter player uses (tokenized URLs have no
  /// extension, so an explicit MIME builds the right MediaSource).
  static String? _mimeFor(VideoSource src) {
    final u = src.url.toLowerCase();
    if (src.container == SourceContainer.hls || u.contains('.m3u8')) {
      return 'application/x-mpegURL';
    }
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.contains('.mp4')) return 'video/mp4';
    return null;
  }
}
