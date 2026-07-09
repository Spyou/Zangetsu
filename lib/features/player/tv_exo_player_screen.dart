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
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_download_service.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/tv_playback_helpers.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/theme/app_colors.dart';
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
  });

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final List<Episode> episodes;
  final int startIndex;
  final String? showUrl;
  final String? showTitle;
  final String category;

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

  bool _subApplied = false; // one-shot preferred-language per (re)load
  bool _subDownloadTried = false; // one auto-download attempt per episode
  final _subDownloads = <TvSubtitleConfig>[]; // sourced-in during playback
  String? _stagedFontPath;
  String _stagedFontFamily = '';
  List<SubtitleSearchResult>? _searchResults;

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
    _loadEpisode();
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
    }
    final subs = _subtitleConfigs(src);
    await _c?.setSource(src.url, src.headers ?? const {}, subtitles: subs);
    await _applyCaptionStyle();
    _applyPlaybackTuning();
    _loadQualities(src);
  }

  void _applyPlaybackTuning() {
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
    // Reuse the menu panel to present results.
    setState(() {
      _searchResults = results;
    });
  }

  Future<void> _applySearchResult(SubtitleSearchResult r) async {
    setState(() => _searchResults = null);
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

  void _openMenu() => setState(() => _menuOpen = true);
  void _closeMenu() => setState(() => _menuOpen = false);

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
    if (_c?.ended.value == true) _next();
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
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (okKeys.contains(k)) { _togglePlay(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowRight) { _seekBy(10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowLeft) { _seekBy(-10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackNext) { _next(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) { _prev(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.arrowUp) {
      _openMenu();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && _menuOpen) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
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
            if (_c != null) _controlsOverlay(_c!),
            if (_menuOpen && _c != null)
              TvTrackMenu(
                sections: _buildSections(_c!),
                onClose: _closeMenu,
              ),
            if (_searchResults != null)
              TvTrackMenu(
                onClose: () => setState(() => _searchResults = null),
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
}
