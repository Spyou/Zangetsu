import 'package:flutter/foundation.dart' show debugPrint;

import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../provider/provider_registry.dart';
import '../repository/source_repository.dart';
import '../zmode/source_matcher.dart';
import '../zmode/playback_resolver.dart';
import '../zmode/zmode_ids.dart';

enum TvPlaybackLoadFailureKind {
  /// No streaming/manga/novel extensions installed for this mode.
  noSourcesInstalled,

  /// Sources exist but none matched this metadata title.
  noSourceMatch,

  /// A source matched the show but not this episode / returned no streams.
  episodeNotAvailable,

  /// Network, Cloudflare, or other unexpected failure.
  generic,
}

class TvPlaybackLoadFailure {
  const TvPlaybackLoadFailure(this.kind, {this.mode});

  final TvPlaybackLoadFailureKind kind;
  final ContentMode? mode;

  @override
  String toString() => 'TvPlaybackLoadFailure($kind, mode=$mode)';
}

ContentMode playbackContentMode({String? showUrl}) {
  final c = showUrl != null ? ZmodeIds.parseShow(showUrl) : null;
  if (c != null) {
    final mode = switch (c.kind) {
      ZKind.manga => ContentMode.manga,
      ZKind.novel => ContentMode.novel,
      _ => ContentMode.anime,
    };
    debugPrint(
      '[tv-playback] playbackContentMode · showUrl=$showUrl '
      '→ ZKind=${c.kind} → mode=$mode',
    );
    return mode;
  }
  if (sl.isRegistered<ContentModeCubit>()) {
    final mode = sl<ContentModeCubit>().state;
    debugPrint(
      '[tv-playback] playbackContentMode · no showUrl → cubit mode=$mode',
    );
    return mode;
  }
  debugPrint('[tv-playback] playbackContentMode · fallback → anime');
  return ContentMode.anime;
}

/// Checks whether at least one source is *installed and enabled* for [mode].
///
/// On TV, JS providers may not be loaded in the QuickJS runtime (loadAll is
/// skipped to avoid freezing the boot), so we check the **registry**
/// (ProviderRegistry) for JS sources rather than the runtime (ProviderManager).
/// CloudStream / Aniyomi / Mihon / LNReader sources are checked via their
/// respective managers, which don't depend on loadAll.
bool hasInstalledPlaybackSources(ContentMode mode) {
  // ── Runtime sources (loaded providers from all ecosystems) ──
  final runtime = sl<SourceRepository>().pickableSources;
  final runtimeIds = runtime.map((s) => s.id).toList();

  // ── Registry sources (installed + enabled JS providers) ──
  // On TV, loadAll() is skipped so _manager.all is empty even though sources
  // are installed. The registry is the source of truth for what's installed.
  final registryIds = <String>[];
  if (sl.isRegistered<ProviderRegistry>()) {
    for (final entry in sl<ProviderRegistry>().getAll()) {
      if (entry.enabled) {
        registryIds.add(entry.name);
      }
    }
  }

  // Merge: runtime + registry (deduplicated). This covers both the normal
  // phone path (runtime has everything) and the TV path (registry has what
  // the runtime doesn't because loadAll was skipped).
  final allIds = <String>{...runtimeIds, ...registryIds};

  debugPrint(
    '[tv-playback] hasInstalledPlaybackSources · mode=$mode · '
    'runtime=${runtimeIds.length} (${runtimeIds.take(5).join(",")}'
    '${runtimeIds.length > 5 ? "…" : ""}) · '
    'registry=${registryIds.length} (${registryIds.take(5).join(",")}'
    '${registryIds.length > 5 ? "…" : ""})',
  );

  final result = switch (mode) {
    ContentMode.manga => allIds.any((id) => id.startsWith('mihon:')),
    ContentMode.novel => allIds.any((id) => id.startsWith('lnr:')),
    ContentMode.anime => allIds.any(
      (id) => !id.startsWith('mihon:') && !id.startsWith('lnr:'),
    ),
  };
  debugPrint(
    '[tv-playback] hasInstalledPlaybackSources · mode=$mode → $result '
    '(${allIds.length} total candidate IDs)',
  );
  return result;
}

TvPlaybackLoadFailure classifyPlaybackError(
  Object? error, {
  required ContentMode mode,
}) {
  if (error is EpisodeNotAvailable) {
    final kind = error.hadTitleMatch
        ? TvPlaybackLoadFailureKind.episodeNotAvailable
        : TvPlaybackLoadFailureKind.noSourceMatch;
    debugPrint(
      '[tv-playback] classifyPlaybackError · EpisodeNotAvailable '
      '→ $kind (hadTitleMatch=${error.hadTitleMatch})',
    );
    return TvPlaybackLoadFailure(kind, mode: mode);
  }
  if (error is NoSourceMatch) {
    final hasSources = hasInstalledPlaybackSources(mode);
    final kind = hasSources
        ? TvPlaybackLoadFailureKind.noSourceMatch
        : TvPlaybackLoadFailureKind.noSourcesInstalled;
    debugPrint(
      '[tv-playback] classifyPlaybackError · NoSourceMatch '
      '→ $kind (hasSources=$hasSources)',
    );
    return TvPlaybackLoadFailure(kind, mode: mode);
  }
  debugPrint('[tv-playback] classifyPlaybackError · generic · $error');
  return TvPlaybackLoadFailure(TvPlaybackLoadFailureKind.generic, mode: mode);
}

TvPlaybackLoadFailure? noSourcesFailureForPlay({String? showUrl}) {
  final mode = playbackContentMode(showUrl: showUrl);
  final hasSources = hasInstalledPlaybackSources(mode);
  debugPrint(
    '[tv-playback] noSourcesFailureForPlay · showUrl=$showUrl '
    '→ mode=$mode hasSources=$hasSources',
  );
  if (hasSources) return null;
  debugPrint(
    '[tv-playback] noSourcesFailureForPlay → BLOCKING PLAY '
    '(no sources installed for mode=$mode)',
  );
  return TvPlaybackLoadFailure(
    TvPlaybackLoadFailureKind.noSourcesInstalled,
    mode: mode,
  );
}
