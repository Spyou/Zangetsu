// lib/features/player/engine/mpv_engine.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/di/injector.dart';
import '../../../core/playback/playback_prefs.dart';
import 'playback_engine.dart';

/// Faithful media_kit (mpv) implementation of [PlaybackEngine]. All mpv
/// tuning/subtitle-font/volume-boost logic is lifted verbatim from the
/// pre-migration `PlayerController` so playback behaviour is unchanged.
class MpvEngine implements PlaybackEngine {
  MpvEngine({bool isTv = false}) : _isTv = isTv {
    _wireStreams();
  }
  final bool _isTv;

  final Player _player = Player();
  late final VideoController _videoController = VideoController(
    _player,
    configuration: VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      width: _isTv ? 1280 : null,
      height: _isTv ? 720 : null,
    ),
  );

  // TEMPORARY escape hatches for the migration (removed in Task 6).
  Player get rawPlayer => _player;
  VideoController get rawVideoController => _videoController;

  final _position = ValueNotifier<Duration>(Duration.zero);
  final _duration = ValueNotifier<Duration>(Duration.zero);
  final _playing = ValueNotifier<bool>(false);
  final _buffering = ValueNotifier<bool>(false);
  final _completed = ValueNotifier<bool>(false);
  final _rate = ValueNotifier<double>(1.0);
  final _videoWidth = ValueNotifier<int>(0);
  final _audioTracks = ValueNotifier<List<EngineTrack>>(const []);
  final _textTracks = ValueNotifier<List<EngineTrack>>(const []);
  final _errors = StreamController<EngineError>.broadcast();
  final _subs = <StreamSubscription>[];
  late final Future<void> _configured = _configure();

  Tracks _lastTracks = const Tracks();
  String? _activeAudioId;
  String? _activeSubtitleId;

  void _wireStreams() {
    _subs.add(_player.stream.position.listen((v) => _position.value = v));
    _subs.add(_player.stream.duration.listen((v) => _duration.value = v));
    _subs.add(_player.stream.playing.listen((v) => _playing.value = v));
    _subs.add(_player.stream.buffering.listen((v) => _buffering.value = v));
    _subs.add(_player.stream.completed.listen((v) => _completed.value = v));
    _subs.add(_player.stream.rate.listen((v) => _rate.value = v));
    _subs.add(_player.stream.width.listen((v) => _videoWidth.value = v ?? 0));
    // audio/text track mapping: convert media_kit tracks → EngineTrack.
    _subs.add(_player.stream.tracks.listen((t) {
      _lastTracks = t;
      _rebuildTracks();
    }));
    // currently-active audio/subtitle track (drives EngineTrack.selected).
    _subs.add(_player.stream.track.listen((t) {
      _activeAudioId = t.audio.id;
      _activeSubtitleId = t.subtitle.id;
      _rebuildTracks();
    }));
    // media_kit surfaces errors via stream.error; treat as fatal-ish.
    _subs.add(_player.stream.error.listen(
      (msg) => _errors.add(EngineError(code: msg, framesRendered: true)),
    ));
  }

  /// Rebuild the exposed [EngineTrack] lists from the latest tracks list +
  /// active track, so `.selected` reflects what mpv is actually playing.
  void _rebuildTracks() {
    _audioTracks.value = [
      for (final a in _lastTracks.audio)
        EngineTrack(
          id: a.id,
          language: a.language ?? '',
          label: a.title,
          selected: a.id == _activeAudioId,
        ),
    ];
    _textTracks.value = [
      for (final s in _lastTracks.subtitle)
        EngineTrack(
          id: s.id,
          language: s.language ?? '',
          label: s.title,
          selected: s.id == _activeSubtitleId,
        ),
    ];
  }

  Future<void> _configure() async {
    final p = _player.platform;
    if (p is NativePlayer) {
      // MOVED verbatim from PlayerController._configureMpv()
      // (lib/features/player/player_controller.dart).
      try {
        await p.setProperty('force-seekable', 'yes');
        await p.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,'
              'reconnect_on_network_error=1,reconnect_delay_max=5',
        );
        // HLS workarounds for anti-leech CDNs (AnimeSalt/AnimixStream, …):
        //  • extension_picky=0 + allowed_extensions=ALL — segments are disguised
        //    with non-media extensions (.js/.css/.woff); FFmpeg 7 otherwise
        //    rejects them by URL extension (segment bytes are still validated).
        //  • http_persistent=0 — these CDNs break FFmpeg's HLS keepalive
        //    ("keepalive request failed … Invalid argument"), which corrupts the
        //    sub-playlist/segment fetches ("parse_playlist error Invalid data").
        //    Forcing a fresh connection per request fixes playback.
        //  • analyzeduration=2000000 (2s) — cap FFmpeg's pre-play stream probe
        //    so the first frame appears sooner. 2s is ample to detect audio+
        //    video on normal streams; raise it if a source ever loses a track.
        await p.setProperty(
          'demuxer-lavf-o',
          'extension_picky=0,allowed_extensions=ALL,http_persistent=0,'
              'analyzeduration=2000000',
        );
        // ── Anti-buffering: prefetch a LARGE read-ahead. ──────────────────
        // mpv's default read-ahead is ~1s, so any CDN/network dip — made worse
        // by http_persistent=0's per-segment reconnects — stalls playback
        // instantly. Buffering ~30–60s ahead absorbs those dips. Playback still
        // starts as soon as there's enough to begin, then keeps filling ahead,
        // so this doesn't slow startup; ~128 MiB forward buffer is fine on phones.
        await p.setProperty('cache', 'yes');
        await p.setProperty('cache-secs', '60');
        await p.setProperty('demuxer-readahead-secs', '60');
        await p.setProperty('demuxer-max-bytes', '128MiB');
        await p.setProperty('demuxer-max-back-bytes', '48MiB');
        // ── A/V stays in sync after a mid-stream stall. ───────────────────────
        // Symptom this fixes: a movie/episode freezes mid-playback (host throttle
        // or a brief dip — not a visible "buffering"), and on recovery the audio
        // runs AHEAD of the picture. Cause: Android's DIRECT mediacodec decoder
        // freezes its last frame on the output surface during the hiccup while
        // the audio track keeps draining, so audio ends up seconds ahead and
        // mpv's default A/V sync (~0.1s/frame) can't claw it back. COPY mode
        // routes frames through mpv's own pipeline, timed against the audio
        // clock, so it drops/resyncs cleanly after a stall — the robustness
        // ExoPlayer/CloudStream get from decoder fallback + shared-clock
        // renderers. Still hardware-decoded; mpv falls back to software per-codec
        // if a device can't hw-decode it.
        await p.setProperty('hwdec', 'mediacodec-copy');
        // On a cache underrun, pause audio+video together and wait until a little
        // is rebuffered before resuming, so they restart in lock-step instead of
        // audio-ahead (mirrors ExoPlayer's buffer-for-playback-after-rebuffer).
        await p.setProperty('cache-pause', 'yes');
        await p.setProperty('cache-pause-wait', '2');
        // ── In-app volume + boost (CloudStream-style). The gain is a SOFTWARE
        // audio filter (af=volume=N), so a >100% boost is genuinely louder than
        // the source even when the phone's system volume is low. ────────────
        await p.setProperty('volume-max', '200');
        await p.setProperty('volume', '100'); // neutral base — gain is via af
        await p.setProperty('af', _audioFilterChain());
      } catch (_) {}
      // Make the bundled subtitle fonts available to mpv/libass (which can't
      // read Flutter's asset bundle). Fire-and-forget so it never delays the
      // first open; the font picker just works once it's done.
      unawaited(_setupSubtitleFonts(p));
    }
  }

  // Extract-once guard (static: shared across engine instances this session).
  static bool _subFontsExtracted = false;

  /// MOVED verbatim from PlayerController._setupSubtitleFonts().
  /// Copy the app's bundled .ttf subtitle fonts to a real on-disk folder and
  /// point mpv/libass at it via `sub-fonts-dir`, so `sub-font` (the Subtitle
  /// style picker) can actually resolve them. Best-effort, never throws.
  Future<void> _setupSubtitleFonts(NativePlayer p) async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/sub_fonts',
      );
      if (!_subFontsExtracted) {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        const fontAssets = <String>[
          'assets/fonts/Inter.ttf',
          'assets/fonts/Poppins-Regular.ttf',
          'assets/fonts/Roboto-Regular.ttf',
          'assets/fonts/OpenSans-Regular.ttf',
          'assets/fonts/Lato-Regular.ttf',
          'assets/fonts/Montserrat-Regular.ttf',
          'assets/fonts/Nunito-Regular.ttf',
          'assets/fonts/Rubik-Regular.ttf',
          'assets/fonts/NotoSans-Regular.ttf',
          'assets/fonts/SourceSans3-Regular.ttf',
        ];
        for (final a in fontAssets) {
          final out = File('${dir.path}/${a.split('/').last}');
          if (!out.existsSync()) {
            try {
              final data = await rootBundle.load(a);
              await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
            } catch (_) {}
          }
        }
        _subFontsExtracted = true;
      }
      // 'auto' → on Android (no fontconfig) libass uses the embedded provider,
      // which scans sub-fonts-dir; the family name in sub-font then matches.
      await p.setProperty('sub-fonts-dir', dir.path);
      await p.setProperty('sub-font-provider', 'auto');
    } catch (_) {}
  }

  /// MOVED verbatim from PlayerController._audioFilterChain().
  /// The mpv audio-filter chain from prefs. `volume=N` is a SOFTWARE gain on
  /// the decoded audio (applied inside libmpv, before the output) — so a
  /// >100% boost is genuinely louder than the source, independent of the
  /// Android system volume. dynaudnorm runs first so the user's boost isn't
  /// normalized away.
  String _audioFilterChain() {
    final prefs = sl<PlaybackPrefs>();
    final parts = <String>[];
    if (prefs.audioNormalize) parts.add('dynaudnorm');
    if (prefs.volumeBoost != 100) {
      parts.add('volume=${(prefs.volumeBoost / 100).toStringAsFixed(2)}');
    }
    return parts.join(',');
  }

  @override ValueListenable<Duration> get position => _position;
  @override ValueListenable<Duration> get duration => _duration;
  @override ValueListenable<bool> get playing => _playing;
  @override ValueListenable<bool> get buffering => _buffering;
  @override ValueListenable<bool> get completed => _completed;
  @override ValueListenable<double> get rate => _rate;
  @override ValueListenable<int> get videoWidth => _videoWidth;
  @override ValueListenable<List<EngineTrack>> get audioTracks => _audioTracks;
  @override ValueListenable<List<EngineTrack>> get textTracks => _textTracks;
  @override Stream<EngineError> get errors => _errors.stream;

  @override
  Future<void> load(EngineSource source,
      {Duration startAt = Duration.zero}) async {
    await _configured;
    await _player.open(
      Media(source.url, httpHeaders: source.headers, start: startAt),
      play: false,
    );
  }

  @override Future<void> play() => _player.play();
  @override Future<void> pause() => _player.pause();
  @override Future<void> seek(Duration to) => _player.seek(to);
  @override Future<void> setRate(double rate) async {
    await _player.setRate(rate);
    _rate.value = rate;
  }
  @override Future<void> setVolume(double volume) =>
      _player.setVolume(volume * 100);

  @override
  Future<void> setVolumeBoost(int percent) async {
    // MOVED (adapted) from PlayerController.setVolumeBoost(): persists the
    // boost to prefs, then re-applies the mpv audio-filter chain — same
    // behaviour as _applyAudioFilters().
    await sl<PlaybackPrefs>().setVolumeBoost(percent.clamp(0, 200));
    final p = _player.platform;
    if (p is! NativePlayer) return;
    try {
      await p.setProperty('af', _audioFilterChain());
    } catch (_) {}
  }

  @override
  Future<void> selectAudioTrack(String id) => _player.setAudioTrack(
        _player.state.tracks.audio.firstWhere((t) => t.id == id),
      );
  @override
  Future<void> selectTextTrack(String? id) => id == null
      ? _player.setSubtitleTrack(SubtitleTrack.no())
      : _player.setSubtitleTrack(
          _player.state.tracks.subtitle.firstWhere((t) => t.id == id));
  @override
  Future<void> addExternalSubtitle(String uriOrPath,
          {String? language, bool select = true}) =>
      _player.setSubtitleTrack(SubtitleTrack.uri(uriOrPath, language: language));
  @override
  Future<void> setSubtitleStyle(EngineSubtitleStyle style) async {
    // mpv renders subs via the Flutter Video overlay (SubtitleViewConfiguration),
    // NOT mpv props — so style is applied at buildVideo time. Store it.
    _style = style;
    _styleRev.value++;
  }

  EngineSubtitleStyle _style = const EngineSubtitleStyle();
  final _styleRev = ValueNotifier<int>(0);

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty(
            'sub-delay', (delay.inMilliseconds / 1000).toString());
      } catch (_) {}
    }
  }

  @override
  Future<void> setAudioDelay(Duration delay) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty(
            'audio-delay', (delay.inMilliseconds / 1000).toString());
      } catch (_) {}
    }
  }

  @override
  Future<void> setMaxVideoBitrate(int bandwidth) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      final target = bandwidth <= 0 ? 'max' : '$bandwidth';
      try {
        await p.setProperty('hls-bitrate', target);
      } catch (_) {}
    }
  }

  @override
  Widget buildVideo(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _styleRev,
      builder: (context, _, _) => Video(
        controller: _videoController,
        subtitleViewConfiguration: _subtitleConfigFromStyle(),
      ),
    );
  }

  /// MOVED (adapted) from PlayerScreen._subtitleConfig(): same visual output,
  /// reading the engine-agnostic [_style] instead of PlaybackPrefs directly
  /// (fgColor/bgColor arrive pre-parsed as ARGB ints instead of hex strings).
  SubtitleViewConfiguration _subtitleConfigFromStyle() {
    final fam = (_style.fontPath == null || _style.fontPath!.isEmpty)
        ? null
        : _style.fontPath;
    // position 0 (top) … 100 (bottom). Higher value → nearer the bottom (less
    // bottom padding); lower value lifts the text up the frame.
    final pos = _style.position.clamp(0, 100);
    final bottom = 16.0 + (100 - pos) * 3.0;
    return SubtitleViewConfiguration(
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      style: TextStyle(
        height: 1.4,
        fontSize: 32.0 * _style.scale,
        fontFamily: fam,
        fontWeight: FontWeight.w600,
        color: _style.fgColor == null
            ? const Color(0xFFFFFFFF)
            : Color(_style.fgColor!),
        backgroundColor: _style.bgColor == null
            ? const Color(0x00000000)
            : Color(_style.bgColor!),
        // A soft shadow keeps text legible when the background box is off.
        shadows: const [Shadow(blurRadius: 4, color: Color(0xCC000000))],
      ),
    );
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _errors.close();
    await _player.dispose();
    _position.dispose();
    _duration.dispose();
    _playing.dispose();
    _buffering.dispose();
    _completed.dispose();
    _rate.dispose();
    _videoWidth.dispose();
    _audioTracks.dispose();
    _textTracks.dispose();
    _styleRev.dispose();
  }
}
