import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_keys.dart';

/// One selectable row in a [TvTrackMenu] section.
class TvMenuOption {
  const TvMenuOption({
    required this.label,
    this.selected = false,
    this.trailing,
    required this.onSelect,
  });
  final String label;
  final bool selected;
  final String? trailing;
  final VoidCallback onSelect;
}

/// A titled group of options.
class TvMenuSection {
  const TvMenuSection({required this.title, required this.options});
  final String title;
  final List<TvMenuOption> options;
}

/// A D-pad-navigable right-side panel of track sections. Up/Down move focus,
/// OK selects, Back closes. Presentational: the screen supplies the sections
/// and the per-option callbacks.
class TvTrackMenu extends StatelessWidget {
  const TvTrackMenu({super.key, required this.sections, required this.onClose});

  final List<TvMenuSection> sections;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.goBack ||
                  e.logicalKey == LogicalKeyboardKey.escape)) {
            onClose();
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
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
              children: [
                for (final s in sections) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
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
                  for (final o in s.options) _Row(option: o),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.option});
  final TvMenuOption option;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.option;
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && okKeys.contains(e.logicalKey)) {
          o.onSelect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: o.onSelect,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: _focused ? Colors.white.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Icon(
                o.selected ? Icons.check : Icons.circle_outlined,
                size: 18,
                color: o.selected ? AppColors.accent : Colors.white38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(o.label,
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
              if (o.trailing != null)
                Text(o.trailing!,
                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
