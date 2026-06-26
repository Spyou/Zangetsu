import 'package:flutter/material.dart';

import '../../../core/di/injector.dart';
import '../../../core/playback/resume_store.dart';
import '../../../core/playback/watch_history.dart';
import '../../../core/repository/source_repository.dart';
import '../../player/player_screen.dart';
import '../model/room_state.dart';
import '../watch_room_service.dart';
import '../watch_together_controller.dart';

Future<void> showWatchTogetherSheet(
  BuildContext context, {
  required RoomState Function() buildInitialRoom,
  required WatchTogetherController controller,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF161616),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Watch Together',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.group_add),
              label: const Text('Create a room'),
              onPressed: () async {
                await controller.host(buildInitialRoom());
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Join with a code'),
              onPressed: () async {
                final code = await _askCode(ctx);
                if (code == null || code.trim().isEmpty || !ctx.mounted) return;
                final rootContext = Navigator.of(ctx, rootNavigator: true).context;
                Navigator.pop(ctx); // close the sheet
                await joinWatchPartyByCode(rootContext, code);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// Prompt for a room code and join it — used by the in-player sheet and the
/// dedicated "Join a watch party" entry (Settings).
Future<void> promptJoinWatchParty(BuildContext context) async {
  final code = await _askCode(context);
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  await joinWatchPartyByCode(context, code);
}

/// Fetch the room for [code] and launch a player for its show, auto-joining.
/// Shows "Room not found" if it's missing/ended. The player handles a missing
/// local source with a clear message (see PlayerScreen).
Future<void> joinWatchPartyByCode(BuildContext context, String code) async {
  final upper = code.trim().toUpperCase();
  if (upper.isEmpty) return;
  final room = await sl<WatchRoomService>().getRoom(upper);
  if (!context.mounted) return;
  if (room == null || room.status == 'ended') {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room not found')),
    );
    return;
  }
  final repo = sl<SourceRepository>();
  Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(
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
      joinRoomCode: upper,
    ),
  ));
}

Future<String?> _askCode(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Enter room code'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'e.g. ABC234'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Join'),
        ),
      ],
    ),
  );
}
