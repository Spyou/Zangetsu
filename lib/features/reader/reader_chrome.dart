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

// ---------------------------------------------------------------------------
// Floating pill chrome
// ---------------------------------------------------------------------------
// The bars float as rounded pills over the page instead of sitting on an
// edge-to-edge gradient. Deliberately SOLID rather than translucent/blurred:
// a reader page can be pure white one moment and near-black the next, and an
// opaque fill is the only thing that stays legible over both without a blur
// pass on every frame. [ReaderScrim] is kept for whatever still uses it, so
// this can be adopted one screen at a time.

/// One height for every top-bar pill. The round buttons and the centre title
/// pill MUST match: they sit in the same row, and a taller centre pill makes
/// the row look lopsided and crowds the status bar.
const double kReaderPillHeight = 50;

/// Opaque fill shared by every pill. Slightly lighter than the app background
/// so a pill still reads as a raised surface on a black page.
const Color _kPillFill = Color(0xFF15151B);
const Color _kPillBorder = Color(0x1AFFFFFF);

/// Deliberately faint. A heavy shadow looks like depth over a white manga
/// page but turns into a visible dark smudge around the pill on a black one —
/// and a reader page is black far more often. Enough to lift the pill off a
/// bright page, not enough to halo on a dark one; the border does the rest.
const List<BoxShadow> _kPillShadow = [
  BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2)),
];

/// Shared pill surface — used for the round buttons, the title pill and the
/// bottom bar so all three can never drift apart.
class ReaderPillSurface extends StatelessWidget {
  const ReaderPillSurface({
    super.key,
    required this.child,
    required this.radius,
    this.padding = EdgeInsets.zero,
    this.onTap,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _kPillFill,
        borderRadius: r,
        border: Border.all(color: _kPillBorder),
        boxShadow: _kPillShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: r,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Round icon button in its own pill (back / overflow).
class ReaderPillIconButton extends StatelessWidget {
  const ReaderPillIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = kReaderPillHeight,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: ReaderPillSurface(
        radius: size / 2,
        onTap: onTap,
        child: Center(child: Icon(icon, color: Colors.white, size: 21)),
      ),
    );
    // Labelled for TalkBack: an icon-only round button is otherwise an
    // unnamed tap target, which is exactly the gap flagged on the player.
    return tooltip == null
        ? button
        : Tooltip(
            message: tooltip!,
            child: Semantics(button: true, label: tooltip, child: button),
          );
  }
}

/// Centre pill showing the work's title and the current chapter. Tapping it
/// opens the chapter list, which is why [onTap] is required rather than
/// optional — a pill that looks tappable and isn't would be worse than a
/// plain label.
class ReaderTitlePill extends StatelessWidget {
  const ReaderTitlePill({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // MergeSemantics, NOT Semantics+ExcludeSemantics: excluding the subtree
    // also throws away the InkWell's tap ACTION, leaving a node that reads as
    // a button but exposes nothing to activate — it announces as a label and
    // TalkBack can't press it. Merging instead folds the two Texts into one
    // node while keeping the tap.
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: '$title, $subtitle. Choose chapter',
        // FIXED width, not sized to its text. Letting it shrink-wrap meant the
        // bar visibly changed shape between chapters and between titles — a
        // short name gave a stubby pill, a long one a wide slab. A constant
        // width with the text centred inside keeps the top bar still, and the
        // island of air either side stays even.
        //
        // Still inside a Flexible, so a screen too narrow for this plus the two
        // buttons clamps it down instead of overflowing.
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.52,
          child: SizedBox(
            height: kReaderPillHeight,
            child: ReaderPillSurface(
              radius: kReaderPillHeight / 2,
              onTap: onTap,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      height: 1.15,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The single bottom pill. [children] are laid out in a row inside it —
/// typically prev-chapter, a slider, then next-chapter (the novel reader
/// slips a text-size button in before next).
class ReaderBottomPill extends StatelessWidget {
  const ReaderBottomPill({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ReaderPillSurface(
      radius: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
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
/// Standard reader-sheet body: grabber, title, then your rows.
///
/// Hand-rolling this per sheet is how they drift — the first two I wrote
/// missed the grabber, the safe area, the height cap and the scroll view, so
/// they overflowed on a short screen.
Widget readerSheetBody({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<Widget> children,
}) {
  return ReaderSheetShell(
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        // Capped and scrollable: a sheet that grows past the screen just
        // overflows, and Flutter paints the yellow stripes over the content.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(title, style: AppText.headline),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      subtitle,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

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

  /// Makes the whole row tappable — for a row that opens something rather than
  /// carrying its own control. Rows with a switch or slider leave this null;
  /// the control is the tap target there.
  VoidCallback? onTap,
}) {
  final row = Padding(
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
  if (onTap == null) return row;
  return Material(
    color: Colors.transparent,
    child: InkWell(onTap: onTap, child: row),
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
