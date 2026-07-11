import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Whether an extension/plugin row matches a search [query].
///
/// Case-insensitive substring on [name]; a query that exactly equals the
/// row's [lang] code (e.g. "en", "id") also matches. An empty/blank query
/// matches everything.
bool sourceSearchMatches(String query, String name, [String? lang]) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (name.toLowerCase().contains(q)) return true;
  return lang != null && lang.trim().toLowerCase() == q;
}

/// The shared search box used by the provider screens (phone + TV).
///
/// Purely presentational: the owning screen holds the [controller] and
/// rebuilds itself from [onChanged]. On TV the field participates in normal
/// D-pad focus traversal; the accent focus border marks it as focused.
class SourcesSearchField extends StatelessWidget {
  const SourcesSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search extensions',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: AppText.body,
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppText.body.copyWith(color: AppColors.textSecondary),
        prefixIcon:
            const Icon(Icons.search, color: AppColors.textSecondary, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close,
                    color: AppColors.textSecondary, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
    );
  }
}
