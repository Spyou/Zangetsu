import 'package:flutter/material.dart';

import '../playback/external_player.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// What a long-press on an episode chose: which player to open it in, this
/// once. An empty [package] means the built-in player.
typedef PlayerChoice = ({String package, String label});

/// What the long-press menu was asked to do. The player pick is its own sheet,
/// so this only carries the actions that don't need further input.
enum EpisodeAction {
  /// Open the "play this episode with" sheet.
  pickPlayer,

  /// Drop this episode's cached links and play again. For when a mirror has
  /// expired and every attempt fails on links that looked fine 20 minutes ago.
  reloadLinks,
}

/// The long-press menu itself. Kept separate from the player sheet so the
/// player list doesn't push the actions off-screen once several players are
/// installed.
Future<EpisodeAction?> showEpisodeActionSheet(
  BuildContext context, {
  required String episodeLabel,
  required String currentPlayerLabel,
}) {
  return showModalBottomSheet<EpisodeAction>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                episodeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline,
              ),
            ),
          ),
          _PlayerRow(
            icon: Icons.play_circle_outline_rounded,
            label: 'Play with…',
            trailingText: currentPlayerLabel,
            onTap: () =>
                Navigator.pop(sheetContext, EpisodeAction.pickPlayer),
          ),
          _PlayerRow(
            icon: Icons.refresh_rounded,
            label: 'Reload links',
            subtitle: 'Fetch fresh streams if playback keeps failing',
            onTap: () =>
                Navigator.pop(sheetContext, EpisodeAction.reloadLinks),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Long-press an episode → pick where it plays, for this episode only.
///
/// Deliberately doesn't touch [PlaybackPrefs.externalPlayerPackage]: Settings
/// stays the place that says "always use X", and trying VLC once shouldn't
/// quietly rewire every future tap.
///
/// Returns null when dismissed — a long-press that starts playback on its own
/// would be a trap.
Future<PlayerChoice?> showEpisodePlayerSheet(
  BuildContext context, {
  required String episodeLabel,
  required String defaultPackage,
}) async {
  final installed = await ExternalPlayer().installed();
  if (!context.mounted) return null;

  return showModalBottomSheet<PlayerChoice>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    // The list is short, but a device with several players installed plus a
    // long episode title shouldn't push the last row off-screen.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Play this episode with', style: AppText.headline),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    episodeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              _PlayerRow(
                icon: Icons.play_circle_outline_rounded,
                label: 'Built-in player',
                isDefault: defaultPackage.isEmpty,
                onTap: () => Navigator.pop(
                  sheetContext,
                  (package: '', label: 'Built-in player'),
                ),
              ),
              for (final p in installed)
                _PlayerRow(
                  icon: Icons.open_in_new_rounded,
                  label: p.label,
                  isDefault: defaultPackage == p.package,
                  onTap: () => Navigator.pop(
                    sheetContext,
                    (package: p.package, label: p.label),
                  ),
                ),
              // Opening an empty sheet on long-press reads as a broken gesture,
              // so say why there's only one row rather than showing nothing.
              if (installed.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Text(
                    'No external players installed. VLC, MX Player and '
                    'Just Player all show up here once installed.',
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDefault = false,
    this.subtitle,
    this.trailingText,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Marks the row a plain tap would have used. Marked rather than sorted to
  /// the top, so the list doesn't reshuffle when the Settings default changes.
  final bool isDefault;
  final String? subtitle;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final trailing = trailingText ?? (isDefault ? 'Default' : null);
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(label, style: AppText.body),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      trailing: trailing == null
          ? null
          : Text(
              trailing,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
      onTap: onTap,
    );
  }
}
