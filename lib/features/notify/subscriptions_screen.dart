import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/announce/announcement.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/subscription_checker.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../announce/announcement_sheet.dart';
import '../detail/detail_screen.dart';
import 'subscriptions_screen_tv.dart';

/// The Notifications screen: developer announcements (history) on top, then the
/// "new episode" subscriptions (the shows the bell on Detail subscribed to).
/// Opening it clears the announcement badge.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  SubscriptionStore get _store => sl<SubscriptionStore>();
  AnnouncementStore get _announcements => sl<AnnouncementStore>();

  @override
  void initState() {
    super.initState();
    // Viewing the list clears the "new announcement" badge.
    _announcements.markAllSeen();
  }

  Future<void> _openDetail(Subscription s) async {
    await Navigator.of(context).push(
      DetailScreen.route(
        MediaItem(
          id: s.url,
          title: s.title,
          url: s.url,
          type: ProviderType.anime,
          sourceId: s.sourceId,
          cover: s.cover,
          coverHeaders: s.coverHeaders,
        ),
      ),
    );
    if (mounted) setState(() {}); // reflect an unsubscribe done from the detail
  }

  Future<void> _remove(Subscription s) async {
    await _store.remove(s.sourceId, s.url);
    await CsNotify.sync(_store.all()); // drop it from the native worker too
    if (mounted) setState(() {});
  }

  Future<void> _checkNow() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Checking for new episodes…')),
    );
    await sl<SubscriptionChecker>().checkAll(); // JS sources
    await CsNotify.checkNow(); // CS sources (native worker)
    if (mounted) setState(() {});
  }

  String _sourceLabel(String sourceId) =>
      sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SubscriptionsScreenTv();
    final subs = _store.all();
    final announcements = _announcements.all();
    final empty = subs.isEmpty && announcements.isEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Notifications', style: AppText.title),
        actions: [
          if (subs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Check now',
              onPressed: _checkNow,
            ),
        ],
      ),
      body: empty
          ? const EmptyState(
              icon: Icons.notifications_none_rounded,
              message:
                  'No notifications yet.\nTap the bell on a show to get alerted '
                  'when a new episode is out.',
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (announcements.isNotEmpty) ...[
                  _header('Announcements'),
                  for (final a in announcements) _announcementTile(a),
                ],
                if (subs.isNotEmpty) ...[
                  if (announcements.isNotEmpty) const SizedBox(height: 8),
                  _header('Subscribed shows'),
                  for (final s in subs) _subscriptionTile(s),
                ],
              ],
            ),
    );
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      label.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _announcementTile(Announcement a) {
    final (icon, tint) = switch (a.type) {
      'warning' => (Icons.warning_amber_rounded, const Color(0xFFF2B01E)),
      'update' => (Icons.system_update_rounded, AppColors.accent),
      _ => (Icons.campaign_rounded, AppColors.accent),
    };
    final iconAvatar = CircleAvatar(
      radius: 20,
      backgroundColor: tint.withValues(alpha: 0.14),
      child: Icon(icon, color: tint, size: 20),
    );
    final hasImage = a.imageUrl != null && a.imageUrl!.isNotEmpty;
    return ListTile(
      // Re-open the full message (with its action button) in the sheet.
      onTap: () => showAnnouncementSheet(context, a),
      leading: hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: CachedNetworkImage(
                  imageUrl: a.imageUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => iconAvatar,
                ),
              ),
            )
          : iconAvatar,
      title: Text(
        a.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: a.body.isEmpty
          ? null
          : Text(
              a.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
    );
  }

  Widget _subscriptionTile(Subscription s) => ListTile(
    onTap: () => _openDetail(s),
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 62,
        child: (s.cover != null && s.cover!.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: s.cover!,
                httpHeaders: s.coverHeaders,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) =>
                    ColoredBox(color: AppColors.surface2),
              )
            : ColoredBox(color: AppColors.surface2),
      ),
    ),
    title: Text(
      s.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
    ),
    subtitle: Text(_sourceLabel(s.sourceId), style: AppText.caption),
    trailing: IconButton(
      icon: const Icon(
        Icons.notifications_off_outlined,
        color: AppColors.textSecondary,
      ),
      tooltip: 'Turn off',
      onPressed: () => _remove(s),
    ),
  );
}
