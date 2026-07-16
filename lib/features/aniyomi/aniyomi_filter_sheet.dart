import 'package:flutter/material.dart';

import '../../core/aniyomi/aniyomi_filters.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Shows the per-source Aniyomi filter sheet.
///
/// [filters] is the schema list returned by [SourceRepository.aniFilters].
/// The sheet mutates the leaf states in place as the user interacts.
///
/// Returns the mutated [filters] list when the user taps **Apply**, or `null`
/// when the sheet is dismissed or **Cancel** is tapped.
Future<List<AniyomiFilter>?> showAniyomiFilterSheet(
  BuildContext context,
  List<AniyomiFilter> filters,
) {
  return showModalBottomSheet<List<AniyomiFilter>>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AniyomiFilterSheet(filters: filters),
  );
}

// ---------------------------------------------------------------------------
// Sheet widget
// ---------------------------------------------------------------------------

class _AniyomiFilterSheet extends StatefulWidget {
  const _AniyomiFilterSheet({required this.filters});
  final List<AniyomiFilter> filters;

  @override
  State<_AniyomiFilterSheet> createState() => _AniyomiFilterSheetState();
}

class _AniyomiFilterSheetState extends State<_AniyomiFilterSheet> {
  // Keyed by the actual AniyomiText object so Reset can sync controllers back.
  final Map<AniyomiText, TextEditingController> _textControllers = {};

  @override
  void initState() {
    super.initState();
    _gatherTextControllers(widget.filters);
  }

  void _gatherTextControllers(List<AniyomiFilter> list) {
    for (final f in list) {
      if (f is AniyomiText) {
        _textControllers[f] = TextEditingController(text: f.state);
      } else if (f is AniyomiGroup) {
        _gatherTextControllers(f.children);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Reset ────────────────────────────────────────────────────────────────

  void _reset() {
    _resetList(widget.filters);
    // Keep text controllers in sync with reset values.
    for (final entry in _textControllers.entries) {
      entry.value.text = entry.key.state;
    }
    setState(() {});
  }

  static void _resetList(List<AniyomiFilter> list) {
    for (final f in list) {
      if (f is AniyomiSelect) {
        f.state = 0;
      } else if (f is AniyomiText) {
        f.state = '';
      } else if (f is AniyomiCheckBox) {
        f.state = false;
      } else if (f is AniyomiTriState) {
        f.state = 0;
      } else if (f is AniyomiSort) {
        f.index = null;
        f.ascending = true;
      } else if (f is AniyomiGroup) {
        _resetList(f.children);
      }
      // AniyomiHeader / AniyomiSeparator carry no mutable state.
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDragHandle(),
            _buildHeader(),
            const Divider(color: AppColors.hairline, height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                children: [
                  for (final f in widget.filters) _buildControl(f),
                ],
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            _buildActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.fromLTRB(0, 12, 0, 4),
        decoration: BoxDecoration(
          color: AppColors.hairline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text('Source Filters', style: AppText.headline),
          ),
          TextButton(
            onPressed: _reset,
            child: Text(
              'Reset',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                'Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
              ),
              onPressed: () => Navigator.pop(context, widget.filters),
              child: Text('Apply', style: AppText.button),
            ),
          ),
        ],
      ),
    );
  }

  // ── Per-filter control builders ──────────────────────────────────────────

  Widget _buildControl(AniyomiFilter f) {
    return switch (f) {
      AniyomiHeader() => _buildHeader2(f),
      AniyomiSeparator() => _buildSeparator(),
      AniyomiSelect() => _buildSelect(f),
      AniyomiText() => _buildText(f),
      AniyomiCheckBox() => _buildCheckBox(f),
      AniyomiTriState() => _buildTriState(f),
      AniyomiGroup() => _buildGroup(f),
      AniyomiSort() => _buildSort(f),
    };
  }

  // Named _buildHeader2 to avoid collision with the sheet-level _buildHeader.
  Widget _buildHeader2(AniyomiHeader f) {
    if (f.name.isEmpty) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
      child: Text(
        f.name.toUpperCase(),
        style: AppText.caption.copyWith(
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSeparator() {
    return const Divider(color: AppColors.hairline, height: 24);
  }

  Widget _buildSelect(AniyomiSelect f) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f.name,
            style: AppText.caption.copyWith(
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          DropdownButton<int>(
            value: f.state,
            isExpanded: true,
            dropdownColor: AppColors.surface2,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            underline: const Divider(color: AppColors.hairline, height: 1),
            items: [
              for (int i = 0; i < f.values.length; i++)
                DropdownMenuItem<int>(
                  value: i,
                  child: Text(f.values[i]),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => f.state = v);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildText(AniyomiText f) {
    final ctrl = _textControllers[f]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: ctrl,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        cursorColor: AppColors.accent,
        decoration: InputDecoration(
          labelText: f.name,
          labelStyle: AppText.caption.copyWith(color: AppColors.textTertiary),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.hairline),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.accent),
          ),
          isDense: true,
        ),
        onChanged: (v) => f.state = v,
      ),
    );
  }

  Widget _buildCheckBox(AniyomiCheckBox f) {
    return SwitchListTile(
      value: f.state,
      onChanged: (v) => setState(() => f.state = v),
      title: Text(
        f.name,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
      ),
      activeThumbColor: AppColors.accent,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildTriState(AniyomiTriState f) {
    final (IconData icon, Color color, String hint) = switch (f.state) {
      1 => (Icons.check_circle, AppColors.accent, 'Include'),
      2 => (Icons.remove_circle, const Color(0xFFFF6B6B), 'Exclude'),
      _ => (Icons.radio_button_unchecked, AppColors.textTertiary, 'Ignore'),
    };

    return InkWell(
      onTap: () => setState(() => f.state = (f.state + 1) % 3),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                f.name,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
            ),
            Text(
              hint,
              style: AppText.caption.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSort(AniyomiSort f) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f.name,
            style: AppText.caption.copyWith(
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int?>(
                  value: f.index,
                  isExpanded: true,
                  dropdownColor: AppColors.surface2,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  hint: Text(
                    'None',
                    style:
                        AppText.body.copyWith(color: AppColors.textSecondary),
                  ),
                  underline:
                      const Divider(color: AppColors.hairline, height: 1),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (int i = 0; i < f.values.length; i++)
                      DropdownMenuItem<int?>(
                        value: i,
                        child: Text(f.values[i]),
                      ),
                  ],
                  onChanged: (v) => setState(() => f.index = v),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: f.index == null
                    ? null
                    : () => setState(() => f.ascending = !f.ascending),
                icon: Icon(
                  f.ascending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  color: f.index == null
                      ? AppColors.textTertiary
                      : AppColors.accent,
                ),
                tooltip: f.ascending ? 'Ascending' : 'Descending',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(AniyomiGroup f) {
    return ExpansionTile(
      title: Text(
        f.name,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
      ),
      tilePadding: EdgeInsets.zero,
      iconColor: AppColors.textSecondary,
      collapsedIconColor: AppColors.textSecondary,
      childrenPadding: const EdgeInsets.only(left: 12),
      children: [
        for (final child in f.children) _buildControl(child),
      ],
    );
  }
}
