import 'dart:async';

import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../models/video_source.dart';
import '../torrent/torrent_prefs.dart';
import '../torrent/torrent_service.dart';
import 'debrid_provider.dart';
import 'debrid_resolver.dart';
import 'debrid_result.dart';

class PlayableTorrentException implements Exception {
  const PlayableTorrentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PlayableTorrentResult {
  const PlayableTorrentResult({
    required this.source,
    this.localTorrentId,
  });

  final VideoSource source;

  /// Non-null when playback is a local libtorrent HTTP stream that must be
  /// stopped with [TorrentService.stop].
  final String? localTorrentId;
}

/// Whether a failed / skipped debrid attempt should fall through to libtorrent.
bool shouldFallbackToLocal(DebridAttempt attempt, DebridMode mode) {
  if (attempt is DebridOk) return false;
  if (mode == DebridMode.always) return false;
  return true;
}

/// Shared magnet → playable HTTP source used by phone, TV Exo, and TV native.
class PlayableTorrent {
  PlayableTorrent({
    required this.debrid,
    required this.torrents,
    required this.torrentPrefs,
  });

  final DebridResolver debrid;
  final TorrentService torrents;
  final TorrentPrefs torrentPrefs;

  /// Resolves [s] to an HTTP [VideoSource]. Throws [PlayableTorrentException]
  /// with a user-facing message on hard failure (Always mode, wifi-only, local
  /// torrent error).
  Future<PlayableTorrentResult> resolve(
    VideoSource s, {
    void Function(String? phase)? onPhase,
  }) async {
    final attempt = await debrid.resolve(s.url, onPhase: onPhase);
    if (attempt is DebridOk) {
      onPhase?.call(null);
      return PlayableTorrentResult(
        source: _httpSource(s, attempt.resolved),
      );
    }
    if (!shouldFallbackToLocal(attempt, debrid.prefs.mode)) {
      onPhase?.call(null);
      final msg = attempt is DebridFailed
          ? attempt.error.message
          : "Couldn't resolve this torrent via debrid.";
      throw PlayableTorrentException(msg);
    }
    if (attempt is DebridFailed) {
      AppLogger.instance.log(
        'debrid prefer fallback (${attempt.error.kind.name}): '
        '${attempt.error.message}',
        level: 'W',
      );
    }
    return _startLocal(s, onPhase: onPhase);
  }

  Future<PlayableTorrentResult> _startLocal(
    VideoSource s, {
    void Function(String? phase)? onPhase,
  }) async {
    onPhase?.call('Finding peers…');
    final sub = torrents.events().listen((p) {
      final txt = switch (p.state) {
        TorrentState.finding => 'Finding peers…',
        TorrentState.buffering =>
          'Buffering ${(p.bufferPct * 100).clamp(0, 100).toStringAsFixed(0)}%'
              '${p.peers > 0 ? ' · ${p.peers} peers' : ''}',
        TorrentState.ready => 'Starting…',
        TorrentState.error => 'Finding peers…',
      };
      onPhase?.call(txt);
    });
    try {
      final t = await torrents.startStream(
        s.url,
        allowMobileData: torrentPrefs.allowMobileData,
      );
      await sub.cancel();
      onPhase?.call(null);
      return PlayableTorrentResult(
        source: VideoSource(
          url: t.localUrl,
          quality: s.quality,
          label: s.label,
          container: SourceContainer.mp4,
          kind: s.kind,
          audioLang: s.audioLang,
          subtitles: s.subtitles,
        ),
        localTorrentId: t.id,
      );
    } catch (e) {
      await sub.cancel();
      onPhase?.call(null);
      final msg = (e is PlatformException && e.code == 'wifi_only')
          ? 'Torrents are set to Wi-Fi only. Turn on mobile data for torrents '
              'in Settings › Torrents.'
          : "Couldn't stream this torrent — no peers or it timed out. "
              'Try another source.';
      throw PlayableTorrentException(msg);
    }
  }
}

VideoSource _httpSource(VideoSource original, DebridResolved resolved) {
  final name = (resolved.filename ?? resolved.url).toLowerCase();
  final container = name.contains('.m3u8')
      ? SourceContainer.hls
      : SourceContainer.mp4;
  return VideoSource(
    url: resolved.url,
    quality: original.quality,
    label: original.label,
    container: container,
    kind: original.kind,
    audioLang: original.audioLang,
    subtitles: original.subtitles,
  );
}
