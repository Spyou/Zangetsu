import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/hls.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_download_service.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/tv_playback_helpers.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/torrent/torrent_service.dart';
import '../../core/torrent/torrent_util.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tv/tv_keys.dart';
import '../../core/ui/subtitle_language_picker.dart';
import 'tv_exo_controller.dart';
import 'tv_track_menu.dart';

/// TV ExoPlayer player (SP1a core: play/pause, D-pad seek, resume, next/prev).
/// Constructor mirrors PlayerScreen so the SP1d router can swap it in unchanged.
/// Reached only behind the EXO_SPIKE dev flag until SP1d.
class TvExoPlayerScreen extends StatefulWidget {
  const TvExoPlayerScreen({
    super.key,
    required this.sourceId,
    required this.resume,
    required this.resolveSources,
    this.episodes = const [],
    this.startIndex = 0,
    this.showUrl,
    this.showTitle,
    this.category = 'sub',
    this.malId,
    this.scrobbleTitle,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
  });

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final List<Episode> episodes;
  final int startIndex;
  final String? showUrl;
  final String? showTitle;
  final String category;
  final int? malId;
  final String? scrobbleTitle;
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;

  @override
  State<TvExoPlayerScreen> createState() => _TvExoPlayerScreenState();
}

class _TvExoPlayerScreenState extends State<TvExoPlayerScreen> {
  TvExoController? _c;
  int _index = 0;
  bool _resumeSeeked = false;
  String? _error;
  int _lastSavedMs = 0;

  final _dio = Dio();
  late String _category;
  List<VideoSource> _sources = const [];
  VideoSource? _activeSource;
  List<HlsVariant> _qualities = const [];
  HlsVariant? _activeQuality; // null = Auto
  int? _seekTargetMs; // one-shot seek on next ready (resume OR source switch)
  bool _menuOpen = false;
  double _speed = 1.0;
  // Focus for the player root (D-pad controls) and the up-next card. Overlays
  // (menu / search / up-next) must explicitly grab focus and hand it back here,
  // because the root Focus holds focus and `autofocus` can't steal it.
  final _rootFocus = FocusNode(debugLabel: 'tvExoRoot');
  final _upNextFocus = FocusNode(debugLabel: 'tvExoUpNext');
  Timer? _menuHideTimer; // auto-hide the track menu after inactivity

  bool _subApplied = false; // one-shot preferred-language per (re)load
  bool _subDownloadTried = false; // one auto-download attempt per episode
  final _subDownloads = <TvSubtitleConfig>[]; // sourced-in during playback
  String? _stagedFontPath;
  String _stagedFontFamily = '';
  List<SubtitleSearchResult>? _searchResults;

  List<SkipInterval> _skips = const [];
  bool _skipsFetched = false;

  bool _markedWatching = false;
  final _scrobbled = <int>{}; // episode indices already scrobbled this session

  String? _torrentId;
  String? _torrentPhase; // non-null while a torrent is resolving
  int _loadGen = 0; // bumped per _open; guards stale async torrent resolves
  int? _upNextCountdown;
  Timer? _upNextTimer;
  bool _controlsVisible = true; // bottom controls; auto-hide after inactivity
  Timer? _controlsHideTimer;
  bool _holdingSpeed = false; // D-pad RIGHT held → temporary 2× (YouTube-style)

