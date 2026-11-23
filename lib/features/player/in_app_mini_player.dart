import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

final dockedPlayer = ValueNotifier<InAppMiniPlayer?>(null);

/// Displays the active dock over routes while allowing taps outside the card.
class InAppMiniPlayerHost extends StatelessWidget {
  const InAppMiniPlayerHost({
    super.key,
    required this.dockedPlayer,
    required this.child,
  });

  final ValueNotifier<InAppMiniPlayer?> dockedPlayer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<InAppMiniPlayer?>(
      valueListenable: dockedPlayer,
      child: child,
      builder: (context, player, child) =>
          Stack(fit: StackFit.expand, children: [child!, ?player]),
    );
  }
}

/// A floating video card whose parent supplies the available browsing area.
class InAppMiniPlayer extends StatefulWidget {
  const InAppMiniPlayer({
    super.key,
    required this.video,
    this.retainedRoute,
    this.entranceReady,
    required this.playing,
    this.playingChanges,
    this.systemPipChanges,
    this.playLabel,
    this.pauseLabel,
    required this.playPauseLabel,
    required this.closeLabel,
    required this.restoreLabel,
    required this.onTogglePlayback,
    required this.onClose,
    required this.onRestore,
  });

  final Widget video;
  final Widget? retainedRoute;
  final Future<void>? entranceReady;
  final bool playing;
  final Stream<bool>? playingChanges;
  final Stream<bool>? systemPipChanges;
  final String? playLabel;
  final String? pauseLabel;
  final String playPauseLabel;
  final String closeLabel;
  final String restoreLabel;
  final VoidCallback onTogglePlayback;
  final VoidCallback onClose;
  final VoidCallback onRestore;

  @override
  State<InAppMiniPlayer> createState() => _InAppMiniPlayerState();
}

