import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

class RemotePanel extends StatelessWidget {
  const RemotePanel({
    super.key,
    required this.connected,
    required this.name,
    required this.status,
    required this.remoteMode,
    required this.state,
    required this.onMode,
    required this.onManage,
    required this.onScan,
    required this.onSearch,
    required this.onShortcut,
    required this.command,
    this.error,
    this.companionReady = true,
    this.inRemoteTab = false,
    this.systemControls = true,
  });
  final bool connected, remoteMode, companionReady;
  final bool inRemoteTab;
  final bool systemControls;
  final String name, status;
  final String? error;
  final Map<String, dynamic> state;
  final ValueChanged<bool> onMode;
  final VoidCallback onManage, onScan, onSearch;
  final ValueChanged<String> onShortcut;
  final void Function(String, Map<String, dynamic>) command;

  @override
  Widget build(BuildContext context) {
    final playing =
        connected &&
        companionReady &&
        state['active'] == true &&
        state['playerForeground'] != false;
    final browsing = connected && companionReady && !playing;
    final duration = ((state['durationMs'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      double.infinity,
    );
    final position = ((state['positionMs'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      duration,
    );
    Widget icon(
      IconData symbol,
      String label,
      VoidCallback tap, {
      bool prominent = false,
      bool enabled = true,
    }) => IconButton(
      tooltip: label,
      onPressed: connected && enabled ? tap : null,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: prominent ? AppColors.accent : Colors.transparent,
        foregroundColor: AppColors.textPrimary,
      ),
      icon: Icon(symbol, size: prominent ? 30 : 24),
    );
    Widget navigation(IconData symbol, String label, VoidCallback tap) =>
        Expanded(
          child: TextButton.icon(
            onPressed: connected ? tap : null,
            icon: Icon(symbol, size: 22),
            label: Text(label),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              minimumSize: const Size(44, 44),
            ),
          ),
        );
    Widget volume(String action, IconData symbol, String label) => _HeldControl(
      enabled: connected && state['volumeAvailable'] != false,
      label: label,
      onPress: () => command(action, {'phase': 'press'}),
      onRelease: () => command('release', {}),
      onTap: () => command(action, {}),
      child: icon(symbol, label, () => command(action, {}), enabled: state['volumeAvailable'] != false),
    );
    final playback = Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state['title'] as String? ?? '',
                      style: AppText.title.copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      state['episodeLabel'] as String? ?? '',
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(
            height: 22,
            child: _ControlSlider(
              value: position,
              max: duration > 0 ? duration : 1,
              label: 'Playback position',
              onEnd: (v) => command('seek', {'positionMs': v.round()}),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _time(position),
                style: AppText.caption.copyWith(fontSize: 11),
              ),
              Text(
                state['buffering'] == true ? 'Loading…' : _time(duration),
                style: AppText.caption.copyWith(fontSize: 11),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              icon(
                Icons.skip_previous_rounded,
                'Previous episode',
                () => command('previous', {}),
              ),
              icon(
                Icons.replay_10_rounded,
                'Back 10 seconds',
                () => command('rewind', {}),
              ),
              icon(
                state['playing'] == true
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                state['playing'] == true ? 'Pause' : 'Play',
                () => command('toggle', {}),
                prominent: true,
              ),
              icon(
                Icons.forward_10_rounded,
                'Forward 10 seconds',
                () => command('forward', {}),
              ),
              icon(
                Icons.skip_next_rounded,
                'Next episode',
                () => command('next', {}),
              ),
            ],
          ),
          if (state['canSkipIntro'] == true || state['megaSkipEnabled'] == true)
            Row(
              children: [
                if (state['canSkipIntro'] == true)
                  Expanded(
                    child: TextButton(
                      onPressed: () => command('skipIntro', {}),
                      child: Text(
                        state['skipLabel'] as String? ?? 'Skip Intro',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                if (state['megaSkipEnabled'] == true)
                  Expanded(
                    child: TextButton(
                      onPressed: () => command('megaSkip', {}),
                      child: Text(
                        'Mega Skip +${state['megaSkipSeconds'] ?? 85}s',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
    final shortcuts = LayoutBuilder(
      builder: (context, constraints) {
        const items = [
          ('phone', 'Phone', Icons.smartphone_rounded),
          ('episodes', 'Episodes', Icons.video_library_outlined),
          ('sources', 'Sources', Icons.source_outlined),
          ('quality', 'Quality', Icons.high_quality_outlined),
          ('audio', 'Audio', Icons.audiotrack_rounded),
          ('subtitles', 'Subtitles', Icons.subtitles_outlined),
        ];
        final columns = constraints.maxWidth >= 290 ? 6 : 3;
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: items
              .where(
                (item) =>
                    item.$1 != 'quality' || state['qualitySelection'] != false,
              )
              .map(
                (item) => SizedBox(
                  width: (constraints.maxWidth - (columns - 1) * 4) / columns,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          tooltip: item.$1 == 'phone'
                              ? 'Continue on phone'
                              : item.$2,
                          onPressed: () => onShortcut(item.$1),
                          style: IconButton.styleFrom(
                            backgroundColor: AppColors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: Icon(item.$3, size: 21),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        );
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final landscape =
            constraints.maxWidth > 550 && constraints.maxHeight < 500;
        // Reserve the dock's footprint on either entry route so opening the
        // full-screen remote does not enlarge its D-pad or spread its controls.
        final portraitHeight = math.min(
          constraints.maxHeight,
          media.size.height - media.viewPadding.vertical - kToolbarHeight - 120,
        );
        final children = <Widget>[
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? name : 'Your TV',
                      style: AppText.title.copyWith(fontSize: 20),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      connected
                          ? (playing
                                ? 'Now playing · Zangetsu'
                                : browsing
                                ? 'Browsing · Zangetsu'
                                : status)
                          : status,
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Manage connection',
                onPressed: onManage,
                icon: const Icon(Icons.settings_outlined, size: 22),
              ),
            ],
          ),
          if (browsing)
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Browse on phone, play on TV',
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Switch(value: remoteMode, onChanged: onMode),
                ],
              ),
            ),
          if (error != null)
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Remote'),
                  content: Text(error!),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
              child: Text(error!, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          Flexible(
            fit: FlexFit.loose,
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 240, maxHeight: 240),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CircularRemotePad(
                    enabled:
                        connected &&
                        (!playing || state['navigationWhilePlaying'] != false),
                    onKey: (key) =>
                        command('key', {'value': key, 'phase': 'press'}),
                    onRelease: () => command('release', {}),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              navigation(
                Icons.arrow_back_rounded,
                'Back',
                () => command('key', {'value': 'back'}),
              ),
              if (systemControls)
                navigation(
                  Icons.home_outlined,
                  'Home',
                  () => command('home', {}),
                ),
              if (browsing)
                navigation(Icons.search_rounded, 'Search', onSearch),
            ],
          ),
          if (playing) ...[shortcuts, const SizedBox(height: 8), playback],
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                volume('volumeDown', Icons.remove_rounded, 'TV volume down'),
                icon(
                  Icons.volume_off_outlined,
                  'Mute TV',
                  () => command('mute', {}),
                  enabled: state['volumeAvailable'] != false,
                ),
                volume('volumeUp', Icons.add_rounded, 'TV volume up'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (!connected)
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan to connect'),
            ),
        ];
        // A short, wide window puts navigation beside playback instead of
        // shrinking touch targets into a single crowded column.
        if (landscape) {
          final padIndex = children.indexWhere((child) => child is Flexible);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      ...children.take(padIndex + 2),
                      if (playing) shortcuts,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: children
                        .skip(padIndex + (playing ? 4 : 2))
                        .toList(),
                  ),
                ),
              ],
            ),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: inRemoteTab ? constraints.maxHeight : portraitHeight,
            width: math.min(constraints.maxWidth, 480),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CustomMultiChildLayout(
                delegate: _RemotePortraitLayout(portraitHeight, inRemoteTab),
                children: [
                  LayoutId(
                    id: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: children
                          .takeWhile((child) => child is! Flexible)
                          .toList(),
                    ),
                  ),
                  LayoutId(
                    id: 1,
                    child:
                        (children.firstWhere((child) => child is Flexible)
                                as Flexible)
                            .child,
                  ),
                  LayoutId(
                    id: 2,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: children
                          .skipWhile((child) => child is! Flexible)
                          .skip(1)
                          .take(playing ? 2 : 1)
                          .toList(),
                    ),
                  ),
                  LayoutId(
                    id: 3,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: children
                          .skipWhile((child) => child is! Flexible)
                          .skip(playing ? 3 : 2)
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _time(double ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _RemotePortraitLayout extends MultiChildLayoutDelegate {
  _RemotePortraitLayout(this.sharedHeight, this.anchorPlayback);
  final double sharedHeight;
  final bool anchorPlayback;
  @override
  void performLayout(Size size) {
    final loose = BoxConstraints(maxWidth: size.width, maxHeight: size.height);
    final header = layoutChild(0, loose);
    final shortcuts = layoutChild(2, loose);
    final bottom = layoutChild(3, loose);
    final available = math.max(
      0.0,
      math.min(sharedHeight, size.height) -
          header.height -
          shortcuts.height -
          bottom.height,
    );
    final diameter = math.min(240.0, math.min(size.width, available));
    layoutChild(1, BoxConstraints.tight(Size.square(diameter)));
    positionChild(0, Offset.zero);
    positionChild(
      1,
      Offset(
        (size.width - diameter) / 2,
        header.height + (available - diameter) / 2,
      ),
    );
    positionChild(2, Offset(0, header.height + available));
    positionChild(
      3,
      Offset(
        0,
        anchorPlayback
            ? size.height - bottom.height
            : header.height + available + shortcuts.height,
      ),
    );
  }

  @override
  bool shouldRelayout(_RemotePortraitLayout old) =>
      sharedHeight != old.sharedHeight || anchorPlayback != old.anchorPlayback;
}

class _HeldControl extends StatefulWidget {
  const _HeldControl({
    required this.enabled,
    required this.label,
    required this.onPress,
    required this.onRelease,
    required this.onTap,
    required this.child,
  });
  final bool enabled;
  final String label;
  final VoidCallback onPress, onRelease, onTap;
  final Widget child;
  @override
  State<_HeldControl> createState() => _HeldControlState();
}

class _HeldControlState extends State<_HeldControl> {
  int? pointer;
  void release() {
    if (pointer != null) {
      pointer = null;
      widget.onRelease();
    }
  }

  @override
  void dispose() {
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    enabled: widget.enabled,
    onTap: widget.enabled ? widget.onTap : null,
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (widget.enabled && pointer == null) {
          pointer = e.pointer;
          widget.onPress();
        }
      },
      onPointerUp: (e) {
        if (pointer == e.pointer) release();
      },
      onPointerCancel: (e) {
        if (pointer == e.pointer) release();
      },
      child: ExcludeSemantics(child: IgnorePointer(child: widget.child)),
    ),
  );
}

class CircularRemotePad extends StatefulWidget {
  const CircularRemotePad({
    super.key,
    required this.enabled,
    required this.onKey,
    this.onRelease,
  });
  final bool enabled;
  final ValueChanged<String> onKey;
  final VoidCallback? onRelease;
  @override
  State<CircularRemotePad> createState() => _CircularRemotePadState();
}

class _CircularRemotePadState extends State<CircularRemotePad> {
  String? _pressed;
  int? _pointer;
  void _release() {
    if (_pointer != null) {
      _pointer = null;
      _pressed = null;
      widget.onRelease?.call();
    }
  }

  void _accessibleTap(String key) {
    _send(key);
    widget.onRelease?.call();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  String _key(Offset point, Size size) {
    final d = point - size.center(Offset.zero);
    if (d.distance < size.shortestSide * .18) return 'ok';
    return d.dx.abs() > d.dy.abs()
        ? (d.dx < 0 ? 'left' : 'right')
        : (d.dy < 0 ? 'up' : 'down');
  }

  void _send(String key) {
    if (widget.enabled) {
      HapticFeedback.selectionClick();
      widget.onKey(key);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      Widget glyph(String key, IconData icon, Alignment alignment) => Align(
        alignment: alignment,
        child: Semantics(
          button: true,
          label: key[0].toUpperCase() + key.substring(1),
          enabled: widget.enabled,
          onTap: widget.enabled ? () => _accessibleTap(key) : null,
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: Icon(
                icon,
                size: size.shortestSide * .105,
                color: widget.enabled
                    ? AppColors.textPrimary
                    : AppColors.textTertiary,
              ),
            ),
          ),
        ),
      );
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled
            ? (e) {
                if (_pressed != null ||
                    (e.localPosition - size.center(Offset.zero)).distance >
                        size.shortestSide / 2)
                  return;
                setState(() => _pressed = _key(e.localPosition, size));
                _pointer = e.pointer;
                _send(_pressed!);
              }
            : null,
        onPointerUp: (e) {
          if (_pointer == e.pointer) setState(_release);
        },
        onPointerCancel: (e) {
          if (_pointer == e.pointer) setState(_release);
        },
        onPointerMove: (e) {
          if (_pointer == e.pointer &&
              (e.localPosition - size.center(Offset.zero)).distance >
                  size.shortestSide / 2)
            setState(_release);
        },
        child: CustomPaint(
          painter: _PadPainter(
            AppColors.surface,
            AppColors.accent,
            _pressed,
            widget.enabled,
          ),
          child: Stack(
            children: [
              glyph(
                'up',
                Icons.keyboard_arrow_up_rounded,
                const Alignment(0, -.78),
              ),
              glyph(
                'down',
                Icons.keyboard_arrow_down_rounded,
                const Alignment(0, .78),
              ),
              glyph(
                'left',
                Icons.keyboard_arrow_left_rounded,
                const Alignment(-.78, 0),
              ),
              glyph(
                'right',
                Icons.keyboard_arrow_right_rounded,
                const Alignment(.78, 0),
              ),
              Center(
                child: Semantics(
                  button: true,
                  label: 'OK',
                  enabled: widget.enabled,
                  onTap: widget.enabled ? () => _accessibleTap('ok') : null,
                  child: ExcludeSemantics(
                    child: Text(
                      'OK',
                      style: AppText.title.copyWith(
                        fontSize: size.shortestSide * .085,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.surface, this.accent, this.pressed, this.enabled);
  final Color surface, accent;
  final String? pressed;
  final bool enabled;
  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero), radius = size.shortestSide / 2 - 2;
    canvas.drawCircle(centre, radius, Paint()..color = surface);
    final border = Paint()
      ..color = Colors.white.withValues(alpha: .13)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    if (pressed != null && pressed != 'ok') {
      final angle = {
        'right': -math.pi / 4,
        'down': math.pi / 4,
        'left': 3 * math.pi / 4,
        'up': 5 * math.pi / 4,
      }[pressed]!;
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        angle,
        math.pi / 2,
        true,
        Paint()..color = accent.withValues(alpha: .15),
      );
    }
    canvas.drawCircle(centre, radius, border);
    for (var i = 0; i < 4; i++) {
      final a = math.pi / 4 + i * math.pi / 2;
      final v = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(centre + v * radius * .38, centre + v * radius, border);
    }
    canvas.drawCircle(centre, radius * .38, Paint()..color = AppColors.bg);
    canvas.drawCircle(
      centre,
      radius * .345,
      Paint()
        ..color = enabled
            ? accent.withValues(alpha: pressed == 'ok' ? .75 : 1)
            : AppColors.surface2,
    );
  }

  @override
  bool shouldRepaint(_PadPainter old) =>
      old.pressed != pressed ||
      old.accent != accent ||
      old.surface != surface ||
      old.enabled != enabled;
}

class _ControlSlider extends StatefulWidget {
  const _ControlSlider({
    required this.value,
    required this.max,
    required this.label,
    required this.onEnd,
  });
  final double value, max;
  final String label;
  final ValueChanged<double> onEnd;
  @override
  State<_ControlSlider> createState() => _ControlSliderState();
}

class _ControlSliderState extends State<_ControlSlider> {
  double? drag;
  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        value: (drag ?? widget.value).clamp(0, widget.max),
        max: widget.max,
        onChanged: (v) => setState(() => drag = v),
        onChangeEnd: (v) {
          setState(() => drag = null);
          widget.onEnd(v);
        },
      ),
    ),
  );
}
