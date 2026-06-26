// lib/features/watch_together/ui/host_choosing_screen.dart
import 'package:flutter/material.dart';
import '../../../core/di/injector.dart';
import '../watch_together_controller.dart';
import 'room_panel.dart';

/// Portrait screen shown to a viewer whose party is in `mode: lobby` —
/// i.e. the host hasn't started playing anything yet.
///
/// Rebuilds via [AnimatedBuilder] on the app-level [WatchTogetherController].
/// Automatically pops when the room is cleared (party ended / viewer removed).
class HostChoosingScreen extends StatefulWidget {
  const HostChoosingScreen({super.key});

  @override
  State<HostChoosingScreen> createState() => _HostChoosingScreenState();
}

class _HostChoosingScreenState extends State<HostChoosingScreen> {
  bool _chatOpen = false;

  @override
  Widget build(BuildContext context) {
    final controller = sl<WatchTogetherController>();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Room was cleared (party ended / viewer removed) — pop automatically.
        if (controller.room == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const Scaffold(backgroundColor: Color(0xFF0E0E0E));
        }

        final room = controller.room!;
        final count = controller.participants.length;

        return Scaffold(
          backgroundColor: const Color(0xFF0E0E0E),
          body: SafeArea(
            child: Column(
              children: [
                // ── Main idle content ─────────────────────────────────────
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Icon.
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.07),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.live_tv_outlined,
                              size: 38,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Title.
                          const Text(
                            'Host is choosing…',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),

                          // Subtitle.
                          const Text(
                            "You'll start watching automatically when the host plays something.",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),

                          // Room code + participant count pill.
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.meeting_room_outlined,
                                    size: 14, color: Colors.white38),
                                const SizedBox(width: 6),
                                Text(
                                  room.code,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Icon(Icons.circle,
                                    size: 5, color: Colors.white24),
                                const SizedBox(width: 10),
                                Text(
                                  '$count watching',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Action buttons ────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(
                    children: [
                      // Chat toggle.
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.chat_bubble_outline_rounded,
                          label: 'Chat',
                          active: _chatOpen,
                          onTap: () => setState(() => _chatOpen = !_chatOpen),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Participants sheet.
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.group_outlined,
                          label: 'Participants',
                          onTap: () =>
                              showRoomParticipantsSheet(context, controller),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Leave.
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.exit_to_app_rounded,
                          label: 'Leave',
                          destructive: true,
                          onTap: () async {
                            final nav = Navigator.of(context);
                            await controller.leave();
                            if (mounted) nav.maybePop();
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Inline chat panel (bottom-anchored, toggleable) ───────
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeInOut,
                  child: _chatOpen
                      ? SizedBox(
                          height: 340,
                          child: RoomChatPanel(controller: controller),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small tappable action button used in the bottom row.
// ─────────────────────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final Color fg = destructive
        ? Colors.redAccent
        : active
            ? Colors.white
            : Colors.white70;
    final Color bg = active
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.06);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: destructive
                ? Colors.redAccent.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
