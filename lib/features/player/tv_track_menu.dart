import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_keys.dart';

/// One selectable row in a [TvTrackMenu].
class TvMenuOption {
  const TvMenuOption({
    required this.label,
    this.selected = false,
    this.trailing,
    this.showCheck = true,
    required this.onSelect,
  });
  final String label;
  final bool selected;
  final String? trailing;

  /// When false, renders a summary/nav row (label + trailing, no check icon).
  final bool showCheck;
  final VoidCallback onSelect;
}

/// A titled group of options (legacy multi-section menus).
class TvMenuSection {
  const TvMenuSection({required this.title, required this.options});
  final String title;
  final List<TvMenuOption> options;
}

/// A D-pad-navigable right-side settings panel. Up/Down move focus, OK selects,
/// Back invokes [onClose] (host pops a sub-page or dismisses).
///
/// Prefer [title] + [options] for the Crunchyroll-style Settings list. [sections]
/// remains for callers that still group rows under headers.
class TvTrackMenu extends StatefulWidget {
  const TvTrackMenu({
    super.key,
    this.title = 'Settings',
    this.options = const [],
    this.sections = const [],
    required this.onClose,
    this.onInteract,
  });

  /// Panel / page title shown at the top.
  final String title;

  /// Flat option list (used when [sections] is empty).
  final List<TvMenuOption> options;

  /// Optional titled groups; when non-empty, rendered instead of [options].
  final List<TvMenuSection> sections;

  final VoidCallback onClose;

  /// Called on any focus change / selection within the menu, so the host can
  /// reset an inactivity auto-hide timer while the user is navigating.
  final VoidCallback? onInteract;

  @override
  State<TvTrackMenu> createState() => _TvTrackMenuState();
}

class _TvTrackMenuState extends State<TvTrackMenu> {
  final _scope = FocusScopeNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var optionIndex = 0;
    final useSections = widget.sections.isNotEmpty;
    return Align(
      alignment: Alignment.centerRight,
      child: FocusScope(
        node: _scope,
        onKeyEvent: (_, e) {
          final k = e.logicalKey;
          // Swallow EVERY phase of Back (down/repeat/up). Closing on the DOWN
          // but letting the UP fall through hands the same press to the system
          // as a route pop — which then eats the NEXT Back-ladder rung.
          if (k == LogicalKeyboardKey.goBack ||
              k == LogicalKeyboardKey.escape) {
            if (e is KeyDownEvent) widget.onClose();
            return KeyEventResult.handled;
          }
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          widget.onInteract?.call();
          if (k == LogicalKeyboardKey.arrowLeft ||
              k == LogicalKeyboardKey.arrowRight) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          width: 380,
          height: double.infinity,
          color: Colors.black.withValues(alpha: 0.92),
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (useSections)
                  for (final s in widget.sections) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: Text(
                        s.title,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                    for (final o in s.options)
                      _Row(
                        option: o,
                        autofocus: optionIndex++ == 0,
                        onInteract: widget.onInteract,
                      ),
                  ]
                else
                  for (final o in widget.options)
                    _Row(
                      option: o,
                      autofocus: optionIndex++ == 0,
                      onInteract: widget.onInteract,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.option, this.autofocus = false, this.onInteract});
  final TvMenuOption option;
  final bool autofocus;
  final VoidCallback? onInteract;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.option;
    final trailingColor =
        _focused ? Colors.white : Colors.white.withValues(alpha: 0.55);
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onInteract?.call();
      },
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && okKeys.contains(e.logicalKey)) {
          widget.onInteract?.call();
          o.onSelect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: o.onSelect,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: _focused ? AppColors.accent : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (o.showCheck) ...[
                Icon(
                  o.selected ? Icons.check : Icons.circle_outlined,
                  size: 18,
                  color: o.selected
                      ? (_focused ? Colors.white : AppColors.accent)
                      : Colors.white38,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  o.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (o.trailing != null)
                Text(
                  o.trailing!,
                  style: TextStyle(color: trailingColor, fontSize: 15),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
