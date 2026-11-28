import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'glass_pad.dart';
import 'remote_prefs.dart';

/// Responsive presentation of receiver capabilities; transport decisions belong to RemoteSession.
///
/// "Glass pad" layout: a swipe surface for the D-pad, pills for navigation and
/// a now-playing card while the TV player is in front.
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
    this.onKeyboard,
    this.onRetry,
    this.prefs,
  });

  /// [connected]: a TV link is up. [remoteMode]: "browse on phone, play on TV"
  /// is on. [companionReady]: the TV app answered, so browse/play controls apply.
  final bool connected, remoteMode, companionReady;

  /// Kept for callers; the remote now fills whatever height it is given.
  final bool inRemoteTab;

  /// Shows the Home pill; false for receivers that cannot press system Home.
  final bool systemControls;

  /// TV display name for the header pill, and the connection status line
  /// shown on the pad while not browsing or playing.
  final String name, status;

  /// Last transport error; shown as a tappable two-line banner when set.
  final String? error;

  /// Retries the TV link from the error sheet; null hides the Reconnect button.
  final VoidCallback? onRetry;

  /// Latest receiver snapshot (keys such as `active`, `playing`, `positionMs`,
  /// `durationMs`, `keyboardVersion`); read only, never mutated here.
  final Map<String, dynamic> state;

  /// Called when the user flips the browse-on-phone switch.
  final ValueChanged<bool> onMode;

  /// Open the connection manager, the QR scanner and phone-side search.
  final VoidCallback onManage, onScan, onSearch;

  /// Called with a shortcut id (`phone`, `episodes`, `sources`, `quality`,
  /// `audio`, `subtitles`) from the now-playing chips.
  final ValueChanged<String> onShortcut;

  /// Sends a remote command name with its arguments to the TV, for example
  /// `command('key', {'value': 'up', 'phase': 'press'})` then `release`.
  final void Function(String, Map<String, dynamic>) command;

  /// Opens the phone keyboard; shown only for TVs advertising keyboardVersion 1.
  final VoidCallback? onKeyboard;

  /// Look-and-feel store; defaults to [RemotePrefs.instance].
  final RemotePrefs? prefs;

  /// The prefs store in use: the injected one or the shared instance.
  RemotePrefs get _prefs => prefs ?? RemotePrefs.instance;

  /// Rebuilds whenever the look-and-feel prefs change (e.g. button names).
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _prefs,
    builder: (context, _) => _layout(context, _prefs.showLabels),
  );

  /// Builds the whole remote from [state]: playing vs browsing controls, and
  /// a side-by-side layout on wide, short (landscape) screens.
  Widget _layout(BuildContext context, bool labels) {
    final playing =
        connected &&
        companionReady &&
        state['active'] == true &&
        state['playerForeground'] != false;
    final browsing = connected && companionReady && !playing;
    final navigation =
        connected && (!playing || state['navigationWhilePlaying'] != false);
    final duration = ((state['durationMs'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      double.infinity,
    );
    final position = ((state['positionMs'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      duration,
    );
    final megaSeconds = state['megaSkipSeconds'] ?? 85;
    final paused = state['playing'] != true;

    Widget pill(
      IconData icon,
      String label,
      VoidCallback tap, {
      String? tooltip,
      bool dot = false,
      bool expand = true,
      bool enabled = true,
      String? fit,
    }) {
      final child = _Pill(
        icon: icon,
        label: label,
        fitLabel: fit,
        tooltip: tooltip ?? label,
        showLabel: labels,
        dot: dot,
        onTap: connected && enabled ? tap : null,
      );
      return expand ? Expanded(child: child) : child;
    }

    Widget row(List<Widget> children) => Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );

    final header = Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _TvPill(
              name: connected ? name : 'Your TV',
              connected: connected,
              onTap: onManage,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Remote options',
          onPressed: () => _options(context),
          icon: const Icon(Icons.settings_outlined, size: 22),
        ),
      ],
    );

    final errorBanner = error == null
        ? null
        : _ErrorBanner(message: error!, onRetry: onRetry);

    final volumeOn = connected && state['volumeAvailable'] != false;
    Widget held(String action, IconData symbol, String label) => _HeldControl(
      enabled: volumeOn,
      label: label,
      onPress: () => command(action, {'phase': 'press'}),
      onRelease: () => command('release', {}),
      onTap: () => command(action, {}),
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: 40,
          height: 44,
          child: Icon(
            symbol,
            size: 22,
            color: volumeOn ? AppColors.textPrimary : AppColors.textTertiary,
          ),
        ),
      ),
    );
    final volume = Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: _cardDecoration(999),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          held('volumeDown', Icons.remove_rounded, 'TV volume down'),
          IconButton(
            tooltip: 'Mute TV',
            onPressed: volumeOn ? () => command('mute', {}) : null,
            constraints: const BoxConstraints.tightFor(width: 40, height: 44),
            padding: EdgeInsets.zero,
            color: AppColors.textPrimary,
            icon: const Icon(Icons.volume_mute_rounded, size: 22),
          ),
          held('volumeUp', Icons.add_rounded, 'TV volume up'),
        ],
      ),
    );

    final browseSwitch = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: _cardDecoration(18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Browse on phone, play on TV',
              style: AppText.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Switch(
            value: remoteMode,
            onChanged: onMode,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.accent,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );

    final showKeyboard =
        onKeyboard != null && browsing && state['keyboardVersion'] == 1;
    // Every pill in this row measures the longest name, so they all switch
    // to "name under icon" together instead of mixing the two layouts.
    final navFit = showKeyboard
        ? 'Keyboard'
        : browsing
        ? 'Search'
        : 'Home';
    final navPills = row([
      pill(
        Icons.arrow_back_rounded,
        'Back',
        () => command('key', {'value': 'back'}),
        fit: navFit,
      ),
      if (systemControls)
        pill(
          Icons.home_outlined,
          'Home',
          () => command('home', {}),
          fit: navFit,
        ),
      if (browsing) pill(Icons.search_rounded, 'Search', onSearch, fit: navFit),
      if (showKeyboard)
        pill(
          Icons.keyboard_alt_outlined,
          'Keyboard',
          onKeyboard!,
          dot: state['keyboard'] is Map,
          fit: navFit,
        ),
    ]);

    final idleBottom = Row(
      children: [
        if (browsing) ...[
          Expanded(child: browseSwitch),
          const SizedBox(width: 8),
          volume,
        ] else
          Expanded(child: Center(child: volume)),
      ],
    );

    final scan = connected
        ? null
        : FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan to connect'),
          );

    final nowPlaying = Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
      decoration: _cardDecoration(20),
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
              if (state['canSkipIntro'] == true) ...[
                const SizedBox(width: 8),
                _SkipPill(
                  label: state['skipLabel'] as String? ?? 'Skip Intro',
                  onTap: () => command('skipIntro', {}),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 22,
            child: _ControlSlider(
              value: position,
              max: duration > 0 ? duration : 1,
              label: 'Playback position',
              onEnd: (v) => command('seek', {'positionMs': v.round()}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
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
          ),
        ],
      ),
    );

    const shortcutItems = [
      ('phone', 'Phone', 'Continue on phone', Icons.smartphone_rounded),
      ('episodes', 'Episodes', 'Episodes', Icons.video_library_outlined),
      ('sources', 'Sources', 'Sources', Icons.source_outlined),
      ('quality', 'Quality', 'Quality', Icons.high_quality_outlined),
      ('audio', 'Audio', 'Audio', Icons.audiotrack_rounded),
      ('subtitles', 'Subtitles', 'Subtitles', Icons.subtitles_outlined),
    ];
    final chips = SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final item in shortcutItems)
              if (item.$1 != 'quality' || state['qualitySelection'] != false)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Pill(
                    icon: item.$4,
                    label: item.$2,
                    tooltip: item.$3,
                    showLabel: labels,
                    height: 40,
                    onTap: () => onShortcut(item.$1),
                  ),
                ),
          ],
        ),
      ),
    );

    final episodePills = row([
      pill(
        Icons.skip_previous_rounded,
        'Previous',
        () => command('previous', {}),
        tooltip: 'Previous episode',
      ),
      if (state['megaSkipEnabled'] == true)
        pill(
          Icons.fast_forward_rounded,
          '+${megaSeconds}s',
          () => command('megaSkip', {}),
          tooltip: 'Mega Skip +${megaSeconds}s',
        ),
      pill(
        Icons.skip_next_rounded,
        'Next',
        () => command('next', {}),
        tooltip: 'Next episode',
      ),
    ]);
    final playingBottom = row([
      pill(
        Icons.arrow_back_rounded,
        'Back',
        () => command('key', {'value': 'back'}),
      ),
      if (systemControls)
        pill(Icons.home_outlined, 'Home', () => command('home', {})),
      volume,
    ]);

    final pad = LayoutBuilder(
      builder: (context, box) {
        final roomy = box.maxHeight >= 150;
        return GlassPad(
          navigation: navigation,
          onStep: (key) => command('key', {'value': key}),
          onHold: (key) => command('key', {'value': key, 'phase': 'press'}),
          onRelease: () => command('release', {}),
          onTap: playing
              ? () => command('toggle', {})
              : (navigation ? () => command('key', {'value': 'ok'}) : null),
          tapLabel: playing ? (paused ? 'Play' : 'Pause') : 'OK',
          // While playing a tap pauses, so a long press stands in for OK.
          onLongPress: playing && navigation
              ? () => command('key', {'value': 'ok'})
              : null,
          caption: box.maxHeight >= 110
              ? Text(
                  connected
                      ? (playing
                            ? 'Now playing'
                            : browsing
                            ? 'Browsing Zangetsu'
                            : status)
                      : status,
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                )
              : null,
          overlay: playing
              ? _PlayingOverlay(
                  paused: paused,
                  hint: roomy
                      ? (navigation
                            ? 'Swipe to move · tap to pause'
                            : 'Tap to pause')
                      : null,
                  compact: box.maxHeight < 120,
                  command: command,
                )
              : (box.maxHeight >= 120
                    ? _IdleHint(enabled: navigation, roomy: roomy)
                    : null),
        );
      },
    );

    const gap = SizedBox(height: 10);
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape =
            constraints.maxWidth > 550 && constraints.maxHeight < 500;
        if (landscape) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      header,
                      ?errorBanner,
                      const SizedBox(height: 6),
                      Expanded(child: pad),
                      if (playing) ...[const SizedBox(height: 8), chips],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: playing
                        ? [
                            nowPlaying,
                            const SizedBox(height: 8),
                            episodePills,
                            const SizedBox(height: 8),
                            playingBottom,
                          ]
                        : [
                            navPills,
                            const SizedBox(height: 8),
                            idleBottom,
                            if (scan != null) ...[
                              const SizedBox(height: 8),
                              scan,
                            ],
                          ],
                  ),
                ),
              ],
            ),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: math.min(constraints.maxWidth, 480),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Platform.isIOS ? 20 : 12,
                0,
                Platform.isIOS ? 20 : 12,
                8,
              ),
              child: Column(
                children: [
                  header,
                  ?errorBanner,
                  if (playing) ...[const SizedBox(height: 6), nowPlaying],
                  gap,
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 460),
                        child: pad,
                      ),
                    ),
                  ),
                  gap,
                  if (playing) ...[
                    chips,
                    gap,
                    episodePills,
                    const SizedBox(height: 8),
                    playingBottom,
                  ] else ...[
                    navPills,
                    gap,
                    idleBottom,
                    if (scan != null) ...[gap, scan],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Small sheet behind the gear: label style plus the connection manager.
  void _options(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListenableBuilder(
        listenable: _prefs,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Remote options',
                style: AppText.title.copyWith(fontSize: 17),
              ),
            ),
            SwitchListTile(
              title: const Text('Show button names'),
              subtitle: const Text('Turn off to show icons only'),
              value: _prefs.showLabels,
              onChanged: _prefs.setShowLabels,
            ),
            ListTile(
              leading: const Icon(Icons.tv_rounded),
              title: const Text('Manage connection'),
              onTap: () {
                Navigator.pop(sheet);
                onManage();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );

  /// Formats milliseconds as `m:ss` for the playback position labels.
  String _time(double ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// Shared surface card look (fill plus hairline border) with [radius] corners.
BoxDecoration _cardDecoration(double radius) => BoxDecoration(
  color: AppColors.surface,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: AppColors.hairline),
);

/// Rounded error line under the TV pill: up to two lines, tap for the full text.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.onRetry});

  /// Full error text; the banner shows at most two lines of it.
  final String message;

  /// Offered as a Reconnect button in the sheet when not null.
  final VoidCallback? onRetry;

  /// Text scale is capped so two lines never squeeze the pad; the sheet shows all of it.
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: _pill(context),
    ),
  );

  /// The rounded, tappable surface holding the icon and the two-line message.
  Widget _pill(BuildContext context) => Material(
    color: AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: AppColors.hairline),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: const ValueKey('remote-error'),
      onTap: () => _details(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: AppColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    ),
  );

  /// Opens a small sheet with the whole message and, if offered, Reconnect.
  void _details(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Connection', style: AppText.title.copyWith(fontSize: 17)),
            const SizedBox(height: 8),
            // A very long message scrolls instead of overflowing the sheet.
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  key: const ValueKey('remote-error-full'),
                  style: AppText.body,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(sheet),
                  child: const Text('Close'),
                ),
                if (onRetry != null) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(sheet);
                      onRetry!();
                    },
                    child: const Text('Reconnect'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Connection pill: status dot, TV name and a chevron that opens Manage connection.
class _TvPill extends StatelessWidget {
  const _TvPill({
    required this.name,
    required this.connected,
    required this.onTap,
  });

  /// TV name shown in the pill.
  final String name;

  /// Turns the status dot green.
  final bool connected;

  /// Opens the connection manager.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Manage connection, $name',
    excludeSemantics: true,
    onTap: onTap,
    child: Tooltip(
      message: 'Manage connection',
      excludeFromSemantics: true,
      child: Material(
        color: AppColors.surface,
        shape: const StadiumBorder(side: BorderSide(color: AppColors.hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // Green reads as "connected"; red would look like an error.
                    color: connected
                        ? const Color(0xFF34C759)
                        : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    name,
                    style: AppText.title.copyWith(fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Rounded remote button; with [showLabel] off it keeps only the icon while
/// the tooltip and semantics label still name it.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.showLabel,
    required this.onTap,
    this.dot = false,
    this.height = 44,
    this.fitLabel,
  });
  final IconData icon;

  /// Visible name, and the tooltip/semantics name (can be longer).
  final String label, tooltip;

  /// Text measured to choose the layout (defaults to [label]); a row passes
  /// its longest name so all of its pills pick the same layout.
  final String? fitLabel;

  /// [showLabel]: draw the name next to/under the icon. [dot]: show an
  /// accent badge (e.g. the TV has a text field waiting for the keyboard).
  final bool showLabel, dot;

  /// Null disables the pill and greys it out.
  final VoidCallback? onTap;

  /// Fixed pill height; also its minimum width.
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = onTap != null
        ? AppColors.textPrimary
        : AppColors.textTertiary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          color: AppColors.surface,
          shape: const StadiumBorder(
            side: BorderSide(color: AppColors.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: height,
                maxHeight: height,
                minWidth: height,
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final badge = Badge(
                    isLabelVisible: dot,
                    smallSize: 8,
                    backgroundColor: AppColors.accent,
                    child: Icon(icon, size: 20, color: color),
                  );
                  if (!showLabel) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Center(child: badge),
                    );
                  }
                  final style = AppText.caption.copyWith(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  );
                  // When icon and name side by side would cut the name off,
                  // put a smaller name under the icon instead.
                  final painter = TextPainter(
                    text: TextSpan(text: fitLabel ?? label, style: style),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                  )..layout();
                  final rowWidth = 12 + 20 + 6 + painter.width + 12;
                  painter.dispose();
                  if (rowWidth <= box.maxWidth) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          badge,
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            badge,
                            const SizedBox(height: 1),
                            Text(
                              label,
                              maxLines: 1,
                              style: style.copyWith(fontSize: 11, height: 1.1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Accent "Skip intro" action on the now-playing card.
class _SkipPill extends StatelessWidget {
  const _SkipPill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 150),
    child: Material(
      color: AppColors.accent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Centre hint on the idle pad; never takes touches from the surface.
class _IdleHint extends StatelessWidget {
  const _IdleHint({required this.enabled, required this.roomy});

  /// [enabled]: navigation works, so the hint is not dimmed. [roomy]: enough
  /// height for the larger icon and spacing.
  final bool enabled, roomy;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Center(
        // Large text sizes shrink the hint instead of overflowing the pad.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.touch_app_outlined,
                size: roomy ? 36 : 28,
                color: enabled
                    ? AppColors.textSecondary
                    : AppColors.textTertiary,
              ),
              if (roomy) const SizedBox(height: 10),
              Text(
                'Swipe to move',
                style: AppText.caption.copyWith(
                  color: enabled
                      ? AppColors.textSecondary
                      : AppColors.textTertiary,
                ),
              ),
              Text(
                'Tap for OK',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Play/pause in the pad centre with replay-10 and forward-10 on its edges.
class _PlayingOverlay extends StatelessWidget {
  const _PlayingOverlay({
    required this.paused,
    required this.hint,
    required this.compact,
    required this.command,
  });

  /// [paused]: show the play icon. [compact]: smaller centre button for short pads.
  final bool paused, compact;

  /// Gesture hint under the button; null when the pad is too short for it.
  final String? hint;

  /// Same command sink as [RemotePanel.command] (`toggle`, `rewind`, `forward`).
  final void Function(String, Map<String, dynamic>) command;

  @override
  Widget build(BuildContext context) {
    Widget edge(IconData icon, String label, String action) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: IconButton(
        tooltip: label,
        onPressed: () => command(action, {}),
        style: IconButton.styleFrom(
          minimumSize: const Size(52, 52),
          foregroundColor: AppColors.textPrimary,
        ),
        icon: Icon(icon, size: 30),
      ),
    );
    final size = compact ? 52.0 : 68.0;
    return Row(
      children: [
        edge(Icons.replay_10_rounded, 'Back 10 seconds', 'rewind'),
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: paused ? 'Play' : 'Pause',
                    onPressed: () => command('toggle', {}),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      fixedSize: Size.square(size),
                    ),
                    icon: Icon(
                      paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      size: size * .52,
                    ),
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 10),
                    IgnorePointer(
                      child: Text(
                        hint!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        edge(Icons.forward_10_rounded, 'Forward 10 seconds', 'forward'),
      ],
    );
  }
}

/// A single-pointer control that always pairs a press with release/cancel.
///
/// Used for volume so holding the button keeps the TV repeating the step.
class _HeldControl extends StatefulWidget {
  const _HeldControl({
    required this.enabled,
    required this.label,
    required this.onPress,
    required this.onRelease,
    required this.onTap,
    required this.child,
  });

  /// When false, touches and semantic taps are ignored.
  final bool enabled;

  /// Accessibility name of the control.
  final String label;

  /// [onPress] on finger down, [onRelease] on up/cancel/dispose, [onTap] for
  /// a single accessibility activation.
  final VoidCallback onPress, onRelease, onTap;

  /// Visual content; it receives no pointer or semantics events itself.
  final Widget child;
  @override
  State<_HeldControl> createState() => _HeldControlState();
}

/// Tracks pointer ownership so overlapping touches do not duplicate held commands.
class _HeldControlState extends State<_HeldControl> {
  /// Id of the pointer currently holding the control, or null.
  int? pointer;

  /// Sends the release once if a press is active; safe to call repeatedly.
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

/// Accessible directional pad whose visual regions share the same command dispatch.
class CircularRemotePad extends StatefulWidget {
  const CircularRemotePad({
    super.key,
    required this.enabled,
    required this.onKey,
    this.onRelease,
  });

  /// When false the pad is greyed and ignores input.
  final bool enabled;

  /// Called on press with `up`, `down`, `left`, `right` or `ok`.
  final ValueChanged<String> onKey;

  /// Called when the finger lifts, cancels or slides off the pad.
  final VoidCallback? onRelease;
  @override
  State<CircularRemotePad> createState() => _CircularRemotePadState();
}

/// Owns touch/release state; hold timing and transport routing remain outside the painter.
class _CircularRemotePadState extends State<CircularRemotePad> {
  /// Key under the active finger, highlighted by the painter.
  String? _pressed;

  /// Id of the pointer that owns the current press.
  int? _pointer;

  /// Clears the press and reports the release once; call inside setState.
  void _release() {
    if (_pointer != null) {
      _pointer = null;
      _pressed = null;
      widget.onRelease?.call();
    }
  }

  /// Emits a complete tap for semantic activation, including the release event.
  void _accessibleTap(String key) {
    _send(key);
    widget.onRelease?.call();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  /// Maps a touch to `ok` (centre disc) or the nearest of the four directions.
  String _key(Offset point, Size size) {
    final d = point - size.center(Offset.zero);
    if (d.distance < size.shortestSide * .18) return 'ok';
    return d.dx.abs() > d.dy.abs()
        ? (d.dx < 0 ? 'left' : 'right')
        : (d.dy < 0 ? 'up' : 'down');
  }

  /// Dispatches only the current pad direction while enforcing one active touch.
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

/// Draws the circular control; contains no input or transport logic.
class _PadPainter extends CustomPainter {
  _PadPainter(this.surface, this.accent, this.pressed, this.enabled);

  /// Ring fill colour and highlight/centre colour.
  final Color surface, accent;

  /// Key to highlight (`up`/`down`/`left`/`right`/`ok`), or null.
  final String? pressed;

  /// Draws the centre disc in the accent colour instead of the muted one.
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

/// Keeps drag feedback local while publishing the final seek or volume change.
class _ControlSlider extends StatefulWidget {
  const _ControlSlider({
    required this.value,
    required this.max,
    required this.label,
    required this.onEnd,
  });

  /// Current value from the receiver and the slider's upper bound.
  final double value, max;

  /// Accessibility name.
  final String label;

  /// Called once with the final value when the drag ends.
  final ValueChanged<double> onEnd;
  @override
  State<_ControlSlider> createState() => _ControlSliderState();
}

/// Separates the in-progress drag value from receiver snapshots.
class _ControlSliderState extends State<_ControlSlider> {
  /// Value while the user is dragging; null shows [_ControlSlider.value].
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
