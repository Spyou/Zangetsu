// lib/features/watch_together/ui/room_panel.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../model/room_state.dart';
import '../watch_together_controller.dart';

/// Opens a bottom sheet listing room participants. The host sees a "Give
/// control" action per other participant; viewers see a read-only list.
/// Rebuilds reactively via [AnimatedBuilder] on [controller].
void showRoomParticipantsSheet(
    BuildContext context, WatchTogetherController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _RoomParticipantsSheet(controller: controller),
  );
}

class _RoomParticipantsSheet extends StatelessWidget {
  const _RoomParticipantsSheet({required this.controller});

  final WatchTogetherController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final participants = controller.participants;
        final canControl = controller.canControl;
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xE6121212),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar.
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Header.
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.group, color: Colors.white70, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Participants (${participants.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                // Participant rows.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: participants.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No participants yet',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: participants.length,
                          itemBuilder: (context, i) {
                            final p = participants[i];
                            final isThisHost =
                                controller.room?.hostId == p.userId;
                            return ListTile(
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.white12,
                                child: Text(
                                  (p.name.isEmpty ? '?' : p.name[0])
                                      .toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text(
                                p.name.isEmpty ? 'Guest' : p.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Row(
                                children: [
                                  if (isThisHost)
                                    const _Chip(
                                        label: 'HOST', color: Colors.amber),
                                  if (p.wantsControl && !isThisHost) ...[
                                    const _Chip(
                                        label: 'Wants control',
                                        color: Colors.blueAccent),
                                  ],
                                ],
                              ),
                              trailing: (canControl && !isThisHost)
                                  ? TextButton(
                                      onPressed: () async {
                                        Navigator.of(context).pop();
                                        await controller.grantControl(p.userId);
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                            content: Text(
                                                'Control given to ${p.name.isEmpty ? "Guest" : p.name}'),
                                          ));
                                        }
                                      },
                                      child: const Text(
                                        'Give control',
                                        style: TextStyle(
                                          color: Colors.greenAccent,
                                          fontSize: 12,
                                        ),
                                      ),
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4, top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// A compact presence strip shown in the player top-bar when a Watch Together
/// room is active. Displays the sync state (icon), participant count + room
/// code, and a "Leave" tap target. Tapping the participant count opens the
/// participants management sheet.
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
          GestureDetector(
            onTap: () => showRoomParticipantsSheet(context, controller),
            child: Text(
              '${controller.participants.length} watching · ${room.code}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              Clipboard.setData(
                  ClipboardData(text: 'zangetsu://room/${room.code}'));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Invite copied')));
            },
            child: const Icon(Icons.copy, size: 12, color: Colors.white54),
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

/// A compact side-panel chat widget for Watch Together.
///
/// Displays the room message history as a scrolling list and provides a
/// [TextField] + send button at the bottom. Rebuilds via [AnimatedBuilder]
/// whenever the [WatchTogetherController] notifies. Wrap in a [StatefulWidget]
/// so the [TextEditingController] is properly disposed.
class RoomChatPanel extends StatefulWidget {
  const RoomChatPanel({super.key, required this.controller});

  final WatchTogetherController controller;

  @override
  State<RoomChatPanel> createState() => _RoomChatPanelState();
}

class _RoomChatPanelState extends State<RoomChatPanel> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    widget.controller.sendChat(text);
    _textCtrl.clear();
    // Scroll to the bottom after sending.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final messages = widget.controller.messages;
        return Container(
          width: 280,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            border: Border(
              left: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            ),
          ),
          child: Column(
            children: [
              // Header.
              Container(
                height: 44,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom:
                        BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                ),
                child: const Text(
                  'Room Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              // Message list.
              Expanded(
                child: messages.isEmpty
                    ? const Center(
                        child: Text(
                          'No messages yet',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        itemCount: messages.length,
                        itemBuilder: (context, i) =>
                            _ChatBubble(message: messages[i]),
                      ),
              ),

              // Input row.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textCtrl,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Message…',
                          hintStyle: const TextStyle(
                              color: Colors.white38, fontSize: 13),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                        textInputAction: TextInputAction.send,
                        maxLines: 1,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send_rounded,
                          color: Colors.white70, size: 20),
                      onPressed: _send,
                      splashRadius: 20,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final RoomMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.name.isEmpty ? 'Guest' : message.name,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            message.text,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
