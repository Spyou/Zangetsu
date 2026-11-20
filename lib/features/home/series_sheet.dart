import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/series_groups.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// "Add to series" picker: existing groups as a single-select list (a title
/// belongs to at most one) + an inline "New series" field that creates and
/// assigns in one go. Reached from the same per-card "more" sheet that
/// handles status and categories.
Future<void> showSeriesSheet(BuildContext context, MediaItem item) async {
  if (!sl.isRegistered<SeriesGroupStore>()) return;
  final store = sl<SeriesGroupStore>();
  final titleKey = '${item.sourceId}::${item.id}';

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => SeriesSheet(titleKey: titleKey, store: store),
  );
}

class SeriesSheet extends StatefulWidget {
  const SeriesSheet({super.key, required this.titleKey, this.store});

  final String titleKey;
  final SeriesGroupStore? store;

  @override
  State<SeriesSheet> createState() => _SeriesSheetState();
}

class _SeriesSheetState extends State<SeriesSheet> {
  final _newGroupController = TextEditingController();

  SeriesGroupStore get _store => widget.store ?? sl<SeriesGroupStore>();

  @override
  void dispose() {
    _newGroupController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final made = await _store.create(_newGroupController.text);
    if (made != null) {
      await _store.addMember(made.id, widget.titleKey);
      _newGroupController.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final groups = store.all();
    final currentGroupId = store.groupOf(widget.titleKey)?.id;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(context.l10n.addToSeries, style: AppText.title),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                RadioListTile<String?>(
                  value: null,
                  groupValue: currentGroupId,
                  activeColor: AppColors.accent,
                  title: Text(
                    context.l10n.noSeries,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  onChanged: (_) async {
                    if (currentGroupId != null) {
                      await store.removeMember(currentGroupId, widget.titleKey);
                    }
                    if (mounted) setState(() {});
                  },
                ),
                for (final group in groups)
                  RadioListTile<String?>(
                    value: group.id,
                    groupValue: currentGroupId,
                    activeColor: AppColors.accent,
                    title: Text(
                      group.title,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    onChanged: (_) async {
                      await store.addMember(group.id, widget.titleKey);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _newGroupController,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: context.l10n.newSeries,
                  hintStyle: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  prefixIcon: Icon(Icons.add_rounded, color: AppColors.accent),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _create(),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
