// lib/features/watch_together/ui/watch_party_lobby_screen.dart
import 'package:flutter/material.dart';

import '../../../core/di/injector.dart';
import '../../auth/auth_cubit.dart';
import '../model/room_state.dart';
import '../watch_together_controller.dart';
import 'host_choosing_screen.dart';

/// Create/Join entry screen for Watch Party.
///
/// - Create a party: login-gated; hosts a content-less lobby room then pops
///   (the party bar appears and the user browses normally as host).
/// - Join with a code: login-gated; joins via [WatchTogetherController.join]
///   and routes to the content player (mode `playing`) or
///   [HostChoosingScreen] (mode `lobby`).
class WatchPartyLobbyScreen extends StatefulWidget {
  const WatchPartyLobbyScreen({super.key});

  @override
  State<WatchPartyLobbyScreen> createState() => _WatchPartyLobbyScreenState();
}

class _WatchPartyLobbyScreenState extends State<WatchPartyLobbyScreen> {
  // True while a create/join request is in flight — drives the button spinner
  // ("Creating…") and blocks double-taps so the user knows it's working.
  bool _busy = false;

  // ── helpers ──────────────────────────────────────────────────────────────

  bool _isLoggedIn() => sl<AuthCubit>().state.user != null;

  void _showNotLoggedIn() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sign in to use Watch Party')),
    );
  }

  // ── Create ────────────────────────────────────────────────────────────────

  Future<void> _onCreate() async {
    if (_busy) return;
    if (!_isLoggedIn()) {
      _showNotLoggedIn();
      return;
    }

    final controller = sl<WatchTogetherController>();
    final messenger = ScaffoldMessenger.of(context);
    if (controller.room != null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("You're already in a party")),
      );
      return;
    }

    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await controller.host(const RoomState(
        code: '',
        hostId: '',
        hostName: '',
        hostAvatar: '',
        sourceId: '',
        sourceLabel: '',
        showUrl: '',
        showTitle: '',
        cover: '',
        episodeId: '',
        episodeNumber: null,
        episodeUrl: '',
        category: 'sub',
        malId: null,
        tmdbId: null,
        positionMs: 0,
        playing: false,
        rate: 1.0,
        updatedAt: 0,
        status: 'active',
        mode: 'lobby',
      ));
    } catch (e) {
      // host() can throw inside _enter() AFTER the room was created — in that
      // case room != null and we still proceed to pop below. Only surface an
      // error (and stop) when the room was genuinely never created.
      debugPrint('[watch-party] create failed: $e');
      if (controller.room == null) {
        if (mounted) setState(() => _busy = false);
        messenger.showSnackBar(
          SnackBar(content: Text("Couldn't create party: $e")),
        );
        return;
      }
    }
    if (mounted) setState(() => _busy = false);
    if (controller.room != null && nav.mounted) nav.pop();
  }

  // ── Join ──────────────────────────────────────────────────────────────────

  Future<void> _onJoin() async {
    if (_busy) return;
    if (!_isLoggedIn()) {
      _showNotLoggedIn();
      return;
    }

    final code = await _askCode(context);
    if (code == null || code.trim().isEmpty) return;
    if (!mounted) return;

    final controller = sl<WatchTogetherController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final ok = await controller.join(code.trim().toUpperCase());
    if (!mounted) return;
    setState(() => _busy = false);

    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Room not found')),
      );
      return;
    }

    if (mounted) await routeAfterJoin(context, controller);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E0E),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Watch Party',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon.
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.live_tv_outlined,
                    size: 40,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 24),

                const Text(
                  'Watch together',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 10),

                const Text(
                  'Create a party and invite friends, or join an existing one with a code.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                // Create button — shows a spinner + "Creating…" while the room
                // is being created (Appwrite round-trip), so the tap has visible
                // feedback instead of feeling unresponsive.
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.group_add),
                    label: Text(_busy ? 'Creating…' : 'Create a party'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _onCreate,
                  ),
                ),
                const SizedBox(height: 12),

                // Join button.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.login),
                    label: const Text('Join with a code'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _onJoin,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Post-join routing
// ─────────────────────────────────────────────────────────────────────────────

/// After a successful [WatchTogetherController.join], push [HostChoosingScreen]
/// as the party base.  If the host is already playing, the controller's viewer
/// follow-driver ([WatchTogetherController._followHost]) pushes the content
/// player on top immediately (it fires once at the end of [join]).
Future<void> routeAfterJoin(
  BuildContext context,
  WatchTogetherController controller,
) async {
  if (controller.room == null) return;

  final nav = Navigator.of(context, rootNavigator: true);
  nav.push(MaterialPageRoute(
    builder: (_) => const HostChoosingScreen(),
  ));
  controller.refollow();
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

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
