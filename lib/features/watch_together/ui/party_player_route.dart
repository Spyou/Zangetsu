// lib/features/watch_together/ui/party_player_route.dart
import 'package:flutter/material.dart';

import '../../../core/di/injector.dart';
import '../../../core/playback/resume_store.dart';
import '../../../core/playback/watch_history.dart';
import '../../../core/repository/source_repository.dart';
import '../../player/player_screen.dart';
import '../model/room_state.dart';

/// Returns a [MaterialPageRoute] that opens [PlayerScreen] configured for a
/// Watch Party room.  Used both by [routeAfterJoin] (lobby screen) and by the
/// viewer follow-driver in [WatchTogetherController] so both code paths build
/// an identical player without a lobby↔controller import cycle.
///
/// `joinRoomCode` is intentionally omitted — the viewer has already joined via
/// [WatchTogetherController.join] before this route is pushed.
MaterialPageRoute<dynamic> buildPartyPlayerRoute(RoomState room) {
  final repo = sl<SourceRepository>();
  return MaterialPageRoute(
    builder: (_) => PopScope(
      canPop: false,                          // viewer can't Back out of the synced player…
      onPopInvokedWithResult: (didPop, _) {}, // …they leave via the party bar's Leave
      child: PlayerScreen(
        sourceId: room.sourceId,
        episodesResolver: () => repo.episodes(
          room.showUrl,
          category: room.category,
          sourceId: room.sourceId,
        ),
        resumeEpisodeId: room.episodeId,
        resumeEpisodeNumber: room.episodeNumber,
        resumePosition: Duration(milliseconds: room.positionMs),
        resume: sl<ResumeStore>(),
        resolveSources: (u) =>
            repo.sources(u, sourceId: room.sourceId, fast: true),
        history: sl<WatchHistory>(),
        showTitle: room.showTitle,
        cover: room.cover,
        showUrl: room.showUrl,
        category: room.category,
        malId: room.malId,
        // joinRoomCode intentionally omitted — join already happened.
      ),
    ),
  );
}
