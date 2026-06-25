// lib/features/watch_together/ui/room_panel.dart
import 'package:flutter/material.dart';
import '../watch_together_controller.dart';

/// A compact presence strip shown in the player top-bar when a Watch Together
/// room is active. Displays the sync state (icon), participant count + room
/// code, and a "Leave" tap target.
///
/// Rebuild is driven by the existing _room listener in player_screen.dart (the
/// listener calls setState, which rebuilds the overlay that mounts this widget),
/// so no extra AnimatedBuilder is needed here.
class RoomStrip extends StatelessWidget {
  const RoomStrip({super.key, required this.controller});

  final WatchTogetherController controller;

  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (room == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            controller.synced ? Icons.sync : Icons.sync_problem,
            size: 16,
            color: controller.synced ? Colors.greenAccent : Colors.amber,
          ),
          const SizedBox(width: 6),
          Text(
            '${controller.participants.length} watching · ${room.code}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => controller.leave(),
            child: const Text(
              'Leave',
              style: TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
