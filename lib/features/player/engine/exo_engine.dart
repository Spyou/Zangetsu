// lib/features/player/engine/exo_engine.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/playback/tv_track_helpers.dart';
import '../tv_exo_controller.dart';
import 'playback_engine.dart';

/// ExoPlayer implementation of [PlaybackEngine], wrapping the native
/// `ExoPlayerView` PlatformView via [TvExoController]. The controller only
/// exists once the platform view is created, so [load] before that stashes
/// the source and replays it in [_bind].
class ExoEngine implements PlaybackEngine {
  TvExoController? _c;

  EngineSource? _pending;
  Duration _pendingStart = Duration.zero;

  // Last-loaded source + external subs, kept so addExternalSubtitle can
  // rebuild setSource with the sidecar sub added (ExoPlayer only takes
  // subtitle configs at setSource time, not as a live "add track" call).
  EngineSource? _lastSource;
  final _externalSubs = <TvSubtitleConfig>[];

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
  Stream<Duration> get positionStream => _streamOf(_position);
  @override
  Stream<Duration> get durationStream => _streamOf(_duration);
  @override
  Stream<bool> get playingStream => _streamOf(_playing);
  @override
  Stream<bool> get bufferingStream => _streamOf(_buffering);
  @override
  Stream<bool> get completedStream => _streamOf(_completed);
  @override
  Stream<int> get widthStream => _streamOf(_videoWidth);
  // ExoPlayer exposes no buffered-ahead position to Dart today; the seek
  // bar's buffered indicator simply won't fill for this engine.
  @override
  Stream<Duration> get bufferedStream => const Stream<Duration>.empty();

  /// Turns a [ValueListenable] into a broadcast [Stream], seeded with the
  /// current value on listen (ExoPlayer has no raw streams to forward).
  Stream<T> _streamOf<T>(ValueListenable<T> listenable) {
    late final StreamController<T> controller;
    void listener() => controller.add(listenable.value);
    controller = StreamController<T>.broadcast(
      onListen: () {
        listenable.addListener(listener);
        controller.add(listenable.value);
      },
      onCancel: () => listenable.removeListener(listener),
    );
    return controller.stream;
  }

  void _bind(int id) {
    final c = TvExoController(id);
    _c = c;
    c.position.addListener(() => _position.value = Duration(milliseconds: c.position.value));
    c.duration.addListener(() => _duration.value = Duration(milliseconds: c.duration.value));
    c.playing.addListener(() => _playing.value = c.playing.value);
    c.buffering.addListener(() => _buffering.value = c.buffering.value);
    c.ended.addListener(() => _completed.value = c.ended.value);
    c.videoWidth.addListener(() => _videoWidth.value = c.videoWidth.value);
    c.audioTracks.addListener(() => _audioTracks.value = _mapTracks(c.audioTracks.value));
    c.textTracks.addListener(() => _textTracks.value = _mapTracks(c.textTracks.value));
    c.onFatalError = (code, framesRendered) =>
        _errors.add(EngineError(code: code, framesRendered: framesRendered));

    final pending = _pending;
    if (pending != null) {
      _pending = null;
      unawaited(load(pending, startAt: _pendingStart));
    }
  }

  List<EngineTrack> _mapTracks(List<TvTrack> tracks) => [
        for (final t in tracks)
          EngineTrack(
            id: t.id,
            language: t.language,
            label: t.label,
            selected: t.selected,
          ),
      ];

  @override
  Future<void> load(EngineSource source, {Duration startAt = Duration.zero}) async {
    final c = _c;
    if (c == null) {
      _pending = source;
      _pendingStart = startAt;
      return;
    }
    _lastSource = source;
    _externalSubs.clear();
    await c.setSource(source.url, source.headers, mimeType: source.mimeType);
    if (startAt > Duration.zero) await c.seek(startAt.inMilliseconds);
    await c.play();
  }

  @override Future<void> play() => _c?.play() ?? Future.value();
  @override Future<void> pause() => _c?.pause() ?? Future.value();

  @override
  Future<void> playOrPause() {
    final c = _c;
    if (c == null) return Future.value();
    return _playing.value ? c.pause() : c.play();
  }

  @override
  Future<void> seek(Duration to) => _c?.seek(to.inMilliseconds) ?? Future.value();

  @override
  Future<void> setRate(double rate) async {
    _rate.value = rate;
    await _c?.setPlaybackSpeed(rate);
  }

  // exo: device volume is handled by the OS/native view; no per-engine gain
  // knob exists here (volume boost below covers the "louder than 100%" case).
  @override
  Future<void> setVolume(double volume) => Future.value();

  @override
  Future<void> setVolumeBoost(int percent) =>
      _c?.setVolumeBoost(percent) ?? Future.value();

  @override
  Future<void> selectAudioTrack(String id) =>
      _c?.selectAudioTrack(id) ?? Future.value();

  @override
  Future<void> selectTextTrack(String? id) =>
      _c?.selectTextTrack(id) ?? Future.value();

  @override
  Future<void> addExternalSubtitle(String uriOrPath,
      {String? language, bool select = true}) async {
    final c = _c;
    final src = _lastSource;
    if (c == null || src == null) return;
    _externalSubs.add(TvSubtitleConfig(
      url: uriOrPath,
      lang: language ?? '',
      mime: subtitleMime(null, url: uriOrPath),
    ));
    final resumeAt = _position.value;
    await c.setSource(src.url, src.headers,
        subtitles: List.unmodifiable(_externalSubs), mimeType: src.mimeType);
    if (resumeAt > Duration.zero) await c.seek(resumeAt.inMilliseconds);
    await c.play();
  }

  @override
  Future<void> setSubtitleStyle(EngineSubtitleStyle style) {
    final fg = style.fgColor ?? 0xFFFFFFFF;
    final bg = style.bgColor ?? 0x00000000;
    return _c?.applyCaptionStyle(
          TvCaptionStyle(
            scale: style.scale,
            fgColor: fg,
            bgColor: bg,
            edge: style.edge != 0,
            position: (style.position.clamp(0, 100)) / 100.0,
          ),
          fontPath: style.fontPath,
        ) ??
        Future.value();
  }

  // exo: no native sub/audio-delay; handled by routing exotic sources to mpv
  @override
  Future<void> setSubtitleDelay(Duration delay) => Future.value();

  // exo: no native sub/audio-delay; handled by routing exotic sources to mpv
  @override
  Future<void> setAudioDelay(Duration delay) => Future.value();

  @override
  Future<void> setMaxVideoBitrate(int bandwidth) =>
      _c?.setMaxVideoBitrate(bandwidth) ?? Future.value();

  @override
  Widget buildVideo(BuildContext context, {BoxFit fit = BoxFit.contain}) {
    // fit: the native SurfaceView/PlayerView self-fits; there is no
    // native resize-mode creationParam wired up today, so [fit] is unused.
    return PlatformViewLink(
      viewType: 'zangetsu/exoplayer_view',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
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
          ..addOnPlatformViewCreatedListener(_bind)
          ..create();
        return controller;
      },
    );
  }

  @override
  Future<void> dispose() async {
    _c?.dispose();
    await _errors.close();
    _position.dispose();
    _duration.dispose();
    _playing.dispose();
    _buffering.dispose();
    _completed.dispose();
    _rate.dispose();
    _videoWidth.dispose();
    _audioTracks.dispose();
    _textTracks.dispose();
  }
}
