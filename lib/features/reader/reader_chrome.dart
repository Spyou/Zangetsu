// Shared chrome widgets for both readers (manga + novel) — restyles the
// top/bottom bars and settings sheets to match the player's own polish (see
// _SheetSurface/_SheetSectionHeader and the top/bottom control scrims in
// player_screen.dart). Pure presentation: no reader state or behavior lives
// here, callers wire every callback through unchanged.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Gradient behind a reader's chrome bar — near-black fading to transparent,
/// same colour ramp as [AppColors.scrim]. Deliberately taller than the
/// button row it sits behind (mirrors the player's own top/bottom control
/// scrims, player_screen.dart ~L3384-3450): the row lands inside the opaque
/// part of the fade so it stays legible over any page/theme background
/// underneath, with the fade tailing off well past it rather than cutting
/// off right at the row's edge.
class ReaderScrim extends StatelessWidget {
  const ReaderScrim({super.key, required this.top});

  /// True for a top-edge bar (fades downward), false for a bottom-edge bar
  /// (fades upward).
  final bool top;

  static const double _topHeight = 120;
  static const double _bottomHeight = 170;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: IgnorePointer(
        child: SizedBox(
          width: double.infinity,
          height: top ? _topHeight : _bottomHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: AppColors.scrim.colors,
                stops: AppColors.scrim.stops,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chapter/page progress slider — rounded track, white thumb on the accent
/// colour, the same visual weight as the player's main scrubber
/// (SliderTheme-wrapped, see player_screen.dart's `_slider`/main scrub bar).
/// A pure restyle: every value/callback passes straight through to a real
/// [Slider], so a caller's existing wiring (`onChangeStart`/`onChanged`/
/// `onChangeEnd`, a `ValueListenableBuilder` around `value`, etc.) is
/// untouched.
class ReaderSlider extends StatelessWidget {
  const ReaderSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.onChangeStart,
    required this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: AppColors.accent,
        inactiveTrackColor: Colors.white24,
        thumbColor: Colors.white,
        overlayColor: AppColors.accentSoft,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChangeStart: onChangeStart,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

/// One reader chrome-bar icon button (back / prev-chapter / settings /
/// next-chapter). [enabled] both dims the icon and detaches [onTap] — an
/// `IconButton` with a null `onPressed` simply doesn't fire, so a disabled
/// button can't be tapped through.
Widget readerBarButton(
  IconData icon,
  VoidCallback onTap, {
  bool enabled = true,
  Color color = Colors.white,
}) {
  return IconButton(
    icon: Icon(icon, color: enabled ? color : color.withValues(alpha: 0.3)),
    onPressed: enabled ? onTap : null,
  );
}

/// Rounded/bordered/shadowed sheet container — mirrors player_screen.dart's
/// `_SheetSurface` (same radius, border, shadow, 560 max width) so both
/// readers' settings sheets read as the same design system as the player's.
/// Open with `showModalBottomSheet(backgroundColor: Colors.transparent,
/// isScrollControlled: true, builder: (_) => ReaderSheetShell(...))`.
class ReaderSheetShell extends StatelessWidget {
  const ReaderSheetShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(24);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        0,
        10,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: r,
                  border: Border.all(color: AppColors.hairline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 40,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: ClipRRect(borderRadius: r, child: child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uppercase caption header grouping a cluster of controls inside a reader
/// settings sheet — mirrors `_SheetSectionHeader`. No horizontal padding of
/// its own; drop it straight into whichever already-side-padded column the
/// sheet's other controls live in.
Widget readerSheetSection(String label) {
  return Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(
      label.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textTertiary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
  );
}
