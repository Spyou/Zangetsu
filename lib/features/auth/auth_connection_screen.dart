import 'package:flutter/material.dart';

/// One-time feedback while a changed auth connection is checked at launch.
enum AuthConnectionPhase { idle, preparing, ready, failed }

class AuthConnectionScreen extends StatelessWidget {
  const AuthConnectionScreen({super.key, required this.phase, this.onContinue});
  final AuthConnectionPhase phase;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ready = phase == AuthConnectionPhase.ready;
    final failed = phase == AuthConnectionPhase.failed;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: ready ? 'Connection ready' : 'Checking connection',
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: ready || failed
                        ? TweenAnimationBuilder<double>(
                            tween: Tween(begin: ready ? 0.8 : 1, end: 1),
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 300),
                            builder: (_, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: Icon(
                              ready
                                  ? Icons.check_circle_rounded
                                  : Icons.cloud_off_rounded,
                              size: 64,
                              color: colors.primary,
                            ),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    ready
                        ? 'All set. Welcome back!'
                        : failed
                        ? 'Couldn’t finish connecting'
                        : 'Getting things ready…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  failed
                      ? 'Your saved data is still here. Try again when you’re online.'
                      : 'Your account and lists stay with you.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (failed && onContinue != null) ...[
                  const SizedBox(height: 24),
                  FilledButton(
                    autofocus: true,
                    onPressed: onContinue,
                    child: const Text('Continue'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthConnectionOverlay extends StatefulWidget {
  const AuthConnectionOverlay({
    super.key,
    required this.phase,
    required this.child,
  });
  final ValueNotifier<AuthConnectionPhase> phase;
  final Widget child;

  @override
  State<AuthConnectionOverlay> createState() => _AuthConnectionOverlayState();
}

class _AuthConnectionOverlayState extends State<AuthConnectionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _confirmation;

  @override
  void initState() {
    super.initState();
    _confirmation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 650),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed &&
              widget.phase.value == AuthConnectionPhase.ready) {
            widget.phase.value = AuthConnectionPhase.idle;
          }
        });
    widget.phase.addListener(_update);
    _update();
  }

  void _update() {
    if (widget.phase.value == AuthConnectionPhase.ready) {
      _confirmation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    widget.phase.removeListener(_update);
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<AuthConnectionPhase>(
        valueListenable: widget.phase,
        builder: (context, phase, _) => Stack(
          children: [
            ExcludeFocus(
              excluding: phase != AuthConnectionPhase.idle,
              child: ExcludeSemantics(
                excluding: phase != AuthConnectionPhase.idle,
                child: widget.child,
              ),
            ),
            if (phase != AuthConnectionPhase.idle)
              Positioned.fill(
                child: AuthConnectionScreen(
                  phase: phase,
                  onContinue: () =>
                      widget.phase.value = AuthConnectionPhase.idle,
                ),
              ),
          ],
        ),
      );
}
