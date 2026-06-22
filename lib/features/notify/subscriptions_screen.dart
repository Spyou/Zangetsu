import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/notify/subscription_checker.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

/// Manage "new episode" subscriptions (the shows the bell on Detail subscribed
/// to). Lists them with poster + source, tap to open, and a button to turn each
/// off. A "Check now" action runs the episode sweep on demand.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  SubscriptionStore get _store => sl<SubscriptionStore>();

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
    if (mounted) setState(() {});
  }

  Future<void> _checkNow() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Checking for new episodes…')),
    );
    await sl<SubscriptionChecker>().checkAll();
    if (mounted) setState(() {});
  }

  String _sourceLabel(String sourceId) =>
      sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;

  @override
  Widget build(BuildContext context) {
    final subs = _store.all();
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
      body: subs.isEmpty
          ? const EmptyState(
              icon: Icons.notifications_none_rounded,
              message:
                  'No notifications yet.\nTap the bell on a show to get alerted '
                  'when a new episode is out.',
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: subs.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.hairline),
              itemBuilder: (context, i) {
                final s = subs[i];
                return ListTile(
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
                                  const ColoredBox(color: AppColors.surface2),
                            )
                          : const ColoredBox(color: AppColors.surface2),
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
              },
            ),
    );
  }
}
