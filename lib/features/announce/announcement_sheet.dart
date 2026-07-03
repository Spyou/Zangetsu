import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/announce/announcement.dart';
import '../../core/announce/announcement_service.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';

/// Fetch the announcements feed and, if something new arrived, pop the newest
/// one as a bottom sheet over the running UI. [context] must be a live widget
/// context under the app Navigator (call it from a home screen's post-frame).
/// Marks every freshly-arrived announcement as seen afterwards (they remain in
/// the Notifications history), so nothing re-pops on the next launch.
/// Fire-and-forget; never throws in normal use.
Future<void> maybeShowAnnouncement(BuildContext context) async {
  final fresh = await sl<AnnouncementService>().check();
  if (fresh.isEmpty) return;
  if (context.mounted) {
    await showAnnouncementSheet(context, fresh.first);
  }
  final store = sl<AnnouncementStore>();
  for (final a in fresh) {
    await store.markSeen(a.id);
  }
}

/// Show a single announcement as a modal bottom sheet.
Future<void> showAnnouncementSheet(BuildContext context, Announcement a) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AnnouncementSheet(a: a),
  );
}

class _AnnouncementSheet extends StatelessWidget {
  const _AnnouncementSheet({required this.a});

  final Announcement a;

  (IconData, Color) get _badge => switch (a.type) {
    'warning' => (Icons.warning_amber_rounded, const Color(0xFFF2B01E)),
    'update' => (Icons.system_update_rounded, AppColors.accent),
    _ => (Icons.campaign_rounded, AppColors.accent),
  };

  Future<void> _openAction() async {
    final url = a.actionUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = _badge;
    final isTv = sl<AppMode>().isTv;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Cap the height so a long message scrolls instead of overflowing —
        // important on TV (short landscape) where the body can be many lines.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Grab handle.
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header + body scroll together; the buttons stay pinned below.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: tint.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: tint, size: 24),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  style: AppText.headline.copyWith(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (a.date != null && a.date!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(a.date!, style: AppText.caption),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (a.body.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          a.body,
                          style: AppText.body.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (a.actionLabel != null && a.actionUrl != null) ...[
                    _sheetButton(
                      context,
                      label: a.actionLabel!,
                      filled: false,
                      autofocus: false,
                      isTv: isTv,
                      onTap: () {
                        Navigator.of(context).pop();
                        _openAction();
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                  _sheetButton(
                    context,
                    label: 'Got it',
                    filled: true,
                    // On TV give the primary button initial focus so OK dismisses.
                    autofocus: isTv,
                    isTv: isTv,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(
    BuildContext context, {
    required String label,
    required bool filled,
    required bool autofocus,
    required bool isTv,
    required VoidCallback onTap,
  }) {
    final button = filled
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: onTap,
            child: Text(label),
          )
        : OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: BorderSide(color: AppColors.hairline),
            ),
            onPressed: onTap,
            child: Text(label),
          );
    if (!isTv) return button;
    // On TV the D-pad drives focus; TvFocusable handles OK-key activation.
    return TvFocusable(scale: 1.0, autofocus: autofocus, onTap: onTap, child: button);
  }
}
