import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../models/media_item.dart';
import '../playback/category_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Tick which of the user's categories [item] belongs to.
///
/// Several at once: a category is a label, not a move, so a title keeps its
/// status and every other category it's already in.
///
/// Lives here rather than in My List because the Add-to-List sheet is opened
/// from a dozen places — detail, home rows, history, TV — and all of them
/// should be able to file a title as they add it.
Future<void> showCategoryPicker(BuildContext context, MediaItem item) async {
  if (!sl.isRegistered<CategoryStore>()) return;
  final store = sl<CategoryStore>();

  if (store.all().isEmpty) {
    final made = await _promptNewCategory(context, store);
    if (made == null || !context.mounted) return;
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (ctx, setSheetState) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Categories', style: AppText.title),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in store.all())
                    CheckboxListTile(
                      value: store.isIn(item, c.id),
                      activeColor: AppColors.accent,
                      title: Text(
                        c.name,
                        style:
                            AppText.body.copyWith(color: AppColors.textPrimary),
                      ),
                      onChanged: (v) async {
                        await store.setMembership(item, c.id, v ?? false);
                        setSheetState(() {});
                      },
                    ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.add_rounded, color: AppColors.accent),
              title: Text(
                'New category',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
              onTap: () async {
                final made = await _promptNewCategory(ctx, store);
                // Filing it straight away saves a second trip through the sheet.
                if (made != null) {
                  await store.setMembership(item, made.id, true);
                  setSheetState(() {});
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Name a new category. Returns null when cancelled, blank, or the name is
/// already taken — two tabs reading the same would be indistinguishable.
Future<ListCategory?> _promptNewCategory(
  BuildContext context,
  CategoryStore store,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('New category', style: AppText.title),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: const InputDecoration(hintText: 'Persona, Gym, …'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  if (name == null) return null;
  return store.create(name);
}
