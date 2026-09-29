import 'package:flutter/material.dart';

import '../anilist/anilist_service.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tracker/tracker.dart';
import 'global_messenger.dart';

/// Ask for a name and create it on AniList. Returns the new full set of list
/// names, or null when cancelled or the write failed.
Future<List<String>?> promptCreateAniListList(
  BuildContext context,
  AniListService service,
  MediaKind kind,
) =>
    _promptNewList(context, service, kind);

Future<List<String>?> _promptNewList(
  BuildContext context,
  AniListService service,
  MediaKind kind,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('New AniList list', style: AppText.title),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: const InputDecoration(hintText: 'Rewatching, Favourites, …'),
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
  if (name == null || name.trim().isEmpty) return null;
  final next = await service.createCustomList(name, kind: kind);
  if (next == null) showGlobalSnack("Couldn't create the list on AniList");
  return next;
}

/// Tick which of the user's AniList custom lists [item] belongs to.
///
/// AniList's own lists — the ones on their website — not the app's local
/// categories. The names come from the user's AniList settings and can't be
/// created from here: the per-entry field only records which existing lists a
/// title is in, and AniList ignores a name it doesn't know rather than making
/// one.
///
/// The write is deferred to close on purpose. AniList takes the submitted set
/// as the WHOLE membership, so saving per tick would mean one request each and
/// a half-applied state if the user backs out mid-way.
Future<void> showAniListCustomListsSheet(
  BuildContext context,
  AniListService service,
  MediaItem item,
  List<String> current,
) async {
  final kind = (item.type == ProviderType.manga || item.type == ProviderType.novel)
      ? MediaKind.manga
      : MediaKind.anime;

  var names = await service.customListNames(kind: kind);
  if (!context.mounted) return;

  if (names.isEmpty) {
    // No lists yet — go straight to making one rather than showing an empty
    // sheet with nothing to tick.
    final made = await _promptNewList(context, service, kind);
    if (made == null || !context.mounted) return;
    names = made;
  }

  final selected = current.toSet();
  final before = current.toSet();

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('AniList custom lists', style: AppText.title),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Saved to your AniList account',
                  style: AppText.caption,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final n in names)
                    CheckboxListTile(
                      value: selected.contains(n),
                      activeColor: AppColors.accent,
                      title: Text(
                        n,
                        style:
                            AppText.body.copyWith(color: AppColors.textPrimary),
                      ),
                      onChanged: (v) => setSheetState(() {
                        if (v ?? false) {
                          selected.add(n);
                        } else {
                          selected.remove(n);
                        }
                      }),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.add_rounded, color: AppColors.accent),
              title: Text(
                'New list',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
              subtitle: Text('Creates it on AniList', style: AppText.caption),
              onTap: () async {
                final made = await _promptNewList(ctx, service, kind);
                if (made == null) return;
                // Tick it straight away — making a list here means wanting
                // this title in it.
                final fresh = made.where((n) => !names.contains(n)).toList();
                setSheetState(() {
                  names = made;
                  selected.addAll(fresh);
                });
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );

  // Nothing moved — don't spend a request saying so.
  if (selected.length == before.length && selected.containsAll(before)) return;

  final ok = await service.setCustomLists(
    malId: item.malId,
    title: item.title,
    names: selected.toList(),
    kind: kind,
  );
  showGlobalSnack(ok ? 'Saved to AniList' : "Couldn't save to AniList");
}