  @override
  void initState() {
    super.initState();
    _index = widget.episodes.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.episodes.length - 1);
    _category = widget.category;
  }

  Episode? get _ep =>
      widget.episodes.isEmpty ? null : widget.episodes[_index];

  String get _resumeShowId => widget.showUrl ?? widget.sourceId;

  void _onViewCreated(int id) {
    final c = TvExoController(id);
    _c = c;
    c.duration.addListener(_maybeResumeSeek);
    c.position.addListener(_maybeSaveProgress);
    c.ended.addListener(_onEnded);
    c.audioTracks.addListener(_onTracksChanged);
    c.textTracks.addListener(_onTracksChanged);
    c.duration.addListener(_maybeFetchSkips);
    c.position.addListener(_scrobbleTick);
    c.playing.addListener(_onPlayingChanged);
    _bumpControls();
    _loadEpisode();
  }

  void _scrobbleTick() => _maybeScrobble();

  /// Show the bottom controls and (re)start the 5s inactivity hide. While
  /// playing, they fade out after 5s of no input; while paused they stay.
  void _bumpControls() {
    _controlsHideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _controlsHideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_c?.playing.value == true &&
          !_menuOpen &&
          _searchResults == null &&
          _upNextCountdown == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onPlayingChanged() {
    if (!mounted) return;
    if (_c?.playing.value == true) {
      _bumpControls(); // resumed → start the fade-out countdown
    } else {
      _controlsHideTimer?.cancel(); // paused → keep controls up
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    }
  }

  bool get _hasTitleId =>
      widget.malId != null ||
      widget.scrobbleTitle != null ||
      widget.tmdbId != null ||
      widget.imdbId != null;

  void _maybeMarkWatching() {
    if (_markedWatching || !_hasTitleId) return;
    _markedWatching = true;
    sl<TrackerHub>().markWatching(
      malId: widget.malId,
      title: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
    );
  }

  void _maybeScrobble({bool force = false}) {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || !_hasTitleId) return;
    _maybeMarkWatching();
    final fire = force
        ? !_scrobbled.contains(_index)
        : shouldScrobble(
            positionMs: c.position.value,
            durationMs: c.duration.value,
            alreadyScrobbled: _scrobbled.contains(_index),
          );
    if (!fire) return;
    _scrobbled.add(_index);
    final epNum = (ep.number ?? (_index + 1)).toInt();
    sl<TrackerHub>().scrobble(
      malId: widget.malId,
      title: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      episode: epNum,
    );
  }

  Future<void> _loadEpisode() async {
    final ep = _ep;
    if (ep == null) {
      setState(() => _error = 'No episode to play.');
      return;
    }
    _lastSavedMs = 0;
    try {
      final sources =
          await widget.resolveSources(tvEpisodeUrl(ep.url, _category));
      final prefer = _category == 'dub' ? AudioKind.dub : AudioKind.sub;
      final src = pickDefault(sources, prefer: prefer);
      if (src == null) {
        setState(() => _error = 'No playable source.');
        return;
      }
      _sources = sources;
      final mark = widget.resume.get(widget.sourceId, _resumeShowId, ep.id);
      await _open(src, seekToMs: mark?.position.inMilliseconds ?? 0);
    } catch (e) {
      setState(() => _error = 'Could not load this episode.');
    }
  }

  /// Loads [src] into the player (with any side-loaded subtitles) and arms a
  /// one-shot seek to [seekToMs] once a real duration arrives. [keepDownloads]
  /// preserves in-playback downloaded subs + the applied-pref flag (used when
  /// re-opening to attach a just-downloaded subtitle).
  Future<void> _open(VideoSource src,
      {int seekToMs = 0, bool keepDownloads = false}) async {
    _activeSource = src;
    _resumeSeeked = false;
    _seekTargetMs = seekToMs > 0 ? seekToMs : null;
    if (!keepDownloads) {
      _subApplied = false;
      _subDownloadTried = false;
      _subDownloads.clear();
      _skipsFetched = false;
      _skips = const [];
    }
    final gen = ++_loadGen; // this load supersedes any in-flight one
    _stopTorrent(); // kill any torrent from the previous source/episode
    _error = null;
    var playUrl = src.url;
    var playHeaders = src.headers ?? const <String, String>{};
    if (isTorrentUrl(src.url)) {
      final local = await _resolveTorrent(src.url, gen);
      // Bail if a newer _open superseded us while resolving, or on error/wifi
      // (shown by _resolveTorrent).
      if (local == null || gen != _loadGen || !mounted) return;
      playUrl = local;
      playHeaders = const {};
    }
    final subs = _subtitleConfigs(src);
    await _c?.setSource(playUrl, playHeaders, subtitles: subs);
    await _applyCaptionStyle();
    _applyPlaybackTuning();
    _loadQualities(src);
  }

  Future<String?> _resolveTorrent(String uri, int gen) async {
    setState(() => _torrentPhase = 'Finding peers…');
    // Local subscription (not a shared field) so an overlapping _open can't
    // cancel this resolve's stream, or vice-versa. Stale ticks are ignored.
    final sub = sl<TorrentService>().events().listen((e) {
      if (!mounted || gen != _loadGen) return;
      if (e.state == TorrentState.buffering) {
        setState(() => _torrentPhase = 'Buffering ${(e.bufferPct * 100).round()}%');
      } else if (e.state == TorrentState.finding) {
        setState(() => _torrentPhase = 'Finding peers…');
      }
    });
    try {
      final t = await sl<TorrentService>().startStream(
        uri,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
      );
      await sub.cancel();
      if (gen != _loadGen) {
        // A newer load superseded us — stop the torrent WE just started so it
        // doesn't leak, and let the caller bail.
        sl<TorrentService>().stop(t.id);
        return null;
      }
      _torrentId = t.id;
      if (mounted) setState(() => _torrentPhase = null);
      return t.localUrl;
    } on PlatformException catch (e) {
      await sub.cancel();
      if (gen != _loadGen) return null;
      if (mounted) {
        setState(() {
          _torrentPhase = null;
          _error = e.code == 'wifi_only'
              ? 'Connect to Wi-Fi or allow mobile data in Settings to stream torrents.'
              : 'Could not start the torrent.';
        });
      }
      return null;
    } catch (_) {
      await sub.cancel();
      if (gen != _loadGen) return null;
      if (mounted) {
        setState(() {
          _torrentPhase = null;
          _error = 'Could not start the torrent.';
        });
      }
      return null;
    }
  }

  void _stopTorrent() {
    final id = _torrentId;
    if (id != null) {
      sl<TorrentService>().stop(id);
      _torrentId = null;
    }
  }

  void _applyPlaybackTuning() {
    _holdingSpeed = false; // a fresh load always starts at the chosen speed
    final perTitle = sl<TitlePrefsStore>().speed(widget.sourceId, _resumeShowId);
    _speed = perTitle ?? sl<PlaybackPrefs>().defaultSpeed;
    _c?.setPlaybackSpeed(_speed);
    _c?.setVolumeBoost(sl<PlaybackPrefs>().volumeBoost);
  }

  List<TvSubtitleConfig> _subtitleConfigs(VideoSource src) => [
        for (final s in src.subtitles)
          TvSubtitleConfig(
            url: s.url,
            lang: s.lang,
            label: s.label,
            mime: subtitleMime(s.format, url: s.url),
          ),
        ..._subDownloads,
      ];

  void _maybeResumeSeek() {
    final c = _c;
    if (c == null || c.duration.value <= 0 || _resumeSeeked) return;
    final target = _seekTargetMs ?? 0;
    if (TvExoController.shouldResumeSeek(
      resumeMs: target,
      durationMs: c.duration.value,
      alreadySeeked: _resumeSeeked,
    )) {
      _resumeSeeked = true;
      c.seek(target);
    } else {
      _resumeSeeked = true; // nothing to seek; don't re-check every tick
    }
  }

  void _maybeFetchSkips() {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || _skipsFetched || c.duration.value <= 0) return;
    _skipsFetched = true;
    if (!sl<PlaybackPrefs>().skipIntro) return;
    final title = widget.showTitle;
    if (title == null || title.isEmpty) return;
    final epNum = (ep.number ?? (_index + 1)).toInt();
    sl<SkipService>()
        .skipTimes(
          title: title,
          episode: epNum,
          duration: Duration(milliseconds: c.duration.value),
        )
        .then((s) {
      if (mounted) setState(() => _skips = s);
    }).catchError((_) {});
  }

  Future<void> _loadQualities(VideoSource src) async {
    var qs = const <HlsVariant>[];
    final u = src.url.toLowerCase();
    if (u.contains('.m3u8')) {
      try {
        qs = await fetchHlsVariants(src.url, src.headers ?? const {}, _dio);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _qualities = qs;
      _activeQuality = null; // Auto after a fresh load
    });
    // Apply the user's default-quality pref (HLS only).
    final v = decideDefaultQuality(
      variants: qs,
      pref: sl<PlaybackPrefs>().defaultQuality,
    );
    if (v != null) _selectQuality(v);
  }

  Future<void> _applyCaptionStyle() async {
    final p = sl<PlaybackPrefs>();
    final style = captionStyleFromPrefs(
      scale: p.subtitleScale,
      colorHex: p.subtitleColorHex,
      bgOpacity: p.subtitleBgOpacity,
      position: p.subtitlePosition,
      font: p.subtitleFont,
    );
    final path = await _stageFont(style.fontFamily);
    _c?.applyCaptionStyle(style, fontPath: path);
  }

  /// Copies the chosen bundled font to app-support once so Kotlin can
  /// Typeface.createFromFile it. Returns null for the default family.
  Future<String?> _stageFont(String family) async {
    if (family.isEmpty) return null;
    if (family == _stagedFontFamily && _stagedFontPath != null) {
      return _stagedFontPath;
    }
    final asset = subtitleFontAsset(family);
    if (asset == null) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final out = File('${dir.path}/sub_fonts/${asset.split('/').last}');
      if (!await out.exists()) {
        await out.parent.create(recursive: true);
        final bytes = await rootBundle.load(asset);
        await out.writeAsBytes(bytes.buffer.asUint8List());
      }
      _stagedFontFamily = family;
      _stagedFontPath = out.path;
      return out.path;
    } catch (_) {
      return null;
    }
  }

  void _selectQuality(HlsVariant? v) {
    setState(() => _activeQuality = v);
    _c?.setMaxVideoBitrate(v?.bandwidth ?? 0);
  }

  /// Sources for the active sub/dub kind, or all sources when the content
  /// isn't kind-split (movies / unknown). The per-source quality menu and its
  /// selection both draw from this same pool so a label can never resolve to a
  /// source of the opposite kind.
  List<VideoSource> _qualityPool() {
    final kind = _category == 'dub' ? AudioKind.dub : AudioKind.sub;
    final pool = sourcesForKind(_sources, kind);
    return pool.isNotEmpty ? pool : _sources;
  }

  void _selectSourceQuality(String label) {
    final match = _qualityPool().where((s) => s.quality == label).toList();
    if (match.isEmpty) return;
    _open(match.first, seekToMs: _c?.position.value ?? 0);
  }

  /// Human label for a source mirror in the Servers menu — the provider's own
  /// label (with quality appended when not already present), else the quality,
  /// else the container name.
  String _serverLabel(VideoSource s) {
    final label = s.label;
    final q = s.quality;
    if (label != null && label.isNotEmpty) {
      return (q != null && q.isNotEmpty && !label.contains(q))
          ? '$label · $q'
          : label;
    }
    return (q != null && q.isNotEmpty) ? q : s.container.name;
  }

  void _selectAudio(TvTrack t) => _c?.selectAudioTrack(t.id);

  void _switchCategory(String cat) {
    if (cat == _category) return;
    // Re-resolve the current episode under the new category, keep position.
    final pos = _c?.position.value ?? 0;
    () async {
      final ep = _ep;
      if (ep == null) return;
      try {
        final sources = await widget.resolveSources(tvEpisodeUrl(ep.url, cat));
        final prefer = cat == 'dub' ? AudioKind.dub : AudioKind.sub;
        final src = pickDefault(sources, prefer: prefer);
        if (src == null) return;
        _sources = sources;
        _category = cat;
        await _open(src, seekToMs: pos);
        if (mounted) setState(() {});
      } catch (_) {}
    }();
  }

  List<TvMenuSection> _buildSections(TvExoController c) {
    final sections = <TvMenuSection>[];

    // Servers — every resolved mirror for the current sub/dub kind, so the user
    // can switch when one is slow or dead (mirrors the phone player's Sources).
    final servers = sortByQuality(_qualityPool());
    if (servers.length > 1) {
      sections.add(TvMenuSection(
        title: 'Servers',
        options: [
          for (final s in servers)
            TvMenuOption(
              label: _serverLabel(s),
              selected: s.url == _activeSource?.url,
              onSelect: () => _open(s, seekToMs: c.position.value),
            ),
        ],
      ));
    }

    // Quality
    final qOptions = <TvMenuOption>[];
    if (_qualities.isNotEmpty) {
      qOptions.add(TvMenuOption(
        label: 'Auto',
        selected: _activeQuality == null,
        onSelect: () => _selectQuality(null),
      ));
      for (final v in _qualities) {
        qOptions.add(TvMenuOption(
          label: v.quality,
          selected: _activeQuality?.url == v.url,
          onSelect: () => _selectQuality(v),
        ));
      }
    } else {
      final labels = <String>{
        for (final s in _qualityPool())
          if ((s.quality ?? '').isNotEmpty) s.quality!,
      }.toList()
        ..sort((a, b) => qualityHeight(b).compareTo(qualityHeight(a)));
      for (final label in labels) {
        qOptions.add(TvMenuOption(
          label: label,
          selected: _activeSource?.quality == label,
          onSelect: () => _selectSourceQuality(label),
        ));
      }
    }
    if (qOptions.isNotEmpty) {
      sections.add(TvMenuSection(title: 'Quality', options: qOptions));
    }

    // Audio
    final audio = c.audioTracks.value;
    if (audio.length > 1) {
      sections.add(TvMenuSection(
        title: 'Audio',
        options: [
          for (final t in audio)
            TvMenuOption(
              label: t.label ?? (t.language.isEmpty ? 'Track' : t.language),
              selected: t.selected,
              onSelect: () => _selectAudio(t),
            ),
        ],
      ));
    }

    // Version (sub/dub)
    final kinds = availableKinds(_sources);
    final hasBoth = kinds.contains(AudioKind.sub) && kinds.contains(AudioKind.dub);
    if (hasBoth) {
      sections.add(TvMenuSection(
        title: 'Version',
        options: [
          TvMenuOption(
            label: 'Sub',
            selected: _category == 'sub',
            onSelect: () => _switchCategory('sub'),
          ),
          TvMenuOption(
            label: 'Dub',
            selected: _category == 'dub',
            onSelect: () => _switchCategory('dub'),
          ),
        ],
      ));
    }

    // Subtitles
    final text = c.textTracks.value;
    final subOptions = <TvMenuOption>[
      TvMenuOption(
        label: 'Off',
        selected: text.every((t) => !t.selected),
        onSelect: () => c.selectTextTrack(null),
      ),
      for (final t in text)
        TvMenuOption(
          label: t.label ?? (t.language.isEmpty ? 'Subtitle' : t.language),
          selected: t.selected,
          onSelect: () => c.selectTextTrack(t.id),
        ),
      TvMenuOption(
        label: 'Preferred language…',
        onSelect: _pickPreferredLanguage,
      ),
      TvMenuOption(
        label: 'Search online…',
        onSelect: _openSubtitleSearch,
      ),
      TvMenuOption(
        label: 'Subtitle size',
        trailing: _sizeLabel(sl<PlaybackPrefs>().subtitleScale),
        onSelect: _cycleSubtitleSize,
      ),
      TvMenuOption(
        label: 'Background',
        trailing: sl<PlaybackPrefs>().subtitleBgOpacity > 0 ? 'On' : 'Off',
        onSelect: _toggleSubtitleBackground,
      ),
    ];
    sections.add(TvMenuSection(title: 'Subtitles', options: subOptions));

    // Speed
    sections.add(TvMenuSection(
      title: 'Speed',
      options: [
        for (final s in kTvSpeeds)
          TvMenuOption(
            label: s == 1.0 ? 'Normal' : '${s}x',
            selected: (_speed - s).abs() < 0.001,
            onSelect: () => _setSpeed(s),
          ),
      ],
    ));

    // Volume boost
    const volSteps = [100, 125, 150, 175, 200];
    final vol = sl<PlaybackPrefs>().volumeBoost;
    sections.add(TvMenuSection(
      title: 'Volume',
      options: [
        for (final v in volSteps)
          TvMenuOption(
            label: v == 100 ? '100% (normal)' : '$v%',
            selected: vol == v,
            onSelect: () => _setVolume(v),
          ),
      ],
    ));

    return sections;
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _c?.setPlaybackSpeed(s);
    sl<TitlePrefsStore>().setSpeed(widget.sourceId, _resumeShowId, s);
    sl<PlaybackPrefs>().setDefaultSpeed(s);
  }

  void _setVolume(int v) {
    sl<PlaybackPrefs>().setVolumeBoost(v);
    _c?.setVolumeBoost(v);
    if (mounted) setState(() {});
  }

  String _sizeLabel(double s) => s <= 0.85 ? 'S' : (s >= 1.2 ? 'L' : 'M');

  Future<void> _cycleSubtitleSize() async {
    final p = sl<PlaybackPrefs>();
    final next = p.subtitleScale <= 0.85
        ? 1.0
        : (p.subtitleScale >= 1.2 ? 0.8 : 1.3);
    await p.setSubtitleScale(next);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _toggleSubtitleBackground() async {
    final p = sl<PlaybackPrefs>();
    await p.setSubtitleBgOpacity(p.subtitleBgOpacity > 0 ? 0.0 : 0.6);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _pickPreferredLanguage() async {
    final picked = await showSubtitleLanguagePicker(
        context, sl<PlaybackPrefs>().subtitlePreference);
    if (picked == null) return;
    await sl<PlaybackPrefs>().setSubtitlePreference(picked);
    _subApplied = false;
    await _maybeApplySubPref();
    if (mounted) setState(() {});
  }

  Future<void> _openSubtitleSearch() async {
    final query = widget.showTitle ?? '';
    if (sl<PlaybackPrefs>().subtitleApiKey.isEmpty) {
      _toast('Add an OpenSubtitles API key in Settings to search.');
      return;
    }
    // Search in the user's preferred subtitle language when they've set one
    // (subtitlePreference is '' for Auto or 'off'); fall back to English.
    final pref = sl<PlaybackPrefs>().subtitlePreference;
    final lang = (pref.isEmpty || pref == 'off') ? 'en' : pref;
    List<SubtitleSearchResult> results;
    try {
      results = await SubtitleSearchService().search(query, language: lang);
    } on SubtitleSearchException catch (e) {
      _toast(e.toString());
      return;
    } catch (_) {
      _toast('Subtitle search failed.');
      return;
    }
    if (!mounted) return;
    if (results.isEmpty) {
      _toast('No subtitles found.');
      return;
    }
    // Reuse the menu panel to present results. Close the track menu so there's
    // a single focused overlay (the results panel grabs focus on mount).
    _menuHideTimer?.cancel(); // menu is going away — don't let it re-close
    setState(() {
      _menuOpen = false;
      _searchResults = results;
    });
  }

  Future<void> _applySearchResult(SubtitleSearchResult r) async {
    setState(() => _searchResults = null);
    _rootFocus.requestFocus();
    try {
      final path = await SubtitleSearchService().download(r);
      final cfg = TvSubtitleConfig(
        url: path,
        lang: r.language,
        label: r.name,
        mime: subtitleMime(r.format, url: path),
      );
      _subDownloads.add(cfg);
      final src = _activeSource;
      if (src != null) {
        await _open(src, seekToMs: _c?.position.value ?? 0, keepDownloads: true);
      }
    } catch (_) {
      _toast('Could not download subtitle.');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openMenu() {
    setState(() => _menuOpen = true);
    _bumpMenuHide();
  }

  /// (Re)start the menu inactivity timer — reset on every menu interaction so
  /// it only auto-closes when the user has stopped navigating it.
  void _bumpMenuHide() {
    _menuHideTimer?.cancel();
    _menuHideTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && _menuOpen) _closeMenu();
    });
  }

  void _closeMenu() {
    _menuHideTimer?.cancel();
    setState(() => _menuOpen = false);
    _rootFocus.requestFocus(); // hand D-pad back to the player controls
  }

  void _onTracksChanged() {
    _maybeApplySubPref();
    if (_menuOpen && mounted) setState(() {});
  }

  Future<void> _maybeApplySubPref() async {
    final c = _c;
    if (c == null || _subApplied) return;
    final tracks = c.textTracks.value;
    if (tracks.isEmpty && c.duration.value <= 0) return; // not ready yet
    _subApplied = true;
    final pref = sl<PlaybackPrefs>().subtitlePreference;
    final d = decideSubtitle(textTracks: tracks, pref: pref);
    switch (d.action) {
      case TvSubAction.off:
        c.selectTextTrack(null);
        break;
      case TvSubAction.auto:
        break; // leave ExoPlayer's default
      case TvSubAction.select:
        c.selectTextTrack(d.track!.id);
        break;
      case TvSubAction.download:
        if (!_subDownloadTried && sl<PlaybackPrefs>().autoDownloadSubtitles) {
          await _downloadAndAttach(d.language!);
        }
        break;
    }
  }

  Future<void> _downloadAndAttach(Language lang) async {
    _subDownloadTried = true;
    try {
      final results = await SubtitleDownloadService().find(
        title: widget.showTitle,
        iso2: lang.iso2,
        iso1: lang.iso1,
      );
      if (results.isEmpty || !mounted) return;
      final r = results.first;
      _subDownloads.add(TvSubtitleConfig(
        url: r.url,
        lang: lang.iso1,
        label: lang.name,
        mime: subtitleMime(null, url: r.url),
      ));
      // Re-open the current source with the added subtitle, keeping position
      // AND the download list (keepDownloads: true). Then re-arm the pref pass
      // so the now-present downloaded track gets selected on the next
      // onTracksChanged (the _subDownloadTried guard prevents a re-download loop).
      final src = _activeSource;
      if (src != null) {
        await _open(src, seekToMs: _c?.position.value ?? 0, keepDownloads: true);
        _subApplied = false;
      }
    } catch (_) {}
  }

  void _maybeSaveProgress() {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || c.duration.value <= 0) return;
    final pos = c.position.value;
    if ((pos - _lastSavedMs).abs() < 5000) return; // throttle: every 5s
    _lastSavedMs = pos;
    widget.resume.save(
      widget.sourceId,
      _resumeShowId,
      ep.id,
      Duration(milliseconds: pos),
      Duration(milliseconds: c.duration.value),
    );
  }

  void _onEnded() {
    if (_c?.ended.value != true) return;
    _maybeScrobble(force: true);
    if (_index >= widget.episodes.length - 1) return;
    if (sl<PlaybackPrefs>().autoplayNext) {
      _startUpNext();
    }
  }

  void _startUpNext() {
    _upNextCountdown = 5;
    if (mounted) setState(() {});
    // Move focus onto the card so OK=play-now / Back=cancel work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _upNextCountdown != null) _upNextFocus.requestFocus();
    });
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final next = (_upNextCountdown ?? 1) - 1;
      if (next <= 0) {
        t.cancel();
        _cancelUpNext();
        _next();
      } else {
        setState(() => _upNextCountdown = next);
      }
    });
  }

  void _cancelUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    if (mounted) setState(() => _upNextCountdown = null);
    _rootFocus.requestFocus(); // hand D-pad back to the player
  }

  void _next() {
    if (_index >= widget.episodes.length - 1) return;
    setState(() => _index++);
    _loadEpisode();
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _loadEpisode();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.playing.value ? c.pause() : c.play();
  }

  void _seekBy(int deltaMs) {
    final c = _c;
    if (c == null) return;
    final target =
        (c.position.value + deltaMs).clamp(0, c.duration.value == 0 ? 1 << 31 : c.duration.value);
    c.seek(target);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    // While an overlay (menu / online search / up-next) is up, it owns the
    // D-pad: let its focused widget + traversal handle keys, don't eat them.
    if (_menuOpen || _searchResults != null || _upNextCountdown != null) {
      if (_holdingSpeed) _endHoldSpeed(); // don't leave 2× stuck if a menu opens
      return KeyEventResult.ignored;
    }
    // Center OK: a tap plays/pauses, a HOLD runs temporary 2× (YouTube-style).
    // The toggle is deferred to key-up so holding speeds up instead of pausing;
    // a hold is detected by the key-repeat that only a held button emits.
    if (okKeys.contains(k)) {
      if (e is KeyDownEvent) { _bumpControls(); return KeyEventResult.handled; }
      if (e is KeyRepeatEvent) { _startHoldSpeed(); return KeyEventResult.handled; }
      if (e is KeyUpEvent) {
        _holdingSpeed ? _endHoldSpeed() : _togglePlay();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    _bumpControls(); // any input reveals the controls + resets the hide timer
    if (k == LogicalKeyboardKey.arrowRight) { _seekBy(10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowLeft) { _seekBy(-10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackNext) { _next(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) { _prev(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Center OK held → play at 2× until released (mirrors YouTube's hold-to-2×
  /// and the phone player's long-press). Drives the controller directly so the
  /// boost is never persisted as the user's chosen speed.
  void _startHoldSpeed() {
    if (_holdingSpeed) return;
    _holdingSpeed = true;
    _bumpControls();
    _c?.setPlaybackSpeed(2.0);
  }

  void _endHoldSpeed() {
    if (!_holdingSpeed) return;
    _holdingSpeed = false;
    _c?.setPlaybackSpeed(_speed); // back to the user's chosen speed
    _bumpControls();
  }

  @override
  void dispose() {
    _loadGen++; // supersede any in-flight torrent resolve so it stops itself
    _stopTorrent();
    _menuHideTimer?.cancel();
    _controlsHideTimer?.cancel();
    _upNextTimer?.cancel(); // cancel directly — _cancelUpNext setStates/refocuses
    final c = _c;
    if (c != null) {
      // Persist final position before releasing.
      final ep = _ep;
      if (ep != null && c.duration.value > 0) {
        widget.resume.save(
          widget.sourceId,
          _resumeShowId,
          ep.id,
          Duration(milliseconds: c.position.value),
          Duration(milliseconds: c.duration.value),
        );
      }
      c.dispose();
    }
    _dio.close();
    _rootFocus.dispose();
    _upNextFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlayOpen =
        _menuOpen || _searchResults != null || _upNextCountdown != null;
    return PopScope(
      // While an overlay is up, Back closes IT (the TV remote Back is a route
      // pop, not a key event, so this — not the menu's onKeyEvent — is what
      // actually catches it); only pop the player when nothing is open.
      // Netflix-style Back ladder: dismiss whatever is showing before exiting.
      // An open overlay closes first; then the visible controls/progress bar
      // hide; only a Back with nothing on screen pops the player.
      canPop: !overlayOpen && !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searchResults != null) {
          setState(() => _searchResults = null);
          _rootFocus.requestFocus();
        } else if (_menuOpen) {
          _closeMenu();
        } else if (_upNextCountdown != null) {
          _cancelUpNext();
        } else if (_controlsVisible) {
          _controlsHideTimer?.cancel();
          setState(() => _controlsVisible = false);
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: PlatformViewLink(
                viewType: 'zangetsu/exoplayer_view',
                surfaceFactory: (context, controller) => AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers:
                      const <Factory<OneSequenceGestureRecognizer>>{},
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                ),
                onCreatePlatformView: (params) {
                  final controller = PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: 'zangetsu/exoplayer_view',
                    layoutDirection: TextDirection.ltr,
                    creationParams: const <String, dynamic>{},
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  )
                    ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                    ..addOnPlatformViewCreatedListener(_onViewCreated)
                    ..create();
                  return controller;
                },
              ),
            ),
            if (_error != null)
              Center(
                child: Text(_error!,
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
              ),
            if (_torrentPhase != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(_torrentPhase!,
                        style: const TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            if (_c != null && _controlsVisible) _controlsOverlay(_c!),
            if (_c != null)
              Positioned(
                right: 40,
                bottom: 120,
                child: ValueListenableBuilder<int>(
                  valueListenable: _c!.position,
                  builder: (_, pos, _) {
                    final children = <Widget>[];
                    final skip = sl<PlaybackPrefs>().skipIntro
                        ? activeSkipInterval(_skips, pos)
                        : null;
                    if (skip != null) {
                      children.add(_pillButton(
                        skip.type == 'ed' ? 'Skip Ending' : 'Skip Opening',
                        () => _c?.seek(skip.end.inMilliseconds),
                      ));
                    }
                    // The manual "+Ns" jump pill rides with the controls — it
                    // fades out on the same 5s timer instead of sitting on the
                    // video the whole episode. (The AniSkip pill above still
                    // shows for its interval, Netflix-style.)
                    if (sl<PlaybackPrefs>().megaSkip && _controlsVisible) {
                      final secs = sl<PlaybackPrefs>().megaSkipSeconds;
                      children.add(_pillButton('+${secs}s', () {
                        final c = _c;
                        if (c != null) c.seek(c.position.value + secs * 1000);
                      }));
                    }
                    if (children.isEmpty) return const SizedBox.shrink();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final w in children) Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: w,
                        ),
                      ],
                    );
                  },
                ),
              ),
            if (_upNextCountdown != null && _index < widget.episodes.length - 1)
              Positioned(
                right: 40,
                bottom: 160,
                child: Focus(
                  focusNode: _upNextFocus,
                  onKeyEvent: (_, e) {
                    if (e is! KeyDownEvent) return KeyEventResult.ignored;
                    if (okKeys.contains(e.logicalKey)) {
                      _cancelUpNext();
                      _next();
                      return KeyEventResult.handled;
                    }
                    if (e.logicalKey == LogicalKeyboardKey.goBack ||
                        e.logicalKey == LogicalKeyboardKey.escape) {
                      _cancelUpNext();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accent, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Up next: ${widget.episodes[_index + 1].title.isNotEmpty ? widget.episodes[_index + 1].title : 'Episode ${_index + 2}'}',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text('Playing in $_upNextCountdown…  (OK to play now, Back to cancel)',
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            if (_menuOpen && _c != null)
              TvTrackMenu(
                sections: _buildSections(_c!),
                onClose: _closeMenu,
                onInteract: _bumpMenuHide,
              ),
            if (_searchResults != null)
              TvTrackMenu(
                onClose: () {
                  setState(() => _searchResults = null);
                  _rootFocus.requestFocus();
                },
                sections: [
                  TvMenuSection(
                    title: 'Online subtitles',
                    options: [
                      for (final r in _searchResults!)
                        TvMenuOption(
                          label: r.name,
                          trailing: r.language,
                          onSelect: () => _applySearchResult(r),
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _controlsOverlay(TvExoController c) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 28),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scrubber
            ValueListenableBuilder<int>(
              valueListenable: c.position,
              builder: (_, pos, _) => ValueListenableBuilder<int>(
                valueListenable: c.duration,
                builder: (_, dur, _) {
                  final frac = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                  return Row(
                    children: [
                      Text(_fmt(pos),
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: frac,
                          minHeight: 4,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.accent),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_fmt(dur),
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: c.buffering,
                  builder: (_, buf, _) => buf
                      ? const Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: c.playing,
                  builder: (_, playing, _) => Text(
                    playing ? 'Playing — OK to pause' : 'Paused — OK to play',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 18),
                Text(
                  '▲ / ▼  Subtitles & options',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  Widget _pillButton(String label, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && okKeys.contains(e.logicalKey)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: focused ? AppColors.accent : Colors.white38,
                width: 2,
              ),
            ),
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        );
      }),
    );
  }
}