class _InAppMiniPlayerState extends State<InAppMiniPlayer>
    with WidgetsBindingObserver {
  bool _trailing = true;
  bool _bottom = true;
  Offset? _dragPosition;
  double _preferredWidth = 216;
  double _gestureWidth = 216;
  double? _pinchSurfaceWidth;
  bool _wasSystemPip = false;
  bool _showControls = false;
  final _cardKey = GlobalKey();
  late final _entranceReady = widget.entranceReady?.timeout(
    const Duration(milliseconds: 450),
    onTimeout: () {},
  );

  bool _entranceStarted = false;
  bool _expanding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_entranceStarted &&
        widget.entranceReady != null &&
        state == AppLifecycleState.resumed) {
      setState(() {});
    }
  }

  static const _settleDuration = Duration(milliseconds: 320);

  Widget _control(
    String label,
    IconData icon,
    VoidCallback pressed, {
    double size = 20,
  }) {
    return Semantics(
      label: label,
      child: IconButton(
        color: Colors.white,
        iconSize: size,
        onPressed: pressed,
        icon: Icon(icon),
      ),
    );
  }

  void _expand() {
    if (_expanding) return;
    if (_entranceReady == null || MediaQuery.disableAnimationsOf(context)) {
      widget.onRestore();
      return;
    }
    setState(() {
      _showControls = false;
      _expanding = true;
    });
  }

  void _finishExpand() {
    widget.onRestore();
    if (mounted) setState(() => _expanding = false);
  }

  Widget _withEntrance({
    required bool animate,
    required Alignment alignment,
    required Widget child,
  }) {
    if (_entranceReady == null) return child;
    return FutureBuilder<void>(
      future: _entranceReady,
      builder: (context, snapshot) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (!animate ||
            (snapshot.connectionState == ConnectionState.done &&
                (lifecycle == null ||
                    lifecycle == AppLifecycleState.resumed))) {
          _entranceStarted = true;
        }
        final expanding = _expanding;
        return TweenAnimationBuilder<double>(
          tween: Tween(
            begin: 0,
            end: expanding
                ? 2
                : _entranceStarted
                ? 1
                : 0,
          ),
          duration: !animate
              ? Duration.zero
              : Duration(milliseconds: expanding ? 200 : 240),
          curve: Curves.easeOutCubic,
          onEnd: expanding ? _finishExpand : null,
          builder: (context, progress, child) {
            final exit = math.max(0.0, progress - 1);
            final opacity = math.min(progress, 1.0) * (1 - exit);
            return IgnorePointer(
              ignoring: !_entranceStarted || expanding,
              child: Opacity(
                // Paint the native view while its first frame is pending.
                opacity: .01 + .99 * opacity,
                child: Transform.translate(
                  offset:
                      Offset(-12 * alignment.x, -28 * alignment.y) *
                      (1 - progress).abs(),
                  child: Transform.scale(
                    alignment: alignment,
                    scale: .90 + .10 * progress,
                    child: child,
                  ),
                ),
              ),
            );
          },
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: widget.systemPipChanges,
      builder: (context, snapshot) => _buildCard(snapshot.data == true),
    );
  }

  Widget _buildCard(bool systemPip) {
    final pipChanged = systemPip != _wasSystemPip;
    _wasSystemPip = systemPip;
    if (systemPip) {
      _showControls = false;
      _pinchSurfaceWidth = null;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SafeArea(
      left: !systemPip,
      top: !systemPip,
      right: !systemPip,
      bottom: !systemPip,
      minimum: systemPip
          ? EdgeInsets.zero
          // shortcut: fixed clearance for the phone navigation bar, measure the
          // shell's dock if it starts covering taller navigation layouts.
          : EdgeInsets.fromLTRB(
              12,
              12,
              12,
              96 + MediaQuery.viewInsetsOf(context).bottom,
            ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = math.min(
            360.0,
            math.min(constraints.maxWidth, constraints.maxHeight * 16 / 9),
          );
          final minWidth = math.min(144.0, maxWidth);
          final width = systemPip
              ? constraints.maxWidth
              : math.min(_preferredWidth, maxWidth);
          final height = systemPip ? constraints.maxHeight : width * 9 / 16;
          final surfaceWidth = _pinchSurfaceWidth ?? width;
          final surfaceHeight = systemPip ? height : surfaceWidth * 9 / 16;
          final right = constraints.maxWidth - width;
          final bottom = math.max(0.0, constraints.maxHeight - height);
          final rtl = Directionality.of(context) == TextDirection.rtl;
          final corner = Offset(
            _trailing != rtl ? right : 0,
            _bottom ? bottom : 0,
          );
          Offset clamp(Offset offset, double cardWidth) => Offset(
            offset.dx.clamp(
              0.0,
              math.max(0.0, constraints.maxWidth - cardWidth),
            ),
            offset.dy.clamp(
              0.0,
              math.max(0.0, constraints.maxHeight - cardWidth * 9 / 16),
            ),
          );
          final position = systemPip
              ? Offset.zero
              : clamp(_dragPosition ?? corner, width);

          void snap() {
            final currentWidth = math.min(_preferredWidth, maxWidth);
            final released = clamp(_dragPosition ?? corner, currentWidth);
            setState(() {
              _trailing =
                  (released.dx >= (constraints.maxWidth - currentWidth) / 2) !=
                  rtl;
              _bottom =
                  released.dy >=
                  (constraints.maxHeight - currentWidth * 9 / 16) / 2;
              _dragPosition = null;
              _pinchSurfaceWidth = null;
            });
          }

          return Stack(
            children: [
              AnimatedPositioned(
                duration:
                    !reduceMotion &&
                        !pipChanged &&
                        !systemPip &&
                        _dragPosition == null
                    ? _settleDuration
                    : Duration.zero,
                curve: const _DockSpringCurve(),
                left: position.dx,
                top: position.dy,
                child: _withEntrance(
                  animate: !systemPip && !reduceMotion,
                  alignment: Alignment(
                    _trailing != rtl ? 1 : -1,
                    _bottom ? 1 : -1,
                  ),
                  child: Transform.scale(
                    alignment: Alignment.topLeft,
                    scale: surfaceWidth > 0 ? width / surfaceWidth : 1,
                    child: SizedBox(
                      width: surfaceWidth,
                      height: surfaceHeight,
                      child: Material(
                        key: _cardKey,
                        color: Colors.black,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(systemPip ? 0 : 16),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(child: widget.video),
                            if (widget.retainedRoute case final route?)
                              Offstage(child: route),
                            if (!systemPip)
                              Semantics(
                                button: true,
                                label: MaterialLocalizations.of(
                                  context,
                                ).moreButtonTooltip,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: width < 144
                                      ? _expand
                                      : () => setState(
                                          () => _showControls = !_showControls,
                                        ),
                                  onScaleStart: (_) {
                                    final card = _cardKey.currentContext
                                        ?.findRenderObject();
                                    final bounds = context.findRenderObject();
                                    final visiblePosition =
                                        card is RenderBox && bounds is RenderBox
                                        ? card.localToGlobal(
                                            Offset.zero,
                                            ancestor: bounds,
                                          )
                                        : position;
                                    setState(() {
                                      _showControls = false;
                                      _gestureWidth = width;
                                      _dragPosition = visiblePosition;
                                    });
                                  },
                                  onScaleUpdate: (details) => setState(() {
                                    final currentWidth = math.min(
                                      _preferredWidth,
                                      maxWidth,
                                    );
                                    final origin = clamp(
                                      _dragPosition ?? corner,
                                      currentWidth,
                                    );
                                    if (details.pointerCount < 2) {
                                      _dragPosition = clamp(
                                        origin + details.focalPointDelta,
                                        currentWidth,
                                      );
                                      return;
                                    }

                                    _pinchSurfaceWidth ??= currentWidth;
                                    final nextWidth =
                                        (_gestureWidth * details.scale).clamp(
                                          minWidth,
                                          maxWidth,
                                        );
                                    final change = currentWidth - nextWidth;
                                    _preferredWidth = nextWidth;
                                    _dragPosition = clamp(
                                      origin +
                                          Offset(
                                            _trailing != rtl ? change : 0,
                                            _bottom ? change * 9 / 16 : 0,
                                          ),
                                      nextWidth,
                                    );
                                  }),
                                  onScaleEnd: (_) => snap(),
                                ),
                              ),
                            if (!systemPip &&
                                _showControls &&
                                width >= 144) ...[
                              const IgnorePointer(
                                child: ColoredBox(color: Colors.black38),
                              ),
                              Align(
                                alignment: Alignment.topRight,
                                child: _control(
                                  widget.restoreLabel,
                                  Icons.open_in_full_rounded,
                                  _expand,
                                ),
                              ),
                              Align(
                                alignment: Alignment.topLeft,
                                child: _control(
                                  widget.closeLabel,
                                  Icons.close_rounded,
                                  widget.onClose,
                                ),
                              ),
                              Center(
                                child: StreamBuilder<bool>(
                                  stream: widget.playingChanges,
                                  initialData: widget.playing,
                                  builder: (context, snapshot) {
                                    final playing =
                                        snapshot.data ?? widget.playing;
                                    return _control(
                                      (playing
                                              ? widget.pauseLabel
                                              : widget.playLabel) ??
                                          widget.playPauseLabel,
                                      playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      widget.onTogglePlayback,
                                      size: 32,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// A critically damped spring settles without sending the card beyond the corner.
class _DockSpringCurve extends Curve {
  const _DockSpringCurve();

  static final _spring = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 360),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) => _spring.x(t * .32) / _spring.x(.32);
}
