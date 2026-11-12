import 'package:cached_network_image/cached_network_image.dart';
import 'package:cue/cue.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../l10n/l10n.dart';

/// A null pick selects the app's own list; dismissing leaves it unchanged.
Future<void> showTrackerSwitchPopup(
  BuildContext context, {
  required Tracker? current,
  required List<Tracker> trackers,
  required ValueChanged<Tracker?> onPick,
  String? ownAvatarUrl,
  String? ownName,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.dismiss,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) => SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final top = (constraints.maxHeight * 0.15).clamp(16.0, 96.0);
          return Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, top, 16, 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 300,
                  maxHeight: constraints.maxHeight - top - 16,
                ),
                child: _TrackerSwitchDialog(
                  current: current,
                  trackers: trackers,
                  onPick: onPick,
                  ownAvatarUrl: ownAvatarUrl,
                  ownName: ownName,
                ),
              ),
            ),
          );
        },
      ),
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _TrackerSwitchDialog extends StatelessWidget {
  const _TrackerSwitchDialog({
    required this.current,
    required this.trackers,
    required this.onPick,
    this.ownAvatarUrl,
    this.ownName,
  });

  final Tracker? current;
  final List<Tracker> trackers;
  final ValueChanged<Tracker?> onPick;
  final String? ownAvatarUrl;
  final String? ownName;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    elevation: 8,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: AppColors.hairline),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Text(
            'Choose list',
            style: AppText.body.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const Divider(height: 1, color: AppColors.hairline),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _row(context, null, 'Zangetsu List', 0),
                for (var i = 0; i < trackers.length; i++)
                  _row(context, trackers[i], trackers[i].displayName, i + 1),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _row(BuildContext context, Tracker? tracker, String label, int index) {
    final selected = identical(tracker, current);
    final avatar = tracker == null ? ownAvatarUrl : tracker.viewerAvatar;
    final name = tracker == null ? ownName : tracker.viewerName;
    final subtitle = name?.trim().isNotEmpty == true
        ? name!
        : tracker == null
        ? context.l10n.yourSavedTitles
        : 'Connected account';
    final letter = (name?.trim().isNotEmpty == true ? name! : label)
        .characters
        .first
        .toUpperCase();
    final fallback = ColoredBox(
      color: AppColors.surface2,
      child: Center(
        child: Text(
          letter,
          style: AppText.body.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
    return Cue.onMount(
      motion: .smooth(),
      acts: [
        .opacity(from: 0.0, to: 1.0, delay: (index * 30).ms),
        .scale(from: 0.96, delay: (index * 30).ms),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Semantics(
          selected: selected,
          child: InkWell(
            onTap: () {
              onPick(tracker);
              Navigator.of(context).pop();
            },
            borderRadius: BorderRadius.circular(16),
            child: Ink(
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.accent.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? AppColors.accent.withValues(alpha: 0.25)
                      : Colors.transparent,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ClipOval(
                      child: avatar?.isNotEmpty == true
                          ? CachedNetworkImage(
                              imageUrl: avatar!,
                              fit: BoxFit.cover,
                              memCacheWidth: 120,
                              placeholder: (_, _) => fallback,
                              errorWidget: (_, _, _) => fallback,
                            )
                          : fallback,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? AppColors.accent : AppColors.textTertiary,
                    size: 20,
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
