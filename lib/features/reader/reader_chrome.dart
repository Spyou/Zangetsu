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
        // Pill-style: a fat, fully-rounded capsule track (rounded end caps)
        // instead of the thin default line — reads like a modern scrubber.
        trackHeight: 7,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
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

/// Equal-width option picker for a reader settings sheet — replaces the old
/// free-wrapping chip `Wrap` rows, which was the main source of the
/// "unorganised" feedback. All of [options] live in one rounded, bordered
/// strip; the selected segment fills solid [AppColors.accent] (white text),
/// the rest sit transparent ([AppColors.textSecondary]). Prefers a single
/// row at a smaller font, and only drops to two full-width rows of equal
/// segments when the labels genuinely don't fit the sheet's width.
class ReaderSegmentedControl extends StatelessWidget {
  const ReaderSegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  /// Each segment's underlying value + display label. `selected` is compared
  /// against `value`, never `label`.
  final List<({String value, String label})> options;
  final String selected;
  final ValueChanged<String> onSelect;

  static const _labelStyle = TextStyle(
    fontFamily: 'Inter',
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Sum of each label's own natural width (+ its segment padding) —
        // a cheap stand-in for "would every segment be legible at its
        // equal-width Expanded size". Good enough to pick single-row vs
        // wrapped without a real layout pass.
        var natural = 0.0;
        for (final o in options) {
          final painter = TextPainter(
            text: TextSpan(text: o.label, style: _labelStyle),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          natural += painter.width + 28;
        }
        if (options.length <= 1 || natural <= constraints.maxWidth) {
          return _row(options);
        }
        final mid = (options.length / 2).ceil();
        return Column(
          children: [
            _row(options.sublist(0, mid)),
            const SizedBox(height: 6),
            _row(options.sublist(mid)),
          ],
        );
      },
    );
  }

  Widget _row(List<({String value, String label})> opts) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: IntrinsicHeight(
          child: Row(
            children: [
              for (var i = 0; i < opts.length; i++) ...[
                if (i > 0)
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: AppColors.hairline,
                  ),
                Expanded(child: _segment(opts[i])),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(({String value, String label}) o) {
    final isSelected = o.value == selected;
    return Material(
      color: isSelected ? AppColors.accent : Colors.transparent,
      child: InkWell(
        onTap: () => onSelect(o.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Text(
            o.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: _labelStyle.copyWith(
              color: isSelected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One setting row inside a reader sheet's grouped card: a small leading
/// icon + label, an optional [trailing] widget inline on the same line (a
/// `Switch`, or the manga reader's per-series override tag), and the row's
/// own control — a [ReaderSegmentedControl], a `Slider`, or nothing — on the
/// line below via [child]. Same shape used by both readers' sheets and the
/// global Settings -> Reader screen, so all three read as one design.
Widget readerSheetRow({
  required IconData icon,
  required String label,
  Widget? trailing,
  Widget? child,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (child != null) ...[const SizedBox(height: 8), child],
      ],
    ),
  );
}

/// Groups a section's [readerSheetRow]s into one rounded card with a thin
/// [AppColors.hairline] divider between each — pairs with
/// [readerSheetSection]'s header sitting above it. Same "grouped card" shape
/// as `settings_widgets.dart`'s `SettingsCard`, sized down for a sheet row.
Widget readerSheetGroup(List<Widget> rows) {
  final children = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    if (i > 0) {
      children.add(
        const Divider(height: 1, thickness: 1, color: AppColors.hairline),
      );
    }
    children.add(rows[i]);
  }
  return DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// Small accent-tinted pill flagging that a row's control is a per-series
/// override rather than the global default — replaces the old loose
/// "· this title" caption under the manga reader's Direction/Fit rows.
Widget readerOverrideTag() {
  return Container(
    margin: const EdgeInsets.only(left: 8),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      'This title',
      style: AppText.caption.copyWith(
        color: AppColors.accent,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        height: 1,
      ),
    ),
  );
}
