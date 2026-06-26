// lib/features/watch_together/ui/party_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/di/injector.dart';
import '../../../core/ui/global_messenger.dart';
import '../watch_together_controller.dart';
import 'room_panel.dart';

/// App-wide party bar that overlays the top of every screen when a Watch Party
/// is active. Returns [SizedBox.shrink] when no party is running so it has
/// zero visual impact during normal use.
class PartyBar extends StatelessWidget {
  const PartyBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = sl<WatchTogetherController>();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final room = controller.room;
        if (room == null) return const SizedBox.shrink();

        final roleLabel = controller.isHost ? 'Hosting' : 'Watching';
        final code = room.code;
        final count = controller.participants.length;
        final modeLabel = controller.mode == 'playing' ? 'Playing' : 'Choosing…';

        return Material(
          color: Colors.black87,
          child: InkWell(
            onTap: () => showRoomParticipantsSheet(context, sl<WatchTogetherController>()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.people, color: Colors.white70, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    '$roleLabel · $code · $count watching · $modeLabel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  _BarButton(
                    icon: Icons.link,
                    label: 'Invite',
                    onTap: () => _copyInvite(code),
                  ),
                  const SizedBox(width: 4),
                  _BarButton(
                    icon: Icons.exit_to_app,
                    label: 'Leave',
                    onTap: () => sl<WatchTogetherController>().leave(),
                    color: Colors.redAccent,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyInvite(String code) async {
    await Clipboard.setData(ClipboardData(text: 'zangetsu://room/$code'));
    rootMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Invite copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white70,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
