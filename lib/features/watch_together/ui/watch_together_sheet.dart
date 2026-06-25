import 'package:flutter/material.dart';

import '../model/room_state.dart';
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
                if (code == null) return;
                final ok = await controller.join(code.toUpperCase());
                if (!ctx.mounted) return;
                if (ok) {
                  Navigator.pop(ctx);
                } else {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Room not found')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    ),
  );
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
