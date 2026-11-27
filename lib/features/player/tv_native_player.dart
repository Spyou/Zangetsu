import '../companion/apple_companion.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/cast/cast_proxy.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_encode_skew.dart';
import '../../core/playback/subtitle_font_stage.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/tv/tv_playback_failure.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/playback/tv_playback_tracker.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/torrent/torrent_service.dart';
import '../../core/torrent/torrent_util.dart';
import 'playback_loading_title.dart' show playbackArtworkHeaders;
import 'subtitle_font_service.dart';
import 'tv_progressive_sources.dart';

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
  /// Bumped on every [play] so a phone handoff started for an older title
  /// is rejected (see [companionSessionMatches]).
  static int _companionSession = 0;

  /// LAN proxy that serves the TV-resolved links (with their headers) to the
  /// paired phone; restricted to the targets it was asked to serve.
  static final _companionProxy = CastProxyServer(restrictTargets: true);

  /// A torrent the TV started only for the paired phone (no TV player on it).
  static String? _companionTorrentId;

  /// Magnet + file index and local stream of [_companionTorrentId], so a
  /// repeat request for the same link reuses it.
  static String? _companionTorrentKey;
  static String? _companionTorrentLocalUrl;

  /// The TV player's own torrent, adopted while the phone streams it, so
  /// closing the TV player doesn't cut the phone off.
  static String? _adoptedTorrentId;

  /// Revokes stream proxy access when the receiver or paired-phone session ends,
  /// and stops any torrent kept alive only for the phone.
  static Future<void> stopCompanionSharing() {
    final ids = {_companionTorrentId, _adoptedTorrentId}
      ..remove(null)
      ..remove(_torrentId); // still the TV player's: it stops it itself
    _companionTorrentId = null;
    _adoptedTorrentId = null;
    if (sl.isRegistered<TorrentService>()) {
      for (final id in ids) {
        unawaited(sl<TorrentService>().stop(id!));
      }
    }
    return _companionProxy.stop();
  }

  /// Returns stable episode identity and a session generation for phone handoff
  /// ('Continue on phone'). Throws [StateError] when nothing is playing on TV.
  static Map<String, dynamic> companionSnapshot() {
    if (_episodes.isEmpty || _resolve == null)
      throw StateError('Start an episode on TV first.');
    return {
      'session': _companionSession,
      'sourceId': _sourceId,
      'showUrl': _showUrl,
      'title': _showTitle,
      'cover': _cover,
      'episodes': _episodes.map((e) => e.toJson()).toList(),
    };
  }

  /// Validates the TV session and lists the episode's links for the phone,
  /// each proxied with its own TV-owned headers, so the phone never needs the
  /// source installed. The TV's live link leads when it is on [index] and
  /// healthy; then the TV's own mirrors (the 'sourcesFor' list). [refresh]
  /// fetches a full fresh set (expired links).
  static Future<Map<String, dynamic>> companionSources(
    int session,
    int index, {
    bool refresh = false,
  }) async {
    if (session != _companionSession ||
        index < 0 ||
        index >= _episodes.length ||
        _resolve == null) {
      throw StateError('The TV title changed. Open Continue on phone again.');
    }
    final live = await const CompanionChannel()
        .invokeMapMethod<String, dynamic>('receiverStream');
    final liveFailed =
        live?['error'] != null ||
        (lastPlaybackErrorCode != null && lastPlaybackErrorIndex == index);
    final ep = _episodes[index];
    final cat = _category;
    final epUrl = tvEpisodeUrl(ep.url, cat);
    var listed = const <VideoSource>[];
    Object? listError;
    try {
      listed = refresh
          ? await _freshSources(epUrl)
          : (await _progressiveSources?.latest(epUrl, cat)) ??
                await _snapshotOrResolve(epUrl);
    } catch (e) {
      listError = e;
    }
    if (session != _companionSession) throw StateError('The TV title changed.');
    VideoSource? first;
    if (!liveFailed && live?['index'] == index && live?['url'] is String) {
      final liveUrl = live!['url'] as String;
      // The listed twin keeps quality, audio kind and the raw subtitles + skew
      // (the live subtitles may be skew files baked for the TV).
      first =
          listed.where((s) => s.url == liveUrl).firstOrNull ??
          VideoSource(
            url: liveUrl,
            headers: (live['headers'] as Map?)?.cast<String, String>(),
            subtitles: (live['subtitles'] as List? ?? [])
                .map(
                  (s) => Subtitle.fromJson(Map<String, dynamic>.from(s as Map)),
                )
                .toList(),
            drmKid: live['drmKid'] as String?,
            drmKey: live['drmKey'] as String?,
          );
      if (_torrentId != null && liveUrl == _torrentLocalUrl) {
        _adoptedTorrentId = _torrentId;
      }
    }
    first ??= listed.isEmpty ? null : _pickSource(ep, listed, cat);
    final seen = <String>{};
    final all = [?first, ...listed];
    final sources = [
      for (final s in all)
        if (!s.isDrm && seen.add(s.url)) s,
    ];
    if (sources.isEmpty) {
      if (all.isNotEmpty)
        throw StateError(
          'This protected stream cannot be transferred to the phone player.',
        );
      if (listError != null) throw listError;
      throw StateError(
        'The TV could not resolve this episode. Try another source.',
      );
    }
    final out = <Map<String, dynamic>>[];
    for (final s in sources) {
      if (isTorrentUrl(s.url) && out.isNotEmpty) {
        // One torrent streams at a time: later ones go to the phone as-is and
        // its own torrent engine plays them (no provider needed).
        out.add(
          VideoSource(
            url: s.url,
            quality: s.quality,
            label: s.label,
            container: s.container,
            kind: s.kind,
            audioLang: s.audioLang,
            torrentFileIndex: s.torrentFileIndex,
            subtitleSkewSeconds: s.subtitleSkewSeconds,
            subtitleSkewAfterSeconds: s.subtitleSkewAfterSeconds,
          ).toJson(),
        );
        continue;
      }
      final playable = await _companionPlayableUrl(
        s.url,
        fileIndex: s.torrentFileIndex,
      );
      if (session != _companionSession)
        throw StateError('The TV title changed.');
      if (playable == null) continue;
      final headers = s.headers ?? const <String, String>{};
      final url = out.isEmpty
          ? await _companionProxy.serve(playable, headers)
          : _companionProxy.proxify(playable, headers: headers);
      if (url == null)
        throw StateError(
          'Connect your phone and TV to the same Wi-Fi for video handoff.',
        );
      out.add(
        VideoSource(
          url: url,
          quality: s.quality,
          label: s.label,
          container: s.container,
          kind: s.kind,
          audioLang: s.audioLang,
          subtitleSkewSeconds: s.subtitleSkewSeconds,
          subtitleSkewAfterSeconds: s.subtitleSkewAfterSeconds,
          subtitles: s.subtitles
              .map(
                (t) => Subtitle(
                  url:
                      _companionProxy.proxify(t.url, headers: headers) ?? t.url,
                  lang: t.lang,
                  label: t.label,
                  format: t.format,
                  isDefault: t.isDefault,
                ),
              )
              .toList(),
        ).toJson(),
      );
    }
    if (out.isEmpty) throw StateError('The TV stream is not available yet.');
    return {'sources': out};
  }

  /// A URL the phone can play through the proxy: a magnet/.torrent is
  /// streamed on the TV. Only the previous companion torrent is stopped here;
  /// the engine runs one torrent at a time, so a TV player torrent it replaces
  /// is forgotten rather than stopped again later.
  static Future<String?> _companionPlayableUrl(
    String url, {
    int? fileIndex,
  }) async {
    if (!isTorrentUrl(url)) return url;
    // The phone asks again for the same episode (the player re-resolves at
    // start, retries): keep streaming the torrent it may already be playing
    // instead of restarting it under a new id.
    final key = '$url#${fileIndex ?? ''}';
    final running = _companionTorrentLocalUrl;
    if (_companionTorrentId != null &&
        _companionTorrentKey == key &&
        running != null) {
      return running;
    }
    final previous = _companionTorrentId;
    _companionTorrentId = null;
    _companionTorrentKey = null;
    _companionTorrentLocalUrl = null;
    _adoptedTorrentId = null;
    try {
      final torrents = sl<TorrentService>();
      if (previous != null) await torrents.stop(previous);
      final t = await torrents.startStream(
        url,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
        fileIndex: fileIndex,
      );
      _torrentId = null;
      _torrentLocalUrl = null;
      _companionTorrentId = t.id;
      _companionTorrentKey = key;
      _companionTorrentLocalUrl = t.localUrl;
      return t.localUrl;
    } catch (_) {
      return null;
    }
  }

  /// Rejects handoff selections made before the TV changed titles.
  static bool companionSessionMatches(int session) =>
      session == _companionSession;
  static bool _handlerBound = false;

  /// Set when [play] fails during source resolution — surfaced by
  /// [launchTvPlayback] instead of a generic error dialog.
  static TvPlaybackLoadFailure? lastFailure;

  /// Populated when the native ExoPlayer reports a fatal playback error
  /// (e.g. PARSING_CONTAINER_NOT_SUPPORTED) — the source resolved fine, but
  /// the stream couldn't play. [launchTvPlayback] reads this after [play]
  /// returns and offers Try Next Source / Select Source. Null when play
  /// succeeded or the user simply backed out.
  static String? lastPlaybackErrorCode;

  /// The episode the native player was on when it reported [lastPlaybackErrorCode].
  /// The viewer may have moved past the start episode, so an automatic source
  /// hop must replay THIS one, not the one the session opened on.
  static int? lastPlaybackErrorIndex;

  /// How long a fresh (non-fast) re-resolve may take after the native player
  /// reports an expired link (HTTP 403). Same budget as the phone player.
  @visibleForTesting
  static Duration refreshTimeout = const Duration(seconds: 15);

  /// How long the picker waits on the running resolve's snapshot.
  static const Duration pollSnapshotTimeout = Duration(seconds: 2);

  // Current session context — set on [play], read by the native→Dart handlers.
  // Only one native player is on screen at a time, so a plain static context is
  // enough (a new play() overwrites it).
  static Future<List<VideoSource>> Function(String episodeUrl)? _resolve;
  static TvProgressiveSources? _progressiveSources;
  static int _session = 0;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String? _skipTitle;
  static String? _skipImdbId;
  static int? _skipTmdbId;
  static bool _skipIsTv = false;
  static TvPlaybackTracker? _tracker;
  static List<SubtitleSearchResult> _subResults =
      const []; // last online search
  static String _category = 'sub';
  static ResumeStore? _resume;
  static String? _torrentId; // active torrent stream (stopped on switch/close)
  static String? _torrentLocalUrl; // [_torrentId]'s local http stream

  /// Returns `false` when the episode could not be resolved or started (no
  /// sources, torrent blocked, etc.). Callers should surface that to the user;
  /// this method itself has no UI.
  static Future<bool> play({
    required String sourceId,
    required List<Episode> episodes,
    required int startIndex,
    required ResumeStore resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
    resolveSources,
    Future<List<VideoSource>> Function(String episodeUrl)? pollSources,
    String? showUrl,
    String? showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String? loadingArtwork,
    String? loadingLogo,
    String category = 'sub',
    List<String> availableCategories = const [],
    int? malId,
    String? scrobbleTitle,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
  }) async {
    if (startIndex < 0 || startIndex >= episodes.length) return false;
    _companionSession++;
    lastFailure = null;
    lastPlaybackErrorCode = null;
    lastPlaybackErrorIndex = null;

    final session = ++_session;
    _stopProgressiveSources();
    _resolve = resolveSources;
    _episodes = episodes;
    _sourceId = sourceId;
    _showUrl = showUrl;
    _showId = showUrl ?? sourceId;
    _showTitle = showTitle ?? '';
    _cover = cover;
    _coverHeaders = coverHeaders;
    _malId = malId;
    _skipTitle = scrobbleTitle;
    _skipImdbId = imdbId;
    _skipTmdbId = tmdbId;
    _skipIsTv = tmdbIsTv;
    _category = category;
    _resume = resume;
    _tracker = TvPlaybackTracker(
      malId: malId,
      scrobbleTitle: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
    );
    if (sourceId == ZmodeIds.sourceId && sl.isRegistered<PlaybackResolver>()) {
      final resolver = sl<PlaybackResolver>();
      _progressiveSources = TvProgressiveSources(
        (url, cut) => resolver
            .resolveProgressive(url, category: cut, stopAfterFirstWave: true)
            .map((event) => event.streams),
        poll: (url, cut) async =>
            (await resolver.polledSources(url, category: cut)).sources,
      );
    } else if (pollSources != null) {
      _progressiveSources = TvProgressiveSources(
        (url, _) => Stream.fromFuture(resolveSources(url)),
        poll: (url, _) => pollSources(url),
      );
    }
    if (!_handlerBound) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerBound = true;
    }

    final ep = _episodes[startIndex];
    // Full subtitle style, computed the SAME way as the Flutter PlatformView TV
    // player so both render identically (colour, box, outline, font).
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

    // Filler flags: use warm cache immediately so launch isn't blocked; push an
    // update over the channel if the Tenrai fetch lands after the player is up.
    final warm = malId != null ? FillerService.instance.peekCache(malId) : null;
    final fillerFlags = _fillerFlags(_episodes, warm ?? const {});
    if (malId != null) {
      unawaited(
        FillerService.instance.fillerEpisodes(malId).then((s) async {
          if (s.isEmpty && warm == null) return;
          final flags = _fillerFlags(_episodes, s);
          try {
            await _ch.invokeMethod<void>('setFillerInfo', {
              'fillerFlags': flags,
              'autoSkipFiller': prefs.autoSkipFiller,
            });
          } catch (_) {}
        }),
      );
    }

    final startupArtwork = [
      ep.thumbnail,
      loadingArtwork,
      cover,
    ].whereType<String>().where((url) => url.trim().isNotEmpty).firstOrNull;
    final launch = _ch.invokeMapMethod<String, dynamic>('launch', {
      'resolveOnOpen': true,
      'title': _showTitle,
      'loadingArtwork': startupArtwork,
      'loadingLogo': ?loadingLogo,
      'loadingArtworkHeaders': ?playbackArtworkHeaders(
        startupArtwork,
        cover,
        coverHeaders,
      ),
      'episodeLabel': _episodeLabel(ep),
      'episodeLabels': [for (final e in _episodes) _episodeLabel(e)],
      'episodeCount': episodes.length,
      'startIndex': startIndex,
      'category': category,
      'availableCategories': availableCategories,
      'accentColor': AppColors.accent.toARGB32(),
      'decoderMode': prefs.tvDecoderMode.wireValue,
      // Playback + subtitle-style defaults from the shared prefs.
      'defaultSpeed': prefs.defaultSpeed,
      'volumeBoost': prefs.volumeBoost,
      // Buffer preset → ExoPlayer LoadControl. Resolved Dart-side so the
      // preset→number mapping stays in PlaybackPrefs (one place, unit-tested)
      // rather than being written a second time in Kotlin.
      ...prefs.exoBufferParams,
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
    // Enrichment can finish behind the player. Preserve the current cut if
    // an episode/category switch replaced the list while metadata was loading.
    unawaited(
      _enrichEpisodes(
        episodes,
        malId: malId,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        anime: scrobbleTitle != null || malId != null,
      ).then((enriched) {
        if (_session == session && identical(_episodes, episodes)) {
          _episodes = enriched;
        }
      }),
    );
    var isCurrentSession = false;
    final res = await launch.whenComplete(() {
      isCurrentSession = _session == session;
      if (isCurrentSession) {
        _session++;
        _stopProgressiveSources();
      }
    });

    if (!isCurrentSession) return true;
    debugPrint('[TvNativePlayer] launch returned: $res');

    // Player closed — stop any active torrent stream.
    _stopTorrent();
    // On close the native side returns the FINAL episode + position, so a session
    // that switched episodes saves progress against the right one.
    final index = (res?['episodeIndex'] as num?)?.toInt() ?? startIndex;
    final posMs = (res?['positionMs'] as num?)?.toInt() ?? 0;
    final durMs = (res?['durationMs'] as num?)?.toInt() ?? 0;
    _saveProgress(index, posMs, durMs);
    _tracker?.stopLive();
    // A fatal ExoPlayer error (e.g. PARSING_CONTAINER_NOT_SUPPORTED) is
    // reported on the channel BEFORE the activity finishes; the result flag
    // confirms it so launchTvPlayback can offer Try Next Source / Select Source.
    if ((res?['playbackError'] as bool?) ?? false) {
      lastPlaybackErrorCode ??= 'PLAYBACK_FAILED';
    }
    // Player closed → drop Watching, then restore browsing. The detail screen
    // stays mounted underneath and won't re-fire it.
    _announceBrowsing();
    return res?['launched'] == true && res?['sourceLookupFailed'] != true;
  }

  /// Handles native→Dart calls while the player is on screen.
  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'resolveEpisode':
        final session = _session;
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final category = (args['category'] as String?) ?? _category;
        if (index < 0 || index >= _episodes.length) return null;
        // Self-contained Sub/Dub swap: don't rely on setCategory finishing
        // first (Kotlin fires both; Flutter may interleave them). Opaque
        // episode urls need the other cut's list or Sub keeps playing Dub.
        final epIndex = args['opening'] == true
            ? index
            : await _ensureEpisodesForCategory(index, category);
        if (_session != session || epIndex < 0 || epIndex >= _episodes.length) {
          return null;
        }
        final ep = _episodes[epIndex];
        final picked = await _resolveSource(ep, category: category);
        if (_session != session || picked == null) return null;
        final src = await _withSkewedSubtitles(picked);
        if (_session != session) return null;
        final playUrl = await _playableUrl(src.url);
        if (_session != session || playUrl == null) return null;
        _category = category;
        _tracker?.maybeMarkWatching();
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
        final completed = args['completed'] as bool? ?? false;
        _saveProgress(index, posMs, durMs, completed: completed);
        if (index >= 0 && index < _episodes.length) {
          _tracker?.liveProgress(
            index: index,
            episode: _episodes[index],
            positionMs: posMs,
            durationMs: durMs,
            playing: args['playing'] as bool? ?? true,
            completed: completed,
          );
          _announceWatching(
            _episodes[index],
            positionMs: posMs,
            durationMs: durMs,
            playing: args['playing'] as bool? ?? true,
          );
        }
        return null;
      case 'trackingTick':
        // Slow heartbeat from the native player while it plays. Position-only:
        // no resume/history write, just the live tracker timeline.
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return null;
        final position = (args['positionMs'] as num?)?.toInt() ?? 0;
        final duration = (args['durationMs'] as num?)?.toInt() ?? 0;
        final progressive = _progressiveSources;
        if (progressive != null &&
            duration > 0 &&
            position >= duration * .85 &&
            index + 1 < _episodes.length &&
            args['playing'] == true) {
          unawaited(
            progressive.prefetch(
              tvEpisodeUrl(_episodes[index + 1].url, _category),
              _category,
            ),
          );
        }
        _tracker?.liveProgress(
          index: index,
          episode: _episodes[index],
          positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
          durationMs: (args['durationMs'] as num?)?.toInt() ?? 0,
          playing: args['playing'] as bool? ?? true,
          completed: args['completed'] as bool? ?? false,
        );
        return null;
      case 'setCategory':
        // The native player switched sub/dub — remember it for this title so the
        // next launch opens in the same version (mirrors the ExoPlayer player).
        // Also re-fetch via CatalogueRepository so Z Mode's remembered cut
        // updates before the next resolveEpisode (sources() has no category
        // arg). SourceRepository would leave the cut on sub and keep Japanese.
        final cat = (call.arguments as Map)['category'] as String?;
        if (cat != null) {
          _category = cat;
          if (_showUrl != null) {
            await sl<TitlePrefsStore>().setCategory(_sourceId, _showUrl!, cat);
            try {
              final other = await sl<CatalogueRepository>().episodes(
                _showUrl!,
                category: cat,
                sourceId: _sourceId,
              );
              if (other.isNotEmpty) {
                _episodes = await _enrichEpisodes(other);
              }
            } catch (_) {}
          }
        }
        return null;
      case 'rememberSubtitle':
        // Native track pick — remember it for this show, same as the mpv
        // player's in-player picker. 'off' is a real choice, not empty.
        final choice = (call.arguments as Map)['choice'] as String?;
        if (choice != null &&
            choice.isNotEmpty &&
            _showUrl != null &&
            _showUrl!.isNotEmpty) {
          await sl<TitlePrefsStore>().setSubtitleChoice(
            _sourceId,
            _showUrl!,
            choice,
          );
        }
        return null;
      case 'setSubtitleScale':
        // In-player subtitle-size change — persist so it sticks next launch.
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
      case 'stageSubtitleFont':
        final font = (call.arguments as Map)['font'] as String? ?? '';
        if (font.isEmpty) return null;
        await SubtitleFontService.instance.ensure(font);
        return await stageSubtitleFont(font);
      case 'searchSubtitles':
        // OpenSubtitles search for the current show; results cached for download.
        // The show's own pick beats the global preference for the search lang.
        final showSub = (_showUrl != null && _showUrl!.isNotEmpty)
            ? sl<TitlePrefsStore>().subtitleChoice(_sourceId, _showUrl!)
            : null;
        final pref = showSub ?? sl<PlaybackPrefs>().subtitlePreference;
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
      case 'resolveTorrent':
        // A magnet/.torrent picked from the Sources menu → local stream URL.
        final url = (call.arguments as Map)['url'] as String?;
        return url == null ? null : await _playableUrl(url);
      case 'sourcesFor':
        // The full mirror list for the Server/Source picker, and the mirror
        // walk the native player runs after a playback error. `refresh: true`
        // (sent once, after an HTTP 403 with no untried mirror left) means the
        // links have expired: fetch a FULL fresh set, the way the phone does.
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final category = (args['category'] as String?) ?? _category;
        final refresh = args['refresh'] == true;
        if (index < 0 || index >= _episodes.length) return const <Map>[];
        final session = _session;
        final requestCategory = _category;
        bool stale() => _session != session || _category != requestCategory;
        try {
          final url = tvEpisodeUrl(_episodes[index].url, category);
          final progressive = _progressiveSources;
          var sources = progressive != null
              ? await progressive.latest(url, category)
              : await _snapshotOrResolve(url);
          if (stale()) return const <Map>[];
          if (refresh) {
            final fresh = await _freshSources(url);
            if (stale()) return const <Map>[];
            if (fresh.isNotEmpty) {
              if (progressive != null &&
                  identical(progressive, _progressiveSources)) {
                progressive.addMirrors(url, category, fresh);
              }
              sources = mergeSourcesByUrl(sources, fresh);
            }
          }
          final prepared = await _prepareSources(sources);
          if (stale()) return const <Map>[];
          return [
            for (var i = 0; i < prepared.length; i++)
              {..._srcMap(prepared[i]), 'label': _srcLabel(prepared[i], i)},
          ];
        } catch (_) {
          return const <Map>[];
        }
      case 'skipsFor':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final index = (args['index'] as num?)?.toInt() ?? -1;
        final durMs = (args['durationMs'] as num?)?.toInt() ?? 0;
        if (index < 0 || index >= _episodes.length) {
          return const <Map>[];
        }
        final ep = _episodes[index];
        final epNo = ep.number?.toInt() ?? (index + 1);
        try {
          final service = sl<SkipService>();
          final duration = Duration(milliseconds: durMs);
          final title = _skipTitle;
          final skips = title != null
              ? await service.skipTimes(
                  title: title,
                  episode: epNo,
                  duration: duration,
                )
              : await service.introDbTimes(
                  imdbId: _skipImdbId,
                  tmdbId: _skipTmdbId,
                  isTv: _skipIsTv,
                  season: ep.season,
                  episode: ep.number,
                  duration: duration,
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
      case 'playbackError':
        // Native ExoPlayer hit a playback error (e.g. PARSING_CONTAINER_NOT_SUPPORTED).
        // Mark the source unhealthy so the resolver deprioritizes it next time,
        // and invalidate the winner cache so the next resolve re-sweeps.
        {
          final args = (call.arguments as Map).cast<String, dynamic>();
          final code = args['errorCode'] as String? ?? '';
          final msg = args['message'] as String? ?? '';
          final index = (args['index'] as num?)?.toInt() ?? -1;
          debugPrint(
            '[TvNativePlayer] playbackError · code=$code msg=$msg index=$index',
          );
          lastPlaybackErrorCode = code.isEmpty ? 'PLAYBACK_FAILED' : code;
          lastPlaybackErrorIndex = index >= 0 && index < _episodes.length
              ? index
              : null;
          unawaited(_handlePlaybackError(code, msg, index));
          return null;
        }
    }
    return null;
  }

  /// Handles a playback error reported by the native ExoPlayer — excludes the
  /// source that served it for THIS episode so the next resolve sweeps past it.
  ///
  /// Nothing is written to the source health store: the phone player doesn't,
  /// and a health strike hid the whole source from sweeps and search for 30
  /// minutes after ONE bad mirror (4KHDHub then "only worked sometimes" on TV).
  static Future<void> _handlePlaybackError(
    String code,
    String message,
    int index,
  ) async {
    if (_showUrl == null) return;
    // The actual source that served the stream (fourkhdhub, etc.) — for metadata
    // (zm) this differs from _sourceId (which is 'zm').
    String failedSourceId = _sourceId;
    if (ZmodeIds.isZ(_showUrl!) && index >= 0 && index < _episodes.length) {
      final epUrl = tvEpisodeUrl(_episodes[index].url, _category);
      if (sl.isRegistered<PlaybackResolver>()) {
        final resolver = sl<PlaybackResolver>();
        failedSourceId =
            resolver.resolvedSourceId(epUrl, category: _category) ?? _sourceId;
        // Exclude THIS source for THIS episode, rather than forgetting
        // everything we know about the episode. invalidateWinner wipes the
        // _unplayable set as part of its job, so using it here would clear the
        // very memory we are trying to write and the next sweep would hand
        // back the same dead link. Same call the phone player makes.
        resolver.markSourceUnplayable(
          epUrl,
          failedSourceId,
          category: _category,
        );
      }
    }
    debugPrint(
      '[TvNativePlayer] playbackError · excluded $failedSourceId for this episode',
    );
  }

  /// Test hook for native→Dart calls (the channel handler is private).
  @visibleForTesting
  static Future<dynamic> debugHandleNativeCall(MethodCall call) =>
      _onNativeCall(call);

  /// [existing] in order, each replaced by its [fresh] twin (newer headers,
  /// cookies and tokens), then the new [fresh] links. One entry per url.
  @visibleForTesting
  static List<VideoSource> mergeSourcesByUrl(
    List<VideoSource> existing,
    List<VideoSource> fresh,
  ) {
    final byUrl = <String, VideoSource>{
      for (final source in existing) source.url: source,
    };
    for (final source in fresh) {
      byUrl[source.url] = source;
    }
    return byUrl.values.toList();
  }

  /// A full (non-fast) resolve for expired links. Never throws: a timeout or
  /// failure returns no links and the caller keeps what it already had.
  static Future<List<VideoSource>> _freshSources(String url) async {
    try {
      if (sl.isRegistered<CatalogueRepository>()) {
        return await sl<CatalogueRepository>()
            .sources(url, sourceId: _sourceId, fast: false)
            .timeout(refreshTimeout);
      }
      return await _resolve!(url).timeout(refreshTimeout);
    } catch (e) {
      debugPrint('[TvNativePlayer] refresh failed · $e');
      return const [];
    }
  }

  /// The running resolve's snapshot first, so the picker doesn't start a new
  /// lookup (that replaces the plugin's link session and kills the mirrors
  /// still arriving). Falls back to a resolve only when the snapshot is empty.
  static Future<List<VideoSource>> _snapshotOrResolve(String url) async {
    if (sl.isRegistered<CatalogueRepository>()) {
      try {
        final polled = await sl<CatalogueRepository>()
            .polledSources(url, sourceId: _sourceId)
            .timeout(pollSnapshotTimeout);
        if (polled.sources.isNotEmpty) return polled.sources;
      } catch (_) {
        // Resolve below.
      }
    }
    return _resolve!(url);
  }

  /// Bakes a provider's subtitle timing skew into local files, as the phone
  /// player does. A failure keeps the raw source.
  static Future<VideoSource> _withSkewedSubtitles(VideoSource src) async {
    if ((src.subtitleSkewSeconds ?? 0).abs() < 0.05) return src;
    try {
      return await materializeSkewedSubtitles(src);
    } catch (e) {
      debugPrint('[TvNativePlayer] subtitle skew failed · $e');
      return src;
    }
  }

  /// Every mirror in [sources] with its subtitle skew baked in, order kept.
  static Future<List<VideoSource>> _prepareSources(List<VideoSource> sources) =>
      // In parallel: the native mirror walk waits at most 30 s on this list,
      // and each skewed mirror may download several subtitle files.
      Future.wait([for (final source in sources) _withSkewedSubtitles(source)]);

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
    'subtitleSkewSeconds': src.subtitleSkewSeconds ?? 0.0,
    'subtitleSkewAfterSeconds': src.subtitleSkewAfterSeconds ?? 0.0,
    // ClearKey DRM (base64url kid/key) for encrypted CENC/DASH channels; the
    // native TV player builds an ExoPlayer clearkey session when present.
    if (src.isDrm) 'drmKid': src.drmKid,
    if (src.isDrm) 'drmKey': src.drmKey,
    'subtitles': [
      for (final s in src.subtitles)
        {'url': s.url, 'lang': s.lang, 'label': s.label ?? s.lang},
    ],
  };

  /// Swap `_episodes` to [category] when URL rewrite can't express the cut.
  /// Returns the index to resolve (clamped if the other list is shorter).
  static Future<int> _ensureEpisodesForCategory(
    int index,
    String category,
  ) async {
    if (index < 0 || index >= _episodes.length) return index;
    final current = _episodes[index];
    if (!categorySwitchNeedsEpisodeRefetch(current.url, category)) {
      return index;
    }
    if (_showUrl == null) return index;
    try {
      final other = await sl<CatalogueRepository>().episodes(
        _showUrl!,
        category: category,
        sourceId: _sourceId,
      );
      if (other.isEmpty) return index;
      _episodes = await _enrichEpisodes(other);
      return index < _episodes.length ? index : 0;
    } catch (_) {
      return index;
    }
  }

  static Future<VideoSource?> _resolveSource(
    Episode ep, {
    String? category,
  }) async {
    final session = _session;
    final cat = category ?? _category;
    try {
      final url = tvEpisodeUrl(ep.url, cat);
      final progressive = _progressiveSources;
      final sources = progressive != null
          ? await progressive.first(url, cat)
          : await _resolve!(url);
      if (_session != session) return null;
      final picked = _pickSource(ep, sources, cat);
      if (picked == null && sources.isEmpty) {
        lastFailure ??= const TvPlaybackLoadFailure(
          TvPlaybackLoadFailureKind.episodeNotAvailable,
        );
      }
      return picked;
    } on NoSourceMatch catch (e) {
      if (_session != session) return null;
      lastFailure ??= classifyPlaybackError(
        e,
        mode: playbackContentMode(showUrl: _showUrl),
      );
      rethrow;
    } on EpisodeNotAvailable catch (e) {
      if (_session != session) return null;
      lastFailure ??= classifyPlaybackError(
        e,
        mode: playbackContentMode(showUrl: _showUrl),
      );
      rethrow;
    } catch (_) {
      if (_session != session) return null;
      lastFailure ??= TvPlaybackLoadFailure(
        TvPlaybackLoadFailureKind.generic,
        mode: playbackContentMode(showUrl: _showUrl),
      );
      rethrow;
    }
  }

  /// The link the TV plays first for [ep]: the viewer's saved Stremio link,
  /// else [pickDefault] with the title's quality.
  static VideoSource? _pickSource(
    Episode ep,
    List<VideoSource> sources,
    String cat,
  ) {
    final saved =
        _sourceId == stremioSourceId && sl.isRegistered<TitlePrefsStore>()
        ? sl<TitlePrefsStore>().preferredStremioLink(
            ep.url,
            sources,
            showUrl: _showUrl,
          )
        : null;
    return saved ??
        pickDefault(
          sources,
          prefer: cat == 'dub' ? AudioKind.dub : AudioKind.sub,
          preferQuality:
              (_showUrl != null && sl.isRegistered<TitlePrefsStore>()
                  ? sl<TitlePrefsStore>().quality(_sourceId, _showUrl!)
                  : null) ??
              sl<PlaybackPrefs>().defaultQuality,
        );
  }

  static void _stopProgressiveSources() {
    final lookup = _progressiveSources;
    _progressiveSources = null;
    if (lookup != null) unawaited(lookup.dispose());
  }

  /// A URL ExoPlayer can play: a magnet/.torrent is streamed through the shared
  /// [TorrentService] (libtorrent → a local http:// stream) exactly like the phone
  /// player does; anything else passes through unchanged. Returns null on
  /// torrent failure / Wi-Fi-only.
  static Future<String?> _playableUrl(String url) async {
    if (!isTorrentUrl(url)) return url;
    final session = _session;
    _stopTorrent();
    try {
      final torrents = sl<TorrentService>();
      final t = await torrents.startStream(
        url,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
      );
      if (_session != session) {
        await torrents.stop(t.id);
        return null;
      }
      // The engine runs one torrent at a time: the phone's one just ended.
      _companionTorrentId = null;
      _adoptedTorrentId = null;
      _torrentId = t.id;
      _torrentLocalUrl = t.localUrl;
      return t.localUrl;
    } catch (_) {
      return null;
    }
  }

  static void _stopTorrent() {
    final id = _torrentId;
    _torrentLocalUrl = null;
    if (id != null) {
      _torrentId = null;
      // The paired phone still streams it (Continue on phone);
      // stopCompanionSharing releases it.
      if (id == _adoptedTorrentId && _companionProxy.isRunning) return;
      sl<TorrentService>().stop(id);
    }
  }

  static Map<String, dynamic> _streamPayload(VideoSource src, int positionMs) =>
      {..._srcMap(src), 'positionMs': positionMs};

  static void _saveProgress(
    int index,
    int posMs,
    int durMs, {
    bool completed = false,
  }) {
    if (index < 0 || index >= _episodes.length || durMs <= 0 || posMs <= 0)
      return;
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
    _tracker?.maybeScrobble(
      index: index,
      episode: ep,
      positionMs: posMs,
      durationMs: durMs,
      force: completed,
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
  static String _episodeLabel(Episode ep) => episodePresenceDetails(ep) ?? '';

  /// Per-index filler flags for the native player (source flags and Tenrai episode numbers).
  static List<bool> _fillerFlags(List<Episode> episodes, Set<int> fillers) => [
    for (final episode in episodes) isFillerEpisode(episode, fillers),
  ];

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
